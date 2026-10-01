//! The hero block: a display-sized tok/s figure on the left, a
//! full-height area chart behind it on the right.
//!
//! Four states share the geometry. While a run is live the number is
//! gold and a token progress bar sits on the chart's baseline; once it
//! finishes the number dims to teal and holds the run average, and the
//! bar becomes a call to action; before any run, and after one that
//! ended without a result, there is no figure to show but the layout
//! is already in place.
//!
//! To their right are two stacked lanes: decode rate above,
//! prime-core load below, each with its own baseline, its own
//! normaliser, and a caption naming both. They are two lanes rather
//! than one because a rate and a percentage share no unit — on a
//! single axis their relative heights would mean nothing. Both are
//! sampled on the same telemetry tick, so column N is the same
//! instant in each and the pair can be read against one another
//! vertically.
//!
//! Nothing here depends on run state: `measure` takes no `running`
//! flag, and the caption row, digit scale and band height are all
//! sized for the taller of the two states, so a run starting or
//! ending moves nothing on screen.

const std = @import("std");
const proto = @import("proto");
const tui = @import("tuiz");

const credit = @import("credit.zig");
const engine_mod = @import("../engine.zig");
const Series = @import("../series.zig").Series;
const theme = @import("theme.zig");
const UiState = @import("state.zig").UiState;

/// Left column bounds. A third of the width matches the mock's
/// 361/1280 split, so the number scales with the terminal instead of
/// leaving a void between a small figure and a far-right chart.
const left_w_min: usize = 36;
const left_w_max: usize = 72;

/// Thresholds for doubling the digit font (each font pixel becomes
/// 4×2 cells). Below these the big number would collide with the
/// chart column.
const big_font_left_w: usize = 64;
const big_font_chart_rows: usize = 12;
const big_font_term_rows: usize = 30;

/// Minimum chart width worth spending a row on the caption.
const chart_caption_min_w: usize = 34;

/// Narrowest chart still worth drawing. Below this the left column
/// takes the width instead — a six-cell chart reads as noise.
const chart_w_min: usize = 24;

/// The left column is sized against the widest figure `formatRate`
/// can produce (four digits and a point) rather than the number
/// currently on screen. Sizing against the live value would make the
/// column — and therefore the chart — change width as the rate moved
/// through 9.99 → 12.34 → 123.4 mid-run.
const number_template = "00.00";

/// Cells the unit stack needs to the right of the digits: two of
/// padding plus `decode`, the longer of the two labels.
const unit_stack_w: usize = 2 + "decode".len;

/// Width the left column must have for `scale` digits plus their unit
/// stack. The leading cell is the space before the first glyph.
fn leftContentWidth(scale: usize) usize {
    return 1 + tui.bigtext.measure(number_template, scale) + unit_stack_w;
}

/// Everything the hero draws from.
pub const View = struct {
    frame: *const proto.TelemetryFrame,
    /// Top lane: decode rate, one sample per telemetry tick, 0 when no
    /// run is producing one.
    tok_lane: *const Series,
    /// Bottom lane: prime-core utilisation, same clock.
    prime_lane: *const Series,
    telemetry_available: bool = true,
    engine: engine_mod.Engine,
    compare: ?engine_mod.Engine,
    running: bool,
    needs_model: bool = false,
    /// The credit plate, when `--logo` named one and the placement put
    /// it in the band. Null for the `top` and `off` placements.
    credit: ?credit.Credit = null,
};

/// Where one lane sits inside the band. A lane is a caption row, a
/// body, and a baseline axis.
pub const Lane = struct {
    caption_row: usize,
    body_top: usize,
    body_rows: usize,
    axis_row: usize,
};

/// Rows a lane spends on chrome: its caption and its axis.
const lane_chrome_rows: usize = 2;
/// Shortest body worth drawing. Two rows of eighth-blocks read as a
/// smudge; below this the band carries one lane instead of two.
const lane_body_min: usize = 3;

/// Where the credit plate sits relative to the number and the chart.
///
/// `above` is the odd one: it costs no width and usually no height
/// either. The left column bottom-aligns against the last lane's
/// baseline, so on any terminal tall enough for a real chart there is
/// already slack above the number — `left_top` rows of it. The plate
/// drops into that gap instead of pushing the whole block down.
pub const PlateSide = enum { off, left, right, above };

/// Cells between the plate and whatever it sits against.
const plate_gap: usize = 2;

/// Row-by-row geometry, resolved once per frame so the render loop
/// stays a straight walk down the block.
pub const Metrics = struct {
    left_w: usize,
    chart_w: usize,
    /// 0 when no plate is drawn in the band.
    plate_w: usize = 0,
    plate_side: PlateSide = .off,
    left_top: usize,
    digit_rows: usize,
    num_scale: usize,
    compare_rows: usize,
    /// 2 when the band can hold both lanes, 1 when only the decode
    /// lane fits, 0 when the terminal is too narrow for any chart.
    lane_count: usize,
    lanes: [2]Lane,
    rows: usize,

    /// Absolute column the number's block starts in. A left-hand plate
    /// pushes everything else across; a right-hand one changes nothing
    /// before it.
    fn leftX(self: Metrics) usize {
        return theme.margin + if (self.plate_side == .left) self.plate_w + plate_gap else 0;
    }

    /// First row of an `above` plate: bottom-aligned against the top of
    /// the digits, so the mark sits on the number rather than floating
    /// somewhere in the slack.
    fn plateTop(self: Metrics, plate_rows: usize) usize {
        return self.left_top -| plate_rows;
    }

    fn chartX(self: Metrics) usize {
        return self.leftX() + self.left_w + 2;
    }

    fn plateX(self: Metrics) usize {
        return switch (self.plate_side) {
            // Same column as the number it is crediting.
            .above => self.leftX(),
            .left => theme.margin,
            // Against the chart's right edge, or the number's when the
            // terminal was too narrow for a chart at all.
            .right => if (self.chart_w > 0)
                self.chartX() + self.chart_w + plate_gap
            else
                self.leftX() + self.left_w + plate_gap,
            .off => 0,
        };
    }

    /// Row offsets within the left column, past the digits.
    fn statsRow(self: Metrics) usize {
        return left_caption_rows + self.digit_rows + 1;
    }
    fn actionRow(self: Metrics) usize {
        return left_caption_rows + self.digit_rows + 2;
    }
    fn compareRow(self: Metrics) usize {
        return left_caption_rows + self.digit_rows + 3;
    }
};

