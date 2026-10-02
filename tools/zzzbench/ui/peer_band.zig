//! One comparison band per peer device.
//!
//! A peer used to be a divider and a single telemetry line, which read
//! as "some other machine is also plugged in". The point of a
//! multi-device window is the comparison, so a peer now gets a band:
//! an accent bar, its index and name, the rate it is achieving, and
//! the two measurements that rate is derived from, with the hardware
//! and model on a quieter second line.
//!
//! No `peak`. The wire carries a *running average* — tokens-so-far ÷
//! elapsed-so-far — and the maximum of a running average is not a rate
//! any device sustained; it is whatever the average happened to reach
//! while the run was still short. `ui/hero.zig` says the same at more
//! length, having shipped that number and had to withdraw it. What is
//! shown instead is `N tok · T s`, which divides back into the
//! headline and so cannot mislead.

const std = @import("std");
const proto = @import("proto");
const tui = @import("tuiz");

const engine_mod = @import("../engine.zig");
const Peer = @import("../peer.zig").Peer;
const run_policy = @import("../run_policy.zig");
const theme = @import("theme.zig");
const wire = @import("../wire.zig");

/// Rows one band occupies: two of content and the gap that separates
/// it from the next.
pub const rows_per_peer: usize = 3;

/// Rows the section spends once, whatever the peer count: a blank to
/// separate it from the stats grid above, the heading, and a blank
/// under it. The leading one is not decoration — without it the
/// heading butts straight onto the last stats row and reads as a
/// fourth stats column.
pub const heading_rows: usize = 3;

/// Left rule of a band, in the peer accent.
const bar = "▌";

/// Cells from the gutter to the device name — the bar, the index, and
/// the spaces around them. The sub-line indents to the same column so
/// the two rows of a band read as one block.
const name_col: usize = 8;

/// Cells given to the name before the rate starts, so rates line up
/// down the column whatever the devices are called. Squeezed on a
/// narrow terminal — see `writeTopRow`.
const name_w: usize = 18;
/// Shortest the name column is allowed to squeeze to before the row
/// starts dropping whole segments instead.
const name_w_min: usize = 8;

/// Cells the rate and its unit take: `999.99 avg`.
const rate_w: usize = 10;
/// Cells the widest status chip takes: `● decoding`.
const status_w: usize = 10;
/// Narrowest sparkline worth drawing in a band.
const spark_min: usize = 8;
/// Blank cells between the segments of the row.
const seg_gap: usize = 3;

/// Rows the whole peer section occupies, heading included.
pub fn rowCount(peers: usize) usize {
    return if (peers == 0) 0 else heading_rows + peers * rows_per_peer;
}

/// A blank, `P E E R S`, then another blank. Drawn once above the
/// bands.
pub fn renderHeading(canvas: *tui.Canvas) !void {
    try canvas.blank();
    try canvas.rowPrint("{s} {s}P E E R S{s}", .{ theme.margin_pad, theme.label, theme.reset });
    try canvas.blank();
}

/// `index` numbers the device within the window — the primary is 1, so
/// the first peer is 2. It is a label, not a keybind: nothing reads
/// digit keys yet, and the chip said "focus" before anything could
/// focus, which is a promise the footer never made and `readKeys`
/// cannot keep.
pub fn render(
    canvas: *tui.Canvas,
    p: *const Peer,
    index: usize,
    policy: ?run_policy.Shown,
    content_w: usize,
) !void {
    try writeTopRow(canvas, p, index, content_w);
    try writeSubRow(canvas, p, policy, content_w);
    try canvas.blank();
}

