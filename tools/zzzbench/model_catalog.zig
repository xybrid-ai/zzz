//! Host-side GGUF discovery and header summaries for `zzzbench models` and
//! the live model picker. Scanning maps files read-only and parses metadata;
//! tensor payloads are never copied into process-private memory.

const std = @import("std");
const gguf_api = @import("gguf_metadata");
const proto = @import("proto");

pub const Source = enum {
    workspace,
    huggingface,
    config,

    pub fn label(self: Source) []const u8 {
        return switch (self) {
            .workspace => "workspace",
            .huggingface => "hf-cache",
            .config => "config",
        };
    }
};

pub const Model = struct {
    path: []const u8,
    name: []const u8,
    quant: []const u8,
    architecture: []const u8,
    parameter_count: u64,
    size_bytes: u64,
    source: Source,

    pub fn unavailableReason(self: Model) ?[]const u8 {
        if (std.mem.eql(u8, self.architecture, "bert") or std.mem.eql(u8, self.architecture, "nomic-bert")) {
            return "Embedding model — this benchmark measures text generation.";
        }
        // Runtime admission belongs to the supplied engine, not a compiled UI list.
        return null;
    }
};

pub const ScanOptions = struct {
    workspace_path: []const u8,
    home: ?[]const u8 = null,
    config_home: ?[]const u8 = null,
};

pub fn scan(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    io: std.Io,
    options: ScanOptions,
) ![]Model {
    var models: std.ArrayListUnmanaged(Model) = .empty;
    defer models.deinit(gpa);
    // Resolved paths of everything already listed. Kept beside the
    // models rather than inside them so the JSON contract stays the
    // path the operator can actually type.
    var seen: std.ArrayListUnmanaged([:0]u8) = .empty;
    defer {
        for (seen.items) |path| gpa.free(path);
        seen.deinit(gpa);
    }

    const fixtures = try std.fs.path.join(gpa, &.{ options.workspace_path, "fixtures", "models" });
    defer gpa.free(fixtures);
    try scanRoot(gpa, arena, io, fixtures, .workspace, &models, &seen);

    if (options.home) |home| {
        const cache = try std.fs.path.join(gpa, &.{ home, ".cache", "huggingface", "hub" });
        defer gpa.free(cache);
        try scanRoot(gpa, arena, io, cache, .huggingface, &models, &seen);
    }

    const configured = try readConfiguredDirs(gpa, arena, io, options);
    for (configured) |path| try scanRoot(gpa, arena, io, path, .config, &models, &seen);

    std.sort.pdq(Model, models.items, {}, struct {
        fn lessThan(_: void, a: Model, b: Model) bool {
            // Case-insensitive: a lowercase repo name is not "after"
            // every capitalised one to a reader scanning the list.
            const by_name = std.ascii.orderIgnoreCase(a.name, b.name);
            if (by_name != .eq) return by_name == .lt;
            return std.mem.lessThan(u8, a.path, b.path);
        }
    }.lessThan);
    return try arena.dupe(Model, models.items);
}

fn scanRoot(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    source: Source,
    models: *std.ArrayListUnmanaged(Model),
    seen: *std.ArrayListUnmanaged([:0]u8),
) !void {
    var dir = std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir, error.AccessDenied => return,
        else => return err,
    };
    defer dir.close(io);
    var walker = try dir.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file and entry.kind != .sym_link) continue;
        if (!endsWithGguf(entry.basename)) continue;
        const joined = try std.fs.path.join(gpa, &.{ root, entry.path });
        defer gpa.free(joined);
        // Dedupe on the resolved path so one blob reached through two
        // links is listed once, but keep the *walked* path: a
        // Hugging Face snapshot entry is a symlink named
        // `Sample-8B.gguf` pointing at a blob named after its SHA, and
        // the name is where both the display name and the quant tag
        // live. Symlinks open fine on every consumer of this path.
        const canonical = std.Io.Dir.cwd().realPathFileAlloc(io, joined, gpa) catch continue;
        var keep_canonical = false;
        defer if (!keep_canonical) gpa.free(canonical);
        if (contains(seen.items, canonical)) continue;
        const model = inspect(gpa, arena, joined, source) catch continue;
        try models.append(gpa, model);
        try seen.append(gpa, canonical);
        keep_canonical = true;
    }
}