pub const Budget = struct {
    content_w: usize,
    /// Rows the dashboard has set aside for the chart band, baseline
    /// included. The band is exactly `chart_rows + 1` tall whenever a
    /// chart is drawn at all.
    chart_rows: usize,
    term_rows: usize,
    show_compare: bool,
    /// Cells the credit plate wants, and which side it wants them on.
    /// Taken off the top of the width before anything else is sized,
    /// so the plate never overlaps the chart.
    plate_w: usize = 0,
    /// Rows the plate needs. The band stretches to hold it rather than
    /// clipping its credit lines.
    plate_rows: usize = 0,
    /// Rows of *art* in the plate, credit lines excluded. Checked
    /// against the headline digits — see `maxPlateArtRows`.
    plate_art_rows: usize = 0,
    /// Cells of art. The art is the part that cannot be cut, so it is
    /// what an `above` plate's width floor is measured against.
    plate_art_w: usize = 0,
    plate_side: PlateSide = .off,
    /// Tallest the whole band may become. Only an `above` plate can
    /// grow it — it stacks on the left column rather than beside it —
    /// so this is the ceiling that decides whether it is seated.
    /// Defaults to unbounded for callers that draw no plate.
    band_max: usize = std.math.maxInt(usize),
};

/// Tallest logo allowed beside a number of `scale` digits, as a
/// percentage of the digits' own height.
///
/// The number is the thing the frame is about; a mark taller than it
/// stops being a credit and becomes the subject. 110% leaves the logo
/// free to be the larger of the two without taking the eye first.
const plate_art_pct: usize = 110;

pub fn maxPlateArtRows(num_scale: usize) usize {
    return tui.bigtext.rows * num_scale * plate_art_pct / 100;
}

/// The left column carries a caption in every state — `DECODE` while
/// a run is live, `RUN AVERAGE · …` after one, `NO RESULT` after one
/// that died, `NO RUN YET` before any. Reserving it unconditionally
/// is deliberate: a caption that came and went would resize the
/// column, and with it the chart, every time a run started or ended.
const left_caption_rows: usize = 1;

/// Rows the left column needs besides the digits: the caption, a
/// blank, the tokens/seconds line, the action line, and the compare
/// line.
fn leftRows(show_compare: bool, scale: usize) usize {
    const compare_rows: usize = if (show_compare) 1 else 0;
    return left_caption_rows + 3 + compare_rows + tui.bigtext.rows * scale;
}

/// Smallest height the left column can occupy, at the single-cell
/// digit scale. The dashboard spends this before assigning chart
/// rows, so it can reject a viewport that cannot hold the essential
/// hero content even with the chart at its minimum.
///
/// `measure` guarantees the column never exceeds the height the
/// dashboard then hands back: double-size digits are only chosen when
/// they fit inside the band that was budgeted.
pub fn minimumRows(show_compare: bool) usize {
    return leftRows(show_compare, 1);
}

/// The digit scale this viewport picks with no plate in the way.
///
/// The plate's own size depends on it — the taller the digits, the
/// taller a logo may be — so the caller needs the answer before it can
/// choose which cut of a mark to hand back in `Budget`.
pub fn digitScale(b: Budget) usize {
    var without = b;
    without.plate_side = .off;
    without.plate_w = 0;
    without.plate_rows = 0;
    without.plate_art_rows = 0;
    return measureWith(without).num_scale;
}

pub fn measure(b: Budget) Metrics {
    var without = b;
    without.plate_side = .off;
    without.plate_w = 0;
    without.plate_rows = 0;
    without.plate_art_rows = 0;
    const bare = measureWith(without);
    if (b.plate_side == .off) return bare;

    const with = measureWith(b);

    // The plate is a guest. It is dropped unless it can be seated
    // without changing anything about the number, on two counts:
    //
    //   • it must not be taller than the digits allow, and the ceiling
    //     is set by the scale the number would have picked on its own —
    //     not the one it was left with after the plate took its width,
    //     which would let a big logo shrink the digits and then justify
    //     itself against the smaller ones;
    //   • it must not cost the number its size at all. The plate takes
    //     width off the top, and the digit scale is chosen from what
    //     remains, so a wide plate can quietly halve the headline. The
    //     headline is the point of the frame; the credit is not.
    const fits_height = b.plate_art_rows <= maxPlateArtRows(bare.num_scale);
    const keeps_digits = with.num_scale == bare.num_scale;
    return if (fits_height and keeps_digits and with.plate_side != .off) with else bare;
}

