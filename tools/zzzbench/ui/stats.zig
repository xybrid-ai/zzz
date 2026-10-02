//! The CPU / THERMAL / MEMORY block under the hero.
//!
//! Each column is a four-row cell drawn one row at a time, so the same
//! cell functions serve all three width tiers: three-up columns on a
//! wide terminal, CPU over a thermal/memory pair at mid widths, and a
//! plain stack when neither fits.

const std = @import("std");
const proto = @import("proto");
const tui = @import("tuiz");

const theme = @import("theme.zig");

/// Column widths for the three-up layout.
const cpu_col_w: usize = 40;
const thermal_col_w: usize = 32;

/// Rows in one column cell: a section label plus three readings.
const cell_rows: usize = 4;

/// Width at or above which all three columns sit side by side, and
/// the width at which thermal/memory can still be paired.
const three_up_min_w: usize = 100;
const paired_min_w: usize = 64;

/// Everything a stats row needs to know about the current sample.
pub const Context = struct {
    frame: *const proto.TelemetryFrame,
    hello: *const proto.Hello,
    hardware_info: ?*const proto.HardwareInfo,
    /// The iOS probe app cannot read per-core utilisation or CPU
    /// frequencies, so those rows are replaced rather than rendered as
    /// sampled zeros.
    ios_probe: bool,
    /// No run in flight: readings dim and the verdict changes voice.
    idle: bool,
};

/// Rows this block will occupy at `content_w`. The hero's height
/// budget needs this before anything is drawn.
pub fn rowCount(content_w: usize) usize {
    if (content_w >= three_up_min_w) return cell_rows;
    if (content_w >= paired_min_w) return 2 * cell_rows;
    return 3 * cell_rows -| 1;
}

pub fn render(canvas: *tui.Canvas, ctx: Context, content_w: usize) !void {
    if (content_w >= three_up_min_w) return renderThreeUp(canvas, ctx, content_w);
    if (content_w >= paired_min_w) return renderPaired(canvas, ctx);
    return renderStacked(canvas, ctx);
}

/// Columns spread with the width like the mock's grid — thermal at
/// ~30%, memory at ~55% — instead of clustering against the left edge
/// of a wide terminal.
fn renderThreeUp(canvas: *tui.Canvas, ctx: Context, content_w: usize) !void {
    const cpu_w: usize = theme.margin + @max(cpu_col_w, content_w * 3 / 10);
    const mem_start: usize = @max(cpu_w + thermal_col_w, theme.margin + content_w * 11 / 20);
    var r: usize = 0;
    while (r < cell_rows) : (r += 1) {
        var line_buf: [tui.scratch_len]u8 = undefined;
        var lw: std.Io.Writer = .fixed(&line_buf);
        try lw.writeAll(theme.margin_pad);
        try writeCpuCell(&lw, r, ctx);
        try tui.cell.padTo(&lw, cpu_w);
        try writeThermalCell(&lw, r, ctx);
        try tui.cell.padTo(&lw, mem_start);
        try writeMemCell(&lw, r, ctx);
        try canvas.row(lw.buffered());
    }
}

/// Mid widths: CPU full width, then THERMAL and MEMORY paired, so the
/// block still fits an 80×24 terminal.
fn renderPaired(canvas: *tui.Canvas, ctx: Context) !void {
    var r: usize = 0;
    while (r < cell_rows) : (r += 1) {
        var line_buf: [tui.scratch_len]u8 = undefined;
        var lw: std.Io.Writer = .fixed(&line_buf);
        try lw.writeAll(theme.margin_pad);
        try writeCpuCell(&lw, r, ctx);
        try canvas.row(lw.buffered());
    }
    r = 0;
    while (r < cell_rows) : (r += 1) {
        var line_buf: [tui.scratch_len]u8 = undefined;
        var lw: std.Io.Writer = .fixed(&line_buf);
        try lw.writeAll(theme.margin_pad);
        try writeThermalCell(&lw, r, ctx);
        try tui.cell.padTo(&lw, theme.margin + thermal_col_w);
        try writeMemCell(&lw, r, ctx);
        try canvas.row(lw.buffered());
    }
}

