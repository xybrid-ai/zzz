//! Logo panels — half-block mark art, alone or in a row.
//!
//! Standalone rather than folded into the dashboard: the frame that
//! ends up in a tweet is the one people judge the project by, and a
//! mark on screen is what makes it look like a product instead of a
//! debug view. Keeping the panels here means the same code can serve
//! `--logos`, a load-time splash, and eventually a provider mark in
//! the title bar, without any of them owning the art.
//!
//! Note the line buffer. `tui.scratch_len` sizes rows made of text and
//! a couple of SGRs; a colour-per-subpixel row emits up to two
//! truecolor escapes *per cell*, so even one 44-cell mark can want
//! ~1.8 kB and the canvas scratch would truncate it mid-escape.
//! `tui.logo.maxRowBytes` is the bound to size against.

const std = @import("std");
const tui = @import("tuiz");

const theme = @import("theme.zig");

/// Widest strip this can draw, in cells. Bounds the stack buffer
/// below, and is asserted against rather than silently clipping.
pub const max_cells: usize = 128;

const LineBuf = [tui.logo.maxRowBytes(max_cells)]u8;

/// One mark, in whichever of the two art formats suits it.
///
/// The choice is a property of the source, not a preference. Art with
/// colour ramp or gradient of its own has to
/// be a bitmap or it stops being that brand. Art that is a single flat
/// ink has no reason to spend 32 bytes a cell carrying one repeated
/// colour, and vector exports are very often near-black, which on a
/// dark panel means a bitmap renders an invisible mark. Those take the
/// mask and get their ink from the palette.
pub const Mark = union(enum) {
    bitmap: tui.logo.Bitmap,
    mask: Inked,

    pub const Inked = struct { art: tui.logo.Mask, ink: tui.Rgb };

    pub fn cols(self: Mark) usize {
        return switch (self) {
            .bitmap => |b| b.w,
            .mask => |m| m.art.w,
        };
    }

    pub fn rows(self: Mark) usize {
        return switch (self) {
            .bitmap => |b| b.rows(),
            .mask => |m| m.art.rows(),
        };
    }

    pub fn writeRow(self: Mark, w: anytype, row: usize) !void {
        switch (self) {
            .bitmap => |b| try tui.logo.writeBitmapRow(w, b, row),
            .mask => |m| try tui.logo.writeMaskRow(w, m.art, m.ink, row),
        }
    }
};

/// A mark plus what to call it.
pub const Entry = struct {
    label: []const u8,
    mark: Mark,
};

/// Cell height of a single-mark panel, caption included.
pub fn panelRows(mark: Mark) usize {
    return mark.rows() + 2; // art, blank, caption
}

/// Draw one mark centred in `content_w`, with `caption` beneath.
pub fn render(
    canvas: *tui.Canvas,
    mark: Mark,
    caption: []const u8,
    content_w: usize,
) !void {
    try renderStrip(canvas, &.{.{ .label = caption, .mark = mark }}, 0, content_w);
}

/// Draw marks side by side with `gap` cells between them, each label
/// centred under its own mark.
///
/// Marks are bottom-aligned rather than top-aligned: they differ in
/// height, and a shared baseline is what makes a row of them read as a
/// set instead of as debris.
pub fn renderStrip(
    canvas: *tui.Canvas,
    entries: []const Entry,
    gap: usize,
    content_w: usize,
) !void {
    if (entries.len == 0) return;
    const width = stripWidth(entries, gap);
    std.debug.assert(width <= max_cells);

    // Baked art cannot reflow. Drawn into a viewport narrower than
    // itself it wraps, and a wrapped mark does not read as "your
    // terminal is small", it reads as a corrupted frame. Say so
    // instead.
    if (width > content_w) return writeTooNarrow(canvas, entries, width, content_w);

    var line_buf: LineBuf = undefined;
    const indent = theme.margin + centreOffset(width, content_w);

    var tallest: usize = 0;
    for (entries) |e| tallest = @max(tallest, e.mark.rows());

    var row: usize = 0;
    while (row < tallest) : (row += 1) {
        var lw: std.Io.Writer = .fixed(&line_buf);
        try tui.padWidth(&lw, indent);
        for (entries, 0..) |e, i| {
            if (i > 0) try tui.padWidth(&lw, gap);
            // Bottom-align: a shorter mark is blank until its baseline
            // catches up with the tallest one.
            const top_pad = tallest - e.mark.rows();
            if (row < top_pad) {
                try tui.padWidth(&lw, e.mark.cols());
            } else {
                try e.mark.writeRow(&lw, row - top_pad);
            }
        }
        try canvas.row(lw.buffered());
    }

    try canvas.blank();
    try writeLabels(canvas, entries, gap, indent, &line_buf);
}