fn endsWithGguf(path: []const u8) bool {
    if (path.len < ".gguf".len) return false;
    return std.ascii.eqlIgnoreCase(path[path.len - ".gguf".len ..], ".gguf");
}

fn contains(paths: []const [:0]u8, path: []const u8) bool {
    for (paths) |seen| {
        if (std.mem.eql(u8, seen, path)) return true;
    }
    return false;
}

fn inspect(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    path: []const u8,
    source: Source,
) !Model {
    var reader = try gguf_api.MmapReader.init(path);
    defer reader.deinit();
    _ = gpa;
    const summary = try gguf_api.parse(reader.data);
    const architecture = summary.architecture;
    return .{
        .path = try arena.dupe(u8, path),
        // Filename, not `general.name`: it is the convention the probe
        // already puts in Hello, so the picker row and the title bar
        // agree after a selection — and repacked community GGUFs carry
        // a `general.name` that is a bare content hash.
        .name = try arena.dupe(u8, proto.deriveModelName(path)),
        .quant = try arena.dupe(u8, proto.quantFromPath(path) orelse summary.quant),
        .architecture = try arena.dupe(u8, architecture),
        .parameter_count = summary.parameters,
        .size_bytes = reader.data.len,
        .source = source,
    };
}

fn readConfiguredDirs(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    io: std.Io,
    options: ScanOptions,
) ![][]const u8 {
    const base = options.config_home orelse options.home orelse return &.{};
    const path = if (options.config_home != null)
        try std.fs.path.join(gpa, &.{ base, "zzzbench", "config.toml" })
    else
        try std.fs.path.join(gpa, &.{ base, ".config", "zzzbench", "config.toml" });
    defer gpa.free(path);
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound, error.AccessDenied => return &.{},
        else => return err,
    };
    defer gpa.free(text);
    return parseModelDirs(arena, text, options.home);
}

pub fn parseModelDirs(arena: std.mem.Allocator, text: []const u8, home: ?[]const u8) ![][]const u8 {
    const key_at = findKey(text, "model_dirs") orelse return &.{};
    const after_key = text[key_at + "model_dirs".len ..];
    const eq_at = std.mem.indexOfScalar(u8, after_key, '=') orelse return error.InvalidConfig;
    const after_eq = after_key[eq_at + 1 ..];
    const open_at = std.mem.indexOfScalar(u8, after_eq, '[') orelse return error.InvalidConfig;
    const close_at = std.mem.indexOfScalar(u8, after_eq[open_at + 1 ..], ']') orelse return error.InvalidConfig;
    const body = after_eq[open_at + 1 ..][0..close_at];

    var paths: std.ArrayListUnmanaged([]const u8) = .empty;
    defer paths.deinit(arena);
    var cursor: usize = 0;
    while (cursor < body.len) {
        while (cursor < body.len and (std.ascii.isWhitespace(body[cursor]) or body[cursor] == ',')) cursor += 1;
        if (cursor == body.len) break;
        // A comment between entries is legal TOML. Only a `#` outside
        // a string reaches here, since a quoted value is consumed
        // whole below.
        if (body[cursor] == '#') {
            cursor = std.mem.indexOfScalarPos(u8, body, cursor, '\n') orelse break;
            continue;
        }
        if (body[cursor] != '"') return error.InvalidConfig;
        cursor += 1;
        const end = std.mem.indexOfScalarPos(u8, body, cursor, '"') orelse return error.InvalidConfig;
        const raw = body[cursor..end];
        if (std.mem.indexOfScalar(u8, raw, '\\') != null) return error.InvalidConfig;
        const expanded = if (std.mem.eql(u8, raw, "~"))
            home orelse return error.HomeUnavailable
        else if (std.mem.startsWith(u8, raw, "~/")) blk: {
            const root = home orelse return error.HomeUnavailable;
            break :blk try std.fs.path.join(arena, &.{ root, raw[2..] });
        } else try arena.dupe(u8, raw);
        try paths.append(arena, expanded);
        cursor = end + 1;
    }
    return try paths.toOwnedSlice(arena);
}