/// Narrow terminals: same cells, one section at a time. Taller, but
/// nothing truncates.
fn renderStacked(canvas: *tui.Canvas, ctx: Context) !void {
    var section: usize = 0;
    while (section < 3) : (section += 1) {
        var r: usize = 0;
        while (r < cell_rows) : (r += 1) {
            var line_buf: [tui.scratch_len]u8 = undefined;
            var lw: std.Io.Writer = .fixed(&line_buf);
            try lw.writeAll(theme.margin_pad);
            switch (section) {
                0 => try writeCpuCell(&lw, r, ctx),
                1 => try writeThermalCell(&lw, r, ctx),
                else => try writeMemCell(&lw, r, ctx),
            }
            // An empty cell row (iOS thermal row 2) contributes
            // nothing but the gutter — drop it rather than emit a
            // blank line mid-section.
            if (lw.buffered().len == theme.margin) continue;
            try canvas.row(lw.buffered());
        }
    }
}

/// One row (0..3) of the CPU column. Row 0 is the section label;
/// Android rows are the three cluster bars, iOS rows swap in the chip
/// name plus app-CPU.
pub fn writeCpuCell(lw: anytype, row: usize, ctx: Context) !void {
    if (row == 0) {
        try lw.print(" {s}C P U{s}", .{ theme.label, theme.reset });
        return;
    }
    const frame = ctx.frame;
    if (ctx.ios_probe) {
        switch (row) {
            1 => try writeChipRow(lw, ctx),
            2 => try writeCoreRow(lw, "app", frame.cpu_util_pct[0], 0, ctx.idle),
            else => try lw.print(" {s}per-core util/MHz unavailable{s}", .{ theme.faint, theme.reset }),
        }
        return;
    }
    switch (row) {
        1 => try writeCoreRow(lw, "prime", frame.cpu_util_pct[0], frame.cpu_freq_mhz[0], ctx.idle),
        2 => try writeCoreRow(lw, "big-0", frame.cpu_util_pct[1], frame.cpu_freq_mhz[1], ctx.idle),
        else => try writeCoreRow(lw, "little", frame.cpu_util_pct[5], frame.cpu_freq_mhz[5], ctx.idle),
    }
}

/// The iOS chip name, preferring the HardwareInfo frame's SoC name
/// over Hello's. The raw machine identifier is never shown — an
/// unrecognised `iPhone99,9` must read as "unknown", not as a chip.
fn writeChipRow(lw: anytype, ctx: Context) !void {
    var soc_name: []const u8 = proto.Hello.nameSlice(&ctx.hello.soc_name);
    if (ctx.hardware_info) |hw| {
        const hw_soc = proto.HardwareInfo.nameSlice(&hw.soc_name);
        if (hw_soc.len > 0) soc_name = hw_soc;
    }
    if (soc_name.len == 0) {
        try lw.print(" {s}chip   {s}—{s}", .{ theme.mid, theme.faint, theme.reset });
        return;
    }
    // Probe-supplied — filtered, never printed raw (tui/sanitize.zig).
    try lw.print(" {s}chip   {s}", .{ theme.mid, theme.text });
    try tui.sanitize.write(lw, soc_name);
    try lw.writeAll(theme.reset);
}

/// ` name   {heat bar} NN%  N.NN GHz`, sentinel-aware. `util` is NaN
/// before the first jiffy delta accumulates; `freq_mhz` is 0 when the
/// sysfs node isn't readable. Idle dims the percent readout.
fn writeCoreRow(lw: anytype, name: []const u8, util: f32, freq_mhz: u32, idle: bool) !void {
    try lw.print(" {s}{s: <6} {s}", .{ theme.mid, name, theme.reset });
    if (std.math.isNan(util)) {
        try tui.meter.write(lw, 0, theme.heat_ramp.at(0), theme.meter_track);
        try lw.print(" {s}  —%{s}", .{ theme.faint, theme.reset });
    } else {
        const t = std.math.clamp(util / 100.0, 0, 1);
        try tui.meter.write(lw, @intFromFloat(util), theme.heat_ramp.at(t), theme.meter_track);
        try lw.print(" {s}{d: >3.0}%{s}", .{ if (idle) theme.sub else theme.text, util, theme.reset });
    }
    if (freq_mhz == 0) {
        try lw.print("  {s}— GHz{s}", .{ theme.faint, theme.reset });
    } else {
        try lw.print("  {s}{d:.2} GHz{s}", .{
            theme.faint,
            @as(f64, @floatFromInt(freq_mhz)) / 1000.0,
            theme.reset,
        });
    }
}

