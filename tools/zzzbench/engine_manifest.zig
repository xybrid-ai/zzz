//! Declarative engine manifests and command resolution.

const std = @import("std");

pub const schema_version: u32 = 1;
pub const manifest_bytes_max: usize = 64 * 1024;
pub const argument_count_max: usize = 32;
pub const environment_count_max: usize = 16;
pub const command_bytes_max: usize = 8 * 1024;

pub const Parser = enum {
    zzz_binary,
    llama_bench_json,
    json_object,

    pub fn label(self: Parser) []const u8 {
        return switch (self) {
            .zzz_binary => "zzz-binary",
            .llama_bench_json => "llama-bench-json",
            .json_object => "json-object",
        };
    }

    fn fromText(text: []const u8) ?Parser {
        inline for (@typeInfo(Parser).@"enum".fields) |field| {
            const parser: Parser = @enumFromInt(field.value);
            if (std.mem.eql(u8, text, parser.label())) return parser;
        }
        return null;
    }
};

pub const Fidelity = enum {
    streaming,
    summary,

    fn fromText(text: []const u8) ?Fidelity {
        return std.meta.stringToEnum(Fidelity, text);
    }
};

pub const Platform = enum { host, android };

pub const EnvironmentEntry = struct {
    key: []const u8,
    value: []const u8,
};

pub const PlatformPaths = struct {
    host: ?[]const u8 = null,
    android: ?[]const u8 = null,

    pub fn get(self: PlatformPaths, platform: Platform) ?[]const u8 {
        return switch (platform) {
            .host => self.host,
            .android => self.android,
        };
    }
};

pub const PlatformEnvironment = struct {
    host: []const EnvironmentEntry = &.{},
    android: []const EnvironmentEntry = &.{},

    pub fn get(self: PlatformEnvironment, platform: Platform) []const EnvironmentEntry {
        return switch (platform) {
            .host => self.host,
            .android => self.android,
        };
    }
};

pub const Metrics = struct {
    prefill: ?[]const u8 = null,
    decode: ?[]const u8 = null,
};

pub const Manifest = struct {
    source: []const u8,
    id: []const u8,
    label: []const u8,
    parser: Parser,
    fidelity: Fidelity,
    bin: PlatformPaths,
    environment: PlatformEnvironment,
    argv: []const []const u8,
    argv_prompt: []const []const u8 = &.{},
    argv_kernel: []const []const u8 = &.{},
    metrics: Metrics = .{},

    pub fn available(self: Manifest, platform: Platform) bool {
        return self.bin.get(platform) != null;
    }
};

pub const Kind = enum {
    none,
    too_large,
    syntax,
    unknown_field,
    duplicate_field,
    missing_field,
    invalid_value,
    invalid_id,
    invalid_placeholder,
    too_many_arguments,
    too_many_environment_entries,
};

pub const Diagnostic = struct {
    source: []const u8 = "",
    field: []const u8 = "",
    line: u32 = 0,
    kind: Kind = .none,

    pub fn message(self: Diagnostic) []const u8 {
        return switch (self.kind) {
            .none => "no error",
            .too_large => "manifest exceeds 64 KiB",
            .syntax => "invalid constrained-TOML syntax",
            .unknown_field => "unknown field",
            .duplicate_field => "duplicate field",
            .missing_field => "missing required field",
            .invalid_value => "invalid field value",
            .invalid_id => "id must match [a-z0-9][a-z0-9_-]*",
            .invalid_placeholder => "unknown or misplaced placeholder",
            .too_many_arguments => "resolved argv exceeds 32 entries",
            .too_many_environment_entries => "environment exceeds 16 entries",
        };
    }
};

const Seen = struct {
    schema: bool = false,
    id: bool = false,
    label: bool = false,
    parser: bool = false,
    fidelity: bool = false,
    bin_host: bool = false,
    bin_android: bool = false,
    env_host: bool = false,
    env_android: bool = false,
    argv: bool = false,
    argv_prompt: bool = false,
    argv_kernel: bool = false,
    metrics_prefill: bool = false,
    metrics_decode: bool = false,
};

const Builder = struct {
    schema: ?u32 = null,
    id: ?[]const u8 = null,
    label: ?[]const u8 = null,
    parser: ?Parser = null,
    fidelity: ?Fidelity = null,
    bin: PlatformPaths = .{},
    environment: PlatformEnvironment = .{},
    argv: ?[]const []const u8 = null,
    argv_prompt: []const []const u8 = &.{},
    argv_kernel: []const []const u8 = &.{},
    metrics: Metrics = .{},
    seen: Seen = .{},
};