/// Offset of `key` where it actually starts an assignment, skipping
/// commented lines. A config that documents the option above the real
/// one — `# model_dirs = ["/example"]` — is valid TOML, and a plain
/// substring search would parse the example instead.
fn findKey(text: []const u8, key: []const u8) ?usize {
    var lines = std.mem.splitScalar(u8, text, '\n');
    var offset: usize = 0;
    while (lines.next()) |line| {
        defer offset += line.len + 1;
        const trimmed = std.mem.trimStart(u8, line, " \t");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;
        if (!std.mem.startsWith(u8, trimmed, key)) continue;
        return offset + (line.len - trimmed.len);
    }
    return null;
}

/// Pick the model `wanted` names: an exact path, else an exact
/// display name, else a unique case-insensitive prefix.
///
/// Ambiguity is a miss, not a guess. `--model Example` with two
/// Example builds in the cache must not silently bench whichever
/// sorted first — a capture that picked the wrong model looks exactly
/// like one that picked the right one.
pub fn match(models: []const Model, wanted: []const u8) ?Model {
    for (models) |model| {
        if (std.mem.eql(u8, model.path, wanted)) return model;
    }
    // Different quantizations can share a derived name. Require an exact
    // path when more than one file has that display name.
    if (unique(models, wanted, exactName)) |model| return model;
    return unique(models, wanted, prefixName);
}

fn unique(
    models: []const Model,
    wanted: []const u8,
    pred: fn (Model, []const u8) bool,
) ?Model {
    var found: ?Model = null;
    for (models) |model| {
        if (!pred(model, wanted)) continue;
        if (found != null) return null;
        found = model;
    }
    return found;
}

fn exactName(model: Model, wanted: []const u8) bool {
    return std.ascii.eqlIgnoreCase(model.name, wanted);
}

fn prefixName(model: Model, wanted: []const u8) bool {
    if (model.name.len < wanted.len) return false;
    return std.ascii.eqlIgnoreCase(model.name[0..wanted.len], wanted);
}

/// Find the catalogued model that *is* the file `wanted` points at.
///
/// Byte-comparing paths is not enough: the catalogue stores the path it
/// walked, rooted at the workspace or the Hugging Face cache, so a
/// perfectly ordinary `--model models/foo.gguf` would miss.
/// Both sides are resolved, which also makes a symlink and its target
/// the same answer. Null when `wanted` is not a path to a catalogued
/// file — the caller then tries it as a name.
pub fn matchPath(gpa: std.mem.Allocator, io: std.Io, models: []const Model, wanted: []const u8) ?Model {
    const target = std.Io.Dir.cwd().realPathFileAlloc(io, wanted, gpa) catch return null;
    defer gpa.free(target);
    for (models) |model| {
        const candidate = std.Io.Dir.cwd().realPathFileAlloc(io, model.path, gpa) catch continue;
        defer gpa.free(candidate);
        if (std.mem.eql(u8, candidate, target)) return model;
    }
    return null;
}

test "an ambiguous --model is a miss rather than a guess" {
    const models = [_]Model{
        .{ .path = "/m/a.gguf", .name = "Example-0.8B", .quant = "Q4_K_M", .architecture = "qwen35", .parameter_count = 1, .size_bytes = 1, .source = .workspace },
        .{ .path = "/m/b.gguf", .name = "Example-27B", .quant = "Q4_0", .architecture = "qwen35", .parameter_count = 1, .size_bytes = 1, .source = .workspace },
        .{ .path = "/m/c.gguf", .name = "Sample-8B", .quant = "Q4_0", .architecture = "qwen3", .parameter_count = 1, .size_bytes = 1, .source = .huggingface },
    };
    // Exact path wins outright.
    try std.testing.expectEqualStrings("Sample-8B", match(&models, "/m/c.gguf").?.name);
    // Exact name, any case.
    try std.testing.expectEqualStrings("Sample-8B", match(&models, "sample-8b").?.name);
    // A unique prefix resolves.
    try std.testing.expectEqualStrings("Sample-8B", match(&models, "Samp").?.name);
    // A prefix matching two builds picks neither.
    try std.testing.expectEqual(@as(?Model, null), match(&models, "Example"));
    try std.testing.expectEqual(@as(?Model, null), match(&models, "nothing"));
}

