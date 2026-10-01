//! Resolve one validated manifest into direct argv and environment entries.

const std = @import("std");
const manifest_mod = @import("engine_manifest.zig");

pub const ResolveOptions = struct {
    platform: manifest_mod.Platform,
    binary: ?[]const u8 = null,
    home: ?[]const u8 = null,
    model: []const u8,
    threads: u32 = 4,
    n_prompt: u32 = 16,
    n_generate: u32 = 32,
    prompt: []const u8 = "",
    kernel: []const u8 = "auto",
    workspace: ?[]const u8 = null,
};

pub const Command = struct {
    argv: []const []const u8,
    environment: []const manifest_mod.EnvironmentEntry,
};

pub fn resolve(
    arena: std.mem.Allocator,
    manifest: manifest_mod.Manifest,
    options: ResolveOptions,
) !Command {
    if (options.model.len == 0) return error.ModelRequired;
    const raw_bin = options.binary orelse manifest.bin.get(options.platform) orelse
        return error.PlatformUnavailable;
    const workspace_bin = try expandWorkspace(arena, raw_bin, options.workspace);
    const bin = if (options.platform == .host)
        try expandHome(arena, workspace_bin, options.home)
    else
        workspace_bin;

    const use_prompt = options.prompt.len > 0;
    if (use_prompt and manifest.argv_prompt.len == 0) return error.UnsupportedPrompt;
    const use_kernel = options.kernel.len > 0 and
        !std.mem.eql(u8, options.kernel, "auto");
    if (use_kernel and manifest.argv_kernel.len == 0) return error.UnsupportedKernel;

    const argument_count = manifest.argv.len +
        (if (use_prompt) manifest.argv_prompt.len else 0) +
        (if (use_kernel) manifest.argv_kernel.len else 0);
    if (argument_count > manifest_mod.argument_count_max) return error.CommandTooLarge;

    var arguments = try std.ArrayListUnmanaged([]const u8).initCapacity(
        arena,
        argument_count,
    );
    try appendArguments(arena, &arguments, manifest.argv, bin, options);
    if (use_prompt) {
        try appendArguments(arena, &arguments, manifest.argv_prompt, bin, options);
    }
    if (use_kernel) {
        try appendArguments(arena, &arguments, manifest.argv_kernel, bin, options);
    }

    const source_environment = manifest.environment.get(options.platform);
    if (source_environment.len > manifest_mod.environment_count_max) {
        return error.CommandTooLarge;
    }
    var environment = try std.ArrayListUnmanaged(manifest_mod.EnvironmentEntry).initCapacity(
        arena,
        source_environment.len,
    );
    for (source_environment) |entry| {
        try environment.append(arena, .{
            .key = try arena.dupe(u8, entry.key),
            .value = try expand(arena, entry.value, bin, options),
        });
    }

    const argv = try arguments.toOwnedSlice(arena);
    const env = try environment.toOwnedSlice(arena);
    if (commandBytes(argv, env) > manifest_mod.command_bytes_max) {
        return error.CommandTooLarge;
    }
    return .{ .argv = argv, .environment = env };
}

fn appendArguments(
    arena: std.mem.Allocator,
    arguments: *std.ArrayListUnmanaged([]const u8),
    templates: []const []const u8,
    bin: []const u8,
    options: ResolveOptions,
) !void {
    for (templates) |template| {
        try arguments.append(arena, try expand(arena, template, bin, options));
    }
}

fn expand(
    arena: std.mem.Allocator,
    template: []const u8,
    bin: []const u8,
    options: ResolveOptions,
) ![]const u8 {
    var output: std.ArrayListUnmanaged(u8) = .empty;
    var index: usize = 0;
    while (std.mem.indexOfScalarPos(u8, template, index, '{')) |open| {
        const close = std.mem.indexOfScalarPos(u8, template, open + 1, '}').?;
        try output.appendSlice(arena, template[index..open]);
        const value = try placeholderValue(arena, template[open + 1 .. close], bin, options);
        try output.appendSlice(arena, value);
        index = close + 1;
    }
    try output.appendSlice(arena, template[index..]);
    return output.toOwnedSlice(arena);
}

fn placeholderValue(
    arena: std.mem.Allocator,
    name: []const u8,
    bin: []const u8,
    options: ResolveOptions,
) ![]const u8 {
    if (std.mem.eql(u8, name, "bin")) return bin;
    if (std.mem.eql(u8, name, "model")) return options.model;
    if (std.mem.eql(u8, name, "threads")) {
        return std.fmt.allocPrint(arena, "{d}", .{options.threads});
    }
    if (std.mem.eql(u8, name, "n_prompt")) {
        return std.fmt.allocPrint(arena, "{d}", .{options.n_prompt});
    }
    if (std.mem.eql(u8, name, "n_generate")) {
        return std.fmt.allocPrint(arena, "{d}", .{options.n_generate});
    }
    if (std.mem.eql(u8, name, "prompt")) return options.prompt;
    if (std.mem.eql(u8, name, "kernel")) return options.kernel;
    if (std.mem.eql(u8, name, "workspace")) {
        return options.workspace orelse error.WorkspaceRequired;
    }
    unreachable;
}

