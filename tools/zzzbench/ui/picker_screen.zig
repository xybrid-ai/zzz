//! Every full-screen frame the bench draws that is not the dashboard:
//! the device list, the model list, and the sync screen that replaces
//! the model list while a chosen model is hashed, uploaded, verified.
//!
//! All of them draw through the same canvas, gutter, and palette as
//! the dashboard, so a picker does not drop the operator out of the
//! bench's visual language into raw terminal output. That was the
//! first cut and it looked like a different program.
//!
//! The sync screen exists because model sync blocks. A 500 MiB push
//! plus an on-device SHA-256 is tens of seconds during which the
//! picker used to sit frozen on screen with the cursor still on the
//! row — indistinguishable from a hang. Every phase renders a frame
//! before it starts work, and the upload polls the growing remote
//! file so the bar actually moves.
//!
//! The embedded model and Compare screens use dashboard stdout. The
//! startup device screen uses stderr so `zzzbench | tee` still works.

const std = @import("std");
const tui = @import("tuiz");

const catalog = @import("../model_catalog.zig");
const device = @import("../discovery/device.zig");
const model_sync = @import("../model_sync.zig");
const run_policy = @import("../run_policy.zig");
const theme = @import("theme.zig");
const title_bar = @import("title_bar.zig");
const tty = @import("../tty.zig");

/// Rows the picker spends on chrome: title, blank, column header,
/// rule, then the blank + selection explanation + legend under the list.
pub const picker_chrome_rows: usize = 7;

const frame_buf_size: usize = 64 * 1024;

pub fn renderPicker(models: []const catalog.Model, cursor: usize, visible: usize) !void {
    var buf: [frame_buf_size]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    try drawPicker(models, cursor, visible, view(), &out);
    try tty.write(out.buffered());
}

pub fn renderSync(status: model_sync.Status) !void {
    var buf: [frame_buf_size]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    try drawSync(status, view(), &out);
    try tty.write(out.buffered());
}

fn view() tui.Viewport {
    return tui.Viewport.fromWinsize(
        tui.terminal.size() orelse .{ .col = 86, .row = 24, .xpixel = 0, .ypixel = 0 },
        theme.limits,
    );
}

/// Model rows a terminal of this height can show at once. A Hugging
/// Face cache holds more GGUFs than a terminal has lines, and a list
/// that runs off the top takes the cursor with it.
pub fn visibleRows(count: usize) usize {
    const rows = view().rowsOr(24);
    if (rows <= picker_chrome_rows + 1) return 1;
    return @min(count, rows - picker_chrome_rows);
}

/// First row of the window that keeps `cursor` on screen, scrolling
/// only when the cursor would otherwise leave it.
pub fn windowStart(cursor: usize, count: usize, visible: usize) usize {
    if (visible >= count) return 0;
    const half = visible / 2;
    if (cursor < half) return 0;
    return @min(cursor - half, count - visible);
}

pub fn drawPicker(
    models: []const catalog.Model,
    cursor: usize,
    visible: usize,
    v: tui.Viewport,
    out: *std.Io.Writer,
) !void {
    var canvas = tui.Canvas.init(out, theme.margin, theme.canvas_style);
    try canvas.home();
    try header(&canvas, "select model", v.content_w);

    // The two leading spaces are the cursor marker's column, so the
    // header sits over the fields rather than two cells left of them.
    var lw: std.Io.Writer = .fixed(&canvas.scratch);
    try lw.print("{s}  {s}{s: <31}{s: <9}{s: <14}{s: >11}   {s}{s}", .{
        theme.margin_pad,
        theme.label,
        "MODEL",
        "QUANT",
        "ARCH",
        "SIZE",
        "SOURCE / STATUS",
        theme.reset,
    });
    try canvas.row(tui.cell.truncate(lw.buffered(), theme.margin + v.content_w));
    try canvas.rule(v.content_w);

    const start = windowStart(cursor, models.len, visible);
    const end = @min(start + visible, models.len);
    for (models[start..end], start..) |model, index| try modelRow(&canvas, model, index == cursor, v.content_w);

    try canvas.blank();
    const reason = if (cursor < models.len) models[cursor].unavailableReason() else null;
    var explanation: std.Io.Writer = .fixed(&canvas.scratch);
    try explanation.print("{s}{s}{s}{s}", .{
        theme.margin_pad,
        if (reason != null) theme.orange else theme.faint,
        reason orelse "Choose a model for the text-generation benchmark.",
        theme.reset,
    });
    try canvas.row(tui.cell.truncate(explanation.buffered(), theme.margin + v.content_w));
    var legend: std.Io.Writer = .fixed(&canvas.scratch);
    try legend.print("{s}{s}", .{ theme.margin_pad, theme.faint });
    try writeKey(&legend, "↑/↓", "move");
    if (reason == null) {
        try writeKey(&legend, "enter", "select");
    } else {
        try legend.print("{s}[enter]unavailable  ", .{theme.disabled});
    }
    try writeKey(&legend, "q", "cancel");
    if (models.len > visible) {
        try legend.print("   {s}{d}/{d}", .{ theme.faint, cursor + 1, models.len });
    }
    try legend.writeAll(theme.reset);
    try canvas.writeRaw(tui.cell.truncate(legend.buffered(), theme.margin + v.content_w));
    try canvas.finish();
}

