//! Resolve the relocatable distribution's Android payload, without building it.
const std = @import("std");
pub const android_dir = "share/zzzbench/v1/aarch64-linux-android";
pub const Artifact = enum { probe, engine };

pub fn supportsI8mm(cpuinfo: []const u8) bool {
    var lines = std.mem.splitScalar(u8, cpuinfo, '\n');
    var found = false;
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (!std.mem.eql(u8, std.mem.trim(u8, line[0..colon], " \t"), "Features")) continue;
        found = true;
        var features = std.mem.tokenizeAny(u8, line[colon + 1 ..], " \t\r");
        var dotprod = false;
        var i8mm = false;
        while (features.next()) |feature| {
            if (std.mem.eql(u8, feature, "asimddp")) dotprod = true;
            if (std.mem.eql(u8, feature, "i8mm")) i8mm = true;
        }
        if (!dotprod or !i8mm) return false;
    }
    return found;
}

pub fn resolve(
    allocator: std.mem.Allocator,
    io: std.Io,
    executable: []const u8,
    artifact: Artifact,
    override: ?[]const u8,
    i8mm: bool,
) ![:0]const u8 {
    if (override) |path| return std.Io.Dir.cwd().realPathFileAlloc(io, path, allocator);
    const bin_dir = std.fs.path.dirname(executable) orelse return error.BundleMissing;
    const prefix = std.fs.path.dirname(bin_dir) orelse return error.BundleMissing;
    if (artifact == .engine and i8mm) {
        if (try candidate(allocator, io, prefix, "i8mm/zzz")) |path| return path;
    }
    const relative = switch (artifact) {
        .probe => "zzzprobe",
        .engine => "baseline/zzz",
    };
    return try candidate(allocator, io, prefix, relative) orelse error.BundleMissing;
}

fn candidate(
    allocator: std.mem.Allocator,
    io: std.Io,
    prefix: []const u8,
    relative: []const u8,
) !?[:0]const u8 {
    const path = try std.fs.path.join(allocator, &.{ prefix, android_dir, relative });
    defer allocator.free(path);
    return std.Io.Dir.cwd().realPathFileAlloc(io, path, allocator) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
}

test "i8mm selection requires both instructions on every reported CPU" {
    try std.testing.expect(supportsI8mm("Features : fp asimddp i8mm\n"));
    try std.testing.expect(!supportsI8mm("Features : fp i8mm\n"));
    try std.testing.expect(!supportsI8mm("Features : fp asimddp\n"));
    try std.testing.expect(!supportsI8mm("Features : fp asimddp i8mm\nFeatures : fp asimddp\n"));
    try std.testing.expect(!supportsI8mm("Features : fp asimddp not_i8mm\n"));
    try std.testing.expect(!supportsI8mm(""));
}

test "relocated bundle selects compatible engine and respects explicit paths" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "bin");
    try tmp.dir.createDirPath(io, android_dir ++ "/baseline");
    try tmp.dir.createDirPath(io, android_dir ++ "/i8mm");
    const baseline = try tmp.dir.createFile(io, android_dir ++ "/baseline/zzz", .{});
    baseline.close(io);
    const probe = try tmp.dir.createFile(io, android_dir ++ "/zzzprobe", .{});
    probe.close(io);
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const executable = try std.fs.path.join(allocator, &.{ root, "bin", "zzzbench" });
    defer allocator.free(executable);
    const expected = try std.fs.path.join(allocator, &.{ root, android_dir, "baseline/zzz" });
    defer allocator.free(expected);
    // A missing optional optimized binary falls back to the baseline.
    const fallback = try resolve(allocator, io, executable, .engine, null, true);
    defer allocator.free(fallback);
    try std.testing.expectEqualStrings(expected, fallback);
    const fast = try tmp.dir.createFile(io, android_dir ++ "/i8mm/zzz", .{});
    fast.close(io);
    const selected = try resolve(allocator, io, executable, .engine, null, true);
    defer allocator.free(selected);
    try std.testing.expect(std.mem.endsWith(u8, selected, "/i8mm/zzz"));
    const conservative = try resolve(allocator, io, executable, .engine, null, false);
    defer allocator.free(conservative);
    try std.testing.expectEqualStrings(expected, conservative);
    const overridden = try resolve(allocator, io, executable, .engine, expected, true);
    defer allocator.free(overridden);
    try std.testing.expectEqualStrings(expected, overridden);
    try std.testing.expectError(error.FileNotFound, resolve(allocator, io, executable, .engine, "/missing-explicit-zzz", true));
    const found_probe = try resolve(allocator, io, executable, .probe, null, false);
    defer allocator.free(found_probe);
    try std.testing.expect(std.mem.endsWith(u8, found_probe, "/zzzprobe"));
    try std.testing.expectError(error.BundleMissing, resolve(allocator, io, "/missing-package/bin/zzzbench", .probe, null, false));
}
