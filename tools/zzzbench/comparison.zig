//! The comparison coordinator: what actually makes two engines'
//! numbers comparable.
//!
//! Everything that decides fairness lives here, not in the adapters. An
//! adapter declares what its tool *can* do; the run policy — how many
//! repetitions, which statistic, what order — is applied identically to
//! every engine in the comparison. A manifest cannot ask for three
//! repetitions of itself and one of its rival.
//!
//! Three rules the rest of the tool is built around:
//!
//! 1. **One warm-up per engine, excluded.** The first run of anything on
//!    a phone pays for page cache and clock ramp.
//! 2. **Round-major rotating order.** Engines alternate within a round so
//!    a device that ratchets down across a session drags both arms
//!    together instead of the one that always ran last.
//! 3. **No ratio from a partial sample.** A failed repetition leaves the
//!    other arms running for diagnosis, but the arm it belonged to
//!    publishes no aggregate. A smaller accidental sample is how a
//!    published number becomes irreproducible.

const std = @import("std");
pub const measurement_stats = @import("measurement_stats.zig");
const tui = @import("tuiz");
const manifest_mod = @import("engine_manifest.zig");
const parser_mod = @import("engine_parser.zig");
const exec_client = @import("exec_client.zig");
const proto = @import("proto");

pub const Stat = enum {
    mean,
    best,

    pub fn label(self: Stat) []const u8 {
        return @tagName(self);
    }

    pub fn parse(text: []const u8) ?Stat {
        return std.meta.stringToEnum(Stat, text);
    }
};

pub const reps_max: u8 = 16;
pub const arms_max: usize = 8;
/// Enough for a summary adapter's whole output; the streaming parser
/// only ever needs one frame of it.
pub const parse_buffer_bytes: usize = 256 * 1024;

pub const Policy = struct {
    reps: u8 = 3,
    warmup: bool = true,
    stat: Stat = .mean,
    threads: u32 = 4,
    n_prompt: u32 = 128,
    n_generate: u32 = 32,
    /// Enforced on the device, per repetition.
    timeout_ms: u32 = 300_000,
};

pub const ArmPlan = struct {
    id: []const u8,
    label: []const u8,
    parser: manifest_mod.Parser,
    fidelity: manifest_mod.Fidelity,
    metrics: manifest_mod.Metrics = .{},
    argv: []const []const u8,
    /// `KEY=VALUE` entries, already in the shape the wire carries.
    environment: []const []const u8 = &.{},
    /// Digest of the executable `argv[0]` selected, when the host can
    /// read it. Empty for a device-side binary this host cannot hash —
    /// recorded as empty rather than as the digest of something else.
    binary_sha256: []const u8 = "",
};

pub const Plan = struct {
    run_id: u64,
    device: []const u8,
    model_path: []const u8,
    model_sha256: []const u8 = "",
    policy: Policy,
    /// `arms[0]` is the baseline every ratio is taken against.
    arms: []const ArmPlan,
};

pub const Failure = enum {
    none,
    /// The operator stopped the run before this repetition happened. It
    /// is a hole in the sample, which is why it is a failure and not an
    /// absence: the arm publishes no aggregate either way.
    not_run,
    rejected,
    timeout,
    cancelled,
    nonzero_exit,
    no_result,
    malformed,
    output_too_large,
    transport,

    pub fn label(self: Failure) []const u8 {
        return @tagName(self);
    }
};

pub const Repetition = struct {
    metrics: ?proto.ExecMetrics = null,
    /// 0 is the warm-up, which is run and recorded but never aggregated.
    round: u8,
    measured: bool,
    sample: parser_mod.Sample = .{},
    failure: Failure = .none,
    /// Probe-side reason, kept verbatim so a receipt says `disabled`
    /// rather than "it did not work".
    reason: []const u8 = "none",
    exit_code: i32 = 0,
    elapsed_ns: u64 = 0,
    stdout_bytes: u64 = 0,
    stderr_bytes: u64 = 0,
    /// Device conditions while this repetition ran. Two arms that
    /// rotated across a thermal ramp are only comparable if the receipt
    /// can show the ramp.
    telemetry: exec_client.Telemetry = .{},

    pub fn valid(self: Repetition) bool {
        return self.failure == .none and self.sample.any();
    }
};

pub const ArmResult = struct {
    id: []const u8,
    label: []const u8,
    fidelity: manifest_mod.Fidelity,
    repetitions: []Repetition,
    prefill_tps: ?f64 = null,
    decode_tps: ?f64 = null,
    prefill_ratio: ?f64 = null,
    decode_ratio: ?f64 = null,
    prefill_stats: ?measurement_stats.Summary = null,
    decode_stats: ?measurement_stats.Summary = null,
    /// Every measured repetition produced a sample. A metric is
    /// aggregated only if every one of them also carried *that* metric,
    /// which is why an arm can be complete with a decode number and no
    /// prefill number.
    complete: bool = false,
};

pub const Result = struct {
    run_id: u64,
    device: []const u8,
    model_path: []const u8,
    model_sha256: []const u8,
    policy: Policy,
    arms: []ArmResult,

    pub fn baseline(self: *const Result) *const ArmResult {
        return &self.arms[0];
    }
};