fn modelRow(canvas: *tui.Canvas, model: catalog.Model, on_cursor: bool, content_w: usize) !void {
    var name_buf: [96]u8 = undefined;
    var arch_buf: [64]u8 = undefined;
    var lw: std.Io.Writer = .fixed(&canvas.scratch);

    // The cursor row is the only place the accent appears in this
    // frame, so the eye lands on it without a highlight bar fighting
    // the dashboard's flat background.
    const unavailable = model.unavailableReason() != null;
    const name_color = if (unavailable) theme.disabled else if (on_cursor) theme.accent else theme.text;
    const rest_color = if (unavailable) theme.disabled else if (on_cursor) theme.sub else theme.mid;
    try lw.print("{s}{s}{s} ", .{
        theme.margin_pad,
        if (on_cursor) theme.accent else theme.faint,
        if (on_cursor) "›" else " ",
    });
    try lw.writeAll(name_color);
    try padded(&lw, tui.sanitize.into(&name_buf, model.name), 31);
    try lw.print("{s}", .{rest_color});
    try padded(&lw, model.quant, 9);
    try padded(&lw, tui.sanitize.into(&arch_buf, model.architecture), 14);

    var size_buf: [24]u8 = undefined;
    const size = try std.fmt.bufPrint(&size_buf, "{Bi:.2}", .{model.size_bytes});
    const size_w = tui.cell.width(size);
    if (size_w < 11) try tui.padWidth(&lw, 11 - size_w);
    try lw.writeAll(size);
    try lw.print("   {s}{s}", .{ if (unavailable) theme.disabled else theme.faint, model.source.label() });
    if (unavailable) try lw.writeAll(" · unavailable");
    try lw.writeAll(theme.reset);
    try canvas.row(tui.cell.truncate(lw.buffered(), theme.margin + content_w));
}

/// Rows the device list spends on chrome. One more than the model
/// list: unusable devices get a footnote under the legend.
pub const device_chrome_rows: usize = 7;

pub fn renderDevices(candidates: []const device.Candidate, selected: anytype, cursor: usize) !void {
    var buf: [frame_buf_size]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    try drawDevices(candidates, selected, cursor, view(), &out);
    try tty.writeErr(out.buffered());
}

pub fn renderCompareSearching() !void {
    var buf: [frame_buf_size]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    var canvas = tui.Canvas.init(&out, theme.margin, theme.canvas_style);
    const v = view();
    try canvas.home();
    if (!v.too_small) try header(&canvas, "compare devices", v.content_w);
    try canvas.writeRaw(theme.sub);
    const text = if (v.too_small) "Compare devices · Searching…" else theme.margin_pad ++ "Searching for connected devices…";
    try canvas.writeRaw(tui.cell.truncate(text, @as(usize, v.cols) -| 1));
    try canvas.writeRaw(theme.reset);
    try canvas.finish();
    try tty.write(out.buffered());
}

pub fn renderComparePreparing(name: []const u8) !void {
    var buf: [frame_buf_size]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    try drawComparePreparing(name, view(), &out);
    try tty.write(out.buffered());
}

fn drawComparePreparing(name: []const u8, v: tui.Viewport, out: *std.Io.Writer) !void {
    var canvas = tui.Canvas.init(out, theme.margin, theme.canvas_style);
    try canvas.home();
    if (!v.too_small) try header(&canvas, "compare devices", v.content_w);
    const width = if (v.too_small) @as(usize, v.cols) -| 1 else v.content_w;
    var safe: [512]u8 = undefined;
    var message: std.Io.Writer = .fixed(&canvas.scratch);
    try message.print("{s}Preparing {s}…{s}", .{
        theme.sub,
        tui.cell.truncate(tui.sanitize.into(&safe, name), width -| 11),
        theme.reset,
    });
    if (!v.too_small) try canvas.writeRaw(theme.margin_pad);
    try canvas.writeRaw(tui.cell.truncate(message.buffered(), width));
    try canvas.writeRaw(theme.reset);
    if (!v.too_small) {
        try canvas.row("");
        try canvas.writeRaw(theme.margin_pad);
        try canvas.writeRaw(theme.faint);
        try canvas.writeRaw(tui.cell.truncate("This can take a moment on first use.", width));
        try canvas.writeRaw(theme.reset);
    }
    try canvas.finish();
    // Setup diagnostics use ordinary lines after this frame. Start them
    // below the status instead of attaching them to its last sentence.
    try out.writeAll("\n");
}

/// Returns false when the viewport hides the choices behind a resize hint.
pub fn renderCompareDevices(candidates: []const device.Candidate, selected: anytype, cursor: usize) !bool {
    var buf: [frame_buf_size]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    const v = view();
    try drawCompareDevices(candidates, selected, cursor, v, &out);
    try tty.write(out.buffered());
    return !v.too_small;
}

pub fn drawDevices(
    candidates: []const device.Candidate,
    selected: anytype,
    cursor: usize,
    v: tui.Viewport,
    out: *std.Io.Writer,
) !void {
    try drawDeviceChoices(candidates, selected, cursor, v, out, false);
}

pub fn drawCompareDevices(
    candidates: []const device.Candidate,
    selected: anytype,
    cursor: usize,
    v: tui.Viewport,
    out: *std.Io.Writer,
) !void {
    try drawDeviceChoices(candidates, selected, cursor, v, out, true);
}