fn expandHome(
    arena: std.mem.Allocator,
    path: []const u8,
    home: ?[]const u8,
) ![]const u8 {
    if (std.mem.eql(u8, path, "~")) {
        return arena.dupe(u8, home orelse return error.HomeUnavailable);
    }
    if (std.mem.startsWith(u8, path, "~/")) {
        const root = home orelse return error.HomeUnavailable;
        return std.fs.path.join(arena, &.{ root, path[2..] });
    }
    return arena.dupe(u8, path);
}

fn expandWorkspace(
    arena: std.mem.Allocator,
    path: []const u8,
    workspace: ?[]const u8,
) ![]const u8 {
    const marker = "{workspace}";
    const at = std.mem.indexOf(u8, path, marker) orelse return arena.dupe(u8, path);
    const root = workspace orelse return error.WorkspaceRequired;
    var output: std.ArrayListUnmanaged(u8) = .empty;
    try output.appendSlice(arena, path[0..at]);
    try output.appendSlice(arena, root);
    try output.appendSlice(arena, path[at + marker.len ..]);
    return output.toOwnedSlice(arena);
}

fn commandBytes(
    arguments: []const []const u8,
    environment: []const manifest_mod.EnvironmentEntry,
) usize {
    var bytes: usize = 0;
    for (arguments) |argument| bytes += @sizeOf(u16) + argument.len;
    for (environment) |entry| {
        bytes += @sizeOf(u16) + entry.key.len + 1 + entry.value.len;
    }
    return bytes;
}

test "command resolution expands policy values without a shell" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diagnostic: manifest_mod.Diagnostic = .{};
    const manifest = try manifest_mod.parse(arena, "zzz.toml",
        \\schema = 1
        \\id = "zzz"
        \\label = "zzz"
        \\parser = "zzz-binary"
        \\fidelity = "streaming"
        \\bin.host = "~/bin/zzz"
        \\argv = ["{bin}", "bench-run", "{model}", "--protocol", "1", "--report-binary", "--threads", "{threads}"]
        \\argv_prompt = ["--prompt", "{prompt}", "--emit-text"]
        \\argv_kernel = ["--kernel", "{kernel}"]
    , &diagnostic);
    const command = try resolve(arena, manifest, .{
        .platform = .host,
        .home = "/Users/tester",
        .model = "/models/qwen.gguf",
        .threads = 8,
        .n_prompt = 128,
        .n_generate = 32,
        .prompt = "Hello world",
        .kernel = "sdot",
    });

    try std.testing.expectEqual(@as(usize, 13), command.argv.len);
    try std.testing.expectEqualStrings("/Users/tester/bin/zzz", command.argv[0]);
    try std.testing.expectEqualStrings("8", command.argv[7]);
    try std.testing.expectEqualStrings("Hello world", command.argv[9]);
    try std.testing.expectEqualStrings("sdot", command.argv[12]);
}

test "resolution rejects a policy that the manifest cannot express" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diagnostic: manifest_mod.Diagnostic = .{};
    const manifest = try manifest_mod.parse(arena, "summary.toml",
        \\schema = 1
        \\id = "summary"
        \\label = "Summary"
        \\parser = "json-object"
        \\fidelity = "summary"
        \\bin.android = "/data/local/tmp/summary"
        \\metrics.prefill = "prefill_tps"
        \\metrics.decode = "decode_tps"
        \\argv = ["{bin}", "{model}"]
    , &diagnostic);

    try std.testing.expectError(error.UnsupportedPrompt, resolve(arena, manifest, .{
        .platform = .android,
        .model = "/data/local/tmp/model.gguf",
        .prompt = "Hello",
    }));
    try std.testing.expectError(error.PlatformUnavailable, resolve(arena, manifest, .{
        .platform = .host,
        .model = "/models/model.gguf",
    }));
}

test "workspace paths resolve without becoming shell text" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diagnostic: manifest_mod.Diagnostic = .{};
    const manifest = try manifest_mod.parse(arena, "zzz.toml",
        \\schema = 1
        \\id = "zzz"
        \\label = "zzz"
        \\parser = "zzz-binary"
        \\fidelity = "streaming"
        \\bin.android = "{workspace}/zzz"
        \\argv = ["{bin}", "bench-run", "{model}", "--protocol", "1", "--report-binary"]
    , &diagnostic);
    const command = try resolve(arena, manifest, .{
        .platform = .android,
        .workspace = "/data/local/tmp/zzz-a1b2",
        .model = "/data/local/tmp/zzz-a1b2/model.gguf",
    });
    try std.testing.expectEqualStrings(
        "/data/local/tmp/zzz-a1b2/zzz",
        command.argv[0],
    );
}
