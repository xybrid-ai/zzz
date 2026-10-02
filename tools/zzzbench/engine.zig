//! What the bench knows about an inference engine: the headline
//! numbers it reports, and (for the host-local dev loop) how to spawn
//! one.

const std = @import("std");
const contract = @import("engine_contract");
const proto = @import("proto");

pub const Engine = struct {
    name: []const u8,
    tok_s: f32,
    /// Model label rendered in the title bar. Optional — empty means
    /// "no engine attached, just device telemetry".
    model: []const u8 = "",
    progress: Progress = .{},
};

/// `EngineReport.phase` values, named so the wire's magic numbers do
/// not have to be re-derived at every comparison.
pub const phase_prefill: u8 = 0;
pub const phase_decode: u8 = 1;
pub const phase_done: u8 = 2;

/// What the dashboard is looking at. These were two states — running
/// and not — until the header began reporting them differently. A
/// finished run is a result worth reading; an empty session and a
/// crashed one are not, and they are not each other either.
pub const State = enum { never_ran, running, complete, failed };

pub const Progress = struct {
    have_report: bool = false,
    /// A successful run request is live before the first report arrives.
    /// Model loading can take seconds on a phone; that is not an idle run.
    requested: bool = false,
    /// 255 until the first report; no phase the engine can send.
    phase: u8 = 255,
    token_index: u32 = 0,
    tokens_total: u32 = 0,
    decode_tok_s: f32 = 0,
    prefill_tok_s: f32 = 0,
    /// Nanoseconds of decode elapsed: running total during the run,
    /// and the run's total wall time on the final report. This is the
    /// denominator behind `decode_tok_s`, so the two together are
    /// self-checking — tokens ÷ seconds must give the headline rate.
    elapsed_ns: u64 = 0,
    /// Set when the bench watched its own engine die without a final
    /// report, or lost the connection a probe-side run was reporting
    /// over. The probe-side crash needs no flag — see `state`.
    failed: bool = false,
    /// The operator gave up on this run, but the device may not have: a
    /// probe-spawned engine cannot be stopped from here, and a busy
    /// probe ignores the next request. Until that run's terminal report
    /// arrives, everything the device sends still belongs to it — so it
    /// is dropped rather than drawn as the run asked for since, under a
    /// model and a policy it never ran. Outlives `reset` for that reason.
    abandoned: bool = false,

    pub fn markStarted(self: *Progress, tokens_total: u32) void {
        // A probe ignores another request while busy. Preserve its current
        // progress in that case instead of making it appear to restart.
        if (self.isRunning()) return;
        self.* = .{ .requested = true, .tokens_total = tokens_total };
    }

    pub fn activityLabel(self: Progress) []const u8 {
        if (!self.have_report) return "starting";
        return if (self.phase == phase_prefill) "prefill" else "decoding";
    }

    /// The run ended without producing a result: the host-local engine
    /// exited unclean, never started at all, or its probe went away.
    pub fn markFailed(self: *Progress) void {
        self.failed = true;
    }

    /// Written off by the operator while the device may still be at it.
    pub fn markAbandoned(self: *Progress) void {
        self.failed = true;
        self.abandoned = true;
    }

    /// The connection an abandoned run reported over is gone, and its
    /// terminal report with it. Holding the quarantine for a report that
    /// can no longer arrive would bench the device for the session.
    pub fn connectionLost(self: *Progress) void {
        self.abandoned = false;
    }

    /// A fresh run's state, keeping only the quarantine: that is a fact
    /// about the device, not about the result being cleared.
    pub fn reset(self: *Progress) void {
        const quarantined = self.abandoned;
        self.* = .{ .abandoned = quarantined };
    }

    /// `update`, unless the report belongs to an abandoned run. False
    /// when it was dropped. The terminal report is dropped too, but it
    /// is the device saying it is free, so it ends the quarantine.
    pub fn take(self: *Progress, rep: proto.EngineReport) bool {
        if (self.abandoned) {
            if (rep.phase == phase_done) self.abandoned = false;
            return false;
        }
        self.update(rep);
        return true;
    }

    /// A report is proof of life, so it outranks `failed`. A probe whose
    /// socket dropped mid-run is marked failed because nothing more may
    /// ever arrive; when it reconnects and the run turns out to have
    /// survived, the reports that follow are the run, and leaving the
    /// flag set would caption a finished benchmark `NO RESULT` with its
    /// rate sitting right beside it. A dead host-local engine cannot get
    /// here: its pipe is closed before the flag is set. Callers holding a
    /// live stream go through `take`, which knows about abandoned runs.
    pub fn update(self: *Progress, rep: proto.EngineReport) void {
        self.failed = false;
        self.have_report = true;
        self.phase = rep.phase;
        self.token_index = rep.token_index;
        self.tokens_total = rep.tokens_total;
        self.decode_tok_s = rep.decode_tok_s;
        self.prefill_tok_s = rep.prefill_tok_s;
        self.elapsed_ns = rep.ts_ns;
    }

    /// A final report is only a *result* if it carries a rate.
    ///
    /// When a probe's engine exits without sending phase 2 — a crash,
    /// a kill, a missing model — the probe synthesizes one so the
    /// bench's terminator fires, and that report is all zeroes. Taking
    /// phase alone would render it as a completed benchmark whose
    /// answer was 0.00 tok/s. A real engine's final report never has a
    /// non-positive rate: it divides tokens by elapsed with the token
    /// count floored at one.
    pub fn state(self: Progress) State {
        if (self.failed or self.abandoned) return .failed;
        if (!self.have_report) return if (self.requested) .running else .never_ran;
        if (self.phase <= phase_decode) return .running;
        // Zero tokens is not a result whatever rate came with it. An
        // engine that decoded nothing and reported a rate anyway is
        // reporting a division, not a measurement — that is exactly how
        // a 9999 tok/s headline reached the dashboard.
        if (self.producedTokens() == 0) return .failed;
        return if (validTokS(self.decode_tok_s)) .complete else .failed;
    }

    /// Includes loading before the first report, then prefill and decode.
    pub fn isRunning(self: Progress) bool {
        return self.state() == .running;
    }

    /// Seconds of decode behind the headline figure.
    pub fn elapsedSeconds(self: Progress) f64 {
        return @as(f64, @floatFromInt(self.elapsed_ns)) / std.time.ns_per_s;
    }

    /// The run's target token count, for a progress bar's denominator.
    pub fn tokenCount(self: Progress) u32 {
        return if (self.tokens_total > 0) self.tokens_total else self.token_index;
    }

    /// Tokens actually produced. Distinct from `tokenCount`, which is
    /// the target: mid-run they differ by everything still to come,
    /// and even at the end they differ if the engine stopped on EOS.
    /// This is the numerator behind `decode_tok_s`, so it is the one
    /// to show beside the elapsed time.
    pub fn producedTokens(self: Progress) u32 {
        return self.token_index;
    }
};

