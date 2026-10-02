//! The race layout: one equal column per device, no hero.
//!
//! `bands` keeps the primary device as the subject and lists the rest
//! beneath it, which is right when you are watching one device and
//! curious about the others. This is the other question — which of
//! these machines is fastest — and it has no subject, so no device
//! gets the big number and every column is built the same way.
//!
//! The fastest column is picked out in the accent. That is the only
//! ranking by default: columns stay in selection order unless the
//! operator enables sorting by average speed with `s`.
//!
//! No `peak`, for the reason `peer_band.zig` sets out at length — the
//! wire carries a running average, and the maximum of a running
//! average is not a rate anything sustained. Each column shows the
//! pair the average divides out of instead.

const std = @import("std");
const tui = @import("tuiz");

const engine_mod = @import("../engine.zig");
const Series = @import("../series.zig").Series;
const run_policy = @import("../run_policy.zig");
const hero = @import("hero.zig");
const theme = @import("theme.zig");

/// Cells between columns, half of it the divider rule.
const col_gap: usize = 3;

/// The rate is set in block glyphs, not text — the same treatment the
/// single-device hero gives its headline, because it is the same
/// headline. A race whose numbers are ordinary text has no focal point
/// and reads as a table.
///
/// Sized against the widest figure `formatRate` produces rather than
/// the value on screen, so a column does not change width as its rate
/// crosses 9.99 → 12.34 → 123.4 mid-run.
const number_template = "00.00";
/// Cells for the ` avg` that sits on the number's baseline.
const unit_w: usize = 4;

/// Cells the number needs at a given scale.
fn numberWidth(scale: usize) usize {
    return tui.bigtext.measure(number_template, scale) + unit_w;
}

/// Narrowest column worth drawing: enough for the number at its
/// smallest, since the number is the thing the layout exists to show.
pub const col_w_min: usize = 35;

/// Rows above and below the digits: name, derivation, SoC, a blank,
/// then the two lanes.
const chrome_rows: usize = 6;

/// Rows one column occupies at `scale`. Fixed per frame so every
/// column lines up whatever state its device is in.
pub fn rowsFor(scale: usize) usize {
    return chrome_rows + tui.bigtext.rows * scale;
}

/// Digit scale every column shares this frame.
///
/// One scale for all of them: columns of different digit sizes would
/// imply a ranking the layout does not have, and the accent already
/// carries the only one it does.
///
/// `grid_rows` is what the caller has left for the grid *after* its own
/// chrome, not the terminal height. Taking the terminal height here and
/// the chrome cost there is how the two disagree, and a scale chosen
/// against more rows than exist draws a frame taller than the terminal.
pub fn digitScale(entries: usize, content_w: usize, grid_rows: usize) usize {
    const n = columnCount(entries, content_w);
    if (n == 0) return 1;
    const fits_width = columnWidth(n, content_w) >= numberWidth(2);
    const fits_height = grid_rows >= rowsFor(2);
    return if (fits_width and fits_height) 2 else 1;
}

/// One device in the race. Built by the dashboard from the primary
/// session and each peer, so this file never learns the difference
/// between them — which is the point of the layout.
pub const Entry = struct {
    name: []const u8,
    /// `SOC001`, or empty when the probe has not said.
    soc: []const u8,
    /// Running average tok/s. NaN when the device has not produced one.
    rate: f32,
    tokens: u32,
    tokens_total: u32,
    elapsed_ns: u64,
    state: engine_mod.State,
    activity: []const u8 = "decoding",
    connected: bool = true,
    /// Decode-rate history — the column's upper lane.
    series: *const Series,
    /// What this device was asked to run, or null when the policy does
    /// not reach it. A race column is the most screenshotted thing the
    /// bench draws, and a ranking whose columns ran at different thread
    /// counts is not a ranking unless it says so.
    policy: ?run_policy.Shown = null,
    /// Prime-core load — the lower lane. Null when the probe supplies
    /// synthetic telemetry rather than a measurement from this device.
    ///
    /// The throughput history is sampled per report and retained when a
    /// run finishes. Load is live context on its own clock and scale.
    prime: ?*const Series,
};

