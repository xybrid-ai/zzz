//! Host end of the bounded raw-exec transport: run one command on a
//! probe and hand its output to whoever asked for it.
//!
//! The socket is used exclusively for the duration of one run. Anything
//! that is not an exec frame — the 10 Hz telemetry tick, a stray engine
//! report — is skipped rather than buffered: a comparison reads the
//! child's output, and the dashboard's own reader owns the rest.
//!
//! Two deadlines, not one. The probe enforces the run's timeout on the
//! device, and the client enforces a wall-clock ceiling above it, so a
//! probe that dies mid-run fails a repetition instead of hanging the
//! coordinator forever.

const std = @import("std");
const proto = @import("proto");
const net = @import("net_compat");
const time_compat = @import("time_compat");

pub const Error = error{
    /// The probe did not advertise `exec_enabled`; it was started
    /// without `--allow-exec` and has to be restarted to be used.
    ExecUnavailable,
    ProbeGone,
    /// The probe stopped answering before the run reached a terminal
    /// event.
    ClientDeadline,
    /// A frame arrived that this client cannot place in the stream.
    Desync,
    RequestTooLarge,
};

pub const Options = struct {
    run_id: u64,
    /// Enforced on the device. The probe kills the child at this point.
    timeout_ms: u32,
    argv: []const []const u8,
    environment: []const []const u8 = &.{},
    /// Enforced here, above the probe's own timeout.
    client_deadline_ms: u32,
    metrics: bool = false,
    telemetry_available: bool = true,
};

/// Where a run's bytes go. One callback rather than two writers because
/// every caller so far wants to do two things with stdout (parse it and
/// record it) and exactly one thing with stderr.
pub const Sink = struct {
    context: *anyopaque,
    write: *const fn (context: *anyopaque, stream: proto.RawOutput.Stream, bytes: []const u8) void,

    fn deliver(self: Sink, stream: proto.RawOutput.Stream, bytes: []const u8) void {
        self.write(self.context, stream, bytes);
    }
};

/// What the device reported while one repetition ran. A comparison that
/// rotates arms on a phone is only interpretable next to this: a decode
/// number from a 41 C device and one from a 33 C device are not the same
/// measurement, and the receipt has to be able to say which was which.
///
/// Sentinels are preserved, not folded into zero: `INT32_MIN` for an
/// absent thermal zone and `maxInt(u32)` for unsampled power both mean
/// "not measured", which is a different fact from "measured as zero".
pub const Telemetry = struct {
    samples: u32 = 0,
    soc_temp_mc_min: i32 = std.math.maxInt(i32),
    soc_temp_mc_max: i32 = std.math.minInt(i32),
    skin_temp_mc_min: i32 = std.math.maxInt(i32),
    skin_temp_mc_max: i32 = std.math.minInt(i32),
    power_mw_min: u32 = std.math.maxInt(u32),
    power_mw_max: u32 = 0,
    throttled: bool = false,

    fn observe(self: *Telemetry, frame: *const proto.TelemetryFrame) void {
        self.samples += 1;
        if (frame.soc_temp_mc != std.math.minInt(i32)) {
            self.soc_temp_mc_min = @min(self.soc_temp_mc_min, frame.soc_temp_mc);
            self.soc_temp_mc_max = @max(self.soc_temp_mc_max, frame.soc_temp_mc);
        }
        if (frame.skin_temp_mc != std.math.minInt(i32)) {
            self.skin_temp_mc_min = @min(self.skin_temp_mc_min, frame.skin_temp_mc);
            self.skin_temp_mc_max = @max(self.skin_temp_mc_max, frame.skin_temp_mc);
        }
        if (frame.power_mw != std.math.maxInt(u32)) {
            self.power_mw_min = @min(self.power_mw_min, frame.power_mw);
            self.power_mw_max = @max(self.power_mw_max, frame.power_mw);
        }
        if (frame.throttling != 0) self.throttled = true;
    }

    pub fn sawSocTemp(self: Telemetry) bool {
        return self.soc_temp_mc_max >= self.soc_temp_mc_min;
    }

    pub fn sawPower(self: Telemetry) bool {
        return self.power_mw_max >= self.power_mw_min;
    }
};

