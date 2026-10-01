//! Probe socket plumbing: connect, read Hello, pull frames off the
//! stream, send requests back.
//!
//! Everything here is about the *wire* — nothing in this file knows
//! what a frame will be rendered as.

const std = @import("std");
const proto = @import("proto");
const net = @import("net_compat");
const time_compat = @import("time_compat");

/// Reconnect backoff bounds, shared by the primary probe and every
/// peer added via `--probe`. Each connection tracks its own next-
/// retry timestamp + current backoff; both reset to the floor on a
/// successful reconnect.
pub const reconnect_min_ms: i64 = 250;
pub const reconnect_max_ms: i64 = 4000;

/// Bits that mean "socket is unusable, time to leave". POLL.ERR alone
/// (no POLL.IN) is what a TCP RST looks like — kill -9'ing the probe
/// sets only ERR, and an earlier loop spun forever rendering stale
/// frames. POLL.HUP fires on orderly close; POLL.NVAL means the fd was
/// closed under us (shouldn't happen here, defensive).
pub const sock_err_mask: i16 = std.posix.POLL.ERR | std.posix.POLL.HUP | std.posix.POLL.NVAL;

/// Result of `extractFrame`. The probe socket carries TelemetryFrame
/// (128 B), optional HardwareInfo (128 B), and EngineReport (64 B)
/// interleaved on the same stream; the bench dispatches by leading
/// magic. Frames are returned by value (small structs, fits-in-cache)
/// so the caller doesn't have to coordinate buffer lifetimes with the
/// read pump.
pub const Frame = union(enum) {
    /// Buffer doesn't contain a full frame yet — keep reading.
    none,
    /// Leading magic doesn't match any known frame; caller closes the
    /// connection and reconnects to resync.
    desync,
    hello: proto.Hello,
    telemetry: proto.TelemetryFrame,
    hardware_info: proto.HardwareInfo,
    engine_report: proto.EngineReport,
    token_text: TokenText,
};

/// A decoded-text chunk lifted out of the read buffer. Carries its own
/// storage for the same reason the fixed frames are returned by value:
/// the caller must not have to finish with it before the read pump
/// reuses the buffer underneath.
pub const TokenText = struct {
    seq: u32,
    final: bool,
    buf: [proto.TokenText.max_payload]u8,
    len: u16,

    pub fn slice(self: *const TokenText) []const u8 {
        return self.buf[0..self.len];
    }
};

/// Pull one frame out of `read_buf[0..read_pos]` if a full one is
/// available, advancing `read_pos` past it. Any remaining bytes (the
/// start of the next frame) are shifted to the head of the buffer.
/// Call in a loop until `.none`, then read more bytes and try again.
///
/// `read_buf` must be aligned to `@alignOf(proto.TelemetryFrame)` (=8)
/// at index 0; both the primary and peer read buffers declare that
/// alignment explicitly. Every frame's total size is a multiple of 8
/// — the fixed ones by construction, the variable one because
/// `TokenText.payloadSpan` pads to it — so the head stays aligned
/// after a shift-down too. `read_buf` must also be at least
/// `proto.max_frame_bytes` long, or a legal frame could never fit and
/// the pump would stall on a buffer that never drains.
pub fn extractFrame(read_buf: []u8, read_pos: *usize) Frame {
    std.debug.assert(read_buf.len >= proto.max_frame_bytes);

    const fs = switch (proto.frameSpan(read_buf[0..read_pos.*])) {
        .need_more => return .none,
        .desync => return .desync,
        .total => |n| n,
    };
    if (read_pos.* < fs) return .none;

    const m = std.mem.readInt(u32, read_buf[0..4], .little);
    const out: Frame = switch (m) {
        proto.hello_magic => .{
            .hello = @as(*const proto.Hello, @ptrCast(@alignCast(read_buf.ptr))).*,
        },
        proto.magic => .{
            .telemetry = @as(*const proto.TelemetryFrame, @ptrCast(@alignCast(read_buf.ptr))).*,
        },
        proto.hardware_info_magic => .{
            .hardware_info = @as(*const proto.HardwareInfo, @ptrCast(@alignCast(read_buf.ptr))).*,
        },
        proto.engine_report_magic => .{
            .engine_report = @as(*const proto.EngineReport, @ptrCast(@alignCast(read_buf.ptr))).*,
        },
        proto.token_text_magic => blk: {
            const hdr: *const proto.TokenText = @ptrCast(@alignCast(read_buf.ptr));
            var text: TokenText = .{
                .seq = hdr.seq,
                .final = hdr.flags & proto.TokenText.flag_final != 0,
                .buf = undefined,
                .len = @intCast(hdr.byte_len),
            };
            const body = read_buf[proto.TokenText.header_bytes..][0..text.len];
            @memcpy(text.buf[0..text.len], body);
            break :blk .{ .token_text = text };
        },
        else => return .desync,
    };

    const remaining = read_pos.* - fs;
    if (remaining > 0) {
        std.mem.copyForwards(u8, read_buf[0..remaining], read_buf[fs..read_pos.*]);
    }
    read_pos.* = remaining;
    return out;
}