/// Cells a strip occupies, marks and gaps together.
pub fn stripWidth(entries: []const Entry, gap: usize) usize {
    var w: usize = 0;
    for (entries, 0..) |e, i| {
        if (i > 0) w += gap;
        w += e.mark.cols();
    }
    return w;
}

/// `⟨ Example · Sample needs 99 cells, have 80 ⟩` — what the strip would
/// have drawn, and what it would have taken.
fn writeTooNarrow(
    canvas: *tui.Canvas,
    entries: []const Entry,
    want: usize,
    content_w: usize,
) !void {
    var buf: [tui.scratch_len]u8 = undefined;
    var lw: std.Io.Writer = .fixed(&buf);
    try tui.padWidth(&lw, theme.margin);
    try lw.writeAll(theme.faint);
    for (entries, 0..) |e, i| {
        if (i > 0) try lw.writeAll(" · ");
        try tui.sanitize.write(&lw, e.label);
    }
    try lw.print(" needs {d} cells, have {d}", .{ want, content_w });
    try lw.writeAll(theme.reset);
    try canvas.row(tui.cell.truncate(lw.buffered(), theme.margin + content_w));
}

/// Each label centred under its own mark, on one shared row.
fn writeLabels(
    canvas: *tui.Canvas,
    entries: []const Entry,
    gap: usize,
    indent: usize,
    line_buf: *LineBuf,
) !void {
    var lw: std.Io.Writer = .fixed(line_buf);
    try tui.padWidth(&lw, indent);
    try lw.writeAll(theme.label);
    for (entries, 0..) |e, i| {
        if (i > 0) try tui.padWidth(&lw, gap);
        const slot = e.mark.cols();
        const text = tui.cell.truncate(e.label, slot);
        const lead = centreOffset(tui.cell.width(text), slot);
        try tui.padWidth(&lw, lead);
        try tui.sanitize.write(&lw, text);
        try tui.padWidth(&lw, slot - lead - tui.cell.width(text));
    }
    try lw.writeAll(theme.reset);
    try canvas.row(lw.buffered());
}

/// Left offset that centres `w` cells in `outer`, clamped to 0 so art
/// wider than the viewport starts at the gutter instead of
/// underflowing.
fn centreOffset(w: usize, outer: usize) usize {
    return if (w < outer) (outer - w) / 2 else 0;
}

const testing = std.testing;

const gold = tui.Rgb.hex("#f5c518");
const blank_bitmap = tui.logo.Bitmap{ .w = 4, .h = 4, .px = &(.{tui.logo.transparent} ** 16) };
const blank_mask = tui.logo.Mask{ .w = 4, .h = 8, .bits = &(.{0} ** 8) };

test "a panel is the art's rows plus a blank and a caption" {
    const mark = Mark{ .bitmap = blank_bitmap };
    try testing.expectEqual(@as(usize, 4), panelRows(mark));

    var buf: [8192]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    var canvas = tui.Canvas.init(&out, theme.margin, theme.canvas_style);
    try render(&canvas, mark, "hi", 40);
    try testing.expectEqual(@as(usize, 4), std.mem.count(u8, out.buffered(), "\n"));
}

