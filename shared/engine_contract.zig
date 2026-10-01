//! Versioned zzz executable interface; deliberately contains no inference code.
const std = @import("std");
const builtin = @import("builtin");
pub const version = 1;

/// Where a supplied engine must run natively. `bench-info` reports its build
/// target as `<arch>-<os>-<abi>`; the arch and OS have to match. An
/// `x86_64-macos` engine runs on Apple Silicon under Rosetta and would pass
/// every other check while measuring translated code.
pub const Platform = struct {
    arch: []const u8,
    os: []const u8,

    /// The machine the checking tool itself was built for.
    pub const native: Platform = .{ .arch = @tagName(builtin.cpu.arch), .os = @tagName(builtin.os.tag) };
    /// What Android bootstrap stages onto the phone.
    pub const android: Platform = .{ .arch = "aarch64", .os = "linux" };
};

/// The `target` string a native engine reports, in `bench-info`'s format.
pub const native_target = @tagName(builtin.cpu.arch) ++ "-" ++ @tagName(builtin.os.tag) ++ "-" ++ @tagName(builtin.abi);

/// `bench-info` only prints a build-time constant. A binary still running after
/// this long is not a zzz engine (a server, a prompt, a hung launch), and an
/// unbounded wait would freeze the TUI thread or keep the probe from binding.
/// Generous so a first launch through macOS's code-signing check still fits.
pub const info_timeout_s = 10;

pub const Options = struct {
    threads: u32 = 4,
    n_prompt: u32 = 16,
    n_generate: u32 = 32,
    prompt: []const u8 = "",
    kernel: []const u8 = "",
    want_text: bool = false,
};

/// Initialize in place: argv borrows the number buffers inside this struct.
pub const Command = struct {
    arguments: [17][]const u8,
    count: usize,
    numbers: [3][16]u8,

    pub fn init(self: *Command, bin: []const u8, model: []const u8, options: Options) !void {
        if (bin.len == 0 or model.len == 0) return error.MissingEngineOrModel;
        if (options.threads == 0 or options.n_prompt == 0 or options.n_generate == 0) {
            return error.InvalidBenchmarkPolicy;
        }
        self.arguments[0..12].* = .{
            bin,         "bench-run",                                                       model,              "--protocol",                                                       "1",               "--report-binary",
            "--threads", try std.fmt.bufPrint(&self.numbers[0], "{d}", .{options.threads}), "--prefill-tokens", try std.fmt.bufPrint(&self.numbers[1], "{d}", .{options.n_prompt}), "--decode-tokens", try std.fmt.bufPrint(&self.numbers[2], "{d}", .{options.n_generate}),
        };
        self.count = 12;
        if (options.kernel.len > 0) {
            self.arguments[self.count..][0..2].* = .{ "--kernel", options.kernel };
            self.count += 2;
        }
        if (options.prompt.len > 0) {
            self.arguments[self.count..][0..2].* = .{ "--prompt", options.prompt };
            self.count += 2;
            if (options.want_text) {
                self.arguments[self.count] = "--emit-text";
                self.count += 1;
            }
        }
    }

    pub fn argv(self: *const Command) []const []const u8 {
        return self.arguments[0..self.count];
    }
};

pub fn validateInfo(allocator: std.mem.Allocator, bytes: []const u8, expected: Platform) !void {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidEngineInfo;
    const info = parsed.value.object;
    const protocol = info.get("benchmark_protocol") orelse return error.InvalidEngineInfo;
    if (protocol != .integer or protocol.integer != version) return error.IncompatibleEngineProtocol;
    for ([_][2][]const u8{ .{ "engine", "zzz" }, .{ "command", "bench-run" }, .{ "backend", "cpu" } }) |field| {
        const value = info.get(field[0]) orelse return error.InvalidEngineInfo;
        if (value != .string or !std.mem.eql(u8, value.string, field[1])) return error.InvalidEngineInfo;
    }
    const target = info.get("target") orelse return error.InvalidEngineInfo;
    if (target != .string) return error.InvalidEngineInfo;
    var parts = std.mem.splitScalar(u8, target.string, '-');
    const arch = parts.first();
    const os = parts.next() orelse return error.InvalidEngineInfo;
    if (!std.mem.eql(u8, arch, expected.arch) or !std.mem.eql(u8, os, expected.os)) {
        return error.EngineTargetMismatch;
    }
}

/// Run a `bench-info` query and return its stdout, owned by the caller.
/// `argv` is the engine itself for a local check, or an `adb shell` wrapper
/// for one on a phone. Bounded by `info_timeout_s`; the child is killed on
/// expiry.
pub fn queryInfo(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8) ![]u8 {
    return queryInfoWithin(allocator, io, argv, info_timeout_s * std.time.ms_per_s);
}