/// The band's top row, laid out against a hard budget.
///
/// Every column here is optional except the name and the rate. The
/// dashboard accepts terminals down to `theme.limits.min_cols`, where
/// the content is 52 cells — less than this row's natural footprint —
/// and a row that overruns does not get clipped by the canvas, it
/// *wraps*, which pushes every band below it and the footer past the
/// height `draw` already promised. So segments are measured before
/// they are written and dropped in reverse order of worth: sparkline,
/// then derivation, then the status chip, and the name squeezes last.
fn writeTopRow(canvas: *tui.Canvas, p: *const Peer, index: usize, content_w: usize) !void {
    var line_buf: [tui.scratch_len]u8 = undefined;
    var lw: std.Io.Writer = .fixed(&line_buf);
    const budget = theme.margin + content_w;

    // What the name may take: its usual column, less whatever the rate
    // and the chip cannot give up.
    const fixed = name_col + rate_w + seg_gap;
    const name_room = std.math.clamp(
        content_w -| fixed,
        name_w_min,
        name_w,
    );

    try writeBar(&lw, p);
    try lw.print(" {s}[{d}]{s}  ", .{ theme.faint, index, theme.reset });
    try lw.writeAll(theme.text);
    try tui.sanitize.write(&lw, tui.cell.truncate(displayName(p), name_room -| 1));
    try lw.writeAll(theme.reset);

    // Disconnected wins over have_frame: once the probe drops, the band
    // says so rather than keeping the last frame's numbers on screen as
    // though they were still arriving.
    if (p.sock_opt == null) return finish(canvas, &lw, budget, "disconnected — retrying...");
    if (!p.have_frame) return finish(canvas, &lw, budget, "connecting...");

    try tui.cell.padTo(&lw, theme.margin + name_col + name_room);
    if (p.have_engine_report) try writeRate(&lw, p) else try writeTelemetry(&lw, p);

    // Everything past here is spent only if it is affordable, and the
    // chip is reserved for while the optional parts are measured.
    const chip = statusWidth(p);
    if (p.have_engine_report) {
        try writeDerivation(&lw, p.engine_progress, room(&lw, budget -| chip));
    } else {
        try writeRam(&lw, &p.current, room(&lw, budget -| chip));
    }
    try writeSparkline(&lw, p, room(&lw, budget -| chip));

    if (room(&lw, budget) >= chip) {
        try tui.cell.padTo(&lw, budget - chip);
        try writeStatus(&lw, p);
    }
    try canvas.row(clip(lw.buffered(), budget));
}

/// Cells left before `lw` reaches `budget`.
fn room(lw: anytype, budget: usize) usize {
    const used = tui.cell.width(lw.buffered());
    return budget -| used;
}

/// Last line of defence: whatever the layout decided, the row cannot
/// be wider than its budget. `truncate` cuts on a cell boundary and
/// carries escapes through, so a clipped row keeps its colours and
/// never ends mid-sequence.
fn clip(line: []const u8, budget: usize) []const u8 {
    return tui.cell.truncate(line, budget);
}

/// The sparkline takes what is left, and is the first thing to go.
///
/// A gap at both ends, not just the leading one: `avail` runs to where
/// the status chip begins, so a sparkline that spent the whole of it
/// would end flush against `✓ done`.
fn writeSparkline(lw: anytype, p: *const Peer, avail: usize) !void {
    if (avail <= 2 * seg_gap) return;
    const w = avail - 2 * seg_gap;
    if (w < spark_min) return;
    try tui.padWidth(lw, seg_gap);
    try lw.writeAll(if (p.have_engine_report) theme.accent_dark else theme.axis);
    if (p.have_engine_report) {
        try p.tok_series.sparkline(lw, w);
    } else {
        try p.prime_series.sparkline(lw, w);
    }
    try lw.writeAll(theme.reset);
}

/// `SoC · model · t8 · 128/60`, indented under the name.
///
/// The policy rides here rather than on the top row because the top
/// row is already fighting for cells, and because a peer's thread
/// count belongs beside the hardware it is a choice about.
fn writeSubRow(canvas: *tui.Canvas, p: *const Peer, policy: ?run_policy.Shown, content_w: usize) !void {
    var line_buf: [tui.scratch_len]u8 = undefined;
    var lw: std.Io.Writer = .fixed(&line_buf);
    try writeBar(&lw, p);
    try tui.cell.padTo(&lw, theme.margin + name_col);
    try lw.writeAll(theme.label);

    var wrote = false;
    if (p.have_hello) {
        const soc = proto.Hello.nameSlice(&p.helloPtr().soc_name);
        const model = proto.Hello.nameSlice(&p.helloPtr().model_name);
        if (soc.len > 0) {
            try tui.sanitize.write(&lw, soc);
            wrote = true;
        }
        if (model.len > 0) {
            if (wrote) try lw.writeAll(" · ");
            try tui.sanitize.write(&lw, model);
            wrote = true;
        }
    }
    // No Hello yet, so the endpoint is all we know it by.
    if (!wrote) try tui.sanitize.write(&lw, p.endpoint);
    try lw.writeAll(theme.reset);

    // Appended only when it fits whole. A clipped `t8 · 12` would
    // read as a thread count and a token count that were never set.
    // Sized for the text plus its SGR escapes, which are ~19 bytes
    // apiece in truecolor.
    var policy_buf: [160]u8 = undefined;
    var pw: std.Io.Writer = .fixed(&policy_buf);
    if (policy) |in_force| {
        try pw.print(" {s}· ", .{theme.faint});
        try run_policy.writeSummary(&pw, in_force);
        try pw.writeAll(theme.reset);
    }
    const policy_text = pw.buffered();
    const budget = theme.margin + content_w;
    if (policy_text.len > 0 and
        tui.cell.width(lw.buffered()) + tui.cell.width(policy_text) <= budget)
    {
        try lw.writeAll(policy_text);
    }
    // Identity text is unbounded — an endpoint is a user-supplied
    // string and a model name comes off the wire — so this row needs
    // the same clip the top one does.
    try canvas.row(clip(lw.buffered(), theme.margin + content_w));
}

