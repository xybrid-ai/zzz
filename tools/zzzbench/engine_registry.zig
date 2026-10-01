//! Engine manifest discovery, precedence, and listing output.

const std = @import("std");
const manifest_mod = @import("engine_manifest.zig");

const Manifest = manifest_mod.Manifest;

const builtin_files = [_]struct { source: []const u8, text: []const u8 }{
    .{ .source = "builtin:zzz.toml", .text = @embedFile("engines/zzz.toml") },
    .{ .source = "builtin:llamacpp.toml", .text = @embedFile("engines/llamacpp.toml") },
    .{ .source = "builtin:llamacpp-depth.toml", .text = @embedFile("engines/llamacpp-depth.toml") },
};

pub const LoadOptions = struct {
    home: ?[]const u8 = null,
    config_home: ?[]const u8 = null,
    engine_dirs: []const []const u8 = &.{},
};

pub fn load(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    io: std.Io,
    options: LoadOptions,
    diagnostic: *manifest_mod.Diagnostic,
) ![]const Manifest {
    var manifests: std.ArrayListUnmanaged(Manifest) = .empty;
    const builtins = try loadBuiltins(arena, diagnostic);
    try manifests.appendSlice(arena, builtins);

    if (try defaultDirectory(gpa, options)) |path| {
        defer gpa.free(path);
        try loadDirectory(gpa, arena, io, path, false, &manifests, diagnostic);
    }
    for (options.engine_dirs) |path| {
        try loadDirectory(gpa, arena, io, path, true, &manifests, diagnostic);
    }
    sort(manifests.items);
    return manifests.toOwnedSlice(arena);
}

pub fn loadBuiltins(
    arena: std.mem.Allocator,
    diagnostic: *manifest_mod.Diagnostic,
) ![]const Manifest {
    var manifests: std.ArrayListUnmanaged(Manifest) = .empty;
    for (builtin_files) |file| {
        try manifests.append(
            arena,
            try manifest_mod.parse(arena, file.source, file.text, diagnostic),
        );
    }
    sort(manifests.items);
    return manifests.toOwnedSlice(arena);
}

pub fn merge(
    arena: std.mem.Allocator,
    earlier: []const Manifest,
    later: []const Manifest,
) ![]const Manifest {
    var manifests = try std.ArrayListUnmanaged(Manifest).initCapacity(
        arena,
        earlier.len + later.len,
    );
    try manifests.appendSlice(arena, earlier);
    for (later) |manifest| try put(arena, &manifests, manifest);
    sort(manifests.items);
    return manifests.toOwnedSlice(arena);
}

fn loadDirectory(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    required: bool,
    manifests: *std.ArrayListUnmanaged(Manifest),
    diagnostic: *manifest_mod.Diagnostic,
) !void {
    var directory = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |err| {
        if (!required) {
            switch (err) {
                error.FileNotFound, error.NotDir, error.AccessDenied => return,
                else => {},
            }
        }
        return err;
    };
    defer directory.close(io);

    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (names.items) |name| gpa.free(name);
        names.deinit(gpa);
    }
    var iterator = directory.iterate();
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .file and entry.kind != .sym_link) continue;
        if (!std.mem.endsWith(u8, entry.name, ".toml")) continue;
        try names.append(gpa, try gpa.dupe(u8, entry.name));
    }
    std.mem.sort([]const u8, names.items, {}, lessThanText);

    for (names.items) |name| {
        const source = try std.fs.path.join(gpa, &.{ path, name });
        defer gpa.free(source);
        const text = std.Io.Dir.cwd().readFileAlloc(
            io,
            source,
            gpa,
            .limited(manifest_mod.manifest_bytes_max + 1),
        ) catch |err| switch (err) {
            error.StreamTooLong => {
                diagnostic.* = .{
                    .source = try arena.dupe(u8, source),
                    .line = 1,
                    .kind = .too_large,
                };
                return error.InvalidManifest;
            },
            else => return err,
        };
        defer gpa.free(text);
        const parsed = try manifest_mod.parse(arena, source, text, diagnostic);
        try put(arena, manifests, parsed);
    }
}