fn drawDeviceChoices(
    candidates: []const device.Candidate,
    selected: anytype,
    cursor: usize,
    v: tui.Viewport,
    out: *std.Io.Writer,
    comptime comparison_mode: bool,
) !void {
    var canvas = tui.Canvas.init(out, theme.margin, theme.canvas_style);
    try canvas.home();
    if (v.too_small) {
        try canvas.writeRaw(theme.sub);
        try canvas.writeRaw(tui.cell.truncate("q cancel · resize to at least 56 × 20", @as(usize, v.cols) -| 1));
        try canvas.writeRaw(theme.reset);
        return canvas.finish();
    }
    try header(&canvas, if (comparison_mode) "compare devices" else "select devices", v.content_w);
    if (comparison_mode) try compareIntro(&canvas, candidates, v.content_w);
    const columns = DeviceColumns.fit(v.content_w);
    try deviceHead(&canvas, columns);
    try canvas.rule(v.content_w);

    const chrome = if (comparison_mode) device_chrome_rows + 2 else device_chrome_rows;
    const visible = @min(candidates.len, if (v.rowsOr(24) > chrome + 1)
        v.rowsOr(24) - chrome
    else
        1);
    const start = windowStart(cursor, candidates.len, visible);
    const end = @min(start + visible, candidates.len);
    var any_unusable = false;
    for (candidates[start..end], start..) |candidate, index| {
        if (!candidate.selectable) any_unusable = true;
        try deviceRow(&canvas, candidate, index == cursor, selected.contains(index), columns);
    }
    if (candidates.len == 0) try canvas.rowPrint("{s}{s}No devices found.{s}", .{ theme.margin_pad, theme.faint, theme.reset });
    try canvas.blank();
    if (comparison_mode) {
        try compareFooter(&canvas, selected.len, v.content_w);
    } else {
        try deviceFooter(&canvas, any_unusable, v.content_w);
    }
    try canvas.writeRaw(theme.reset);
    try canvas.finish();
}

fn deviceFooter(canvas: *tui.Canvas, any_unusable: bool, content_w: usize) !void {
    var legend: std.Io.Writer = .fixed(&canvas.scratch);
    try legend.print("{s}{s}", .{ theme.margin_pad, theme.faint });
    try writeKey(&legend, "↑/↓", "move");
    try writeKey(&legend, "space", "toggle");
    try writeKey(&legend, "enter", "launch");
    try writeKey(&legend, "q", "cancel");
    try legend.writeAll(theme.reset);
    const budget = theme.margin + content_w;
    if (!any_unusable) {
        return canvas.writeRaw(tui.cell.truncate(legend.buffered(), budget));
    }
    try canvas.row(tui.cell.truncate(legend.buffered(), budget));
    // Unusable rows stay on screen rather than being filtered out, so
    // the phone on the desk is visible with its reason attached. Say
    // what the dash means, or it reads as a rendering glitch.
    var note: std.Io.Writer = .fixed(&canvas.scratch);
    try note.print("{s}{s}dimmed rows cannot be selected — see STATE{s}", .{
        theme.margin_pad,
        theme.faint,
        theme.reset,
    });
    try canvas.writeRaw(tui.cell.truncate(note.buffered(), budget));
}

fn compareIntro(canvas: *tui.Canvas, candidates: []const device.Candidate, width: usize) !void {
    var available: usize = 0;
    for (candidates) |candidate| available += @intFromBool(candidate.selectable);
    const text = if (available < 2)
        "Connect another device for side-by-side view."
    else
        "Choose 2–5 devices for the side-by-side view.";
    try canvas.rowPrint("{s}{s}{s}{s}", .{ theme.margin_pad, theme.sub, tui.cell.truncate(text, width), theme.reset });
}

fn compareFooter(canvas: *tui.Canvas, count: usize, width: usize) !void {
    const budget = theme.margin + width;
    var status: std.Io.Writer = .fixed(&canvas.scratch);
    const hint = if (count < 2) "choose at least 2" else if (count == 5) "maximum reached" else "ready for side-by-side view";
    try status.print("{s}{s}{d}/5 selected · {s}{s}", .{ theme.margin_pad, if (count < 2) theme.sub else theme.green, count, hint, theme.reset });
    try canvas.row(tui.cell.truncate(status.buffered(), budget));
    var legend: std.Io.Writer = .fixed(&canvas.scratch);
    try legend.writeAll(theme.margin_pad);
    try writeKey(&legend, "↑/↓", "move");
    try writeKey(&legend, "space", "toggle");
    try writeKey(&legend, "q/esc", "cancel");
    try legend.writeAll(theme.reset);
    try canvas.row(tui.cell.truncate(legend.buffered(), budget));
    legend = .fixed(&canvas.scratch);
    try legend.writeAll(theme.margin_pad);
    if (count >= 2) {
        try writeKey(&legend, "enter", "open split view");
    } else {
        try legend.print("{s}[enter]open split view · needs 2 devices", .{theme.faint});
    }
    try legend.writeAll(theme.reset);
    try canvas.writeRaw(tui.cell.truncate(legend.buffered(), budget));
}

const DeviceColumns = struct {
    name: usize = 24,
    soc: usize = 18,
    platform: usize = 11,
    transport: usize = 13,
    state: usize = 13,
    probe: usize = 8,

    fn fit(width: usize) DeviceColumns {
        var columns: DeviceColumns = .{};
        if (width < 91) columns.transport = 0;
        if (width < 78) columns.soc = 0;
        if (width < 60) columns.probe = 0;
        if (width < 52) columns.platform = 0;
        if (width < 41) columns.name = width -| 17;
        return columns;
    }
};

