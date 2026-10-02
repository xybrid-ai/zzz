//! The single title row: `zzzbench · device / soc / model` on the
//! left, a status chip and the run clock right-aligned. The three `z`s
//! carry the icon's neon ramp — see `writeWordmark` for why that is
//! text and not block art.
//!
//! The left half is identity — who is running what — and identity
//! does not change when a run starts or stops, so its colours do not
//! either. Only the chip and the clock on the right track state.
//!
//! This was state-dependent twice over and wrong both times: first
//! the whole bar dimmed unless a run was actively decoding, which
//! left a finished run — the frame that gets screenshotted — as the
//! least legible one; then it dimmed only before the first run, which
//! still meant the wordmark and model name "switched on" partway
//! through a session.

const std = @import("std");
const proto = @import("proto");
const tui = @import("tuiz");

const engine_mod = @import("../engine.zig");
const run_policy = @import("../run_policy.zig");
const theme = @import("theme.zig");
const UiState = @import("state.zig").UiState;

pub fn render(
    canvas: *tui.Canvas,
    hello: *const proto.Hello,
    engine: engine_mod.Engine,
    policy: ?run_policy.Shown,
    ui: *UiState,
    content_w: usize,
) !void {
    var line_buf: [tui.scratch_len]u8 = undefined;
    var lw: std.Io.Writer = .fixed(&line_buf);

    const device = proto.Hello.nameSlice(&hello.device_name);
    const soc = proto.Hello.nameSlice(&hello.soc_name);

    try lw.print("{s} {s}", .{ theme.margin_pad, theme.bold });
    try writeWordmark(&lw);
    try lw.writeAll(theme.reset);
    // Every name past this point came off the wire — filtered, never
    // printed raw. See tui/sanitize.zig.
    if (device.len > 0) try writeSegment(&lw, "·", theme.sub, device);
    if (soc.len > 0) try writeSegment(&lw, "/", theme.sub, soc);
    if (engine.model.len > 0) try writeSegment(&lw, "/", theme.accent, engine.model);
    try lw.writeAll(theme.reset);

    var st_buf: [96]u8 = undefined;
    var sw: std.Io.Writer = .fixed(&st_buf);
    try writeStatusChip(&sw, engine, ui);
    try writeClock(&sw, engine, ui);

    const st = sw.buffered();
    const st_w = tui.cell.width(st);
    const right_edge = theme.margin + content_w;

    // Configuration, not run state: it does not switch on when a run
    // starts, so it belongs on the identity half of the bar. Measured
    // before it is written — a title bar that overruns its width does
    // not get clipped by the canvas, it *wraps*, which pushes every
    // row below it past the height `draw` already promised.
    // Sized for the text plus its SGR escapes, which are ~19 bytes
    // apiece in truecolor.
    var policy_buf: [160]u8 = undefined;
    var pw: std.Io.Writer = .fixed(&policy_buf);
    if (policy) |p| {
        try pw.print(" {s}· {s}", .{ theme.sep, theme.faint });
        try run_policy.writeSummary(&pw, p);
        try pw.writeAll(theme.reset);
    }
    const policy_text = pw.buffered();
    if (policy_text.len > 0 and
        tui.cell.width(lw.buffered()) + tui.cell.width(policy_text) + st_w < right_edge)
    {
        try lw.writeAll(policy_text);
    }

    if (tui.cell.width(lw.buffered()) + st_w < right_edge) {
        try tui.cell.padTo(&lw, right_edge - st_w);
        try lw.writeAll(st);
    }
    try canvas.row(tui.cell.truncate(lw.buffered(), right_edge));
}

/// Whether the devices in a race are running the same model.
///
/// Only `same` licenses a claim of comparability, and only `differ`
/// contradicts one. `unknown` is the common case early in a session,
/// before every probe has sent its `Hello`.
pub const ModelAgreement = enum { unknown, same, differ };

