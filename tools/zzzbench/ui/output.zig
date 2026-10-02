//! The OUTPUT panel: the text the model actually generated.
//!
//! Every other band on this dashboard renders numbers the bench
//! computed. This one renders bytes a model produced, forwarded by a
//! probe the bench does not control — the least trusted text in the
//! system, landing in a terminal. So it goes through `sanitize` like
//! every probe-supplied name, and every row is width-clipped like
//! every other row.
//!
//! It shows the *tail*, not the beginning. A run generates far more
//! text than a panel can hold, and the interesting end of a stream you
//! are watching live is the end.

const std = @import("std");
const tui = @import("tuiz");

const theme = @import("theme.zig");

/// Rows of prose. Enough to read a couple of sentences without the
/// panel competing with the hero for the frame.
pub const text_rows: usize = 4;

/// Rows the panel occupies: a blank, the section heading, the text,
/// and a blank beneath. The leading blank is the same fix the peer
/// heading needed — without it the heading butts onto the rule above
/// and reads as part of the hero.
pub const rows: usize = text_rows + 3;

/// Longest line the wrapper will emit, which bounds the scratch a row
/// needs. Beyond the dashboard's 200-column cap there is nothing to
/// draw, so clipping here costs nothing real.
const max_line_cells: usize = 240;

/// Bytes of the tail the panel looks at. Four rows of the widest line,
/// at the worst case of 4 bytes per cell, is already more than can be
/// shown; anything before that cannot reach the screen, so wrapping it
/// would be work with no output.
const considered_bytes: usize = text_rows * max_line_cells * 4;

pub const Panel = struct {
    /// The retained tail of the run's output.
    text: []const u8,
    /// Older text was dropped to make room.
    truncated: bool,
    /// The engine sent its terminator: this is the whole (retained)
    /// output rather than a stream still arriving.
    complete: bool,
    /// A chunk went missing on the way here. Worth saying, because
    /// dropped text reads as fluent prose — there is nothing in the
    /// result to notice.
    gap: bool,
    /// A run is in flight, so an empty panel means "not yet" rather
    /// than "nothing".
    running: bool,
};

pub fn render(canvas: *tui.Canvas, panel: Panel, content_w: usize) !void {
    try canvas.blank();
    try canvas.section("OUTPUT", content_w);

    if (panel.text.len == 0) {
        try writeNote(canvas, if (panel.running)
            "waiting for the first token..."
        else
            "no output captured — run with --prompt to ask for text", content_w);
        var blanks: usize = text_rows - 1;
        while (blanks > 0) : (blanks -= 1) try canvas.blank();
        try canvas.blank();
        return;
    }

    // Sanitize once, up front, and wrap the result. Wrapping the raw
    // bytes and filtering per row would measure a different string
    // than it drew: `cell.width` skips an escape as zero cells, while
    // `sanitize` renders it as a visible `?`.
    var clean_buf: [considered_bytes]u8 = undefined;
    const clean = filterKeepingNewlines(&clean_buf, tail(panel.text));

    var lines: [text_rows][]const u8 = @splat("");
    const count = lastLines(clean, content_w, &lines);

    // Bottom-align: a partly-filled panel keeps its text against the
    // heading rather than floating in the middle of the band.
    for (lines[0..count]) |line| try writeText(canvas, line, content_w);
    var pad = text_rows - count;
    while (pad > 0) : (pad -= 1) try canvas.blank();

    if (panel.truncated or panel.gap) {
        try writeNote(canvas, if (panel.gap)
            "chunks were dropped in transit — text is incomplete"
        else
            "showing the tail; earlier output was dropped", content_w);
    } else {
        try canvas.blank();
    }
}