/// One row (0..3) of the THERMAL column: skin + soc heat bars and the
/// nominal / warm / throttling verdict.
pub fn writeThermalCell(lw: anytype, row: usize, ctx: Context) !void {
    if (row == 0) {
        try lw.print(" {s}T H E R M A L{s}", .{ theme.label, theme.reset });
        return;
    }
    const frame = ctx.frame;
    if (ctx.ios_probe) {
        switch (row) {
            1 => try lw.print(" {s}state  {s}{s}{s}", .{
                theme.mid,
                theme.text,
                iosThermalStateName(frame.ios_thermal_state),
                theme.reset,
            }),
            2 => {},
            else => try writeThrottleVerdict(lw, ctx),
        }
        return;
    }
    switch (row) {
        // lo/hi map the interesting range onto the bar and the heat
        // ramp — the same spans the mock uses.
        1 => try writeTempRow(lw, "skin", frame.skin_temp_mc, 26.0, 46.0),
        2 => try writeTempRow(lw, "soc", frame.soc_temp_mc, 40.0, 95.0),
        else => try writeThrottleVerdict(lw, ctx),
    }
}

/// ` name  {heat bar} NN.N°C`, dim dash on the INT32_MIN sentinel. The
/// reading inherits the bar's heat colour so hot values read hot.
fn writeTempRow(lw: anytype, name: []const u8, mc: i32, lo: f32, hi: f32) !void {
    try lw.print(" {s}{s: <5}{s}", .{ theme.mid, name, theme.reset });
    if (mc == std.math.minInt(i32)) {
        try tui.meter.write(lw, 0, theme.heat_ramp.at(0), theme.meter_track);
        try lw.print(" {s}    —{s}", .{ theme.faint, theme.reset });
        return;
    }
    const v = @as(f32, @floatFromInt(mc)) / 1000.0;
    const t = std.math.clamp((v - lo) / (hi - lo), 0, 1);
    const col = theme.heat_ramp.at(t);
    try tui.meter.write(lw, @intFromFloat(t * 100), col, theme.meter_track);
    try tui.color.writeFg(lw, col);
    try lw.print(" {d: >5.1}°C{s}", .{ v, theme.reset });
}

/// Warning band for the SoC sensor, in millidegrees.
const soc_warm_mc: i32 = 74_000;

/// `✓ thermals nominal` (running) or `✓ cooled — ready to run`
/// (idle), `▲ soc warm`, `▲ thermal throttling`.
fn writeThrottleVerdict(lw: anytype, ctx: Context) !void {
    const frame = ctx.frame;
    const nominal: []const u8 = if (ctx.idle) "✓ cooled — ready to run" else "✓ thermals nominal";
    if (frame.throttling != 0) {
        try lw.print(" {s}▲ thermal throttling{s}", .{ theme.red, theme.reset });
        return;
    }
    if (ctx.ios_probe) {
        if (frame.ios_thermal_state == @intFromEnum(proto.IosThermalState.serious) or
            frame.ios_thermal_state == @intFromEnum(proto.IosThermalState.critical))
        {
            try lw.print(" {s}▲ thermal pressure{s}", .{ theme.red, theme.reset });
        } else if (frame.ios_thermal_state == @intFromEnum(proto.IosThermalState.fair)) {
            try lw.print(" {s}▲ running warm{s}", .{ theme.orange, theme.reset });
        } else {
            try lw.print(" {s}{s}{s}", .{ theme.teal, nominal, theme.reset });
        }
        return;
    }
    if (frame.soc_temp_mc != std.math.minInt(i32) and frame.soc_temp_mc > soc_warm_mc) {
        try lw.print(" {s}▲ soc warm{s}", .{ theme.orange, theme.reset });
    } else {
        try lw.print(" {s}{s}{s}", .{ theme.teal, nominal, theme.reset });
    }
}

