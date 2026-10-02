//! Repository rules that neither the compiler nor `zig fmt` enforces.
//!
//! Zig compiles lazily, so a file nothing imports, or a test file no test
//! root lists, is silently skipped rather than reported. These tests make
//! both visible and check that documented build steps exist. `zig build test`
//! runs them from the repository root.

const std = @import("std");
const builtin = @import("builtin");
const options = @import("tidy_options");

const io = std.testing.io;

/// Where sources and public text live. Generated trees are skipped wherever
/// they appear, including inside `tests/consumer/`.
const scanned_dirs = [_][]const u8{ ".github", "docs", "runtime", "shared", "tests", "tools" };
const source_dirs = [_][]const u8{ "shared", "tools" };
const skipped_dirs = [_][]const u8{ ".git", ".zig-cache", "zig-out", "zig-pkg" };
const text_extensions = [_][]const u8{ ".zig", ".zon", ".md", ".yml", ".yaml", ".toml", ".json", ".sh", ".txt" };

test "the compiler matches the pinned .zigversion" {
    const pinned = try std.Io.Dir.cwd().readFileAlloc(io, ".zigversion", std.testing.allocator, .limited(64));
    defer std.testing.allocator.free(pinned);
    const want = std.mem.trim(u8, pinned, " \t\r\n");
    if (!std.mem.eql(u8, want, builtin.zig_version_string)) {
        std.debug.print("tidy: .zigversion pins Zig {s}; this compiler is {s}\n", .{ want, builtin.zig_version_string });
        return error.ZigVersionMismatch;
    }
}

test "every Zig file is reachable from a build root" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var reached: std.StringHashMapUnmanaged(void) = .empty;
    var queue: std.ArrayList([]const u8) = .empty;
    try queue.appendSlice(arena, options.roots);
    while (queue.pop()) |path| {
        if ((try reached.getOrPut(arena, path)).found_existing) continue;
        try queue.appendSlice(arena, try relativeImports(arena, path, try readText(arena, path)));
    }

    var unreachable_count: usize = 0;
    for (try listFiles(arena, &source_dirs, &.{".zig"})) |path| {
        if (reached.contains(path)) continue;
        std.debug.print("tidy: {s} is not imported from any build root; import or delete it\n", .{path});
        unreachable_count += 1;
    }
    if (unreachable_count > 0) return error.UnreachableSource;
}

test "every file with tests is listed by a test root" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // A test block runs only when its file belongs to the tested module and
    // is referenced from the test root, so registration is one import away.
    var registered: std.StringHashMapUnmanaged(void) = .empty;
    for (options.test_roots) |root| {
        try registered.put(arena, root, {});
        for (try relativeImports(arena, root, try readText(arena, root))) |path| {
            try registered.put(arena, path, {});
        }
    }

    var unlisted: usize = 0;
    for (try listFiles(arena, &source_dirs, &.{".zig"})) |path| {
        if (registered.contains(path) or !hasTests(try readText(arena, path))) continue;
        std.debug.print("tidy: tests in {s} never run; add it to tools/zzzbench/tests.zig or a test root\n", .{path});
        unlisted += 1;
    }
    if (unlisted > 0) return error.UnlistedTests;
}

test "documented build steps exist" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const command = "zig" ++ " build ";
    var missing: usize = 0;
    for (try textFiles(arena)) |path| {
        const text = try readText(arena, path);
        var cursor: usize = 0;
        while (std.mem.indexOfPos(u8, text, cursor, command)) |at| {
            const start = at + command.len;
            var end = start;
            while (end < text.len and isStepChar(text[end])) end += 1;
            cursor = end;
            // Options (`-D...`) and prose continue the default install step.
            const step = text[start..end];
            if (step.len == 0 or !std.ascii.isLower(step[0])) continue;
            if (isStep(step)) continue;
            std.debug.print("tidy: {s}:{d}: `zig build {s}` is not a build step\n", .{ path, lineOf(text, at), step });
            missing += 1;
        }
    }
    if (missing > 0) return error.UnknownBuildStep;
}

fn isStep(name: []const u8) bool {
    for (options.steps) |step| {
        if (std.mem.eql(u8, step, name)) return true;
    }
    return false;
}

fn isStepChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-' or c == '_';
}

fn hasTests(source: []const u8) bool {
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        const code = std.mem.trimStart(u8, line, " \t");
        if (std.mem.startsWith(u8, code, "test \"") or std.mem.startsWith(u8, code, "test {")) return true;
    }
    return false;
}

