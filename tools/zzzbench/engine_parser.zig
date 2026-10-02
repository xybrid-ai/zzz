//! Raw engine output → one measured sample.
//!
//! Every adapter's output arrives as bytes and leaves as the same two
//! numbers, so the comparison coordinator never branches on which engine
//! produced them. Parsers are incremental — `push` as the bytes arrive,
//! `finish` once the process is over — because a streaming adapter has to
//! feed the dashboard while it runs, and a summary adapter still has to
//! survive output that arrives in arbitrary chunks.
//!
//! A parser reports progress zero or more times and then exactly one
//! result or one typed failure. "Nearly a result" is a failure: a
//! comparison that silently aggregates a half-parsed run publishes a
//! number nobody can reproduce.

const std = @import("std");
const proto = @import("proto");
const manifest_mod = @import("engine_manifest.zig");

pub const Sample = struct {
    prefill_tps: ?f64 = null,
    decode_tps: ?f64 = null,

    /// Prefill and decode are stored and compared separately, so an
    /// engine that reports only one of them still produced a result —
    /// for that metric. A decode-only stream leaves prefill absent.
    pub fn any(self: Sample) bool {
        return self.prefill_tps != null or self.decode_tps != null;
    }

    pub fn both(self: Sample) bool {
        return self.prefill_tps != null and self.decode_tps != null;
    }
};

/// What a streaming adapter knows mid-run. Summary adapters never
/// produce one, which is exactly the distinction the UI labels.
pub const Progress = struct {
    phase: u8,
    token_index: u32 = 0,
    tokens_total: u32 = 0,
    prefill_tps: f64 = 0,
    decode_tps: f64 = 0,
};

pub const Error = error{
    /// The process failed; whatever it printed is not a measurement.
    NonZeroExit,
    /// Output was well-formed but carried no usable result.
    NoResult,
    /// Output was not the shape this parser consumes.
    Malformed,
    /// More output than the parse buffer holds. Truncating and parsing
    /// the head would produce a plausible wrong number.
    OutputTooLarge,
};

/// Counts the run asked for. `llama-bench` reports one row per test and
/// names them by these, so the parser can pick the prompt row and the
/// generation row instead of trusting their order.
pub const Expect = struct {
    n_prompt: u32,
    n_generate: u32,
};

