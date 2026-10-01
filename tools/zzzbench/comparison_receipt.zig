//! The audit receipt for one comparison.
//!
//! A published number is only worth as much as the evidence that it was
//! produced the way it claims. Every comparison writes a directory
//! holding the plan it committed to before the first warm-up, the exact
//! bytes each process wrote, and the result computed from them — so a
//! reviewer can re-derive the aggregate, or spot that one arm ran a
//! different command than the other.
//!
//! This is diagnostic evidence, not a canonical benchmark fixture.
//! Publishing a number still means reviewing the receipt first.

const std = @import("std");
const proto = @import("proto");
const comparison = @import("comparison.zig");
const report = @import("comparison_report.zig");

/// Value placeholder for an environment entry whose name is not on the
/// safe list below.
pub const redacted = "<redacted>";

/// Environment names whose *values* are written to the receipt in full.
///
/// This is an allowlist, not a denylist, because a denylist only hides
/// the secrets someone thought of: `HF_TOKEN` and `API_KEY` are caught
/// by any list, `GITHUB_PAT` and `NGC_CLI_ORG` are not, and the receipt
/// is a file the docs tell you to paste into a review. Everything here
/// is a path or a tuning knob whose value is part of the measurement and
/// carries no credential. Every other key is still *named* in the
/// receipt — a reviewer can see that it was set, and ask — with its
/// value replaced.
///
/// Add to this list when an adapter needs a value to be auditable, not
/// when it needs a value to be convenient.
pub const value_safe_environment = [_][]const u8{
    "LD_LIBRARY_PATH",
    "LD_PRELOAD",
    "PATH",
    "TMPDIR",
    "OMP_NUM_THREADS",
    "OMP_PROC_BIND",
    "OMP_PLACES",
    "GOMP_CPU_AFFINITY",
    "MKL_NUM_THREADS",
    "OPENBLAS_NUM_THREADS",
    "GGML_NTHREADS",
    "LLAMA_CACHE",
    "ADSP_LIBRARY_PATH",
    "ZZZ_KERNEL",
    "ZZZ_THREADS",
};