/// True when the Hello came from the iOS probe app, which cannot
/// sample per-core utilisation or CPU frequencies. Drives the
/// alternate stat rows rather than rendering unavailable fields as
/// sampled zeros.
pub fn isIosProbe(hello: *const proto.Hello) bool {
    const source = proto.Hello.sourceSlice(&hello.source);
    const soc = proto.Hello.nameSlice(&hello.soc_name);
    return std.mem.startsWith(u8, source, "ios network") or
        std.mem.startsWith(u8, soc, "iPhone") or
        std.mem.startsWith(u8, soc, "iPad");
}

// --- connecting ---------------------------------------------------

/// Cap on the time spent in a single connect attempt. Picked short so
/// a peer at a network-unreachable address (`--probe pixel:tcp:
/// 192.0.2.50:7779` after the wifi drops) doesn't stall the render
/// loop on the OS-level TCP SYN timeout (20–75 s on Linux/macOS).
/// Backoff handles retry pacing — each attempt just needs to fail fast.
const connect_timeout_ms: i32 = 250;

pub const TcpEndpoint = struct {
    host: ?[]const u8,
    port: u16,
};

pub fn parseTcpEndpoint(endpoint: []const u8) !TcpEndpoint {
    std.debug.assert(std.mem.startsWith(u8, endpoint, "tcp:"));
    const spec = endpoint[4..];
    if (std.mem.lastIndexOfScalar(u8, spec, ':')) |colon| {
        const host = spec[0..colon];
        const port_text = spec[colon + 1 ..];
        if (host.len == 0 or port_text.len == 0) return error.InvalidCharacter;
        return .{
            .host = host,
            .port = try std.fmt.parseInt(u16, port_text, 10),
        };
    }
    return .{
        .host = null,
        .port = try std.fmt.parseInt(u16, spec, 10),
    };
}

/// Connect to the probe with a bounded latency. The socket is created
/// `SOCK_NONBLOCK` so `connect()` returns immediately with
/// `EINPROGRESS`; we then poll() up to `connect_timeout_ms` for
/// POLL.OUT and check SO_ERROR to confirm the connect actually
/// succeeded vs. the peer rejecting after the SYN. The returned fd
/// stays non-blocking — the rest of the bench polls before every read,
/// so blocking semantics aren't required.
pub fn connectEndpoint(endpoint: []const u8) !net.fd_t {
    if (std.mem.startsWith(u8, endpoint, "tcp:")) {
        const tcp = try parseTcpEndpoint(endpoint);
        const addr = if (tcp.host) |host|
            try net.Address.initIp4Host(host, tcp.port)
        else
            net.Address.initIp4(.{ 127, 0, 0, 1 }, tcp.port);
        const sock = try net.socket(
            std.posix.AF.INET,
            std.posix.SOCK.STREAM | std.posix.SOCK.NONBLOCK,
            0,
        );
        errdefer net.close(sock);
        try connectWithTimeout(sock, addr.ptr(), addr.len());
        return sock;
    }

    const addr = try net.Address.initUnix(endpoint);
    const sock = try net.socket(
        std.posix.AF.UNIX,
        std.posix.SOCK.STREAM | std.posix.SOCK.NONBLOCK,
        0,
    );
    errdefer net.close(sock);
    try connectWithTimeout(sock, addr.ptr(), addr.len());
    return sock;
}