/// A rate worth rendering as a number. Engines report NaN before the
/// first timing window closes, and 0 in phases where the field has no
/// meaning yet.
pub fn validTokS(v: f32) bool {
    return !std.math.isNan(v) and v > 0;
}

/// `NAME:TOK_S`, the `--engine` / `--compare` spec.
pub fn parseSpec(spec: []const u8) ?Engine {
    const colon = std.mem.indexOfScalar(u8, spec, ':') orelse return null;
    const tok_s = std.fmt.parseFloat(f32, spec[colon + 1 ..]) catch return null;
    return .{ .name = spec[0..colon], .tok_s = tok_s };
}

/// Wraps a spawned engine subprocess (e.g. zzz). Used for
/// the bench-local mac-host case only — the dev loop where bench,
/// synthetic probe, and engine all run on the same host. On-device
/// engine spawn is the probe's job; see the `r` keypress handler for
/// the broadcast path.
pub const Runner = struct {
    allocator: std.mem.Allocator,
    /// Io used to spawn/kill the engine child (0.16 routes process
    /// control through the Io interface).
    io: std.Io,
    child: ?std.process.Child = null,
    stdout_fd: ?std.posix.fd_t = null,
    stderr_fd: ?std.posix.fd_t = null,
    /// Bytes accumulate over a single run; cleared on each start().
    stderr_buf: [1024]u8 = @splat(0),
    stderr_len: usize = 0,

    pub fn isRunning(self: *Runner) bool {
        return self.child != null;
    }

    /// `prompt` non-empty asks the engine for real text: it encodes the
    /// prompt instead of its synthetic token sequence, and streams the
    /// decoded output back as TokenText frames. Empty leaves the engine
    /// on its default path, where the capture is a pure timing run and
    /// nothing on stdout but reports.
    pub const RunOptions = struct {
        prompt: []const u8 = "",
        threads: u32 = 4,
        n_prompt: u32 = 16,
        n_generate: u32 = 32,
        /// Empty leaves the engine on its own dispatcher choice.
        kernel: []const u8 = "",
    };

    pub fn start(self: *Runner, bin: []const u8, model: []const u8, options: RunOptions) !void {
        if (self.child != null) self.stop();
        try contract.check(self.allocator, self.io, bin);
        var command: contract.Command = undefined;
        try command.init(bin, model, .{
            .threads = options.threads,
            .n_prompt = options.n_prompt,
            .n_generate = options.n_generate,
            .prompt = options.prompt,
            .kernel = options.kernel,
            .want_text = options.prompt.len > 0,
        });
        const argv = command.argv();
        // Pipe (not inherit) — the bench's alt-screen would otherwise
        // mix engine stderr into the rendered TUI; we drain it and
        // surface the first line on exit instead.
        const c = try std.process.spawn(self.io, .{
            .argv = argv,
            .stdout = .pipe,
            .stderr = .pipe,
        });

        self.child = c;
        self.stdout_fd = if (c.stdout) |f| f.handle else null;
        self.stderr_fd = if (c.stderr) |f| f.handle else null;
        self.stderr_len = 0;
    }

    /// Read whatever is waiting on the engine's stderr into the
    /// capture buffer, and nothing more.
    ///
    /// The poll is what makes that true, and it is not optional. This
    /// used to document a precondition — "only call when poll() has
    /// signalled POLL.IN" — that `stop()` then ignored, draining
    /// unconditionally on its way to killing the child. An engine
    /// that had written nothing to stderr yet left the read blocking
    /// on a pipe whose only writer was the process being stopped, so
    /// pressing `r` to end a host-local run froze the whole TUI:
    /// no redraws, no keys, not even `q`. Enforcing the condition
    /// here rather than asking every caller to remember it.
    pub fn drainStderr(self: *Runner) void {
        const fd = self.stderr_fd orelse return;
        if (self.stderr_len >= self.stderr_buf.len) return;
        var pfd = [_]std.posix.pollfd{.{
            .fd = fd,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        const ready = std.posix.poll(&pfd, 0) catch return;
        if (ready == 0 or pfd[0].revents & std.posix.POLL.IN == 0) return;
        const n = std.posix.read(fd, self.stderr_buf[self.stderr_len..]) catch return;
        self.stderr_len = @min(self.stderr_buf.len, self.stderr_len + n);
    }

    /// Everything captured from the engine's stderr so far. Under
    /// `--report-binary` the engine's whole human banner lands here,
    /// which is what makes its build mode readable.
    pub fn stderrText(self: *const Runner) []const u8 {
        return self.stderr_buf[0..self.stderr_len];
    }

    /// The engine's own `Build mode:` banner line, or null before the
    /// banner has arrived. An engine built without ReleaseFast
    /// produces timings that are not comparable to anything, and
    /// nothing else in the session can tell. Every engine is supplied,
    /// and `zzz` itself defaults to Debug.
    pub fn buildMode(self: *const Runner) ?[]const u8 {
        const marker = "Build mode:";
        const text = self.stderrText();
        const at = std.mem.indexOf(u8, text, marker) orelse return null;
        const rest = text[at + marker.len ..];
        const end = std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len;
        const mode = std.mem.trim(u8, rest[0..end], " \t\r");
        return if (mode.len > 0) mode else null;
    }

    /// First non-empty trimmed line of captured stderr, for building a
    /// useful "engine exited: <reason>" flash. Empty when nothing was
    /// captured.
    pub fn firstStderrLine(self: *const Runner) []const u8 {
        const text = self.stderr_buf[0..self.stderr_len];
        var lines = std.mem.tokenizeScalar(u8, text, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len > 0) return trimmed;
        }
        return "";
    }

    pub fn stop(self: *Runner) void {
        if (self.child) |*c| {
            // One final stderr drain in case the child wrote and
            // exited between poll iterations.
            self.drainStderr();
            c.kill(self.io);
            self.child = null;
            self.stdout_fd = null;
            self.stderr_fd = null;
        }
    }
};

/// Shown when no engine was found. Relaunching cannot fix that: the tools
/// never build an engine, so the recovery is to name one.
pub const setup_hint = "no zzz engine found — pass --engine-bin PATH or set ZZZBENCH_ENGINE_BIN";

/// Prefer the runner supplied by the build launcher, then an installed
/// sibling, then this workspace's installed runner. Zig launches build
/// artifacts out of separate cache directories, so argv[0] alone is not
/// enough. Explicit --engine-bin is handled by the caller first.
pub fn defaultBin(io: std.Io, argv0: []const u8, workspace: []const u8, bundled: ?[]const u8, buf: []u8) ?[]const u8 {
    if (bundled) |path| {
        return runnerAt(io, buf, "{s}", .{path});
    }
    if (std.fs.path.dirname(argv0)) |dir| {
        if (runnerAt(io, buf, "{s}/zzz", .{dir})) |found| return found;
    }
    return runnerAt(io, buf, "{s}/zig-out/bin/zzz", .{workspace});
}

/// One candidate, or null to move on to the next. A path too long for
/// `buf` is a miss like any other: a build-cache launch directory can
/// be far deeper than the workspace runner it would otherwise shadow.
fn runnerAt(io: std.Io, buf: []u8, comptime fmt: []const u8, args: anytype) ?[]const u8 {
    const candidate = std.fmt.bufPrint(buf, fmt, args) catch return null;
    return if (executable(io, candidate)) candidate else null;
}

fn executable(io: std.Io, path: []const u8) bool {
    const dir = std.Io.Dir.cwd();
    const stat = dir.statFile(io, path, .{}) catch return false;
    if (stat.kind != .file) return false;
    dir.access(io, path, .{ .execute = true }) catch return false;
    return true;
}

test "local runner resolves a build-cache launch and respects bundled and installed paths" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.createDirPath(io, "zig-out/bin");
    const workspace = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(workspace);
    const installed = try std.fmt.allocPrint(std.testing.allocator, "{s}/zig-out/bin/zzz", .{workspace});
    defer std.testing.allocator.free(installed);
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    try std.testing.expect(defaultBin(io, ".zig-cache/o/tui/zzzbench", workspace, null, &buf) == null);
    const file = try tmp.dir.createFile(io, "zig-out/bin/zzz", .{ .permissions = .fromMode(0o755) });
    file.close(io);
    try std.testing.expectEqualStrings(installed, defaultBin(io, ".zig-cache/o/tui/zzzbench", workspace, null, &buf).?);
    try std.testing.expectEqualStrings(installed, defaultBin(io, "zzzbench", "/missing-workspace", installed, &buf).?);
    const argv0 = try std.fmt.allocPrint(std.testing.allocator, "{s}/zig-out/bin/zzzbench", .{workspace});
    defer std.testing.allocator.free(argv0);
    try std.testing.expectEqualStrings(installed, defaultBin(io, argv0, "/missing-workspace", null, &buf).?);
    try std.testing.expect(defaultBin(io, "zzzbench", "/missing-workspace", workspace, &buf) == null);
    try std.testing.expect(defaultBin(io, argv0, workspace, "/missing-explicit-engine", &buf) == null);
    // A sibling path that overflows the buffer is skipped, not fatal:
    // the workspace runner behind it still resolves.
    const deep_argv0 = "/" ++ "d" ** 512 ++ "/zzzbench";
    try std.testing.expectEqualStrings(installed, defaultBin(io, deep_argv0, workspace, null, buf[0..installed.len]).?);
}

