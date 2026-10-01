//! recap-bars — deterministic ASCII bar renderer for recap/SUMMARY blocks.
//!
//! Bars are drawn here (not hand-typed by an agent) so a given set of numbers
//! always renders byte-identically — the same reproducibility contract the
//! bench memos hold their numbers to.
//!
//! Usage (reads rows from stdin, one per line, `|`-separated):
//!
//!   perf mode  —  group | series | value [| baseline]
//!     zig run shared/recap_bars.zig -- perf [--width N] [--unit STR]
//!     Bars are normalized to the largest value across all rows. When a
//!     baseline is given, a signed delta% vs that baseline is appended.
//!
//!   progress mode  —  label | current | total [| note]
//!     zig run shared/recap_bars.zig -- progress [--width N]
//!     Each bar fills current/total; the note is printed after the count.
//!
//! Blank lines and lines beginning with `#` are ignored, so a heredoc can
//! carry comments. Output is meant to sit inside a ``` code fence so the
//! monospace alignment survives Markdown rendering (glow and GitHub).
//!
//! Example:
//!   printf 'Sample Q4_0 t8 pp512 | serial | 32.5\n%s\n' \
//!     'Sample Q4_0 t8 pp512 | threaded | 63.0 | 32.5' \
//!     | zig run shared/recap_bars.zig -- perf --unit tok/s

const std = @import("std");

const full_block = "\u{2588}"; // █  (8/8)
// partials[i] renders (i+1)/8 of a cell: ▏▎▍▌▋▊▉
const partials = [_][]const u8{
    "\u{258F}", "\u{258E}", "\u{258D}", "\u{258C}", "\u{258B}", "\u{258A}", "\u{2589}",
};
const empty_block = "\u{2591}"; // ░  (empty track)

const default_width: usize = 22;

const PerfRow = struct {
    group: []const u8,
    series: []const u8,
    value: f64,
    baseline: ?f64,
};

const ProgRow = struct {
    label: []const u8,
    cur: f64,
    total: f64,
    note: []const u8,
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const arena = init.arena.allocator();
    const io = init.io;

    const argv = try init.minimal.args.toSlice(arena);
    if (argv.len < 2) return usageError("missing mode (perf|progress)");
    const mode = argv[1];

    var width: usize = default_width;
    var unit: []const u8 = "";
    var i: usize = 2;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "--width")) {
            i += 1;
            if (i >= argv.len) return usageError("--width needs a value");
            width = std.fmt.parseInt(usize, argv[i], 10) catch return usageError("bad --width");
        } else if (std.mem.eql(u8, a, "--unit")) {
            i += 1;
            if (i >= argv.len) return usageError("--unit needs a value");
            unit = argv[i];
        } else {
            return usageError("unknown flag");
        }
    }
    if (width == 0) return usageError("--width must be > 0");

    var in_buf: [64 * 1024]u8 = undefined;
    var fr = std.Io.File.stdin().reader(io, &in_buf);
    const input = try fr.interface.allocRemaining(gpa, .limited(4 * 1024 * 1024));
    defer gpa.free(input);

    var out_buf: [64 * 1024]u8 = undefined;
    var ow = std.Io.File.stdout().writer(io, &out_buf);
    const w = &ow.interface;

    if (std.mem.eql(u8, mode, "perf")) {
        try renderPerf(gpa, arena, w, input, width, unit);
    } else if (std.mem.eql(u8, mode, "progress")) {
        try renderProgress(gpa, arena, w, input, width);
    } else {
        return usageError("mode must be perf or progress");
    }
    try w.flush();
}

fn usageError(msg: []const u8) error{Usage} {
    std.log.err("recap-bars: {s}", .{msg});
    std.log.err("usage: recap-bars perf|progress [--width N] [--unit STR]  (rows on stdin)", .{});
    return error.Usage;
}