pub const Parser = struct {
    kind: manifest_mod.Parser,
    metrics: manifest_mod.Metrics = .{},
    expect: Expect,
    /// Caller-owned scratch. Must hold a whole `proto` frame for the
    /// streaming parser, and the engine's whole summary output for the
    /// others.
    buffer: []u8,
    len: usize = 0,
    overflow: bool = false,
    /// Set when the streaming parser saw bytes that are not frames. Kept
    /// separate from `overflow` so the failure names the actual cause
    /// (an engine built without `--report-binary`, say) rather than a
    /// size limit it never hit.
    malformed: bool = false,
    latest: ?Progress = null,
    streamed: Sample = .{},
    saw_final_report: bool = false,

    pub fn init(
        kind: manifest_mod.Parser,
        metrics: manifest_mod.Metrics,
        expect: Expect,
        buffer: []u8,
    ) Parser {
        // Only the streaming parser needs to hold a whole frame; a
        // summary parser's buffer is sized to its engine's output and
        // is allowed to be smaller than any frame.
        if (kind == .zzz_binary) std.debug.assert(buffer.len >= proto.max_frame_bytes);
        return .{ .kind = kind, .metrics = metrics, .expect = expect, .buffer = buffer };
    }

    /// Never fails: a parse problem is a result-time verdict, not a
    /// reason to stop reading a process that is still running. Output
    /// the buffer cannot hold is dropped and recorded, so `finish` can
    /// say which of the two it was.
    pub fn push(self: *Parser, bytes: []const u8) void {
        if (self.malformed) return;
        var rest = bytes;
        while (rest.len > 0) {
            const room = self.buffer.len - self.len;
            if (room == 0) {
                // The buffer holds a whole frame by construction, so a
                // streaming parser that cannot drain a full one is not
                // reading frames at all.
                if (self.kind == .zzz_binary) self.malformed = true else self.overflow = true;
                return;
            }
            const take = @min(room, rest.len);
            @memcpy(self.buffer[self.len..][0..take], rest[0..take]);
            self.len += take;
            rest = rest[take..];
            if (self.kind == .zzz_binary) self.drainFrames();
        }
    }

    pub fn finish(self: *Parser, exit_code: i32, arena: std.mem.Allocator) Error!Sample {
        if (exit_code != 0) return error.NonZeroExit;
        if (self.overflow) return error.OutputTooLarge;
        return switch (self.kind) {
            .zzz_binary => self.finishBinary(),
            .llama_bench_json => self.finishLlamaBench(arena),
            .json_object => self.finishJsonObject(arena),
        };
    }

    fn finishBinary(self: *Parser) Error!Sample {
        if (self.malformed) return error.Malformed;
        // A run that ended without its final report is a run that died
        // mid-decode; the last running average is not its result.
        if (!self.saw_final_report) return error.NoResult;
        if (!self.streamed.any()) return error.NoResult;
        return self.streamed;
    }

    fn drainFrames(self: *Parser) void {
        var offset: usize = 0;
        while (offset < self.len) {
            const span = switch (proto.frameSpan(self.buffer[offset..self.len])) {
                .need_more => break,
                .desync => {
                    // Not frames — most often an engine built without
                    // `--report-binary` printing human-readable text.
                    self.malformed = true;
                    self.len = 0;
                    return;
                },
                .total => |total| total,
            };
            if (self.len - offset < span) break;
            self.consumeFrame(self.buffer[offset..][0..span]);
            offset += span;
        }
        if (offset > 0) {
            const remaining = self.len - offset;
            if (remaining > 0) {
                std.mem.copyForwards(u8, self.buffer[0..remaining], self.buffer[offset..self.len]);
            }
            self.len = remaining;
        }
    }

    fn consumeFrame(self: *Parser, frame: []const u8) void {
        if (std.mem.readInt(u32, frame[0..4], .little) != proto.engine_report_magic) return;
        if (frame.len != @sizeOf(proto.EngineReport)) return;
        const report: *const proto.EngineReport = @ptrCast(@alignCast(frame.ptr));
        self.latest = .{
            .phase = report.phase,
            .token_index = report.token_index,
            .tokens_total = report.tokens_total,
            .prefill_tps = report.prefill_tok_s,
            .decode_tps = report.decode_tok_s,
        };
        // Same finite-and-positive bar the summary parsers apply: a
        // report carrying zero, NaN or infinity did not measure a rate,
        // and letting one through would put it in a mean.
        if (usableRate(report.prefill_tok_s)) self.streamed.prefill_tps = report.prefill_tok_s;
        if (report.phase == phase_done) {
            self.saw_final_report = true;
            if (usableRate(report.decode_tok_s)) {
                self.streamed.decode_tps = report.decode_tok_s;
            }
        }
    }

    fn finishLlamaBench(self: *Parser, arena: std.mem.Allocator) Error!Sample {
        // `avg_ts` has no default: a row that does not carry it is a
        // row from an output schema this parser does not understand, and
        // defaulting it to zero would turn an upstream rename into a
        // run of perfectly successful zero-throughput measurements.
        const Row = struct {
            n_prompt: u32 = 0,
            n_gen: u32 = 0,
            avg_ts: f64,
        };
        const parsed = std.json.parseFromSliceLeaky(
            []const Row,
            arena,
            self.text(),
            .{ .ignore_unknown_fields = true },
        ) catch return error.Malformed;

        var sample: Sample = .{};
        for (parsed) |row| {
            // Rows are matched by what they measured, not by position:
            // llama-bench emits prompt and generation rows in whatever
            // order its test list had.
            if (!usableRate(row.avg_ts)) return error.Malformed;
            if (row.n_gen == 0 and row.n_prompt == self.expect.n_prompt) {
                sample.prefill_tps = row.avg_ts;
            } else if (row.n_prompt == 0 and row.n_gen == self.expect.n_generate) {
                sample.decode_tps = row.avg_ts;
            }
        }
        // Rows that answer a different question than this run asked are
        // skipped above; if none of them answered either, there is no
        // sample here at all.
        if (!sample.any()) return error.NoResult;
        return sample;
    }

    fn finishJsonObject(self: *Parser, arena: std.mem.Allocator) Error!Sample {
        const parsed = std.json.parseFromSliceLeaky(
            std.json.Value,
            arena,
            self.text(),
            .{},
        ) catch return error.Malformed;
        if (parsed != .object) return error.Malformed;

        // The manifest names the fields; the registry refuses a
        // `json-object` adapter that does not. Guessing at field names
        // here would let a manifest silently measure something else.
        const prefill_field = self.metrics.prefill orelse return error.Malformed;
        const decode_field = self.metrics.decode orelse return error.Malformed;
        var sample: Sample = .{};
        sample.prefill_tps = try readNumber(parsed.object, prefill_field);
        sample.decode_tps = try readNumber(parsed.object, decode_field);
        // Zero, negative, NaN and infinity are all "the tool did not
        // measure this", and none of them belong in a mean.
        if (sample.prefill_tps) |rate| {
            if (!usableRate(rate)) return error.Malformed;
        }
        if (sample.decode_tps) |rate| {
            if (!usableRate(rate)) return error.Malformed;
        }
        if (!sample.any()) return error.NoResult;
        return sample;
    }

    fn text(self: *const Parser) []const u8 {
        return self.buffer[0..self.len];
    }

    const phase_done: u8 = 2;
};