test "parseSpec splits name from rate, rejects malformed specs" {
    const ok = parseSpec("zzz:20.41").?;
    try std.testing.expectEqualStrings("zzz", ok.name);
    try std.testing.expectApproxEqAbs(@as(f32, 20.41), ok.tok_s, 0.001);
    try std.testing.expect(parseSpec("zzz") == null);
    try std.testing.expect(parseSpec("zzz:fast") == null);
}

test "the four run states are distinguished, not collapsed" {
    var p = Progress{};
    try std.testing.expectEqual(State.never_ran, p.state());
    try std.testing.expect(!p.isRunning());

    p.have_report = true;
    p.phase = phase_prefill;
    try std.testing.expectEqual(State.running, p.state());
    p.phase = phase_decode;
    try std.testing.expectEqual(State.running, p.state());
    try std.testing.expect(p.isRunning());

    p.phase = phase_done;
    p.decode_tok_s = 59.44;
    // A complete run also has tokens behind its rate; see the
    // zero-token case below for why the two are checked together.
    p.token_index = 32;
    try std.testing.expectEqual(State.complete, p.state());
    try std.testing.expect(!p.isRunning());
}

test "a requested comparison run is active before reports and repeated requests preserve progress" {
    var progress: Progress = .{};
    progress.markStarted(64);
    try std.testing.expect(progress.isRunning());
    try std.testing.expect(!progress.have_report);
    try std.testing.expectEqualStrings("starting", progress.activityLabel());
    var report = std.mem.zeroes(proto.EngineReport);
    report.phase = phase_prefill;
    report.tokens_total = 64;
    progress.update(report);
    try std.testing.expectEqualStrings("prefill", progress.activityLabel());
    report.phase = phase_decode;
    report.token_index = 10;
    report.decode_tok_s = 2.5;
    progress.update(report);
    progress.markStarted(128);
    try std.testing.expectEqual(@as(u32, 10), progress.token_index);
    try std.testing.expectEqual(@as(u32, 64), progress.tokens_total);
    try std.testing.expectEqualStrings("decoding", progress.activityLabel());
    report.phase = phase_done;
    report.token_index = 64;
    progress.update(report);
    try std.testing.expectEqual(State.complete, progress.state());
    progress.markStarted(32);
    try std.testing.expectEqualStrings("starting", progress.activityLabel());
    try std.testing.expectEqual(@as(u32, 0), progress.token_index);
    progress.markFailed();
    try std.testing.expectEqual(State.failed, progress.state());
}

