//! Public zzz build: shared interfaces, the zzzbench application, and
//! repository checks. Engines and probes are supplied binaries, never built here.
const std = @import("std");

pub const Config = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    is_macos: bool,
    strip: bool = false,
};

/// Everything `zig build fmt` formats and `zig build ci` checks.
const fmt_paths = [_][]const u8{ "build.zig", "build.zig.zon", "build_support.zig", "shared", "tests", "tools" };

/// Source files the build compiles directly. `tools/tidy.zig` checks that
/// every other Zig file is imported from one of these, and that every file
/// with tests is imported from a test root.
const Roots = struct {
    b: *std.Build,
    all: std.ArrayList([]const u8) = .empty,
    tests: std.ArrayList([]const u8) = .empty,

    fn source(roots: *Roots, path: []const u8) std.Build.LazyPath {
        roots.all.append(roots.b.allocator, path) catch @panic("OOM");
        return roots.b.path(path);
    }

    fn testSource(roots: *Roots, path: []const u8) std.Build.LazyPath {
        roots.tests.append(roots.b.allocator, path) catch @panic("OOM");
        return roots.source(path);
    }
};

pub fn add(b: *std.Build, core: Config) void {
    const target = core.target;
    const optimize = core.optimize;
    const test_filters = b.option([]const []const u8, "test-filter", "Run only tests whose names contain this text (repeatable)") orelse &.{};
    const exhaustive = b.option(bool, "exhaustive", "Run exhaustive rendering sweeps in `test` (always on in `ci`)") orelse false;
    var roots: Roots = .{ .b = b };

    const test_step = b.step("test", "Run public application, interface, and repository tests");
    const check_step = b.step("check", "Compile zzzbench and every test binary without running them");
    const ci_step = b.step("ci", "Run what CI runs: format check, exhaustive tests, compilation, package consumer");

    b.step("fmt", "Format all Zig sources").dependOn(&b.addFmt(.{ .paths = &fmt_paths }).step);
    ci_step.dependOn(&b.addFmt(.{ .paths = &fmt_paths, .check = true }).step);

    // The supported public interfaces. Other packages import these with
    // `dep.module("proto")` and `dep.module("engine_contract")`.
    const proto_mod = b.addModule("proto", .{
        .root_source_file = roots.testSource("shared/proto.zig"),
        .target = target,
        .optimize = optimize,
    });
    const engine_contract_mod = b.addModule("engine_contract", .{
        .root_source_file = roots.testSource("shared/engine_contract.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Application utilities: compiled into zzzbench, not exported.
    const net_compat_mod = b.createModule(.{
        .root_source_file = roots.source("shared/net_compat.zig"),
        .target = target,
        .optimize = optimize,
    });
    const time_compat_mod = b.createModule(.{
        .root_source_file = roots.source("shared/time_compat.zig"),
        .target = target,
        .optimize = optimize,
    });
    const gguf_metadata_mod = b.createModule(.{
        .root_source_file = roots.testSource("shared/gguf_metadata.zig"),
        .target = target,
        .optimize = optimize,
    });
    const recap_bars_mod = b.createModule(.{
        .root_source_file = roots.source("shared/recap_bars.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Importing a module from another does not run its tests; each tested
    // shared module needs its own artifact.
    for ([_]*std.Build.Module{ proto_mod, engine_contract_mod, gguf_metadata_mod }) |module| {
        const tests = b.addTest(.{ .root_module = module, .filters = test_filters });
        const run_tests = b.addRunArtifact(tests);
        check_step.dependOn(&tests.step);
        test_step.dependOn(&run_tests.step);
        ci_step.dependOn(&run_tests.step);
    }

    // Only the application and its tests need the pinned terminal toolkit.
    // Interface-only consumers opt out with -Dtui=false. Android does not
    // build the application; it runs separately supplied engine/probe binaries.
    const tui_enabled = b.option(bool, "tui", "Build the zzzbench application and its tests, fetching the tuiz package (default: true)") orelse true;
    const bench_wanted = tui_enabled and (core.is_macos or (target.result.os.tag == .linux and target.result.abi != .android));
    const tuiz_mod: ?*std.Build.Module = if (!bench_wanted) null else if (b.lazyDependency("tuiz", .{
        .target = target,
        .optimize = optimize,
    })) |dep| dep.module("tuiz") else null;

    // Registered on every host so documented commands always resolve; they
    // explain themselves where the application cannot be built.
    const zzzbench_step = b.step("zzzbench", "Build, install, and run zzzbench (pass arguments after --)");
    const golden_step = b.step("update-golden", "Rewrite the dashboard golden snapshot; review the diff before committing");
    const main_source = roots.source("tools/zzzbench/main.zig");
    const tests_source = roots.testSource("tools/zzzbench/tests.zig");
    const golden_source = roots.source("tools/zzzbench/update_golden.zig");

    if (tuiz_mod) |tuiz| {
        const bench_imports: []const std.Build.Module.Import = &.{
            .{ .name = "proto", .module = proto_mod },
            .{ .name = "engine_contract", .module = engine_contract_mod },
            .{ .name = "net_compat", .module = net_compat_mod },
            .{ .name = "time_compat", .module = time_compat_mod },
            .{ .name = "gguf_metadata", .module = gguf_metadata_mod },
            .{ .name = "recap_bars", .module = recap_bars_mod },
            .{ .name = "tuiz", .module = tuiz },
        };

        // `ci` always runs the exhaustive rendering sweeps; `test` samples
        // them unless -Dexhaustive is given.
        const bench_tests = benchTests(b, tests_source, target, optimize, bench_imports, test_filters, exhaustive);
        const ci_bench_tests = if (exhaustive) bench_tests else benchTests(b, tests_source, target, optimize, bench_imports, test_filters, true);
        check_step.dependOn(&bench_tests.step);
        test_step.dependOn(&b.addRunArtifact(bench_tests).step);
        ci_step.dependOn(&b.addRunArtifact(ci_bench_tests).step);

        const golden = b.addExecutable(.{
            .name = "update-golden",
            .root_module = b.createModule(.{
                .root_source_file = golden_source,
                .target = target,
                .optimize = optimize,
                .link_libc = true,
                .imports = bench_imports,
            }),
        });
        check_step.dependOn(&golden.step);
        ci_step.dependOn(&golden.step);
        const write_golden = b.addUpdateSourceFiles();
        write_golden.addCopyFileToSource(
            b.addRunArtifact(golden).captureStdOut(.{}),
            "tools/zzzbench/ui/testdata/dashboard.golden",
        );
        golden_step.dependOn(&write_golden.step);

        // The interactive application runs on macOS; its tests also run on
        // Linux. Runtime binaries are resolved by the application, never built here.
        if (core.is_macos) {
            const zzzbench = b.addExecutable(.{
                .name = "zzzbench",
                .root_module = b.createModule(.{
                    .root_source_file = main_source,
                    .target = target,
                    .optimize = optimize,
                    .strip = core.strip,
                    .imports = bench_imports,
                }),
            });
            const install = b.addInstallArtifact(zzzbench, .{});
            b.getInstallStep().dependOn(&install.step);
            check_step.dependOn(&zzzbench.step);
            ci_step.dependOn(&zzzbench.step);
            // Run the installed executable so package-relative discovery also works
            // for custom prefixes and after moving the distribution directory.
            const run_zzzbench = b.addSystemCommand(&.{b.getInstallPath(.bin, "zzzbench")});
            run_zzzbench.step.dependOn(&install.step);
            if (b.args) |raw_args| run_zzzbench.addArgs(raw_args);
            zzzbench_step.dependOn(&run_zzzbench.step);
        } else {
            zzzbench_step.dependOn(&b.addFail("the zzzbench application currently builds on macOS only").step);
        }
    } else {
        const reason = "zzzbench needs the tuiz package: build for macOS or Linux without -Dtui=false";
        zzzbench_step.dependOn(&b.addFail(reason).step);
        golden_step.dependOn(&b.addFail(reason).step);
    }

    // A separate package imports the exported modules without fetching the
    // terminal toolkit, as a downstream consumer would.
    const consumer = b.addSystemCommand(&.{ b.graph.zig_exe, "build", "test" });
    consumer.setCwd(b.path("tests/consumer"));
    consumer.has_side_effects = true;
    ci_step.dependOn(&consumer.step);

    // Repository checks read files the build graph does not track, so they
    // always run. The step list is taken last, once every step exists.
    const tidy_options = b.addOptions();
    const tidy_source = roots.testSource("tools/tidy.zig");
    tidy_options.addOption([]const []const u8, "roots", roots.all.items);
    tidy_options.addOption([]const []const u8, "test_roots", roots.tests.items);
    tidy_options.addOption([]const []const u8, "steps", b.top_level_steps.keys());
    const tidy_module = b.createModule(.{
        .root_source_file = tidy_source,
        .target = b.graph.host,
        .optimize = .Debug,
    });
    tidy_module.addOptions("tidy_options", tidy_options);
    const tidy = b.addTest(.{ .root_module = tidy_module, .filters = test_filters });
    check_step.dependOn(&tidy.step);
    const run_tidy = b.addRunArtifact(tidy);
    run_tidy.setCwd(b.path("."));
    run_tidy.has_side_effects = true;
    test_step.dependOn(&run_tidy.step);
    ci_step.dependOn(&run_tidy.step);
}

fn benchTests(
    b: *std.Build,
    root: std.Build.LazyPath,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    imports: []const std.Build.Module.Import,
    filters: []const []const u8,
    exhaustive: bool,
) *std.Build.Step.Compile {
    const test_options = b.addOptions();
    test_options.addOption(bool, "exhaustive", exhaustive);
    const module = b.createModule(.{
        .root_source_file = root,
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = imports,
    });
    module.addOptions("test_options", test_options);
    return b.addTest(.{ .root_module = module, .filters = filters });
}