pub const Receipt = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    /// Engine directory names, indexed the way `Invocation.arm` is.
    engine_ids: []const []const u8,
    stdout_file: ?std.Io.File = null,
    stderr_file: ?std.Io.File = null,
    /// Set when a write failed. The run keeps going — losing the receipt
    /// must not cost the measurement — and the caller reports it.
    failed: bool = false,

    /// `stamp` is supplied by the caller rather than read from a clock
    /// here, so a test can pin a directory name.
    pub fn create(
        gpa: std.mem.Allocator,
        io: std.Io,
        root: []const u8,
        stamp: []const u8,
        run_id: u64,
        engine_ids: []const []const u8,
    ) !Receipt {
        const directory = try std.fmt.allocPrint(gpa, "{s}/{s}-{x}", .{ root, stamp, run_id });
        errdefer gpa.free(directory);
        try std.Io.Dir.cwd().createDirPath(io, directory);
        return .{ .gpa = gpa, .io = io, .root = directory, .engine_ids = engine_ids };
    }

    pub fn deinit(self: *Receipt) void {
        self.closeStreams();
        self.gpa.free(self.root);
    }

    pub fn recorder(self: *Receipt) comparison.Recorder {
        return .{
            .context = self,
            .started = started,
            .output = output,
            .finished = finished,
        };
    }

    /// Written before the first warm-up: the plan is immutable once a
    /// measurement has started, and the file is the proof of that.
    pub fn writePlan(
        self: *Receipt,
        plan: comparison.Plan,
        sources: []const []const u8,
    ) !void {
        var text: std.Io.Writer.Allocating = .init(self.gpa);
        defer text.deinit();
        var json: std.json.Stringify = .{
            .writer = &text.writer,
            .options = .{ .whitespace = .indent_2 },
        };
        try json.beginObject();
        try json.objectField("run_id");
        try json.write(plan.run_id);
        try json.objectField("device");
        try json.write(plan.device);
        try json.objectField("model_path");
        try json.write(plan.model_path);
        try json.objectField("model_sha256");
        try json.write(plan.model_sha256);
        try json.objectField("policy");
        try json.write(plan.policy);
        try json.objectField("manifest_sources");
        try json.write(sources);
        try json.objectField("baseline");
        try json.write(plan.arms[0].id);

        try json.objectField("order");
        try json.beginArray();
        const first_round: u8 = if (plan.policy.warmup) 0 else 1;
        var round: u8 = first_round;
        while (round <= plan.policy.reps) : (round += 1) {
            for (0..plan.arms.len) |slot| {
                const index = comparison.armForSlot(plan.arms.len, round, slot);
                try json.beginObject();
                try json.objectField("round");
                try json.write(round);
                try json.objectField("engine");
                try json.write(plan.arms[index].id);
                try json.objectField("measured");
                try json.write(round > 0);
                try json.endObject();
            }
        }
        try json.endArray();

        try json.objectField("engines");
        try json.beginArray();
        for (plan.arms) |arm| {
            try json.beginObject();
            try json.objectField("id");
            try json.write(arm.id);
            try json.objectField("label");
            try json.write(arm.label);
            try json.objectField("parser");
            try json.write(arm.parser.label());
            try json.objectField("fidelity");
            try json.write(@tagName(arm.fidelity));
            try json.objectField("argv");
            try json.write(arm.argv);
            try json.objectField("environment");
            try json.beginArray();
            var redacted_buf: [256]u8 = undefined;
            for (arm.environment) |entry| try json.write(redact(entry, &redacted_buf));
            try json.endArray();
            // A `json-object` adapter's numbers are only re-derivable
            // from the raw bytes if the receipt also says which fields
            // were read as prefill and decode.
            try json.objectField("metrics");
            try json.beginObject();
            try json.objectField("prefill");
            try json.write(arm.metrics.prefill);
            try json.objectField("decode");
            try json.write(arm.metrics.decode);
            try json.endObject();
            // What produced the numbers, when this host can tell. An
            // engine rebuilt after the run would otherwise leave the
            // receipt naming a path and nothing else.
            try json.objectField("binary_sha256");
            try json.write(arm.binary_sha256);
            try json.endObject();
        }
        try json.endArray();
        try json.endObject();
        try text.writer.writeByte('\n');

        try self.writeFile("plan.json", text.written());
    }

    pub fn writeResult(self: *Receipt, result: comparison.Result) !void {
        var text: std.Io.Writer.Allocating = .init(self.gpa);
        defer text.deinit();
        try comparison.writeJson(&text.writer, result);
        try self.writeFile("result.json", text.written());
        var summary: std.Io.Writer.Allocating = .init(self.gpa);
        defer summary.deinit();
        try report.write(&summary.writer, result);
        try self.writeFile("SUMMARY.md", summary.written());
    }

    fn started(context: *anyopaque, invocation: comparison.Invocation) void {
        const self: *Receipt = @ptrCast(@alignCast(context));
        self.closeStreams();
        self.stdout_file = self.openStream(invocation, "stdout");
        self.stderr_file = self.openStream(invocation, "stderr");
    }

    fn output(
        context: *anyopaque,
        _: comparison.Invocation,
        stream: proto.RawOutput.Stream,
        bytes: []const u8,
    ) void {
        const self: *Receipt = @ptrCast(@alignCast(context));
        const file = switch (stream) {
            .stdout => self.stdout_file,
            .stderr => self.stderr_file,
        } orelse return;
        file.writeStreamingAll(self.io, bytes) catch {
            self.failed = true;
        };
    }

    fn finished(
        context: *anyopaque,
        _: comparison.Invocation,
        _: comparison.Repetition,
    ) void {
        const self: *Receipt = @ptrCast(@alignCast(context));
        self.closeStreams();
    }

    /// `<engine>/<round>.stdout`, with the warm-up named as such so a
    /// reader never mistakes it for a measured round.
    fn openStream(
        self: *Receipt,
        invocation: comparison.Invocation,
        extension: []const u8,
    ) ?std.Io.File {
        var name_buf: [64]u8 = undefined;
        const name = if (invocation.round == 0)
            std.fmt.bufPrint(&name_buf, "warmup.{s}", .{extension}) catch return null
        else
            std.fmt.bufPrint(&name_buf, "round{d}.{s}", .{ invocation.round, extension }) catch
                return null;

        const directory = std.fmt.allocPrint(
            self.gpa,
            "{s}/{s}",
            .{ self.root, self.engine_ids[invocation.arm] },
        ) catch {
            self.failed = true;
            return null;
        };
        defer self.gpa.free(directory);
        std.Io.Dir.cwd().createDirPath(self.io, directory) catch {
            self.failed = true;
            return null;
        };
        const path = std.fmt.allocPrint(self.gpa, "{s}/{s}", .{ directory, name }) catch {
            self.failed = true;
            return null;
        };
        defer self.gpa.free(path);
        return std.Io.Dir.cwd().createFile(self.io, path, .{}) catch {
            self.failed = true;
            return null;
        };
    }

    fn closeStreams(self: *Receipt) void {
        if (self.stdout_file) |file| file.close(self.io);
        if (self.stderr_file) |file| file.close(self.io);
        self.stdout_file = null;
        self.stderr_file = null;
    }

    fn writeFile(self: *Receipt, name: []const u8, data: []const u8) !void {
        const path = try std.fmt.allocPrint(self.gpa, "{s}/{s}", .{ self.root, name });
        defer self.gpa.free(path);
        std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = path, .data = data }) catch |e| {
            self.failed = true;
            return e;
        };
    }
};