/// Index of the fastest entry, or null when nothing has a rate yet.
///
/// Ties keep the earlier entry: the order is the command line's, and a
/// tie that reordered itself frame to frame would be worse than
/// arbitrary, it would be unreadable.
pub fn leader(entries: []const Entry) ?usize {
    var best: ?usize = null;
    for (entries, 0..) |e, i| {
        if (!engine_mod.validTokS(e.rate)) continue;
        if (best == null or e.rate > entries[best.?].rate) best = i;
    }
    return best;
}

pub fn fasterFirst(_: void, a: Entry, b: Entry) bool {
    if (!engine_mod.validTokS(a.rate)) return false;
    return !engine_mod.validTokS(b.rate) or a.rate > b.rate;
}

test "race sorting ranks measured speeds and keeps ties and idle devices stable" {
    var entries = [_]Entry{
        entry("idle", std.math.nan(f32), .never_ran),
        entry("slow", 20, .complete),
        entry("fast", 40, .complete),
        entry("tie", 20, .complete),
    };
    std.sort.insertion(Entry, &entries, {}, fasterFirst);
    try std.testing.expectEqualStrings("fast", entries[0].name);
    try std.testing.expectEqualStrings("slow", entries[1].name);
    try std.testing.expectEqualStrings("tie", entries[2].name);
    try std.testing.expectEqualStrings("idle", entries[3].name);
}

test "fast device numbers stay inside their split-view column" {
    for ([_]f32{ 2.41, 99.999, 306.49, 999.96, 9999, 1e10 }) |rate| {
        const value = entry("Mac", rate, .complete);
        for ([_]usize{ 1, 2 }) |scale| {
            for (0..tui.bigtext.rows * scale) |row| {
                var buf: [2048]u8 = undefined;
                var out: std.Io.Writer = .fixed(&buf);
                try writeNumber(&out, value, row, true, scale);
                try std.testing.expect(tui.cell.width(out.buffered()) <= numberWidth(scale));
            }
        }
    }
}

/// Columns that fit `content_w`, capped at the number of devices.
pub fn columnCount(entries: usize, content_w: usize) usize {
    if (entries == 0) return 0;
    var n = entries;
    while (n > 1) : (n -= 1) {
        if (columnWidth(n, content_w) >= col_w_min) break;
    }
    return n;
}

fn columnWidth(n: usize, content_w: usize) usize {
    const gaps = (n - 1) * col_gap;
    return (content_w -| gaps) / n;
}

/// Draw the whole grid. `content_w` is the layout's content width, the
/// same one every other band is given.
pub fn render(canvas: *tui.Canvas, entries: []const Entry, content_w: usize, scale: usize) !void {
    if (entries.len == 0) return;
    const n = columnCount(entries.len, content_w);
    const col_w = columnWidth(n, content_w);
    // Over the columns that will actually be drawn, not every device.
    // The fastest machine can be the one a narrow terminal dropped, and
    // accenting an index nobody can see leaves the visible race with no
    // winner at all. What the accent means is "fastest of these", which
    // the header's `(N shown)` already qualifies.
    const lead = leader(entries[0..n]);
    const total = rowsFor(scale);

    var row: usize = 0;
    while (row < total) : (row += 1) {
        var line_buf: [tui.scratch_len]u8 = undefined;
        var lw: std.Io.Writer = .fixed(&line_buf);
        try tui.padWidth(&lw, theme.margin);

        for (entries[0..n], 0..) |e, i| {
            const start = theme.margin + i * (col_w + col_gap);
            try tui.cell.padTo(&lw, start);
            if (i > 0) {
                // The divider sits in the gap rather than inside a
                // column, so the columns themselves stay equal.
                try lw.print("{s}│{s} ", .{ theme.rule, theme.reset });
            }
            const inner = col_w -| (if (i > 0) @as(usize, 2) else 0);
            try writeCell(&lw, e, row, inner, lead == i, scale);
        }
        try canvas.row(tui.cell.truncate(lw.buffered(), theme.margin + content_w));
    }
}

