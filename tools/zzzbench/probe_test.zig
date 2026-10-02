//! `--probe-test`: a wire diagnostic that bypasses the TUI entirely.
//!
//! Connects to the primary endpoint and each peer, reads Hello, reads
//! N telemetry frames within a deadline, prints structured PASS/FAIL,
//! and returns an exit code. Replaces the manual `nc 127.0.0.1 PORT |
//! xxd` + `cat /proc/net/tcp` dance when setup friction shows up (adb
//! forward stuck, wrong port, dead probe).

const std = @import("std");
const proto = @import("proto");
const net = @import("net_compat");
const time_compat = @import("time_compat");
const tui = @import("tuiz");

const Peer = @import("peer.zig").Peer;
const tty = @import("tty.zig");
const wire = @import("wire.zig");

const target_frames: usize = 10;
const telemetry_deadline_ns: i128 = @as(i128, std.time.ns_per_s) * 2;

/// Returns 0 if every probe passed both Hello and telemetry, 1
/// otherwise. The caller handles `std.process.exit`.
pub fn run(primary_endpoint: []const u8, peers: []const Peer) !u8 {
    try tty.diagLine("zzzbench probe-test\n===================\n\n", .{});

    var passed: usize = 0;
    var total: usize = 1;
    if (try testOne("primary", primary_endpoint)) passed += 1;

    for (peers) |*p| {
        total += 1;
        var safe_buf: [48]u8 = undefined;
        var label_buf: [64]u8 = undefined;
        const label = std.fmt.bufPrint(&label_buf, "peer {s}", .{
            tui.sanitize.into(&safe_buf, p.label),
        }) catch "peer";
        if (try testOne(label, p.endpoint)) passed += 1;
    }

    try tty.diagLine("overall: {d}/{d} pass\n", .{ passed, total });
    return if (passed == total) 0 else 1;
}

/// Test one probe: connect → Hello → N telemetry frames.
fn testOne(label: []const u8, endpoint: []const u8) !bool {
    // The endpoint can carry a CoreDevice hostname the device chose,
    // and every Hello field below is probe-supplied. stderr is a
    // terminal too, so all of it is filtered (tui/sanitize.zig).
    var endpoint_buf: [128]u8 = undefined;
    try tty.diagLine("{s} {s}\n", .{ label, tui.sanitize.into(&endpoint_buf, endpoint) });

    const t0 = time_compat.nanoTimestamp();
    var hello_buf: [@sizeOf(proto.Hello)]u8 align(@alignOf(proto.Hello)) = undefined;
    const fd = wire.connectAndReadHello(endpoint, &hello_buf) catch |e| {
        try tty.diagLine("  hello      FAIL ({s})\n  status     FAIL\n\n", .{@errorName(e)});
        return false;
    };
    defer net.close(fd);
    const hello_ms = @divTrunc(time_compat.nanoTimestamp() - t0, std.time.ns_per_ms);

    const hello: *const proto.Hello = @ptrCast(@alignCast(&hello_buf));
    var dev_buf: [64]u8 = undefined;
    var soc_buf: [64]u8 = undefined;
    var src_buf: [64]u8 = undefined;
    try tty.diagLine("  hello      OK   {d} ms — {s} / {s} / {s} / has_engine={d}\n", .{
        hello_ms,
        tui.sanitize.into(&dev_buf, proto.Hello.nameSlice(&hello.device_name)),
        tui.sanitize.into(&soc_buf, proto.Hello.nameSlice(&hello.soc_name)),
        tui.sanitize.into(&src_buf, proto.Hello.sourceSlice(&hello.source)),
        hello.has_engine,
    });
    // The device list cannot show this — it is built from `adb
    // devices` before any probe exists — so the wire diagnostic is
    // where you check what thread count the bench will default to.
    if (hello.total_cores > 0) {
        try tty.diagLine("  cores      OK   {d} total, {d} perf — default threads={d}\n", .{
            hello.total_cores,
            hello.perf_cores,
            hello.perf_cores,
        });
    } else {
        try tty.diagLine("  cores      INFO probe reports no core counts — threads stays at the bench default\n", .{});
    }

    wire.requestHardwareInfo(fd) catch {};

    const t_telem = time_compat.nanoTimestamp();
    const result = drainTelemetry(fd, target_frames, t_telem + telemetry_deadline_ns);
    const elapsed_ms = @divTrunc(time_compat.nanoTimestamp() - t_telem, std.time.ns_per_ms);

    if (result.have_hardware_info) {
        try printHardwareInfo(&result.hardware_info);
    } else {
        try tty.diagLine("  hardware   INFO no hardware-info frame\n", .{});
    }

    switch (result.status) {
        .desync => {
            try tty.diagLine("  telemetry  FAIL desync (bad magic)\n  status     FAIL\n\n", .{});
            return false;
        },
        .timeout => {
            try tty.diagLine("  telemetry  FAIL {d}/{d} frames in {d} ms\n  status     FAIL\n\n", .{ result.frames, target_frames, elapsed_ms });
            return false;
        },
        .ok => {
            try tty.diagLine("  telemetry  OK   {d} frames in {d} ms\n  status     PASS\n\n", .{ result.frames, elapsed_ms });
            return true;
        },
    }
}

