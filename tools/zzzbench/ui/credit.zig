//! The credit plate: a provider mark over the model it is running.
//!
//! Two text rows under the art, in descending weight — the model, then
//! who made it and at what precision. The hierarchy is the whole
//! point: at a glance the plate answers "what model is this", and only
//! on a second look "whose, and at what precision".
//!
//! The engine is deliberately not a third row. It is already named in
//! the title bar, and the plate exists to credit the model's maker —
//! a line saying who ran it pulls against that.
//!
//! Sized and drawn a row at a time rather than as a block, because the
//! hero writes the frame row-major: every column on a row is emitted
//! before the next row starts, so a widget that could only draw itself
//! all at once could not sit beside the chart.

const std = @import("std");
const tui = @import("tuiz");

const splash = @import("splash.zig");
const theme = @import("theme.zig");

/// Rows of text under the art.
const text_rows: usize = 2;
/// Blank row between the art and the text.
const gap_rows: usize = 1;

/// Longest a text line may be before it is cut. Model names off a
/// model card are unbounded, and one long enough to widen the plate
/// would take the width out of the chart.
pub const text_w_max: usize = 28;

/// Widest a plate can be, art included. The art is what sets this —
/// `--logo zzz` puts a 56-cell bitmap on the plate, twice `text_w_max`
/// — so any buffer sized for a plate row must be sized from here and
/// not from the text cap.
pub const max_plate_w: usize = splash.max_cells;

/// Scratch for one filtered text line. `sanitize` never grows a
/// string in bytes — each dangerous sequence collapses to one `?` —
/// so `text_w_max` cells of 4-byte code points is a safe ceiling.
const TextBuf = [4 * text_w_max]u8;

/// Filter, then clamp to `cells`.
///
/// The order matters and is the whole point of this helper. `cell.width`
/// skips CSI sequences as zero-width, but `sanitize.write` renders each
/// one as a visible `?`. Measuring or truncating the raw string
/// therefore under-counts, and the row emitted from that measurement
/// comes out wider than the plate it was centred in — shifting every
/// column drawn after it. Model names arrive from the probe's `Hello`,
/// so this is reachable from the wire.
fn filtered(buf: *TextBuf, s: []const u8, cells: usize) []const u8 {
    return tui.cell.truncate(tui.sanitize.into(buf, s), cells);
}

/// How the art and its two text lines are arranged.
pub const Layout = enum {
    /// Art over the text, both centred. For a plate in its own narrow
    /// column beside the chart, where width is what is scarce.
    stacked,
    /// Art with the text beside it. For the plate sitting in the slack
    /// above the number, where the scarce thing is rows and the mark
    /// should hug the figure it credits rather than float two rows off
    /// it.
    beside,
};

/// Cells between the art and text set beside it.
const beside_gap: usize = 2;
/// Least text worth setting beside the art. Below this the layout is
/// not a credit, it is a smear, and the caller should pick `stacked`
/// or drop the plate.
pub const beside_text_min: usize = 8;

pub const Credit = struct {
    mark: splash.Mark,
    layout: Layout = .stacked,
    /// A smaller cut of the same mark, for when the headline digits are
    /// at single size and `mark` would tower over them. Null for marks
    /// with no legible smaller bake — they are dropped instead.
    mark_sm: ?splash.Mark = null,
    /// `Neutrino-0.6B` — the headline, brightest row.
    model: []const u8,
    /// `Example · Q4_K_M` — who made it and at what precision.
    detail: []const u8,

    /// The largest cut of this mark within `max_art_rows`, or null if
    /// even the smallest is too tall.
    ///
    /// Shrinking beats dropping. The proportion rule exists so the logo
    /// never overpowers the number, and on a terminal too narrow for
    /// double-size digits that ceiling is only five rows — which the
    /// preferred cut exceeds, so enforcing the rule by dropping alone
    /// meant `--logo` drew nothing at all below 200 columns.
    pub fn forDigits(self: Credit, max_art_rows: usize) ?Credit {
        if (self.mark.rows() <= max_art_rows) return self;
        const small = self.mark_sm orelse return null;
        if (small.rows() > max_art_rows) return null;
        var out = self;
        out.mark = small;
        return out;
    }

    /// Widest of the two credit lines, filtered and clamped.
    fn textWidth(self: Credit) usize {
        var w: usize = 0;
        for ([_][]const u8{ self.model, self.detail }) |s| {
            var buf: TextBuf = undefined;
            w = @max(w, tui.cell.width(filtered(&buf, s, text_w_max)));
        }
        return w;
    }

    /// Cells the plate occupies.
    pub fn width(self: Credit) usize {
        return switch (self.layout) {
            .stacked => @max(self.mark.cols(), self.textWidth()),
            .beside => self.mark.cols() + beside_gap + self.textWidth(),
        };
    }

    /// Rows the plate occupies.
    pub fn rows(self: Credit) usize {
        return switch (self.layout) {
            .stacked => self.mark.rows() + gap_rows + text_rows,
            // The text is set inside the art's own height, so a beside
            // plate is exactly as tall as its mark — three rows shorter
            // than the stacked form, which is most of why it fits in
            // the slack over the number.
            .beside => @max(self.mark.rows(), text_rows),
        };
    }
};