test "a strip is as tall as its tallest mark, not as tall as the sum" {
    const short = Entry{ .label = "a", .mark = .{ .bitmap = blank_bitmap } }; // 2 rows
    const tall = Entry{ .label = "b", .mark = .{ .mask = .{ .art = blank_mask, .ink = gold } } }; // 4

    var buf: [16384]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    var canvas = tui.Canvas.init(&out, theme.margin, theme.canvas_style);
    try renderStrip(&canvas, &.{ short, tall }, 2, 60);
    // 4 art rows + blank + labels.
    try testing.expectEqual(@as(usize, 6), std.mem.count(u8, out.buffered(), "\n"));
}

test "strip width counts the gaps between marks, not after the last" {
    const e = Entry{ .label = "x", .mark = .{ .bitmap = blank_bitmap } };
    try testing.expectEqual(@as(usize, 4), stripWidth(&.{e}, 3));
    try testing.expectEqual(@as(usize, 11), stripWidth(&.{ e, e }, 3));
    try testing.expectEqual(@as(usize, 18), stripWidth(&.{ e, e, e }, 3));
}

test "a label longer than its mark is truncated, not spilled into the neighbour" {
    // Without the clamp the label would push every mark after it out of
    // column, which reads as a corrupted frame rather than a long name.
    // The invariant is that the label row measures exactly what an art
    // row measures — same indent, same slots, same total.
    const e = Entry{ .label = "an extremely long provider name", .mark = .{ .bitmap = blank_bitmap } };
    var buf: [16384]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    var canvas = tui.Canvas.init(&out, theme.margin, theme.canvas_style);
    try renderStrip(&canvas, &.{ e, e }, 2, 60);

    var first_art: []const u8 = "";
    var labels: []const u8 = "";
    var it = std.mem.splitScalar(u8, out.buffered(), '\n');
    while (it.next()) |line| if (line.len > 0) {
        if (first_art.len == 0) first_art = line;
        labels = line;
    };

    const erase = "\x1b[K".len;
    try testing.expectEqual(
        tui.cell.width(first_art[0 .. first_art.len - erase]),
        tui.cell.width(labels[0 .. labels.len - erase]),
    );
}

test "art wider than the viewport starts at the gutter rather than underflowing" {
    try testing.expectEqual(@as(usize, 0), centreOffset(80, 40));
    try testing.expectEqual(@as(usize, 5), centreOffset(30, 40));
}

test "a mark too wide for the viewport says so instead of wrapping" {
    // Wrapping baked art reads as a corrupted frame, so the panel has
    // to refuse rather than try.
    const wide = tui.logo.Bitmap{ .w = 40, .h = 2, .px = &(.{tui.logo.transparent} ** 80) };
    const e = Entry{ .label = "Wide", .mark = .{ .bitmap = wide } };
    var buf: [8192]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    var canvas = tui.Canvas.init(&out, theme.margin, theme.canvas_style);
    try renderStrip(&canvas, &.{e}, 0, 30);

    const rendered = out.buffered();
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, rendered, "\n"));
    try testing.expect(std.mem.indexOf(u8, rendered, "Wide") != null);
    try testing.expect(std.mem.indexOf(u8, rendered, "40") != null);
    // And the note must itself fit, or the guard has the bug it exists
    // to stop.
    const line = rendered[0 .. rendered.len - "\x1b[K\n".len];
    try testing.expect(tui.cell.width(line) <= theme.margin + 30);
}

test "a full-width colour row survives the line buffer" {
    // The regression this guards: sizing against `tui.scratch_len`
    // truncates a wide bitmap row part-way through an escape sequence,
    // which paints the rest of the frame in whatever colour it landed
    // on. Alternating colours defeat SGR coalescing, so this is the
    // worst case the buffer has to hold.
    var px: [max_cells * 2]?tui.Rgb = undefined;
    for (&px, 0..) |*p, i| {
        p.* = if (i % 2 == 0) gold else tui.Rgb.hex("#2dd4bf");
    }
    const art = tui.logo.Bitmap{ .w = max_cells, .h = 2, .px = &px };

    var line_buf: LineBuf = undefined;
    var lw: std.Io.Writer = .fixed(&line_buf);
    try tui.logo.writeBitmapRow(&lw, art, 0);
    try testing.expectEqual(max_cells, tui.cell.width(lw.buffered()));
    try testing.expect(lw.buffered().len > tui.scratch_len);
}