fn connectWithTimeout(
    sock: net.fd_t,
    addr: *const std.posix.sockaddr,
    addr_len: std.posix.socklen_t,
) !void {
    // On a non-blocking socket, connect() either succeeds immediately
    // (e.g. a unix socket whose listener is local + accepting) or
    // returns WouldBlock to indicate "in progress, poll for OUT".
    net.connect(sock, addr, addr_len) catch |e| switch (e) {
        error.WouldBlock => {},
        else => return e,
    };

    var pfd = [_]std.posix.pollfd{.{
        .fd = sock,
        .events = std.posix.POLL.OUT,
        .revents = 0,
    }};
    const ready = std.posix.poll(&pfd, connect_timeout_ms) catch return error.ConnectionRefused;
    if (ready == 0) return error.ConnectionRefused; // poll timeout

    // Non-blocking connect leaves the actual error in SO_ERROR — a
    // ready POLL.OUT alone doesn't mean success. Read it and bail if
    // the kernel set ECONNREFUSED / ETIMEDOUT / EHOSTUNREACH /
    // ENETUNREACH there.
    var so_err: i32 = 0;
    var so_buf: [@sizeOf(i32)]u8 = undefined;
    try net.getsockopt(sock, std.posix.SOL.SOCKET, std.posix.SO.ERROR, &so_buf);
    @memcpy(std.mem.asBytes(&so_err), &so_buf);
    if (so_err != 0) return error.ConnectionRefused;
}