pub const Outcome = struct {
    metrics: ?proto.ExecMetrics = null,
    kind: proto.ExecEvent.Kind,
    reason: proto.ExecEvent.Reason,
    exit_code: i32 = 0,
    signal: u16 = 0,
    elapsed_ns: u64 = 0,
    stdout_bytes: u64 = 0,
    stderr_bytes: u64 = 0,
    /// Sequence numbers seen out of order. Non-zero means the recorded
    /// interleaving of stdout and stderr is not what the child wrote.
    out_of_order: u32 = 0,
    /// Device conditions observed while this run was in flight.
    telemetry: Telemetry = .{},

    /// The child ran to completion on its own terms. A rejection, a
    /// timeout, a cancellation, or a non-zero exit are all "no sample".
    pub fn succeeded(self: Outcome) bool {
        return self.kind == .exited and self.reason == .none and
            self.exit_code == 0 and self.signal == 0;
    }
};

pub fn available(hello: *const proto.Hello) bool {
    return hello.proto_version >= proto.exec_min_version and
        hello.capabilities & proto.capability_exec != 0;
}

/// Run one command to its terminal event. Blocks for the whole run.
pub fn run(fd: net.fd_t, options: Options, sink: Sink) Error!Outcome {
    var request_buf: [proto.max_frame_bytes]u8 align(8) = undefined;
    const request = proto.ExecRequest.encode(&request_buf, .{
        .run_id = options.run_id,
        .timeout_ms = options.timeout_ms,
        .argv = options.argv,
        .env = options.environment,
        .metrics = options.metrics,
    }) catch return error.RequestTooLarge;
    try writeAll(fd, request);

    var outcome: Outcome = .{ .kind = .accepted, .reason = .none };
    var next_seq: u32 = 0;
    // Telemetry only counts once the probe says the child exists. The
    // socket carries a 10 Hz tick the whole time this bench has been
    // connected — through manifest resolution, model hashing, and the
    // gap between repetitions — and folding those queued frames into a
    // run would describe the device before it, not during it.
    var accepted = false;

    var read_buf: [proto.max_frame_bytes]u8 align(8) = undefined;
    var read_pos: usize = 0;
    const deadline_ns = time_compat.nanoTimestamp() +
        @as(i128, options.client_deadline_ms) * std.time.ns_per_ms;

    while (true) {
        // Drain everything already buffered before waiting for more:
        // one read can carry several 4 KiB chunks.
        while (true) {
            const span = switch (proto.frameSpan(read_buf[0..read_pos])) {
                .need_more => break,
                .desync => return error.Desync,
                .total => |total| total,
            };
            if (read_pos < span) break;
            const frame = read_buf[0..span];

            switch (std.mem.readInt(u32, frame[0..4], .little)) {
                proto.exec_metrics_magic => {
                    const metrics: *const proto.ExecMetrics = @ptrCast(@alignCast(frame.ptr));
                    if (!metrics.valid()) return error.Desync;
                    if (metrics.run_id == options.run_id and accepted) outcome.metrics = metrics.*;
                },
                proto.raw_output_magic => {
                    const chunk = proto.RawOutput.decode(frame) catch return error.Desync;
                    if (chunk.run_id == options.run_id) {
                        if (chunk.seq != next_seq) outcome.out_of_order += 1;
                        next_seq = chunk.seq +% 1;
                        switch (chunk.stream) {
                            .stdout => outcome.stdout_bytes += chunk.bytes.len,
                            .stderr => outcome.stderr_bytes += chunk.bytes.len,
                        }
                        sink.deliver(chunk.stream, chunk.bytes);
                    }
                },
                proto.exec_event_magic => {
                    const event: *const proto.ExecEvent = @ptrCast(@alignCast(frame.ptr));
                    if (event.run_id == options.run_id) {
                        switch (event.kind) {
                            // Accepted is not terminal: it is the probe
                            // saying the child exists, which is what
                            // separates "refused" from "slow".
                            .accepted => accepted = true,
                            .rejected, .exited, .cancelled => {
                                outcome.kind = event.kind;
                                outcome.reason = event.reason;
                                outcome.exit_code = event.exit_code;
                                outcome.signal = event.signal;
                                outcome.elapsed_ns = event.elapsed_ns;
                                consume(&read_buf, &read_pos, span);
                                return outcome;
                            },
                        }
                    }
                },
                // This client is the socket's only reader during a
                // headless comparison, so the tick is folded into the
                // run's conditions rather than dropped.
                proto.magic => {
                    if (accepted and options.telemetry_available and frame.len == @sizeOf(proto.TelemetryFrame)) {
                        const tick: *const proto.TelemetryFrame = @ptrCast(@alignCast(frame.ptr));
                        outcome.telemetry.observe(tick);
                    }
                },
                // Engine reports belong to the dashboard's reader.
                else => {},
            }
            consume(&read_buf, &read_pos, span);
        }

        const remaining_ns = deadline_ns - time_compat.nanoTimestamp();
        if (remaining_ns <= 0) return error.ClientDeadline;
        const remaining_ms: i32 = @intCast(@min(
            @divTrunc(remaining_ns, std.time.ns_per_ms) + 1,
            std.math.maxInt(i32),
        ));
        var pfd = [_]std.posix.pollfd{.{
            .fd = fd,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        const ready = std.posix.poll(&pfd, remaining_ms) catch return error.ProbeGone;
        if (ready == 0) return error.ClientDeadline;
        if (pfd[0].revents & sock_err_mask != 0) return error.ProbeGone;
        if (read_pos == read_buf.len) return error.Desync;
        const n = std.posix.read(fd, read_buf[read_pos..]) catch |e| switch (e) {
            error.WouldBlock => continue,
            else => return error.ProbeGone,
        };
        if (n == 0) return error.ProbeGone;
        read_pos += n;
    }
}

/// Ask the probe to end a run early. Harmless for a run that is already
/// over, which is what makes it safe to send on any abort path.
pub fn cancel(fd: net.fd_t, run_id: u64) Error!void {
    const frame = proto.ExecCancel{ .run_id = run_id };
    const bytes: *const [@sizeOf(proto.ExecCancel)]u8 = @ptrCast(&frame);
    try writeAll(fd, bytes);
}

const sock_err_mask: i16 = std.posix.POLL.ERR | std.posix.POLL.HUP | std.posix.POLL.NVAL;

fn consume(buf: []u8, pos: *usize, span: usize) void {
    const remaining = pos.* - span;
    if (remaining > 0) std.mem.copyForwards(u8, buf[0..remaining], buf[span..pos.*]);
    pos.* = remaining;
}

/// Unlike the bench's telemetry writes, an exec request can be several
/// kilobytes, so a full send buffer is a wait rather than a lost peer.
fn writeAll(fd: net.fd_t, bytes: []const u8) Error!void {
    var written: usize = 0;
    while (written < bytes.len) {
        const n = net.write(fd, bytes[written..]) catch |e| switch (e) {
            error.WouldBlock => {
                var pfd = [_]std.posix.pollfd{.{
                    .fd = fd,
                    .events = std.posix.POLL.OUT,
                    .revents = 0,
                }};
                const ready = std.posix.poll(&pfd, 5_000) catch return error.ProbeGone;
                if (ready == 0) return error.ProbeGone;
                if (pfd[0].revents & sock_err_mask != 0) return error.ProbeGone;
                continue;
            },
            else => return error.ProbeGone,
        };
        if (n == 0) return error.ProbeGone;
        written += n;
    }
}

const testing = std.testing;

/// The test plays the probe: it decodes what the client sent and writes
/// back the frames a probe would.
const FakeProbe = struct {
    fd: net.fd_t,
    client_fd: net.fd_t,
    buf: [proto.max_frame_bytes]u8 align(8) = undefined,
    pos: usize = 0,

    fn init() !FakeProbe {
        var fds: [2]std.posix.fd_t = undefined;
        const rc = std.c.socketpair(
            @intCast(std.posix.AF.UNIX),
            @intCast(std.posix.SOCK.STREAM),
            0,
            &fds,
        );
        if (rc != 0) return error.SocketPairFailed;
        return .{ .fd = fds[0], .client_fd = fds[1] };
    }

    fn deinit(self: *FakeProbe) void {
        net.close(self.fd);
        net.close(self.client_fd);
    }

    fn readRequest(self: *FakeProbe, decoded: *proto.ExecRequest.Decoded) !void {
        while (true) {
            switch (proto.frameSpan(self.buf[0..self.pos])) {
                .total => |span| if (self.pos >= span) {
                    try proto.ExecRequest.decode(self.buf[0..span], decoded);
                    return;
                },
                .desync => return error.Desync,
                .need_more => {},
            }
            const n = try std.posix.read(self.fd, self.buf[self.pos..]);
            if (n == 0) return error.ClientGone;
            self.pos += n;
        }
    }

    fn sendEvent(self: *FakeProbe, event: proto.ExecEvent) !void {
        const bytes: *const [@sizeOf(proto.ExecEvent)]u8 = @ptrCast(&event);
        try self.sendBytes(bytes);
    }

    fn sendOutput(
        self: *FakeProbe,
        run_id: u64,
        seq: u32,
        stream: proto.RawOutput.Stream,
        text: []const u8,
    ) !void {
        var frame_buf: [proto.RawOutput.header_bytes + proto.RawOutput.max_payload]u8 align(8) = undefined;
        const frame = try proto.RawOutput.encode(&frame_buf, .{
            .run_id = run_id,
            .seq = seq,
            .stream = stream,
            .bytes = text,
        });
        try self.sendBytes(frame);
    }

    const Tick = struct {
        soc_temp_mc: i32,
        power_mw: u32,
        throttling: u8 = 0,
    };

    /// The 10 Hz tick keeps arriving during a run. The client has to
    /// step over it without losing the frame boundary — and, since it is
    /// the socket's only reader, record what it said.
    fn sendTelemetry(self: *FakeProbe, tick: Tick) !void {
        var frame = proto.sentinelFrame(1);
        frame.soc_temp_mc = tick.soc_temp_mc;
        frame.power_mw = tick.power_mw;
        frame.throttling = tick.throttling;
        const bytes: *const [@sizeOf(proto.TelemetryFrame)]u8 = @ptrCast(&frame);
        try self.sendBytes(bytes);
    }

    fn sendBytes(self: *FakeProbe, bytes: []const u8) !void {
        var written: usize = 0;
        while (written < bytes.len) written += try net.write(self.fd, bytes[written..]);
    }
};

const Capture = struct {
    stdout: std.ArrayList(u8) = .empty,
    stderr: std.ArrayList(u8) = .empty,

    fn deinit(self: *Capture) void {
        self.stdout.deinit(testing.allocator);
        self.stderr.deinit(testing.allocator);
    }

    fn sink(self: *Capture) Sink {
        return .{ .context = self, .write = writeInto };
    }

    fn writeInto(context: *anyopaque, stream: proto.RawOutput.Stream, bytes: []const u8) void {
        const self: *Capture = @ptrCast(@alignCast(context));
        const target = switch (stream) {
            .stdout => &self.stdout,
            .stderr => &self.stderr,
        };
        target.appendSlice(testing.allocator, bytes) catch @panic("capture");
    }
};

test "a run's output reaches the sink and its exit reaches the caller" {
    var probe = try FakeProbe.init();
    defer probe.deinit();
    var capture: Capture = .{};
    defer capture.deinit();

    const thread = try std.Thread.spawn(.{}, struct {
        fn serve(fake: *FakeProbe) void {
            var request: proto.ExecRequest.Decoded = undefined;
            fake.readRequest(&request) catch return;
            // A tick from before the child existed: the probe has been
            // sending these since the bench connected.
            fake.sendTelemetry(.{ .soc_temp_mc = 30_000, .power_mw = 1_000 }) catch return;
            fake.sendEvent(.{ .kind = .accepted, .run_id = request.run_id }) catch return;
            fake.sendOutput(request.run_id, 0, .stdout, "[{\"avg_ts\":1}") catch return;
            fake.sendTelemetry(.{ .soc_temp_mc = 41_800, .power_mw = 3_100 }) catch return;
            fake.sendTelemetry(.{ .soc_temp_mc = 42_200, .power_mw = 3_050, .throttling = 1 }) catch return;
            fake.sendOutput(request.run_id, 1, .stderr, "loading model\n") catch return;
            fake.sendOutput(request.run_id, 2, .stdout, "]") catch return;
            fake.sendEvent(.{
                .kind = .exited,
                .run_id = request.run_id,
                .exit_code = 0,
                .elapsed_ns = 5_000,
            }) catch return;
        }
    }.serve, .{&probe});
    defer thread.join();

    const outcome = try run(probe.client_fd, .{
        .run_id = 7,
        .timeout_ms = 10_000,
        .argv = &.{ "/data/local/tmp/llama-bench", "-o", "json" },
        .client_deadline_ms = 5_000,
    }, capture.sink());

    try testing.expect(outcome.succeeded());
    try testing.expect(outcome.metrics == null);
    try testing.expectEqual(@as(u32, 0), outcome.out_of_order);
    try testing.expectEqual(@as(u64, 14), outcome.stdout_bytes);
    // Telemetry interleaved mid-run must not land in either stream.
    try testing.expectEqualStrings("[{\"avg_ts\":1}]", capture.stdout.items);
    try testing.expectEqualStrings("loading model\n", capture.stderr.items);

    // ...and must be kept: a decode number from a 42 C device is not the
    // same measurement as one from a 33 C device, and the receipt has to
    // be able to say which this was.
    // Two ticks, not three: the one that arrived before `accepted`
    // describes the device before this child existed.
    try testing.expectEqual(@as(u32, 2), outcome.telemetry.samples);
    try testing.expect(outcome.telemetry.sawSocTemp());
    try testing.expectEqual(@as(i32, 41_800), outcome.telemetry.soc_temp_mc_min);
    try testing.expectEqual(@as(i32, 42_200), outcome.telemetry.soc_temp_mc_max);
    try testing.expectEqual(@as(u32, 3_050), outcome.telemetry.power_mw_min);
    try testing.expect(outcome.telemetry.throttled);
}

test "a refused run is reported, not retried or mistaken for a result" {
    var probe = try FakeProbe.init();
    defer probe.deinit();
    var capture: Capture = .{};
    defer capture.deinit();

    const thread = try std.Thread.spawn(.{}, struct {
        fn serve(fake: *FakeProbe) void {
            var request: proto.ExecRequest.Decoded = undefined;
            fake.readRequest(&request) catch return;
            fake.sendEvent(.{
                .kind = .rejected,
                .reason = .disabled,
                .run_id = request.run_id,
            }) catch return;
        }
    }.serve, .{&probe});
    defer thread.join();

    const outcome = try run(probe.client_fd, .{
        .run_id = 9,
        .timeout_ms = 1_000,
        .argv = &.{"/bin/true"},
        .client_deadline_ms = 5_000,
    }, capture.sink());

    try testing.expect(!outcome.succeeded());
    try testing.expectEqual(proto.ExecEvent.Kind.rejected, outcome.kind);
    try testing.expectEqual(proto.ExecEvent.Reason.disabled, outcome.reason);
}

test "requested metrics reassemble before exit and never enter process output" {
    var probe = try FakeProbe.init();
    defer probe.deinit();
    var capture: Capture = .{};
    defer capture.deinit();
    const thread = try std.Thread.spawn(.{}, struct {
        fn serve(fake: *FakeProbe) void {
            var request: proto.ExecRequest.Decoded = undefined;
            fake.readRequest(&request) catch return;
            if (!request.metrics) return;
            fake.sendEvent(.{ .kind = .accepted, .run_id = request.run_id }) catch return;
            var metrics: proto.ExecMetrics = .{ .run_id = request.run_id, .flags = proto.ExecMetrics.flag_usage, .minor_faults = 42 };
            const bytes = std.mem.asBytes(&metrics);
            fake.sendBytes(bytes[0..17]) catch return;
            fake.sendBytes(bytes[17..]) catch return;
            fake.sendEvent(.{ .kind = .exited, .run_id = request.run_id }) catch return;
        }
    }.serve, .{&probe});
    defer thread.join();
    const outcome = try run(probe.client_fd, .{
        .run_id = 41,
        .timeout_ms = 1000,
        .argv = &.{"/bin/true"},
        .client_deadline_ms = 2000,
        .metrics = true,
    }, capture.sink());
    try testing.expect(outcome.succeeded());
    try testing.expectEqual(@as(u64, 42), outcome.metrics.?.minor_faults);
    try testing.expectEqual(@as(usize, 0), capture.stdout.items.len);
}

test "a probe that stops answering fails the run instead of hanging" {
    var probe = try FakeProbe.init();
    defer probe.deinit();
    var capture: Capture = .{};
    defer capture.deinit();

    const thread = try std.Thread.spawn(.{}, struct {
        fn serve(fake: *FakeProbe) void {
            var request: proto.ExecRequest.Decoded = undefined;
            fake.readRequest(&request) catch return;
            // Accepted, then silence: the device's own timeout would
            // normally end this, so the client's ceiling is what covers
            // a probe that died holding the socket open.
            fake.sendEvent(.{ .kind = .accepted, .run_id = request.run_id }) catch return;
            std.Io.sleep(testing.io, .fromMilliseconds(400), .awake) catch {};
        }
    }.serve, .{&probe});
    defer thread.join();

    try testing.expectError(error.ClientDeadline, run(probe.client_fd, .{
        .run_id = 11,
        .timeout_ms = 60_000,
        .argv = &.{"/bin/sleep"},
        .client_deadline_ms = 150,
    }, capture.sink()));
}

test "exec is gated on the probe advertising it" {
    var hello = proto.Hello{};
    try testing.expect(!available(&hello));
    hello.capabilities = proto.capability_exec;
    try testing.expect(available(&hello));
    // The protocol level is required in addition to the capability bit.
    hello.proto_version = proto.exec_min_version - 1;
    try testing.expect(!available(&hello));
}

test "a probe with no readable sensors reports absent, not zero" {
    var probe = try FakeProbe.init();
    defer probe.deinit();
    var capture: Capture = .{};
    defer capture.deinit();

    const thread = try std.Thread.spawn(.{}, struct {
        fn serve(fake: *FakeProbe) void {
            var request: proto.ExecRequest.Decoded = undefined;
            fake.readRequest(&request) catch return;
            fake.sendEvent(.{ .kind = .accepted, .run_id = request.run_id }) catch return;
            // `sentinelFrame` is what a probe emits when sysfs gives it
            // nothing: INT32_MIN thermal zones, unsampled power.
            const frame = proto.sentinelFrame(1);
            const bytes: *const [@sizeOf(proto.TelemetryFrame)]u8 = @ptrCast(&frame);
            fake.sendBytes(bytes) catch return;
            fake.sendEvent(.{ .kind = .exited, .run_id = request.run_id }) catch return;
        }
    }.serve, .{&probe});
    defer thread.join();

    const outcome = try run(probe.client_fd, .{
        .run_id = 13,
        .timeout_ms = 1_000,
        .argv = &.{"/bin/true"},
        .client_deadline_ms = 5_000,
    }, capture.sink());

    try testing.expectEqual(@as(u32, 1), outcome.telemetry.samples);
    // Sampled nothing is not "measured zero" — a receipt that folded
    // these together would read as a stone-cold device.
    try testing.expect(!outcome.telemetry.sawSocTemp());
    try testing.expect(!outcome.telemetry.sawPower());
}
