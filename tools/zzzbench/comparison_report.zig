//! Readable report from the same result used by JSON and the terminal.
//! Formats recorded measurements without starting processes or accessing the network.
const std = @import("std");
const comparison = @import("comparison.zig");
const bars = @import("recap_bars");
const proto = @import("proto");

pub fn write(out: *std.Io.Writer, result: comparison.Result) !void {
    try out.writeAll("# Benchmark report\n\nDevice: ");
    try markdown(out, result.device);
    try out.writeAll("\n\nModel: ");
    try markdown(out, result.model_path);
    try out.print("\n\nRun: `{x}`. {d} measured repetitions per engine; statistic: {s}. ", .{
        result.run_id, result.policy.reps, result.policy.stat.label(),
    });
    try out.print("Warm-up: {s}. {d} threads, {d} prompt tokens, {d} generated tokens.\n\n", .{
        if (result.policy.warmup) "recorded and excluded" else "disabled",
        result.policy.threads,
        result.policy.n_prompt,
        result.policy.n_generate,
    });
    try out.writeAll("Commands, environment and available file digests: [plan.json](plan.json). " ++
        "All repetitions, failures and observed device conditions: [result.json](result.json). " ++
        "Raw process output is retained in each engine directory.\n\n" ++
        "| Engine | Metric | Tokens/s | Ratio to baseline | Measured | Range | Spread |\n" ++
        "|---|---|---:|---:|---:|---:|---:|\n");
    var complete: usize = 0;
    for (result.arms) |arm| {
        if (arm.complete) complete += 1;
        try metricRow(out, arm.label, "Prompt processing", arm.prefill_tps, arm.prefill_ratio, arm.prefill_stats);
        try metricRow(out, arm.label, "Generation", arm.decode_tps, arm.decode_ratio, arm.decode_stats);
    }
    try out.writeAll("\nSpread = (maximum − minimum) / mean × 100, over measured repetitions only. " ++
        "It describes observed variation, not a confidence interval or proof of a speed difference. " ++
        "One repetition cannot establish stability. Missing or failed repetitions suppress that engine's aggregate.\n\n");
    try failures(out, result);
    try diagnostics(out, result);
    try out.print("## Recap\n\n{d}/{d} engines completed every measured repetition. ", .{ complete, result.arms.len });
    try out.writeAll("Review variability and matching workloads before interpreting ratios.\n\n");
    try chart(out, result, true);
    try chart(out, result, false);
    try out.writeAll("Next: repeat inconclusive measurements under comparable device conditions. " ++
        "This report is a run receipt; it does not certify a publication benchmark.\n");
}

fn diagnostics(out: *std.Io.Writer, result: comparison.Result) !void {
    try out.writeAll("## Process and device conditions\n\n" ++
        "CPU time and memory faults cover the whole child process, including model loading and warm-up. " ++
        "CPU time sums all threads and can exceed elapsed wall time. These are not timings of an individual model phase. " ++
        "Frequency counters cover all processes on each CPU policy, within a window surrounding spawn and reap; " ++
        "counter reads add overhead. They do not prove throttling. Missing data stays unavailable.\n\n" ++
        "| Engine | Round | User CPU ms | System CPU ms | Minor faults | Major faults | Peak memory bytes |\n" ++
        "|---|---:|---:|---:|---:|---:|---:|\n");
    for (result.arms) |arm| {
        for (arm.repetitions) |rep| {
            if (!rep.measured) continue;
            try out.writeAll("| ");
            try markdown(out, arm.label);
            try out.print(" | {d} | ", .{rep.round});
            if (rep.metrics) |m| {
                if (m.flags & proto.ExecMetrics.flag_usage != 0) {
                    try out.print("{d:.2} | {d:.2} | {d} | {d} | {d} |\n", .{
                        @as(f64, @floatFromInt(m.user_ns)) / std.time.ns_per_ms,
                        @as(f64, @floatFromInt(m.system_ns)) / std.time.ns_per_ms,
                        m.minor_faults,
                        m.major_faults,
                        m.max_rss_bytes,
                    });
                    continue;
                }
            }
            try out.writeAll("unavailable | unavailable | unavailable | unavailable | unavailable |\n");
        }
    }
    try frequencyRows(out, result);
}