/// One process the coordinator wants run. The transport turns this into
/// bytes on a probe socket (or, in tests, into canned output).
pub const Invocation = struct {
    arm: usize,
    /// 0 is the warm-up.
    round: u8,
    argv: []const []const u8,
    environment: []const []const u8,
    timeout_ms: u32,
};

/// How a repetition actually gets run. Injected so the fairness rules
/// above are testable without a device: the coordinator is the part
/// that has to be right, and it never talks to a socket itself.
pub const Transport = struct {
    context: *anyopaque,
    execute: *const fn (
        context: *anyopaque,
        invocation: Invocation,
        sink: exec_client.Sink,
    ) anyerror!exec_client.Outcome,
};

/// Watches the run without changing it: the audit receipt writes the
/// raw bytes to disk through this, and a UI renders progress through the
/// same three calls. Nothing here can fail the run — a receipt that
/// cannot be written is reported at the end, not by aborting a
/// measurement halfway.
pub const Recorder = struct {
    context: *anyopaque,
    started: *const fn (context: *anyopaque, invocation: Invocation) void = noopStarted,
    output: *const fn (
        context: *anyopaque,
        invocation: Invocation,
        stream: proto.RawOutput.Stream,
        bytes: []const u8,
    ) void = noopOutput,
    finished: *const fn (context: *anyopaque, invocation: Invocation, repetition: Repetition) void = noopFinished,
    /// Mid-run signal from a streaming adapter, so a UI can render a run
    /// that has not finished. Summary adapters never produce one.
    progress: *const fn (context: *anyopaque, invocation: Invocation, update: parser_mod.Progress) void = noopProgress,
    /// Asked before each repetition. Stopping leaves the repetitions
    /// that did not happen marked `not_run`, so the arm publishes no
    /// aggregate rather than a shorter one.
    stopRequested: *const fn (context: *anyopaque) bool = noopStop,

    fn noopStarted(_: *anyopaque, _: Invocation) void {}
    fn noopProgress(_: *anyopaque, _: Invocation, _: parser_mod.Progress) void {}
    fn noopStop(_: *anyopaque) bool {
        return false;
    }
    fn noopOutput(_: *anyopaque, _: Invocation, _: proto.RawOutput.Stream, _: []const u8) void {}
    fn noopFinished(_: *anyopaque, _: Invocation, _: Repetition) void {}
};

/// Which arm runs in `slot` of `round`. Round 0 (the warm-up) and every
/// odd round keep the declared order; each later round rotates by one,
/// so no engine is permanently first.
pub fn armForSlot(arm_count: usize, round: u8, slot: usize) usize {
    std.debug.assert(arm_count > 0);
    const rotation: usize = if (round == 0) 0 else (round - 1) % arm_count;
    return (slot + rotation) % arm_count;
}

pub fn execute(
    arena: std.mem.Allocator,
    plan: Plan,
    transport: Transport,
    recorder: ?Recorder,
) !Result {
    if (plan.arms.len == 0) return error.NoArms;
    if (plan.arms.len > arms_max) return error.TooManyArms;
    if (plan.policy.reps == 0 or plan.policy.reps > reps_max) return error.BadRepetitionCount;

    const first_round: u8 = if (plan.policy.warmup) 0 else 1;
    var arms = try arena.alloc(ArmResult, plan.arms.len);
    for (plan.arms, 0..) |arm, index| {
        const count = plan.policy.reps + @as(usize, if (plan.policy.warmup) 1 else 0);
        const repetitions = try arena.alloc(Repetition, count);
        // Pre-filled rather than left undefined: a run stopped part way
        // still has to serialize, and every slot it never reached must
        // say so instead of reading as whatever was on the heap.
        for (repetitions, 0..) |*repetition, slot| {
            const round: u8 = @intCast(slot + @as(usize, if (plan.policy.warmup) 0 else 1));
            repetition.* = .{
                .round = round,
                .measured = round > 0,
                .failure = .not_run,
                .reason = "not run",
            };
        }
        arms[index] = .{
            .id = arm.id,
            .label = arm.label,
            .fidelity = arm.fidelity,
            .repetitions = repetitions,
        };
    }
    var written = try arena.alloc(usize, plan.arms.len);
    @memset(written, 0);

    var round: u8 = first_round;
    rounds: while (round <= plan.policy.reps) : (round += 1) {
        for (0..plan.arms.len) |slot| {
            const index = armForSlot(plan.arms.len, round, slot);
            const arm = plan.arms[index];
            const invocation: Invocation = .{
                .arm = index,
                .round = round,
                .argv = arm.argv,
                .environment = arm.environment,
                .timeout_ms = plan.policy.timeout_ms,
            };
            if (recorder) |watch| {
                if (watch.stopRequested(watch.context)) break :rounds;
                watch.started(watch.context, invocation);
            }
            const repetition = try runOnce(arena, plan, arm, invocation, transport, recorder);
            arms[index].repetitions[written[index]] = repetition;
            written[index] += 1;
            if (recorder) |watch| watch.finished(watch.context, invocation, repetition);
        }
    }

    for (arms) |*arm| aggregate(arm, plan.policy);
    applyRatios(arms);
    return .{
        .run_id = plan.run_id,
        .device = plan.device,
        .model_path = plan.model_path,
        .model_sha256 = plan.model_sha256,
        .policy = plan.policy,
        .arms = arms,
    };
}