fn deviceHead(canvas: *tui.Canvas, columns: DeviceColumns) !void {
    var lw: std.Io.Writer = .fixed(&canvas.scratch);
    try lw.print("{s}    {s}", .{ theme.margin_pad, theme.label });
    inline for (.{ "name", "soc", "platform", "transport", "state", "probe" }, .{ "DEVICE", "SOC", "PLATFORM", "TRANSPORT", "STATE", "PROBE" }) |field, label| {
        try deviceCell(&lw, label, @field(columns, field));
    }
    try lw.writeAll(theme.reset);
    try canvas.row(lw.buffered());
}

fn deviceCell(lw: *std.Io.Writer, value: []const u8, width: usize) !void {
    if (width == 0) return;
    var safe: [128]u8 = undefined;
    const text = tui.cell.truncate(tui.sanitize.into(&safe, value), width - 1);
    try lw.writeAll(text);
    try tui.padWidth(lw, width - tui.cell.width(text));
}

fn deviceRow(
    canvas: *tui.Canvas,
    candidate: device.Candidate,
    on_cursor: bool,
    picked: bool,
    columns: DeviceColumns,
) !void {
    var lw: std.Io.Writer = .fixed(&canvas.scratch);

    const name_color = if (!candidate.selectable)
        theme.faint
    else if (on_cursor)
        theme.accent
    else
        theme.text;
    const rest_color = if (!candidate.selectable) theme.faint else if (on_cursor) theme.sub else theme.mid;

    try lw.print("{s}{s}{s} {s}{s} ", .{
        theme.margin_pad,
        if (on_cursor) theme.accent else theme.faint,
        if (on_cursor) "›" else " ",
        if (picked) theme.green else theme.faint,
        if (picked) "◉" else "○",
    });
    try lw.writeAll(name_color);
    try deviceCell(&lw, candidate.name, columns.name);
    try lw.writeAll(rest_color);
    try deviceCell(&lw, candidate.soc, columns.soc);
    try deviceCell(&lw, candidate.platform.label(), columns.platform);
    try deviceCell(&lw, candidate.transport, columns.transport);
    try deviceCell(&lw, candidate.transport_state, columns.state);
    try lw.writeAll(theme.faint);
    try deviceCell(&lw, candidate.probe_state.label(), columns.probe);
    try lw.writeAll(theme.reset);
    try canvas.row(lw.buffered());
}

/// Cells given to the parameter name, then to each device column.
const param_label_w: usize = 20;
const param_col_w: usize = 13;
/// Cells before the first column: the gutter and the cursor marker.
const param_lead_w: usize = theme.margin + 2;

/// Device columns that fit, ALL included. Five devices at 13 cells
/// apiece plus the label column is 102 cells, which wraps on the
/// 86-column fallback and on plenty of real terminals — and a wrapped
/// row in the alternate screen corrupts every row below it.
pub fn paramColumns(devices: usize, content_w: usize) usize {
    const room = (theme.margin + content_w) -| (param_lead_w + param_label_w);
    const fits = room / param_col_w;
    // ALL is not optional: it is the column that writes to every
    // device, and a grid without it cannot express the common case.
    if (fits <= 1) return 1;
    return @min(fits, devices + 1);
}

/// Columns this terminal can show right now, ALL included.
pub fn visibleParamColumns(devices: usize) usize {
    return paramColumns(devices, view().content_w);
}

pub fn renderParams(
    labels: []const []const u8,
    policies: []const run_policy.RunPolicy,
    managed: []const bool,
    field: usize,
    column: usize,
) !void {
    var buf: [frame_buf_size]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    try drawParams(labels, policies, managed, field, column, view(), &out);
    try tty.write(out.buffered());
}

