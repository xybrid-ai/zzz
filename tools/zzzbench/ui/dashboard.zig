//! Composes one frame of the bench dashboard.
//!
//! This file owns the vertical budget — how many rows each band gets
//! at the current terminal size — and nothing else. Every band knows
//! how to draw itself; the dashboard only decides where each one
//! starts and how tall the chart is allowed to be.
//!
//! Layout, top to bottom:
//!   top margin · title bar · rule
//!   hero (big number + chart backdrop) · rule
//!   stats grid · peer bands
//!   rule · footer keybinds

const std = @import("std");
const proto = @import("proto");
const tui = @import("tuiz");

const cli = @import("../cli.zig");
const credit_mod = @import("credit.zig");
const engine_mod = @import("../engine.zig");
const test_marks = @import("test_marks.zig");
const Peer = @import("../peer.zig").Peer;
const Series = @import("../series.zig").Series;
const tty = @import("../tty.zig");
const wire = @import("../wire.zig");

const hero = @import("hero.zig");
const output_panel = @import("output.zig");
const peer_band = @import("peer_band.zig");
const run_policy = @import("../run_policy.zig");
const race = @import("race.zig");
const stats = @import("stats.zig");
const state = @import("state.zig");
const theme = @import("theme.zig");
const title_bar = @import("title_bar.zig");

const UiState = state.UiState;

/// Render scratch. The hero chart dominates: ~600 B of block glyphs
/// per row at the 200-column cap, one truecolor SGR each, times the
/// row count, plus peer sections.
const frame_buf_size: usize = 32768 + logo_frame_slack;

/// Terminal height at or above which the layout can afford the mock's
/// 18–22px section gaps. At 24 rows they would push the idle layout
/// past the bottom edge.
const rhythm_min_rows: usize = 28;

/// Fixed chrome around the hero: top margin, title, three rules, and
/// the footer.
const chrome_rows: usize = 6;

/// A colour-per-subpixel logo costs escapes per cell rather than per
/// run, so a frame carrying one needs far more room than the text-only
/// worst case `frame_buf_size` was sized for.
const logo_frame_slack: usize = 64 * 1024;

/// Chart height bounds. The proportional cap preserves the mock's
/// chart-to-card ratio; the hard cap keeps a maximum-width frame,
/// including all peer rows, within `frame_buf_size`.
const chart_rows_min: usize = 7;
const chart_rows_floor_cap: usize = 13;
const chart_rows_max: usize = 24;

/// Everything one frame is drawn from. A parameter object rather than
/// a dozen positional arguments: the render path is a pure function of
/// this plus the viewport.
pub const Snapshot = struct {
    frame: *const proto.TelemetryFrame,
    tok_lane: *const Series,
    prime_lane: *const Series,
    engine: engine_mod.Engine,
    compare: ?engine_mod.Engine,
    hello: *const proto.Hello,
    hardware_info: ?*const proto.HardwareInfo,
    peers: []const Peer,
    /// The credit plate and where it goes, or null when no `--logo`
    /// was named.
    credit: ?credit_mod.Credit = null,
    credit_at: cli.LogoAt = .right,
    /// Which multi-device layout to draw.
    multi: cli.Multi = .bands,
    /// The primary device's generated text. Null when the panel is
    /// toggled off, which is the default — the dashboard's subject is
    /// how fast the model spoke, not what it said.
    output: ?output_panel.Panel = null,
    /// What each device is set to run, indexed primary-first. Drawn on
    /// every frame so a screencap says which thread count produced the
    /// number beside it.
    /// `null` for a device the policy does not reach — a probe still
    /// using fixed-size `RunRequest` runs its own startup settings,
    /// and printing a figure the bench does not control would be worse
    /// than printing none.
    policies: []const ?run_policy.Shown = &.{},
    /// No configured engine has a selected model for the next run.
    needs_model: bool = false,
    /// The primary's run is coming from this process's own engine, not
    /// over the probe socket — so that socket dropping says nothing
    /// about whether the column is live.
    local_run_live: bool = false,

    /// The policy for device `index`, or the default when the caller
    /// supplied none — the golden fixture and the tests do.
    pub fn policyFor(self: Snapshot, index: usize) ?run_policy.Shown {
        if (index < self.policies.len) return self.policies[index];
        return .{ .policy = .{} };
    }
};

/// Draw a frame, push it to the terminal, then let a pending `e`
/// snapshot consume the exact bytes that were displayed.
pub fn render(snap: Snapshot, ui: *UiState, view: tui.Viewport) !void {
    var buf: [frame_buf_size]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    try draw(snap, ui, view, &out);
    const rendered = out.buffered();
    try tty.write(rendered);
    state.consumeExport(ui, rendered);
}

