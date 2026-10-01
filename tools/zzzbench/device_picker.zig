//! Device-selection policy plus the small raw-ANSI picker used before
//! the dashboard. Selection arithmetic is pure and unit-tested; only
//! `interactive` owns terminal state.

const std = @import("std");
const tui = @import("tuiz");

const device = @import("discovery/device.zig");
const keys = @import("keys.zig");
const picker_screen = @import("ui/picker_screen.zig");
const theme = @import("ui/theme.zig");

pub const max_selected: usize = 5;

/// Immediate feedback while the platform discovery commands run. It stays in
/// the caller's normal terminal so Ctrl-C remains shell-safe while a child
/// command is blocking; the interactive picker owns the alternate screen once
/// candidates exist.
pub const SearchStatus = struct {
    active: bool = false,

    pub fn begin(scope: []const u8) SearchStatus {
        if (std.c.isatty(std.posix.STDERR_FILENO) == 0) return .{};
        var buf: [512]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buf);
        writeLoading(&writer, scope) catch return .{};
        std.debug.print("{s}", .{writer.buffered()});
        return .{ .active = true };
    }

    pub fn clear(self: *SearchStatus) void {
        if (!self.active) return;
        std.debug.print("\r\x1b[2K", .{});
        self.active = false;
    }
};

fn writeLoading(writer: *std.Io.Writer, scope: []const u8) !void {
    try writer.print("\r\x1b[2K{s}{s}zzzbench{s} · Searching for devices…  {s}{s}{s}", .{
        theme.bold,
        theme.accent,
        theme.reset,
        theme.sub,
        scope,
        theme.reset,
    });
}

pub const Selection = struct {
    indices: [max_selected]usize = undefined,
    len: usize = 0,

    pub fn append(self: *Selection, index: usize) !void {
        if (self.len == self.indices.len) return error.TooManyDevices;
        self.indices[self.len] = index;
        self.len += 1;
    }

    pub fn contains(self: Selection, index: usize) bool {
        return std.mem.indexOfScalar(usize, self.indices[0..self.len], index) != null;
    }

    pub fn toggle(self: *Selection, index: usize) !void {
        const found = std.mem.indexOfScalar(usize, self.indices[0..self.len], index) orelse {
            return self.append(index);
        };
        std.mem.copyForwards(usize, self.indices[found .. self.len - 1], self.indices[found + 1 .. self.len]);
        self.len -= 1;
    }
};

pub fn selectByIds(candidates: []const device.Candidate, csv: []const u8) !Selection {
    var selected: Selection = .{};
    var ids = std.mem.splitScalar(u8, csv, ',');
    while (ids.next()) |raw| {
        const id = std.mem.trim(u8, raw, " \t\r\n");
        if (id.len == 0) continue;
        for (candidates, 0..) |candidate, index| {
            if (!std.mem.eql(u8, candidate.id, id)) continue;
            if (!candidate.selectable) return error.DeviceUnavailable;
            if (!selected.contains(index)) try selected.append(index);
            break;
        } else return error.DeviceNotFound;
    }
    if (selected.len == 0) return error.NoDevicesSelected;
    return selected;
}

pub fn selectAll(candidates: []const device.Candidate) Selection {
    var selected: Selection = .{};
    for (candidates, 0..) |candidate, index| {
        if (!candidate.selectable) continue;
        selected.append(index) catch break;
    }
    return selected;
}