/// One row (0..3) of the MEMORY column: the used/total bar, then the
/// engine footprint plus power (Android) or battery (iOS). Idle with
/// the engine gone renders `model unloaded` instead of `engine 0 MB`.
pub fn writeMemCell(lw: anytype, row: usize, ctx: Context) !void {
    const frame = ctx.frame;
    switch (row) {
        0 => try lw.print(" {s}M E M O R Y{s}", .{ theme.label, theme.reset }),
        1 => {
            if (frame.sys_total_mb == 0) {
                try lw.print(" {s}—{s}", .{ theme.faint, theme.reset });
                return;
            }
            try lw.writeAll(" ");
            const fill = if (ctx.idle) theme.memory_fill_idle else theme.memory_fill;
            try tui.meter.write(lw, frame.sys_used_mb * 100 / frame.sys_total_mb, fill, theme.meter_track);
            try lw.print(" {s}{d:.2}{s}/{d:.2} GB{s}", .{
                if (ctx.idle) theme.sub else theme.text,
                @as(f64, @floatFromInt(frame.sys_used_mb)) / 1024.0,
                theme.faint,
                @as(f64, @floatFromInt(frame.sys_total_mb)) / 1024.0,
                theme.reset,
            });
        },
        2 => try writeFootprintRow(lw, ctx),
        else => {},
    }
}

fn writeFootprintRow(lw: anytype, ctx: Context) !void {
    const frame = ctx.frame;
    if (ctx.ios_probe) {
        try lw.print(" {s}app {s}{d} MB{s}", .{ theme.label, theme.sub, frame.proc_rss_mb, theme.reset });
        if (frame.ios_battery_pct != proto.ios_battery_pct_unavailable) {
            try lw.print(" {s}· batt {s}{d}%{s}", .{ theme.label, theme.sub, frame.ios_battery_pct, theme.reset });
        }
        return;
    }
    if (ctx.idle and frame.proc_rss_mb == 0) {
        try lw.print(" {s}model unloaded{s}", .{ theme.label, theme.reset });
        return;
    }
    try lw.print(" {s}engine {s}{d} MB{s}", .{ theme.label, theme.sub, frame.proc_rss_mb, theme.reset });
    if (frame.power_mw != std.math.maxInt(u32)) {
        try lw.print(" {s}· {s}{d:.1} W{s}", .{
            theme.label,
            theme.sub,
            @as(f64, @floatFromInt(frame.power_mw)) / 1000.0,
            theme.reset,
        });
    }
}

fn iosThermalStateName(state: u8) []const u8 {
    return switch (state) {
        @intFromEnum(proto.IosThermalState.nominal) => "nominal",
        @intFromEnum(proto.IosThermalState.fair) => "fair",
        @intFromEnum(proto.IosThermalState.serious) => "serious",
        @intFromEnum(proto.IosThermalState.critical) => "critical",
        else => "unknown",
    };
}

test "writeMemCell hides battery on the sentinel frame" {
    const frame = proto.sentinelFrame(0);
    const hello = proto.Hello{};

    var buf: [tui.scratch_len]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try writeMemCell(&writer, 2, .{
        .frame = &frame,
        .hello = &hello,
        .hardware_info = null,
        .ios_probe = true,
        .idle = false,
    });

    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "batt") == null);
}

test "writeCpuCell keeps an unknown machine id out of the chip name" {
    const frame = proto.sentinelFrame(0);
    const hello = proto.Hello{};
    var hw = proto.HardwareInfo{};
    const machine = "iPhone99,9";
    @memcpy(hw.machine[0..machine.len], machine);

    var buf: [tui.scratch_len]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try writeCpuCell(&writer, 1, .{
        .frame = &frame,
        .hello = &hello,
        .hardware_info = &hw,
        .ios_probe = true,
        .idle = false,
    });
    const out = writer.buffered();

    // soc_name is empty everywhere, so the chip row falls back to a
    // dash — the raw machine id must never leak in as the chip name.
    try std.testing.expect(std.mem.indexOf(u8, out, "chip") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "iPhone99,9") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "—") != null);
}

test "rowCount matches what render actually emits at each tier" {
    const frame = proto.sentinelFrame(0);
    const hello = proto.Hello{};
    const ctx = Context{
        .frame = &frame,
        .hello = &hello,
        .hardware_info = null,
        .ios_probe = false,
        .idle = true,
    };
    for ([_]usize{ 120, 80, 50 }) |content_w| {
        var buf: [16384]u8 = undefined;
        var out: std.Io.Writer = .fixed(&buf);
        var canvas = tui.Canvas.init(&out, theme.margin, theme.canvas_style);
        try render(&canvas, ctx, content_w);
        try std.testing.expectEqual(
            rowCount(content_w),
            std.mem.count(u8, out.buffered(), "\n"),
        );
    }
}