fn measureWith(b: Budget) Metrics {
    // What the plate would cost, and whether there is room for it
    // alongside a number and a legible chart. Dropped outright when
    // there is not — better no logo than a logo that ate the dashboard.
    const beside = b.plate_side == .left or b.plate_side == .right;
    const plate_claim = if (beside) b.plate_w + plate_gap else 0;
    const plate_fits = plate_claim > 0 and
        b.content_w > plate_claim + left_w_min + 2 + chart_w_min;
    var plate_w: usize = if (plate_fits) b.plate_w else 0;
    var plate_side: PlateSide = if (plate_fits) b.plate_side else .off;
    const claimed = if (plate_fits) plate_claim else 0;
    const content_w = b.content_w;

    // A third of the width is the starting point; the column then
    // grows to whatever the digits and their unit stack actually need.
    // Without that second step the labels spill past the column, the
    // chart starts wherever they happen to end, and the row runs off
    // the right edge of a wide terminal.
    //
    // Deliberately a third of the *whole* width, plate included. The
    // plate competes with the chart for space, not with the number:
    // sizing the column against `content_w - plate` instead made the
    // headline's font depend on whether a logo happened to be shown,
    // and at the 200-column cap that meant any plate silently halved
    // the digits.
    const base_left_w: usize = @max(left_w_min, @min(content_w / 3, left_w_max));

    // The dashboard sized the whole band as `chart_rows + 1`. Doubling
    // the digits costs five more rows, and taking them would push the
    // block past the height that was budgeted for it — which the
    // dashboard cannot detect, because it asks for the geometry after
    // it has already spent the rows. So the fit is checked here.
    const doubled_fits_height = leftRows(b.show_compare, 2) <= b.chart_rows + 1;
    var num_scale: usize = if (base_left_w >= big_font_left_w and
        b.chart_rows >= big_font_chart_rows and
        b.term_rows >= big_font_term_rows and
        doubled_fits_height) 2 else 1;
    var left_w = @max(base_left_w, leftContentWidth(num_scale));
    // Double-size digits are a luxury: give them up before giving up
    // a legible chart.
    if (num_scale == 2 and content_w < left_w + 2 + chart_w_min + claimed) {
        num_scale = 1;
        left_w = @max(base_left_w, leftContentWidth(num_scale));
    }
    // Still no room even at single size — the chart goes to zero and
    // the column takes what is left, so nothing overruns the edge.
    left_w = @min(left_w, content_w -| claimed);

    const available_chart_w: usize =
        if (content_w > left_w + 2 + claimed) content_w - left_w - 2 - claimed else 0;
    // Honour the threshold rather than drawing a sliver: a chart
    // narrower than `chart_w_min` carries no shape, just noise beside
    // the number. Below it the column takes the whole width.
    const chart_w: usize = if (available_chart_w >= chart_w_min) available_chart_w else 0;
    if (chart_w == 0) left_w = content_w -| claimed;

    const digit_rows = tui.bigtext.rows * num_scale;
    const compare_rows: usize = if (b.show_compare) 1 else 0;
    const left_rows = leftRows(b.show_compare, num_scale);

    // With no chart the band has nothing to stretch for, so it
    // collapses to the column and the frame simply ends earlier —
    // better than a tall gap the eye has to cross.
    const chart_band = if (chart_w == 0) left_rows else @max(b.chart_rows + 1, left_rows);
    // A plate taller than the band would lose its bottom rows without
    // saying so — the credit lines are the first thing to go, which is
    // exactly the part that has to be readable. Stretch instead, but
    // only when the plate is actually being drawn: a plate dropped for
    // want of width must not still be paid for in height.
    var band_rows = @max(chart_band, if (plate_fits) b.plate_rows else 0);

    // An `above` plate stacks on the left column instead of sitting
    // beside it, so it needs the column's own height plus its own — and
    // it is free whenever the chart has already made the band that
    // tall, which is the usual case. It must also fit the column's
    // width, since it shares that column with the digits.
    if (b.plate_side == .above) {
        const stacked = b.plate_rows + left_rows;
        // The column may be narrower than the plate asked for. Clamp
        // rather than drop: the art is fixed but the credit text can be
        // cut, and a mark with a shortened model name beside it still
        // reads. Only when the column cannot seat the art plus a usable
        // scrap of text is the plate given up.
        const floor = b.plate_art_w + credit.beside_text_min;
        if (left_w >= floor and stacked <= b.band_max) {
            band_rows = @max(chart_band, stacked);
            plate_w = @min(b.plate_w, left_w);
            plate_side = .above;
        } else {
            plate_w = 0;
            plate_side = .off;
        }
    }
    const lanes = splitLanes(band_rows, chart_w);

    return .{
        .left_w = left_w,
        .chart_w = chart_w,
        .plate_w = plate_w,
        .plate_side = plate_side,
        // The left column bottom-aligns like the mock
        // (align-items: flex-end): the progress bar lands on the last
        // lane's baseline and any slack sits above the number rather
        // than under the stats.
        .left_top = band_rows - left_rows,
        .digit_rows = digit_rows,
        .num_scale = num_scale,
        .compare_rows = compare_rows,
        .lane_count = lanes.count,
        .lanes = lanes.lanes,
        .rows = band_rows,
    };
}

const LaneSplit = struct { count: usize, lanes: [2]Lane };

/// Divide the band into stacked lanes, bottom-aligned so the last
/// axis is the band's last row.
///
/// Two lanes when both clear `lane_body_min`, otherwise one. The
/// decode lane is the one that survives: prime-core load still has a
/// labelled readout in the CPU column below, whereas throughput has
/// nowhere else to go.
fn splitLanes(band_rows: usize, chart_w: usize) LaneSplit {
    const empty = Lane{ .caption_row = 0, .body_top = 0, .body_rows = 0, .axis_row = 0 };
    if (chart_w == 0) return .{ .count = 0, .lanes = .{ empty, empty } };

    const two_lane_min = 2 * (lane_chrome_rows + lane_body_min);
    if (band_rows < two_lane_min) {
        const body = band_rows -| lane_chrome_rows;
        return .{
            .count = 1,
            .lanes = .{ laneAt(band_rows - (lane_chrome_rows + body), body), empty },
        };
    }

    // The odd row goes to the top lane, matching the mock's slightly
    // taller throughput chart.
    const body_total = band_rows - 2 * lane_chrome_rows;
    const top_body = body_total - body_total / 2;
    const bottom_body = body_total / 2;
    const top = laneAt(0, top_body);
    const bottom = laneAt(top.axis_row + 1, bottom_body);
    return .{ .count = 2, .lanes = .{ top, bottom } };
}

fn laneAt(top: usize, body_rows: usize) Lane {
    return .{
        .caption_row = top,
        .body_top = top + 1,
        .body_rows = body_rows,
        .axis_row = top + 1 + body_rows,
    };
}

/// Headroom over the observed peak, so the tallest column of a run
/// never clips flat against the top row.
const tok_scale_headroom: f32 = 1.12;

/// Prime-core load is a percentage; its lane is pinned to that range
/// so a column's height means the same thing from one second to the
/// next, and so idle noise does not fill the lane.
const prime_denom: f32 = 100;