const Scanner = struct {
    arena: std.mem.Allocator,
    source: []const u8,
    text: []const u8,
    diagnostic: *Diagnostic,
    index: usize = 0,
    line: u32 = 1,

    fn fail(
        self: *Scanner,
        kind: Kind,
        field: []const u8,
    ) error{ OutOfMemory, InvalidManifest } {
        self.diagnostic.* = .{
            .source = self.source,
            .field = try self.arena.dupe(u8, field),
            .line = self.line,
            .kind = kind,
        };
        return error.InvalidManifest;
    }

    fn skipSpaceAndComments(self: *Scanner) void {
        while (self.index < self.text.len) {
            const byte = self.text[self.index];
            if (byte == '#') {
                while (self.index < self.text.len and self.text[self.index] != '\n') {
                    self.index += 1;
                }
            } else if (std.ascii.isWhitespace(byte)) {
                if (byte == '\n') self.line += 1;
                self.index += 1;
            } else {
                return;
            }
        }
    }

    fn skipHorizontal(self: *Scanner) void {
        while (self.index < self.text.len) {
            const byte = self.text[self.index];
            if (byte != ' ' and byte != '\t' and byte != '\r') return;
            self.index += 1;
        }
    }

    fn finishAssignment(self: *Scanner, field: []const u8) !void {
        self.skipHorizontal();
        if (self.index < self.text.len and self.text[self.index] == '#') {
            while (self.index < self.text.len and self.text[self.index] != '\n') {
                self.index += 1;
            }
        }
        if (self.index == self.text.len) return;
        if (self.text[self.index] != '\n') return self.fail(.syntax, field);
        self.index += 1;
        self.line += 1;
    }

    fn parseKey(self: *Scanner) ![]const u8 {
        const start = self.index;
        while (self.index < self.text.len) {
            const byte = self.text[self.index];
            if (!isKeyByte(byte)) break;
            self.index += 1;
        }
        if (self.index == start) return self.fail(.syntax, "");
        return self.text[start..self.index];
    }

    fn expect(self: *Scanner, byte: u8, field: []const u8) !void {
        self.skipHorizontal();
        if (self.index == self.text.len) return self.fail(.syntax, field);
        if (self.text[self.index] != byte) return self.fail(.syntax, field);
        self.index += 1;
    }

    fn parseInteger(self: *Scanner, field: []const u8) !u32 {
        self.skipHorizontal();
        const start = self.index;
        while (self.index < self.text.len and std.ascii.isDigit(self.text[self.index])) {
            self.index += 1;
        }
        if (self.index == start) return self.fail(.invalid_value, field);
        return std.fmt.parseInt(u32, self.text[start..self.index], 10) catch
            return self.fail(.invalid_value, field);
    }

    fn parseString(self: *Scanner, field: []const u8) ![]const u8 {
        self.skipHorizontal();
        if (self.index == self.text.len) return self.fail(.syntax, field);
        if (self.text[self.index] != '"') return self.fail(.invalid_value, field);
        self.index += 1;

        var bytes: std.ArrayListUnmanaged(u8) = .empty;
        while (self.index < self.text.len) {
            const byte = self.text[self.index];
            self.index += 1;
            if (byte == '"') return bytes.toOwnedSlice(self.arena);
            if (byte == '\n') return self.fail(.syntax, field);
            if (byte != '\\') {
                try bytes.append(self.arena, byte);
                continue;
            }
            if (self.index == self.text.len) return self.fail(.syntax, field);
            const escaped = self.text[self.index];
            self.index += 1;
            const decoded: u8 = switch (escaped) {
                '"' => '"',
                '\\' => '\\',
                'n' => '\n',
                'r' => '\r',
                't' => '\t',
                else => return self.fail(.invalid_value, field),
            };
            try bytes.append(self.arena, decoded);
        }
        return self.fail(.syntax, field);
    }

    fn parseStringArray(self: *Scanner, field: []const u8) ![]const []const u8 {
        try self.expect('[', field);
        var values: std.ArrayListUnmanaged([]const u8) = .empty;
        while (true) {
            self.skipSpaceAndComments();
            if (self.index == self.text.len) return self.fail(.syntax, field);
            if (self.text[self.index] == ']') {
                self.index += 1;
                return values.toOwnedSlice(self.arena);
            }
            if (values.items.len >= argument_count_max) {
                return self.fail(.too_many_arguments, field);
            }
            try values.append(self.arena, try self.parseString(field));
            self.skipSpaceAndComments();
            if (self.index == self.text.len) return self.fail(.syntax, field);
            if (self.text[self.index] == ']') continue;
            if (self.text[self.index] != ',') return self.fail(.syntax, field);
            self.index += 1;
        }
    }

    fn parseEnvironment(self: *Scanner, field: []const u8) ![]const EnvironmentEntry {
        try self.expect('{', field);
        var entries: std.ArrayListUnmanaged(EnvironmentEntry) = .empty;
        while (true) {
            self.skipSpaceAndComments();
            if (self.index == self.text.len) return self.fail(.syntax, field);
            if (self.text[self.index] == '}') {
                self.index += 1;
                return entries.toOwnedSlice(self.arena);
            }
            if (entries.items.len >= environment_count_max) {
                return self.fail(.too_many_environment_entries, field);
            }
            const key = try self.parseKey();
            if (!validEnvironmentKey(key)) return self.fail(.invalid_value, field);
            for (entries.items) |entry| {
                if (std.mem.eql(u8, entry.key, key)) return self.fail(.duplicate_field, field);
            }
            try self.expect('=', field);
            const value = try self.parseString(field);
            try entries.append(self.arena, .{
                .key = try self.arena.dupe(u8, key),
                .value = value,
            });
            self.skipSpaceAndComments();
            if (self.index == self.text.len) return self.fail(.syntax, field);
            if (self.text[self.index] == '}') continue;
            if (self.text[self.index] != ',') return self.fail(.syntax, field);
            self.index += 1;
        }
    }
};