/// One column, one row. Every row is clipped by the caller as a
/// backstop, but each is also built to fit so the clip never decides
/// the layout.
fn writeCell(lw: anytype, e: Entry, row: usize, w: usize, is_leader: bool, scale: usize) !void {
    const digit_rows = tui.bigtext.rows * scale;
    // `PHONE01 ✓ done`
    if (row == 0) {
        try lw.writeAll(theme.text);
        try tui.sanitize.write(lw, tui.cell.truncate(e.name, w -| 11));
        try lw.writeAll(" ");
        return writeStatus(lw, e);
    }
    // The rate, in block glyphs. This is the whole point of the
    // layout, so it is the one thing that never gives way.
    if (row <= digit_rows) return writeNumber(lw, e, row - 1, is_leader, scale);

    return switch (row - digit_rows) {
        // `320 tok · 5.58 s` — what the rate divides out of.
        1 => {
            try lw.writeAll(theme.label);
            try writeDerivation(lw, e, w);
            try lw.writeAll(theme.reset);
        },
        // `SOC001 · t8 · 198/320`
        2 => {
            try lw.writeAll(theme.label);
            var wrote = false;
            if (e.soc.len > 0) {
                try tui.sanitize.write(lw, tui.cell.truncate(e.soc, w -| 16));
                wrote = true;
            }
            // The thread count rides here rather than in the header
            // because it is the field that differs per device — a
            // header can only state it when every column agrees.
            if (e.policy) |policy| {
                if (wrote) try lw.writeAll(" · ");
                try lw.print("t{d}", .{policy.policy.threads});
                wrote = true;
            }
            if (e.tokens_total > 0) {
                if (wrote) try lw.writeAll(" · ");
                try lw.print("{d}/{d}", .{ @min(e.tokens, e.tokens_total), e.tokens_total });
            }
            try lw.writeAll(theme.reset);
        },
        3 => {}, // breathing room above the lanes
        // Decode above load, the hero's order. Colour carries which is
        // which: the gold family is throughput, teal is load, and the
        // accent within the gold family marks the leader.
        4 => {
            try lw.writeAll(if (is_leader) theme.spark_lead else theme.spark_rest);
            // Each device's history shows its own variation. The peer-band
            // 20 tok/s floor made a real 2.5 tok/s phone disappear entirely.
            try e.series.chartRow(lw, 0, 1, w, e.series.maxRecent(w));
            try lw.writeAll(theme.reset);
        },
        else => {
            if (e.prime) |prime| {
                try lw.writeAll(theme.spark_prime);
                try prime.sparkline(lw, w);
                try lw.writeAll(theme.reset);
            }
        },
    };
}

/// One row of the block-glyph rate, with ` avg` on its last line so
/// the unit sits on the number's baseline rather than floating.
fn writeNumber(lw: anytype, e: Entry, digit_row: usize, is_leader: bool, scale: usize) !void {
    const colour = if (is_leader) theme.accent else theme.sub;
    var buf: [16]u8 = undefined;
    const text = if (engine_mod.validTokS(e.rate))
        hero.formatRate(&buf, e.rate)
    else
        "";

    try lw.writeAll(colour);
    try tui.bigtext.writeRow(lw, text, digit_row, scale);
    try lw.writeAll(theme.reset);

    if (digit_row + 1 == tui.bigtext.rows * scale and text.len > 0) {
        try lw.print("{s}avg{s}", .{ theme.label, theme.reset });
    }
}