pub fn render(canvas: *tui.Canvas, m: Metrics, view: View, ui: *UiState) !void {
    // The number follows the run: gold from the moment decoding
    // starts, dimmed to teal once it ends.
    const num_color = if (view.running) theme.accent else theme.idle_number;

    // Each lane is normalised on its own terms — throughput against
    // the peak still on screen, load against a percentage's true
    // ceiling — and says so in its caption. One axis for both would
    // put a rate and a percentage on the same ruler, which makes their
    // relative heights mean nothing.
    // Scaled against the window the lane actually draws, not the whole
    // ring: a spike that has scrolled off the left of the panel should
    // stop holding the scale up for the samples still on it.
    const tok_denom = @max(view.tok_lane.maxRecent(m.chart_w), 1) * tok_scale_headroom;

    var num_buf: [16]u8 = undefined;
    // A run that ended without a result has no figure to headline.
    // The digits are left blank rather than filled with the zero the
    // wire reports, which would read as a measurement of zero.
    const has_figure = view.engine.progress.state() != .failed;
    const num = if (has_figure) formatRate(&num_buf, view.engine.tok_s) else "";

    var r: usize = 0;
    while (r < m.rows) : (r += 1) {
        // A colour-per-subpixel plate row can spend two truecolor SGRs
        // per cell, which `tui.scratch_len` was never sized for. See
        // `tui.logo.maxRowBytes`.
        var line_buf: [row_buf_len]u8 = undefined;
        var lw: std.Io.Writer = .fixed(&line_buf);
        try lw.writeAll(theme.margin_pad);

        // Columns are emitted left to right, so a left-hand plate has
        // to be written before the number rather than after it.
        if (m.plate_side == .left) try writePlateRow(&lw, m, view, r);

        if (m.plate_side == .above) try writePlateRow(&lw, m, view, r);

        if (r >= m.left_top) {
            try tui.cell.padTo(&lw, m.leftX());
            try writeLeftRow(&lw, m, view, ui, r - m.left_top, num, num_color);
        }

        var lane_idx: usize = 0;
        while (lane_idx < m.lane_count) : (lane_idx += 1) {
            const lane = m.lanes[lane_idx];
            if (r < lane.caption_row or r > lane.axis_row) continue;
            try tui.cell.padTo(&lw, m.chartX());
            if (lane_idx == 0) {
                try writeTokLane(&lw, m, lane, view, tok_denom, r);
            } else {
                try writePrimeLane(&lw, m, lane, view, r);
            }
        }

        if (m.plate_side == .right) try writePlateRow(&lw, m, view, r);
        try canvas.row(lw.buffered());
    }
}

/// Per-row buffer for the hero. Wider than `tui.scratch_len` because
/// the plate can carry bitmap art, which costs escapes per cell rather
/// than per run — and the art, not the text, is what sets the width.
/// Sizing this from `credit.text_w_max` looked right and was not:
/// A 56-cell bitmap can occupy the plate, and a populated
/// chart row plus that plate overran the writer and failed the frame.
const row_buf_len: usize = tui.scratch_len + tui.logo.maxRowBytes(credit.max_plate_w);

/// The plate, bottom-aligned against whatever it is crediting: the
/// band's own floor when it sits beside the chart, and the top of the
/// digits when it sits above them. Either way it lands on something
/// rather than floating in the middle of the slack.
fn writePlateRow(lw: anytype, m: Metrics, view: View, r: usize) !void {
    const c = view.credit orelse return;
    const top = if (m.plate_side == .above)
        m.plateTop(c.rows())
    else
        m.rows -| c.rows();
    if (r < top or r >= top + c.rows()) return;
    try tui.cell.padTo(lw, m.plateX());
    try credit.writeRow(lw, c, m.plate_w, r - top);
}

/// Top lane: decode rate. The caption names the unit on the left and
/// the axis ceiling on the right, so the height of a column can be
/// read as a number.
fn writeTokLane(
    lw: anytype,
    m: Metrics,
    lane: Lane,
    view: View,
    denom: f32,
    r: usize,
) !void {
    if (r == lane.caption_row) {
        var scale_buf: [24]u8 = undefined;
        const scale = std.fmt.bufPrint(&scale_buf, "{d:.1}", .{denom}) catch "";
        return writeLaneCaption(lw, m.chart_w, "tok/s", theme.accent_dark, scale);
    }
    if (r == lane.axis_row) return writeLaneAxis(lw, m.chart_w);
    try writeLaneBody(lw, lane, view.tok_lane, theme.chart_ramp, denom, r, m.chart_w);
}

/// Bottom lane: prime-core utilisation, with the current reading and
/// its fixed ceiling spelled out — `97% of 100` — so the lane cannot
/// be mistaken for a second view of the one above it.
fn writePrimeLane(lw: anytype, m: Metrics, lane: Lane, view: View, r: usize) !void {
    if (r == lane.caption_row) {
        var scale_buf: [24]u8 = undefined;
        const util = view.frame.cpu_util_pct[0];
        const scale = if (std.math.isNan(util))
            "— of 100"
        else
            std.fmt.bufPrint(&scale_buf, "{d:.0}% of 100", .{util}) catch "";
        return writeLaneCaption(lw, m.chart_w, if (view.telemetry_available) "prime" else "device telemetry unavailable", theme.label, if (view.telemetry_available) scale else "");
    }
    if (r == lane.axis_row) return writeLaneAxis(lw, m.chart_w);
    if (view.telemetry_available) try writeLaneBody(lw, lane, view.prime_lane, theme.idle_ramp, prime_denom, r, m.chart_w);
}

/// `label ······································ readout`, the
/// readout flush against the lane's right edge.
fn writeLaneCaption(
    lw: anytype,
    chart_w: usize,
    label: []const u8,
    label_color: []const u8,
    readout: []const u8,
) !void {
    const start = tui.cell.width(lw.buffered());
    try lw.print("{s}{s}{s}", .{ label_color, label, theme.reset });
    const readout_w = tui.cell.width(readout);
    if (tui.cell.width(label) + readout_w + 2 <= chart_w) {
        try tui.cell.padTo(lw, start + chart_w - readout_w);
        try lw.print("{s}{s}{s}", .{ theme.faint, readout, theme.reset });
    }
}

