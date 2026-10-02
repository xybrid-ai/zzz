//! Transient UI state: the message slots the footer shows, the
//! screenshot flag, and the "when did the last run finish" clock.
//!
//! Deliberately separate from the render code — everything here is
//! written by the event loop and only read while drawing.

const std = @import("std");
const time_compat = @import("time_compat");
const snapshot_export = @import("export.zig");

const flash_hold_ns: i128 = 2 * std.time.ns_per_s;
/// Formatted messages get longer than literals, so they hold longer.
const flash_fmt_hold_ns: i128 = 4 * std.time.ns_per_s;

pub const UiState = struct {
    sort_race: bool = false,
    /// Whether the OUTPUT panel is drawn. Off by default: the panel is
    /// for reading what a model said, and the dashboard's subject is
    /// how fast it said it.
    show_output: bool = false,
    flash_msg: ?[]const u8 = null,
    flash_until_ns: i128 = 0,
    /// Backing storage for dynamic flash messages built via flashFmt.
    /// Static-message calls (`flash`) keep pointing at string literals.
    flash_buf: [256]u8 = @splat(0),
    /// Persistent banner — replaces the flash slot for as long as it
    /// is set, no expiry. Used for "probe disconnected" while a
    /// reconnect is in flight: the user needs to keep seeing it, not
    /// just for the flash window.
    status_msg: ?[]const u8 = null,
    /// One-shot flag set by the `e` keypress. Consumed at the end of
    /// the next render, snapshotting the exact frame the user pressed
    /// `e` on.
    pending_export: bool = false,
    /// Export confirmation uses the whole footer so its path stays visible.
    export_notice: bool = false,
    /// Monotonic timestamp of the primary engine's last phase=2
    /// report. Drives the idle hero's "LAST RUN · Xm ago" caption; 0
    /// means no completed run this session.
    last_done_ns: i128 = 0,

    pub fn flash(self: *UiState, msg: []const u8) void {
        self.export_notice = false;
        self.flash_msg = msg;
        self.flash_until_ns = time_compat.nanoTimestamp() + flash_hold_ns;
    }

    /// Format into the internal buffer and flash. Used when the
    /// message text is dynamic (e.g. an engine error line).
    pub fn flashFmt(self: *UiState, comptime fmt: []const u8, args: anytype) void {
        self.export_notice = false;
        const out = std.fmt.bufPrint(&self.flash_buf, fmt, args) catch self.flash_buf[0..];
        self.flash_msg = out;
        self.flash_until_ns = time_compat.nanoTimestamp() + flash_fmt_hold_ns;
    }

    /// Whether `msg` is the flash currently held, expiry included.
    /// Asks the slot rather than `currentFlash`, which a status banner
    /// outranks: a prompt waiting on a second keypress is still waiting
    /// while the probe reconnects over the top of it.
    pub fn isFlashing(self: *const UiState, msg: []const u8) bool {
        const held = self.flash_msg orelse return false;
        return std.mem.eql(u8, held, msg) and time_compat.nanoTimestamp() <= self.flash_until_ns;
    }

    pub fn setStatus(self: *UiState, msg: []const u8) void {
        self.status_msg = msg;
    }

    pub fn clearStatus(self: *UiState) void {
        self.status_msg = null;
    }

    /// True while the primary probe is disconnected — `status_msg` is
    /// only ever set by the reconnect path, so it doubles as the flag.
    pub fn isDisconnected(self: *const UiState) bool {
        return self.status_msg != null;
    }

    /// The message to render in the footer slot. Status (persistent)
    /// wins over flash (timed): a disconnected probe matters more than
    /// the most recent transient.
    pub fn currentFlash(self: *UiState) ?[]const u8 {
        if (self.status_msg) |s| return s;
        if (self.flash_msg == null) return null;
        if (time_compat.nanoTimestamp() > self.flash_until_ns) {
            self.flash_msg = null;
            return null;
        }
        return self.flash_msg;
    }

    /// Age of the last completed run in seconds, or null if none.
    pub fn lastRunAgeSecs(self: *const UiState) ?i64 {
        if (self.last_done_ns == 0) return null;
        const age_ns = time_compat.nanoTimestamp() - self.last_done_ns;
        return @intCast(@max(0, @divTrunc(age_ns, std.time.ns_per_s)));
    }
};

/// Consume a pending `e` snapshot, writing the on-screen bytes to a
/// timestamped file. Called from both render paths (full dashboard and
/// the "terminal too small" early return) so the flag never leaks into
/// a later, unintended frame.
pub fn consumeExport(ui: *UiState, bytes: []const u8) void {
    if (!ui.pending_export) return;
    ui.pending_export = false;
    var threaded: std.Io.Threaded = .init_single_threaded;
    var path_buf: [snapshot_export.path_capacity]u8 = undefined;
    if (snapshot_export.save(threaded.io(), .cwd(), bytes, time_compat.realtimeSeconds(), &path_buf)) |path| {
        ui.flashFmt("Saved {s}", .{path});
    } else |err| {
        ui.flashFmt("Export failed: {s}", .{@errorName(err)});
    }
    ui.export_notice = true;
    ui.flash_until_ns = time_compat.nanoTimestamp() + 8 * std.time.ns_per_s;
}

test "status outranks flash in the footer slot" {
    var ui = UiState{};
    ui.flash("transient");
    ui.setStatus("probe disconnected");
    try std.testing.expectEqualStrings("probe disconnected", ui.currentFlash().?);
    try std.testing.expect(ui.isDisconnected());
    ui.clearStatus();
    try std.testing.expectEqualStrings("transient", ui.currentFlash().?);
}

test "a held flash is recognised until it expires or is replaced" {
    var ui = UiState{};
    try std.testing.expect(!ui.isFlashing("press again"));
    ui.flash("press again");
    try std.testing.expect(ui.isFlashing("press again"));
    ui.setStatus("probe disconnected");
    try std.testing.expect(ui.isFlashing("press again"));
    ui.flash("something else");
    try std.testing.expect(!ui.isFlashing("press again"));
    ui.flash("press again");
    ui.flash_until_ns = 0;
    try std.testing.expect(!ui.isFlashing("press again"));
}

test "an expired flash clears itself" {
    var ui = UiState{};
    ui.flash("gone");
    ui.flash_until_ns = 0;
    try std.testing.expect(ui.currentFlash() == null);
    try std.testing.expect(ui.flash_msg == null);
}