pub fn parse(
    arena: std.mem.Allocator,
    source: []const u8,
    text: []const u8,
    diagnostic: *Diagnostic,
) !Manifest {
    diagnostic.* = .{};
    const owned_source = try arena.dupe(u8, source);
    if (text.len > manifest_bytes_max) {
        diagnostic.* = .{ .source = owned_source, .line = 1, .kind = .too_large };
        return error.InvalidManifest;
    }

    var scanner: Scanner = .{
        .arena = arena,
        .source = owned_source,
        .text = text,
        .diagnostic = diagnostic,
    };
    var builder: Builder = .{};
    while (true) {
        scanner.skipSpaceAndComments();
        if (scanner.index == text.len) break;
        const field = try scanner.parseKey();
        try scanner.expect('=', field);
        try parseField(&scanner, &builder, field);
        try scanner.finishAssignment(field);
    }
    return finish(&scanner, builder);
}

fn parseField(scanner: *Scanner, builder: *Builder, field: []const u8) !void {
    if (std.mem.eql(u8, field, "schema")) {
        try first(scanner, &builder.seen.schema, field);
        builder.schema = try scanner.parseInteger(field);
    } else if (std.mem.eql(u8, field, "id")) {
        try first(scanner, &builder.seen.id, field);
        builder.id = try scanner.parseString(field);
    } else if (std.mem.eql(u8, field, "label")) {
        try first(scanner, &builder.seen.label, field);
        builder.label = try scanner.parseString(field);
    } else if (std.mem.eql(u8, field, "parser")) {
        try first(scanner, &builder.seen.parser, field);
        const value = try scanner.parseString(field);
        builder.parser = Parser.fromText(value) orelse
            return scanner.fail(.invalid_value, field);
    } else if (std.mem.eql(u8, field, "fidelity")) {
        try first(scanner, &builder.seen.fidelity, field);
        const value = try scanner.parseString(field);
        builder.fidelity = Fidelity.fromText(value) orelse
            return scanner.fail(.invalid_value, field);
    } else if (std.mem.eql(u8, field, "bin.host")) {
        try first(scanner, &builder.seen.bin_host, field);
        builder.bin.host = try scanner.parseString(field);
    } else if (std.mem.eql(u8, field, "bin.android")) {
        try first(scanner, &builder.seen.bin_android, field);
        builder.bin.android = try scanner.parseString(field);
    } else if (std.mem.eql(u8, field, "env.host")) {
        try first(scanner, &builder.seen.env_host, field);
        builder.environment.host = try scanner.parseEnvironment(field);
    } else if (std.mem.eql(u8, field, "env.android")) {
        try first(scanner, &builder.seen.env_android, field);
        builder.environment.android = try scanner.parseEnvironment(field);
    } else if (std.mem.eql(u8, field, "argv")) {
        try first(scanner, &builder.seen.argv, field);
        builder.argv = try scanner.parseStringArray(field);
    } else if (std.mem.eql(u8, field, "argv_prompt")) {
        try first(scanner, &builder.seen.argv_prompt, field);
        builder.argv_prompt = try scanner.parseStringArray(field);
    } else if (std.mem.eql(u8, field, "argv_kernel")) {
        try first(scanner, &builder.seen.argv_kernel, field);
        builder.argv_kernel = try scanner.parseStringArray(field);
    } else if (std.mem.eql(u8, field, "metrics.prefill")) {
        try first(scanner, &builder.seen.metrics_prefill, field);
        builder.metrics.prefill = try scanner.parseString(field);
    } else if (std.mem.eql(u8, field, "metrics.decode")) {
        try first(scanner, &builder.seen.metrics_decode, field);
        builder.metrics.decode = try scanner.parseString(field);
    } else {
        return scanner.fail(.unknown_field, field);
    }
}