/// The run-parameter grid: one row per field, one column per device,
/// plus a leading ALL column that writes to every device at once.
///
/// ALL is first because it is the common case — the same thread count
/// everywhere — and because it makes the *disagreement* visible: when
/// devices differ on a field, ALL shows `—` rather than one device's
/// value standing in for the set.
pub fn drawParams(
    labels: []const []const u8,
    policies: []const run_policy.RunPolicy,
    /// Whether each device's policy actually reaches it. A probe still
    /// using fixed-size `RunRequest` runs its own startup settings,
    /// so its column is marked rather than presented as in force.
    managed: []const bool,
    field: usize,
    column: usize,
    v: tui.Viewport,
    out: *std.Io.Writer,
) !void {
    var canvas = tui.Canvas.init(out, theme.margin, theme.canvas_style);
    try canvas.home();
    try header(&canvas, "run params", v.content_w);

    const columns = paramColumns(policies.len, v.content_w);
    const shown_devices = columns - 1;
    const budget = theme.margin + v.content_w;

    var head: std.Io.Writer = .fixed(&canvas.scratch);
    try head.print("{s}  {s}", .{ theme.margin_pad, theme.label });
    try padded(&head, "PARAM", param_label_w);
    try writeColumnHead(&head, "ALL", column == 0);
    for (labels[0..@min(shown_devices, labels.len)], 0..) |label, i| {
        var label_buf: [64]u8 = undefined;
        try writeColumnHead(&head, tui.sanitize.into(&label_buf, label), column == i + 1);
    }
    try head.writeAll(theme.reset);
    try canvas.row(tui.cell.truncate(head.buffered(), budget));
    try canvas.rule(v.content_w);

    for (run_policy.Field.all, 0..) |f, row| {
        try paramRow(&canvas, policies, managed, f, row == field, column, shown_devices, budget);
    }

    try canvas.blank();
    // A selection may affect only part of the engine; keep the limitation visible.
    var any_pinned = false;
    for (policies[0..@min(shown_devices, policies.len)]) |policy| {
        if (policy.kernel != .auto) any_pinned = true;
    }
    if (any_pinned) {
        var note: std.Io.Writer = .fixed(&canvas.scratch);
        try note.print("{s}{s}kernel selection: {s}{s}", .{
            theme.margin_pad,
            theme.orange,
            run_policy.reach,
            theme.reset,
        });
        try canvas.row(tui.cell.truncate(note.buffered(), budget));
    }

    var any_unmanaged = false;
    for (managed[0..@min(shown_devices, managed.len)]) |in_force| {
        if (!in_force) any_unmanaged = true;
    }
    if (any_unmanaged) {
        var note: std.Io.Writer = .fixed(&canvas.scratch);
        try note.print("{s}{s}dimmed columns are not in force — those probes run their own startup settings until `m` points them at a model{s}", .{
            theme.margin_pad,
            theme.faint,
            theme.reset,
        });
        try canvas.row(tui.cell.truncate(note.buffered(), budget));
    }
    // Same rule the race header follows: a screen that quietly leaves
    // a device out reads as the whole set.
    if (shown_devices < policies.len) {
        var note: std.Io.Writer = .fixed(&canvas.scratch);
        try note.print("{s}{s}{d} of {d} devices shown — widen the terminal to edit the rest{s}", .{
            theme.margin_pad,
            theme.orange,
            shown_devices,
            policies.len,
            theme.reset,
        });
        try canvas.row(note.buffered());
    }
    var legend: std.Io.Writer = .fixed(&canvas.scratch);
    try legend.print("{s}{s}", .{ theme.margin_pad, theme.faint });
    try writeKey(&legend, "↑/↓", "row");
    try writeKey(&legend, "←/→", "adjust");
    try writeKey(&legend, "space", "device");
    try writeKey(&legend, "enter", "apply");
    try writeKey(&legend, "q", "cancel");
    try legend.writeAll(theme.reset);
    try canvas.writeRaw(legend.buffered());
    try canvas.finish();
}

fn writeColumnHead(lw: *std.Io.Writer, text: []const u8, selected: bool) !void {
    try lw.writeAll(if (selected) theme.accent else theme.label);
    try rightPadded(lw, tui.cell.truncate(text, param_col_w - 1), param_col_w);
    try lw.writeAll(theme.label);
}

fn paramRow(
    canvas: *tui.Canvas,
    policies: []const run_policy.RunPolicy,
    managed: []const bool,
    field: run_policy.Field,
    on_row: bool,
    column: usize,
    shown_devices: usize,
    budget: usize,
) !void {
    var lw: std.Io.Writer = .fixed(&canvas.scratch);
    try lw.print("{s}{s}{s} ", .{
        theme.margin_pad,
        if (on_row) theme.accent else theme.faint,
        if (on_row) "›" else " ",
    });
    try lw.writeAll(if (on_row) theme.text else theme.mid);
    try padded(&lw, field.label(), param_label_w);

    var value_buf: [24]u8 = undefined;
    // ALL: the shared value, or a dash when the devices disagree. A
    // dash is the honest answer — printing the first device's number
    // would claim a uniformity that is not there.
    const shared: ?u32 = blk: {
        if (policies.len == 0) break :blk null;
        const first = policies[0].get(field);
        for (policies[1..]) |p| {
            if (p.get(field) != first) break :blk null;
        }
        break :blk first;
    };
    const all_text = if (shared) |value| field.cellText(value, &value_buf) else "—";
    try writeCell(&lw, all_text, on_row and column == 0, true);

    for (policies[0..@min(shown_devices, policies.len)], 0..) |policy, i| {
        var cell_buf: [24]u8 = undefined;
        const text = field.cellText(policy.get(field), &cell_buf);
        const in_force = i >= managed.len or managed[i];
        try writeCell(&lw, text, on_row and column == i + 1, in_force);
    }
    try lw.writeAll(theme.reset);
    try canvas.row(tui.cell.truncate(lw.buffered(), budget));
}

fn writeCell(lw: *std.Io.Writer, text: []const u8, selected: bool, in_force: bool) !void {
    // An unmanaged column keeps its value — the moment `m` points that
    // device at a model the number becomes real — but it is drawn back
    // so it cannot be read as what the device is running.
    const colour = if (!in_force) theme.faint else if (selected) theme.accent else theme.sub;
    try lw.writeAll(colour);
    try rightPadded(lw, text, param_col_w);
}

/// Right-align `text` inside `cells`, so a column of numbers lines up
/// on its units digit.
fn rightPadded(lw: *std.Io.Writer, text: []const u8, cells: usize) !void {
    const w = tui.cell.width(text);
    if (w + 1 < cells) try tui.padWidth(lw, cells - w - 1);
    try lw.writeAll(text);
    try tui.padWidth(lw, 1);
}

const spinner = [_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };

pub fn drawSync(status: model_sync.Status, v: tui.Viewport, out: *std.Io.Writer) !void {
    var canvas = tui.Canvas.init(out, theme.margin, theme.canvas_style);
    try canvas.home();
    try header(&canvas, "syncing model", v.content_w);

    var name: std.Io.Writer = .fixed(&canvas.scratch);
    try name.print("{s}{s}{s}", .{ theme.margin_pad, theme.text, theme.bold });
    try tui.sanitize.write(&name, status.model);
    try name.writeAll(theme.reset);
    if (status.device.len > 0) {
        try name.print(" {s}→ {s}", .{ theme.sep, theme.sub });
        try tui.sanitize.write(&name, status.device);
        try name.writeAll(theme.reset);
    }
    try canvas.row(name.buffered());
    try canvas.blank();

    var phase: std.Io.Writer = .fixed(&canvas.scratch);
    try phase.print("{s}{s}{s} {s}{s}", .{
        theme.margin_pad,
        theme.accent,
        spinner[status.tick % spinner.len],
        theme.mid,
        status.phase.label(),
    });
    try phase.writeAll(theme.reset);
    try canvas.row(phase.buffered());
    try canvas.blank();

    var bar: std.Io.Writer = .fixed(&canvas.scratch);
    try bar.writeAll(theme.margin_pad);
    if (status.percent()) |pct| {
        try tui.meter.write(&bar, pct, theme.heat_ramp.at(0), theme.meter_track);
        try bar.print("  {s}{d: >3}%{s}  {s}{Bi:.2} / {Bi:.2}{s}", .{
            theme.text,
            pct,
            theme.reset,
            theme.faint,
            status.done_bytes,
            status.total_bytes,
            theme.reset,
        });
    } else if (status.total_bytes > 0) {
        // Size known, progress not: an on-device hash is opaque until
        // it returns. Say the size rather than draw a fake bar.
        try bar.print("{s}{Bi:.2}{s}", .{ theme.faint, status.total_bytes, theme.reset });
    }
    try canvas.row(bar.buffered());
    try canvas.blank();

    // No key legend here, and that is not an omission: sync blocks, so
    // nothing is reading the keyboard. Promising a cancel key the
    // screen cannot honour would be worse than saying nothing.
    var note: std.Io.Writer = .fixed(&canvas.scratch);
    try note.print("{s}{s}the dashboard comes back when this finishes{s}", .{
        theme.margin_pad,
        theme.faint,
        theme.reset,
    });
    try canvas.writeRaw(note.buffered());
    try canvas.finish();
}

fn header(canvas: *tui.Canvas, title: []const u8, content_w: usize) !void {
    var lw: std.Io.Writer = .fixed(&canvas.scratch);
    try lw.print("{s}{s}", .{ theme.margin_pad, theme.bold });
    try title_bar.writeWordmark(&lw);
    try lw.print("{s} {s}·{s} {s}", .{ theme.reset, theme.sep, theme.sub, title });
    try lw.writeAll(theme.reset);
    try canvas.row(lw.buffered());
    _ = content_w;
    try canvas.blank();
}

fn writeKey(lw: anytype, key: []const u8, action: []const u8) !void {
    try lw.print("{s}[{s}{s}{s}]{s}{s}  ", .{
        theme.faint,
        theme.accent,
        key,
        theme.faint,
        theme.faint,
        action,
    });
}

/// Write `text` and pad to `cells`, truncating nothing — an
/// over-long name pushes the rest of the row rather than being cut,
/// since a silently trimmed model name reads as a different model.
fn padded(lw: *std.Io.Writer, text: []const u8, cells: usize) !void {
    try lw.writeAll(text);
    const w = tui.cell.width(text);
    try tui.padWidth(lw, if (w < cells) cells - w else 1);
}

test "the window scrolls only once the cursor would leave it" {
    // Everything fits: no scrolling, ever.
    try std.testing.expectEqual(@as(usize, 0), windowStart(0, 4, 10));
    try std.testing.expectEqual(@as(usize, 0), windowStart(3, 4, 10));

    // 40 models through a 10-row window.
    try std.testing.expectEqual(@as(usize, 0), windowStart(0, 40, 10));
    try std.testing.expectEqual(@as(usize, 0), windowStart(4, 40, 10));
    try std.testing.expectEqual(@as(usize, 15), windowStart(20, 40, 10));
    // Wrapping to the last entry pins the window to the end rather
    // than scrolling past it.
    try std.testing.expectEqual(@as(usize, 30), windowStart(39, 40, 10));
}

test "a picker frame carries the model, the cursor, and the legend" {
    const models = [_]catalog.Model{
        .{
            .path = "/models/qwen.gguf",
            .name = "Example-0.8B",
            .quant = "Q4_K_M",
            .architecture = "qwen35",
            .parameter_count = 752_393_024,
            .size_bytes = 532_517_120,
            .source = .workspace,
        },
        .{
            .path = "/models/sample.gguf",
            .name = "Sample-8B",
            .quant = "Q4_0",
            .architecture = "qwen3",
            .parameter_count = 8_188_548_096,
            .size_bytes = 1_158_654_496,
            .source = .huggingface,
        },
    };
    var buf: [frame_buf_size]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    const v = tui.Viewport.fromWinsize(
        .{ .col = 120, .row = 30, .xpixel = 0, .ypixel = 0 },
        theme.limits,
    );
    try drawPicker(&models, 1, 2, v, &out);

    const frame = out.buffered();
    try std.testing.expect(std.mem.indexOf(u8, frame, "Example-0.8B") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "Q4_K_M") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "hf-cache") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "cancel") != null);
    // The cursor marker sits on the second row, not the first.
    const first = std.mem.indexOf(u8, frame, "Example-0.8B").?;
    const marker = std.mem.indexOf(u8, frame, "›").?;
    try std.testing.expect(marker > first);
}