fn runOnce(
    arena: std.mem.Allocator,
    plan: Plan,
    arm: ArmPlan,
    invocation: Invocation,
    transport: Transport,
    recorder: ?Recorder,
) !Repetition {
    const buffer = try arena.alloc(u8, parse_buffer_bytes);
    var parser: parser_mod.Parser = .init(arm.parser, arm.metrics, .{
        .n_prompt = plan.policy.n_prompt,
        .n_generate = plan.policy.n_generate,
    }, buffer);

    var feed: ParserSink = .{
        .parser = &parser,
        .recorder = recorder,
        .invocation = invocation,
    };
    const outcome = transport.execute(transport.context, invocation, feed.sink()) catch {
        // The run never reached a verdict: the probe went away, or the
        // client's ceiling fired. Not a measurement, and not the
        // engine's fault — recorded as its own kind of failure.
        return .{
            .round = invocation.round,
            .measured = invocation.round > 0,
            .failure = .transport,
            .reason = "transport",
        };
    };

    var repetition: Repetition = .{
        .round = invocation.round,
        .measured = invocation.round > 0,
        .reason = @tagName(outcome.reason),
        .exit_code = outcome.exit_code,
        .elapsed_ns = outcome.elapsed_ns,
        .stdout_bytes = outcome.stdout_bytes,
        .stderr_bytes = outcome.stderr_bytes,
        .telemetry = outcome.telemetry,
        .metrics = outcome.metrics,
    };
    if (!outcome.succeeded()) {
        repetition.failure = switch (outcome.kind) {
            .rejected => .rejected,
            .cancelled => .cancelled,
            else => switch (outcome.reason) {
                .timeout => .timeout,
                .output_limit => .output_too_large,
                else => .nonzero_exit,
            },
        };
        return repetition;
    }

    repetition.sample = parser.finish(outcome.exit_code, arena) catch |e| {
        repetition.failure = switch (e) {
            error.NonZeroExit => .nonzero_exit,
            error.NoResult => .no_result,
            error.Malformed => .malformed,
            error.OutputTooLarge => .output_too_large,
        };
        return repetition;
    };
    return repetition;
}

/// Fans one run's bytes out to the parser and the recorder. stdout is
/// parsed; stderr is only recorded, because engines print progress there
/// and a number lifted out of a progress line is not the number the tool
/// reported. Both streams reach the receipt verbatim.
const ParserSink = struct {
    parser: *parser_mod.Parser,
    recorder: ?Recorder,
    invocation: Invocation,
    last_progress: ?parser_mod.Progress = null,

    fn sink(self: *ParserSink) exec_client.Sink {
        return .{ .context = self, .write = write };
    }

    fn write(context: *anyopaque, stream: proto.RawOutput.Stream, bytes: []const u8) void {
        const self: *ParserSink = @ptrCast(@alignCast(context));
        if (stream == .stdout) self.parser.push(bytes);
        if (self.recorder) |watch| {
            watch.output(watch.context, self.invocation, stream, bytes);
            // Streaming adapters advance `latest` as frames arrive; a
            // summary adapter leaves it null and the UI says so rather
            // than animating a number it does not have.
            if (self.parser.latest) |update| {
                if (!std.meta.eql(self.last_progress, update)) {
                    self.last_progress = update;
                    watch.progress(watch.context, self.invocation, update);
                }
            }
        }
    }
};

fn aggregate(arm: *ArmResult, policy: Policy) void {
    var prefill: [reps_max]f64 = undefined;
    var decode: [reps_max]f64 = undefined;
    var prefill_count: usize = 0;
    var decode_count: usize = 0;
    var valid: usize = 0;
    var measured: usize = 0;
    for (arm.repetitions) |repetition| {
        if (!repetition.measured) continue;
        measured += 1;
        if (!repetition.valid()) continue;
        valid += 1;
        if (repetition.sample.prefill_tps) |value| {
            prefill[prefill_count] = value;
            prefill_count += 1;
        }
        if (repetition.sample.decode_tps) |value| {
            decode[decode_count] = value;
            decode_count += 1;
        }
    }
    // Every measured repetition, or no aggregate at all.
    arm.complete = measured == policy.reps and valid == measured and valid > 0;
    if (!arm.complete) return;
    // Per metric, for the same reason: a mean over the repetitions that
    // happened to report prefill is a different measurement than the one
    // the policy asked for.
    if (prefill_count == valid) {
        arm.prefill_tps = combine(prefill[0..valid], policy.stat);
        arm.prefill_stats = measurement_stats.summarize(prefill[0..valid]);
    }
    if (decode_count == valid) {
        arm.decode_tps = combine(decode[0..valid], policy.stat);
        arm.decode_stats = measurement_stats.summarize(decode[0..valid]);
    }
}

fn combine(values: []const f64, stat: Stat) f64 {
    switch (stat) {
        .mean => {
            var total: f64 = 0;
            for (values) |value| total += value;
            return total / @as(f64, @floatFromInt(values.len));
        },
        .best => {
            var best = values[0];
            for (values[1..]) |value| best = @max(best, value);
            return best;
        },
    }
}