fn first(scanner: *Scanner, seen: *bool, field: []const u8) !void {
    if (seen.*) return scanner.fail(.duplicate_field, field);
    seen.* = true;
}

fn finish(scanner: *Scanner, builder: Builder) !Manifest {
    if (builder.schema == null) return scanner.fail(.missing_field, "schema");
    if (builder.schema.? != schema_version) return scanner.fail(.invalid_value, "schema");
    const id = builder.id orelse return scanner.fail(.missing_field, "id");
    if (!validID(id)) return scanner.fail(.invalid_id, "id");
    const label = builder.label orelse return scanner.fail(.missing_field, "label");
    if (label.len == 0 or label.len > 64) return scanner.fail(.invalid_value, "label");
    const parser = builder.parser orelse return scanner.fail(.missing_field, "parser");
    const fidelity = builder.fidelity orelse return scanner.fail(.missing_field, "fidelity");
    if (builder.bin.host == null and builder.bin.android == null) {
        return scanner.fail(.missing_field, "bin.host|bin.android");
    }
    if (builder.bin.host) |path| try validateBinTemplate(scanner, "bin.host", path);
    if (builder.bin.android) |path| try validateBinTemplate(scanner, "bin.android", path);
    const argv = builder.argv orelse return scanner.fail(.missing_field, "argv");
    if (argv.len == 0) return scanner.fail(.invalid_value, "argv");
    if (!std.mem.eql(u8, argv[0], "{bin}")) {
        return scanner.fail(.invalid_placeholder, "argv[0]");
    }
    if (parser == .zzz_binary and fidelity != .streaming) {
        return scanner.fail(.invalid_value, "fidelity");
    }
    if (parser != .zzz_binary and fidelity != .summary) {
        return scanner.fail(.invalid_value, "fidelity");
    }
    if (parser == .json_object) {
        if (builder.metrics.prefill == null) {
            return scanner.fail(.missing_field, "metrics.prefill");
        }
        if (builder.metrics.decode == null) {
            return scanner.fail(.missing_field, "metrics.decode");
        }
    }
    try validateTemplates(scanner, "argv", argv);
    try validateTemplates(scanner, "argv_prompt", builder.argv_prompt);
    try validateTemplates(scanner, "argv_kernel", builder.argv_kernel);
    try validateEnvironment(scanner, "env.host", builder.environment.host);
    try validateEnvironment(scanner, "env.android", builder.environment.android);
    return .{
        .source = scanner.source,
        .id = id,
        .label = label,
        .parser = parser,
        .fidelity = fidelity,
        .bin = builder.bin,
        .environment = builder.environment,
        .argv = argv,
        .argv_prompt = builder.argv_prompt,
        .argv_kernel = builder.argv_kernel,
        .metrics = builder.metrics,
    };
}

fn validateBinTemplate(scanner: *Scanner, field: []const u8, template: []const u8) !void {
    var index: usize = 0;
    while (std.mem.indexOfScalarPos(u8, template, index, '{')) |open| {
        const close = std.mem.indexOfScalarPos(u8, template, open + 1, '}') orelse
            return scanner.fail(.invalid_placeholder, field);
        if (!std.mem.eql(u8, template[open + 1 .. close], "workspace")) {
            return scanner.fail(.invalid_placeholder, field);
        }
        index = close + 1;
    }
    if (std.mem.indexOfScalarPos(u8, template, index, '}') != null) {
        return scanner.fail(.invalid_placeholder, field);
    }
}

fn validateEnvironment(
    scanner: *Scanner,
    field: []const u8,
    entries: []const EnvironmentEntry,
) !void {
    for (entries) |entry| try validateTemplates(scanner, field, &.{entry.value});
}

