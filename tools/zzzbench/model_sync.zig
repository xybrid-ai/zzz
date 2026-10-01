//! Maps one selected host model onto every dashboard target. Android models
//! are content-addressed, checksum-verified, and recorded in a host cache;
//! host runs keep the original path. iOS/manual targets stay unsupported
//! until their transport can upload files safely.

const std = @import("std");

const bootstrap_android = @import("discovery/bootstrap_android.zig");
const catalog = @import("model_catalog.zig");
const device_picker = @import("device_picker.zig");

/// One entry per device the dashboard can drive, so this array and the
/// device selection can never disagree about the cap.
pub const max_targets: usize = device_picker.max_selected;

pub const Kind = enum { android, host, unsupported };

pub const Target = struct {
    kind: Kind,
    id: []const u8 = "",
};

pub const Prepared = struct {
    paths: [max_targets][]const u8 = @splat(""),
    len: usize = 0,
};

/// What sync is doing right now. Every step here blocks — a 500 MiB
/// push plus an on-device SHA-256 is tens of seconds — so the caller
/// gets one of these before each phase starts and repeatedly during
/// the upload, and paints a frame from it. Without that the screen
/// keeps the picker up and looks hung.
pub const Status = struct {
    pub const Phase = enum {
        scanning,
        hashing,
        checking,
        uploading,
        verifying,
        pointing,

        pub fn label(self: Phase) []const u8 {
            return switch (self) {
                .scanning => "scanning for models",
                .hashing => "hashing on this Mac",
                .checking => "checking the device",
                .uploading => "uploading to the device",
                .verifying => "verifying on the device",
                .pointing => "pointing the probe at it",
            };
        }
    };

    phase: Phase,
    model: []const u8 = "",
    /// The device this phase is for, when it is device-specific.
    device: []const u8 = "",
    done_bytes: u64 = 0,
    /// Zero when this phase has no measurable size at all; equal to
    /// `done_bytes`-less when the size is known but progress is not
    /// (an on-device `sha256sum` reports nothing until it returns).
    total_bytes: u64 = 0,
    /// Advances once per report so a phase with no measurable progress
    /// still visibly ticks.
    tick: usize = 0,

    /// Whole percent, or null when there is nothing honest to draw.
    pub fn percent(self: Status) ?u32 {
        if (self.total_bytes == 0 or self.done_bytes == 0) return null;
        return @intCast(@min(self.done_bytes * 100 / self.total_bytes, 100));
    }
};

test "percent is null until a phase has measurable progress" {
    try std.testing.expectEqual(@as(?u32, null), (Status{ .phase = .verifying }).percent());
    try std.testing.expectEqual(@as(?u32, null), (Status{
        .phase = .verifying,
        .total_bytes = 1024,
    }).percent());
    try std.testing.expectEqual(@as(?u32, 50), (Status{
        .phase = .uploading,
        .done_bytes = 512,
        .total_bytes = 1024,
    }).percent());
    // A stale, larger file already at the remote path must not make
    // the bar read 400%.
    try std.testing.expectEqual(@as(?u32, 100), (Status{
        .phase = .uploading,
        .done_bytes = 4096,
        .total_bytes = 1024,
    }).percent());
}

/// How sync paints. Type-erased so this module stays free of the UI —
/// it knows what it is doing, not how that looks.
pub const Reporter = struct {
    ctx: *anyopaque,
    paint: *const fn (ctx: *anyopaque, status: Status) void,

    pub fn report(self: Reporter, status: Status) void {
        self.paint(self.ctx, status);
    }
};

fn report(reporter: ?Reporter, status: Status) void {
    if (reporter) |r| r.report(status);
}

const CacheEntry = struct {
    serial: []const u8,
    sha256: []const u8,
    remote_path: []const u8,
    size_bytes: u64,
};