/// Written only if it fits: a token count has no bound worth assuming,
/// and a column is narrower than a band.
fn writeDerivation(lw: anytype, e: Entry, w: usize) !void {
    if (e.tokens == 0 and e.elapsed_ns == 0) return;
    var buf: [48]u8 = undefined;
    var dw: std.Io.Writer = .fixed(&buf);
    dw.print("{d} tok", .{e.tokens}) catch return;
    if (e.elapsed_ns > 0) {
        const secs = @as(f64, @floatFromInt(e.elapsed_ns)) / std.time.ns_per_s;
        dw.print(" · {d:.2} s", .{secs}) catch return;
    }
    const text = dw.buffered();
    if (tui.cell.width(text) > w) return;
    try lw.writeAll(text);
}

fn writeStatus(lw: anytype, e: Entry) !void {
    if (!e.connected) return lw.print("{s}○ offline{s}", .{ theme.red, theme.reset });
    switch (e.state) {
        .running => try lw.print("{s}● {s}{s}", .{ theme.accent, e.activity, theme.reset }),
        .complete => try lw.print("{s}✓ done{s}", .{ theme.green, theme.reset }),
        .failed => try lw.print("{s}✗ failed{s}", .{ theme.red, theme.reset }),
        .never_ran => try lw.print("{s}○ idle{s}", .{ theme.faint, theme.reset }),
    }
}

const testing = std.testing;

var test_series = Series{};

fn entry(name: []const u8, rate: f32, state: engine_mod.State) Entry {
    return .{
        .name = name,
        .soc = "SOC001",
        .rate = rate,
        .tokens = 320,
        .tokens_total = 320,
        .elapsed_ns = 5_584_642_233,
        .state = state,
        .series = &test_series,
        .prime = &test_series,
    };
}

fn widestRow(frame: []const u8) usize {
    var w: usize = 0;
    var it = std.mem.splitScalar(u8, frame, '\n');
    while (it.next()) |line| {
        const body = if (std.mem.endsWith(u8, line, "\x1b[K")) line[0 .. line.len - 3] else line;
        w = @max(w, tui.cell.width(body));
    }
    return w;
}

test "the fastest device is the one picked out" {
    const entries = [_]Entry{
        entry("PHONE01", 41.91, .running),
        entry("Pixel 8", 24.76, .complete),
        entry("Mac mini", 57.30, .complete),
    };
    try testing.expectEqual(@as(?usize, 2), leader(&entries));
}

test "a tie keeps the order it was given" {
    // Reordering on a tie would make columns swap places frame to
    // frame, which is worse than an arbitrary winner.
    const entries = [_]Entry{
        entry("first", 42.0, .complete),
        entry("second", 42.0, .complete),
    };
    try testing.expectEqual(@as(?usize, 0), leader(&entries));
}

test "nothing leads until something has a rate" {
    const entries = [_]Entry{
        entry("a", std.math.nan(f32), .never_ran),
        entry("b", 0, .never_ran),
    };
    try testing.expect(leader(&entries) == null);
}

test "comparison charts remain visible for a slow device and blank without samples" {
    var history: Series = .{ .floor = 20 };
    var phone = entry("phone", 2.5, .complete);
    phone.series = &history;
    const chart_row = tui.bigtext.rows + 4;
    var buf: [256]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    try writeCell(&out, phone, chart_row, 35, false, 1);
    try testing.expect(std.mem.indexOf(u8, out.buffered(), "▇") == null);
    history.push(2.5);
    out = .fixed(&buf);
    try writeCell(&out, phone, chart_row, 35, false, 1);
    try testing.expect(std.mem.indexOf(u8, out.buffered(), "▇") != null);
    try testing.expectEqual(@as(usize, 35), tui.cell.width(out.buffered()));
}

test "columns drop rather than shrink past legibility" {
    // Three devices on a narrow terminal is two readable columns, not
    // three unreadable ones.
    try testing.expectEqual(@as(usize, 3), columnCount(3, 160));
    try testing.expectEqual(@as(usize, 1), columnCount(3, 52));
    try testing.expectEqual(@as(usize, 0), columnCount(0, 120));
    // Whatever it returns, the columns it returns are legible.
    for ([_]usize{ 52, 60, 80, 132, 196 }) |cw| {
        for (1..5) |devices| {
            const n = columnCount(devices, cw);
            try testing.expect(n >= 1 and n <= devices);
            if (n > 1) try testing.expect(columnWidth(n, cw) >= col_w_min);
        }
    }
}