fn defaultDirectory(
    gpa: std.mem.Allocator,
    options: LoadOptions,
) !?[]const u8 {
    if (options.config_home) |root| {
        return try std.fs.path.join(gpa, &.{ root, "zzzbench", "engines" });
    }
    if (options.home) |root| {
        return try std.fs.path.join(gpa, &.{ root, ".config", "zzzbench", "engines" });
    }
    return null;
}

fn put(
    arena: std.mem.Allocator,
    manifests: *std.ArrayListUnmanaged(Manifest),
    manifest: Manifest,
) !void {
    for (manifests.items) |*existing| {
        if (!std.mem.eql(u8, existing.id, manifest.id)) continue;
        existing.* = manifest;
        return;
    }
    try manifests.append(arena, manifest);
}

fn sort(manifests: []Manifest) void {
    std.mem.sort(Manifest, manifests, {}, struct {
        fn lessThan(_: void, left: Manifest, right: Manifest) bool {
            return std.mem.lessThan(u8, left.id, right.id);
        }
    }.lessThan);
}

fn lessThanText(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.lessThan(u8, left, right);
}

pub fn writeTable(writer: *std.Io.Writer, manifests: []const Manifest) !void {
    // Columns sized for the longest built-in id and label, so a table
    // with every adapter loaded still lines up.
    try writer.writeAll(
        "ID              LABEL             PARSER              MODE       HOST  ANDROID  SOURCE\n",
    );
    for (manifests) |manifest| {
        try writer.print("{s: <15} {s: <17} {s: <19} {s: <10} {s: <5} {s: <8} {s}\n", .{
            manifest.id,
            manifest.label,
            manifest.parser.label(),
            @tagName(manifest.fidelity),
            yesNo(manifest.available(.host)),
            yesNo(manifest.available(.android)),
            manifest.source,
        });
    }
}

pub fn writeJson(writer: *std.Io.Writer, manifests: []const Manifest) !void {
    const Listing = struct {
        id: []const u8,
        label: []const u8,
        parser: []const u8,
        fidelity: []const u8,
        host: bool,
        android: bool,
        source: []const u8,
    };
    var json: std.json.Stringify = .{ .writer = writer, .options = .{} };
    try json.beginArray();
    for (manifests) |manifest| {
        try json.write(Listing{
            .id = manifest.id,
            .label = manifest.label,
            .parser = manifest.parser.label(),
            .fidelity = @tagName(manifest.fidelity),
            .host = manifest.available(.host),
            .android = manifest.available(.android),
            .source = manifest.source,
        });
    }
    try json.endArray();
    try writer.writeByte('\n');
}

fn yesNo(value: bool) []const u8 {
    return if (value) "yes" else "no";
}

test "embedded manifests load in deterministic id order" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var diagnostic: manifest_mod.Diagnostic = .{};

    const manifests = try loadBuiltins(arena_state.allocator(), &diagnostic);
    try std.testing.expectEqual(builtin_files.len, manifests.len);
    try std.testing.expectEqualStrings("llamacpp", manifests[0].id);
    try std.testing.expectEqualStrings("llamacpp-depth", manifests[1].id);
    try std.testing.expectEqualStrings("zzz", manifests[2].id);
    try std.testing.expectEqualStrings("builtin:llamacpp.toml", manifests[0].source);
    try std.testing.expect(manifests[0].available(.android));
    try std.testing.expect(manifests[2].available(.host));
}