test "an embedding model is dimmed and explains why it cannot run" {
    const model: catalog.Model = .{
        .path = "/models/bge.gguf",
        .name = "bge-small-en-v1.5-f16",
        .quant = "F16",
        .architecture = "bert",
        .parameter_count = 33_000_000,
        .size_bytes = 67_000_000,
        .source = .huggingface,
    };
    for ([_]u16{ 56, 80, 132 }) |cols| {
        var buf: [frame_buf_size]u8 = undefined;
        var out: std.Io.Writer = .fixed(&buf);
        const v = tui.Viewport.fromWinsize(.{ .col = cols, .row = 24, .xpixel = 0, .ypixel = 0 }, theme.limits);
        try drawPicker(&.{model}, 0, 1, v, &out);
        const text = out.buffered();
        try std.testing.expect(std.mem.indexOf(u8, text, theme.disabled ++ "bge-small") != null);
        try std.testing.expect(std.mem.indexOf(u8, text, "Embedding model") != null);
        try std.testing.expect(std.mem.indexOf(u8, text, "[enter]unavailable") != null);
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| try std.testing.expect(tui.cell.width(line) <= cols);
    }
}

test "a device frame keeps an unusable device visible with its reason" {
    const candidates = [_]device.Candidate{
        .{
            .platform = .android,
            .id = "TESTANDROID001",
            .name = "Pixel_8",
            .soc = "Tensor G3",
            .transport = "adb-usb",
            .transport_state = "unauthorized",
            .selectable = false,
        },
        .{ .platform = .host, .id = "localhost", .name = "Mac", .transport = "local" },
    };
    var buf: [frame_buf_size]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    const v = tui.Viewport.fromWinsize(
        .{ .col = 140, .row = 30, .xpixel = 0, .ypixel = 0 },
        theme.limits,
    );
    const nothing_selected = struct {
        fn contains(_: @This(), _: usize) bool {
            return false;
        }
    }{};
    try drawDevices(&candidates, nothing_selected, 1, v, &out);

    const frame = out.buffered();
    try std.testing.expect(std.mem.indexOf(u8, frame, "Pixel_8") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "unauthorized") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "cannot be selected") != null);
}

const TestDeviceSelection = struct {
    indices: []const usize,
    len: usize,

    fn contains(self: @This(), index: usize) bool {
        return std.mem.indexOfScalar(usize, self.indices, index) != null;
    }
};

test "comparison preparation clears the menu and starts diagnostics on a new line" {
    var buf: [frame_buf_size]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    const v = tui.Viewport.fromWinsize(.{ .col = 56, .row = 20, .xpixel = 0, .ypixel = 0 }, theme.limits);
    try drawComparePreparing("Pixel\x1b[2J\nphone", v, &out);
    const frame = out.buffered();
    try std.testing.expect(std.mem.startsWith(u8, frame, "\x1b[H"));
    try std.testing.expect(std.mem.indexOf(u8, frame, "compare devices") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "Preparing Pixel?[2J?phone…") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "This can take a moment on first use.") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "\x1b[2J") == null);
    try std.testing.expect(std.mem.endsWith(u8, frame, "\x1b[K\x1b[J\n"));
    var rows = std.mem.splitScalar(u8, frame, '\n');
    while (rows.next()) |row| try std.testing.expect(tui.cell.width(row) < v.cols);
}

test "comparison picker frame explains device selection and split view" {
    const candidates = [_]device.Candidate{
        .{ .platform = .android, .id = "pixel", .name = "Pixel", .transport = "adb-usb" },
        .{ .platform = .host, .id = "localhost", .name = "Mac", .transport = "local" },
    };
    var buf: [frame_buf_size]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    const v = tui.Viewport.fromWinsize(.{ .col = 86, .row = 24, .xpixel = 0, .ypixel = 0 }, theme.limits);
    try drawCompareDevices(&candidates, TestDeviceSelection{ .indices = &.{ 0, 1 }, .len = 2 }, 1, v, &out);
    const frame = out.buffered();
    for ([_][]const u8{ "compare devices", "Choose 2–5 devices", "side-by-side view", "2/5 selected", "space", "toggle", "open split view", "q/esc" }) |text| {
        try std.testing.expect(std.mem.indexOf(u8, frame, text) != null);
    }
    try std.testing.expect(std.mem.indexOf(u8, frame, theme.accent ++ "enter") != null);
}