/// Compose one frame into `out`. Separate from `render` so the layout
/// can be exercised without a terminal — see the golden test below.
pub fn draw(snap: Snapshot, ui: *UiState, view: tui.Viewport, out: *std.Io.Writer) !void {
    var canvas = tui.Canvas.init(out, theme.margin, theme.canvas_style);

    // Home the cursor only — never `\x1b[2J`. On iTerm2 (and a few
    // other terminals) `[2J` in alt-screen mode pushes the cleared
    // content into scrollback, which is what makes frames replicate on
    // a click. Instead every row ends with `[K` and the frame ends
    // with `[J`, so a taller previous frame is wiped without ever
    // touching scrollback. Same pattern htop, top, and vim use.
    try canvas.home();

    if (view.too_small) return renderTooSmall(&canvas, view, theme.limits.min_rows);

    if (snap.multi == .race) return drawRace(snap, ui, view, &canvas);

    const running = snap.engine.progress.isRunning();
    const show_compare = snap.compare != null;
    const content_w = view.content_w;
    const term_rows = view.rowsOr(24);

    const stats_rows = stats.rowCount(content_w);
    const hero_rows_min = hero.minimumRows(show_compare);

    // Which cut of the mark this viewport can carry. The ceiling comes
    // from the headline digits, and those are half as tall on a
    // terminal too narrow for the double-size font — so the choice has
    // to be made per frame, before any rows are spent on the plate.
    // `top` sets the text beside the mark rather than under it: it sits
    // in the left column's slack, where rows are the scarce thing and a
    // stacked plate would be three rows taller for no gain.
    const laid_out: ?credit_mod.Credit = if (snap.credit) |c| blk: {
        var placed = c;
        placed.layout = if (snap.credit_at == .top) .beside else .stacked;
        break :blk placed;
    } else null;

    const credit: ?credit_mod.Credit = if (laid_out) |c| c.forDigits(
        hero.maxPlateArtRows(hero.digitScale(.{
            .content_w = content_w,
            .chart_rows = chart_rows_floor_cap,
            .term_rows = term_rows,
            .show_compare = show_compare,
        })),
    ) else null;
    // The OUTPUT panel is the first thing to give way on a short
    // terminal. Same precedence as the credit plate, and for the same
    // reason: it is an addition to the frame, so it must not cost the
    // hero the rows the hero needs to be itself.
    const base_essential = chrome_rows + stats_rows +
        peer_band.rowCount(snap.peers.len) + hero_rows_min;
    const panel_rows: usize = if (ui.show_output and snap.output != null and
        term_rows >= base_essential + output_panel.rows) output_panel.rows else 0;

    const essential_rows = base_essential + panel_rows;
    if (term_rows < essential_rows) return renderTooSmall(&canvas, view, essential_rows);

    // Vertical rhythm is decorative: keep it only when both gaps fit
    // without stealing a row from the minimum chart.
    const rhythm_rows: usize = if (term_rows >= rhythm_min_rows and
        term_rows >= essential_rows + 2) 1 else 0;
    const fixed_rows = chrome_rows + 2 * rhythm_rows + stats_rows +
        peer_band.rowCount(snap.peers.len) + panel_rows;
    const chart_budget = term_rows - fixed_rows - 1;
    const chart_cap = @min(chart_rows_max, @max(chart_rows_floor_cap, term_rows * 2 / 5));
    const chart_rows = @min(chart_budget, chart_cap);
    std.debug.assert(chart_rows >= chart_rows_min);

    // Every placement now lives inside the hero band — `top` draws in
    // the slack the left column already leaves above the number rather
    // than as a band of its own, so nothing above needs reserving.
    const plate_rows: usize = if (credit) |c| c.rows() else 0;

    // A plate beside the chart stretches the band to fit it, and the
    // band is what has to stay inside `term_rows - fixed_rows`.
    // Shrinking the chart cannot buy room here — once the plate is the
    // taller of the two, the band is its height and the chart's no
    // longer matters — so a plate that does not fit is dropped instead.
    // `above` stacks rather than sitting beside, and `hero.measure`
    // checks that against `band_max`.
    const band_max = chart_budget + 1;
    const side: hero.PlateSide = if (credit == null) .off else switch (snap.credit_at) {
        .left => .left,
        .right => .right,
        .top => .above,
    };
    const in_band = side == .above or (side != .off and plate_rows <= band_max);

    const metrics = hero.measure(.{
        .content_w = content_w,
        .chart_rows = chart_rows,
        .term_rows = term_rows,
        .show_compare = show_compare,
        .band_max = band_max,
        .plate_w = if (in_band) credit.?.width() else 0,
        .plate_rows = if (in_band) plate_rows else 0,
        .plate_art_rows = if (in_band) credit.?.mark.rows() else 0,
        .plate_art_w = if (in_band) credit.?.mark.cols() else 0,
        .plate_side = if (in_band) side else .off,
    });

    // Top margin — the mock's card padding above the title.
    try canvas.blank();
    try title_bar.render(&canvas, snap.hello, snap.engine, snap.policyFor(0), ui, content_w);
    try canvas.rule(content_w);

    try hero.render(&canvas, metrics, .{
        .frame = snap.frame,
        .tok_lane = snap.tok_lane,
        .prime_lane = snap.prime_lane,
        .telemetry_available = !isSynthetic(snap.hello),
        .engine = snap.engine,
        .compare = snap.compare,
        .running = running,
        .needs_model = snap.needs_model,
        .credit = if (metrics.plate_side != .off) credit else null,
    }, ui);

    try canvas.rule(content_w);
    if (panel_rows > 0) try output_panel.render(&canvas, snap.output.?, content_w);
    if (rhythm_rows > 0) try canvas.blank();

    if (isSynthetic(snap.hello)) {
        const notice = "Device telemetry unavailable; speed is measured.";
        try canvas.rowPrint("{s}{s}", .{ theme.margin_pad, tui.cell.truncate(notice, content_w) });
        for (1..stats_rows) |_| try canvas.blank();
    } else try stats.render(&canvas, .{
        .frame = snap.frame,
        .hello = snap.hello,
        .hardware_info = snap.hardware_info,
        .ios_probe = wire.isIosProbe(snap.hello),
        .idle = !running,
    }, content_w);

    if (snap.peers.len > 0) {
        try peer_band.renderHeading(&canvas);
        // The primary device is 1, so peers are numbered from 2. A
        // label for reading the window, not a keybind — no digit key
        // is bound.
        for (snap.peers, 0..) |*p, i| try peer_band.render(&canvas, p, i + 2, snap.policyFor(i + 1), content_w);
    }

    if (rhythm_rows > 0) try canvas.blank();
    try canvas.rule(content_w);
    try renderFooter(&canvas, ui, content_w, snap.needs_model);

    try canvas.finish();
}

/// Rows the race layout spends outside the grid: a top margin, the
/// title, a rule, a blank, then a blank, a rule and the footer.
const race_chrome_rows: usize = 7;

/// The race layout: chrome, then one column per device.
///
/// A separate path rather than a branch inside `draw` because it
/// shares almost nothing with the band layout — no hero, no stats
/// grid, no peer section — and threading two layouts through one
/// vertical budget would make both harder to read than either is
/// apart. What they do share is the chrome and the promise that the
/// frame fits the terminal.
fn drawRace(snap: Snapshot, ui: *UiState, view: tui.Viewport, canvas: *tui.Canvas) !void {
    const content_w = view.content_w;
    const term_rows = view.rowsOr(24);

    var buf: [1 + cli.max_peers]race.Entry = undefined;
    const entries = raceEntries(snap, &buf);
    entries[0].connected = snap.local_run_live or !ui.isDisconnected();
    if (ui.sort_race) std.sort.insertion(race.Entry, entries, {}, race.fasterFirst);

    // The digit scale decides the grid's height, so it is settled
    // before the viewport is judged big enough for it — and against the
    // rows the grid will actually get, not the terminal's total.
    const scale = race.digitScale(entries.len, content_w, term_rows -| race_chrome_rows);
    const needed = race_chrome_rows + race.rowsFor(scale);
    if (term_rows < needed) return renderTooSmall(canvas, view, needed);

    const shown = race.columnCount(entries.len, content_w);
    try canvas.blank();
    try title_bar.renderRace(canvas, entries.len, shown, modelName(snap), modelAgreement(snap), content_w);
    try canvas.rule(content_w);
    try canvas.blank();
    try race.render(canvas, entries, content_w, scale);
    try canvas.blank();
    try canvas.rule(content_w);
    var busy = false;
    for (entries) |entry| busy = busy or entry.state == .running;
    try renderRaceFooter(canvas, ui, content_w, snap.needs_model, busy);
    try canvas.finish();
}

/// Every device in the window as one flat list: the primary first,
/// then the peers in the order they were given. The race layout has no
/// primary device, so this is where that distinction is dropped.
/// Whether every device in the window reports the same model.
///
/// Compared rather than assumed. The race header used to assert that
/// the models matched, which nothing checked and which a peer started
/// against a different `--model` quietly falsified — turning a header
/// into a claim that made incomparable numbers look like a ranking.
///
/// A device that has not sent its `Hello` yet, or whose probe is
/// telemetry-only and names no model, cannot disagree with anything, so
/// it is skipped rather than counted as a mismatch.
fn modelAgreement(snap: Snapshot) title_bar.ModelAgreement {
    var reference: []const u8 = modelName(snap);
    var seen: usize = if (reference.len > 0) 1 else 0;

    for (snap.peers) |*peer| {
        if (!peer.have_hello) continue;
        const name = proto.Hello.nameSlice(&peer.helloPtr().model_name);
        if (name.len == 0) continue;
        if (reference.len == 0) {
            reference = name;
            seen = 1;
            continue;
        }
        if (!std.mem.eql(u8, reference, name)) return .differ;
        seen += 1;
    }
    // One device that names a model agrees with nothing; it takes two
    // to make the claim mean anything.
    return if (seen > 1) .same else .unknown;
}

fn raceEntries(snap: Snapshot, buf: []race.Entry) []race.Entry {
    const p = snap.engine.progress;
    buf[0] = .{
        .name = primaryName(snap),
        .soc = proto.Hello.nameSlice(&snap.hello.soc_name),
        .rate = if (engine_mod.validTokS(p.decode_tok_s)) p.decode_tok_s else snap.engine.tok_s,
        .tokens = p.token_index,
        .tokens_total = p.tokens_total,
        .elapsed_ns = p.elapsed_ns,
        .state = p.state(),
        .activity = p.activityLabel(),
        .policy = snap.policyFor(0),
        .series = snap.tok_lane,
        .prime = if (isSynthetic(snap.hello)) null else snap.prime_lane,
    };

    var n: usize = 1;
    for (snap.peers) |*peer| {
        if (n >= buf.len) break;
        const pp = peer.engine_progress;
        buf[n] = .{
            .name = peerName(peer),
            .soc = if (peer.have_hello) proto.Hello.nameSlice(&peer.helloPtr().soc_name) else "",
            .rate = if (!peer.have_engine_report)
                std.math.nan(f32)
            else if (engine_mod.validTokS(pp.decode_tok_s))
                pp.decode_tok_s
            else
                peer.last_tok_s,
            .tokens = pp.token_index,
            .tokens_total = pp.tokens_total,
            .elapsed_ns = pp.elapsed_ns,
            .state = pp.state(),
            .activity = pp.activityLabel(),
            .connected = peer.sock_opt != null,
            .policy = snap.policyFor(n),
            .series = &peer.tok_series,
            .prime = if (peer.have_hello and isSynthetic(peer.helloPtr())) null else &peer.prime_series,
        };
        n += 1;
    }
    return buf[0..n];
}