const DrainStatus = enum { ok, timeout, desync };

const DrainResult = struct {
    status: DrainStatus,
    frames: usize,
    hardware_info: proto.HardwareInfo = .{},
    have_hardware_info: bool = false,
};

/// Read up to `target` TelemetryFrames from `fd` before `deadline_ns`.
/// HardwareInfo and EngineReport frames in the same stream are
/// tolerated and ignored — this test cares about telemetry liveness.
/// HardwareInfo is captured when present; its absence is allowed.
fn drainTelemetry(fd: std.posix.fd_t, target: usize, deadline_ns: i128) DrainResult {
    var read_buf: [proto.max_frame_bytes]u8 align(@alignOf(proto.TelemetryFrame)) = undefined;
    var read_pos: usize = 0;
    var frames: usize = 0;
    var hardware_info: proto.HardwareInfo = .{};
    var have_hardware_info = false;

    drain: while (frames < target) {
        const remaining_ns = deadline_ns - time_compat.nanoTimestamp();
        if (remaining_ns <= 0) break;
        const remaining_ms: i32 = @intCast(@min(@divTrunc(remaining_ns, std.time.ns_per_ms), std.math.maxInt(i32)));
        var pfd = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 }};
        const ready = std.posix.poll(&pfd, remaining_ms) catch break;
        if (ready == 0) break;
        const n = std.posix.read(fd, read_buf[read_pos..]) catch |e| switch (e) {
            error.WouldBlock => continue,
            else => break,
        };
        if (n == 0) break;
        read_pos += n;

        while (true) {
            switch (wire.extractFrame(&read_buf, &read_pos)) {
                .none => continue :drain,
                .desync => return .{
                    .status = .desync,
                    .frames = frames,
                    .hardware_info = hardware_info,
                    .have_hardware_info = have_hardware_info,
                },
                .telemetry => frames += 1,
                .hello => {},
                .hardware_info => |hw| {
                    hardware_info = hw;
                    have_hardware_info = true;
                },
                .engine_report, .token_text => {},
            }
            if (frames >= target) break :drain;
        }
    }
    return .{
        .status = if (frames >= target) .ok else .timeout,
        .frames = frames,
        .hardware_info = hardware_info,
        .have_hardware_info = have_hardware_info,
    };
}

/// Filtered field, or an em dash when the probe didn't report one.
fn orDash(buf: []u8, s: []const u8) []const u8 {
    return if (s.len > 0) tui.sanitize.into(buf, s) else "—";
}

fn printHardwareInfo(hw: *const proto.HardwareInfo) !void {
    var machine_buf: [64]u8 = undefined;
    var soc_buf: [64]u8 = undefined;
    var gpu_buf: [64]u8 = undefined;
    var npu_buf: [64]u8 = undefined;
    const npu = proto.HardwareInfo.nameSlice(&hw.npu_name);
    const npu_label: []const u8 = if (npu.len > 0)
        tui.sanitize.into(&npu_buf, npu)
    else
        "public API unavailable";
    const source: []const u8 = if ((hw.flags & proto.hardware_info_flag_soc_inferred) != 0) "inferred" else "identifier";

    try tty.diagLine("  hardware   OK   chip {s} / hw {s} ({s})\n", .{
        orDash(&soc_buf, proto.HardwareInfo.nameSlice(&hw.soc_name)),
        orDash(&machine_buf, proto.HardwareInfo.machineSlice(&hw.machine)),
        source,
    });
    try tty.diagLine("             GPU  {s}\n", .{orDash(&gpu_buf, proto.HardwareInfo.nameSlice(&hw.gpu_name))});
    try tty.diagLine("             NPU  {s}\n", .{npu_label});
}