fn applyRatios(arms: []ArmResult) void {
    const base = arms[0];
    for (arms) |*arm| {
        arm.prefill_ratio = ratio(arm.prefill_tps, base.prefill_tps);
        arm.decode_ratio = ratio(arm.decode_tps, base.decode_tps);
    }
}

fn ratio(value: ?f64, base: ?f64) ?f64 {
    const numerator = value orelse return null;
    const denominator = base orelse return null;
    if (denominator == 0) return null;
    return numerator / denominator;
}

/// The `result.json` schema, shared by the receipt on disk and by
/// `zzzbench compare --json`. One schema, so a scripted consumer and a
/// stored receipt never drift apart.
pub fn writeJson(writer: *std.Io.Writer, result: Result) !void {
    var json: std.json.Stringify = .{ .writer = writer, .options = .{ .whitespace = .indent_2 } };
    try json.beginObject();
    try json.objectField("run_id");
    try json.write(result.run_id);
    try json.objectField("device");
    try json.write(result.device);
    try json.objectField("model_path");
    try json.write(result.model_path);
    try json.objectField("model_sha256");
    try json.write(result.model_sha256);

    try json.objectField("policy");
    try json.beginObject();
    try json.objectField("reps");
    try json.write(result.policy.reps);
    try json.objectField("warmup");
    try json.write(result.policy.warmup);
    try json.objectField("stat");
    try json.write(result.policy.stat.label());
    try json.objectField("threads");
    try json.write(result.policy.threads);
    try json.objectField("n_prompt");
    try json.write(result.policy.n_prompt);
    try json.objectField("n_generate");
    try json.write(result.policy.n_generate);
    try json.objectField("timeout_ms");
    try json.write(result.policy.timeout_ms);
    try json.endObject();

    try json.objectField("baseline");
    try json.write(result.baseline().id);

    try json.objectField("engines");
    try json.beginArray();
    for (result.arms) |arm| {
        try json.beginObject();
        try json.objectField("id");
        try json.write(arm.id);
        try json.objectField("label");
        try json.write(arm.label);
        try json.objectField("fidelity");
        try json.write(@tagName(arm.fidelity));
        try json.objectField("complete");
        try json.write(arm.complete);
        try json.objectField("prefill_tps");
        try json.write(arm.prefill_tps);
        try json.objectField("decode_tps");
        try json.write(arm.decode_tps);
        try json.objectField("prefill_ratio");
        try json.write(arm.prefill_ratio);
        try json.objectField("decode_ratio");
        try json.write(arm.decode_ratio);
        try json.objectField("prefill_stats");
        try json.write(arm.prefill_stats);
        try json.objectField("decode_stats");
        try json.write(arm.decode_stats);
        try json.objectField("repetitions");
        try json.beginArray();
        for (arm.repetitions) |repetition| {
            try json.beginObject();
            try json.objectField("round");
            try json.write(repetition.round);
            try json.objectField("measured");
            try json.write(repetition.measured);
            try json.objectField("prefill_tps");
            try json.write(repetition.sample.prefill_tps);
            try json.objectField("decode_tps");
            try json.write(repetition.sample.decode_tps);
            try json.objectField("failure");
            try json.write(repetition.failure.label());
            try json.objectField("reason");
            try json.write(repetition.reason);
            try json.objectField("exit_code");
            try json.write(repetition.exit_code);
            try json.objectField("elapsed_ns");
            try json.write(repetition.elapsed_ns);
            try json.objectField("stdout_bytes");
            try json.write(repetition.stdout_bytes);
            try json.objectField("stderr_bytes");
            try json.write(repetition.stderr_bytes);
            try json.objectField("telemetry");
            try json.beginObject();
            try json.objectField("samples");
            try json.write(repetition.telemetry.samples);
            try json.objectField("soc_temp_mc");
            if (repetition.telemetry.sawSocTemp()) {
                try json.write([2]i32{
                    repetition.telemetry.soc_temp_mc_min,
                    repetition.telemetry.soc_temp_mc_max,
                });
            } else {
                // Not sampled is not zero — a probe with no readable
                // thermal zone must not read as a cold device.
                try json.write(null);
            }
            try json.objectField("power_mw");
            if (repetition.telemetry.sawPower()) {
                try json.write([2]u32{
                    repetition.telemetry.power_mw_min,
                    repetition.telemetry.power_mw_max,
                });
            } else {
                try json.write(null);
            }
            try json.objectField("throttled");
            try json.write(repetition.telemetry.throttled);
            try json.endObject();
            try json.objectField("process_metrics");
            try writeProcessMetrics(&json, repetition.metrics);
            try json.endObject();
        }
        try json.endArray();
        try json.endObject();
    }
    try json.endArray();
    try json.endObject();
    try writer.writeByte('\n');
}