fn renderPerf(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    w: *std.Io.Writer,
    input: []const u8,
    width: usize,
    unit: []const u8,
) !void {
    var rows: std.ArrayList(PerfRow) = try .initCapacity(gpa, 8);
    defer rows.deinit(gpa);

    var max_val: f64 = 0;
    var group_w: usize = 0;
    var series_w: usize = 0;

    var lines = std.mem.tokenizeScalar(u8, input, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        var fields = std.mem.splitScalar(u8, line, '|');
        const group = std.mem.trim(u8, fields.next() orelse continue, " \t");
        const series = std.mem.trim(u8, fields.next() orelse return usageError("perf row needs group|series|value"), " \t");
        const val_s = std.mem.trim(u8, fields.next() orelse return usageError("perf row needs a value"), " \t");
        const value = std.fmt.parseFloat(f64, val_s) catch return usageError("perf value is not a number");
        var baseline: ?f64 = null;
        if (fields.next()) |b_s| {
            const bt = std.mem.trim(u8, b_s, " \t");
            if (bt.len != 0) baseline = std.fmt.parseFloat(f64, bt) catch return usageError("perf baseline is not a number");
        }
        try rows.append(gpa, .{ .group = group, .series = series, .value = value, .baseline = baseline });
        if (value > max_val) max_val = value;
        group_w = @max(group_w, group.len);
        series_w = @max(series_w, series.len);
    }
    if (rows.items.len == 0) return usageError("no perf rows on stdin");
    if (max_val <= 0) max_val = 1;

    var prev_group: ?[]const u8 = null;
    for (rows.items) |r| {
        const same = prev_group != null and std.mem.eql(u8, prev_group.?, r.group);
        if (same) {
            try padSpaces(w, group_w);
        } else {
            try writePadded(w, r.group, group_w);
        }
        try w.writeAll("  ");
        try writePadded(w, r.series, series_w);
        try w.writeAll("  ");
        try renderBar(w, r.value / max_val, width);
        try w.print("  {s}", .{try fmtNum(arena, r.value)});
        if (unit.len != 0) try w.print(" {s}", .{unit});
        if (r.baseline) |b| {
            if (b > 0) {
                const pct = (r.value - b) / b * 100.0;
                const sign: []const u8 = if (pct >= 0) "+" else "";
                try w.print("  {s}{d}%", .{ sign, @as(i64, @intFromFloat(@round(pct))) });
            }
        }
        try w.writeAll("\n");
        prev_group = r.group;
    }
}

fn renderProgress(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    w: *std.Io.Writer,
    input: []const u8,
    width: usize,
) !void {
    var rows: std.ArrayList(ProgRow) = try .initCapacity(gpa, 8);
    defer rows.deinit(gpa);
    var label_w: usize = 0;

    var lines = std.mem.tokenizeScalar(u8, input, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        var fields = std.mem.splitScalar(u8, line, '|');
        const label = std.mem.trim(u8, fields.next() orelse continue, " \t");
        const cur_s = std.mem.trim(u8, fields.next() orelse return usageError("progress row needs label|current|total"), " \t");
        const total_s = std.mem.trim(u8, fields.next() orelse return usageError("progress row needs a total"), " \t");
        const cur = std.fmt.parseFloat(f64, cur_s) catch return usageError("progress current is not a number");
        const total = std.fmt.parseFloat(f64, total_s) catch return usageError("progress total is not a number");
        var note: []const u8 = "";
        if (fields.next()) |n| note = std.mem.trim(u8, n, " \t");
        try rows.append(gpa, .{ .label = label, .cur = cur, .total = total, .note = note });
        label_w = @max(label_w, label.len);
    }
    if (rows.items.len == 0) return usageError("no progress rows on stdin");

    for (rows.items) |r| {
        try writePadded(w, r.label, label_w);
        try w.writeAll("  ");
        const frac = if (r.total > 0) r.cur / r.total else 0;
        try renderBar(w, frac, width);
        try w.print("  {s}/{s}", .{ try fmtNum(arena, r.cur), try fmtNum(arena, r.total) });
        if (r.note.len != 0) try w.print(" · {s}", .{r.note});
        try w.writeAll("\n");
    }
}

pub fn renderBar(w: *std.Io.Writer, frac_in: f64, width: usize) !void {
    const frac = std.math.clamp(frac_in, 0.0, 1.0);
    const total_eighths: usize = @intFromFloat(@round(frac * @as(f64, @floatFromInt(width)) * 8.0));
    const full_n = total_eighths / 8;
    const rem = total_eighths % 8;
    var cells: usize = 0;
    var k: usize = 0;
    while (k < full_n and cells < width) : (k += 1) {
        try w.writeAll(full_block);
        cells += 1;
    }
    if (rem > 0 and cells < width) {
        try w.writeAll(partials[rem - 1]);
        cells += 1;
    }
    while (cells < width) : (cells += 1) try w.writeAll(empty_block);
}

/// Format a number: whole values print without a decimal, otherwise one place.
fn fmtNum(arena: std.mem.Allocator, v: f64) ![]const u8 {
    const rounded = @round(v * 10.0) / 10.0;
    if (rounded == @round(rounded)) {
        return std.fmt.allocPrint(arena, "{d}", .{@as(i64, @intFromFloat(@round(rounded)))});
    }
    return std.fmt.allocPrint(arena, "{d:.1}", .{rounded});
}

fn writePadded(w: *std.Io.Writer, s: []const u8, width: usize) !void {
    try w.writeAll(s);
    if (s.len < width) try padSpaces(w, width - s.len);
}

fn padSpaces(w: *std.Io.Writer, n: usize) !void {
    var k: usize = 0;
    while (k < n) : (k += 1) try w.writeByte(' ');
}