/// Connect to the probe and read its on-connect Hello frame. Used at
/// startup and on every reconnect attempt — the bench re-reads Hello
/// on reconnect so the title bar reflects the current device (which
/// lets the user swap phones mid-session). The hello validation errors
/// are intentionally distinct from the connect errors so a caller can
/// decide whether to retry (connect failed → retry quietly) vs bail
/// (bad magic → wrong protocol). For v1 the bench retries either way,
/// because the alternative is dying mid-screencap.
pub fn connectAndReadHello(
    endpoint: []const u8,
    hello_buf: *align(@alignOf(proto.Hello)) [@sizeOf(proto.Hello)]u8,
) !std.posix.fd_t {
    const sock = try connectEndpoint(endpoint);
    errdefer net.close(sock);

    // Bound the *total* hello-read latency, not just time-to-first-
    // byte. Hello is 128 B and TCP can fragment it across segments on
    // a real network — without re-polling between reads a fragmented
    // Hello could block the render loop indefinitely. Deadline-driven:
    // each iteration polls for the remaining budget and reads what's
    // ready, treating WouldBlock as "more not ready yet, re-poll".
    const deadline_ns = time_compat.nanoTimestamp() + 1 * std.time.ns_per_s;
    var got: usize = 0;
    while (got < hello_buf.len) {
        const remaining_ns = deadline_ns - time_compat.nanoTimestamp();
        if (remaining_ns <= 0) return error.HelloTimeout;
        const remaining_ms: i32 = @intCast(@min(@divTrunc(remaining_ns, std.time.ns_per_ms), std.math.maxInt(i32)));
        var pfd = [_]std.posix.pollfd{.{
            .fd = sock,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        const ready = std.posix.poll(&pfd, remaining_ms) catch return error.HelloTimeout;
        if (ready == 0) return error.HelloTimeout;
        const n = std.posix.read(sock, hello_buf[got..]) catch |e| switch (e) {
            error.WouldBlock => continue,
            else => return e,
        };
        if (n == 0) return error.HelloEof;
        got += n;
    }

    const hello: *const proto.Hello = @ptrCast(@alignCast(hello_buf));
    if (hello.magic != proto.hello_magic) return error.BadHelloMagic;
    if (hello.version != 1) return error.HelloVersionMismatch;
    return sock;
}

/// One connect + Hello round-trip, then hang up. Discovery and
/// bootstrap use this as "is something speaking our protocol there
/// right now?" — a plain TCP accept is not enough, since any stray
/// listener on the port would pass it.
pub fn probeHealthy(endpoint: []const u8) bool {
    return probeHello(endpoint) != null;
}

pub fn probeHello(endpoint: []const u8) ?proto.Hello {
    var hello_buf: [@sizeOf(proto.Hello)]u8 align(@alignOf(proto.Hello)) = undefined;
    const fd = connectAndReadHello(endpoint, &hello_buf) catch return null;
    net.close(fd);
    return @as(*const proto.Hello, @ptrCast(@alignCast(&hello_buf))).*;
}

// --- sending ------------------------------------------------------

/// Runs on the main event-loop thread, so any wait blocks the TUI (no
/// rendering, no keypresses, no peer updates). WouldBlock means the
/// kernel send buffer is full — for a healthy probe that's a transient
/// blip and the next attempt would succeed, but a hung probe (e.g.
/// SIGSTOP'd while debugging) keeps the buffer full indefinitely and
/// would freeze the bench. Treat it as a lost peer instead; the next
/// read on this fd surfaces the disconnect and reconnect takes over.
fn writeWireBytes(fd: std.posix.fd_t, bytes: []const u8) !void {
    var written: usize = 0;
    while (written < bytes.len) {
        const n = net.write(fd, bytes[written..]) catch |e| switch (e) {
            error.WouldBlock,
            error.BrokenPipe,
            error.ConnectionResetByPeer,
            => return error.ProbeGone,
            else => return e,
        };
        if (n == 0) return error.ProbeGone;
        written += n;
    }
}

pub fn requestHardwareInfo(fd: std.posix.fd_t) !void {
    const req = proto.HardwareInfoRequest{};
    const bytes: *const [@sizeOf(proto.HardwareInfoRequest)]u8 = @ptrCast(&req);
    try writeWireBytes(fd, bytes);
}

/// Send a single RunRequest frame to a probe socket. Used on `r` to
/// ask each connected probe with has_engine=1 to spawn its configured
/// engine and start streaming EngineReport frames back over the same
/// socket.
///
/// `want_text` opts this bench into TokenText frames. The probe sends
/// these frames only when requested, so the receiver can parse them.
pub fn sendRunRequest(fd: std.posix.fd_t, want_text: bool) !void {
    const req = proto.RunRequest{
        .flags = if (want_text) proto.run_flag_want_text else 0,
    };
    const bytes: *const [@sizeOf(proto.RunRequest)]u8 = @ptrCast(&req);
    try writeWireBytes(fd, bytes);
}

pub fn sendRunSpec(fd: std.posix.fd_t, values: proto.RunSpec.Values) !void {
    var buf: [proto.max_frame_bytes]u8 align(8) = undefined;
    const frame = try proto.RunSpec.encode(&buf, values);
    try writeWireBytes(fd, frame);
}

test "extractFrame accepts telemetry without HardwareInfo" {
    const telemetry = proto.sentinelFrame(123);

    var read_buf: [proto.max_frame_bytes]u8 align(@alignOf(proto.TelemetryFrame)) = undefined;
    const bytes: *const [@sizeOf(proto.TelemetryFrame)]u8 = @ptrCast(&telemetry);
    @memcpy(read_buf[0..bytes.len], bytes);

    var read_pos: usize = bytes.len;
    const out = extractFrame(&read_buf, &read_pos);
    switch (out) {
        .telemetry => |got| {
            try std.testing.expectEqual(@as(usize, 0), read_pos);
            try std.testing.expectEqual(@as(u64, 123), got.ts_ns);
        },
        else => return error.ExpectedTelemetryFrame,
    }
}

test "extractFrame accepts an updated Hello between telemetry frames" {
    const hello = proto.Hello{ .has_engine = 1 };
    var read_buf: [proto.max_frame_bytes]u8 align(8) = undefined;
    const bytes: *const [@sizeOf(proto.Hello)]u8 = @ptrCast(&hello);
    @memcpy(read_buf[0..bytes.len], bytes);
    var read_pos: usize = bytes.len;
    switch (extractFrame(&read_buf, &read_pos)) {
        .hello => |got| {
            try std.testing.expectEqual(proto.protocol_version, got.proto_version);
            try std.testing.expectEqual(@as(usize, 0), read_pos);
        },
        else => return error.ExpectedHello,
    }
}

test "extractFrame accepts HardwareInfo frames" {
    var hw = proto.HardwareInfo{};
    const machine = "iPhone15,2";
    @memcpy(hw.machine[0..machine.len], machine);

    var read_buf: [proto.max_frame_bytes]u8 align(@alignOf(proto.TelemetryFrame)) = undefined;
    const bytes: *const [@sizeOf(proto.HardwareInfo)]u8 = @ptrCast(&hw);
    @memcpy(read_buf[0..bytes.len], bytes);

    var read_pos: usize = bytes.len;
    const out = extractFrame(&read_buf, &read_pos);
    switch (out) {
        .hardware_info => |got| {
            try std.testing.expectEqual(@as(usize, 0), read_pos);
            try std.testing.expectEqualStrings(machine, proto.HardwareInfo.machineSlice(&got.machine));
        },
        else => return error.ExpectedHardwareInfoFrame,
    }
}

test "parseTcpEndpoint supports loopback ports and host ports" {
    const loopback = try parseTcpEndpoint("tcp:7779");
    try std.testing.expect(loopback.host == null);
    try std.testing.expectEqual(@as(u16, 7779), loopback.port);

    const remote = try parseTcpEndpoint("tcp:iphone.coredevice.local:7779");
    try std.testing.expectEqualStrings("iphone.coredevice.local", remote.host.?);
    try std.testing.expectEqual(@as(u16, 7779), remote.port);
}

test "extractFrame lifts a text chunk out and keeps the next frame aligned" {
    var read_buf: [proto.max_frame_bytes]u8 align(@alignOf(proto.TelemetryFrame)) = @splat(0);
    const body = "A bonsai"; // 8 bytes of text, then a report behind it

    const hdr = proto.TokenText{
        .flags = proto.TokenText.flag_final,
        .seq = 3,
        .byte_len = body.len,
    };
    const hdr_bytes: *const [@sizeOf(proto.TokenText)]u8 = @ptrCast(&hdr);
    @memcpy(read_buf[0..hdr_bytes.len], hdr_bytes);
    @memcpy(read_buf[hdr_bytes.len..][0..body.len], body);

    const span = proto.TokenText.header_bytes + proto.TokenText.payloadSpan(body.len);
    const rep = proto.EngineReport{ .ts_ns = 42, .token_index = 1, .tokens_total = 2, .decode_tok_s = 3, .prefill_tok_s = 0 };
    const rep_bytes: *const [@sizeOf(proto.EngineReport)]u8 = @ptrCast(&rep);
    @memcpy(read_buf[span..][0..rep_bytes.len], rep_bytes);

    var read_pos: usize = span + rep_bytes.len;
    switch (extractFrame(&read_buf, &read_pos)) {
        .token_text => |got| {
            try std.testing.expectEqualStrings(body, got.slice());
            try std.testing.expectEqual(@as(u32, 3), got.seq);
            try std.testing.expect(got.final);
        },
        else => return error.ExpectedTokenText,
    }

    // The report behind it must still parse — a text frame that left
    // the buffer off a frame boundary would corrupt everything after
    // it rather than just itself.
    switch (extractFrame(&read_buf, &read_pos)) {
        .engine_report => |got| try std.testing.expectEqual(@as(u64, 42), got.ts_ns),
        else => return error.ExpectedEngineReport,
    }
    try std.testing.expectEqual(@as(usize, 0), read_pos);
}

test "a text frame split across reads yields nothing until it is whole" {
    var read_buf: [proto.max_frame_bytes]u8 align(@alignOf(proto.TelemetryFrame)) = @splat(0);
    const body = "half";
    const hdr = proto.TokenText{ .seq = 0, .byte_len = body.len };
    const hdr_bytes: *const [@sizeOf(proto.TokenText)]u8 = @ptrCast(&hdr);
    @memcpy(read_buf[0..hdr_bytes.len], hdr_bytes);
    @memcpy(read_buf[hdr_bytes.len..][0..body.len], body);

    // Header not yet complete: the length field has not arrived, so
    // the frame's size is not even knowable.
    var read_pos: usize = 6;
    try std.testing.expectEqual(Frame.none, extractFrame(&read_buf, &read_pos));

    // Header complete, payload short.
    read_pos = proto.TokenText.header_bytes + 2;
    try std.testing.expectEqual(Frame.none, extractFrame(&read_buf, &read_pos));

    read_pos = proto.TokenText.header_bytes + proto.TokenText.payloadSpan(body.len);
    switch (extractFrame(&read_buf, &read_pos)) {
        .token_text => |got| try std.testing.expectEqualStrings(body, got.slice()),
        else => return error.ExpectedTokenText,
    }
}