test "two builds sharing a derived name are ambiguous, not first-wins" {
    // These synthetic quantizations both present as `Sample-0.6B`.
    const models = [_]Model{
        .{ .path = "/m/Sample-0.6B-Q4_0.gguf", .name = "Sample-0.6B", .quant = "Q4_0", .architecture = "qwen3", .parameter_count = 1, .size_bytes = 1, .source = .workspace },
        .{ .path = "/m/Sample-0.6B-Q8_0.gguf", .name = "Sample-0.6B", .quant = "Q8_0", .architecture = "qwen3", .parameter_count = 1, .size_bytes = 1, .source = .workspace },
    };
    try std.testing.expectEqual(@as(?Model, null), match(&models, "Sample-0.6B"));
    // The path is how you say which one you meant.
    try std.testing.expectEqualStrings(
        "/m/Sample-0.6B-Q8_0.gguf",
        match(&models, "/m/Sample-0.6B-Q8_0.gguf").?.path,
    );
}

pub fn writeTable(writer: *std.Io.Writer, models: []const Model) !void {
    try writer.writeAll("NAME                         QUANT    ARCH             PARAMS       SIZE       SOURCE\n");
    for (models) |model| {
        try writer.print("{s: <28} {s: <8} {s: <16} {d: >12} {Bi: >10.2}  {s}\n", .{
            model.name,
            model.quant,
            model.architecture,
            model.parameter_count,
            model.size_bytes,
            model.source.label(),
        });
        try writer.print("  {s}\n", .{model.path});
    }
}

pub fn writeJson(writer: *std.Io.Writer, models: []const Model) !void {
    var json: std.json.Stringify = .{ .writer = writer, .options = .{} };
    try json.beginArray();
    for (models) |model| {
        try json.write(model);
    }
    try json.endArray();
    try writer.writeByte('\n');
}

test "a commented-out sample does not become the config" {
    const paths = try parseModelDirs(std.testing.allocator,
        \\# zzzbench paths — uncomment and edit:
        \\# model_dirs = ["/example/one", "/example/two"]
        \\model_dirs = [
        \\  "/real/models",  # the one that counts
        \\]
    , null);
    defer std.testing.allocator.free(paths);
    defer for (paths) |path| std.testing.allocator.free(path);
    try std.testing.expectEqual(@as(usize, 1), paths.len);
    try std.testing.expectEqualStrings("/real/models", paths[0]);
}

test "a config with only a commented key reads as no configured dirs" {
    const paths = try parseModelDirs(std.testing.allocator,
        \\# model_dirs = ["/example"]
    , null);
    defer std.testing.allocator.free(paths);
    try std.testing.expectEqual(@as(usize, 0), paths.len);
}

test "config model_dirs expands home and accepts multiline arrays" {
    const paths = try parseModelDirs(std.testing.allocator,
        \\# zzzbench paths
        \\model_dirs = [
        \\  "~/models",
        \\  "/Volumes/models"
        \\]
    , "/Users/tester");
    defer std.testing.allocator.free(paths);
    defer for (paths) |path| std.testing.allocator.free(path);
    try std.testing.expectEqual(@as(usize, 2), paths.len);
    try std.testing.expectEqualStrings("/Users/tester/models", paths[0]);
    try std.testing.expectEqualStrings("/Volumes/models", paths[1]);
}

test "model JSON keeps scriptable metadata and the absolute path" {
    const models = [_]Model{.{
        .path = "/models/qwen.gguf",
        .name = "Qwen",
        .quant = "Q4_0",
        .architecture = "qwen3",
        .parameter_count = 600_000_000,
        .size_bytes = 400_000_000,
        .source = .workspace,
    }};
    var buf: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try writeJson(&writer, &models);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "\"path\":\"/models/qwen.gguf\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "\"parameter_count\":600000000") != null);
}
