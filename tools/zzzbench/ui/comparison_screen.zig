//! The screen a comparison runs behind.
//!
//! `zzzbench compare` prints a table when it is over. A comparison on a
//! phone takes minutes — one model load per repetition, per engine — and
//! a frozen terminal for that long is indistinguishable from a hang. So
//! `--vs` draws the run as it happens: which engine is executing, which
//! round, what the finished repetitions measured, and for a streaming
//! adapter the tokens as they land.
//!
//! It draws through the same canvas, gutter and palette as the
//! dashboard, for the reason the pickers do: a comparison must not drop
//! the operator out of the bench's visual language.
//!
//! The screen owns no measurement logic. Everything it renders is a
//! snapshot the coordinator handed it — which is what keeps "what the
//! table says" and "what the receipt says" the same thing by
//! construction.

const std = @import("std");
const tui = @import("tuiz");

const comparison = @import("../comparison.zig");
const theme = @import("theme.zig");
const title_bar = @import("title_bar.zig");
const tty = @import("../tty.zig");

const frame_buf_size: usize = 64 * 1024;

/// Width of the engine-name column, in cells.
const label_cells: usize = 18;

/// Repetition cells, in the order a reader scans them.
pub const Cell = enum {
    pending,
    running,
    done,
    failed,

    fn glyph(self: Cell) []const u8 {
        return switch (self) {
            .pending => "·",
            .running => "▸",
            .done => "✓",
            .failed => "✗",
        };
    }

    fn color(self: Cell) []const u8 {
        return switch (self) {
            .pending => theme.faint,
            .running => theme.accent,
            .done => theme.sub,
            .failed => theme.red,
        };
    }
};

pub const max_arms: usize = comparison.arms_max;
pub const max_cells: usize = comparison.reps_max + 1;

pub const Arm = struct {
    id: []const u8 = "",
    label: []const u8 = "",
    fidelity: []const u8 = "summary",
    cells: [max_cells]Cell = @splat(.pending),
    cell_count: usize = 0,
    /// Aggregates, once the run is over and the arm earned them.
    prefill_tps: ?f64 = null,
    decode_tps: ?f64 = null,
    prefill_ratio: ?f64 = null,
    decode_ratio: ?f64 = null,
    prefill_stats: ?comparison.measurement_stats.Summary = null,
    decode_stats: ?comparison.measurement_stats.Summary = null,
    failures: usize = 0,
};

/// What the streaming arm is doing right now. Summary adapters have no
/// live signal, which is the distinction the screen labels rather than
/// papering over with a synthesized one.
pub const Live = struct {
    arm: usize = 0,
    round: u8 = 0,
    phase: u8 = 255,
    token_index: u32 = 0,
    tokens_total: u32 = 0,
    prefill_tps: f64 = 0,
    decode_tps: f64 = 0,
};

pub const View = struct {
    device: []const u8 = "",
    model: []const u8 = "",
    reps: u8 = 3,
    stat: []const u8 = "mean",
    threads: u32 = 0,
    n_prompt: u32 = 0,
    n_generate: u32 = 0,
    arms: [max_arms]Arm = @splat(.{}),
    arm_count: usize = 0,
    live: ?Live = null,
    /// Set when the operator asked to stop; the run ends after the
    /// repetition in flight rather than mid-measurement.
    stopping: bool = false,
    done: bool = false,
    receipt: []const u8 = "",
};

pub fn render(v: View) !void {
    var buf: [frame_buf_size]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    try draw(v, viewport(), &out);
    try tty.write(out.buffered());
}

pub fn draw(v: View, port: tui.Viewport, out: *std.Io.Writer) !void {
    var canvas = tui.Canvas.init(out, theme.margin, theme.canvas_style);
    try canvas.home();
    const details_fit = detailsFit(v, port);
    const compact_spread = v.done and !details_fit;

    var lw: std.Io.Writer = .fixed(&canvas.scratch);
    try lw.print("{s}{s}", .{ theme.margin_pad, theme.bold });
    try title_bar.writeWordmark(&lw);
    try lw.print("{s} {s}·{s} compare{s}", .{ theme.reset, theme.sep, theme.sub, theme.reset });
    try canvas.row(lw.buffered());

    try metaRow(&canvas, "device", v.device);
    try metaRow(&canvas, "model", v.model);
    var policy_buf: [128]u8 = undefined;
    const policy = try std.fmt.bufPrint(
        &policy_buf,
        "{d} reps ({s}), warm-up excluded, {d} threads, pp{d}/tg{d}",
        .{ v.reps, v.stat, v.threads, v.n_prompt, v.n_generate },
    );
    try metaRow(&canvas, "policy", policy);
    try canvas.blank();

    var head: std.Io.Writer = .fixed(&canvas.scratch);
    try head.print("{s}{s}{s: <18}{s: <14}{s: <15}{s: <15}{s}", .{
        theme.margin_pad,
        theme.label,
        "ENGINE",
        if (compact_spread) "SPREAD pp/tg" else "ROUNDS",
        "PREFILL tok/s",
        "DECODE tok/s",
        theme.reset,
    });
    try canvas.row(head.buffered());
    try canvas.rule(port.content_w);

    for (v.arms[0..v.arm_count], 0..) |arm, index| {
        try armRow(&canvas, v, arm, index, details_fit, port.content_w);
    }

    try canvas.blank();
    if (v.done) {
        try footerDone(&canvas, v, compact_spread);
    } else {
        try footerRunning(&canvas, v);
    }
    try canvas.finish();
}