test "a final report carrying no rate is a failure, not a completion" {
    // What a probe synthesizes when its engine exits without sending
    // phase 2: the terminator fires so the bench stops waiting, but
    // every measurement in it is zero. Read by phase alone this is a
    // finished benchmark whose answer was 0.00 tok/s.
    var p = Progress{};
    p.update(.{
        .phase = phase_done,
        .ts_ns = 1_200_000_000,
        .token_index = 0,
        .tokens_total = 0,
        .decode_tok_s = 0,
        .prefill_tok_s = 0,
    });
    try std.testing.expectEqual(State.failed, p.state());
    try std.testing.expect(!p.isRunning());
}

test "a locally killed engine does not pass for a finished one" {
    // The bench forces its own terminator when a host-local engine
    // dies mid-run. Without the flag, the last partial running average
    // it happened to receive would be captioned as the run average.
    var p = Progress{};
    p.update(.{
        .phase = phase_decode,
        .ts_ns = 400_000_000,
        .token_index = 12,
        .tokens_total = 60,
        .decode_tok_s = 30.0,
        .prefill_tok_s = 0,
    });
    try std.testing.expectEqual(State.running, p.state());
    p.markFailed();
    try std.testing.expectEqual(State.failed, p.state());
    try std.testing.expect(!p.isRunning());
}