fn frequencyRows(out: *std.Io.Writer, result: comparison.Result) !void {
    try out.writeAll("\nFrequency residency (time-weighted clock per policy; raw counter deltas in result.json):\n\n");
    for (result.arms) |arm| {
        for (arm.repetitions) |rep| {
            if (!rep.measured) continue;
            try out.writeAll("- ");
            try markdown(out, arm.label);
            try out.print(" round {d}: ", .{rep.round});
            const m = rep.metrics orelse {
                try out.writeAll("unavailable\n");
                continue;
            };
            if (m.flags & proto.ExecMetrics.flag_frequency == 0) {
                try out.writeAll("unavailable\n");
                continue;
            }
            for (m.policies[0..m.policy_count], 0..) |policy, i| {
                if (i > 0) try out.writeAll("; ");
                var ticks: f64 = 0;
                var weighted: f64 = 0;
                for (policy.bins[0..policy.count]) |bin| {
                    const count: f64 = @floatFromInt(bin.ticks);
                    ticks += count;
                    weighted += count * @as(f64, @floatFromInt(bin.khz));
                }
                try out.print("policy {d}: ", .{policy.id});
                if (ticks > 0) try out.print("{d:.0} MHz", .{weighted / ticks / 1000}) else try out.writeAll("no counter advance");
            }
            try out.writeByte('\n');
        }
    }
    try out.writeByte('\n');
}

fn metricRow(out: *std.Io.Writer, label: []const u8, metric: []const u8, rate: ?f64, ratio: ?f64, stats: ?comparison.measurement_stats.Summary) !void {
    try out.writeAll("| ");
    try markdown(out, label);
    try out.print(" | {s} | ", .{metric});
    if (rate) |value| try out.print("{d:.2}", .{value}) else try out.writeAll("—");
    try out.writeAll(" | ");
    if (ratio) |value| try out.print("{d:.3}×", .{value}) else try out.writeAll("—");
    if (stats) |s| {
        try out.print(" | {d} | {d:.2}–{d:.2} | ", .{ s.count, s.min, s.max });
        if (s.spread_pct) |spread| try out.print("{d:.2}%", .{spread}) else try out.writeAll("unknown");
        try out.writeAll(" |\n");
    } else try out.writeAll(" | — | — | unavailable |\n");
}

fn failures(out: *std.Io.Writer, result: comparison.Result) !void {
    for (result.arms) |arm| {
        for (arm.repetitions) |rep| {
            if (rep.failure == .none) continue;
            try out.writeAll("- ");
            try markdown(out, arm.label);
            try out.print(" {s} {d}: {s}; reason ", .{
                if (rep.measured) "round" else "warm-up", rep.round, rep.failure.label(),
            });
            try markdown(out, rep.reason);
            try out.print("; exit {d}.\n", .{rep.exit_code});
        }
    }
    try out.writeByte('\n');
}

fn chart(out: *std.Io.Writer, result: comparison.Result, prompt: bool) !void {
    var maximum: f64 = 0;
    for (result.arms) |arm| {
        const rate = if (prompt) arm.prefill_tps else arm.decode_tps;
        if (rate) |value| maximum = @max(maximum, value);
    }
    if (maximum <= 0) return;
    try out.print("{s} (tokens/s; higher is faster):\n\n```text\n", .{if (prompt) "Prompt processing" else "Generation"});
    for (result.arms) |arm| {
        const rate = (if (prompt) arm.prefill_tps else arm.decode_tps) orelse continue;
        // Manifest IDs are restricted ASCII; labels can contain Markdown fences.
        try out.print("{s: <20} ", .{arm.id});
        try bars.renderBar(out, rate / maximum, 22);
        try out.print("  {d:.2}\n", .{rate});
    }
    try out.writeAll("```\n\n");
}

fn markdown(out: *std.Io.Writer, text: []const u8) !void {
    for (text) |byte| switch (byte) {
        0...31, 127 => try out.writeByte(' '),
        '&' => try out.writeAll("&amp;"),
        '<' => try out.writeAll("&lt;"),
        '>' => try out.writeAll("&gt;"),
        '|', '\\', '`', '*', '_', '[', ']', '#', '!' => {
            try out.writeByte('\\');
            try out.writeByte(byte);
        },
        else => try out.writeByte(byte),
    };
}

test "report escapes metadata and preserves failed results without invented rates" {
    var arms = [_]comparison.ArmResult{.{ .id = "zzz", .label = "bad|<script>\n```", .fidelity = .summary, .repetitions = &.{} }};
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try write(&out.writer, .{ .run_id = 1, .device = "phone", .model_path = "model", .model_sha256 = "", .policy = .{}, .arms = &arms });
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "bad\\|&lt;script&gt;") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "0/1 engines completed") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "unavailable") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "```text") == null);
}