fn writeProcessMetrics(json: *std.json.Stringify, metrics: ?proto.ExecMetrics) !void {
    const m = metrics orelse return json.write(null);
    try json.beginObject();
    try json.objectField("scope");
    try json.write("whole child process, including load and warm-up; CPU times sum across threads");
    try json.objectField("usage");
    if (m.flags & proto.ExecMetrics.flag_usage != 0) {
        try json.write(.{
            .user_ns = m.user_ns,
            .system_ns = m.system_ns,
            .minor_faults = m.minor_faults,
            .major_faults = m.major_faults,
            .max_rss_bytes = m.max_rss_bytes,
        });
    } else try json.write(null);
    try json.objectField("frequency_residency");
    if (m.flags & proto.ExecMetrics.flag_frequency != 0) {
        try json.beginObject();
        try json.objectField("scope");
        try json.write("whole CPU policy, including other processes; raw kernel ticks");
        try json.objectField("window_ns");
        try json.write(m.frequency_window_ns);
        try json.objectField("policies");
        try json.beginArray();
        for (m.policies[0..m.policy_count]) |policy| {
            try json.beginObject();
            try json.objectField("id");
            try json.write(policy.id);
            try json.objectField("bins");
            try json.beginArray();
            for (policy.bins[0..policy.count]) |bin| try json.write(.{ .khz = bin.khz, .ticks = bin.ticks });
            try json.endArray();
            try json.endObject();
        }
        try json.endArray();
        try json.endObject();
    } else try json.write(null);
    try json.endObject();
}

/// Human-readable form of the same result. Ratios are printed only
/// where both arms are complete, so a table can never show a number the
/// JSON refuses to.
pub fn writeTable(writer: *std.Io.Writer, result: Result) !void {
    // Device name, model path and engine labels all come from somewhere
    // else — the wire, the command line, a manifest — and this table is
    // written to a terminal. Same rule the screens follow: text we did
    // not write ourselves is filtered, never printed raw.
    try writer.writeAll("device   ");
    try tui.sanitize.write(writer, result.device);
    try writer.writeAll("\nmodel    ");
    try tui.sanitize.write(writer, result.model_path);
    try writer.writeByte('\n');
    if (result.model_sha256.len > 0) {
        try writer.print("sha256   {s}\n", .{result.model_sha256});
    }
    try writer.print(
        "policy   {d} reps ({s}), warm-up {s}, {d} threads, pp{d}/tg{d}\n\n",
        .{
            result.policy.reps,
            result.policy.stat.label(),
            if (result.policy.warmup) "excluded" else "off",
            result.policy.threads,
            result.policy.n_prompt,
            result.policy.n_generate,
        },
    );
    try writer.writeAll("engine           prefill tok/s   decode tok/s   vs baseline\n");
    for (result.arms) |arm| {
        const label = tui.cell.truncate(arm.label, 16);
        try tui.sanitize.write(writer, label);
        var pad = tui.cell.width(label);
        while (pad < 17) : (pad += 1) try writer.writeByte(' ');
        try writeMetric(writer, arm.prefill_tps);
        try writer.writeAll("   ");
        try writeMetric(writer, arm.decode_tps);
        try writer.writeAll("   ");
        if (arm.prefill_ratio) |prefill| {
            try writer.print("{d:.2}x pf / ", .{prefill});
        } else {
            try writer.writeAll("—      / ");
        }
        if (arm.decode_ratio) |decode| {
            try writer.print("{d:.2}x dec", .{decode});
        } else {
            try writer.writeAll("—      dec");
        }
        try writer.writeByte('\n');
        if (arm.prefill_stats) |stats| try writeSpread(writer, "prefill", stats);
        if (arm.decode_stats) |stats| try writeSpread(writer, "decode", stats);
    }

    var reported_header = false;
    for (result.arms) |arm| {
        for (arm.repetitions) |repetition| {
            if (repetition.failure == .none) continue;
            if (!reported_header) {
                try writer.writeAll("\nfailures\n");
                reported_header = true;
            }
            const round = if (repetition.round == 0) "warm-up" else "round";
            try writer.writeAll("  ");
            const id = tui.cell.truncate(arm.id, 10);
            try tui.sanitize.write(writer, id);
            var id_pad = tui.cell.width(id);
            while (id_pad < 11) : (id_pad += 1) try writer.writeByte(' ');
            try writer.print("{s} {d}: {s} ({s}, exit {d})\n", .{
                round,
                repetition.round,
                repetition.failure.label(),
                repetition.reason,
                repetition.exit_code,
            });
        }
    }
}

pub fn writeSpread(writer: *std.Io.Writer, metric: []const u8, stats: measurement_stats.Summary) !void {
    try writer.print("  {s}: {d} measured, range {d:.2}–{d:.2} tok/s; spread ", .{
        metric, stats.count, stats.min, stats.max,
    });
    if (stats.spread_pct) |spread| {
        try writer.print("{d:.2}% of mean\n", .{spread});
    } else {
        try writer.writeAll("unknown (one repetition)\n");
    }
}

fn writeMetric(writer: *std.Io.Writer, value: ?f64) !void {
    if (value) |number| {
        try writer.print("{d: >13.2}", .{number});
    } else {
        // An arm that lost a repetition prints nothing here rather than
        // a number derived from the repetitions that survived.
        try writer.writeAll("            —");
    }
}

const testing = std.testing;