test "a failed run before any report is still a failure, not a fresh session" {
    var p = Progress{};
    p.markFailed();
    try std.testing.expectEqual(State.failed, p.state());
}

test "a run that survives a dropped connection is not left marked failed" {
    // The primary probe's socket blips mid-run, so the bench writes the
    // run off. The probe reconnects and the same run reports again.
    var p = Progress{};
    p.markStarted(64);
    p.update(.{ .phase = phase_decode, .ts_ns = 400_000_000, .token_index = 12, .tokens_total = 64, .decode_tok_s = 30.0, .prefill_tok_s = 0 });
    p.markFailed();
    try std.testing.expectEqual(State.failed, p.state());
    p.update(.{ .phase = phase_decode, .ts_ns = 800_000_000, .token_index = 24, .tokens_total = 64, .decode_tok_s = 30.0, .prefill_tok_s = 0 });
    try std.testing.expectEqual(State.running, p.state());
    p.update(.{ .phase = phase_done, .ts_ns = 2_100_000_000, .token_index = 64, .tokens_total = 64, .decode_tok_s = 30.5, .prefill_tok_s = 0 });
    try std.testing.expectEqual(State.complete, p.state());
}

test "an abandoned run's reports are dropped until its terminal report frees the device" {
    const decoding: proto.EngineReport = .{ .phase = phase_decode, .ts_ns = 400_000_000, .token_index = 12, .tokens_total = 64, .decode_tok_s = 30.0, .prefill_tok_s = 0 };
    var done = decoding;
    done.phase = phase_done;
    done.token_index = 64;

    var p = Progress{};
    p.markStarted(64);
    p.markAbandoned();
    try std.testing.expectEqual(State.failed, p.state());
    // The device is still running the old request. Drawn, this would be
    // the old model's rate under whatever was asked for since.
    try std.testing.expect(!p.take(decoding));
    try std.testing.expect(!p.have_report);
    // Clearing the result for the next `r` does not free the device.
    p.reset();
    try std.testing.expect(p.abandoned);
    try std.testing.expectEqual(State.failed, p.state());
    try std.testing.expect(!p.take(decoding));
    // Its terminal report does — and is itself not a result.
    try std.testing.expect(!p.take(done));
    try std.testing.expect(!p.abandoned);
    try std.testing.expectEqual(State.never_ran, p.state());
    try std.testing.expect(p.take(decoding));
    try std.testing.expectEqual(State.running, p.state());

    // A dropped connection takes the terminal report with it.
    var lost = Progress{};
    lost.markAbandoned();
    lost.connectionLost();
    lost.reset();
    try std.testing.expectEqual(State.never_ran, lost.state());
}

