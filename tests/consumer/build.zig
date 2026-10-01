//! A downstream package: imports zzz's exported modules the way another
//! repository would, with the terminal toolkit disabled so it is never fetched.
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const zzz = b.dependency("zzz", .{ .target = target, .optimize = optimize, .tui = false });
    const consumer = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "proto", .module = zzz.module("proto") },
                .{ .name = "engine_contract", .module = zzz.module("engine_contract") },
            },
        }),
    });
    b.step("test", "Compile and run the consumer against the local zzz package").dependOn(&b.addRunArtifact(consumer).step);
}