fn writeLaneAxis(lw: anytype, chart_w: usize) !void {
    try lw.writeAll(theme.axis);
    var i: usize = 0;
    while (i < chart_w) : (i += 1) try lw.writeAll("─");
    try lw.writeAll(theme.reset);
}

fn writeLaneBody(
    lw: anytype,
    lane: Lane,
    series: *const Series,
    ramp: tui.Ramp,
    denom: f32,
    r: usize,
    chart_w: usize,
) !void {
    // Bright at the baseline, fading toward the peaks — the mock
    // colours row r with t = 1 - r/(rows-1).
    const cr = r - lane.body_top;
    const row_span: f32 = @floatFromInt(@max(lane.body_rows - 1, 1));
    const t = 1.0 - @as(f32, @floatFromInt(cr)) / row_span;
    try tui.color.writeFg(lw, ramp.at(t));
    try series.chartRow(lw, cr, lane.body_rows, chart_w, denom);
    try lw.writeAll(theme.reset);
}

/// Largest rate the headline will display. A five-digit decode rate
/// means a corrupt report, not a fast engine; the headline is a
/// display, not the record, and `peak` / `avg` below it still carry
/// the unclamped figures.
const max_display_rate: f32 = 9999;

/// Block digits collide with the chart column past ~5 glyphs, so
/// decimals are shed as the value grows. The result is never wider
/// than `number_template`, which is what lets `measure` reserve the
/// left column once instead of resizing it every frame.
pub fn formatRate(buf: []u8, tok_s: f32) []const u8 {
    const raw: f32 = if (std.math.isNan(tok_s)) 0 else tok_s;
    const v = @min(raw, max_display_rate);

    // Precision is chosen from the *formatted* result, not from the
    // raw value. Picking on the raw value looks right and isn't:
    // 99.999 is below the 100 threshold yet renders as `100.00`, and
    // 999.96 is below 1000 yet renders as `1000.0` — each a glyph
    // wider than the reservation, which is enough to push the unit
    // stack and the chart past the row. Formatting and then checking
    // is immune to wherever the rounding happens to land.
    if (v < 100) {
        const s = std.fmt.bufPrint(buf, "{d:.2}", .{v}) catch "0";
        if (fitsReservation(s)) return s;
    }
    if (v < 1000) {
        const s = std.fmt.bufPrint(buf, "{d:.1}", .{v}) catch "0";
        if (fitsReservation(s)) return s;
    }
    // Clamped to four digits above, so this form always fits.
    return std.fmt.bufPrint(buf, "{d:.0}", .{v}) catch "0";
}

/// `bigtext.measure` is linear in scale, so checking at scale 1
/// settles it for every scale.
fn fitsReservation(s: []const u8) bool {
    return tui.bigtext.measure(s, 1) <= tui.bigtext.measure(number_template, 1);
}

fn writeLeftRow(
    lw: anytype,
    m: Metrics,
    view: View,
    ui: *UiState,
    lr: usize,
    num: []const u8,
    num_color: []const u8,
) !void {
    if (lr == 0) return writeHeadlineCaption(lw, view, ui);

    if (lr >= left_caption_rows and lr - left_caption_rows < m.digit_rows) {
        const dr = lr - left_caption_rows;
        try lw.print(" {s}", .{num_color});
        try tui.bigtext.writeRow(lw, num, dr, m.num_scale);
        try lw.writeAll(theme.reset);
        // The unit sits on the baseline row, beside the digits; what
        // the number measures is named by the caption above them.
        if (dr == m.digit_rows - 1 and num.len > 0) {
            try lw.print("  {s}tok/s{s}", .{ if (view.running) theme.accent_dark else theme.sep, theme.reset });
        }
        return;
    }

    if (lr == m.statsRow()) return writeRunStats(lw, view);
    if (lr == m.actionRow()) {
        if (view.running) return writeProgress(lw, view.engine, m.left_w -| 12);
        return writeIdleHint(lw, view.frame, view.needs_model);
    }
    if (lr == m.compareRow() and m.compare_rows == 1) {
        return writeCompare(lw, view.engine, view.compare.?);
    }
}

/// Names what the headline figure is. The engine derives it as
/// tokens ÷ elapsed over the whole run, so `RUN AVERAGE` is the
/// literal truth and the caption says so.
///
/// It used to read `LAST RUN`, which invited the opposite reading —
/// that the number was the most recent instantaneous sample — and put
/// the screen's largest figure in doubt for anyone captioning it.
fn writeHeadlineCaption(lw: anytype, view: View, ui: *UiState) !void {
    switch (view.engine.progress.state()) {
        .running => try lw.print(" {s}{s}{s}", .{
            theme.label,
            if (!view.engine.progress.have_report) @as([]const u8, "STARTING") else if (view.engine.progress.phase == engine_mod.phase_prefill) "PREFILL" else "DECODE",
            theme.reset,
        }),
        .failed => try lw.print(" {s}NO RESULT{s}", .{ theme.red, theme.reset }),
        .complete => {
            try lw.print(" {s}RUN AVERAGE", .{theme.faint});
            if (ui.lastRunAgeSecs()) |age| {
                if (age < 90) {
                    try lw.print(" · {d}s ago", .{age});
                } else {
                    try lw.print(" · {d}m ago", .{@divTrunc(age, 60)});
                }
            }
            try lw.writeAll(theme.reset);
        },
        .never_ran => try lw.print(" {s}{s}{s}", .{
            theme.faint,
            if (view.needs_model) @as([]const u8, "NO MODEL SELECTED") else "NO RUN YET",
            theme.reset,
        }),
    }
}