fn validateTemplates(scanner: *Scanner, field: []const u8, templates: []const []const u8) !void {
    for (templates) |template| {
        var index: usize = 0;
        while (std.mem.indexOfScalarPos(u8, template, index, '{')) |open| {
            const close = std.mem.indexOfScalarPos(u8, template, open + 1, '}') orelse
                return scanner.fail(.invalid_placeholder, field);
            if (!validPlaceholder(template[open + 1 .. close])) {
                return scanner.fail(.invalid_placeholder, field);
            }
            index = close + 1;
        }
        if (std.mem.indexOfScalarPos(u8, template, index, '}') != null) {
            return scanner.fail(.invalid_placeholder, field);
        }
    }
}

fn validPlaceholder(name: []const u8) bool {
    const names = [_][]const u8{
        "bin",        "model",  "threads", "n_prompt",
        "n_generate", "prompt", "kernel",  "workspace",
    };
    for (names) |known| {
        if (std.mem.eql(u8, name, known)) return true;
    }
    return false;
}

fn validID(id: []const u8) bool {
    if (id.len == 0 or id.len > 32) return false;
    if (!std.ascii.isLower(id[0]) and !std.ascii.isDigit(id[0])) return false;
    for (id[1..]) |byte| {
        if (std.ascii.isLower(byte) or std.ascii.isDigit(byte)) continue;
        if (byte == '_' or byte == '-') continue;
        return false;
    }
    return true;
}

fn isKeyByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '-' or byte == '.';
}

fn validEnvironmentKey(key: []const u8) bool {
    if (key.len == 0) return false;
    if (!std.ascii.isAlphabetic(key[0]) and key[0] != '_') return false;
    for (key[1..]) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '_') continue;
        return false;
    }
    return true;
}

test "a version-one manifest parses multiline argv and platform environment" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diagnostic: Diagnostic = .{};

    const manifest = try parse(arena, "fixture.toml",
        \\schema = 1
        \\id = "llamacpp"
        \\label = "llama.cpp"
        \\parser = "llama-bench-json"
        \\fidelity = "summary"
        \\bin.host = "~/llama.cpp/llama-bench"
        \\bin.android = "/data/local/tmp/llama.cpp/llama-bench"
        \\env.android = { LD_LIBRARY_PATH = "/data/local/tmp/llama.cpp" }
        \\argv = [
        \\  "{bin}", "-m", "{model}",
        \\  "-p", "{n_prompt}", "-n", "{n_generate}",
        \\  "-t", "{threads}", "-r", "1", "-o", "json",
        \\]
    , &diagnostic);

    try std.testing.expectEqualStrings("llamacpp", manifest.id);
    try std.testing.expectEqual(Parser.llama_bench_json, manifest.parser);
    try std.testing.expectEqual(Fidelity.summary, manifest.fidelity);
    try std.testing.expectEqual(@as(usize, 13), manifest.argv.len);
    try std.testing.expectEqualStrings(
        "/data/local/tmp/llama.cpp",
        manifest.environment.android[0].value,
    );
}

test "unknown and duplicate manifest fields fail at their source line" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diagnostic: Diagnostic = .{};

    try std.testing.expectError(error.InvalidManifest, parse(arena, "unknown.toml",
        \\schema = 1
        \\id = "zzz"
        \\surprise = "no"
    , &diagnostic));
    try std.testing.expectEqual(Kind.unknown_field, diagnostic.kind);
    try std.testing.expectEqual(@as(u32, 3), diagnostic.line);
    try std.testing.expectEqualStrings("surprise", diagnostic.field);

    diagnostic = .{};
    try std.testing.expectError(error.InvalidManifest, parse(arena, "duplicate.toml",
        \\schema = 1
        \\id = "zzz"
        \\id = "again"
    , &diagnostic));
    try std.testing.expectEqual(Kind.duplicate_field, diagnostic.kind);
    try std.testing.expectEqual(@as(u32, 3), diagnostic.line);
    try std.testing.expectEqualStrings("id", diagnostic.field);
}

test "unknown placeholders fail during manifest validation" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var diagnostic: Diagnostic = .{};

    try std.testing.expectError(error.InvalidManifest, parse(
        arena_state.allocator(),
        "placeholder.toml",
        \\schema = 1
        \\id = "broken"
        \\label = "Broken"
        \\parser = "json-object"
        \\fidelity = "summary"
        \\bin.host = "{shell}/broken"
        \\metrics.prefill = "prefill"
        \\metrics.decode = "decode"
        \\argv = ["{bin}", "{model}"]
    ,
        &diagnostic,
    ));
    try std.testing.expectEqual(Kind.invalid_placeholder, diagnostic.kind);
    try std.testing.expectEqualStrings("bin.host", diagnostic.field);
}