test "no race row overruns its width, at any accepted terminal size" {
    // Same hazard the band had: an overrunning row wraps, and a wrapped
    // row costs the frame a height the dashboard already promised.
    const long = Entry{
        .name = "a-device-with-a-really-long-name",
        .soc = "A-Very-Long-System-On-Chip-Name",
        .rate = 1234.56,
        .tokens = 4_000_000,
        .tokens_total = 4_000_000,
        .elapsed_ns = 999_999_999_999,
        .state = .running,
        .series = &test_series,
        .prime = &test_series,
    };
    const entries = [_]Entry{ long, long, long, long };

    for ([_]usize{ 52, 56, 64, 80, 132, 196 }) |content_w| {
        for (1..entries.len + 1) |n| {
            var buf: [32768]u8 = undefined;
            var out: std.Io.Writer = .fixed(&buf);
            var canvas = tui.Canvas.init(&out, theme.margin, theme.canvas_style);
            try render(&canvas, entries[0..n], content_w, 1);
            const w = widestRow(out.buffered());
            if (w > theme.margin + content_w) {
                std.debug.print(
                    "race overran: content_w={d} devices={d} widest={d}\n",
                    .{ content_w, n, w },
                );
                return error.RaceOverflowsWidth;
            }
            try testing.expectEqual(rowsFor(1), std.mem.count(u8, out.buffered(), "\n"));
        }
    }
}

test "a device name cannot inject terminal commands" {
    var evil = entry("pixel\x1b[2J", 12.0, .running);
    evil.soc = "\x1b]0;pwned\x07";
    var buf: [16384]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    var canvas = tui.Canvas.init(&out, theme.margin, theme.canvas_style);
    try render(&canvas, &.{evil}, 120, 1);
    const text = out.buffered();
    try testing.expect(std.mem.indexOf(u8, text, "\x1b[2J") == null);
    try testing.expect(std.mem.indexOf(u8, text, "\x1b]") == null);
}

test "the rate is set in block glyphs, not text" {
    // The headline shipped as plain text once and read as a table.
    // `▀`-class block glyphs are what make it a headline; if this ever
    // renders as digits again the layout has quietly lost its point.
    const entries = [_]Entry{entry("PHONE01", 41.91, .running)};
    var buf: [16384]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    var canvas = tui.Canvas.init(&out, theme.margin, theme.canvas_style);
    try render(&canvas, &entries, 120, 1);
    const text = out.buffered();

    try testing.expect(std.mem.count(u8, text, "█") > 20);
    // And the literal digits are nowhere in it.
    try testing.expect(std.mem.indexOf(u8, text, "41.91") == null);
    try testing.expect(std.mem.indexOf(u8, text, "avg") != null);
}

test "the leader is the only column in the accent" {
    // Every non-leader drawn in the axis tone was the first attempt,
    // and it made a race read as one device with decoration.
    const entries = [_]Entry{
        entry("slow", 24.76, .complete),
        entry("fast", 57.30, .complete),
    };
    var buf: [16384]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    var canvas = tui.Canvas.init(&out, theme.margin, theme.canvas_style);
    try render(&canvas, &entries, 160, 1);
    const text = out.buffered();

    try testing.expect(std.mem.indexOf(u8, text, theme.spark_lead) != null);
    try testing.expect(std.mem.indexOf(u8, text, theme.spark_rest) != null);
    // The colour a sparkline must never be: it is the chart *axis*,
    // dim enough to vanish against the panel.
    try testing.expect(std.mem.indexOf(u8, text, theme.axis) == null);
}