test "a later manifest replaces an earlier id without changing sort order" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diagnostic: manifest_mod.Diagnostic = .{};

    const builtins = try loadBuiltins(arena, &diagnostic);
    const override = try manifest_mod.parse(arena, "/override/zzz.toml",
        \\schema = 1
        \\id = "zzz"
        \\label = "zzz local"
        \\parser = "zzz-binary"
        \\fidelity = "streaming"
        \\bin.host = "/tmp/zzz"
        \\argv = ["{bin}", "bench-run", "{model}", "--protocol", "1", "--report-binary"]
    , &diagnostic);
    const merged = try merge(arena, builtins, &.{override});

    // An override replaces its id in place; it never adds a row.
    try std.testing.expectEqual(builtin_files.len, merged.len);
    try std.testing.expectEqualStrings("llamacpp", merged[0].id);
    // `zzz` sorts last among the builtins, and an override keeps that
    // position rather than jumping the list.
    try std.testing.expectEqualStrings("zzz local", merged[merged.len - 1].label);
    try std.testing.expectEqualStrings("/override/zzz.toml", merged[merged.len - 1].source);
}

test "JSON listing exposes parser platform availability and source" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var diagnostic: manifest_mod.Diagnostic = .{};
    const manifests = try loadBuiltins(arena_state.allocator(), &diagnostic);
    var buffer: [2048]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try writeJson(&writer, manifests);
    const output = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, "\"id\":\"llamacpp\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"parser\":\"zzz-binary\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"android\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"source\":\"builtin:zzz.toml\"") != null);
}

test "an explicit directory loads files in name order and overrides builtins" {
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    try temporary_directory.dir.writeFile(std.testing.io, .{
        .sub_path = "20-zzz.toml",
        .data =
        \\schema = 1
        \\id = "zzz"
        \\label = "zzz override"
        \\parser = "zzz-binary"
        \\fidelity = "streaming"
        \\bin.host = "/tmp/zzz"
        \\argv = ["{bin}", "bench-run", "{model}", "--protocol", "1", "--report-binary"]
        ,
    });
    try temporary_directory.dir.writeFile(std.testing.io, .{
        .sub_path = "10-extra.toml",
        .data =
        \\schema = 1
        \\id = "extra"
        \\label = "Extra"
        \\parser = "json-object"
        \\fidelity = "summary"
        \\bin.host = "/tmp/extra"
        \\metrics.prefill = "prefill"
        \\metrics.decode = "decode"
        \\argv = ["{bin}", "{model}"]
        ,
    });
    const path = try std.fmt.allocPrint(
        std.testing.allocator,
        ".zig-cache/tmp/{s}",
        .{temporary_directory.sub_path},
    );
    defer std.testing.allocator.free(path);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var diagnostic: manifest_mod.Diagnostic = .{};
    const manifests = try load(
        std.testing.allocator,
        arena_state.allocator(),
        std.testing.io,
        .{ .engine_dirs = &.{path} },
        &diagnostic,
    );
    try std.testing.expectEqual(builtin_files.len + 1, manifests.len);
    try std.testing.expectEqualStrings("extra", manifests[0].id);
    try std.testing.expectEqualStrings("llamacpp", manifests[1].id);
    try std.testing.expectEqualStrings("zzz override", manifests[manifests.len - 1].label);
}

test "a failed file keeps its source and field diagnostic alive" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var diagnostic: manifest_mod.Diagnostic = .{};
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    try directory.dir.writeFile(std.testing.io, .{
        .sub_path = "invalid-engine.toml",
        .data = @embedFile("testdata/invalid-engine.toml"),
    });
    const path = try directory.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(path);

    try std.testing.expectError(error.InvalidManifest, load(
        std.testing.allocator,
        arena_state.allocator(),
        std.testing.io,
        .{ .engine_dirs = &.{path} },
        &diagnostic,
    ));
    try std.testing.expectEqual(manifest_mod.Kind.unknown_field, diagnostic.kind);
    try std.testing.expectEqual(@as(u32, 7), diagnostic.line);
    try std.testing.expectEqualStrings("surprise", diagnostic.field);
    try std.testing.expect(std.mem.endsWith(
        u8,
        diagnostic.source,
        "invalid-engine.toml",
    ));
}