pub fn prepare(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    io: std.Io,
    workspace_path: []const u8,
    cache_root: []const u8,
    targets: []const Target,
    model: catalog.Model,
    reporter: ?Reporter,
) !Prepared {
    if (targets.len > max_targets) return error.TooManyDevices;
    var result: Prepared = .{ .len = targets.len };
    var digest: ?[32]u8 = null;
    for (targets, 0..) |target, index| {
        result.paths[index] = switch (target.kind) {
            .host => model.path,
            .unsupported => return error.ModelSelectionUnsupported,
            .android => blk: {
                // Hashed once for the whole selection, not per device:
                // it is the slowest local step on a multi-GB model.
                if (digest == null) digest = try localSha256(io, model, reporter);
                break :blk try prepareAndroid(
                    gpa,
                    arena,
                    io,
                    workspace_path,
                    cache_root,
                    target.id,
                    model,
                    digest.?,
                    reporter,
                );
            },
        };
    }
    return result;
}

fn prepareAndroid(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    io: std.Io,
    workspace_path: []const u8,
    cache_root: []const u8,
    serial: []const u8,
    model: catalog.Model,
    digest: [32]u8,
    reporter: ?Reporter,
) ![]const u8 {
    report(reporter, .{
        .phase = .checking,
        .model = model.name,
        .device = serial,
        .total_bytes = model.size_bytes,
    });
    var root_buf: [96]u8 = undefined;
    const workspace_root = bootstrap_android.remoteWorkspacePath(workspace_path, &root_buf);
    const name = safeBasename(std.fs.path.basename(model.path));
    const hex = std.fmt.bytesToHex(digest, .lower);
    // Content address goes in the directory, not the filename: the
    // probe derives its Hello model name from the basename, and a
    // `bd258782e35f-` prefix would ride all the way into the title bar
    // and every screencap.
    const remote_dir = try std.fmt.allocPrint(gpa, "{s}/models/{s}", .{ workspace_root, hex[0..12] });
    defer gpa.free(remote_dir);
    const remote_path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ remote_dir, name });
    try adbChecked(gpa, io, &.{ "adb", "-s", serial, "shell", "mkdir", "-p", remote_dir });

    const cache_path = try cachePath(gpa, cache_root);
    defer gpa.free(cache_path);
    var cache = try loadCache(gpa, io, cache_path);
    defer {
        for (cache.items) |entry| deinitEntry(gpa, entry);
        cache.deinit(gpa);
    }
    const digest_text = hex[0..64];
    const known = cacheContains(cache.items, serial, digest_text, remote_path, model.size_bytes);
    const remote_matches = if (known)
        (remoteSize(gpa, io, serial, remote_path) catch null) == model.size_bytes
    else blk: {
        const remote_digest = remoteSha256(gpa, io, serial, remote_path) catch break :blk false;
        break :blk std.mem.eql(u8, &digest, &remote_digest);
    };
    if (!remote_matches) {
        // No log line here: the sync screen already names the device,
        // the model, and the byte count, and a stderr write lands on
        // top of that frame.
        const upload = try std.fmt.allocPrint(gpa, "{s}.upload", .{remote_path});
        defer gpa.free(upload);
        try push(gpa, io, serial, model, upload, reporter);
        report(reporter, .{
            .phase = .verifying,
            .model = model.name,
            .device = serial,
            .total_bytes = model.size_bytes,
        });
        const uploaded = try remoteSha256(gpa, io, serial, upload);
        if (!std.mem.eql(u8, &digest, &uploaded)) return error.UploadChecksumMismatch;
        try adbChecked(gpa, io, &.{ "adb", "-s", serial, "shell", "mv", upload, remote_path });
    }
    try upsertCache(gpa, &cache, serial, digest_text, remote_path, model.size_bytes);
    try writeCache(gpa, io, cache_root, cache_path, cache.items);
    return remote_path;
}

fn safeBasename(name: []const u8) []const u8 {
    for (name) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '.' or c == '-' or c == '_')) return "model.gguf";
    }
    return name;
}

fn cachePath(gpa: std.mem.Allocator, cache_root: []const u8) ![]u8 {
    return std.fs.path.join(gpa, &.{ cache_root, "zzzbench", "pushed.json" });
}