/// Filter the text a terminal must not interpret, but keep newlines.
///
/// `sanitize` treats a newline as a control byte, which is right for
/// every other field on this dashboard — a name containing one would
/// break the row it sits in. Here the newline is *content*: the model
/// wrote it, and it is the only paragraph structure the output has.
/// Rendering it as `?` did not just look wrong, it collapsed a
/// multi-line answer onto one line.
///
/// So newlines survive to the wrapper, which turns each into a row
/// break, and no row ever carries one.
fn filterKeepingNewlines(buf: []u8, text: []const u8) []const u8 {
    var used: usize = 0;
    var rest = text;
    while (rest.len > 0 and used < buf.len) {
        const nl = std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len;
        const clean = tui.sanitize.into(buf[used..], rest[0..nl]);
        used += clean.len;
        if (nl == rest.len) break;
        if (used < buf.len) {
            buf[used] = '\n';
            used += 1;
        }
        rest = rest[nl + 1 ..];
    }
    return buf[0..used];
}

/// The last `considered_bytes` of `text`, advanced to a code-point
/// boundary so the cut never lands mid-glyph.
fn tail(text: []const u8) []const u8 {
    if (text.len <= considered_bytes) return text;
    var start = text.len - considered_bytes;
    while (start < text.len and text[start] & 0xc0 == 0x80) start += 1;
    return text[start..];
}