test "comparison picker frame explains one-device and unavailable states" {
    const candidates = [_]device.Candidate{
        .{ .platform = .android, .id = "locked", .name = "Pixel", .transport = "adb-usb", .transport_state = "unauthorized", .selectable = false },
        .{ .platform = .host, .id = "localhost", .name = "Mac", .transport = "local" },
    };
    var buf: [frame_buf_size]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    const v = tui.Viewport.fromWinsize(.{ .col = 56, .row = 20, .xpixel = 0, .ypixel = 0 }, theme.limits);
    try drawCompareDevices(&candidates, TestDeviceSelection{ .indices = &.{1}, .len = 1 }, 0, v, &out);
    for ([_][]const u8{ "Connect another device", "Pixel", "unauthorized", "1/5 selected", "choose at least 2", "needs 2 devices" }) |text| {
        try std.testing.expect(std.mem.indexOf(u8, out.buffered(), text) != null);
    }
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), theme.accent ++ "enter") == null);
    out = .fixed(&buf);
    try drawCompareDevices(candidates[1..], TestDeviceSelection{ .indices = &.{0}, .len = 1 }, 0, v, &out);
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "Connect another device") != null);
    out = .fixed(&buf);
    try drawCompareDevices(&.{}, TestDeviceSelection{ .indices = &.{}, .len = 0 }, 0, v, &out);
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "No devices found.") != null);
}

test "comparison picker frame scrolls without wrapping narrow or short terminals" {
    const candidates = [_]device.Candidate{.{
        .platform = .android,
        .id = "pixel",
        .name = "Pixel\x1b[2J very long device name that does not fit one row",
        .soc = "An unusually long processor name",
        .transport = "adb-usb",
        .transport_state = "unauthorized",
        .selectable = false,
    }} ** 30;
    for ([_][2]u16{ .{ 1, 1 }, .{ 30, 5 }, .{ 56, 20 }, .{ 86, 20 }, .{ 140, 30 } }) |size| {
        var buf: [frame_buf_size]u8 = undefined;
        var out: std.Io.Writer = .fixed(&buf);
        const v = tui.Viewport.fromWinsize(.{ .col = size[0], .row = size[1], .xpixel = 0, .ypixel = 0 }, theme.limits);
        try drawCompareDevices(&candidates, TestDeviceSelection{ .indices = &.{}, .len = 0 }, 29, v, &out);
        var rows = std.mem.splitScalar(u8, out.buffered(), '\n');
        var count: usize = 0;
        while (rows.next()) |row| {
            try std.testing.expect(tui.cell.width(row) < size[0]);
            count += 1;
        }
        try std.testing.expect(count <= size[1]);
        try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "\x1b[2J") == null);
        if (!v.too_small) try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "›") != null);
    }
}

test "the params grid never draws more columns than fit" {
    // Five devices at 13 cells apiece plus the label column needs 102;
    // the fallback viewport is 86 wide.
    try std.testing.expectEqual(@as(usize, 6), paramColumns(5, 200));
    try std.testing.expect(paramColumns(5, 86) < 6);
    // ALL survives even a viewport that fits nothing else, because it
    // is the column that writes to every device.
    try std.testing.expectEqual(@as(usize, 1), paramColumns(5, 10));
    // Never more columns than there are devices to fill them.
    try std.testing.expectEqual(@as(usize, 2), paramColumns(1, 200));
}

test "a params frame stays inside its viewport with five devices" {
    const labels = [_][]const u8{ "one", "two", "three", "four", "five" };
    const policies = [_]run_policy.RunPolicy{.{}} ** 5;
    var buf: [frame_buf_size]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    const v = tui.Viewport.fromWinsize(
        .{ .col = 86, .row = 30, .xpixel = 0, .ypixel = 0 },
        theme.limits,
    );
    const managed = [_]bool{true} ** 5;
    try drawParams(&labels, &policies, &managed, 0, 0, v, &out);

    var widest: usize = 0;
    var lines = std.mem.splitScalar(u8, out.buffered(), '\n');
    while (lines.next()) |line| {
        widest = @max(widest, tui.cell.width(line));
    }
    // A row wider than the viewport wraps, and a wrapped row in the
    // alternate screen corrupts every row under it.
    try std.testing.expect(widest <= theme.margin + v.content_w);
    // And it says so rather than silently dropping the devices.
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "devices shown") != null);
}

test "the kernel row renders as a name, not a tag number" {
    const labels = [_][]const u8{"PHONE01"};
    const policies = [_]run_policy.RunPolicy{
        .{ .threads = 8, .n_prompt = 32, .n_generate = 64, .kernel = .sdot },
    };
    const managed = [_]bool{true};
    var buf: [frame_buf_size]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    const v = tui.Viewport.fromWinsize(
        .{ .col = 120, .row = 30, .xpixel = 0, .ypixel = 0 },
        theme.limits,
    );
    try drawParams(&labels, &policies, &managed, 3, 0, v, &out);

    const frame = out.buffered();
    try std.testing.expect(std.mem.indexOf(u8, frame, "gemv kernel") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "sdot") != null);
    // A selection must carry the supplied-engine scope warning.
    try std.testing.expect(std.mem.indexOf(u8, frame, "Scope depends on the supplied engine") != null);
    // The three numeric rows are still there beside it.
    try std.testing.expect(std.mem.indexOf(u8, frame, "threads") != null);
}

test "a sync frame names the phase, the model, and the device" {
    var buf: [frame_buf_size]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    const v = tui.Viewport.fromWinsize(
        .{ .col = 120, .row = 30, .xpixel = 0, .ypixel = 0 },
        theme.limits,
    );
    try drawSync(.{
        .phase = .uploading,
        .model = "Example-0.8B",
        .device = "PHONE01",
        .done_bytes = 266_258_560,
        .total_bytes = 532_517_120,
    }, v, &out);

    const frame = out.buffered();
    try std.testing.expect(std.mem.indexOf(u8, frame, "uploading to the device") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "Example-0.8B") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "PHONE01") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "50%") != null);
}
