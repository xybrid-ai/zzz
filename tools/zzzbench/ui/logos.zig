//! Optional artwork catalogue. No brand or project artwork is bundled.
//! Adding artwork is deferred; see ARTWORK.md for the inclusion requirements.
const std = @import("std");
const splash = @import("splash.zig");

pub const Named = struct {
    /// What `--logo` matches on: lowercase, no spaces.
    id: []const u8,
    label: []const u8,
    /// Gallery size — big enough to look at on its own.
    mark: splash.Mark,
    /// Plate size, for sitting beside the hero without competing with
    /// the number. Null when the mark has no art small enough to sit
    /// there at all.
    plate: ?splash.Mark,
    /// A smaller cut still, for terminals too narrow for the
    /// double-size headline digits, where `plate` would overpower a
    /// five-row number. Null when no smaller rendition is available.
    plate_sm: ?splash.Mark = null,
};

pub const catalog: [0]Named = .{};

/// Resolve an available mark by its case-insensitive command-line name.
pub fn byName(id: []const u8) ?Named {
    for (catalog) |n| {
        if (std.ascii.eqlIgnoreCase(n.id, id)) return n;
    }
    return null;
}

/// Comma-separated available identifiers for command-line diagnostics.
/// Only ids that can actually be drawn on a plate, since that is the
/// only thing `--logo` does.
pub fn writeIds(w: anytype) !void {
    var first = true;
    for (catalog) |n| {
        if (n.plate == null) continue;
        if (!first) try w.writeAll(", ");
        try w.writeAll(n.id);
        first = false;
    }
}

test "the public catalogue ships no artwork" {
    try std.testing.expectEqual(@as(usize, 0), catalog.len);
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeIds(&w);
    try std.testing.expectEqualStrings("", w.buffered());
}

test "deferred marks cannot be selected by name" {
    for ([_][]const u8{ "zzz", "example", "sample", "Example", "missing" }) |id| {
        try std.testing.expect(byName(id) == null);
    }
}