fn writeText(canvas: *tui.Canvas, line: []const u8, content_w: usize) !void {
    // Sized for bytes, not cells. `truncate` bounds what it emits in
    // *cells*, and combining or formatting code points are zero cells
    // at up to four bytes each — model output stuffed with them is a
    // line whose byte length only the retained tail bounds. A buffer
    // sized `cells * 4` failed the whole frame on exactly that input.
    var buf: [considered_bytes + 64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try tui.padWidth(&w, theme.margin);
    try w.writeAll(theme.text);
    try w.writeAll(tui.cell.truncate(line, content_w));
    try w.writeAll(tui.color.reset);
    try canvas.row(w.buffered());
}

/// Notes are fixed strings, but the narrowest accepted panel is
/// narrower than the longest of them — the empty-state hint alone is
/// 52 cells against 51 of content at `min_cols` — so they clip like
/// every other row rather than wrapping and costing an unbudgeted row.
fn writeNote(canvas: *tui.Canvas, note: []const u8, content_w: usize) !void {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try tui.padWidth(&w, theme.margin);
    try w.writeAll(theme.faint);
    try w.writeAll(tui.cell.truncate(note, content_w));
    try w.writeAll(tui.color.reset);
    try canvas.row(w.buffered());
}

/// Wrap `text` to `width` and keep the last `out.len` lines, in order.
/// Returns how many were filled.
///
/// The wrap is greedy and breaks on spaces where it can, hard-breaks
/// where it cannot (a URL, or CJK, which carries no spaces at all).
/// Explicit newlines in the model's output are honoured — they are
/// part of what it wrote.
pub fn lastLines(text: []const u8, width: usize, out: [][]const u8) usize {
    const w = @max(1, @min(width, max_line_cells));
    var ring_len: usize = 0;
    var next: usize = 0;

    var rest = text;
    while (rest.len > 0) {
        const line = takeLine(rest, w);
        // Ring, so a long run costs no more than the panel's height.
        out[next] = trimTrailingSpaces(rest[0..line.len]);
        next = (next + 1) % out.len;
        if (ring_len < out.len) ring_len += 1;
        rest = rest[line.advance..];
    }

    if (ring_len < out.len) return ring_len;

    // Ring wrapped: rotate so the oldest retained line is first.
    var ordered: [64][]const u8 = undefined;
    std.debug.assert(out.len <= ordered.len);
    for (0..ring_len) |i| ordered[i] = out[(next + i) % out.len];
    for (0..ring_len) |i| out[i] = ordered[i];
    return ring_len;
}

/// Trailing spaces are an artefact of where the wrap fell, not text
/// the model wrote, and a coloured run of them shows up as a smear on
/// some terminals.
fn trimTrailingSpaces(s: []const u8) []const u8 {
    var end = s.len;
    while (end > 0 and s[end - 1] == ' ') end -= 1;
    return s[0..end];
}

const Take = struct {
    /// Bytes of `text` that belong to this line.
    len: usize,
    /// Bytes to skip to reach the next line, including a consumed
    /// newline or the space that was broken on.
    advance: usize,
};

fn takeLine(text: []const u8, width: usize) Take {
    var cells: usize = 0;
    var i: usize = 0;
    var last_space: ?usize = null;

    while (i < text.len) {
        if (text[i] == '\n') return .{ .len = i, .advance = i + 1 };
        if (text[i] == ' ') last_space = i;

        // The same display unit `truncate` uses — an emoji plus its
        // VS16 is one two-cell step here, so a wrap can never fall
        // between the base and the selector and hand `writeText` a
        // line it measures differently than this loop did.
        const unit = tui.cell.step(text[i..]);
        const end = @min(text.len, i + @max(unit.bytes, 1));
        cells += unit.cells;
        if (cells > width) {
            // Break at the last space if there was one, so words stay
            // whole; otherwise hard-break at the cell that overflowed.
            if (last_space) |s| return .{ .len = s, .advance = s + 1 };
            // Except for the first glyph of a line: a double-width
            // glyph in a one-cell column overflows immediately, and
            // breaking before it would advance nothing and spin.
            if (i == 0) return .{ .len = end, .advance = end };
            return .{ .len = i, .advance = i };
        }
        i = end;
    }
    return .{ .len = text.len, .advance = text.len };
}

test "wrapping breaks on spaces and keeps whole words" {
    var lines: [4][]const u8 = @splat("");
    const n = lastLines("the bonsai is a full tree", 12, &lines);
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqualStrings("the bonsai", lines[0]);
    try std.testing.expectEqualStrings("is a full", lines[1]);
    try std.testing.expectEqualStrings("tree", lines[2]);
}

test "a word longer than the width hard-breaks rather than vanishing" {
    var lines: [4][]const u8 = @splat("");
    const n = lastLines("aaaaaaaaaa", 4, &lines);
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqualStrings("aaaa", lines[0]);
    try std.testing.expectEqualStrings("aaaa", lines[1]);
    try std.testing.expectEqualStrings("aa", lines[2]);
}

test "the model's own newlines are honoured" {
    var lines: [4][]const u8 = @splat("");
    const n = lastLines("one\ntwo", 40, &lines);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualStrings("one", lines[0]);
    try std.testing.expectEqualStrings("two", lines[1]);
}

test "only the last lines survive, in order" {
    var lines: [4][]const u8 = @splat("");
    const n = lastLines("l1\nl2\nl3\nl4\nl5\nl6", 40, &lines);
    try std.testing.expectEqual(@as(usize, 4), n);
    try std.testing.expectEqualStrings("l3", lines[0]);
    try std.testing.expectEqualStrings("l4", lines[1]);
    try std.testing.expectEqualStrings("l5", lines[2]);
    try std.testing.expectEqualStrings("l6", lines[3]);
}

test "an escape in model output is neutralised, not rendered" {
    var buf: [4096]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    var canvas = tui.Canvas.init(&out, theme.margin, theme.canvas_style);
    // OSC 52 would write the user's clipboard from a model's output.
    try render(&canvas, .{
        .text = "safe\x1b]52;c;cGF5bG9hZA==\x07tail",
        .truncated = false,
        .complete = true,
        .gap = false,
        .running = false,
    }, 60);

    const frame = out.buffered();
    // The escape that starts the sequence is what makes it a command;
    // with it filtered, the rest is inert text on the row.
    try std.testing.expect(std.mem.indexOf(u8, frame, "\x1b]") == null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "safe") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "tail") != null);
}

test "a newline the model wrote breaks a row; an escape does not survive" {
    var buf: [4096]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    var canvas = tui.Canvas.init(&out, theme.margin, theme.canvas_style);
    try render(&canvas, .{
        .text = "first\x1b[2Jline\nsecond line",
        .truncated = false,
        .complete = true,
        .gap = false,
        .running = false,
    }, 60);

    const frame = out.buffered();
    // Both halves of the model's text are on screen...
    try std.testing.expect(std.mem.indexOf(u8, frame, "second line") != null);
    // ...as separate rows, not joined by a rendered `?`.
    try std.testing.expect(std.mem.indexOf(u8, frame, "line?second") == null);
    // The clear-screen escape is gone; a `?` stands where its ESC was,
    // and what is left is inert text on the row.
    try std.testing.expect(std.mem.indexOf(u8, frame, "\x1b[2J") == null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "first?[2Jline") != null);
}