fn detailsFit(v: View, port: tui.Viewport) bool {
    // Seven header rows, a separator and the final key row. Receipt and
    // live progress rows must fit before spending any rows on detail.
    var rows: usize = 9 + v.arm_count;
    if (v.done and v.receipt.len > 0) rows += 1;
    if (v.live) |live| {
        if (!v.done and live.arm < v.arm_count) rows += 1;
    }
    for (v.arms[0..v.arm_count]) |arm| {
        if (arm.prefill_stats != null) rows += 1;
        if (arm.decode_stats != null) rows += 1;
    }
    return rows <= port.rowsOr(24);
}

fn armRow(canvas: *tui.Canvas, v: View, arm: Arm, index: usize, details_fit: bool, content_w: usize) !void {
    var lw: std.Io.Writer = .fixed(&canvas.scratch);
    const is_baseline = index == 0;
    // The label comes from a manifest — a file the operator may have
    // copied from anywhere — so it is untrusted text like every other
    // string this screen did not write itself.
    try lw.print("{s}{s}", .{
        theme.margin_pad,
        if (is_baseline) theme.accent else theme.reset,
    });
    const label = tui.cell.truncate(arm.label, label_cells);
    try tui.sanitize.write(&lw, label);
    var written = tui.cell.width(label);
    while (written < label_cells) : (written += 1) try lw.writeByte(' ');
    try lw.writeAll(theme.reset);

    if (v.done and !details_fit) {
        // Finished round glyphs give way to spread percentages on short
        // terminals; every engine still gets both metrics in one row.
        try writeSpreadPercent(&lw, arm.prefill_stats);
        try writeSpreadPercent(&lw, arm.decode_stats);
    } else {
        try writeRounds(&lw, arm);
    }

    try writeMetric(&lw, arm.prefill_tps, arm.prefill_ratio, is_baseline);
    try writeMetric(&lw, arm.decode_tps, arm.decode_ratio, is_baseline);
    if (arm.failures > 0) {
        try lw.print("{s}{d} failed{s}", .{ theme.red, arm.failures, theme.reset });
    }
    try canvas.row(lw.buffered());

    // The live line belongs under the arm producing it, and only a
    // streaming adapter has one.
    if (v.live) |live| {
        if (live.arm == index and !v.done) try liveRow(canvas, live);
    }
    if (details_fit) {
        if (arm.prefill_stats) |stats| try spreadRow(canvas, "prefill", stats, content_w);
        if (arm.decode_stats) |stats| try spreadRow(canvas, "decode", stats, content_w);
    }
}

fn writeRounds(out: *std.Io.Writer, arm: Arm) !void {
    for (arm.cells[0..arm.cell_count]) |cell| {
        try out.print("{s}{s}{s} ", .{ cell.color(), cell.glyph(), theme.reset });
    }
    var pad = arm.cell_count * 2;
    while (pad < 14) : (pad += 1) try out.writeByte(' ');
}

fn writeSpreadPercent(out: *std.Io.Writer, stats: ?comparison.measurement_stats.Summary) !void {
    if (stats) |s| {
        if (s.spread_pct) |spread| {
            try out.print("{d: >5.1}% ", .{spread});
        } else try out.writeAll("     ? ");
    } else try out.writeAll("     — ");
}

fn spreadRow(canvas: *tui.Canvas, metric: []const u8, stats: comparison.measurement_stats.Summary, content_w: usize) !void {
    var lw: std.Io.Writer = .fixed(&canvas.scratch);
    try lw.writeAll(theme.margin_pad);
    try comparison.writeSpread(&lw, metric, stats);
    const line = std.mem.trimEnd(u8, lw.buffered(), "\n");
    try canvas.row(tui.cell.truncate(line, theme.margin + content_w));
}

