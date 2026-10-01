//! An additional probe alongside the primary, registered via
//! `--probe LABEL:ENDPOINT` (or filled in by auto-discovery).
//!
//! Each peer owns its connection, its own reconnect clock, its
//! last-frame buffer, and a small history — enough for one live
//! comparison row. A single bench window watching "Pixel 8 vs Mac M3
//! vs Pi 5" is three of these.

const std = @import("std");
const proto = @import("proto");
const net = @import("net_compat");
const time_compat = @import("time_compat");

const engine = @import("engine.zig");
const wire = @import("wire.zig");
const Series = @import("series.zig").Series;
const Output = @import("output.zig").Output;

/// Normaliser floors for the one-row peer sparklines. Prime% is a
/// percentage of a single core, so an idle peer renders small rather
/// than filling the row; the tok/s floor keeps a slow engine from
/// looking pegged.
const prime_floor: f32 = 50;
const tok_floor: f32 = 20;

pub const Peer = struct {
    /// User-supplied label (the LABEL part of `LABEL:ENDPOINT`).
    /// Falls back to the device_name from Hello if empty.
    label: []const u8,
    endpoint: []const u8,
    sock_opt: ?std.posix.fd_t = null,
    hello_buf: [@sizeOf(proto.Hello)]u8 align(@alignOf(proto.Hello)) = undefined,
    have_hello: bool = false,
    /// Sized for the largest frame the probe can interleave on the
    /// wire. Magic-dispatch picks the size once the first 4 bytes land
    /// — and for TokenText, once its header has.
    read_buf: [proto.max_frame_bytes]u8 align(@alignOf(proto.TelemetryFrame)) = undefined,
    read_pos: usize = 0,
    current: proto.TelemetryFrame = std.mem.zeroes(proto.TelemetryFrame),
    have_frame: bool = false,
    hardware_info: proto.HardwareInfo = .{},
    have_hardware_info: bool = false,
    /// Per-connection retry state. The primary probe keeps its own
    /// pair in the event loop; peers carry theirs inline so the loop
    /// services them uniformly.
    next_retry_at_ns: i128 = 0,
    backoff_ms: i64 = wire.reconnect_min_ms,
    prime_series: Series = .{ .floor = prime_floor },
    /// Engine tok/s history, populated when the probe was started with
    /// `--engine` + `--model` and is forwarding EngineReport frames.
    /// When `have_engine_report` is true the peer row shows this
    /// instead of prime%.
    tok_series: Series = .{ .floor = tok_floor },
    last_tok_s: f32 = 0,
    engine_progress: engine.Progress = .{},
    have_engine_report: bool = false,
    /// Text this device generated, when its probe was asked for it.
    /// Empty when the probe does not send TokenText or the bench
    /// never subscribes to it.
    output: Output = .{},

    pub fn helloPtr(self: *const Peer) *const proto.Hello {
        return @ptrCast(@alignCast(&self.hello_buf));
    }

    /// This peer's probe can spawn an engine on `r`.
    pub fn canRunEngine(self: *const Peer) bool {
        return self.have_hello and self.helloPtr().has_engine == 1;
    }

    /// Clear per-run state ahead of a new benchmark, so the visual
    /// fresh start lines up with the first inbound report.
    pub fn resetRun(self: *Peer) void {
        self.tok_series = .{ .floor = tok_floor };
        self.last_tok_s = 0;
        self.engine_progress.reset();
        self.have_engine_report = false;
        self.output.reset();
    }

    /// Fold one wire frame into this peer's state. Returns true when
    /// something render-visible changed.
    pub fn applyFrame(self: *Peer, frame: wire.Frame) bool {
        switch (frame) {
            .none, .desync => return false,
            .hello => |hello| {
                const bytes: *const [@sizeOf(proto.Hello)]u8 = @ptrCast(&hello);
                @memcpy(&self.hello_buf, bytes);
                self.have_hello = true;
            },
            .telemetry => |t| {
                self.current = t;
                self.have_frame = true;
                self.prime_series.push(t.cpu_util_pct[0]);
            },
            .hardware_info => |hw| {
                self.hardware_info = hw;
                self.have_hardware_info = true;
            },
            .engine_report => |rep| {
                // Each peer's probe forwards EngineReport frames over
                // its own socket, so each peer drives its own tok/s
                // history independently — the unlock that makes
                // multi-device compare worth looking at.
                //
                // Except from a run the operator abandoned: that is
                // not the run on screen — see `Progress.take`.
                if (self.engine_progress.take(rep)) {
                    if (engine.validTokS(rep.decode_tok_s) or rep.phase == engine.phase_done) {
                        self.last_tok_s = rep.decode_tok_s;
                    }
                    if (engine.validTokS(rep.decode_tok_s)) self.tok_series.push(rep.decode_tok_s);
                    self.have_engine_report = true;
                }
            },
            .token_text => |chunk| {
                if (self.engine_progress.abandoned) return false;
                return self.output.push(chunk);
            },
        }
        return true;
    }

    pub fn scheduleReconnect(self: *Peer) void {
        if (self.sock_opt) |s| net.close(s);
        self.sock_opt = null;
        self.read_pos = 0;
        self.hardware_info = .{};
        self.have_hardware_info = false;
        // Engine reports from the previous connection are stale on
        // reconnect — the new probe may not even be running an engine.
        // Drop the history + tok/s number so the row reflects "no live
        // data" instead of the last value from a dead session.
        self.resetRun();
        self.engine_progress.connectionLost();
        self.next_retry_at_ns = time_compat.nanoTimestamp() +
            @as(i128, self.backoff_ms) * std.time.ns_per_ms;
        self.backoff_ms = @min(self.backoff_ms * 2, wire.reconnect_max_ms);
    }

    pub fn tryReconnect(self: *Peer) void {
        const now = time_compat.nanoTimestamp();
        if (now < self.next_retry_at_ns) return;
        if (wire.connectAndReadHello(self.endpoint, &self.hello_buf)) |fd| {
            wire.requestHardwareInfo(fd) catch {};
            self.sock_opt = fd;
            self.have_hello = true;
            self.backoff_ms = wire.reconnect_min_ms;
            self.read_pos = 0;
            self.hardware_info = .{};
            self.have_hardware_info = false;
        } else |_| {
            self.next_retry_at_ns = now + @as(i128, self.backoff_ms) * std.time.ns_per_ms;
            self.backoff_ms = @min(self.backoff_ms * 2, wire.reconnect_max_ms);
        }
    }

    pub fn deinit(self: *Peer) void {
        if (self.sock_opt) |s| net.close(s);
        self.sock_opt = null;
    }
};