fn isSynthetic(hello: *const proto.Hello) bool {
    return std.mem.eql(u8, proto.Hello.sourceSlice(&hello.source), "synthetic");
}

test "single-device synthetic telemetry is explicitly unavailable" {
    var hello: proto.Hello = .{};
    fillName(&hello.source, "synthetic");
    var frame = proto.sentinelFrame(0);
    var series: Series = .{};
    var ui: UiState = .{};
    var buf: [64 * 1024]u8 = undefined;
    for ([_]u16{ 56, 57, 60, 64, 67, 68, 80, 150 }) |cols| {
        for ([_]u16{ 27, 45 }) |rows| {
            var out: std.Io.Writer = .fixed(&buf);
            const view = tui.Viewport.fromWinsize(.{
                .col = cols,
                .row = rows,
                .xpixel = 0,
                .ypixel = 0,
            }, theme.limits);
            try draw(.{
                .hello = &hello,
                .frame = &frame,
                .engine = .{ .name = "zzz", .tok_s = 0 },
                .compare = null,
                .hardware_info = null,
                .tok_lane = &series,
                .prime_lane = &series,
                .peers = &.{},
            }, &ui, view, &out);
            try expectFits(out.buffered(), cols, rows, view.content_w, "synthetic telemetry");
            try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "Device telemetry unavailable") != null);
            try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "T H E R M A L") == null);
        }
    }
}

test "comparison shows a loading peer and omits synthetic load measurements" {
    var hello = proto.Hello{};
    fillName(&hello.device_name, "Mac");
    fillName(&hello.source, "synthetic");
    var phone = Peer{ .label = "phone", .endpoint = "tcp:8001", .sock_opt = 0 };
    phone.engine_progress.markStarted(64);
    const frame = proto.sentinelFrame(0);
    const series = Series{};
    const snap: Snapshot = .{
        .frame = &frame,
        .tok_lane = &series,
        .prime_lane = &series,
        .engine = .{ .name = "zzz", .tok_s = 0 },
        .compare = null,
        .hello = &hello,
        .hardware_info = null,
        .peers = &.{phone},
        .multi = .race,
    };
    var entries: [2]race.Entry = undefined;
    _ = raceEntries(snap, &entries);
    try std.testing.expect(entries[0].prime == null);
    try std.testing.expect(entries[1].prime != null);
    try std.testing.expectEqual(engine_mod.State.running, entries[1].state);
    try std.testing.expectEqualStrings("starting", entries[1].activity);
    for ([_]u16{ 80, 132, 200 }) |cols| {
        var buf: [frame_buf_size]u8 = undefined;
        var out: std.Io.Writer = .fixed(&buf);
        var ui: UiState = .{};
        try draw(snap, &ui, tui.Viewport.fromWinsize(.{ .col = cols, .row = 36, .xpixel = 0, .ypixel = 0 }, theme.limits), &out);
        const text = out.buffered();
        try std.testing.expect(std.mem.indexOf(u8, text, "● starting") != null);
        try std.testing.expect(std.mem.indexOf(u8, text, theme.disabled ++ "[r]") != null);
        try std.testing.expect(std.mem.indexOf(u8, text, theme.disabled ++ "[c]") != null);
    }
}

fn primaryName(snap: Snapshot) []const u8 {
    const dev = proto.Hello.nameSlice(&snap.hello.device_name);
    return if (dev.len > 0) dev else "this device";
}

fn peerName(peer: *const Peer) []const u8 {
    if (peer.label.len > 0) return peer.label;
    if (peer.have_hello) {
        const dev = proto.Hello.nameSlice(&peer.helloPtr().device_name);
        if (dev.len > 0) return dev;
    }
    return peer.endpoint;
}

/// The model every column is running. Taken from the engine rather
/// than a peer, since the header claims they all share it.
fn modelName(snap: Snapshot) []const u8 {
    if (snap.engine.model.len > 0) return snap.engine.model;
    return proto.Hello.nameSlice(&snap.hello.model_name);
}

/// The same device and model controls remain available in split view.
fn renderRaceFooter(canvas: *tui.Canvas, ui: *UiState, content_w: usize, needs_model: bool, busy: bool) !void {
    if (try renderExportNotice(canvas, ui, content_w)) return;
    var line_buf: [tui.scratch_len]u8 = undefined;
    var lw: std.Io.Writer = .fixed(&line_buf);
    try lw.print("{s} ", .{theme.margin_pad});
    if (needs_model) try lw.print("{s}[m]{s}{s}  ", .{ theme.accent, theme.sub, if (content_w >= 85) @as([]const u8, " choose model") else "odel" });
    // Dimmed means the key is refused right now, and only a run in
    // progress refuses these. A missing model does not: `r` opens the
    // picker and starts once one is chosen, so it stays lit and `[m]`
    // merely goes first.
    const action_color = if (busy) theme.disabled else theme.accent;
    const action_label = if (busy) theme.disabled else theme.label;
    try lw.print("{s}[r]{s}un all  ", .{ action_color, action_label });
    if (!needs_model) try lw.print("{s}[m]{s}odel  ", .{ action_color, action_label });
    if (content_w >= 95) try lw.print("{s}[p]{s}arams  ", .{ action_color, action_label });
    try lw.print("{s}[c]{s}ompare  ", .{ action_color, action_label });
    if (content_w >= 70) try lw.print("{s}[s]{s}ort  ", .{ theme.accent, theme.label });
    if (content_w >= 70) try lw.print("{s}[e]{s}xport  ", .{ theme.accent, theme.label });
    try lw.print("{s}[q]{s}uit{s}", .{ theme.accent, theme.label, theme.reset });
    try writeFlash(&lw, ui, content_w);
    try canvas.writeRaw(tui.cell.truncate(lw.buffered(), theme.margin + content_w));
}

/// The one message that has to render in a viewport too small for the
/// dashboard — so it must fit a viewport too small for itself. Three
/// forms, longest first, then a hard cut.
fn renderTooSmall(canvas: *tui.Canvas, view: tui.Viewport, min_rows: usize) !void {
    var line_buf: [tui.scratch_len]u8 = undefined;
    var lw: std.Io.Writer = .fixed(&line_buf);
    try lw.print("zzzbench: terminal too small ({d}×{d}, need ≥{d}×{d})", .{
        view.cols,
        view.rows,
        theme.limits.min_cols,
        min_rows,
    });

    const cols: usize = view.cols;
    if (tui.cell.width(lw.buffered()) > cols) {
        var short_buf: [tui.scratch_len]u8 = undefined;
        var sw: std.Io.Writer = .fixed(&short_buf);
        try sw.print("need ≥{d}×{d}", .{ theme.limits.min_cols, min_rows });
        // Even the short form loses on a truly tiny window; a cut
        // message still beats one that wraps into a second row the
        // caller was told would not be used.
        try canvas.writeRaw(tui.cell.truncate(sw.buffered(), cols));
        try canvas.finish();
        return;
    }

    try canvas.writeRaw(lw.buffered());
    try canvas.finish();
}

/// Cells the flash decoration costs around the message itself:
/// four of separation, `« `, and ` »`.
const flash_decoration_w: usize = 4 + 2 + 2;