fn loadCache(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !std.ArrayListUnmanaged(CacheEntry) {
    var entries: std.ArrayListUnmanaged(CacheEntry) = .empty;
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(4 * 1024 * 1024)) catch return entries;
    defer gpa.free(text);
    const parsed = std.json.parseFromSlice([]CacheEntry, gpa, text, .{ .ignore_unknown_fields = true }) catch return entries;
    defer parsed.deinit();
    for (parsed.value) |entry| {
        try entries.append(gpa, .{
            .serial = try gpa.dupe(u8, entry.serial),
            .sha256 = try gpa.dupe(u8, entry.sha256),
            .remote_path = try gpa.dupe(u8, entry.remote_path),
            .size_bytes = entry.size_bytes,
        });
    }
    return entries;
}

fn deinitEntry(gpa: std.mem.Allocator, entry: CacheEntry) void {
    gpa.free(entry.serial);
    gpa.free(entry.sha256);
    gpa.free(entry.remote_path);
}

fn cacheContains(entries: []const CacheEntry, serial: []const u8, sha: []const u8, path: []const u8, size: u64) bool {
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.serial, serial) and
            std.mem.eql(u8, entry.sha256, sha) and
            std.mem.eql(u8, entry.remote_path, path) and
            entry.size_bytes == size) return true;
    }
    return false;
}

fn upsertCache(
    gpa: std.mem.Allocator,
    entries: *std.ArrayListUnmanaged(CacheEntry),
    serial: []const u8,
    sha: []const u8,
    path: []const u8,
    size: u64,
) !void {
    for (entries.items) |*entry| {
        if (!std.mem.eql(u8, entry.serial, serial) or !std.mem.eql(u8, entry.remote_path, path)) continue;
        gpa.free(entry.sha256);
        entry.sha256 = try gpa.dupe(u8, sha);
        entry.size_bytes = size;
        return;
    }
    try entries.append(gpa, .{
        .serial = try gpa.dupe(u8, serial),
        .sha256 = try gpa.dupe(u8, sha),
        .remote_path = try gpa.dupe(u8, path),
        .size_bytes = size,
    });
}

fn writeCache(
    gpa: std.mem.Allocator,
    io: std.Io,
    cache_root: []const u8,
    path: []const u8,
    entries: []const CacheEntry,
) !void {
    const dir_path = try std.fs.path.join(gpa, &.{ cache_root, "zzzbench" });
    defer gpa.free(dir_path);
    try std.Io.Dir.cwd().createDirPath(io, dir_path);
    var output: std.Io.Writer.Allocating = .init(gpa);
    defer output.deinit();
    var json: std.json.Stringify = .{ .writer = &output.writer, .options = .{ .whitespace = .indent_2 } };
    try json.write(entries);
    try output.writer.writeByte('\n');
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = output.written() });
}

fn remoteSize(gpa: std.mem.Allocator, io: std.Io, serial: []const u8, path: []const u8) !u64 {
    const result = try std.process.run(gpa, io, .{
        .argv = &.{ "adb", "-s", serial, "shell", "stat", "-c", "%s", path },
        .stdout_limit = .limited(1024),
        .stderr_limit = .limited(1024),
    });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) return error.RemoteStatFailed;
    return std.fmt.parseInt(u64, std.mem.trim(u8, result.stdout, " \t\r\n"), 10);
}

fn localSha256(io: std.Io, model: catalog.Model, reporter: ?Reporter) ![32]u8 {
    const file = try std.Io.Dir.cwd().openFile(io, model.path, .{});
    defer file.close(io);
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    var buf: [64 * 1024]u8 = undefined;
    var done: u64 = 0;
    var tick: usize = 0;
    report(reporter, .{ .phase = .hashing, .model = model.name, .total_bytes = model.size_bytes });
    while (true) {
        const n = file.readStreaming(io, &.{&buf}) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (n == 0) break;
        hash.update(buf[0..n]);
        done += n;
        // Every 8 MiB rather than every chunk: a repaint per 64 KiB
        // would spend more time drawing than hashing.
        if (done % (8 * 1024 * 1024) < n) {
            tick += 1;
            report(reporter, .{
                .phase = .hashing,
                .model = model.name,
                .done_bytes = done,
                .total_bytes = model.size_bytes,
                .tick = tick,
            });
        }
    }
    return hash.finalResult();
}