test "every scale keeps its promised height" {
    // `dashboard.drawRace` reserves rows from `rowsFor` before drawing,
    // so a grid that spends more is a frame taller than the terminal.
    const entries = [_]Entry{ entry("a", 12.0, .running), entry("b", 34.0, .complete) };
    for ([_]usize{ 1, 2 }) |scale| {
        var buf: [32768]u8 = undefined;
        var out: std.Io.Writer = .fixed(&buf);
        var canvas = tui.Canvas.init(&out, theme.margin, theme.canvas_style);
        try render(&canvas, &entries, 160, scale);
        try testing.expectEqual(rowsFor(scale), std.mem.count(u8, out.buffered(), "\n"));
    }
}

test "the digit scale never outgrows the rows it was given" {
    // The two sides of this disagreed once — the scale was picked
    // against the terminal height and the grid was measured against
    // what was left after chrome — and the frame overran by two rows.
    for ([_]usize{ 52, 80, 132, 196 }) |content_w| {
        for (1..4) |devices| {
            for ([_]usize{ 8, 13, 15, 20, 40 }) |grid_rows| {
                const scale = digitScale(devices, content_w, grid_rows);
                if (scale == 2) try testing.expect(rowsFor(2) <= grid_rows);
            }
        }
    }
}

test "each column stacks a decode lane over a prime lane" {
    // Two lanes, in the hero's order and by the hero's reasoning: a
    // rate and a percentage share no unit, so one axis for both would
    // make their relative heights meaningless. Colour is what tells
    // them apart in a column this small — gold family for throughput,
    // teal for load — so a regression that drew both the same would be
    // invisible to a row-count check.
    var decode = Series{};
    var load = Series{};
    for (0..40) |i| {
        decode.push(40.0 + @as(f32, @floatFromInt(i % 7)));
        load.push(@as(f32, @floatFromInt((i * 13) % 100)));
    }
    const entries = [_]Entry{.{
        .name = "PHONE01",
        .soc = "SOC001",
        .rate = 41.91,
        .tokens = 198,
        .tokens_total = 320,
        .elapsed_ns = 4_724_000_000,
        .state = .running,
        .series = &decode,
        .prime = &load,
    }};

    var buf: [16384]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    var canvas = tui.Canvas.init(&out, theme.margin, theme.canvas_style);
    try render(&canvas, &entries, 120, 1);
    const text = out.buffered();

    // A single device leads, so its decode lane takes the accent.
    try testing.expect(std.mem.indexOf(u8, text, theme.spark_lead) != null);
    try testing.expect(std.mem.indexOf(u8, text, theme.spark_prime) != null);

    // And they are on separate rows, decode above load.
    var decode_row: ?usize = null;
    var prime_row: ?usize = null;
    var it = std.mem.splitScalar(u8, text, '\n');
    var i: usize = 0;
    while (it.next()) |line| : (i += 1) {
        if (std.mem.indexOf(u8, line, theme.spark_lead) != null) decode_row = i;
        if (std.mem.indexOf(u8, line, theme.spark_prime) != null) prime_row = i;
    }
    try testing.expect(decode_row != null and prime_row != null);
    try testing.expect(decode_row.? < prime_row.?);
}

test "the accent goes to a column that is actually on screen" {
    // The fastest device can be the one a narrow terminal dropped.
    // Picking the leader from the full list then drawing a prefix of it
    // left the visible race with no winner at all — every column in the
    // non-leader tone and nothing to say why.
    const entries = [_]Entry{
        entry("first", 10.0, .complete),
        entry("second", 20.0, .complete),
        // Fastest, and the one a narrow viewport drops.
        entry("third", 99.0, .complete),
    };

    var buf: [16384]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    var canvas = tui.Canvas.init(&out, theme.margin, theme.canvas_style);
    // Room for one column only.
    try render(&canvas, &entries, 52, 1);
    const text = out.buffered();

    try testing.expectEqual(@as(usize, 1), columnCount(entries.len, 52));
    try testing.expect(std.mem.indexOf(u8, text, theme.spark_lead) != null);
}