fn liveRow(canvas: *tui.Canvas, live: Live) !void {
    var lw: std.Io.Writer = .fixed(&canvas.scratch);
    try lw.print("{s}  {s}", .{ theme.margin_pad, theme.faint });
    const round_label: []const u8 = if (live.round == 0) "warm-up" else "round";
    if (live.round == 0) {
        try lw.print("{s} · ", .{round_label});
    } else {
        try lw.print("{s} {d} · ", .{ round_label, live.round });
    }
    switch (live.phase) {
        0 => try lw.print("prefill {d:.1} tok/s", .{live.prefill_tps}),
        1 => try lw.print(
            "decoding {d}/{d} · {d:.1} tok/s",
            .{ live.token_index, live.tokens_total, live.decode_tps },
        ),
        2 => try lw.print("done · {d:.1} tok/s", .{live.decode_tps}),
        // A summary adapter reports nothing until it exits; saying so
        // beats an empty line that reads as a stall.
        else => try lw.writeAll("running (no live signal from this adapter)"),
    }
    try lw.writeAll(theme.reset);
    try canvas.row(lw.buffered());
}

fn writeMetric(lw: *std.Io.Writer, value: ?f64, ratio: ?f64, is_baseline: bool) !void {
    if (value) |number| {
        try lw.print("{s}{d: >7.2}{s}", .{ theme.text, number, theme.reset });
        if (!is_baseline) {
            if (ratio) |r| {
                try lw.print(" {s}{d:.2}x{s}  ", .{ theme.sub, r, theme.reset });
            } else {
                try lw.writeAll("        ");
            }
        } else {
            try lw.writeAll("        ");
        }
    } else {
        // Nothing yet, or nothing at all — the same dash the table and
        // the JSON use for "this arm published no number".
        try lw.print("{s}      —{s}        ", .{ theme.faint, theme.reset });
    }
}

fn footerRunning(canvas: *tui.Canvas, v: View) !void {
    var lw: std.Io.Writer = .fixed(&canvas.scratch);
    try lw.print("{s}{s}", .{ theme.margin_pad, theme.faint });
    if (v.stopping) {
        try lw.writeAll("stopping after this repetition…");
    } else {
        try writeKey(&lw, "q", "stop after this repetition");
    }
    try lw.writeAll(theme.reset);
    try canvas.writeRaw(lw.buffered());
}

fn footerDone(canvas: *tui.Canvas, v: View, compact_spread: bool) !void {
    if (v.receipt.len > 0) try metaRow(canvas, "receipt", v.receipt);
    var lw: std.Io.Writer = .fixed(&canvas.scratch);
    try lw.print("{s}{s}", .{ theme.margin_pad, theme.faint });
    try writeKey(&lw, "any key", "exit");
    if (compact_spread) try lw.writeAll(" · ? = one repetition");
    try lw.writeAll(theme.reset);
    try canvas.writeRaw(lw.buffered());
}

/// `value` is never ours: a device name arrives off the wire, a model
/// path off the command line, a receipt path from the filesystem. One
/// `\x1b` in any of them would let its source move the cursor, repaint
/// rows, or write the clipboard through OSC 52 — and even without
/// malice it breaks the layout, because an escape measures as zero
/// cells. See `tui/sanitize.zig`.
fn metaRow(canvas: *tui.Canvas, key: []const u8, value: []const u8) !void {
    var lw: std.Io.Writer = .fixed(&canvas.scratch);
    try lw.print("{s}{s}{s: <9}{s}", .{
        theme.margin_pad,
        theme.label,
        key,
        theme.sub,
    });
    try tui.sanitize.write(&lw, value);
    try lw.writeAll(theme.reset);
    try canvas.row(lw.buffered());
}

fn writeKey(lw: *std.Io.Writer, key: []const u8, action: []const u8) !void {
    try lw.print("{s}[{s}{s}{s}]{s} {s}", .{
        theme.faint,
        theme.accent,
        key,
        theme.faint,
        theme.faint,
        action,
    });
}

fn viewport() tui.Viewport {
    return tui.Viewport.fromWinsize(
        tui.terminal.size() orelse .{ .col = 86, .row = 24, .xpixel = 0, .ypixel = 0 },
        theme.limits,
    );
}

const testing = std.testing;

fn testView() View {
    var v: View = .{
        .device = "PHONE01",
        .model = "/data/local/tmp/model.gguf",
        .reps = 3,
        .stat = "mean",
        .threads = 8,
        .n_prompt = 128,
        .n_generate = 32,
        .arm_count = 2,
    };
    v.arms[0] = .{ .id = "zzz", .label = "zzz", .fidelity = "streaming", .cell_count = 4 };
    v.arms[1] = .{ .id = "llamacpp", .label = "llama.cpp", .fidelity = "summary", .cell_count = 4 };
    return v;
}