/// Repository-relative paths of the `.zig` files `from` imports by path.
fn relativeImports(arena: std.mem.Allocator, from: []const u8, source: []const u8) ![]const []const u8 {
    const marker = "@import(\"";
    var imports: std.ArrayList([]const u8) = .empty;
    var cursor: usize = 0;
    while (std.mem.indexOfPos(u8, source, cursor, marker)) |at| {
        const start = at + marker.len;
        const end = std.mem.indexOfScalarPos(u8, source, start, '"') orelse break;
        cursor = end;
        const target = source[start..end];
        if (!std.mem.endsWith(u8, target, ".zig")) continue;
        const dir = std.fs.path.dirnamePosix(from) orelse ".";
        try imports.append(arena, try std.fs.path.resolvePosix(arena, &.{ dir, target }));
    }
    return imports.items;
}

fn textFiles(arena: std.mem.Allocator) ![]const []const u8 {
    var files: std.ArrayList([]const u8) = .empty;
    try files.appendSlice(arena, try listFiles(arena, &scanned_dirs, &text_extensions));

    var root = try std.Io.Dir.cwd().openDir(io, ".", .{ .iterate = true });
    defer root.close(io);
    var entries = root.iterate();
    while (try entries.next(io)) |entry| {
        if (entry.kind != .file or !isText(entry.name)) continue;
        try files.append(arena, try arena.dupe(u8, entry.name));
    }
    return files.items;
}

fn isText(name: []const u8) bool {
    if (std.mem.eql(u8, name, ".zigversion")) return true;
    for (text_extensions) |extension| {
        if (std.mem.endsWith(u8, name, extension)) return true;
    }
    return false;
}

/// Files under `dirs` whose names end in one of `extensions`, as
/// repository-relative POSIX paths.
fn listFiles(arena: std.mem.Allocator, dirs: []const []const u8, extensions: []const []const u8) ![]const []const u8 {
    var files: std.ArrayList([]const u8) = .empty;
    for (dirs) |dir_path| {
        var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => |e| return e,
        };
        defer dir.close(io);
        var walker = try dir.walkSelectively(arena);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            switch (entry.kind) {
                .directory => if (!isSkipped(entry.basename)) try walker.enter(io, entry),
                .file => for (extensions) |extension| {
                    if (!std.mem.endsWith(u8, entry.basename, extension)) continue;
                    try files.append(arena, try std.fmt.allocPrint(arena, "{s}/{s}", .{ dir_path, entry.path }));
                    break;
                },
                else => {},
            }
        }
    }
    return files.items;
}

fn isSkipped(name: []const u8) bool {
    for (skipped_dirs) |skipped| {
        if (std.mem.eql(u8, name, skipped)) return true;
    }
    return false;
}

fn readText(arena: std.mem.Allocator, path: []const u8) ![]const u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(16 * 1024 * 1024));
}

fn lineOf(text: []const u8, offset: usize) usize {
    return std.mem.count(u8, text[0..offset], "\n") + 1;
}

test "tidy requires exact environment table entries with descriptions" {
    const source =
        \\// environ.get("ZZZBENCH_COMMENT")
        \\const a = environ.get (
        \\    "ZZZBENCH_FOO"
        \\);
        \\const b = std.c.getenv("CUSTOM_SETTING");
        \\const key = "ZZZBENCH_INDIRECT";
        \\const c = env.get(key);
        \\const d = env.getAlloc(allocator, "XDG_STATE_HOME");
    ;
    const docs =
        \\Example: `ZZZBENCH_FOO`
        \\| `ZZZBENCH_FOO_EXTRA` | Not the same variable |
        \\| `CUSTOM_SETTING` | |
        \\| `ZZZBENCH_INDIRECT` | Used by the app |
        \\| `XDG_STATE_HOME` | State directory |
    ;
    try std.testing.expectEqual(@as(usize, 2), try undocumentedEnvironmentCount(std.testing.allocator, source, docs, null));
    try std.testing.expectEqual(@as(usize, 0), try undocumentedEnvironmentCount(std.testing.allocator, source, docs ++ "\n| `ZZZBENCH_FOO` | Feature setting |\n| `CUSTOM_SETTING` | Custom setting |\n", null));
}

test "configuration environment variables are documented" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const docs = try readText(arena, "docs/installation.md");
    var violations: usize = 0;
    for (try applicationFiles(arena)) |path| {
        violations += try undocumentedEnvironmentCount(arena, try readText(arena, path), docs, path);
    }
    if (violations != 0) return error.UndocumentedEnvironmentVariable;
}

fn applicationFiles(arena: std.mem.Allocator) ![]const []const u8 {
    var files: std.ArrayList([]const u8) = .empty;
    for (try listFiles(arena, &source_dirs, &.{".zig"})) |path| {
        // Tidy's own fixtures deliberately contain undocumented keys.
        if (!std.mem.eql(u8, path, "tools/tidy.zig")) try files.append(arena, path);
    }
    try files.appendSlice(arena, &.{ "build.zig", "build_support.zig", "build.zig.zon" });
    return files.items;
}