/// `adb push`, with a progress bar the operator can believe.
///
/// adb prints per-chunk progress only to a terminal — piped, it emits
/// one summary line at the end and nothing before it. So the bar comes
/// from the other side: poll the growing remote file while the child
/// runs. The child's stdout pipe closing is the exit signal, which
/// avoids a blocking wait that would freeze the frame.
fn push(
    gpa: std.mem.Allocator,
    io: std.Io,
    serial: []const u8,
    model: catalog.Model,
    remote: []const u8,
    reporter: ?Reporter,
) !void {
    var status: Status = .{
        .phase = .uploading,
        .model = model.name,
        .device = serial,
        .total_bytes = model.size_bytes,
    };
    report(reporter, status);

    var child = try std.process.spawn(io, .{
        .argv = &.{ "adb", "-s", serial, "push", model.path, remote },
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    const out_fd = (child.stdout orelse {
        child.kill(io);
        return error.AdbCommandFailed;
    }).handle;

    var scratch: [4096]u8 = undefined;
    while (true) {
        var pfd = [_]std.posix.pollfd{.{ .fd = out_fd, .events = std.posix.POLL.IN, .revents = 0 }};
        const ready = std.posix.poll(&pfd, 250) catch break;
        if (ready > 0) {
            const n = std.posix.read(out_fd, &scratch) catch 0;
            if (n == 0) break; // pipe closed — adb has exited
            continue;
        }
        status.tick += 1;
        // A failed stat (the file is not there yet on the first poll)
        // holds the last known figure rather than snapping to zero.
        status.done_bytes = remoteSize(gpa, io, serial, remote) catch status.done_bytes;
        report(reporter, status);
    }

    const term = try child.wait(io);
    if (term == .exited and term.exited == 0) return;
    std.debug.print("zzzbench: {s}: model upload failed\n", .{serial});
    return error.AdbCommandFailed;
}

fn remoteSha256(gpa: std.mem.Allocator, io: std.Io, serial: []const u8, path: []const u8) ![32]u8 {
    const result = try std.process.run(gpa, io, .{
        .argv = &.{ "adb", "-s", serial, "shell", "sha256sum", path },
        .stdout_limit = .limited(1024),
        .stderr_limit = .limited(1024),
    });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) return error.RemoteHashFailed;
    const text = std.mem.trim(u8, result.stdout, " \t\r\n");
    if (text.len < 64) return error.RemoteHashMalformed;
    var digest: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&digest, text[0..64]) catch return error.RemoteHashMalformed;
    return digest;
}

fn adbChecked(gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8) !void {
    const result = try std.process.run(gpa, io, .{
        .argv = argv,
        .stdout_limit = .limited(8 * 1024 * 1024),
        .stderr_limit = .limited(8 * 1024 * 1024),
    });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    if (result.term == .exited and result.term.exited == 0) return;
    const detail = std.mem.trim(u8, result.stderr, " \t\r\n");
    std.debug.print("zzzbench: adb model sync failed: {s}\n", .{detail[0..@min(detail.len, 2048)]});
    return error.AdbCommandFailed;
}

test "cache identity includes device, digest, path, and size" {
    const entries = [_]CacheEntry{.{
        .serial = "pixel",
        .sha256 = "abc",
        .remote_path = "/data/model.gguf",
        .size_bytes = 42,
    }};
    try std.testing.expect(cacheContains(&entries, "pixel", "abc", "/data/model.gguf", 42));
    try std.testing.expect(!cacheContains(&entries, "oneplus", "abc", "/data/model.gguf", 42));
    try std.testing.expect(!cacheContains(&entries, "pixel", "abc", "/data/model.gguf", 43));
}

test "unsafe model basenames do not reach the Android shell" {
    try std.testing.expectEqualStrings("Qwen-Q4_0.gguf", safeBasename("Qwen-Q4_0.gguf"));
    try std.testing.expectEqualStrings("model.gguf", safeBasename("model;reboot.gguf"));
}