fn drawToBuf(v: View, buf: []u8) ![]const u8 {
    var out: std.Io.Writer = .fixed(buf);
    try draw(v, .{ .cols = 100, .rows = 30, .content_w = 92 }, &out);
    return out.buffered();
}

test "a run in flight shows which engine is where, and what it is doing" {
    var v = testView();
    v.arms[0].cells[0] = .done;
    v.arms[0].cells[1] = .running;
    v.arms[1].cells[0] = .failed;
    v.arms[1].failures = 1;
    v.live = .{
        .arm = 0,
        .round = 1,
        .phase = 1,
        .token_index = 12,
        .tokens_total = 32,
        .decode_tps = 87.4,
    };

    var buf: [16 * 1024]u8 = undefined;
    const frame = try drawToBuf(v, &buf);

    try testing.expect(std.mem.indexOf(u8, frame, "compare") != null);
    try testing.expect(std.mem.indexOf(u8, frame, "PHONE01") != null);
    try testing.expect(std.mem.indexOf(u8, frame, "3 reps (mean)") != null);
    try testing.expect(std.mem.indexOf(u8, frame, "pp128/tg32") != null);
    // The live line names the round and the tokens, so a long run is
    // visibly progressing rather than merely open.
    try testing.expect(std.mem.indexOf(u8, frame, "decoding 12/32") != null);
    try testing.expect(std.mem.indexOf(u8, frame, "87.4 tok/s") != null);
    // No numbers before the run earns them.
    try testing.expect(std.mem.indexOf(u8, frame, "—") != null);
    try testing.expect(std.mem.indexOf(u8, frame, "1 failed") != null);
    try testing.expect(std.mem.indexOf(u8, frame, "stop after this repetition") != null);
}

test "a summary adapter says it has no live signal rather than showing none" {
    var v = testView();
    v.live = .{ .arm = 1, .round = 2, .phase = 255 };

    var buf: [16 * 1024]u8 = undefined;
    const frame = try drawToBuf(v, &buf);
    try testing.expect(std.mem.indexOf(u8, frame, "no live signal") != null);
    try testing.expect(std.mem.indexOf(u8, frame, "round 2") != null);
}

test "the finished screen carries the ratios and the receipt path" {
    var v = testView();
    v.done = true;
    v.receipt = "zzzbench-runs/20260828-120631-abc";
    v.arms[0].prefill_tps = 347.52;
    v.arms[0].decode_tps = 87.08;
    v.arms[0].prefill_ratio = 1;
    v.arms[0].decode_ratio = 1;
    v.arms[1].prefill_tps = 515.36;
    v.arms[1].decode_tps = 98.99;
    v.arms[1].prefill_ratio = 1.4829;
    v.arms[1].decode_ratio = 1.1368;

    var buf: [16 * 1024]u8 = undefined;
    const frame = try drawToBuf(v, &buf);
    try testing.expect(std.mem.indexOf(u8, frame, "347.52") != null);
    try testing.expect(std.mem.indexOf(u8, frame, "1.48x") != null);
    try testing.expect(std.mem.indexOf(u8, frame, "1.14x") != null);
    try testing.expect(std.mem.indexOf(u8, frame, "20260828-120631-abc") != null);
    // The baseline carries no ratio against itself in the live view's
    // ratio column — 1.00x is noise there, the row is the reference.
    try testing.expect(std.mem.indexOf(u8, frame, "stop after") == null);
}

test "an arm that published nothing renders a dash, not a zero" {
    var v = testView();
    v.done = true;
    v.arms[0].prefill_tps = 300;
    v.arms[0].decode_tps = 80;
    v.arms[1].decode_tps = null;
    v.arms[1].prefill_tps = null;
    v.arms[1].failures = 2;

    var buf: [16 * 1024]u8 = undefined;
    const frame = try drawToBuf(v, &buf);
    try testing.expect(std.mem.indexOf(u8, frame, "2 failed") != null);
    // Both of that arm's metrics render as the same dash the table and
    // the JSON use, never as a zero that would read as a measurement.
    var dashes: usize = 0;
    var cursor: usize = 0;
    while (std.mem.indexOfPos(u8, frame, cursor, "—")) |at| : (cursor = at + 3) dashes += 1;
    try testing.expectEqual(@as(usize, 2), dashes);
}