/// Decide by key name, and default to hiding: an adapter's environment
/// is operator-supplied, a token pasted into a review is not
/// recoverable, and the set of names a credential can hide behind is
/// open-ended. `writePlan` writes `KEY=<redacted>` for anything not on
/// `value_safe_environment`, so which variables were set stays
/// auditable while their values do not leak.
///
/// Returns the entry to write. `out` holds the rewritten form when the
/// value is redacted; it must outlive the returned slice.
pub fn redact(entry: []const u8, out: []u8) []const u8 {
    const equals = std.mem.indexOfScalar(u8, entry, '=') orelse return redacted;
    const key = entry[0..equals];
    for (value_safe_environment) |safe| {
        // Exact, not case-insensitive: Unix environment names are
        // case-sensitive, so `path` and `PATH` are different variables
        // and a credential parked in the former must not inherit the
        // latter's exemption.
        if (std.mem.eql(u8, key, safe)) return entry;
    }
    return std.fmt.bufPrint(out, "{s}={s}", .{ key, redacted }) catch redacted;
}

const testing = std.testing;

test "secret-looking environment entries are redacted, ordinary ones are not" {
    var buf: [256]u8 = undefined;
    // Paths and tuning knobs are part of the measurement.
    try testing.expectEqualStrings(
        "LD_LIBRARY_PATH=/data/local/tmp/lib",
        redact("LD_LIBRARY_PATH=/data/local/tmp/lib", &buf),
    );
    try testing.expectEqualStrings(
        "OMP_NUM_THREADS=8",
        redact("OMP_NUM_THREADS=8", &buf),
    );
    // Anything else keeps its name and loses its value — including the
    // credential names no denylist would have thought of.
    try testing.expectEqualStrings("HF_TOKEN=<redacted>", redact("HF_TOKEN=hf_secret", &buf));
    try testing.expectEqualStrings("GITHUB_PAT=<redacted>", redact("GITHUB_PAT=ghp_x", &buf));
    try testing.expectEqualStrings("NGC_CLI_ORG=<redacted>", redact("NGC_CLI_ORG=acme", &buf));
    // A different variable that merely looks like an allowlisted one.
    try testing.expectEqualStrings("path=<redacted>", redact("path=/tmp/secret", &buf));
    try testing.expectEqualStrings("Ld_Preload=<redacted>", redact("Ld_Preload=x", &buf));
    try testing.expectEqualStrings(redacted, redact("no_equals_sign", &buf));
}

/// A transport that writes one line to each stream, so the receipt's
/// files can be compared byte for byte.
const EchoTransport = struct {
    fn transport() comparison.Transport {
        return .{ .context = undefined, .execute = execute };
    }

    fn execute(
        _: *anyopaque,
        invocation: comparison.Invocation,
        sink: @import("exec_client.zig").Sink,
    ) anyerror!@import("exec_client.zig").Outcome {
        var buf: [128]u8 = undefined;
        const body = try std.fmt.bufPrint(
            &buf,
            "{{\"prefill_tps\": {d}, \"decode_tps\": {d}}}",
            .{ 100 + invocation.round, 10 + invocation.round },
        );
        sink.write(sink.context, .stdout, body);
        sink.write(sink.context, .stderr, "warming up\n");
        return .{ .kind = .exited, .reason = .none, .exit_code = 0 };
    }
};