/// A throughput a comparison can divide by: finite and above zero.
fn usableRate(rate: f64) bool {
    return std.math.isFinite(rate) and rate > 0;
}

fn readNumber(object: std.json.ObjectMap, field: []const u8) Error!?f64 {
    const value = object.get(field) orelse return null;
    return switch (value) {
        .float => |number| number,
        .integer => |number| @floatFromInt(number),
        .number_string, .string => |literal| std.fmt.parseFloat(f64, literal) catch
            return error.Malformed,
        else => error.Malformed,
    };
}

const testing = std.testing;

fn testParser(kind: manifest_mod.Parser, buffer: []u8) Parser {
    // Every `json-object` adapter carries its field mapping; these are
    // the names the fixture uses.
    const metrics: manifest_mod.Metrics = .{ .prefill = "prefill_tps", .decode = "decode_tps" };
    return .init(kind, metrics, .{ .n_prompt = 128, .n_generate = 32 }, buffer);
}

/// One `EngineReport`, as the engine writes it onto its stdout pipe.
fn reportBytes(phase: u8, prefill: f32, decode: f32) [@sizeOf(proto.EngineReport)]u8 {
    const report = proto.EngineReport{
        .phase = phase,
        .ts_ns = 1,
        .token_index = 0,
        .tokens_total = 32,
        .decode_tok_s = decode,
        .prefill_tok_s = prefill,
    };
    const bytes: *const [@sizeOf(proto.EngineReport)]u8 = @ptrCast(&report);
    return bytes.*;
}

test "zzz-binary reports progress and takes its result from the final report" {
    var buffer: [proto.max_frame_bytes]u8 align(8) = undefined;
    var parser = testParser(.zzz_binary, &buffer);

    const prefill = reportBytes(0, 236.75, 0);
    const decode = reportBytes(1, 236.75, 40.0);
    const final = reportBytes(2, 236.75, 48.5);

    // Split every frame across two pushes: the bytes arrive in whatever
    // chunks the socket hands over, never one frame at a time.
    parser.push(prefill[0..17]);
    parser.push(prefill[17..]);
    try testing.expect(parser.latest != null);
    try testing.expectEqual(@as(u8, 0), parser.latest.?.phase);

    parser.push(&decode);
    try testing.expectEqual(@as(f64, 40.0), parser.latest.?.decode_tps);

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    // Still running: no final report, so no result.
    try testing.expectError(error.NoResult, parser.finish(0, arena.allocator()));

    parser.push(final[0..3]);
    parser.push(final[3..]);
    const sample = try parser.finish(0, arena.allocator());
    try testing.expectEqual(@as(?f64, 236.75), sample.prefill_tps);
    try testing.expectEqual(@as(?f64, 48.5), sample.decode_tps);
}