/// The band's left rule, lit only while the peer is actually reporting.
fn writeBar(lw: anytype, p: *const Peer) !void {
    const live = p.sock_opt != null and p.have_frame;
    try lw.print("{s} {s}{s}{s}", .{
        theme.margin_pad,
        if (live) theme.accent_dark else theme.rule,
        bar,
        theme.reset,
    });
}

/// `24.76 avg` — the rate alone. The pair it divides out of follows
/// separately, because that part is affordable only sometimes.
/// Nothing here is a peak; see the module header.
fn writeRate(lw: anytype, p: *const Peer) !void {
    const progress = p.engine_progress;
    const rate = if (engine_mod.validTokS(progress.decode_tok_s))
        progress.decode_tok_s
    else
        p.last_tok_s;

    if (engine_mod.validTokS(rate)) {
        try lw.print("{s}{s}{d: >6.2}{s} {s}avg{s}", .{
            theme.bold, theme.text, rate, theme.reset, theme.label, theme.reset,
        });
    } else {
        try lw.print("{s}{s: >6}{s}    ", .{ theme.faint, "—", theme.reset });
    }
}

/// The two measurements behind the rate, written only if `avail` cells
/// can hold them whole. Mid-run this is tokens *produced*, not the
/// run's target: a total there would contradict the average beside it,
/// which is computed from what has actually been decoded.
///
/// Rendered to a scratch buffer and measured first. A token count has
/// no bound worth relying on — a long run legitimately reaches seven
/// figures — so guessing its width from a constant is how the row ends
/// up wider than the terminal.
fn writeDerivation(lw: anytype, progress: engine_mod.Progress, avail: usize) !void {
    if (progress.token_index == 0 and progress.elapsed_ns == 0) return;

    var buf: [48]u8 = undefined;
    var dw: std.Io.Writer = .fixed(&buf);
    dw.print("{d} tok", .{progress.token_index}) catch return;
    if (progress.elapsed_ns > 0) {
        const secs = @as(f64, @floatFromInt(progress.elapsed_ns)) / std.time.ns_per_s;
        dw.print(" · {d:.2} s", .{secs}) catch return;
    }

    const text = dw.buffered();
    if (tui.cell.width(text) + seg_gap > avail) return;
    try tui.padWidth(lw, seg_gap);
    try lw.print("{s}{s}{s}", .{ theme.label, text, theme.reset });
}

/// A peer with no engine attached still has telemetry worth showing,
/// and a rate for it would be an invention.
fn writeTelemetry(lw: anytype, p: *const Peer) !void {
    const frame = &p.current;
    const ios_probe = p.have_hello and wire.isIosProbe(p.helloPtr());
    if (ios_probe or std.math.isNan(frame.cpu_util_pct[0])) {
        try lw.print("{s}     —{s}", .{ theme.faint, theme.reset });
    } else {
        try lw.print("{s}{d: >5.0}%{s} {s}prime{s}", .{
            theme.mid, frame.cpu_util_pct[0], theme.reset, theme.label, theme.reset,
        });
    }
}