/// The race variant: `zzzbench · 3 devices / model`, with what is
/// actually known about the comparison where the single-device bar
/// puts its clock.
///
/// The device name is gone because there is no primary device in this
/// layout — naming one would contradict the point of it.
///
/// It said `same model · same prompt` before, and asserted both. It
/// checked neither. Model agreement is now computed from the `Hello`
/// each probe sends and reported as what it is, including `models
/// differ` in orange when they do — a ranking of devices running
/// different models is not a ranking, and the header is the only place
/// that can say so. The prompt claim is gone entirely rather than
/// softened: `RunRequest` carries no prompt, so each probe runs
/// whatever it was configured with and nothing on the wire could
/// establish they match. A condition that cannot be checked should not
/// be printed beside a result.
///
/// `shown` is how many columns actually fit. When it is fewer than
/// `devices` the bar says so: a race that quietly leaves a competitor
/// out reads as a complete result that happens to be wrong, and the
/// count in this very header is what makes the omission detectable.
/// No `ui`, unlike the single-device bar: that one needs the session
/// to know whether the probe is reconnecting, whereas here every column
/// carries its own status chip and the bar has no state left to report.
pub fn renderRace(
    canvas: *tui.Canvas,
    devices: usize,
    shown: usize,
    model: []const u8,
    agreement: ModelAgreement,
    content_w: usize,
) !void {
    var line_buf: [tui.scratch_len]u8 = undefined;
    var lw: std.Io.Writer = .fixed(&line_buf);

    try lw.print("{s} {s}", .{ theme.margin_pad, theme.bold });
    try writeWordmark(&lw);
    try lw.writeAll(theme.reset);
    try lw.print(" {s}·{s} {d} devices", .{ theme.sep, theme.sub, devices });
    if (shown < devices) try lw.print("{s} ({d} shown){s}", .{ theme.orange, shown, theme.sub });
    if (model.len > 0) try writeSegment(&lw, "/", theme.accent, model);
    try lw.writeAll(theme.reset);

    var st_buf: [96]u8 = undefined;
    var sw: std.Io.Writer = .fixed(&st_buf);
    switch (agreement) {
        .same => try sw.print("{s}same model · avg tok/s{s}", .{ theme.label, theme.reset }),
        .differ => try sw.print("{s}models differ · avg tok/s{s}", .{ theme.orange, theme.reset }),
        .unknown => try sw.print("{s}avg tok/s{s}", .{ theme.label, theme.reset }),
    }

    const st = sw.buffered();
    const st_w = tui.cell.width(st);
    const right_edge = theme.margin + content_w;
    if (tui.cell.width(lw.buffered()) + st_w < right_edge) {
        try tui.cell.padTo(&lw, right_edge - st_w);
        try lw.writeAll(st);
    }
    try canvas.row(tui.cell.truncate(lw.buffered(), right_edge));
}

/// `zzzbench` with the three `z`s carrying the icon's neon ramp.
///
/// The mark is text rather than block art on purpose. The zzz icon
/// is a picture of the letters `ZZZ`, and one row of a title bar is two
/// subpixels tall — the art renders as solid noise there, and needs
/// about eleven rows before it reads at all. The terminal already draws
/// letters perfectly at one row, so what is worth carrying up here is
/// the colour ramp, which is the part of the mark that is actually its
/// own.
///
/// Shared rather than private so every full-screen the bench owns —
/// the dashboard, the device picker, the model picker, the sync
/// screen — opens on the same ramp instead of reinventing a header.
pub fn writeWordmark(lw: anytype) !void {
    for (theme.logo) |colour| try lw.print("{s}z", .{colour});
    try lw.print("{s}bench", .{theme.accent});
}

/// ` <sep> <text>` — one probe-supplied field of the title bar.
fn writeSegment(lw: anytype, sep_glyph: []const u8, text_color: []const u8, text: []const u8) !void {
    try lw.print(" {s}{s} {s}", .{ theme.sep, sep_glyph, text_color });
    try tui.sanitize.write(lw, text);
}

/// `● prefill` / `● decoding` while a run is live, `✓ complete` once
/// one has finished with a result, `✗ no result` when it ended
/// without one, `○ idle` before any, or `○ reconnecting` while the
/// primary probe is down — which outranks all of them, since a stale
/// reading matters more than what produced it.
pub fn writeStatusChip(lw: anytype, engine: engine_mod.Engine, ui: *UiState) !void {
    if (ui.isDisconnected()) {
        try lw.print("{s}○ reconnecting{s}", .{ theme.red, theme.reset });
        return;
    }
    switch (engine.progress.state()) {
        .running => try lw.print("{s}● {s}{s}", .{ theme.green, engine.progress.activityLabel(), theme.reset }),
        .complete => try lw.print("{s}✓ complete{s}", .{ theme.green, theme.reset }),
        .failed => try lw.print("{s}✗ no result{s}", .{ theme.red, theme.reset }),
        .never_ran => try lw.print("{s}○ idle{s}", .{ theme.faint, theme.reset }),
    }
}