fn queryInfoWithin(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8, timeout_ms: i64) ![]u8 {
    const timeout: std.Io.Timeout = .{ .duration = .{ .raw = .fromMilliseconds(timeout_ms), .clock = .awake } };
    const result = std.process.run(allocator, io, .{
        .argv = argv,
        .stdout_limit = .limited(16 * 1024),
        .stderr_limit = .limited(16 * 1024),
        // A deadline, not a duration: `run` applies the timeout per read, so
        // a duration would restart on every byte a trickling child writes.
        .timeout = timeout.toDeadline(io),
    }) catch |err| return switch (err) {
        error.Timeout => error.EngineInfoTimeout,
        else => err,
    };
    allocator.free(result.stderr);
    errdefer allocator.free(result.stdout);
    if (result.term != .exited or result.term.exited != 0) return error.EngineInfoFailed;
    return result.stdout;
}

/// Identity check for an engine that runs on this machine.
pub fn check(allocator: std.mem.Allocator, io: std.Io, bin: []const u8) !void {
    try std.Io.Dir.cwd().access(io, bin, .{ .execute = true });
    const stdout = try queryInfo(allocator, io, &.{ bin, "bench-info" });
    defer allocator.free(stdout);
    try validateInfo(allocator, stdout, .native);
}

test "contract command keeps text and paths as single arguments" {
    var command: Command = undefined;
    try command.init("/a b/zzz", "/models/a b.gguf", .{
        .threads = 8,
        .prompt = "Hello; $world",
        .want_text = true,
        .kernel = "scalar",
    });
    try std.testing.expectEqual(@as(usize, 17), command.argv().len);
    try std.testing.expectEqualStrings("bench-run", command.argv()[1]);
    try std.testing.expectEqualStrings("Hello; $world", command.argv()[15]);
    try std.testing.expectEqualStrings("8", command.argv()[7]);
}

fn testInfo(comptime target: []const u8) []const u8 {
    return "{\"engine\":\"zzz\",\"benchmark_protocol\":1,\"command\":\"bench-run\",\"backend\":\"cpu\",\"target\":\"" ++ target ++ "\"}";
}

test "contract rejects missing and incompatible protocol identities" {
    const gpa = std.testing.allocator;
    try validateInfo(gpa, testInfo(native_target), .native);
    try std.testing.expectError(error.InvalidEngineInfo, validateInfo(gpa, "{}", .native));
    try std.testing.expectError(error.IncompatibleEngineProtocol, validateInfo(gpa, "{\"benchmark_protocol\":2}", .native));
    // v1 engines always report a target; one without it is not a v1 engine.
    const untargeted = "{\"engine\":\"zzz\",\"benchmark_protocol\":1,\"command\":\"bench-run\",\"backend\":\"cpu\"}";
    try std.testing.expectError(error.InvalidEngineInfo, validateInfo(gpa, untargeted, .native));
}

test "contract rejects an engine built for another architecture or OS" {
    const gpa = std.testing.allocator;
    const apple: Platform = .{ .arch = "aarch64", .os = "macos" };
    try validateInfo(gpa, testInfo("aarch64-macos-none"), apple);
    // The Rosetta case: runs fine, measures translated code.
    try std.testing.expectError(error.EngineTargetMismatch, validateInfo(gpa, testInfo("x86_64-macos-none"), apple));
    try std.testing.expectError(error.EngineTargetMismatch, validateInfo(gpa, testInfo("aarch64-linux-android"), apple));
    try validateInfo(gpa, testInfo("aarch64-linux-android"), .android);
    try std.testing.expectError(error.EngineTargetMismatch, validateInfo(gpa, testInfo("aarch64-macos-none"), .android));
    try std.testing.expectError(error.InvalidEngineInfo, validateInfo(gpa, testInfo("aarch64"), apple));
}

test "a bench-info query that never exits is killed at the deadline" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(io, "server", .{ .permissions = .fromMode(0o755) });
    try file.writeStreamingAll(io, "#!/bin/sh\nexec sleep 30\n");
    file.close(io);
    const path = try tmp.dir.realPathFileAlloc(io, "server", std.testing.allocator);
    defer std.testing.allocator.free(path);
    const started = std.Io.Clock.awake.now(io);
    try std.testing.expectError(
        error.EngineInfoTimeout,
        queryInfoWithin(std.testing.allocator, io, &.{ path, "bench-info" }, 200),
    );
    // Well short of the 30 s sleep: the wait ended at the deadline.
    try std.testing.expect(started.durationTo(std.Io.Clock.awake.now(io)).toSeconds() < 10);
}