/// `RAM 2.0/8G`, written only if `avail` holds it whole.
///
/// Measured rather than clipped, for the same reason the derivation is:
/// the row's final clip cuts on a cell boundary, which would leave
/// `RAM 4.0/12G` reading as `RAM 4.0/12` — a different number, quietly.
fn writeRam(lw: anytype, frame: *const proto.TelemetryFrame, avail: usize) !void {
    if (frame.sys_total_mb == 0) return;

    var buf: [32]u8 = undefined;
    var rw: std.Io.Writer = .fixed(&buf);
    rw.print("RAM {d:.1}/{d:.0}G", .{
        @as(f64, @floatFromInt(frame.sys_used_mb)) / 1024.0,
        @as(f64, @floatFromInt(frame.sys_total_mb)) / 1024.0,
    }) catch return;

    const text = rw.buffered();
    if (tui.cell.width(text) + seg_gap > avail) return;
    try tui.padWidth(lw, seg_gap);
    try lw.print("{s}{s}{s}", .{ theme.label, text, theme.reset });
}

/// Cells `writeStatus` will take. Reserved before the optional
/// segments are measured, so the chip is never the thing squeezed out
/// by a sparkline.
fn statusWidth(p: *const Peer) usize {
    return switch (p.engine_progress.state()) {
        .running => "● ".len + p.engine_progress.activityLabel().len,
        .complete => "✓ done".len,
        .failed => "✗ failed".len,
        .never_ran => "○ idle".len,
    };
}

fn writeStatus(lw: anytype, p: *const Peer) !void {
    switch (p.engine_progress.state()) {
        .running => try lw.print("{s}● {s}{s}", .{ theme.green, p.engine_progress.activityLabel(), theme.reset }),
        .complete => try lw.print("{s}✓ done{s}", .{ theme.green, theme.reset }),
        .failed => try lw.print("{s}✗ failed{s}", .{ theme.red, theme.reset }),
        .never_ran => try lw.print("{s}○ idle{s}", .{ theme.faint, theme.reset }),
    }
}

/// The label the user gave, or whatever the device called itself.
fn displayName(p: *const Peer) []const u8 {
    if (p.label.len > 0) return p.label;
    if (p.have_hello) {
        const dev = proto.Hello.nameSlice(&p.helloPtr().device_name);
        if (dev.len > 0) return dev;
    }
    return p.endpoint;
}

/// Close a band's top row early with a status in place of the numbers
/// it has none of. Only the top row — the caller still draws the
/// sub-line and the gap, so every state costs `rows_per_peer`.
fn finish(canvas: *tui.Canvas, lw: anytype, budget: usize, text: []const u8) !void {
    try tui.padWidth(lw, seg_gap);
    try lw.print("{s}{s}{s}", .{ theme.faint, text, theme.reset });
    try canvas.row(clip(lw.buffered(), budget));
}

const testing = std.testing;

fn testCanvas(out: *std.Io.Writer) tui.Canvas {
    return tui.Canvas.init(out, theme.margin, theme.canvas_style);
}

fn liveEnginePeer(label: []const u8) Peer {
    var p = Peer{ .label = label, .endpoint = "tcp:7780" };
    p.sock_opt = 0;
    p.have_frame = true;
    p.current = proto.sentinelFrame(1);
    p.have_engine_report = true;
    return p;
}

test "a band is two rows of content and a gap, in every state" {
    // The dashboard budgets `rows_per_peer` per peer before it knows
    // which state each one is in, so every path has to spend exactly
    // that many rows.
    var connected = liveEnginePeer("Mac mini");
    connected.engine_progress = .{ .have_report = true, .phase = 1, .decode_tok_s = 57.3 };

    var no_engine = Peer{ .label = "pi", .endpoint = "tcp:7781" };
    no_engine.sock_opt = 0;
    no_engine.have_frame = true;
    no_engine.current = proto.sentinelFrame(1);

    var connecting = Peer{ .label = "pixel", .endpoint = "tcp:7779" };
    connecting.sock_opt = 0;

    const down = Peer{ .label = "pixel", .endpoint = "tcp:7779" };

    for ([_]Peer{ connected, no_engine, connecting, down }) |peer| {
        var buf: [8192]u8 = undefined;
        var out: std.Io.Writer = .fixed(&buf);
        var canvas = testCanvas(&out);
        var p = peer;
        try render(&canvas, &p, 2, .{ .policy = .{} }, 120);
        try testing.expectEqual(rows_per_peer, std.mem.count(u8, out.buffered(), "\n"));
    }
}

test "a disconnected peer says so instead of showing stale numbers" {
    var p = liveEnginePeer("pixel");
    p.sock_opt = null; // socket dropped, frame still buffered
    p.engine_progress = .{ .have_report = true, .phase = 1, .decode_tok_s = 24.76 };

    var buf: [8192]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    var canvas = testCanvas(&out);
    try render(&canvas, &p, 2, .{ .policy = .{} }, 120);
    const text = out.buffered();

    try testing.expect(std.mem.indexOf(u8, text, "disconnected") != null);
    try testing.expect(std.mem.indexOf(u8, text, "24.76") == null);
}