test "text this screen did not write cannot drive the terminal" {
    var v = testView();
    // A device name arrives off the wire and a model path off the
    // command line; a manifest label can say anything at all. An escape
    // in any of them would repaint the screen, and OSC 52 would reach
    // the clipboard.
    v.device = "Pixel\x1b[2J\x1b]52;c;cGFzcw==\x07";
    v.model = "/tmp/\x1b[31mmodel.gguf";
    v.arms[1].label = "llama\x1b[1;1Hcpp";
    v.receipt = "zzzbench-runs/\x1b[2Jx";
    v.done = true;

    var buf: [16 * 1024]u8 = undefined;
    const frame = try drawToBuf(v, &buf);

    // The visible text survives; the commands do not.
    try testing.expect(std.mem.indexOf(u8, frame, "Pixel") != null);
    try testing.expect(std.mem.indexOf(u8, frame, "model.gguf") != null);
    try testing.expect(std.mem.indexOf(u8, frame, "\x1b[2J") == null);
    try testing.expect(std.mem.indexOf(u8, frame, "\x1b]52") == null);
    try testing.expect(std.mem.indexOf(u8, frame, "\x1b[1;1H") == null);
    try testing.expect(std.mem.indexOf(u8, frame, "\x1b[31m") == null);
}

test "completed comparisons keep all engines and the footer within the viewport" {
    const labels = [_][]const u8{
        "engine-1", "engine-2", "engine-3", "engine-4",
        "engine-5", "engine-6", "engine-7", "engine-8",
    };
    var v = testView();
    v.done = true;
    v.receipt = "zzzbench-runs/example";
    for (&v.arms, labels) |*arm, label| {
        arm.* = .{
            .label = label,
            .cell_count = 4,
            .prefill_tps = 100,
            .decode_tps = 50,
            .prefill_ratio = 1,
            .decode_ratio = 1,
            .prefill_stats = comparison.measurement_stats.summarize(&.{ 90, 110 }),
            .decode_stats = comparison.measurement_stats.summarize(&.{ 40, 60 }),
        };
    }
    for ([_]usize{ 2, 6, 8 }) |count| {
        v.arm_count = count;
        for ([_]u16{ 20, 24, 27, 28, 33, 34, 40 }) |rows| {
            var buf: [frame_buf_size]u8 = undefined;
            var out: std.Io.Writer = .fixed(&buf);
            const port = tui.Viewport.fromWinsize(.{
                .col = 86,
                .row = rows,
                .xpixel = 0,
                .ypixel = 0,
            }, theme.limits);
            try draw(v, port, &out);
            const frame = out.buffered();
            try testing.expect(std.mem.count(u8, frame, "\n") + 1 <= rows);
            var lines = std.mem.splitScalar(u8, frame, '\n');
            while (lines.next()) |line| {
                try testing.expect(tui.cell.width(line) <= theme.margin + port.content_w);
            }
            for (labels[0..count]) |label| try testing.expect(std.mem.indexOf(u8, frame, label) != null);
            try testing.expect(std.mem.indexOf(u8, frame, "compare") != null);
            try testing.expect(std.mem.indexOf(u8, frame, v.receipt) != null);
            try testing.expect(std.mem.indexOf(u8, frame, "any key") != null);
            // A shorter frame must retain both spreads, not merely hide
            // the overflowing rows; a tall frame retains the full ranges.
            try testing.expectEqual(count, std.mem.count(u8, frame, "20.0%") + std.mem.count(u8, frame, "20.00%"));
            try testing.expectEqual(count, std.mem.count(u8, frame, "40.0%") + std.mem.count(u8, frame, "40.00%"));
            if (rows == 40) try testing.expect(std.mem.indexOf(u8, frame, "range 90.00–110.00") != null);
        }
    }
}

test "compact comparisons keep unknown and missing spreads distinct" {
    var v = testView();
    v.done = true;
    v.arm_count = max_arms;
    for (&v.arms) |*arm| {
        arm.prefill_stats = comparison.measurement_stats.summarize(&.{100});
        arm.decode_stats = comparison.measurement_stats.summarize(&.{ 40, 60 });
    }
    v.arms[0].decode_stats = null;
    var buf: [frame_buf_size]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    try draw(v, .{ .cols = 86, .rows = 24, .content_w = 81 }, &out);
    const frame = out.buffered();
    try testing.expect(std.mem.indexOf(u8, frame, "SPREAD pp/tg") != null);
    try testing.expect(std.mem.indexOf(u8, frame, "? = one repetition") != null);
    try testing.expect(std.mem.indexOf(u8, frame, "     ?      — ") != null);
    try testing.expect(std.mem.indexOf(u8, frame, "  0.0%") == null);
}