test "the panel spends exactly the rows it advertises" {
    for ([_]Panel{
        .{ .text = "", .truncated = false, .complete = false, .gap = false, .running = true },
        .{ .text = "short", .truncated = false, .complete = true, .gap = false, .running = false },
        .{ .text = "l1\nl2\nl3\nl4\nl5\nl6", .truncated = true, .complete = true, .gap = false, .running = false },
        .{ .text = "dropped", .truncated = false, .complete = true, .gap = true, .running = false },
    }) |panel| {
        var buf: [16384]u8 = undefined;
        var out: std.Io.Writer = .fixed(&buf);
        var canvas = tui.Canvas.init(&out, theme.margin, theme.canvas_style);
        try render(&canvas, panel, 60);
        try std.testing.expectEqual(rows, std.mem.count(u8, out.buffered(), "\n"));
    }
}

test "an emoji presentation pair never splits at a wrap" {
    // `takeLine` advances by `cell.step`, the same unit `truncate`
    // measures by. Stepping base and VS16 separately let a wrap fall
    // between them — the base ended one line and the selector opened
    // the next, and the pair measured differently than it drew.
    const pair = "\u{2764}\u{FE0F}"; // ❤ + VS16: one two-cell glyph
    var text_buf: [128]u8 = undefined;
    var tw: std.Io.Writer = .fixed(&text_buf);
    // Words sized so the pair lands exactly at the width limit.
    tw.writeAll("abcd " ++ pair ++ pair ++ " tail") catch unreachable;

    var lines: [4][]const u8 = @splat("");
    const n = lastLines(tw.buffered(), 6, &lines);
    for (lines[0..n]) |line| {
        // No line may end between a base and its selector: a trailing
        // heart must carry its VS16 with it.
        if (std.mem.endsWith(u8, line, "\u{2764}")) return error.SplitPresentation;
        try std.testing.expect(tui.cell.width(line) <= 6);
    }
}

test "model output stuffed with zero-width marks renders instead of failing" {
    // `truncate` bounds cells, and combining marks are zero cells at
    // two bytes each — a line of them is bounded by bytes retained,
    // not by width. The row scratch sized `cells * 4` failed the whole
    // frame on exactly this input.
    var text_buf: [3000]u8 = undefined;
    var i: usize = 0;
    text_buf[0] = 'a';
    i = 1;
    while (i + 2 <= text_buf.len) : (i += 2) {
        text_buf[i] = 0xCC; // U+0300 combining grave accent
        text_buf[i + 1] = 0x80;
    }

    var buf: [32768]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    var canvas = tui.Canvas.init(&out, theme.margin, theme.canvas_style);
    try render(&canvas, .{
        .text = text_buf[0..i],
        .truncated = false,
        .complete = true,
        .gap = false,
        .running = false,
    }, 60);
    try std.testing.expectEqual(rows, std.mem.count(u8, out.buffered(), "\n"));
}

test "notes clip to the panel width like every other row" {
    // The empty-state hint is longer than the narrowest accepted panel;
    // unclipped it wrapped and cost a row the height budget had already
    // spent.
    var buf: [16384]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    var canvas = tui.Canvas.init(&out, theme.margin, theme.canvas_style);
    try render(&canvas, .{
        .text = "",
        .truncated = false,
        .complete = false,
        .gap = false,
        .running = false,
    }, 51);

    var it = std.mem.splitScalar(u8, out.buffered(), '\n');
    while (it.next()) |line| {
        try std.testing.expect(tui.cell.width(line) <= theme.margin + 51);
    }
}