test "variability excludes warm-up and disappears with an incomplete metric" {
    var reps = [_]Repetition{
        .{ .round = 0, .measured = false, .sample = .{ .decode_tps = 10000 } },
        .{ .round = 1, .measured = true, .sample = .{ .decode_tps = 90 } },
        .{ .round = 2, .measured = true, .sample = .{ .decode_tps = 110 } },
    };
    var arm: ArmResult = .{ .id = "zzz", .label = "zzz", .fidelity = .streaming, .repetitions = &reps };
    aggregate(&arm, .{ .reps = 2, .stat = .best });
    try testing.expectEqual(@as(?f64, 110), arm.decode_tps);
    try testing.expectEqual(@as(?f64, 20), arm.decode_stats.?.spread_pct);
    try testing.expect(arm.prefill_stats == null);
    reps[2].failure = .timeout;
    arm = .{ .id = "zzz", .label = "zzz", .fidelity = .streaming, .repetitions = &reps };
    aggregate(&arm, .{ .reps = 2 });
    try testing.expect(arm.decode_stats == null);
}

/// A transport that answers with canned output instead of a device, so
/// the ordering and aggregation rules can be tested exactly.
const FakeTransport = struct {
    /// tok/s the arm reports on each round; index 0 is the warm-up.
    prefill: [2][]const f64,
    decode: [2][]const f64,
    fail_round: ?u8 = null,
    fail_arm: usize = 0,
    /// Stands in for an engine whose output carries no prefill number.
    omit_prefill_arm: ?usize = null,
    /// Stands in for a streaming adapter: this arm answers with real
    /// `EngineReport` frames instead of a JSON summary.
    stream_binary_arm: ?usize = null,
    order: std.ArrayList([]const u8) = .empty,

    fn transport(self: *FakeTransport) Transport {
        return .{ .context = self, .execute = FakeTransport.execute };
    }

    fn deinit(self: *FakeTransport) void {
        for (self.order.items) |item| testing.allocator.free(item);
        self.order.deinit(testing.allocator);
    }

    fn execute(
        context: *anyopaque,
        invocation: Invocation,
        sink: exec_client.Sink,
    ) anyerror!exec_client.Outcome {
        const self: *FakeTransport = @ptrCast(@alignCast(context));
        const label = try std.fmt.allocPrint(
            testing.allocator,
            "{d}:{d}",
            .{ invocation.round, invocation.arm },
        );
        try self.order.append(testing.allocator, label);

        if (self.fail_round) |round| {
            if (round == invocation.round and invocation.arm == self.fail_arm) {
                return .{ .kind = .exited, .reason = .none, .exit_code = 1 };
            }
        }

        if (self.stream_binary_arm == invocation.arm) {
            const decode: f32 = @floatCast(self.decode[invocation.arm][invocation.round]);
            const prefill: f32 = @floatCast(self.prefill[invocation.arm][invocation.round]);
            for ([_]u8{ 1, 2 }) |phase| {
                const report = proto.EngineReport{
                    .phase = phase,
                    .ts_ns = 1,
                    .token_index = phase,
                    .tokens_total = 2,
                    .decode_tok_s = decode,
                    .prefill_tok_s = prefill,
                };
                const bytes: *const [@sizeOf(proto.EngineReport)]u8 = @ptrCast(&report);
                sink.write(sink.context, .stdout, bytes);
            }
            return .{ .kind = .exited, .reason = .none, .exit_code = 0 };
        }

        var buf: [256]u8 = undefined;
        const omit_prefill = self.omit_prefill_arm == invocation.arm;
        const body = if (omit_prefill) try std.fmt.bufPrint(
            &buf,
            "{{\"decode_tps\": {d}}}",
            .{self.decode[invocation.arm][invocation.round]},
        ) else try std.fmt.bufPrint(
            &buf,
            "{{\"prefill_tps\": {d}, \"decode_tps\": {d}}}",
            .{
                self.prefill[invocation.arm][invocation.round],
                self.decode[invocation.arm][invocation.round],
            },
        );
        // Deliberately split: a summary parser has to survive chunking.
        sink.write(sink.context, .stdout, body[0 .. body.len / 2]);
        sink.write(sink.context, .stdout, body[body.len / 2 ..]);
        sink.write(sink.context, .stderr, "loading\n");
        return .{ .kind = .exited, .reason = .none, .exit_code = 0, .stdout_bytes = body.len };
    }
};

fn testPlan(policy: Policy) Plan {
    return .{
        .run_id = 1,
        .device = "test-device",
        .model_path = "/tmp/model.gguf",
        .model_sha256 = "deadbeef",
        .policy = policy,
        .arms = &.{
            .{
                .id = "zzz",
                .label = "zzz",
                .parser = .json_object,
                .fidelity = .streaming,
                .metrics = .{ .prefill = "prefill_tps", .decode = "decode_tps" },
                .argv = &.{"zzz"},
            },
            .{
                .id = "llamacpp",
                .label = "llama.cpp",
                .parser = .json_object,
                .fidelity = .summary,
                .metrics = .{ .prefill = "prefill_tps", .decode = "decode_tps" },
                .argv = &.{"llama-bench"},
            },
        },
    };
}