/// The two measurements the headline rate is derived from, so a
/// reader can divide one by the other and get it back.
///
/// This row used to carry `peak` and `avg`, taken as the max and mean
/// of the reported series. That series is a *running average* — the
/// engine sends tokens-so-far ÷ elapsed-so-far — so its max was
/// whatever the average happened to reach while the run was still
/// short, and its mean was a mean of means. Both read as sustained
/// rates and neither was one; the peak sat ~28% above the number it
/// appeared to qualify. Real peak and steady-state need per-token
/// timings, which the wire does not carry yet.
fn writeRunStats(lw: anytype, view: View) !void {
    const progress = view.engine.progress;
    if (progress.state() == .never_ran) return;
    if (progress.state() == .failed) {
        if (progress.producedTokens() > 0) {
            try lw.print(" {s}stopped after {d} tok · {d:.2} s{s}", .{
                theme.faint,
                progress.producedTokens(),
                progress.elapsedSeconds(),
                theme.reset,
            });
        } else {
            try lw.print(" {s}the engine produced no tokens{s}", .{ theme.faint, theme.reset });
        }
        return;
    }

    const tokens = progress.producedTokens();
    if (tokens == 0 and progress.elapsed_ns == 0) return;

    try lw.print(" {s}{d} tok{s} · {s}{d:.2} s{s}", .{
        theme.sub, tokens,                    theme.label,
        theme.sub, progress.elapsedSeconds(), theme.label,
    });
    if (engine_mod.validTokS(progress.prefill_tok_s)) {
        try lw.print(" · prefill {s}{d:.1}{s}", .{ theme.sub, progress.prefill_tok_s, theme.label });
    }
    try lw.writeAll(theme.reset);
}

/// Token progress bar; width follows the hero column.
fn writeProgress(lw: anytype, engine: engine_mod.Engine, width: usize) !void {
    const progress = engine.progress;
    if (progress.tokens_total > 0) {
        const bar_w: usize = @max(width, 20);
        const done = @min(progress.token_index, progress.tokens_total);
        const filled = @as(usize, done) * bar_w / @as(usize, progress.tokens_total);
        try lw.print(" {s}", .{theme.accent});
        var i: usize = 0;
        while (i < bar_w) : (i += 1) try lw.writeAll(if (i < filled) "█" else "░");
        try lw.print("{s} {s}{d}{s}/{d}{s}", .{ theme.reset, theme.mid, done, theme.faint, progress.tokens_total, theme.reset });
        return;
    }
    if (progress.have_report) {
        try lw.print(" {s}{d} tok{s}", .{ theme.mid, progress.token_index, theme.reset });
        return;
    }
    try lw.print(" {s}press [r] to run{s}", .{ theme.faint, theme.reset });
}

/// Idle call to action where the progress bar lives while running:
/// `[m] choose a model ▊` until configured, then `[r] run benchmark ▊`.
/// The cursor blinks off the probe's second
/// counter — renders are event-driven, so telemetry cadence is the
/// cheapest steady blink source available.
fn writeIdleHint(lw: anytype, frame: *const proto.TelemetryFrame, needs_model: bool) !void {
    if (needs_model) {
        try lw.print(" {s}[m]{s} choose a model", .{ theme.accent, theme.sub });
    } else {
        try lw.print(" {s}[r]{s} run benchmark", .{ theme.accent, theme.sub });
    }
    const secs = frame.ts_ns / std.time.ns_per_s;
    if (secs % 2 == 0) try lw.print(" {s}▊", .{theme.accent});
    try lw.writeAll(theme.reset);
}

/// `vs NAME N tok/s · R×` — the compare engine as a quiet line under
/// the hero block. The layout has no second sparkline.
fn writeCompare(lw: anytype, engine: engine_mod.Engine, c: engine_mod.Engine) !void {
    try lw.print(" {s}vs ", .{theme.faint});
    try tui.sanitize.write(lw, c.name);
    try lw.print(" {d:.2} tok/s", .{c.tok_s});
    if (c.tok_s > 0 and engine_mod.validTokS(engine.tok_s)) {
        try lw.print("{s} · {d:.2}×", .{ theme.sub, engine.tok_s / c.tok_s });
    }
    try lw.writeAll(theme.reset);
}

test "measure bottom-aligns the left column against the last baseline" {
    const m = measure(.{ .content_w = 120, .chart_rows = 10, .term_rows = 40, .show_compare = false });
    // The band is chart-sized here, so the left column sits at its
    // foot and the action row lands on the bottom lane's axis.
    try std.testing.expectEqual(@as(usize, 11), m.rows);
    try std.testing.expectEqual(m.rows - (left_caption_rows + m.digit_rows + 3), m.left_top);
    try std.testing.expectEqual(@as(usize, 0), m.lanes[0].caption_row);
}

test "two lanes stack without overlapping and end on the band's last row" {
    for ([_]usize{ 10, 11, 13, 18, 24 }) |chart_rows| {
        const m = measure(.{
            .content_w = 160,
            .chart_rows = chart_rows,
            .term_rows = 47,
            .show_compare = false,
        });
        try std.testing.expectEqual(@as(usize, 2), m.lane_count);
        const top = m.lanes[0];
        const bottom = m.lanes[1];
        // Each lane is caption, body, axis — contiguous and ordered.
        try std.testing.expectEqual(top.caption_row + 1, top.body_top);
        try std.testing.expectEqual(top.body_top + top.body_rows, top.axis_row);
        try std.testing.expectEqual(top.axis_row + 1, bottom.caption_row);
        try std.testing.expectEqual(bottom.body_top + bottom.body_rows, bottom.axis_row);
        // The last axis is the band's last row, so the left column's
        // progress bar lands on it.
        try std.testing.expectEqual(m.rows - 1, bottom.axis_row);
        try std.testing.expect(top.body_rows >= lane_body_min);
        try std.testing.expect(bottom.body_rows >= lane_body_min);
        // The odd row goes to the throughput lane.
        try std.testing.expect(top.body_rows >= bottom.body_rows);
        try std.testing.expect(top.body_rows - bottom.body_rows <= 1);
    }
}

test "a band too short for two lanes keeps the decode lane" {
    // Prime-core load still has a labelled readout in the CPU column;
    // throughput has nowhere else to go, so it is the one that stays.
    const m = measure(.{ .content_w = 160, .chart_rows = 8, .term_rows = 24, .show_compare = false });
    try std.testing.expectEqual(@as(usize, 1), m.lane_count);
    try std.testing.expectEqual(m.rows - 1, m.lanes[0].axis_row);
    try std.testing.expect(m.lanes[0].body_rows >= lane_body_min);
}