/// Time to the right of the chip: how long the run has taken, or is
/// taking. Before any run there is no duration to report, so the slot
/// says what the bench is doing instead.
///
/// The clock is the engine's own decode elapsed, not the probe's
/// uptime. It used to be the latter, which put a number beside the
/// model name that had nothing to do with the run.
fn writeClock(lw: anytype, engine: engine_mod.Engine, ui: *UiState) !void {
    if (ui.isDisconnected()) return;
    switch (engine.progress.state()) {
        .never_ran => try lw.print("   {s}monitoring{s}", .{ theme.label, theme.reset }),
        // A run that never started has no duration to report; one
        // that died partway does, and it is worth seeing.
        .failed => if (engine.progress.elapsed_ns == 0) {
            try lw.print("   {s}monitoring{s}", .{ theme.label, theme.reset });
        } else {
            try lw.print("   {s}{d:.1} s{s}", .{ theme.label, engine.progress.elapsedSeconds(), theme.reset });
        },
        .running, .complete => try lw.print("   {s}{d:.1} s{s}", .{
            theme.label,
            engine.progress.elapsedSeconds(),
            theme.reset,
        }),
    }
}

fn chipFor(buf: []u8, progress: engine_mod.Progress, ui: *UiState) ![]const u8 {
    var w: std.Io.Writer = .fixed(buf);
    var engine = engine_mod.Engine{ .name = "zzz", .tok_s = 12 };
    engine.progress = progress;
    try writeStatusChip(&w, engine, &ui.*);
    return w.buffered();
}

test "the status chip reports reconnecting over any run state" {
    var ui = UiState{};
    ui.setStatus("probe disconnected");
    var buf: [128]u8 = undefined;
    const chip = try chipFor(&buf, .{ .have_report = true, .phase = engine_mod.phase_decode }, &ui);
    try std.testing.expect(std.mem.indexOf(u8, chip, "reconnecting") != null);
}

test "the status chip distinguishes prefill from decode" {
    var ui = UiState{};
    var buf: [128]u8 = undefined;
    const prefill = try chipFor(&buf, .{ .have_report = true, .phase = engine_mod.phase_prefill }, &ui);
    try std.testing.expect(std.mem.indexOf(u8, prefill, "prefill") != null);

    var buf2: [128]u8 = undefined;
    const decode = try chipFor(&buf2, .{ .have_report = true, .phase = engine_mod.phase_decode }, &ui);
    try std.testing.expect(std.mem.indexOf(u8, decode, "decoding") != null);
}

test "a finished run is complete, not idle" {
    // These were one state, and a capture of a finished run said
    // `○ idle` beside numbers that had just been measured.
    var ui = UiState{};
    var buf: [128]u8 = undefined;
    const done = try chipFor(&buf, .{
        .have_report = true,
        .phase = engine_mod.phase_done,
        // A completed run has tokens behind its rate — a report with a
        // rate and no tokens is a division, not a measurement, and now
        // reads as failed.
        .token_index = 32,
        .decode_tok_s = 59.44,
    }, &ui);
    try std.testing.expect(std.mem.indexOf(u8, done, "✓ complete") != null);
    try std.testing.expect(std.mem.indexOf(u8, done, "idle") == null);

    var buf2: [128]u8 = undefined;
    const fresh = try chipFor(&buf2, .{}, &ui);
    try std.testing.expect(std.mem.indexOf(u8, fresh, "○ idle") != null);
}