test "engines alternate round-major so neither is permanently first" {
    // The order in the PRD: warm-up and round 1 in declared order, then
    // one rotation per round.
    try testing.expectEqual(@as(usize, 0), armForSlot(2, 0, 0));
    try testing.expectEqual(@as(usize, 1), armForSlot(2, 0, 1));
    try testing.expectEqual(@as(usize, 0), armForSlot(2, 1, 0));
    try testing.expectEqual(@as(usize, 1), armForSlot(2, 2, 0));
    try testing.expectEqual(@as(usize, 0), armForSlot(2, 2, 1));
    try testing.expectEqual(@as(usize, 0), armForSlot(2, 3, 0));

    // Three arms rotate rather than swap.
    try testing.expectEqual(@as(usize, 2), armForSlot(3, 3, 0));
    try testing.expectEqual(@as(usize, 0), armForSlot(3, 3, 1));
}

test "the warm-up runs, is recorded, and is never aggregated" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var fake: FakeTransport = .{
        // Warm-up is deliberately absurd: if it reached the mean, the
        // aggregate would not be 100/50.
        .prefill = .{ &.{ 10, 90, 100, 110 }, &.{ 5, 45, 50, 55 } },
        .decode = .{ &.{ 1, 9, 10, 11 }, &.{ 2, 4, 5, 6 } },
    };
    defer fake.deinit();

    const result = try execute(
        arena.allocator(),
        testPlan(.{ .reps = 3, .warmup = true, .stat = .mean }),
        fake.transport(),
        null,
    );

    try testing.expectEqual(@as(usize, 8), fake.order.items.len);
    try testing.expectEqualStrings("0:0", fake.order.items[0]);
    try testing.expectEqualStrings("0:1", fake.order.items[1]);
    // Round 2 rotates: llama.cpp goes first.
    try testing.expectEqualStrings("2:1", fake.order.items[4]);
    try testing.expectEqualStrings("2:0", fake.order.items[5]);

    try testing.expect(result.arms[0].complete);
    try testing.expectEqual(@as(?f64, 100), result.arms[0].prefill_tps);
    try testing.expectEqual(@as(?f64, 10), result.arms[0].decode_tps);
    try testing.expectEqual(@as(?f64, 50), result.arms[1].prefill_tps);
    try testing.expectEqual(@as(?f64, 5), result.arms[1].decode_tps);

    // Ratios are against the baseline arm, both directions of the pair.
    try testing.expectEqual(@as(?f64, 1), result.arms[0].decode_ratio);
    try testing.expectEqual(@as(?f64, 0.5), result.arms[1].decode_ratio);
    try testing.expectEqual(@as(?f64, 0.5), result.arms[1].prefill_ratio);

    // The warm-up is in the receipt, marked as not measured.
    try testing.expectEqual(@as(u8, 0), result.arms[0].repetitions[0].round);
    try testing.expect(!result.arms[0].repetitions[0].measured);
    try testing.expectEqual(@as(?f64, 10), result.arms[0].repetitions[0].sample.prefill_tps);
}

test "one failed repetition costs that arm its aggregate, not the run" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var fake: FakeTransport = .{
        .prefill = .{ &.{ 10, 90, 100, 110 }, &.{ 5, 45, 50, 55 } },
        .decode = .{ &.{ 1, 9, 10, 11 }, &.{ 2, 4, 5, 6 } },
        .fail_round = 2,
        .fail_arm = 1,
    };
    defer fake.deinit();

    const result = try execute(
        arena.allocator(),
        testPlan(.{ .reps = 3, .warmup = true, .stat = .mean }),
        fake.transport(),
        null,
    );

    // Every arm still ran every round — a failure is diagnosed, not
    // aborted around.
    try testing.expectEqual(@as(usize, 8), fake.order.items.len);
    try testing.expect(result.arms[0].complete);
    try testing.expect(!result.arms[1].complete);
    // Two good repetitions out of three is not a two-repetition result.
    try testing.expectEqual(@as(?f64, null), result.arms[1].decode_tps);
    try testing.expectEqual(@as(?f64, null), result.arms[1].decode_ratio);
    try testing.expectEqual(Failure.nonzero_exit, result.arms[1].repetitions[2].failure);
}

test "stat best takes the fastest repetition, mean takes all of them" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var fake: FakeTransport = .{
        .prefill = .{ &.{ 10, 90, 100, 110 }, &.{ 5, 45, 50, 55 } },
        .decode = .{ &.{ 1, 9, 10, 11 }, &.{ 2, 4, 5, 6 } },
    };
    defer fake.deinit();

    const result = try execute(
        arena.allocator(),
        testPlan(.{ .reps = 3, .warmup = true, .stat = .best }),
        fake.transport(),
        null,
    );
    try testing.expectEqual(@as(?f64, 110), result.arms[0].prefill_tps);
    try testing.expectEqual(@as(?f64, 11), result.arms[0].decode_tps);
}