/// The footer is the last row of the frame, so it is written without a
/// line break — `canvas.finish()` supplies the erase codes.
fn renderFooter(canvas: *tui.Canvas, ui: *UiState, content_w: usize, needs_model: bool) !void {
    if (try renderExportNotice(canvas, ui, content_w)) return;
    var line_buf: [tui.scratch_len]u8 = undefined;
    var lw: std.Io.Writer = .fixed(&line_buf);
    try lw.print("{s} ", .{theme.margin_pad});
    // Without a model `[m]` goes first, but `[r]` stays lit: it opens
    // the same picker and then runs, so dimming it would advertise a
    // working key as a dead one.
    if (needs_model) {
        try lw.print("{s}[m]{s}odel  {s}[r]{s}un  ", .{ theme.accent, theme.label, theme.accent, theme.label });
    } else {
        try lw.print("{s}[r]{s}un  {s}[m]{s}odel  ", .{ theme.accent, theme.label, theme.accent, theme.label });
    }
    try lw.print("{s}[p]{s}arams  {s}[c]{s}ompare  {s}[o]{s}utput  {s}[e]{s}xport  {s}[q]{s}uit{s}", .{
        theme.accent, theme.label,  theme.accent, theme.label,  theme.accent,
        theme.label,  theme.accent, theme.label,  theme.accent, theme.label,
        theme.reset,
    });

    try writeFlash(&lw, ui, content_w);
    // Clipped like the race footer: with `[o]utput` the key list alone
    // outgrows the narrowest accepted layouts, and an overrunning
    // footer breaks the shared gutter every other row keeps.
    try canvas.writeRaw(tui.cell.truncate(lw.buffered(), theme.margin + content_w));
}

fn renderExportNotice(canvas: *tui.Canvas, ui: *UiState, content_w: usize) !bool {
    if (!ui.export_notice or ui.status_msg != null) return false;
    const notice = ui.currentFlash() orelse return false;
    var safe_buf: [256]u8 = undefined;
    try canvas.writeRaw(theme.margin_pad ++ theme.sub);
    try canvas.writeRaw(tui.cell.truncate(tui.sanitize.into(&safe_buf, notice), content_w));
    try canvas.writeRaw(theme.reset);
    return true;
}

test "export confirmation keeps its saved path visible in both narrow footers" {
    for ([_]bool{ false, true }) |race_view| {
        var buf: [2048]u8 = undefined;
        var out: std.Io.Writer = .fixed(&buf);
        var canvas = tui.Canvas.init(&out, theme.margin, theme.canvas_style);
        var ui: UiState = .{};
        const notice = "Saved exports/bench-20260920-143835.html";
        ui.flash(notice);
        ui.export_notice = true;
        if (race_view) try renderRaceFooter(&canvas, &ui, 52, false, false) else try renderFooter(&canvas, &ui, 52, false);
        try std.testing.expect(std.mem.indexOf(u8, out.buffered(), notice) != null);
        try std.testing.expect(tui.cell.width(out.buffered()) <= 54);
        try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "[r]") == null);
    }
}

/// The flash tail, shared by every footer.
///
/// Shared rather than copied because it was copied once and the copy
/// forgot it: the race footer took a `*UiState` and discarded it, so
/// `saved bench-….txt` and every engine failure went nowhere in race
/// mode. A second implementation of this is a second chance to omit it.
///
/// The flash is the only part of the frame whose length the layout does
/// not control — an engine's stderr line lands here verbatim. It takes
/// whatever space is left after the keybinds and is cut to fit, because
/// a footer that wraps costs a row the height budget already promised
/// to the terminal.
///
/// The cut is against the layout's content boundary, not the terminal
/// edge: `right_edge` is where rules stop and where the title bar's
/// status chip ends, so the flash respects the same gutter as every
/// other row. On a narrow terminal that can mean dropping a short
/// message which the raw column count would have fit — deliberate,
/// since the alternative is one element that ignores the margin.
fn writeFlash(lw: anytype, ui: *UiState, content_w: usize) !void {
    const msg = ui.currentFlash() orelse return;
    const right_edge = theme.margin + content_w;
    const used = tui.cell.width(lw.buffered());
    if (used + flash_decoration_w >= right_edge) return;

    // Filtered before it is measured: an escape sequence would
    // otherwise count as zero cells and defeat the cut.
    var safe_buf: [512]u8 = undefined;
    const safe = tui.sanitize.into(&safe_buf, msg);
    const room = right_edge - used - flash_decoration_w;
    try lw.print("    {s}« ", .{theme.sub});
    try lw.writeAll(tui.cell.truncate(safe, room));
    try lw.print(" »{s}", .{theme.reset});
}

// --- golden test ---------------------------------------------------
//
// The dashboard is the one place where a small refactor can silently
// change hundreds of cells. `dashboard.golden` pins the exact bytes
// for a fixed snapshot across five terminal sizes and six states.
//
// Regenerate deliberately, never just to make a red test go away —
// read the diff first:
//
//     zig build update-golden
//     git diff tools/zzzbench/ui/testdata/dashboard.golden
//
// The step runs `update_golden.zig`, which writes `goldenFrames`.

const golden = @embedFile("testdata/dashboard.golden");

/// Room for every golden frame at once.
pub const golden_buf_size = 8 * frame_buf_size;

