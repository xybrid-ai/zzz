//! Device identities used when moving a live dashboard into split view.
const std = @import("std");
const device = @import("discovery/device.zig");
const picker = @import("device_picker.zig");
const wire = @import("wire.zig");

/// Keep connected devices first, including manually supplied endpoints.
/// Discovery can find an already connected phone by its serial while its
/// forwarded port changes; either the identity or endpoint makes it one row.
pub fn merge(arena: std.mem.Allocator, current: []const device.Candidate, discovered: []const device.Candidate) ![]device.Candidate {
    var result: std.ArrayList(device.Candidate) = .empty;
    for (current) |candidate| try result.append(arena, candidate);
    for (discovered) |candidate| {
        if (find(result.items, candidate) == null) try result.append(arena, candidate);
    }
    return result.toOwnedSlice(arena);
}

pub fn find(candidates: []const device.Candidate, wanted: device.Candidate) ?usize {
    for (candidates, 0..) |candidate, index| {
        if (candidate.platform == wanted.platform and std.mem.eql(u8, candidate.id, wanted.id)) return index;
        if (sameEndpoint(candidate.endpoint, wanted.endpoint)) return index;
    }
    return null;
}

fn sameEndpoint(a: []const u8, b: []const u8) bool {
    if (a.len == 0 or b.len == 0) return false;
    if (std.mem.eql(u8, a, b)) return true;
    if (!std.mem.startsWith(u8, a, "tcp:") or !std.mem.startsWith(u8, b, "tcp:")) return false;
    const left = wire.parseTcpEndpoint(a) catch return false;
    const right = wire.parseTcpEndpoint(b) catch return false;
    return left.port == right.port and isLoopback(left.host) and isLoopback(right.host);
}

pub fn isLoopback(host: ?[]const u8) bool {
    const name = host orelse return true;
    return std.mem.eql(u8, name, "127.0.0.1") or std.mem.eql(u8, name, "localhost") or std.mem.eql(u8, name, "::1");
}

/// The local runner feeds the primary slot. Race columns are equal, so put
/// this Mac there regardless of selection order instead of dropping its run.
pub fn hostFirst(candidates: []const device.Candidate, selected: picker.Selection) picker.Selection {
    var ordered = selected;
    for (selected.indices[0..selected.len], 0..) |index, position| {
        const candidate = candidates[index];
        if (candidate.platform != .host or !std.mem.eql(u8, candidate.id, "localhost")) continue;
        std.mem.copyBackwards(usize, ordered.indices[1 .. position + 1], ordered.indices[0..position]);
        ordered.indices[0] = index;
        break;
    }
    return ordered;
}

test "device comparison keeps manual endpoints and deduplicates discovered devices" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const current = [_]device.Candidate{
        .{ .platform = .android, .id = "pixel-serial", .name = "Pixel 8", .transport = "adb", .endpoint = "tcp:8100" },
        .{ .platform = .host, .id = "tcp:9200", .name = "Remote Mac", .transport = "manual", .endpoint = "tcp:9200" },
    };
    const found = try merge(arena.allocator(), &current, &.{
        .{ .platform = .android, .id = "pixel-serial", .name = "Pixel 8", .transport = "adb" },
        .{ .platform = .host, .id = "localhost", .name = "Mac", .transport = "local", .endpoint = "tcp:7779" },
    });
    try std.testing.expectEqual(@as(usize, 3), found.len);
    try std.testing.expectEqualStrings("tcp:8100", found[0].endpoint);
    try std.testing.expectEqualStrings("Remote Mac", found[1].name);
    try std.testing.expect(sameEndpoint("tcp:7779", "tcp:127.0.0.1:7779"));
    try std.testing.expect(!sameEndpoint("tcp:7779", "tcp:192.0.2.1:7779"));
}

test "device comparison puts the local runner first without changing membership" {
    const candidates = [_]device.Candidate{
        .{ .platform = .android, .id = "pixel", .name = "Pixel", .transport = "adb" },
        .{ .platform = .android, .id = "oppo", .name = "Oppo", .transport = "adb" },
        .{ .platform = .host, .id = "localhost", .name = "Mac", .transport = "local" },
    };
    var selected: picker.Selection = .{};
    try selected.append(0);
    try selected.append(1);
    try selected.append(2);
    const ordered = hostFirst(&candidates, selected);
    try std.testing.expectEqualSlices(usize, &.{ 2, 0, 1 }, ordered.indices[0..ordered.len]);
    selected.len = 2;
    const phones = hostFirst(&candidates, selected);
    try std.testing.expectEqualSlices(usize, &.{ 0, 1 }, phones.indices[0..phones.len]);
}