test "zzz-binary accepts a decode-only stream" {
    var buffer: [proto.max_frame_bytes]u8 align(8) = undefined;
    var parser = testParser(.zzz_binary, &buffer);
    // A stream with no prefill measurement still yields a decode result.
    parser.push(&reportBytes(1, 0, 40.0));
    parser.push(&reportBytes(2, 0, 88.75));

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const sample = try parser.finish(0, arena.allocator());
    try testing.expectEqual(@as(?f64, null), sample.prefill_tps);
    try testing.expectEqual(@as(?f64, 88.75), sample.decode_tps);
}

test "zzz-binary refuses output that is not frames" {
    var buffer: [proto.max_frame_bytes]u8 align(8) = undefined;
    var parser = testParser(.zzz_binary, &buffer);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    // An engine built without --report-binary prints its numbers as text.
    parser.push("prefill 236.75 tok/s\ndecode 48.50 tok/s\n");
    try testing.expectError(error.Malformed, parser.finish(0, arena.allocator()));
}

test "llama-bench-json picks rows by what they measured" {
    var buffer: [16 * 1024]u8 = undefined;
    var parser = testParser(.llama_bench_json, &buffer);
    const fixture = @embedFile("testdata/llama-bench.json");
    // Arbitrary split, as a pipe would deliver it.
    parser.push(fixture[0 .. fixture.len / 3]);
    parser.push(fixture[fixture.len / 3 ..]);

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const sample = try parser.finish(0, arena.allocator());
    try testing.expectEqual(@as(?f64, 236.75), sample.prefill_tps);
    try testing.expectEqual(@as(?f64, 48.50), sample.decode_tps);
}

test "llama-bench-json ignores rows that answer a different question" {
    var buffer: [16 * 1024]u8 = undefined;
    // Against a run that asked for 512 prompt tokens, the fixture's
    // 128-token prompt row is not that run's prefill — but its 32-token
    // generation row is still that run's decode.
    var parser: Parser = .init(
        .llama_bench_json,
        .{},
        .{ .n_prompt = 512, .n_generate = 32 },
        &buffer,
    );
    parser.push(@embedFile("testdata/llama-bench.json"));

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const sample = try parser.finish(0, arena.allocator());
    try testing.expectEqual(@as(?f64, null), sample.prefill_tps);
    try testing.expectEqual(@as(?f64, 48.50), sample.decode_tps);

    // Neither row matching is no sample at all.
    var neither: Parser = .init(
        .llama_bench_json,
        .{},
        .{ .n_prompt = 512, .n_generate = 64 },
        &buffer,
    );
    neither.push(@embedFile("testdata/llama-bench.json"));
    try testing.expectError(error.NoResult, neither.finish(0, arena.allocator()));
}

test "json-object reads mapped fields and ignores the rest" {
    var buffer: [16 * 1024]u8 = undefined;
    var parser = testParser(.json_object, &buffer);
    parser.push(@embedFile("testdata/json-object.json"));

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const sample = try parser.finish(0, arena.allocator());
    try testing.expectEqual(@as(?f64, 236.75), sample.prefill_tps);
    try testing.expectEqual(@as(?f64, 48.50), sample.decode_tps);

    // Each adapter names its own fields, and only those are read.
    var mapped: Parser = .init(
        .json_object,
        .{ .prefill = "pp", .decode = "tg" },
        .{ .n_prompt = 128, .n_generate = 32 },
        &buffer,
    );
    mapped.push("{\"pp\": 100, \"tg\": \"25.5\", \"prefill_tps\": 1}");
    const remapped = try mapped.finish(0, arena.allocator());
    try testing.expectEqual(@as(?f64, 100), remapped.prefill_tps);
    try testing.expectEqual(@as(?f64, 25.5), remapped.decode_tps);

    // No mapping is a refusal, not a guess at conventional names.
    var unmapped: Parser = .init(
        .json_object,
        .{},
        .{ .n_prompt = 128, .n_generate = 32 },
        &buffer,
    );
    unmapped.push("{\"prefill_tps\": 1, \"decode_tps\": 2}");
    try testing.expectError(error.Malformed, unmapped.finish(0, arena.allocator()));
}