test "a run that produced nothing is never dressed as a completion" {
    var ui = UiState{};

    // A probe's synthesized terminator: phase 2, all measurements zero.
    var buf: [128]u8 = undefined;
    const synthesized = try chipFor(&buf, .{
        .have_report = true,
        .phase = engine_mod.phase_done,
        .decode_tok_s = 0,
    }, &ui);
    try std.testing.expect(std.mem.indexOf(u8, synthesized, "✗ no result") != null);
    try std.testing.expect(std.mem.indexOf(u8, synthesized, "complete") == null);

    // A host-local engine killed mid-decode, with a partial rate.
    var buf2: [128]u8 = undefined;
    const killed = try chipFor(&buf2, .{
        .have_report = true,
        .phase = engine_mod.phase_decode,
        .decode_tok_s = 30.0,
        .failed = true,
    }, &ui);
    try std.testing.expect(std.mem.indexOf(u8, killed, "✗ no result") != null);
    try std.testing.expect(std.mem.indexOf(u8, killed, "decoding") == null);
}

test "the clock shows the run's own elapsed time, not the probe's" {
    var ui = UiState{};
    var engine = engine_mod.Engine{ .name = "zzz", .tok_s = 59.44 };
    engine.progress = .{ .have_report = true, .phase = engine_mod.phase_done, .elapsed_ns = 41_600_000_000 };

    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeClock(&w, engine, &ui);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "41.6 s") != null);

    // Nothing run yet: there is no duration to report.
    var buf2: [128]u8 = undefined;
    var w2: std.Io.Writer = .fixed(&buf2);
    try writeClock(&w2, .{ .name = "zzz", .tok_s = 0 }, &ui);
    try std.testing.expect(std.mem.indexOf(u8, w2.buffered(), "monitoring") != null);
}

test "identity is coloured the same in every run state" {
    // The wordmark and the model name used to switch on partway
    // through a session — dim until something had run, gold after.
    // Identity does not depend on run state, so neither do its
    // colours; only the chip and clock to the right move.
    var hello = proto.Hello{};
    const dev = "Pixel 8";
    @memcpy(hello.device_name[0..dev.len], dev);
    const soc = "Tensor G3";
    @memcpy(hello.soc_name[0..soc.len], soc);

    const states = [_]engine_mod.Progress{
        .{},
        .{ .have_report = true, .phase = engine_mod.phase_prefill },
        .{ .have_report = true, .phase = engine_mod.phase_decode },
        .{ .have_report = true, .phase = engine_mod.phase_done, .elapsed_ns = 1_200_000_000 },
    };

    for (states) |progress| {
        var ui = UiState{};
        var engine = engine_mod.Engine{ .name = "zzz", .tok_s = 32.9, .model = "Neutrino-0.6B" };
        engine.progress = progress;

        var buf: [4096]u8 = undefined;
        var out: std.Io.Writer = .fixed(&buf);
        var canvas = tui.Canvas.init(&out, theme.margin, theme.canvas_style);
        try render(&canvas, &hello, engine, .{ .policy = .{} }, &ui, 120);
        const text = out.buffered();

        // The wordmark's ramp is part of identity too, so it is fixed
        // across states along with everything else on the left.
        inline for (theme.logo) |colour| {
            try std.testing.expect(std.mem.indexOf(u8, text, colour ++ "z") != null);
        }
        try std.testing.expect(std.mem.indexOf(u8, text, theme.accent ++ "bench") != null);
        try std.testing.expect(std.mem.indexOf(u8, text, theme.accent ++ "Neutrino-0.6B") != null);
        try std.testing.expect(std.mem.indexOf(u8, text, theme.sub ++ "Pixel 8") != null);
        try std.testing.expect(std.mem.indexOf(u8, text, theme.sub ++ "Tensor G3") != null);
    }
}

test "the wordmark still measures eight cells" {
    // The ramp is three SGRs inside a word, and `cell.width` has to see
    // through them: the bar right-aligns its chip against this
    // measurement, so a wordmark that measured wide would push the
    // clock off the edge.
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeWordmark(&w);
    try std.testing.expectEqual(@as(usize, "zzzbench".len), tui.cell.width(w.buffered()));
}

test "the wordmark colours each z and neither of the others" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeWordmark(&w);
    inline for (theme.logo) |colour| {
        try std.testing.expect(std.mem.indexOf(u8, w.buffered(), colour) != null);
    }
    // `bench` is the accent, as the whole word used to be.
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), theme.accent ++ "bench") != null);
}