test "elapsed seconds and the headline rate agree with the token count" {
    // The engine derives `decode_tok_s` as tokens / elapsed, so a
    // reader must be able to divide the two numbers on screen and get
    // the third back.
    var p = Progress{};
    p.update(.{
        .phase = phase_done,
        .ts_ns = 538_400_000,
        .token_index = 32,
        .tokens_total = 32,
        .decode_tok_s = 59.44,
        .prefill_tok_s = 0,
    });
    const derived = @as(f64, @floatFromInt(p.producedTokens())) / p.elapsedSeconds();
    try std.testing.expectApproxEqAbs(@as(f64, 59.44), derived, 0.01);
}

test "validTokS rejects NaN and non-positive rates" {
    try std.testing.expect(validTokS(7.5));
    try std.testing.expect(!validTokS(0));
    try std.testing.expect(!validTokS(std.math.nan(f32)));
}

test "the build mode is read out of the engine's own banner" {
    var runner: Runner = .{ .allocator = std.testing.allocator, .io = undefined };
    const banner =
        "Kernel flag:    auto\n" ++
        "Build mode:     Debug\n" ++
        "dotprod runtime: true\n";
    @memcpy(runner.stderr_buf[0..banner.len], banner);
    runner.stderr_len = banner.len;
    try std.testing.expectEqualStrings("Debug", runner.buildMode().?);
}

test "no banner yet reads as unknown rather than as a fast build" {
    var runner: Runner = .{ .allocator = std.testing.allocator, .io = undefined };
    try std.testing.expectEqual(@as(?[]const u8, null), runner.buildMode());

    const partial = "zzz-decode-iter v0.1.0\n";
    @memcpy(runner.stderr_buf[0..partial.len], partial);
    runner.stderr_len = partial.len;
    try std.testing.expectEqual(@as(?[]const u8, null), runner.buildMode());
}

test "a run that decoded nothing is a failure, whatever rate it reports" {
    // What a harness produces when the model emits EOS at the first
    // step and the rate is computed anyway: zero tokens, essentially
    // zero elapsed, and a division between them. The dashboard drew
    // that as `9999 tok/s` for LFM2.5-350M before this gate existed.
    var p = Progress{};
    p.update(.{
        .phase = phase_done,
        .ts_ns = 400_000,
        .token_index = 0,
        .tokens_total = 32,
        .decode_tok_s = 250_000,
        .prefill_tok_s = 41.7,
    });
    try std.testing.expectEqual(State.failed, p.state());
    try std.testing.expect(!p.isRunning());
}