fn documentedEnvironment(docs: []const u8, name: []const u8) bool {
    var lines = std.mem.splitScalar(u8, docs, '\n');
    while (lines.next()) |line| {
        var cells = std.mem.splitScalar(u8, std.mem.trim(u8, line, " \t\r"), '|');
        if (cells.first().len != 0) continue;
        const key = std.mem.trim(u8, cells.next() orelse continue, " \t");
        if (key.len != name.len + 2 or key[0] != '`' or key[key.len - 1] != '`') continue;
        if (!std.mem.eql(u8, key[1 .. key.len - 1], name)) continue;
        const description = std.mem.trim(u8, cells.next() orelse continue, " \t");
        if (description.len > 0) return true;
    }
    return false;
}

fn environmentName(name: []const u8) bool {
    if (name.len == 0 or !std.ascii.isUpper(name[0])) return false;
    for (name) |c| if (!std.ascii.isUpper(c) and !std.ascii.isDigit(c) and c != '_') return false;
    return true;
}

/// Recognize conventional environment receivers and fully qualified std APIs.
/// Other maps can use the same method names without defining configuration.
fn environmentReader(tokens: [5][]const u8) bool {
    if (!std.mem.eql(u8, tokens[3], ".")) return false;
    const receiver = tokens[2];
    const method = tokens[4];
    for ([_][]const u8{ "env", "environ", "environ_map" }) |name| {
        if (!std.mem.eql(u8, receiver, name)) continue;
        for ([_][]const u8{ "get", "getPosix", "getAlloc", "contains" }) |reader| {
            if (std.mem.eql(u8, method, reader)) return true;
        }
    }
    if (!std.mem.eql(u8, tokens[0], "std") or !std.mem.eql(u8, tokens[1], ".")) return false;
    if (std.mem.eql(u8, receiver, "c")) return std.mem.eql(u8, method, "getenv");
    if (!std.mem.eql(u8, receiver, "process")) return false;
    return std.mem.eql(u8, method, "getEnvVarOwned") or std.mem.eql(u8, method, "hasEnvVarConstant");
}

/// Prefix literals also catch keys passed via constants or helper functions.
/// This is a lexical guard, not data-flow analysis of computed variable names.
fn undocumentedEnvironmentCount(allocator: std.mem.Allocator, source: []const u8, docs: []const u8, path: ?[]const u8) !usize {
    const terminated = try allocator.dupeZ(u8, source);
    defer allocator.free(terminated);
    var tokenizer = std.zig.Tokenizer.init(terminated);
    var count: usize = 0;
    var previous: [5][]const u8 = @splat("");
    var in_reader = false;
    while (true) {
        const token = tokenizer.next();
        const text = source[token.loc.start..token.loc.end];
        switch (token.tag) {
            .eof => break,
            .doc_comment, .container_doc_comment => continue,
            .l_paren => in_reader = environmentReader(previous),
            .r_paren, .semicolon, .l_brace, .r_brace => in_reader = false,
            .string_literal => {
                const name = try std.zig.string_literal.parseAlloc(allocator, text);
                defer allocator.free(name);
                const prefixed = std.mem.startsWith(u8, name, "ZZZBENCH_") or std.mem.startsWith(u8, name, "XDG_");
                if ((prefixed or in_reader) and environmentName(name) and !documentedEnvironment(docs, name)) {
                    count += 1;
                    if (path) |p| std.debug.print("tidy: {s}:{d}: document {s} with a description in docs/installation.md's environment table\n", .{ p, lineOf(source, token.loc.start), name });
                }
            },
            else => {},
        }
        std.mem.copyForwards([]const u8, previous[0..4], previous[1..5]);
        previous[4] = text;
    }
    return count;
}

test "tidy distinguishes environment receivers from ordinary lookups" {
    const source =
        \\const a = headers.get("CONTENT_TYPE");
        \\const b = registry.get("BACKEND");
        \\const c = cache.getAlloc(allocator, "CACHE_KEY");
        \\const d = parser.getPosix("FORMAT");
        \\const e = api.getenv("SERVICE_NAME");
    ;
    try std.testing.expectEqual(@as(usize, 0), try undocumentedEnvironmentCount(std.testing.allocator, source, "", null));
    const environment =
        \\const a = environ.get("FIRST_SETTING");
        \\const b = init.environ_map . get // reader
        \\    ("SECOND_SETTING");
        \\const c = init.minimal.environ.getPosix("THIRD_SETTING");
        \\const d = env.getAlloc(allocator, "FOURTH_SETTING");
        \\const e = std.c.getenv("FIFTH_SETTING");
        \\const f = std.process.getEnvVarOwned(allocator, "SIXTH_SETTING");
    ;
    try std.testing.expectEqual(@as(usize, 6), try undocumentedEnvironmentCount(std.testing.allocator, environment, "", null));
}