/// Write row `r` of the plate into `lw`, padded to exactly `plate_w`
/// cells so whatever follows on the line still starts in column.
/// Rows past the plate's height emit blanks, since the hero band is
/// usually taller than the plate.
pub fn writeRow(lw: anytype, c: Credit, plate_w: usize, r: usize) !void {
    const start = tui.cell.width(lw.buffered());
    if (c.layout == .beside) {
        try writeBesideRow(lw, c, start, plate_w, r);
        try tui.cell.padTo(lw, start + plate_w);
        return;
    }

    const art_rows = c.mark.rows();
    if (r < art_rows) {
        // Art is centred over the text rather than flush left: a
        // narrow mark hard against the chart edge reads as an
        // accident, not a plate.
        try tui.padWidth(lw, centreOffset(c.mark.cols(), plate_w));
        try c.mark.writeRow(lw, r);
    } else if (r >= art_rows + gap_rows) {
        const i = r - art_rows - gap_rows;
        if (i < text_rows) {
            const text = if (i == 0) c.model else c.detail;
            const color = if (i == 0) theme.text else theme.sub;
            var text_buf: TextBuf = undefined;
            const cut = filtered(&text_buf, text, @min(plate_w, text_w_max));
            try tui.padWidth(lw, centreOffset(tui.cell.width(cut), plate_w));
            try lw.writeAll(color);
            // Already filtered — writing it raw would double-escape.
            try lw.writeAll(cut);
            try lw.writeAll(theme.reset);
        }
    }

    // Pad the plate out to its full width whatever it drew, including
    // nothing at all.
    try tui.cell.padTo(lw, start + plate_w);
}

/// `[art] model` / `[art] detail` — the text set beside the mark and
/// centred against its height.
fn writeBesideRow(lw: anytype, c: Credit, start: usize, plate_w: usize, r: usize) !void {
    const art_rows = c.mark.rows();
    const art_w = c.mark.cols();
    if (r < art_rows) try c.mark.writeRow(lw, r);

    const text_top = (art_rows -| text_rows) / 2;
    if (r < text_top or r - text_top >= text_rows) return;
    // The column may be narrower than the plate asked for; cut the text
    // rather than overrun, since the art is the part that cannot flex.
    const room = plate_w -| (art_w + beside_gap);
    if (room == 0) return;

    const i = r - text_top;
    const text = if (i == 0) c.model else c.detail;
    const color = if (i == 0) theme.text else theme.sub;
    var text_buf: TextBuf = undefined;
    const cut = filtered(&text_buf, text, @min(room, text_w_max));
    // Absolute column: the plate does not necessarily begin at zero.
    try tui.cell.padTo(lw, start + art_w + beside_gap);
    try lw.writeAll(color);
    try lw.writeAll(cut);
    try lw.writeAll(theme.reset);
}

fn centreOffset(w: usize, outer: usize) usize {
    return if (w < outer) (outer - w) / 2 else 0;
}

const testing = std.testing;

const test_mark = splash.Mark{ .bitmap = .{
    .w = 6,
    .h = 4,
    .px = &(.{tui.logo.transparent} ** 24),
} };

fn testCredit() Credit {
    return .{
        .mark = test_mark,
        .model = "Neutrino-0.6B",
        .detail = "Example · Q4_K_M",
    };
}

test "the plate is as wide as its widest line, art included" {
    const c = testCredit();
    // `Example · Q4_K_M` is 16 cells; the art is 6.
    try testing.expectEqual(@as(usize, 16), c.width());
    try testing.expectEqual(@as(usize, 2 + 1 + 2), c.rows());
}

test "every row is padded to the plate width, drawn or not" {
    // The hero writes row-major, so a plate row that came up short
    // would shift whatever is drawn after it on that line.
    const c = testCredit();
    const plate_w = c.width();
    var r: usize = 0;
    while (r < c.rows() + 3) : (r += 1) {
        var buf: [4096]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        try writeRow(&w, c, plate_w, r);
        try testing.expectEqual(plate_w, tui.cell.width(w.buffered()));
    }
}