test "a failed process is never a measurement" {
    var buffer: [16 * 1024]u8 = undefined;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    var parser = testParser(.llama_bench_json, &buffer);
    parser.push(@embedFile("testdata/llama-bench.json"));
    // Well-formed output plus a non-zero exit is still a failed run: the
    // numbers may be from the half of the work that completed.
    try testing.expectError(error.NonZeroExit, parser.finish(1, arena.allocator()));

    var malformed = testParser(.json_object, &buffer);
    malformed.push("{not json");
    try testing.expectError(error.Malformed, malformed.finish(0, arena.allocator()));

    var missing = testParser(.json_object, &buffer);
    missing.push("{\"neither_field\": 48.5}");
    // Neither metric present is no sample; one of the two is a sample
    // for that metric alone.
    try testing.expectError(error.NoResult, missing.finish(0, arena.allocator()));
}

test "output past the parse buffer fails instead of parsing its head" {
    // Small on purpose: the real buffer is sized for a whole summary,
    // and the failure has to name the size, not a plausible number
    // parsed from a truncated document.
    var buffer: [64]u8 = undefined;
    var parser = testParser(.llama_bench_json, &buffer);
    parser.push(@embedFile("testdata/llama-bench.json"));

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.OutputTooLarge, parser.finish(0, arena.allocator()));
}

test "a row without a usable throughput is not a zero-throughput result" {
    var buffer: [16 * 1024]u8 = undefined;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    // The field renamed upstream: every count still matches, so the
    // rows look right and carry no number.
    var renamed = testParser(.llama_bench_json, &buffer);
    renamed.push(
        \\[{"n_prompt": 128, "n_gen": 0, "average_ts": 236.75},
        \\ {"n_prompt": 0, "n_gen": 32, "average_ts": 48.5}]
    );
    try testing.expectError(error.Malformed, renamed.finish(0, arena.allocator()));

    // A tool that reported zero measured nothing.
    var zeroed = testParser(.llama_bench_json, &buffer);
    zeroed.push(
        \\[{"n_prompt": 128, "n_gen": 0, "avg_ts": 0},
        \\ {"n_prompt": 0, "n_gen": 32, "avg_ts": 48.5}]
    );
    try testing.expectError(error.Malformed, zeroed.finish(0, arena.allocator()));

    var negative = testParser(.json_object, &buffer);
    negative.push("{\"prefill_tps\": -1, \"decode_tps\": 48.5}");
    try testing.expectError(error.Malformed, negative.finish(0, arena.allocator()));
}

test "a binary report carrying a non-rate is not a result" {
    var buffer: [proto.max_frame_bytes]u8 align(8) = undefined;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    // Final report, right phase, and a decode figure that is not a
    // measurement. Accepting it would publish a ratio against zero.
    var zeroed = testParser(.zzz_binary, &buffer);
    zeroed.push(&reportBytes(2, 0, 0));
    try testing.expectError(error.NoResult, zeroed.finish(0, arena.allocator()));

    var infinite = testParser(.zzz_binary, &buffer);
    infinite.push(&reportBytes(2, std.math.inf(f32), std.math.inf(f32)));
    try testing.expectError(error.NoResult, infinite.finish(0, arena.allocator()));

    // A usable decode with an unusable prefill is still a decode result.
    var mixed = testParser(.zzz_binary, &buffer);
    mixed.push(&reportBytes(2, -1, 48.5));
    const sample = try mixed.finish(0, arena.allocator());
    try testing.expectEqual(@as(?f64, null), sample.prefill_tps);
    try testing.expectEqual(@as(?f64, 48.5), sample.decode_tps);
}