test "a band shows the rate with the pair it divides out of, and no peak" {
    var p = liveEnginePeer("Mac mini");
    p.engine_progress = .{
        .have_report = true,
        .phase = engine_mod.phase_done,
        .token_index = 320,
        .tokens_total = 320,
        .decode_tok_s = 57.30,
        .elapsed_ns = 5_584_642_233,
    };

    var buf: [8192]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    var canvas = testCanvas(&out);
    try render(&canvas, &p, 3, .{ .policy = .{} }, 120);
    const text = out.buffered();

    try testing.expect(std.mem.indexOf(u8, text, "57.30") != null);
    try testing.expect(std.mem.indexOf(u8, text, "avg") != null);
    // 320 ÷ 5.58 = 57.3, so a reader can check the headline itself.
    try testing.expect(std.mem.indexOf(u8, text, "320 tok") != null);
    try testing.expect(std.mem.indexOf(u8, text, "5.58 s") != null);
    try testing.expect(std.mem.indexOf(u8, text, "✓ done") != null);
    // The statistic this layout deliberately does not carry.
    try testing.expect(std.mem.indexOf(u8, text, "peak") == null);
}

test "a peer with no engine shows telemetry rather than an invented rate" {
    var p = Peer{ .label = "pi", .endpoint = "tcp:7781" };
    p.sock_opt = 0;
    p.have_frame = true;
    p.current = proto.sentinelFrame(1);
    p.current.cpu_util_pct[0] = 42;
    p.current.sys_used_mb = 2048;
    p.current.sys_total_mb = 8192;

    var buf: [8192]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    var canvas = testCanvas(&out);
    try render(&canvas, &p, 2, .{ .policy = .{} }, 120);
    const text = out.buffered();

    try testing.expect(std.mem.indexOf(u8, text, "42%") != null);
    try testing.expect(std.mem.indexOf(u8, text, "RAM 2.0/8G") != null);
    try testing.expect(std.mem.indexOf(u8, text, "avg") == null);
}

test "a peer label and its Hello cannot inject terminal commands" {
    var p = Peer{ .label = "pi\x1b[2J", .endpoint = "tcp:7779" };
    p.sock_opt = 0;
    p.have_frame = true;
    p.have_hello = true;
    var hello = proto.Hello{};
    const soc = "\x1b]0;pwned\x07";
    @memcpy(hello.soc_name[0..soc.len], soc);
    @memcpy(&p.hello_buf, std.mem.asBytes(&hello));

    var buf: [8192]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    var canvas = testCanvas(&out);
    try render(&canvas, &p, 2, .{ .policy = .{} }, 120);
    const text = out.buffered();

    try testing.expect(std.mem.indexOf(u8, text, "\x1b[2J") == null);
    try testing.expect(std.mem.indexOf(u8, text, "\x1b]") == null);
}

test "the section costs nothing when there are no peers" {
    try testing.expectEqual(@as(usize, 0), rowCount(0));
    try testing.expectEqual(heading_rows + rows_per_peer, rowCount(1));
    try testing.expectEqual(heading_rows + 3 * rows_per_peer, rowCount(3));
}

/// Widest visible row in `frame`, erase codes excluded.
fn widestRow(frame: []const u8) usize {
    var w: usize = 0;
    var it = std.mem.splitScalar(u8, frame, '\n');
    while (it.next()) |line| {
        const body = if (std.mem.endsWith(u8, line, "\x1b[K")) line[0 .. line.len - 3] else line;
        w = @max(w, tui.cell.width(body));
    }
    return w;
}