pub fn interactive(candidates: []const device.Candidate) !Selection {
    if (candidates.len == 0) return error.NoDevices;
    if (candidates.len == 1 and candidates[0].selectable) return selectAll(candidates);
    if (std.c.isatty(std.posix.STDIN_FILENO) == 0 or std.c.isatty(std.posix.STDERR_FILENO) == 0) {
        return error.InteractiveSelectionNeedsTty;
    }

    var selected: Selection = .{};
    var cursor = firstSelectable(candidates) orelse 0;
    if (candidates[cursor].selectable) try selected.append(cursor);
    var raw = tui.RawTty.enable();
    defer raw.disable();
    if (!raw.enabled) return error.InteractiveSelectionNeedsTty;

    std.debug.print("\x1b[?1049h\x1b[?25l", .{});
    defer std.debug.print("\x1b[?25h\x1b[?1049l", .{});

    while (true) {
        try picker_screen.renderDevices(candidates, selected, cursor);
        var pfd = [_]std.posix.pollfd{.{
            .fd = std.posix.STDIN_FILENO,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        _ = try std.posix.poll(&pfd, -1);
        var input: [32]u8 = undefined;
        const n = try std.posix.read(std.posix.STDIN_FILENO, &input);
        if (n == 0) return error.SelectionCancelled;
        var burst: keys.Iterator = .{ .bytes = input[0..n] };
        while (burst.next()) |key| switch (key) {
            .cancel => return error.SelectionCancelled,
            .select => if (selected.len > 0) return selected,
            .toggle => {
                if (!candidates[cursor].selectable) continue;
                selected.toggle(cursor) catch continue;
            },
            .up => cursor = if (cursor == 0) candidates.len - 1 else cursor - 1,
            .down => cursor = (cursor + 1) % candidates.len,
            .left, .right, .unknown => {},
        };
    }
}

/// Discovery feedback inside the dashboard's existing alternate screen.
pub fn searching() !void {
    try picker_screen.renderCompareSearching();
}

pub fn preparing(name: []const u8) !void {
    try picker_screen.renderComparePreparing(name);
}

/// The dashboard already owns raw mode and the alternate screen. Unlike
/// startup, Compare always shows the choices and needs two devices.
pub fn compare(candidates: []const device.Candidate, initial: Selection) !Selection {
    if (std.c.isatty(std.posix.STDIN_FILENO) == 0 or std.c.isatty(std.posix.STDOUT_FILENO) == 0)
        return error.InteractiveSelectionNeedsTty;
    var selected = availableSelection(candidates, initial);
    var cursor = if (selected.len > 0) selected.indices[0] else firstSelectable(candidates) orelse 0;
    while (true) {
        const visible = try picker_screen.renderCompareDevices(candidates, selected, cursor);
        var pfd = [_]std.posix.pollfd{.{ .fd = std.posix.STDIN_FILENO, .events = std.posix.POLL.IN, .revents = 0 }};
        if (try std.posix.poll(&pfd, 250) == 0) continue;
        var input: [32]u8 = undefined;
        const n = try std.posix.read(std.posix.STDIN_FILENO, &input);
        if (n == 0) return error.SelectionCancelled;
        var burst: keys.Iterator = .{ .bytes = input[0..n] };
        while (burst.next()) |key| {
            if (!visible and key != .cancel) continue;
            if (try compareKey(candidates, &selected, &cursor, key)) return selected;
        }
    }
}

fn availableSelection(candidates: []const device.Candidate, initial: Selection) Selection {
    var selected: Selection = .{};
    for (initial.indices[0..@min(initial.len, max_selected)]) |index| {
        if (index >= candidates.len or !candidates[index].selectable or selected.contains(index)) continue;
        selected.append(index) catch break;
    }
    return selected;
}

fn compareKey(candidates: []const device.Candidate, selected: *Selection, cursor: *usize, key: keys.Key) !bool {
    if (key == .cancel) return error.SelectionCancelled;
    if (candidates.len == 0) return false;
    switch (key) {
        .select => return selected.len >= 2,
        .toggle => if (candidates[cursor.*].selectable) {
            selected.toggle(cursor.*) catch return false;
        },
        .up => cursor.* = if (cursor.* == 0) candidates.len - 1 else cursor.* - 1,
        .down => cursor.* = (cursor.* + 1) % candidates.len,
        .left, .right, .cancel, .unknown => {},
    }
    return false;
}

fn firstSelectable(candidates: []const device.Candidate) ?usize {
    for (candidates, 0..) |candidate, index| {
        if (candidate.selectable) return index;
    }
    return null;
}

test "selection preserves requested id order" {
    const candidates = [_]device.Candidate{
        .{ .platform = .android, .id = "pixel", .name = "Pixel", .transport = "usb" },
        .{ .platform = .ios, .id = "iphone", .name = "iPhone", .transport = "coredevice" },
        .{ .platform = .host, .id = "localhost", .name = "Mac", .transport = "local" },
    };
    const selected = try selectByIds(&candidates, "iphone,pixel");
    try std.testing.expectEqual(@as(usize, 2), selected.len);
    try std.testing.expectEqual(@as(usize, 1), selected.indices[0]);
    try std.testing.expectEqual(@as(usize, 0), selected.indices[1]);
}

test "selection rejects an unknown id" {
    const candidates = [_]device.Candidate{
        .{ .platform = .host, .id = "localhost", .name = "Mac", .transport = "local" },
    };
    try std.testing.expectError(error.DeviceNotFound, selectByIds(&candidates, "pixel"));
}

test "select all obeys the dashboard's five-device cap" {
    const candidate: device.Candidate = .{ .platform = .host, .id = "host", .name = "Mac", .transport = "local" };
    const candidates = [_]device.Candidate{candidate} ** 7;
    try std.testing.expectEqual(max_selected, selectAll(&candidates).len);
}

test "unavailable devices are visible but cannot be selected" {
    const candidates = [_]device.Candidate{
        .{ .platform = .android, .id = "locked", .name = "Pixel", .transport = "adb-usb", .transport_state = "unauthorized", .selectable = false },
        .{ .platform = .host, .id = "localhost", .name = "Mac", .transport = "local" },
    };

    try std.testing.expectError(error.DeviceUnavailable, selectByIds(&candidates, "locked"));
    const selected = selectAll(&candidates);
    try std.testing.expectEqual(@as(usize, 1), selected.len);
    try std.testing.expectEqual(@as(usize, 1), selected.indices[0]);
}

test "loading frame identifies the CLI before device discovery" {
    var buf: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);

    try writeLoading(&writer, "Android · iOS · this Mac");

    const rendered = writer.buffered();
    const title_at = std.mem.indexOf(u8, rendered, "zzzbench") orelse return error.MissingTitle;
    const search_at = std.mem.indexOf(u8, rendered, "Searching for devices") orelse return error.MissingSearchState;
    try std.testing.expect(title_at < search_at);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Android · iOS · this Mac") != null);
}

test "comparison picker requires two devices and processes arrows plus space" {
    const candidate: device.Candidate = .{ .platform = .host, .id = "host", .name = "Mac", .transport = "local" };
    const candidates = [_]device.Candidate{candidate} ** 3;
    var selected: Selection = .{};
    var cursor: usize = 0;
    try std.testing.expect(!try compareKey(&candidates, &selected, &cursor, .select));
    _ = try compareKey(&candidates, &selected, &cursor, .toggle);
    try std.testing.expect(!try compareKey(&candidates, &selected, &cursor, .select));
    _ = try compareKey(&candidates, &selected, &cursor, .down);
    _ = try compareKey(&candidates, &selected, &cursor, .toggle);
    try std.testing.expect(try compareKey(&candidates, &selected, &cursor, .select));
    try std.testing.expectEqualSlices(usize, &.{ 0, 1 }, selected.indices[0..selected.len]);
    _ = try compareKey(&candidates, &selected, &cursor, .toggle);
    try std.testing.expect(!try compareKey(&candidates, &selected, &cursor, .select));
    _ = try compareKey(&candidates, &selected, &cursor, .up);
    _ = try compareKey(&candidates, &selected, &cursor, .up);
    try std.testing.expectEqual(@as(usize, 2), cursor);
    _ = try compareKey(&candidates, &selected, &cursor, .down);
    try std.testing.expectEqual(@as(usize, 0), cursor);
}

test "comparison picker rejects unavailable devices and stops at five" {
    const candidate: device.Candidate = .{ .platform = .host, .id = "host", .name = "Mac", .transport = "local" };
    var candidates = [_]device.Candidate{candidate} ** 7;
    candidates[0].selectable = false;
    var selected: Selection = .{};
    var cursor: usize = 0;
    _ = try compareKey(&candidates, &selected, &cursor, .toggle);
    try std.testing.expectEqual(@as(usize, 0), selected.len);
    for (1..candidates.len) |_| {
        _ = try compareKey(&candidates, &selected, &cursor, .down);
        _ = try compareKey(&candidates, &selected, &cursor, .toggle);
    }
    try std.testing.expectEqual(max_selected, selected.len);
    try std.testing.expect(!selected.contains(0));
    try std.testing.expect(!selected.contains(6));
}

test "comparison picker cancels an empty or single-device selection" {
    const candidates = [_]device.Candidate{.{ .platform = .host, .id = "host", .name = "Mac", .transport = "local" }};
    var selected = selectAll(&candidates);
    var cursor: usize = 0;
    try std.testing.expect(!try compareKey(&candidates, &selected, &cursor, .select));
    for ([_][]const u8{ "q", "\x1b" }) |input| {
        var burst: keys.Iterator = .{ .bytes = input };
        try std.testing.expectError(error.SelectionCancelled, compareKey(&candidates, &selected, &cursor, burst.next().?));
    }
    selected = .{};
    try std.testing.expect(!try compareKey(&.{}, &selected, &cursor, .select));
    try std.testing.expectError(error.SelectionCancelled, compareKey(&.{}, &selected, &cursor, .cancel));
}

test "comparison picker removes stale unavailable and duplicate initial choices" {
    const candidates = [_]device.Candidate{
        .{ .platform = .host, .id = "host", .name = "Mac", .transport = "local" },
        .{ .platform = .android, .id = "locked", .name = "Phone", .transport = "adb-usb", .selectable = false },
    };
    const initial: Selection = .{ .indices = .{ 0, 1, 9, 0, 0 }, .len = 4 };
    const selected = availableSelection(&candidates, initial);
    try std.testing.expectEqualSlices(usize, &.{0}, selected.indices[0..selected.len]);
}