test "result json names the statistic and keeps every repetition" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var fake: FakeTransport = .{
        .prefill = .{ &.{ 10, 90, 100, 110 }, &.{ 5, 45, 50, 55 } },
        .decode = .{ &.{ 1, 9, 10, 11 }, &.{ 2, 4, 5, 6 } },
    };
    defer fake.deinit();

    const result = try execute(
        arena.allocator(),
        testPlan(.{ .reps = 3, .warmup = true, .stat = .mean }),
        fake.transport(),
        null,
    );

    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    try writeJson(&output.writer, result);
    const text = output.written();

    try testing.expect(std.mem.indexOf(u8, text, "\"stat\": \"mean\"") != null);
    try testing.expect(std.mem.indexOf(u8, text, "\"baseline\": \"zzz\"") != null);
    try testing.expect(std.mem.indexOf(u8, text, "\"decode_ratio\": 0.5") != null);
    // The warm-up is present and labelled, not silently dropped.
    try testing.expect(std.mem.indexOf(u8, text, "\"measured\": false") != null);
}

test "an engine that reports only decode still gets a decode ratio" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    // Arm 0 reports decode only and leaves prefill at zero.
    var fake: FakeTransport = .{
        .prefill = .{ &.{ 0, 0, 0, 0 }, &.{ 5, 45, 50, 55 } },
        .decode = .{ &.{ 1, 9, 10, 11 }, &.{ 2, 4, 5, 6 } },
        .omit_prefill_arm = 0,
    };
    defer fake.deinit();

    const result = try execute(
        arena.allocator(),
        testPlan(.{ .reps = 3, .warmup = true, .stat = .mean }),
        fake.transport(),
        null,
    );

    try testing.expect(result.arms[0].complete);
    try testing.expectEqual(@as(?f64, null), result.arms[0].prefill_tps);
    try testing.expectEqual(@as(?f64, 10), result.arms[0].decode_tps);
    // The comparator reported both; only the metric the baseline shares
    // gets a ratio.
    try testing.expectEqual(@as(?f64, 50), result.arms[1].prefill_tps);
    try testing.expectEqual(@as(?f64, null), result.arms[1].prefill_ratio);
    try testing.expectEqual(@as(?f64, 0.5), result.arms[1].decode_ratio);
}

test "a stopped run leaves holes, not a shorter sample" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var fake: FakeTransport = .{
        .prefill = .{ &.{ 10, 90, 100, 110 }, &.{ 5, 45, 50, 55 } },
        .decode = .{ &.{ 1, 9, 10, 11 }, &.{ 2, 4, 5, 6 } },
    };
    defer fake.deinit();

    // Stop after the warm-up and the first measured round.
    var stopper: Stopper = .{ .after = 4 };
    const result = try execute(
        arena.allocator(),
        testPlan(.{ .reps = 3, .warmup = true, .stat = .mean }),
        fake.transport(),
        stopper.recorder(),
    );

    try testing.expectEqual(@as(usize, 4), fake.order.items.len);
    for (result.arms) |arm| {
        try testing.expect(!arm.complete);
        // Two repetitions did happen; publishing their mean would be a
        // different measurement than the one the policy asked for.
        try testing.expectEqual(@as(?f64, null), arm.decode_tps);
        try testing.expectEqual(Failure.not_run, arm.repetitions[2].failure);
        try testing.expectEqualStrings("not run", arm.repetitions[2].reason);
        try testing.expectEqual(@as(u8, 3), arm.repetitions[3].round);
    }
}

/// Stops the run once `after` invocations have started.
const Stopper = struct {
    after: usize,
    started_count: usize = 0,

    fn recorder(self: *Stopper) Recorder {
        return .{ .context = self, .started = started, .stopRequested = stopRequested };
    }

    fn started(context: *anyopaque, _: Invocation) void {
        const self: *Stopper = @ptrCast(@alignCast(context));
        self.started_count += 1;
    }

    fn stopRequested(context: *anyopaque) bool {
        const self: *Stopper = @ptrCast(@alignCast(context));
        return self.started_count >= self.after;
    }
};

test "a streaming adapter's progress reaches the recorder" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var watcher: ProgressWatcher = .{};
    var fake: FakeTransport = .{
        .prefill = .{ &.{ 10, 90 }, &.{ 5, 45 } },
        .decode = .{ &.{ 1, 9 }, &.{ 2, 4 } },
        .stream_binary_arm = 0,
    };
    defer fake.deinit();

    // Arm 0 is the streaming adapter here, so its parser has to be the
    // one that reads frames.
    var plan = testPlan(.{ .reps = 1, .warmup = false, .stat = .mean });
    var arms = [_]ArmPlan{ plan.arms[0], plan.arms[1] };
    arms[0].parser = .zzz_binary;
    plan.arms = &arms;

    _ = try execute(arena.allocator(), plan, fake.transport(), watcher.recorder());

    // One update per distinct report, and none at all from the summary
    // arm — which is the difference the UI labels.
    try testing.expectEqual(@as(usize, 2), watcher.updates);
    try testing.expectEqual(@as(u8, 2), watcher.last.phase);
    try testing.expectEqual(@as(f64, 9), watcher.last.decode_tps);
}

const ProgressWatcher = struct {
    updates: usize = 0,
    last: parser_mod.Progress = .{ .phase = 255 },

    fn recorder(self: *ProgressWatcher) Recorder {
        return .{ .context = self, .progress = progress };
    }

    fn progress(context: *anyopaque, _: Invocation, update: parser_mod.Progress) void {
        const self: *ProgressWatcher = @ptrCast(@alignCast(context));
        self.updates += 1;
        self.last = update;
    }
};