test "a plate row respects a caller's existing column" {
    // `padTo` works in absolute columns, so the plate has to measure
    // from wherever the line already is rather than from zero.
    const c = testCredit();
    var buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try tui.padWidth(&w, 7);
    try writeRow(&w, c, c.width(), 0);
    try testing.expectEqual(7 + c.width(), tui.cell.width(w.buffered()));
}

test "an overlong model name is cut rather than widening the plate" {
    var c = testCredit();
    c.model = "a-model-name-far-longer-than-any-plate-should-carry";
    try testing.expectEqual(text_w_max, c.width());

    var buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeRow(&w, c, c.width(), c.mark.rows() + gap_rows);
    try testing.expectEqual(text_w_max, tui.cell.width(w.buffered()));
}

test "control bytes in credit text cannot widen the plate" {
    // `cell.width` skips CSI sequences, but `sanitize.write` turns the
    // ESC into a visible `?`. Measuring before filtering therefore
    // under-counts, and the emitted row comes out wider than the plate
    // it was centred in — which shifts every column after it.
    var c = testCredit();
    c.model = "\x1b[31mowned\x1b[0m";
    c.detail = "\x1b]0;title\x07x";

    const plate_w = c.width();
    var r: usize = 0;
    while (r < c.rows()) : (r += 1) {
        var buf: [4096]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        try writeRow(&w, c, plate_w, r);
        try testing.expectEqual(plate_w, tui.cell.width(w.buffered()));
    }
}

test "a mark too tall for the digits shrinks before it is dropped" {
    // The regression this pins: enforcing the proportion rule by
    // dropping alone meant `--logo` drew nothing below 200 columns,
    // because that is where the headline digits fall to single size and
    // the ceiling with them.
    const tall = splash.Mark{ .bitmap = .{ .w = 4, .h = 14, .px = &(.{tui.logo.transparent} ** 56) } }; // 7 rows
    const small = splash.Mark{ .bitmap = .{ .w = 4, .h = 10, .px = &(.{tui.logo.transparent} ** 40) } }; // 5 rows

    var c = testCredit();
    c.mark = tall;
    c.mark_sm = small;

    // Roomy: the preferred cut is kept.
    try testing.expectEqual(@as(usize, 7), c.forDigits(11).?.mark.rows());
    try testing.expectEqual(@as(usize, 7), c.forDigits(7).?.mark.rows());
    // Tight: it shrinks rather than vanishing.
    try testing.expectEqual(@as(usize, 5), c.forDigits(6).?.mark.rows());
    try testing.expectEqual(@as(usize, 5), c.forDigits(5).?.mark.rows());
    // Tighter than even the small cut: nothing is drawn.
    try testing.expect(c.forDigits(4) == null);

    // A mark with no small cut is dropped at the first ceiling it
    // exceeds.
    var no_small = c;
    no_small.mark_sm = null;
    try testing.expect(no_small.forDigits(7) != null);
    try testing.expect(no_small.forDigits(5) == null);
}

test "a beside plate sets its text next to the art, not under it" {
    var c = testCredit();
    c.layout = .beside;
    // Two rows of art, so the layout is as tall as the art and no more.
    try testing.expectEqual(c.mark.rows(), c.rows());
    try testing.expectEqual(
        c.mark.cols() + beside_gap + tui.cell.width("Example · Q4_K_M"),
        c.width(),
    );

    // Every row is padded to the plate width, from wherever the line
    // already was — the art cannot flex, so a column that starts late
    // must not shift it.
    const plate_w = c.width();
    for ([_]usize{ 0, 9 }) |indent| {
        var r: usize = 0;
        while (r < c.rows() + 2) : (r += 1) {
            var buf: [4096]u8 = undefined;
            var w: std.Io.Writer = .fixed(&buf);
            try tui.padWidth(&w, indent);
            try writeRow(&w, c, plate_w, r);
            try testing.expectEqual(indent + plate_w, tui.cell.width(w.buffered()));
        }
    }
}

test "a beside plate cuts its text when the column is short" {
    // The art is fixed; the text is what gives. Overrunning here would
    // push the chart column out of line on every row of the plate.
    var c = testCredit();
    c.layout = .beside;
    const narrow = c.mark.cols() + beside_gap + 4;
    var buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeRow(&w, c, narrow, 0);
    try testing.expectEqual(narrow, tui.cell.width(w.buffered()));
}