/// Deterministic input for the golden: a sentinel telemetry frame,
/// filled histories, and a mid-run engine. Nothing here reads a clock.
pub fn goldenFrames(out: *std.Io.Writer) !void {
    var hello = proto.Hello{};
    fillName(&hello.device_name, "PHONE01");
    fillName(&hello.soc_name, "SOC001");
    // The race header reports whether the devices agree on a model, so
    // the fixture has to name one for that half of the header to be
    // pinned at all.
    fillName(&hello.model_name, "Sample-8B-Q4_0");
    hello.has_engine = 1;

    var tok = Series{ .floor = tok_floor_for_golden };
    for (0..47) |i| tok.push(6.0 + @as(f32, @floatFromInt(i % 13)) * 0.9);
    // The two lanes on one clock: load throughout, decode only for
    // the second half, so the golden pins both a filled lane and one
    // whose run has not reached the left edge yet.
    var tok_lane = Series{};
    var prime_lane = Series{};
    for (0..62) |i| {
        tok_lane.push(if (i < 31) 0 else 6.0 + @as(f32, @floatFromInt(i % 13)) * 0.9);
        prime_lane.push(@as(f32, @floatFromInt((i * 17) % 100)));
    }

    const frame = proto.sentinelFrame(12 * std.time.ns_per_s);

    var running_engine = engine_mod.Engine{ .name = "zzz", .tok_s = 12.34, .model = "Sample-8B-Q4_0" };
    running_engine.progress = .{
        .have_report = true,
        .phase = engine_mod.phase_decode,
        .token_index = 30,
        .tokens_total = 60,
        .decode_tok_s = 12.34,
        .prefill_tok_s = 96.4,
        // 30 tokens at 12.34 tok/s, so the elapsed time on screen
        // divides back into the headline rate.
        .elapsed_ns = 2_431_118_314,
    };
    var idle_engine = running_engine;
    idle_engine.progress.phase = engine_mod.phase_done;
    idle_engine.progress.token_index = 60;
    idle_engine.progress.elapsed_ns = 4_862_236_629;
    // Nothing run yet. Pinned because this is the state where the
    // header's colours regressed: the wordmark and model name were
    // dimmed until a run had happened, so identity "switched on"
    // partway through a session.
    const fresh_engine = engine_mod.Engine{ .name = "zzz", .tok_s = 0, .model = "Sample-8B-Q4_0" };
    // A probe's synthesized terminator: phase 2, every measurement
    // zero, because its engine exited without reporting one.
    var crashed_engine = engine_mod.Engine{ .name = "zzz", .tok_s = 0, .model = "Sample-8B-Q4_0" };
    crashed_engine.progress = .{
        .have_report = true,
        .phase = engine_mod.phase_done,
        .elapsed_ns = 1_204_000_000,
    };
    // A host-local engine killed mid-decode: it left a partial running
    // average behind, which is exactly the number not to headline.
    var killed_engine = running_engine;
    killed_engine.progress.markFailed();
    const compare = engine_mod.Engine{ .name = "llama.cpp", .tok_s = 25.0 };

    const sizes = [_]std.posix.winsize{
        .{ .col = 200, .row = 47, .xpixel = 0, .ypixel = 0 }, // three-up, double-size digits
        .{ .col = 132, .row = 36, .xpixel = 0, .ypixel = 0 }, // three-up
        .{ .col = 80, .row = 24, .xpixel = 0, .ypixel = 0 }, // paired columns, exact fit
        .{ .col = 60, .row = 22, .xpixel = 0, .ypixel = 0 }, // stacked columns
        .{ .col = 40, .row = 10, .xpixel = 0, .ypixel = 0 }, // too small
    };

    for (sizes) |ws| {
        const view = tui.Viewport.fromWinsize(ws, theme.limits);
        for ([_]struct { engine: engine_mod.Engine, compare: ?engine_mod.Engine }{
            .{ .engine = running_engine, .compare = compare },
            .{ .engine = idle_engine, .compare = compare },
            .{ .engine = idle_engine, .compare = null },
            .{ .engine = fresh_engine, .compare = null },
            .{ .engine = crashed_engine, .compare = null },
            .{ .engine = killed_engine, .compare = null },
        }) |case| {
            var ui = UiState{};
            try draw(.{
                .frame = &frame,
                .tok_lane = &tok_lane,
                .prime_lane = &prime_lane,
                .engine = case.engine,
                .compare = case.compare,
                .hello = &hello,
                .hardware_info = null,
                .peers = &.{},
            }, &ui, view, out);
        }

        // The same sizes again with peers attached. The peer section
        // was outside the golden entirely until the one-line row became
        // a three-row band — the most intricate block after the hero,
        // pinned by nothing. One peer reporting a finished run, one
        // telemetry-only, so both halves of the band are covered.
        var ui = UiState{};
        try draw(.{
            .frame = &frame,
            .tok_lane = &tok_lane,
            .prime_lane = &prime_lane,
            .engine = running_engine,
            .compare = compare,
            .hello = &hello,
            .hardware_info = null,
            .peers = &golden_peers,
        }, &ui, view, out);

        // With the OUTPUT panel open. Two frames, because the panel's
        // two interesting states are structural rather than cosmetic:
        // text long enough to wrap and be cut to the tail, and a run
        // that has produced nothing yet. The second is the one that
        // would otherwise go unpinned — an empty panel is easy to draw
        // as a hole the wrong height.
        for ([_]output_panel.Panel{
            .{
                .text = "A bonsai is not a small tree; it is a full tree held at a scale " ++
                    "where every decision about a branch becomes visible.\nThe wire carries " ++
                    "this as chunks, and the panel shows the tail.",
                .truncated = true,
                .complete = true,
                .gap = false,
                .running = false,
            },
            .{ .text = "", .truncated = false, .complete = false, .gap = false, .running = true },
        }) |panel| {
            var out_ui = UiState{ .show_output = true };
            try draw(.{
                .frame = &frame,
                .tok_lane = &tok_lane,
                .prime_lane = &prime_lane,
                .engine = running_engine,
                .compare = compare,
                .hello = &hello,
                .hardware_info = null,
                .peers = &golden_peers,
                .output = panel,
            }, &out_ui, view, out);
        }

        // And the same devices as a race, which shares none of the
        // band layout's geometry and so needs its own frames.
        var race_ui = UiState{};
        try draw(.{
            .frame = &frame,
            .tok_lane = &tok_lane,
            .prime_lane = &prime_lane,
            .engine = running_engine,
            .compare = compare,
            .hello = &hello,
            .hardware_info = null,
            .peers = &golden_peers,
            .multi = .race,
        }, &race_ui, view, out);
    }
}

/// Two peers with fixed contents, for the golden. Deterministic by
/// construction: no clock, no socket, and histories pushed from the
/// same arithmetic the hero's lanes use.
const golden_peers = blk: {
    @setEvalBranchQuota(20_000);
    var engine_peer = Peer{ .label = "Mac mini", .endpoint = "tcp:7780" };
    engine_peer.sock_opt = 0;
    engine_peer.have_frame = true;
    engine_peer.have_hello = true;
    var engine_hello = proto.Hello{};
    fillName(&engine_hello.soc_name, "M4");
    fillName(&engine_hello.model_name, "Sample-8B-Q4_0");
    @memcpy(&engine_peer.hello_buf, std.mem.asBytes(&engine_hello));
    engine_peer.current = proto.sentinelFrame(12 * std.time.ns_per_s);
    engine_peer.have_engine_report = true;
    engine_peer.engine_progress = .{
        .have_report = true,
        .phase = engine_mod.phase_done,
        .token_index = 320,
        .tokens_total = 320,
        .decode_tok_s = 57.30,
        .elapsed_ns = 5_584_642_233,
    };
    for (0..40) |i| engine_peer.tok_series.push(50.0 + @as(f32, @floatFromInt(i % 9)));
    // Prime history too, or the race column's lower lane draws empty
    // and the fixture covers only half of what a column shows.
    for (0..40) |i| engine_peer.prime_series.push(@as(f32, @floatFromInt((i * 11) % 100)));

    var telemetry_peer = Peer{ .label = "pi-5", .endpoint = "tcp:7781" };
    telemetry_peer.sock_opt = 0;
    telemetry_peer.have_frame = true;
    telemetry_peer.have_hello = true;
    var telemetry_hello = proto.Hello{};
    fillName(&telemetry_hello.soc_name, "BCM2712");
    @memcpy(&telemetry_peer.hello_buf, std.mem.asBytes(&telemetry_hello));
    telemetry_peer.current = proto.sentinelFrame(12 * std.time.ns_per_s);
    telemetry_peer.current.cpu_util_pct[0] = 37;
    telemetry_peer.current.sys_used_mb = 2048;
    telemetry_peer.current.sys_total_mb = 8192;
    for (0..40) |i| telemetry_peer.prime_series.push(@as(f32, @floatFromInt((i * 7) % 100)));

    break :blk [_]Peer{ engine_peer, telemetry_peer };
};

/// Matches the event loop's tok/s normaliser floor. Duplicated rather
/// than imported to keep the fixture independent of main.zig; the
/// fill mode is duplicated for the same reason, and matters more —
/// both histories draw into the same slot, so they must agree.
const tok_floor_for_golden: f32 = 20;

fn fillName(dst: []u8, s: []const u8) void {
    @memset(dst, 0);
    @memcpy(dst[0..s.len], s);
}

test "probe-supplied text cannot inject terminal commands" {
    // A hostile (or merely broken) probe controls every string in
    // Hello, and an engine controls the stderr line that reaches the
    // flash slot. None of it may reach the terminal as a command.
    var hello = proto.Hello{};
    fillName(&hello.device_name, "Pixel\x1b[2J");
    fillName(&hello.soc_name, "\x1b]0;pwned\x07");

    var engine = engine_mod.Engine{ .name = "zzz", .tok_s = 9.5, .model = "M\x1b[31mQ4" };
    engine.progress = .{ .have_report = true, .phase = 1, .decode_tok_s = 9.5 };

    const frame = proto.sentinelFrame(1);
    const series = Series{};
    var ui = UiState{};
    ui.flash("engine: \x1b[2Jboom");

    var buf: [frame_buf_size]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    try draw(.{
        .frame = &frame,
        .tok_lane = &series,
        .prime_lane = &series,
        .engine = engine,
        .compare = .{ .name = "llama\x1b[7m", .tok_s = 20 },
        .hello = &hello,
        .hardware_info = null,
        .peers = &.{},
    }, &ui, tui.Viewport.fromWinsize(
        .{ .col = 132, .row = 36, .xpixel = 0, .ypixel = 0 },
        theme.limits,
    ), &out);
    const text = out.buffered();

    // The dashboard never emits erase-screen or OSC itself, so either
    // appearing means injected bytes got through verbatim.
    try std.testing.expect(std.mem.indexOf(u8, text, "\x1b[2J") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\x1b]") == null);
    try std.testing.expect(std.mem.indexOfScalar(u8, text, 0x07) == null);
    // The payload still renders — filtered, not dropped.
    try std.testing.expect(std.mem.indexOf(u8, text, "Pixel?[2J") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "M?[31mQ4") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "engine: ?[2Jboom") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "llama?[7m") != null);
}