test "geometry does not depend on whether a run is live" {
    // `measure` has no run-state input at all, which is the structural
    // guarantee: nothing in the band can move when a run starts or
    // ends. This pins that the input stays absent.
    try std.testing.expect(!@hasField(Budget, "idle"));
    try std.testing.expect(!@hasField(Budget, "running"));
}

test "render emits exactly the measured number of rows" {
    const frame = proto.sentinelFrame(0);
    const series = Series{};
    var ui = UiState{};
    const view = View{
        .frame = &frame,
        .tok_lane = &series,
        .prime_lane = &series,
        .engine = .{ .name = "zzz", .tok_s = 12.34 },
        .compare = null,
        .running = false,
    };
    const m = measure(.{ .content_w = 120, .chart_rows = 10, .term_rows = 40, .show_compare = false });

    var buf: [65536]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    var canvas = tui.Canvas.init(&out, theme.margin, theme.canvas_style);
    try render(&canvas, m, view, &ui);
    try std.testing.expectEqual(m.rows, std.mem.count(u8, out.buffered(), "\n"));
}

test "the block never outgrows the height the dashboard budgeted" {
    // The dashboard hands over `chart_rows` after it has already spent
    // `chart_rows + 1` rows on the band, so the block must never come
    // back taller. It may come back shorter: a viewport too narrow for
    // a readable chart collapses the band to the column alone, which
    // just ends the frame earlier.
    for ([_]usize{ 60, 80, 132, 194, 199, 240 }) |content_w| {
        for (7..31) |chart_rows| {
            for ([_]u16{ 20, 24, 30, 36, 47, 120 }) |term_rows| {
                for ([_]bool{ true, false }) |show_compare| {
                    if (minimumRows(show_compare) > chart_rows + 1) continue;
                    const m = measure(.{
                        .content_w = content_w,
                        .chart_rows = chart_rows,
                        .term_rows = term_rows,
                        .show_compare = show_compare,
                    });
                    try std.testing.expect(m.rows <= chart_rows + 1);
                    if (m.chart_w > 0) try std.testing.expectEqual(chart_rows + 1, m.rows);
                    // Every lane has to fit inside the band it was cut
                    // from, or the frame grows a row the dashboard
                    // never budgeted.
                    var i: usize = 0;
                    while (i < m.lane_count) : (i += 1) {
                        try std.testing.expect(m.lanes[i].axis_row < m.rows);
                        try std.testing.expect(m.lanes[i].body_rows >= lane_body_min);
                    }
                }
            }
        }
    }
}

test "a chart is either readable or absent, never a sliver" {
    // `chart_w_min` used to gate only the font-scale decision, so
    // narrow terminals still drew a nine-cell chart beside the number.
    for (40..260) |content_w| {
        const m = measure(.{
            .content_w = content_w,
            .chart_rows = 13,
            .term_rows = 47,
            .show_compare = false,
        });
        try std.testing.expect(m.chart_w == 0 or m.chart_w >= chart_w_min);
        // Whatever the split, the row still ends inside the frame.
        try std.testing.expect(m.left_w <= content_w);
        if (m.chart_w > 0) try std.testing.expect(m.left_w + 2 + m.chart_w <= content_w);
        // No chart, no lanes to draw into.
        if (m.chart_w == 0) try std.testing.expectEqual(@as(usize, 0), m.lane_count);
    }
}

test "the left column reserves room for the digits and their unit stack" {
    // At 200 columns the doubled digits plus `decode` used to spill
    // past the column and shove the chart off the right edge.
    const m = measure(.{ .content_w = 195, .chart_rows = 13, .term_rows = 47, .show_compare = false });
    try std.testing.expectEqual(@as(usize, 2), m.num_scale);
    try std.testing.expect(m.left_w >= leftContentWidth(2));
    try std.testing.expectEqual(@as(usize, 195), m.left_w + 2 + m.chart_w);
}

test "every formatRate output fits the width the column reserved" {
    const rates = [_]f32{
        0,      0.01,    9.87,    99.99,             100,    123.4,  999.9,   1000,
        1234,   9999,    999_999, std.math.nan(f32),
        // Values that round *across* a precision threshold. The
        // earlier version chose precision from the raw value, so
        // these rendered a glyph wider than the reservation.
        99.999, 99.995, 99.9999, 999.96,
        999.95, 999.999, 9999.4,
    };
    for ([_]usize{ 1, 2 }) |scale| {
        const reserved = tui.bigtext.measure(number_template, scale);
        for (rates) |rate| {
            var buf: [16]u8 = undefined;
            const text = formatRate(&buf, rate);
            try std.testing.expect(tui.bigtext.measure(text, scale) <= reserved);
        }
    }
}

test "a rate that rounds up sheds a decimal instead of a column" {
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("100.0", formatRate(&buf, 99.999));
    try std.testing.expectEqualStrings("1000", formatRate(&buf, 999.96));
}

test "formatRate stays within the reservation across a full sweep" {
    // The thresholds are crossed by a continuously varying float many
    // times a second during a run, so walk the whole display range
    // rather than trusting a handful of hand-picked values.
    const reserved = tui.bigtext.measure(number_template, 1);
    var v: f32 = 0;
    while (v < max_display_rate) : (v += 0.37) {
        var buf: [16]u8 = undefined;
        try std.testing.expect(tui.bigtext.measure(formatRate(&buf, v), 1) <= reserved);
    }
    // And the boundaries themselves, approached from below.
    for ([_]f32{ 100, 1000, max_display_rate }) |edge| {
        for ([_]f32{ 0.0001, 0.001, 0.01 }) |delta| {
            var buf: [16]u8 = undefined;
            try std.testing.expect(tui.bigtext.measure(formatRate(&buf, edge - delta), 1) <= reserved);
        }
    }
}

test "formatRate sheds decimals as the number grows" {
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("12.34", formatRate(&buf, 12.34));
    try std.testing.expectEqualStrings("123.4", formatRate(&buf, 123.44));
    try std.testing.expectEqualStrings("1234", formatRate(&buf, 1234.4));
    try std.testing.expectEqualStrings("0.00", formatRate(&buf, std.math.nan(f32)));
}