/// `LABEL:ENDPOINT` parser for `--probe`. The label is mandatory and
/// non-empty (otherwise the row title in multi-device mode would be
/// blank); the endpoint is anything `wire.connectEndpoint` accepts —
/// `tcp:PORT`, `/abs/path`, or `@abstract-name`. Endpoints can
/// themselves contain colons (`tcp:7779`), so this splits on the FIRST
/// colon only and treats the remainder as the endpoint.
pub fn parseSpec(spec: []const u8) ?struct { label: []const u8, endpoint: []const u8 } {
    const colon = std.mem.indexOfScalar(u8, spec, ':') orelse return null;
    const label = spec[0..colon];
    const endpoint = spec[colon + 1 ..];
    if (label.len == 0 or endpoint.len == 0) return null;
    return .{ .label = label, .endpoint = endpoint };
}

test "parseSpec splits on the first colon so tcp endpoints survive" {
    const got = parseSpec("pixel:tcp:7779").?;
    try std.testing.expectEqualStrings("pixel", got.label);
    try std.testing.expectEqualStrings("tcp:7779", got.endpoint);
}

test "parseSpec rejects an empty label or endpoint" {
    try std.testing.expect(parseSpec(":tcp:7779") == null);
    try std.testing.expect(parseSpec("pixel:") == null);
    try std.testing.expect(parseSpec("pixel") == null);
}

test "applyFrame marks a peer live and feeds its prime history" {
    var p = Peer{ .label = "pixel", .endpoint = "tcp:7779" };
    var telemetry = proto.sentinelFrame(1);
    telemetry.cpu_util_pct[0] = 42;
    try std.testing.expect(p.applyFrame(.{ .telemetry = telemetry }));
    try std.testing.expect(p.have_frame);
    try std.testing.expectEqual(@as(usize, 1), p.prime_series.count);
    try std.testing.expect(!p.applyFrame(.none));
}