test "short accepted viewports never draw past the terminal" {
    var hello = proto.Hello{};
    fillName(&hello.device_name, "Pixel");

    const frame = proto.sentinelFrame(1);
    const series = Series{};
    var engine = engine_mod.Engine{ .name = "zzz", .tok_s = 12.34 };
    engine.progress = .{ .have_report = true, .phase = 1 };
    const compare = engine_mod.Engine{ .name = "llama.cpp", .tok_s = 25 };

    const cases = [_]struct {
        cols: u16,
        rows: u16,
        peers: []const Peer,
        min_required_rows: usize,
    }{
        // The engines here are mid-run, but the required height counts
        // the taller idle column: budgeting for the running state
        // alone would let a viewport accept a run and then fall out to
        // this message the moment the run finished.
        .{ .cols = 60, .rows = 22, .peers = &.{}, .min_required_rows = 27 },
        // A peer costs a three-row band plus the three-row section
        // heading, so one peer raises the floor by six rows over the
        // peerless case at this width.
        .{
            .cols = 80,
            .rows = 24,
            .peers = &.{Peer{ .label = "pixel", .endpoint = "tcp:7779" }},
            .min_required_rows = 30,
        },
    };

    for (cases) |case| {
        var ui = UiState{};
        var buf: [frame_buf_size]u8 = undefined;
        var out: std.Io.Writer = .fixed(&buf);
        try draw(.{
            .frame = &frame,
            .tok_lane = &series,
            .prime_lane = &series,
            .engine = engine,
            .compare = compare,
            .hello = &hello,
            .hardware_info = null,
            .peers = case.peers,
        }, &ui, tui.Viewport.fromWinsize(
            .{ .col = case.cols, .row = case.rows, .xpixel = 0, .ypixel = 0 },
            theme.limits,
        ), &out);

        const rendered = out.buffered();
        try std.testing.expect(renderedRowCount(rendered) <= case.rows);
        try std.testing.expect(std.mem.indexOf(u8, rendered, "terminal too small") != null);

        var need_buf: [16]u8 = undefined;
        const need = try std.fmt.bufPrint(&need_buf, "×{d})", .{case.min_required_rows});
        try std.testing.expect(std.mem.indexOf(u8, rendered, need) != null);
    }
}

test "tall viewport stays within the fixed frame buffer" {
    var hello = proto.Hello{};
    fillName(&hello.device_name, "Pixel");

    const frame = proto.sentinelFrame(1);
    var tok = Series{ .floor = tok_floor_for_golden };
    var tok_lane = Series{};
    var prime_lane = Series{};
    for (0..120) |i| {
        tok.push(5 + @as(f32, @floatFromInt(i % 30)));
        tok_lane.push(5 + @as(f32, @floatFromInt(i % 30)));
        prime_lane.push(@as(f32, @floatFromInt(i % 100)));
    }

    var peers = [_]Peer{
        .{ .label = "pixel-1", .endpoint = "tcp:7771", .sock_opt = 0, .have_frame = true, .current = frame },
        .{ .label = "pixel-2", .endpoint = "tcp:7772", .sock_opt = 0, .have_frame = true, .current = frame },
        .{ .label = "pixel-3", .endpoint = "tcp:7773", .sock_opt = 0, .have_frame = true, .current = frame },
        .{ .label = "pixel-4", .endpoint = "tcp:7774", .sock_opt = 0, .have_frame = true, .current = frame },
    };
    for (&peers) |*peer| {
        for (0..120) |i| peer.prime_series.push(@as(f32, @floatFromInt(i % 100)));
    }

    var engine = engine_mod.Engine{ .name = "zzz", .tok_s = 12.34 };
    engine.progress = .{ .have_report = true, .phase = 1 };
    const compare = engine_mod.Engine{ .name = "llama.cpp", .tok_s = 25 };
    var ui = UiState{};
    var buf: [frame_buf_size]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    try draw(.{
        .frame = &frame,
        .tok_lane = &tok_lane,
        .prime_lane = &prime_lane,
        .engine = engine,
        .compare = compare,
        .hello = &hello,
        .hardware_info = null,
        .peers = &peers,
    }, &ui, tui.Viewport.fromWinsize(
        .{ .col = 200, .row = 250, .xpixel = 0, .ypixel = 0 },
        theme.limits,
    ), &out);

    try std.testing.expect(out.buffered().len < frame_buf_size);
    try std.testing.expect(renderedRowCount(out.buffered()) <= 250);
}

fn renderedRowCount(rendered: []const u8) usize {
    return std.mem.count(u8, rendered, "\n") + 1;
}

/// Assert a frame stays inside the viewport it was drawn for. A row
/// wider than the terminal wraps, which costs a row and cascades; a
/// frame taller than the terminal scrolls the header away, and the
/// `[H`-only redraw never brings it back.
fn expectFits(rendered: []const u8, cols: u16, rows: u16, content_w: usize, label: []const u8) !void {
    // Rows are held to the layout's content boundary, not the terminal
    // edge. The distinction caught nothing for a long time and then
    // mattered: a footer that measured exactly the terminal's width
    // passed the edge check while overrunning the gutter every other
    // row keeps. The too-small message is the one exception — it is
    // drawn for viewports that have no gutters to honour, and clips to
    // the raw terminal width on purpose.
    const too_small = std.mem.indexOf(u8, rendered, "too small") != null or
        std.mem.indexOf(u8, rendered, "need ≥") != null;
    const budget: usize = if (too_small) cols else @min(cols, theme.margin + content_w);

    var line_count: usize = 0;
    var it = std.mem.splitScalar(u8, rendered, '\n');
    while (it.next()) |line| {
        line_count += 1;
        const w = tui.cell.width(line);
        if (w > budget) {
            std.debug.print(
                "{s}: row {d} is {d} cells wide against a budget of {d} ({d}-column terminal)\n",
                .{ label, line_count, w, budget, cols },
            );
            return error.RowOverflowsViewport;
        }
    }
    if (line_count > rows) {
        std.debug.print(
            "{s}: frame is {d} rows tall in a {d}-row terminal\n",
            .{ label, line_count, rows },
        );
        return error.FrameOverflowsViewport;
    }
}

