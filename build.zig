const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    _ = @import("build_support.zig").add(b, .{
        .target = target,
        .optimize = optimize,
        .is_macos = target.result.os.tag == .macos,
        .strip = b.option(bool, "strip", "Strip installed tools") orelse false,
    });
}