test "no band overruns its width, at any accepted terminal size" {
    // A row wider than the terminal is not clipped by the canvas, it
    // wraps — which pushes every band below it and the footer past the
    // height `dashboard.draw` already committed to, and re-opens the
    // redraw cascade `expectFits` exists to prevent.
    //
    // Every one of these overran before the row was laid out against a
    // budget: at 52 cells of content an engine band measured 63, and a
    // seven-figure token count measured 70 at every width up to 72.
    var engine_peer = liveEnginePeer("Mac mini");
    engine_peer.engine_progress = .{
        .have_report = true,
        .phase = engine_mod.phase_done,
        .token_index = 320,
        .tokens_total = 320,
        .decode_tok_s = 57.30,
        .elapsed_ns = 5_584_642_233,
    };

    // Telemetry with real percentages and RAM: the values the sweep's
    // own fixtures lack, which is why it never caught any of this.
    var telemetry_peer = Peer{ .label = "pi-5", .endpoint = "tcp:7781" };
    telemetry_peer.sock_opt = 0;
    telemetry_peer.have_frame = true;
    telemetry_peer.current = proto.sentinelFrame(1);
    telemetry_peer.current.cpu_util_pct[0] = 37;
    telemetry_peer.current.sys_used_mb = 2048;
    telemetry_peer.current.sys_total_mb = 8192;

    // Identity text runs long from two directions: `Hello` caps its
    // names at 32 bytes, but the endpoint is user-supplied argv and has
    // no bound at all.
    var long_peer = Peer{
        .label = "a-device-with-a-very-long-name",
        .endpoint = "tcp:host.example.internal.very.long:7781",
    };
    long_peer.sock_opt = 0;
    long_peer.have_frame = true;
    long_peer.have_hello = true;
    var hello = proto.Hello{};
    const soc = "A-Very-Long-System-On-Chip-Name";
    const model = "a-long-model-identifier-Q4_K_M";
    @memcpy(hello.soc_name[0..soc.len], soc);
    @memcpy(hello.model_name[0..model.len], model);
    @memcpy(&long_peer.hello_buf, std.mem.asBytes(&hello));

    // A long run legitimately reaches seven figures.
    var big_peer = engine_peer;
    big_peer.engine_progress.token_index = 4_000_000;
    big_peer.engine_progress.elapsed_ns = 999_999_999_999;

    var connecting = Peer{ .label = "pixel", .endpoint = "tcp:7779" };
    connecting.sock_opt = 0;
    const down = Peer{ .label = "pixel", .endpoint = "tcp:7779" };

    const peers = [_]Peer{ engine_peer, telemetry_peer, long_peer, big_peer, connecting, down };

    // From the narrowest content the dashboard accepts to the widest.
    for ([_]usize{ 52, 53, 56, 60, 63, 64, 72, 96, 196 }) |content_w| {
        for (peers) |peer| {
            var buf: [16384]u8 = undefined;
            var out: std.Io.Writer = .fixed(&buf);
            var canvas = testCanvas(&out);
            var p = peer;
            try render(&canvas, &p, 2, .{ .policy = .{} }, content_w);
            const w = widestRow(out.buffered());
            if (w > theme.margin + content_w) {
                std.debug.print(
                    "band overran: content_w={d} budget={d} widest={d}\n",
                    .{ content_w, theme.margin + content_w, w },
                );
                return error.BandOverflowsWidth;
            }
            try testing.expectEqual(rows_per_peer, std.mem.count(u8, out.buffered(), "\n"));
        }
    }
}

test "a narrow band gives up its sparkline and derivation, never its rate" {
    // The drop order is the point: what a comparison window is for is
    // the number, so the number is the last thing to go.
    var p = liveEnginePeer("Mac mini");
    p.engine_progress = .{
        .have_report = true,
        .phase = engine_mod.phase_done,
        .token_index = 320,
        .tokens_total = 320,
        .decode_tok_s = 57.30,
        .elapsed_ns = 5_584_642_233,
    };

    var narrow_buf: [8192]u8 = undefined;
    var narrow_out: std.Io.Writer = .fixed(&narrow_buf);
    var narrow = testCanvas(&narrow_out);
    try render(&narrow, &p, 2, .{ .policy = .{} }, 52);
    const tight = narrow_out.buffered();

    var wide_buf: [8192]u8 = undefined;
    var wide_out: std.Io.Writer = .fixed(&wide_buf);
    var wide = testCanvas(&wide_out);
    try render(&wide, &p, 2, .{ .policy = .{} }, 120);
    const roomy = wide_out.buffered();

    // The rate survives everywhere.
    try testing.expect(std.mem.indexOf(u8, tight, "57.30") != null);
    try testing.expect(std.mem.indexOf(u8, roomy, "57.30") != null);
    // The derivation is affordable only with room to spare.
    try testing.expect(std.mem.indexOf(u8, tight, "320 tok") == null);
    try testing.expect(std.mem.indexOf(u8, roomy, "320 tok") != null);
}