test "no viewport renders a frame that overflows it" {
    // Widths and heights straddle every threshold the layout switches
    // on: the too-small floors, the stats column tiers (64, 100), the
    // vertical rhythm cutoff (28), and the double-size digit gates
    // (192 wide, 30 tall).
    //
    // The full product is ~380k frames. By default every viewport is
    // visited but draws only every `sample_stride`-th content case,
    // rotated per viewport so each case still meets many viewports.
    // `zig build ci` and `-Dexhaustive` draw all of them.
    const exhaustive = @import("test_options").exhaustive;
    const sample_stride = 32;
    const widths = [_]u16{ 20, 40, 55, 56, 57, 63, 64, 65, 79, 80, 99, 100, 101, 131, 132, 160, 191, 192, 199, 200, 201, 240 };
    const heights = [_]u16{ 6, 10, 19, 20, 21, 22, 23, 24, 25, 27, 28, 29, 30, 31, 36, 47, 60, 120 };

    // Wide glyphs in the title bar too: `nameSlice` hands back
    // whatever the probe sent, and a phone can be named in Chinese.
    var hello = proto.Hello{};
    fillName(&hello.device_name, "小米手机");
    fillName(&hello.soc_name, "SOC001");

    const frame = proto.sentinelFrame(12 * std.time.ns_per_s);
    var tok = Series{ .floor = tok_floor_for_golden };
    var tok_lane = Series{};
    var prime_lane = Series{};
    for (0..120) |i| {
        tok.push(6.0 + @as(f32, @floatFromInt(i % 13)) * 0.9);
        // Half the decode lane empty, so the sweep covers a lane that
        // is still filling as well as one that has wrapped.
        tok_lane.push(if (i < 60) 0 else 6.0 + @as(f32, @floatFromInt(i % 13)) * 0.9);
        prime_lane.push(@as(f32, @floatFromInt((i * 17) % 100)));
    }

    // These two carried a sentinel frame and nothing else — NaN CPU,
    // zero RAM, no engine report — so every band they produced took the
    // shortest possible path and the sweep proved nothing about the
    // widest one. One now reports an engine, the other real telemetry.
    var busy_frame = frame;
    busy_frame.cpu_util_pct[0] = 37;
    busy_frame.sys_used_mb = 2048;
    busy_frame.sys_total_mb = 8192;

    var all_peers = [_]Peer{
        .{
            .label = "pixel-1",
            .endpoint = "tcp:7771",
            .sock_opt = 0,
            .have_frame = true,
            .current = busy_frame,
            .have_engine_report = true,
            .engine_progress = .{
                .have_report = true,
                .phase = engine_mod.phase_done,
                .token_index = 320,
                .tokens_total = 320,
                .decode_tok_s = 24.76,
                .elapsed_ns = 12_923_020_000,
            },
        },
        .{ .label = "pixel-2", .endpoint = "tcp:7772", .sock_opt = 0, .have_frame = true, .current = busy_frame },
    };

    // Rates that exercise every `formatRate` branch, including the
    // clamp, since the number's glyph count drives the left column.
    const rates = [_]f32{ 0, 9.87, 12.34, 123.4, 1234, 999_999 };

    // The flash is the one span the layout does not control — an
    // engine's stderr line reaches it verbatim. A live 80×24 run
    // overflowed on `« saved bench-….txt »` while this sweep was
    // green, because the sweep only ever rendered an empty footer.
    const flashes = [_]?[]const u8{
        null,
        "saved bench-20260728-004212.txt",
        "engine: failed to mmap model: /very/long/path/to/a/model/Sample-8B-Q4_0.gguf: FileNotFound",
        // Double-width glyphs: an engine that localises its errors, or
        // a model file named in Chinese. Two cells each, so a bound
        // that counts code points lets the row through at twice its
        // measured width.
        "engine: 模型文件找不到 — 请检查路径是否正确，然后重新运行基准测试",
    };

    var running = engine_mod.Engine{ .name = "zzz", .tok_s = 0, .model = "Sample-8B-Q4_0" };
    running.progress = .{
        .have_report = true,
        .phase = 1,
        .token_index = 30,
        .tokens_total = 60,
        .decode_tok_s = 12.34,
        .prefill_tok_s = 96.4,
    };
    const compare = engine_mod.Engine{ .name = "llama.cpp", .tok_s = 25.0 };

    // No plate, plus every placement. The bitmap mark is the expensive
    // one to draw (two SGRs a cell) and the mask the cheap one, so both
    // formats are represented.
    // The output field rides the same axis: null (panel off), an empty
    // panel (the notes), and a textful panel with the gap warning — so
    // the sweep holds the panel's every row to the width budget at
    // every size it visits.
    const long_text = "The bonsai is not a small tree; it is a full tree held at a scale " ++
        "where every decision about a branch becomes visible.\n" ++
        "第二段落は中国語と日本語の文字で構成されています。改行も含まれます。";
    const plate_cases = [_]struct {
        credit: ?credit_mod.Credit,
        at: cli.LogoAt,
        output: ?output_panel.Panel = null,
    }{
        .{ .credit = null, .at = .right, .output = .{
            .text = "",
            .truncated = false,
            .complete = false,
            .gap = false,
            .running = false,
        } },
        .{
            .credit = .{
                .mark = test_marks.mask,
                .model = "Neutrino-0.6B",
                .detail = "Example · Q4_K_M",
            },
            .at = .right,
        },
        .{
            .credit = .{
                .mark = test_marks.bitmap,
                .model = "Sample-8B-Q4_0",
                .detail = "Example · Q4_0",
            },
            .at = .left,
        },
        // A wide synthetic plate, on the placement that puts
        // it beside a full-width chart row — the case that overran the
        // hero's row buffer when it was sized from the text cap.
        .{ .credit = .{
            .mark = test_marks.wide_bitmap,
            .model = "zzz",
            .detail = "synthetic wide plate",
        }, .at = .right, .output = .{
            .text = long_text,
            .truncated = true,
            .complete = false,
            .gap = true,
            .running = true,
        } },
        .{
            .credit = .{
                .mark = test_marks.mask,
                // A name long enough to need the plate's own clamp.
                .model = "a-model-name-far-longer-than-any-plate-should-carry",
                .detail = "模型文件找不到 — 请检查路径",
            },
            .at = .top,
        },
    };

    var buf: [frame_buf_size]u8 = undefined;
    var label_buf: [160]u8 = undefined;
    var viewport_index: usize = 0;
    var case_index: usize = 0;

    for (widths) |cols| {
        for (heights) |rows| {
            viewport_index += 1;
            const view = tui.Viewport.fromWinsize(
                .{ .col = cols, .row = rows, .xpixel = 0, .ypixel = 0 },
                theme.limits,
            );
            for ([_]usize{ 0, all_peers.len }) |peer_count| {
                for ([_]bool{ true, false }) |is_running| {
                    for ([_]bool{ true, false }) |with_compare| {
                        for (rates) |rate| for (flashes) |flash| {
                            var engine = running;
                            engine.tok_s = rate;
                            if (!is_running) engine.progress.phase = engine_mod.phase_done;

                            var ui = UiState{};
                            if (flash) |text| ui.flash(text);
                            // The plate is swept alongside everything
                            // else rather than in a test of its own:
                            // it takes width from the same budget the
                            // chart and the number draw from, so the
                            // interesting cases are the narrow
                            // viewports these loops already visit.
                            for (plate_cases) |plate| for ([_]cli.Multi{ .bands, .race }) |multi| {
                                case_index += 1;
                                if (!exhaustive and (case_index + viewport_index) % sample_stride != 0) continue;
                                var out: std.Io.Writer = .fixed(&buf);
                                ui.show_output = plate.output != null;
                                try draw(.{
                                    .frame = &frame,
                                    .tok_lane = &tok_lane,
                                    .prime_lane = &prime_lane,
                                    .engine = engine,
                                    .compare = if (with_compare) compare else null,
                                    .hello = &hello,
                                    .hardware_info = null,
                                    .peers = all_peers[0..peer_count],
                                    .credit = plate.credit,
                                    .credit_at = plate.at,
                                    .multi = multi,
                                    .output = plate.output,
                                }, &ui, view, &out);

                                const label = std.fmt.bufPrint(
                                    &label_buf,
                                    "{d}x{d} peers={d} running={} compare={} rate={d} flash={} plate={s} multi={s}",
                                    .{ cols, rows, peer_count, is_running, with_compare, rate, flash != null, @tagName(plate.at), @tagName(multi) },
                                ) catch "case";
                                try expectFits(out.buffered(), cols, rows, view.content_w, label);
                            };
                        };
                    }
                }
            }
        }
    }
}

test "the rendered dashboard matches the golden frames" {
    var buf: [golden_buf_size]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    try goldenFrames(&out);
    try std.testing.expectEqualStrings(golden, out.buffered());
}