test "the tokens and seconds on screen divide back into the headline" {
    // The whole point of this row: a reader can check the big number
    // without trusting it. Mid-run it must show tokens *produced*,
    // not the run's target, or the division contradicts the headline.
    var ui = UiState{};
    const frame = proto.sentinelFrame(0);
    const lane = Series{};
    var engine = engine_mod.Engine{ .name = "zzz", .tok_s = 12.34 };
    engine.progress = .{
        .have_report = true,
        .phase = engine_mod.phase_decode,
        .token_index = 30,
        .tokens_total = 60,
        .decode_tok_s = 12.34,
        .elapsed_ns = 2_431_118_314,
    };

    var buf: [tui.scratch_len]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeRunStats(&w, .{
        .frame = &frame,
        .tok_lane = &lane,
        .prime_lane = &lane,
        .engine = engine,
        .compare = null,
        .running = true,
    });
    const text = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, text, "30 tok") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "2.43 s") != null);
    // 30 / 2.43 = 12.35, which is the headline. 60 / 2.43 is not.
    try std.testing.expect(std.mem.indexOf(u8, text, "60 tok") == null);
    _ = &ui;
}

test "nothing is claimed before a run has happened" {
    var ui = UiState{};
    const frame = proto.sentinelFrame(0);
    const lane = Series{};
    const engine = engine_mod.Engine{ .name = "zzz", .tok_s = 20.41 };

    var buf: [tui.scratch_len]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const view = View{
        .frame = &frame,
        .tok_lane = &lane,
        .prime_lane = &lane,
        .engine = engine,
        .compare = null,
        .running = false,
    };
    try writeRunStats(&w, view);
    // A `--engine zzz:20.41` baseline is not a measurement, so the
    // row stays empty rather than dressing it as one.
    try std.testing.expectEqual(@as(usize, 0), w.buffered().len);

    var cap_buf: [tui.scratch_len]u8 = undefined;
    var cw: std.Io.Writer = .fixed(&cap_buf);
    try writeHeadlineCaption(&cw, view, &ui);
    try std.testing.expect(std.mem.indexOf(u8, cw.buffered(), "NO RUN YET") != null);
}

test "a finished run is captioned as the average it is" {
    var ui = UiState{};
    const frame = proto.sentinelFrame(0);
    const lane = Series{};
    var engine = engine_mod.Engine{ .name = "zzz", .tok_s = 59.44 };
    engine.progress = .{
        .have_report = true,
        .phase = engine_mod.phase_done,
        .token_index = 32,
        .tokens_total = 32,
        .decode_tok_s = 59.44,
        .elapsed_ns = 538_400_000,
    };

    var buf: [tui.scratch_len]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeHeadlineCaption(&w, .{
        .frame = &frame,
        .tok_lane = &lane,
        .prime_lane = &lane,
        .engine = engine,
        .compare = null,
        .running = false,
    }, &ui);
    const text = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, text, "RUN AVERAGE") != null);
    // `LAST RUN` read as "the most recent sample" and put the
    // screen's biggest number in doubt.
    try std.testing.expect(std.mem.indexOf(u8, text, "LAST RUN") == null);
}

test "a logo taller than 110% of the digits is dropped, not drawn" {
    // The number is what the frame is about. A mark that towers over it
    // stops reading as a credit and becomes the subject — which is
    // why this synthetic tall mark must yield to the digits.
    const wide = Budget{
        .content_w = 240,
        .chart_rows = 24,
        .term_rows = 60,
        .show_compare = false,
    };

    // Establish the digit scale this viewport picks on its own — the
    // cap is defined against that, not against whatever the number is
    // left with once the plate has taken its width.
    const bare = measure(wide);
    const cap = maxPlateArtRows(bare.num_scale);
    try std.testing.expect(cap > 0);

    var at_cap = wide;
    at_cap.plate_side = .right;
    at_cap.plate_w = 20;
    at_cap.plate_art_rows = cap;
    at_cap.plate_rows = cap + 3;
    const seated = measure(at_cap);
    try std.testing.expect(seated.plate_side == .right);
    // And seating it must not have cost the number its size.
    try std.testing.expectEqual(bare.num_scale, seated.num_scale);

    var over = at_cap;
    over.plate_art_rows = cap + 1;
    over.plate_rows = cap + 4;
    const dropped = measure(over);
    try std.testing.expect(dropped.plate_side == .off);
    try std.testing.expectEqual(@as(usize, 0), dropped.plate_w);

    // Dropping it must hand the width back rather than leave a hole.
    try std.testing.expectEqual(bare.chart_w, dropped.chart_w);
}

test "the proportion cap tracks the digit scale" {
    // Double-size digits are twice as tall, so they can carry twice the
    // logo. A cap that ignored the scale would either ban every mark at
    // scale 2 or admit a giant one at scale 1.
    try std.testing.expectEqual(@as(usize, 5), maxPlateArtRows(1));
    try std.testing.expectEqual(@as(usize, 11), maxPlateArtRows(2));
}

test "the widest catalogued plate fits the hero row buffer" {
    // A wide synthetic bitmap occupies the plate. Sizing the row
    // buffer against the *text* cap instead of the art meant a chart row
    // plus that plate overran the fixed writer and the whole frame
    // failed to render.
    const wide_art = tui.logo.Bitmap{
        .w = credit.max_plate_w,
        .h = 2,
        .px = &(.{tui.Rgb.hex("#f5c518")} ** (credit.max_plate_w * 2)),
    };
    var line_buf: [row_buf_len]u8 = undefined;
    var lw: std.Io.Writer = .fixed(&line_buf);
    // A full chart row's worth of bytes already on the line, then the
    // plate — which is the real worst case, both on one row.
    try tui.padWidth(&lw, theme.margin);
    var i: usize = 0;
    while (i < 200) : (i += 1) try lw.writeAll("\x1b[38;2;20;52;58m\u{2587}");
    try tui.logo.writeBitmapRow(&lw, wide_art, 0);
    try std.testing.expect(lw.buffered().len <= row_buf_len);
}