test "a comparison leaves a receipt that can be re-derived from" {
    var temporary_directory = testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    const root = try std.fmt.allocPrint(
        testing.allocator,
        ".zig-cache/tmp/{s}/runs",
        .{temporary_directory.sub_path},
    );
    defer testing.allocator.free(root);

    const plan: comparison.Plan = .{
        .run_id = 0x2a,
        .device = "oneplus13",
        .model_path = "/data/local/tmp/model.gguf",
        .model_sha256 = "abc123",
        .policy = .{ .reps = 2, .warmup = true, .stat = .mean },
        .arms = &.{
            .{
                .id = "zzz",
                .label = "zzz",
                .parser = .json_object,
                .fidelity = .streaming,
                .metrics = .{ .prefill = "prefill_tps", .decode = "decode_tps" },
                .argv = &.{ "fixture-engine", "model.gguf" },
            },
            .{
                .id = "llamacpp",
                .label = "llama.cpp",
                .parser = .json_object,
                .fidelity = .summary,
                .metrics = .{ .prefill = "prefill_tps", .decode = "decode_tps" },
                .argv = &.{ "llama-bench", "-o", "json" },
                .environment = &.{ "LD_LIBRARY_PATH=/lib", "HF_TOKEN=hf_secret" },
                .binary_sha256 = "cafe",
            },
        },
    };

    var receipt = try Receipt.create(
        testing.allocator,
        testing.io,
        root,
        "20260826-120000",
        plan.run_id,
        &.{ "zzz", "llamacpp" },
    );
    defer receipt.deinit();
    try receipt.writePlan(plan, &.{ "builtin:zzz.toml", "builtin:llamacpp.toml" });

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const result = try comparison.execute(
        arena.allocator(),
        plan,
        EchoTransport.transport(),
        receipt.recorder(),
    );
    try receipt.writeResult(result);
    try testing.expect(!receipt.failed);

    const plan_text = try readReceiptFile(receipt.root, "plan.json");
    defer testing.allocator.free(plan_text);
    // The order is committed to before the first warm-up, so a reviewer
    // can check the rotation actually happened.
    try testing.expect(std.mem.indexOf(u8, plan_text, "\"engine\": \"llamacpp\"") != null);
    try testing.expect(std.mem.indexOf(u8, plan_text, "\"measured\": false") != null);
    try testing.expect(std.mem.indexOf(u8, plan_text, "hf_secret") == null);
    try testing.expect(std.mem.indexOf(u8, plan_text, "HF_TOKEN=<redacted>") != null);
    // The safe entry survives in full, so the receipt still says what
    // the run actually ran with.
    try testing.expect(std.mem.indexOf(u8, plan_text, "LD_LIBRARY_PATH=/lib") != null);
    try testing.expect(std.mem.indexOf(u8, plan_text, "\"binary_sha256\": \"cafe\"") != null);
    try testing.expect(std.mem.indexOf(u8, plan_text, "\"prefill\": \"prefill_tps\"") != null);

    // Raw bytes, per engine, per round — including the warm-up, named so
    // it cannot be read as a measured round.
    const warmup = try readReceiptFile(receipt.root, "zzz/warmup.stdout");
    defer testing.allocator.free(warmup);
    try testing.expectEqualStrings("{\"prefill_tps\": 100, \"decode_tps\": 10}", warmup);
    const round2 = try readReceiptFile(receipt.root, "llamacpp/round2.stderr");
    defer testing.allocator.free(round2);
    try testing.expectEqualStrings("warming up\n", round2);

    const result_text = try readReceiptFile(receipt.root, "result.json");
    defer testing.allocator.free(result_text);
    try testing.expect(std.mem.indexOf(u8, result_text, "\"prefill_tps\": 101.5") != null);
    const summary = try readReceiptFile(receipt.root, "SUMMARY.md");
    defer testing.allocator.free(summary);
    try testing.expect(std.mem.indexOf(u8, summary, "101.50") != null);
    try testing.expect(std.mem.indexOf(u8, summary, "## Recap") != null);
    try testing.expect(std.mem.indexOf(u8, summary, "```text") != null);
}

fn readReceiptFile(root: []const u8, name: []const u8) ![]u8 {
    const path = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ root, name });
    defer testing.allocator.free(path);
    return std.Io.Dir.cwd().readFileAlloc(testing.io, path, testing.allocator, .limited(64 * 1024));
}