test "an above plate uses the slack over the number, not extra rows" {
    // The `top` placement used to be a band of its own, which pushed the
    // whole hero down and left a chasm between the mark and the digits
    // it was crediting. It now drops into the gap the left column
    // already leaves, so on a terminal with any slack it costs nothing:
    // the frame is exactly as tall as it would be with no logo at all.
    var hello = proto.Hello{};
    const frame = proto.sentinelFrame(0);
    var tok = Series{};
    var prime = Series{};
    const engine = engine_mod.Engine{ .name = "zzz", .tok_s = 0, .model = "Neutrino-0.6B" };

    const plate = credit_mod.Credit{
        .mark = test_marks.mask,
        .mark_sm = test_marks.small_mask,
        .model = "Neutrino-0.6B",
        .detail = "Example · Q4_K_M",
    };
    const view = tui.Viewport.fromWinsize(
        .{ .col = 160, .row = 44, .xpixel = 0, .ypixel = 0 },
        theme.limits,
    );

    var with_buf: [frame_buf_size]u8 = undefined;
    var without_buf: [frame_buf_size]u8 = undefined;
    var with: std.Io.Writer = .fixed(&with_buf);
    var without: std.Io.Writer = .fixed(&without_buf);

    const base = Snapshot{
        .frame = &frame,
        .tok_lane = &tok,
        .prime_lane = &prime,
        .engine = engine,
        .compare = null,
        .hello = &hello,
        .hardware_info = null,
        .peers = &.{},
    };
    var ui_a = UiState{};
    var ui_b = UiState{};
    var snap = base;
    snap.credit = plate;
    snap.credit_at = .top;
    try draw(snap, &ui_a, view, &with);
    try draw(base, &ui_b, view, &without);

    // Same height, and the mark really is drawn.
    try std.testing.expectEqual(
        std.mem.count(u8, without.buffered(), "\n"),
        std.mem.count(u8, with.buffered(), "\n"),
    );
    try std.testing.expect(std.mem.indexOf(u8, with.buffered(), "Example") != null);
}

test "the race header reports model agreement rather than asserting it" {
    // The header claimed `same model · same prompt` and checked
    // neither. Two probes on different models made a ranking out of
    // incomparable numbers, and the header was the thing vouching for
    // it.
    var hello = proto.Hello{};
    fillName(&hello.model_name, "Neutrino-0.6B");

    var matching = Peer{ .label = "b", .endpoint = "tcp:2", .sock_opt = 0, .have_hello = true };
    var mh = proto.Hello{};
    fillName(&mh.model_name, "Neutrino-0.6B");
    @memcpy(&matching.hello_buf, std.mem.asBytes(&mh));

    var different = Peer{ .label = "c", .endpoint = "tcp:3", .sock_opt = 0, .have_hello = true };
    var dh = proto.Hello{};
    fillName(&dh.model_name, "Sample-8B-Q4_0");
    @memcpy(&different.hello_buf, std.mem.asBytes(&dh));

    // Not connected yet: it names no model, so it cannot disagree.
    const silent = Peer{ .label = "d", .endpoint = "tcp:4" };

    const frame = proto.sentinelFrame(1);
    const series = Series{};
    const base = Snapshot{
        .frame = &frame,
        .tok_lane = &series,
        .prime_lane = &series,
        .engine = .{ .name = "zzz", .tok_s = 0 },
        .compare = null,
        .hello = &hello,
        .hardware_info = null,
        .peers = &.{},
    };

    var one = base;
    one.peers = &.{matching};
    try std.testing.expectEqual(title_bar.ModelAgreement.same, modelAgreement(one));

    // A local runner selects a model without changing the telemetry-only
    // host probe's Hello. Its configured model still participates.
    var host_hello = proto.Hello{};
    var host = one;
    host.hello = &host_hello;
    host.engine.model = "Neutrino-0.6B";
    try std.testing.expectEqual(title_bar.ModelAgreement.same, modelAgreement(host));

    var mixed = base;
    mixed.peers = &.{ matching, different };
    try std.testing.expectEqual(title_bar.ModelAgreement.differ, modelAgreement(mixed));

    // One named model on its own agrees with nothing.
    var alone = base;
    alone.peers = &.{silent};
    try std.testing.expectEqual(title_bar.ModelAgreement.unknown, modelAgreement(alone));

    // And the claim reaches the frame only when it holds.
    var buf: [frame_buf_size]u8 = undefined;
    const view = tui.Viewport.fromWinsize(
        .{ .col = 160, .row = 40, .xpixel = 0, .ypixel = 0 },
        theme.limits,
    );
    for ([_]struct { snap: Snapshot, want: []const u8, absent: []const u8 }{
        .{ .snap = one, .want = "same model", .absent = "models differ" },
        .{ .snap = mixed, .want = "models differ", .absent = "same model" },
    }) |case| {
        var ui = UiState{};
        var out: std.Io.Writer = .fixed(&buf);
        var snap = case.snap;
        snap.multi = .race;
        try draw(snap, &ui, view, &out);
        const text = out.buffered();
        try std.testing.expect(std.mem.indexOf(u8, text, case.want) != null);
        try std.testing.expect(std.mem.indexOf(u8, text, case.absent) == null);
        // The claim that can never be checked is gone for good.
        try std.testing.expect(std.mem.indexOf(u8, text, "same prompt") == null);
    }
}

test "the race footer shows a flash, like every other footer" {
    // It took a `*UiState` and discarded it, so an export confirmation
    // or an engine failure went nowhere in race mode.
    var hello = proto.Hello{};
    const frame = proto.sentinelFrame(1);
    const series = Series{};
    var ui = UiState{};
    ui.flash("saved bench-20260730-101500.txt");

    var buf: [frame_buf_size]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    try draw(.{
        .frame = &frame,
        .tok_lane = &series,
        .prime_lane = &series,
        .engine = .{ .name = "zzz", .tok_s = 0 },
        .compare = null,
        .hello = &hello,
        .hardware_info = null,
        .peers = &.{},
        .multi = .race,
    }, &ui, tui.Viewport.fromWinsize(
        .{ .col = 160, .row = 40, .xpixel = 0, .ypixel = 0 },
        theme.limits,
    ), &out);

    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "saved bench-") != null);
}

test "a dashboard without a model leads with model selection in both layouts" {
    const hello = proto.Hello{};
    const frame = proto.sentinelFrame(0);
    const series = Series{};
    var buf: [frame_buf_size]u8 = undefined;
    for ([_]cli.Multi{ .bands, .race }) |multi| {
        for ([_]bool{ true, false }) |needs_model| {
            for ([_]u16{ 56, 100, 160 }) |cols| {
                var ui = UiState{};
                var out: std.Io.Writer = .fixed(&buf);
                const view = tui.Viewport.fromWinsize(
                    .{ .col = cols, .row = 32, .xpixel = 0, .ypixel = 0 },
                    theme.limits,
                );
                try draw(.{
                    .frame = &frame,
                    .tok_lane = &series,
                    .prime_lane = &series,
                    .engine = .{ .name = "zzz", .tok_s = 0 },
                    .compare = null,
                    .hello = &hello,
                    .hardware_info = null,
                    .peers = &.{},
                    .multi = multi,
                    .needs_model = needs_model,
                }, &ui, view, &out);
                const rendered = out.buffered();
                // `r` works either way — without a model it opens the
                // picker and then runs — so it is never drawn as dead.
                // The footer is the frame's last row, hence `last`.
                const run_key = std.mem.lastIndexOf(u8, rendered, theme.accent ++ "[r]").?;
                try std.testing.expect(std.mem.indexOf(u8, rendered, theme.disabled ++ "[r]") == null);
                if (needs_model) {
                    const model_key = std.mem.lastIndexOf(u8, rendered, theme.accent ++ "[m]").?;
                    try std.testing.expect(model_key < run_key);
                    try std.testing.expect(std.mem.indexOf(u8, rendered, "run benchmark") == null);
                    if (multi == .bands) {
                        try std.testing.expect(std.mem.indexOf(u8, rendered, "NO MODEL SELECTED") != null);
                        try std.testing.expect(std.mem.indexOf(u8, rendered, "choose a model") != null);
                    }
                }
                try expectFits(rendered, cols, 32, view.content_w, "model selection guidance");
            }
        }
    }
}
