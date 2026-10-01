//! Android probe preparation: forward an existing probe when possible,
//! otherwise validate supplied executables, checksum, push, launch, and verify workspace-scoped
//! artifacts before the dashboard starts.

const std = @import("std");
const proto = @import("proto");

const android = @import("android.zig");
const bundle = @import("../bundle.zig");
const wire = @import("../wire.zig");

pub const Prepared = struct {
    endpoint: []const u8,
    bootstrapped: bool,
};

pub fn prepare(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    io: std.Io,
    workspace_path: []const u8,
    serial: []const u8,
) !Prepared {
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe_len = try std.process.executablePath(io, &exe_buf);
    const machine = try deviceOutput(gpa, io, &.{ "adb", "-s", serial, "shell", "uname", "-m" });
    defer gpa.free(machine);
    if (!std.mem.eql(u8, std.mem.trim(u8, machine, " \t\r\n"), "aarch64")) {
        return error.UnsupportedAndroidArchitecture;
    }
    // Unknown CPU features select the baseline; never guess from a phone name.
    const cpuinfo = deviceOutput(gpa, io, &.{ "adb", "-s", serial, "shell", "cat", "/proc/cpuinfo" }) catch null;
    defer if (cpuinfo) |bytes| gpa.free(bytes);
    const i8mm = if (cpuinfo) |bytes| bundle.supportsI8mm(bytes) else false;
    const probe_path = try suppliedArtifact(gpa, io, exe_buf[0..exe_len], .probe, i8mm);
    defer gpa.free(probe_path);
    const engine_path = try suppliedArtifact(gpa, io, exe_buf[0..exe_len], .engine, i8mm);
    defer gpa.free(engine_path);
    const host_port = try android.setupForward(gpa, io, serial);
    const endpoint = try std.fmt.allocPrint(arena, "tcp:{d}", .{host_port});
    const running_hello = wire.probeHello(endpoint);

    if (running_hello) |hello| {
        if (hello.proto_version < proto.run_spec_min_version or hello.has_engine != 1) {
            std.debug.print("zzzbench: {s}: replacing probe without run-time model support\n", .{serial});
        } else switch (reuseDecisionFor(gpa, io, serial, probe_path, engine_path)) {
            .reuse => {
                std.debug.print("zzzbench: {s}: reusing already-running probe (same binary)\n", .{serial});
                return .{ .endpoint = endpoint, .bootstrapped = false };
            },
            .replace_stale => std.debug.print(
                "zzzbench: {s}: replacing probe — the one running is a different binary\n",
                .{serial},
            ),
            .replace_unverifiable => std.debug.print(
                "zzzbench: {s}: replacing probe — cannot tell which binary it is\n",
                .{serial},
            ),
        }
    }

    var remote_buf: [96]u8 = undefined;
    const remote_root = remoteWorkspacePath(workspace_path, &remote_buf);
    try adbChecked(gpa, io, &.{ "adb", "-s", serial, "shell", "mkdir", "-p", remote_root });

    const remote_probe = try std.fmt.allocPrint(gpa, "{s}/zzzprobe", .{remote_root});
    defer gpa.free(remote_probe);
    const remote_engine = try std.fmt.allocPrint(gpa, "{s}/zzz", .{remote_root});
    defer gpa.free(remote_engine);
    if (running_hello != null) {
        var buf: ProbeBuffers = undefined;
        const running = findRunningProbe(gpa, io, serial, &buf);
        // Ours or a stranger's? An exact match on the full remote path,
        // not a prefix: `zzz-abc-backup` starts with `zzz-abc`, and a
        // prefix test would classify a neighbouring workspace's probe
        // as ours and kill it — the opposite of the protection below.
        //
        // Kill by PID rather than by argv pattern: a probe started with
        // a relative path has an argv that no absolute pattern matches,
        // and a `pkill` that quietly matches nothing looks exactly like
        // a probe that refused to die.
        const ours = running != null and isOurProbe(running.?.path, remote_probe);
        if (ours) {
            try adbChecked(gpa, io, &.{ "adb", "-s", serial, "shell", "kill", "-9", running.?.pid });
        } else {
            try stopWorkspaceProbe(gpa, io, serial, remote_root);
        }
        var attempt: usize = 0;
        while (attempt < 20 and wire.probeHealthy(endpoint)) : (attempt += 1) {
            std.Io.sleep(io, .fromMilliseconds(25), .awake) catch {};
        }
        if (wire.probeHealthy(endpoint)) {
            // Still answering after we stopped everything of ours, so
            // the port belongs to a probe another workspace launched.
            // Name it rather than killing it: the device may be shared,
            // and a blind `pkill zzzprobe` would end someone else's run.
            if (running) |probe| {
                std.debug.print(
                    "zzzbench: {s}: port 7779 is held by a probe outside this workspace:\n  {s}\n",
                    .{ serial, probe.path },
                );
            }
            return error.IncompatibleProbeRunning;
        }
    }
    try pushVerified(gpa, io, serial, probe_path, remote_probe);
    try pushVerified(gpa, io, serial, engine_path, remote_engine);
    // Query on the target before launching a probe configured with this engine.
    const contract = @import("engine_contract");
    const info = try contract.queryInfo(gpa, io, &.{ "adb", "-s", serial, "shell", remote_engine, "bench-info" });
    defer gpa.free(info);
    try contract.validateInfo(gpa, info, .android);
    try startProbe(gpa, io, serial, remote_probe, remote_engine, remote_root);

    var attempt: usize = 0;
    while (attempt < 20) : (attempt += 1) {
        std.Io.sleep(io, .fromMilliseconds(50), .awake) catch {};
        if (wire.probeHealthy(endpoint)) return .{ .endpoint = endpoint, .bootstrapped = true };
    }
    return error.ProbeBootstrapFailed;
}

/// What to do with a probe that is already serving this port.
pub const Reuse = enum { reuse, replace_stale, replace_unverifiable };

/// Adopt a running probe only when its checksum matches the supplied binary.
/// A compatible Hello establishes protocol support, not binary identity.
/// Missing checksums prevent reuse because the runtime cannot be verified.
pub fn reuseDecision(local: ?[32]u8, running: ?[32]u8) Reuse {
    const want = local orelse return .replace_unverifiable;
    const have = running orelse return .replace_unverifiable;
    return if (std.mem.eql(u8, &want, &have)) .reuse else .replace_stale;
}

/// Whether a running probe's executable is this workspace's own.
///
/// Exact, not a prefix. `/data/local/tmp/zzz-abc-backup/zzzprobe`
/// starts with `/data/local/tmp/zzz-abc`, so a prefix test would
/// classify a neighbouring workspace's probe as ours and kill it —
/// exactly the foreign-probe protection this is meant to uphold.
pub fn isOurProbe(running_path: []const u8, remote_probe: []const u8) bool {
    return std.mem.eql(u8, running_path, remote_probe);
}

test "a neighbouring workspace's probe is not ours to kill" {
    const ours = "/data/local/tmp/zzz-abc/zzzprobe";
    try std.testing.expect(isOurProbe(ours, ours));
    // The prefix trap: `zzz-abc-backup` begins with `zzz-abc`.
    try std.testing.expect(!isOurProbe("/data/local/tmp/zzz-abc-backup/zzzprobe", ours));
    try std.testing.expect(!isOurProbe("/data/local/tmp/zzz-def/zzzprobe", ours));
    try std.testing.expect(!isOurProbe("/data/local/tmp/zzzprobe", ours));
}

/// The port the probe binds on the device. The host side of the adb
/// forward is kernel-picked and differs per launch, but the device
/// side is fixed by `startProbe` — and it is the device side that
/// appears in `ps`.
const device_endpoint = "tcp:7779";

/// The running probe, as `ps` sees it.
pub const RunningProbe = struct {
    pid: []const u8,
    path: []const u8,
    /// The engine it was launched with, from its `--engine` argument.
    /// Empty when it carries none.
    engine: []const u8,
};

/// Verify both the running probe and its engine against the supplied binaries.
/// The engine can change independently of the probe, so both must match before
/// reusing the process for a benchmark.
fn reuseDecisionFor(
    gpa: std.mem.Allocator,
    io: std.Io,
    serial: []const u8,
    probe_path: []const u8,
    engine_path: []const u8,
) Reuse {
    var buf: ProbeBuffers = undefined;
    const running = findRunningProbe(gpa, io, serial, &buf) orelse return .replace_unverifiable;

    // `/proc/<pid>/exe`, not the pathname. A path can be replaced
    // underneath a live process — that is exactly what `pushVerified`
    // does when it `mv`s a new binary into place — so hashing the path
    // would read the *new* inode while still talking to a probe
    // running the old one, and report `reuse`. The proc link is the
    // image the process actually loaded.
    var exe_buf: [64]u8 = undefined;
    const running_exe = std.fmt.bufPrint(&exe_buf, "/proc/{s}/exe", .{running.pid}) catch
        return .replace_unverifiable;
    const probe = reuseDecision(
        localSha256(io, probe_path) catch null,
        remoteSha256(gpa, io, serial, running_exe) catch null,
    );
    if (probe != .reuse) return probe;

    // The engine has no live process to ask — it is spawned per run —
    // so the path is all there is. It is written by `pushVerified`,
    // which checksums after the `mv`, so the file at that path is the
    // one a run would load.
    if (running.engine.len == 0) return .replace_unverifiable;
    return reuseDecision(
        localSha256(io, engine_path) catch null,
        remoteSha256(gpa, io, serial, running.engine) catch null,
    );
}

/// SHA-256 of the executable the running probe was launched from, or
/// null when that cannot be established.
///
/// The *process*, not the file at this workspace's remote path. Only
/// one probe can hold device port 7779, so the one answering may have
/// been started by another workspace from another directory — and it
/// is the running code that produced any number, not whatever happens
/// to sit at the path we would have used.
/// Scratch the caller owns for one `findRunningProbe` result.
pub const ProbeBuffers = struct {
    path: [256]u8 = undefined,
    engine: [256]u8 = undefined,
    pid: [32]u8 = undefined,
};

/// Ask the device which probe is running. Null when none is, or when
/// `ps` cannot be read.
fn findRunningProbe(
    gpa: std.mem.Allocator,
    io: std.Io,
    serial: []const u8,
    buf: *ProbeBuffers,
) ?RunningProbe {
    // One argv element for the whole remote command: `adb shell` joins
    // its arguments with no quoting, so a multi-word command passed as
    // separate arguments silently does the wrong thing on device.
    const result = std.process.run(gpa, io, .{
        .argv = &.{ "adb", "-s", serial, "shell", "ps -A -o PID,ARGS" },
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(64 * 1024),
    }) catch return null;
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) return null;

    // `path` is written into the caller's buffer; `pid` still slices
    // `result.stdout`, which the defer above frees as this returns, so
    // it is copied out too. Returning a borrow of freed stdout was a
    // use-after-free the caller had no way to see.
    const found = runningProbeLine(result.stdout, device_endpoint, &buf.path) orelse return null;
    if (found.pid.len > buf.pid.len or found.engine.len > buf.engine.len) return null;
    @memcpy(buf.pid[0..found.pid.len], found.pid);
    @memcpy(buf.engine[0..found.engine.len], found.engine);
    return .{
        .pid = buf.pid[0..found.pid.len],
        .path = found.path,
        .engine = buf.engine[0..found.engine.len],
    };
}

/// Path of the running `zzzprobe` binary, read out of `ps` output.
///
/// Two shapes, because Android gives both. A hand-launched probe shows
/// its full path as argv[0]. One this bench started shows a *bare*
/// `zzzprobe` — it goes through `nohup` inside `sh -c`, and that is
/// what toybox reports:
///
///   zzzprobe tcp:7779 --engine /data/local/tmp/zzz-8fff9cb/zzz
///
/// In that shape the `--engine` argument still names the directory the
/// probe was launched from, which is the workspace-scoped root, so the
/// probe sits beside it. Reading only argv[0] found nothing here and
/// made every launch re-push — a check that never verifies is worse
/// than no check, because it looks like one.
/// The `ps` line for the probe listening on `endpoint`, or null.
///
/// The endpoint is part of the match, not an afterthought: a shared
/// device can carry several probes, and the Hello that prompted this
/// came from one specific port. Taking the first `zzzprobe` in `ps`
/// would hash one process and kill another.
///
/// `path` may borrow from `ps_output` — the caller copies it out.
fn runningProbeLine(ps_output: []const u8, endpoint: []const u8, buf: []u8) ?RunningProbe {
    var lines = std.mem.tokenizeScalar(u8, ps_output, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        var fields = std.mem.tokenizeScalar(u8, line, ' ');
        const pid = fields.next() orelse continue;
        if (pid.len == 0 or !std.ascii.isDigit(pid[0])) continue;
        const argv0 = fields.next() orelse continue;
        const is_probe = std.mem.eql(u8, argv0, "zzzprobe") or
            std.mem.endsWith(u8, argv0, "/zzzprobe");
        if (!is_probe) continue;

        // The probe's first argument is its endpoint.
        const arg_endpoint = fields.next() orelse continue;
        if (!std.mem.eql(u8, arg_endpoint, endpoint)) continue;

        // `--engine` is wanted either way: as the probe's location
        // when argv[0] is bare, and always as the engine to verify.
        var engine: []const u8 = "";
        var rest = fields;
        while (rest.next()) |field| {
            if (!std.mem.eql(u8, field, "--engine")) continue;
            engine = rest.next() orelse "";
            break;
        }
        if (std.mem.indexOfScalar(u8, argv0, '/') != null) {
            const path = std.fmt.bufPrint(buf, "{s}", .{argv0}) catch return null;
            return .{ .pid = pid, .path = path, .engine = engine };
        }
        // A probe launched through `nohup` inside `sh -c` reports a
        // bare argv[0]; `--engine` names the directory it lives in.
        if (engine.len > 0) {
            const dir = std.fs.path.dirname(engine) orelse continue;
            const path = std.fmt.bufPrint(buf, "{s}/zzzprobe", .{dir}) catch return null;
            return .{ .pid = pid, .path = path, .engine = engine };
        }
    }
    return null;
}

test "a running probe is adopted only when it is provably this build" {
    const built: [32]u8 = @splat(0xAB);
    const other: [32]u8 = @splat(0xCD);

    try std.testing.expectEqual(Reuse.reuse, reuseDecision(built, built));
    try std.testing.expectEqual(Reuse.replace_stale, reuseDecision(built, other));
    // No local artifact to compare against, or a probe whose binary
    // cannot be identified: both are "we do not know", and not knowing
    // which binary produced a number is the same problem as knowing it
    // was the wrong one.
    try std.testing.expectEqual(Reuse.replace_unverifiable, reuseDecision(null, other));
    try std.testing.expectEqual(Reuse.replace_unverifiable, reuseDecision(built, null));
    try std.testing.expectEqual(Reuse.replace_unverifiable, reuseDecision(null, null));
}

test "the probe path and pid survive both shapes Android reports" {
    var buf: [256]u8 = undefined;

    // What a probe this bench launched actually looks like on device:
    // a bare argv[0], with the workspace root only in `--engine`.
    const nohup_shape =
        "  PID ARGS\n" ++
        "    1 /system/bin/init second_stage\n" ++
        " 4821 sh -c cd /data/local/tmp/zzz-8fff9cb4544e && nohup ./zzzprobe tcp:7779\n" ++
        " 4830 zzzprobe tcp:7779 --engine /data/local/tmp/zzz-8fff9cb4544e/zzz\n";
    const found = runningProbeLine(nohup_shape, device_endpoint, &buf).?;
    try std.testing.expectEqualStrings("/data/local/tmp/zzz-8fff9cb4544e/zzzprobe", found.path);
    try std.testing.expectEqualStrings("4830", found.pid);
    // The engine is captured too: kernel work changes it while leaving
    // the probe byte-identical, so verifying the probe alone would
    // adopt a stale engine.
    try std.testing.expectEqualStrings(
        "/data/local/tmp/zzz-8fff9cb4544e/zzz",
        found.engine,
    );

    // A hand-launched one carries its own path.
    const full_path_shape = "  PID ARGS\n 900 /data/local/tmp/zzzprobe tcp:7779\n";
    const direct = runningProbeLine(full_path_shape, device_endpoint, &buf).?;
    try std.testing.expectEqualStrings("/data/local/tmp/zzzprobe", direct.path);
    try std.testing.expectEqualStrings("900", direct.pid);

    // Nothing to find, a header row, and a bare name with no
    // `--engine` to locate it by.
    try std.testing.expectEqual(
        @as(?RunningProbe, null),
        runningProbeLine("  PID ARGS\n 1 /system/bin/init\n", device_endpoint, &buf),
    );
    try std.testing.expectEqual(
        @as(?RunningProbe, null),
        runningProbeLine(" 12 zzzprobe tcp:7779\n", device_endpoint, &buf),
    );
}

test "a shared device picks the probe holding this port, not the first one" {
    var buf: [256]u8 = undefined;
    // Two probes, and the one that answered our Hello is the second.
    const output =
        "  PID ARGS\n" ++
        " 4000 zzzprobe tcp:7999 --engine /data/local/tmp/zzz-other/zzz\n" ++
        " 4830 zzzprobe tcp:7779 --engine /data/local/tmp/zzz-8fff9cb4544e/zzz\n";
    const found = runningProbeLine(output, device_endpoint, &buf).?;
    try std.testing.expectEqualStrings("/data/local/tmp/zzz-8fff9cb4544e/zzzprobe", found.path);
    // Hashing one process and killing another is how a run gets
    // attributed to a binary that never produced it.
    try std.testing.expectEqualStrings("4830", found.pid);
}

fn stopWorkspaceProbe(
    gpa: std.mem.Allocator,
    io: std.Io,
    serial: []const u8,
    remote_root: []const u8,
) !void {
    const command = try std.fmt.allocPrint(
        gpa,
        "pkill -f '{s}/[z]zzprobe' >/dev/null 2>&1 || true",
        .{remote_root},
    );
    defer gpa.free(command);
    try adbChecked(gpa, io, &.{ "adb", "-s", serial, "shell", command });
}

pub fn remoteWorkspacePath(workspace_path: []const u8, out: *[96]u8) []const u8 {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(workspace_path, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return std.fmt.bufPrint(out, "/data/local/tmp/zzz-{s}", .{hex[0..12]}) catch unreachable;
}

fn deviceOutput(gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8) ![]u8 {
    const timeout: std.Io.Timeout = .{
        .duration = .{ .raw = .fromSeconds(10), .clock = .awake },
    };
    const result = try std.process.run(gpa, io, .{
        .argv = argv,
        .stdout_limit = .limited(256 * 1024),
        .stderr_limit = .limited(16 * 1024),
        .timeout = timeout.toDeadline(io),
    });
    gpa.free(result.stderr);
    errdefer gpa.free(result.stdout);
    if (result.term != .exited or result.term.exited != 0) return error.DeviceQueryFailed;
    return result.stdout;
}

fn suppliedArtifact(
    gpa: std.mem.Allocator,
    io: std.Io,
    executable: []const u8,
    artifact: bundle.Artifact,
    i8mm: bool,
) ![:0]const u8 {
    const name: [:0]const u8 = switch (artifact) {
        .probe => "ZZZBENCH_ANDROID_PROBE_BIN",
        .engine => "ZZZBENCH_ANDROID_ENGINE_BIN",
    };
    const override = if (std.c.getenv(name)) |raw| std.mem.span(raw) else null;
    const path = bundle.resolve(gpa, io, executable, artifact, override, i8mm) catch |err| {
        std.debug.print(
            "zzzbench: Android {s} unavailable ({s}); install the full zzzbench bundle or set {s}\n",
            .{ @tagName(artifact), @errorName(err), name },
        );
        return err;
    };
    errdefer gpa.free(path);
    // Refuse host Mach-O and wrong-architecture ELF before uploading either file.
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var header: [20]u8 = undefined;
    const count = try file.readPositionalAll(io, &header, 0);
    if (!androidTarget(header[0..count])) return error.WrongAndroidTarget;
    return path;
}

fn androidTarget(header: []const u8) bool {
    return header.len >= 20 and std.mem.eql(u8, header[0..4], "\x7fELF") and
        header[4] == 2 and header[5] == 1 and
        std.mem.readInt(u16, header[18..20], .little) == 183;
}

test "Android staging rejects host, wrong architecture and truncated executables" {
    var header: [20]u8 = @splat(0);
    @memcpy(header[0..4], "\x7fELF");
    header[4] = 2;
    header[5] = 1;
    std.mem.writeInt(u16, header[18..20], 183, .little);
    try std.testing.expect(androidTarget(&header));
    try std.testing.expect(!androidTarget(header[0..19]));
    std.mem.writeInt(u16, header[18..20], 62, .little);
    try std.testing.expect(!androidTarget(&header));
    try std.testing.expect(!androidTarget("\xcf\xfa\xed\xfe"));
}

fn pushVerified(
    gpa: std.mem.Allocator,
    io: std.Io,
    serial: []const u8,
    local_path: []const u8,
    remote_path: []const u8,
) !void {
    const expected = try localSha256(io, local_path);
    const current = remoteSha256(gpa, io, serial, remote_path) catch null;
    const plan = syncPlan(expected, current);
    if (plan.upload) {
        const temp_path = try std.fmt.allocPrint(gpa, "{s}.upload", .{remote_path});
        defer gpa.free(temp_path);
        try adbChecked(gpa, io, &.{ "adb", "-s", serial, "push", local_path, temp_path });
        const uploaded = try remoteSha256(gpa, io, serial, temp_path);
        if (!std.mem.eql(u8, &expected, &uploaded)) return error.UploadChecksumMismatch;
        try adbChecked(gpa, io, &.{ "adb", "-s", serial, "shell", "mv", temp_path, remote_path });
    }
    try adbChecked(gpa, io, &.{ "adb", "-s", serial, "shell", "chmod", "755", remote_path });
    if (!plan.upload) return;
    const installed = try remoteSha256(gpa, io, serial, remote_path);
    if (!std.mem.eql(u8, &expected, &installed)) return error.InstalledChecksumMismatch;
}

const SyncPlan = struct {
    upload: bool,
    chmod: bool = true,
};

fn syncPlan(expected: [32]u8, current: ?[32]u8) SyncPlan {
    const digest = current orelse return .{ .upload = true };
    return .{ .upload = !std.mem.eql(u8, &expected, &digest) };
}

fn localSha256(io: std.Io, path: []const u8) ![32]u8 {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        const n = file.readStreaming(io, &.{&buf}) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        // EOF is signalled by EndOfStream above; treat a defensive
        // zero-byte read as EOF too rather than spinning on it.
        if (n == 0) break;
        hash.update(buf[0..n]);
    }
    return hash.finalResult();
}

fn remoteSha256(
    gpa: std.mem.Allocator,
    io: std.Io,
    serial: []const u8,
    path: []const u8,
) ![32]u8 {
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

fn startProbe(
    gpa: std.mem.Allocator,
    io: std.Io,
    serial: []const u8,
    remote_probe: []const u8,
    remote_engine: []const u8,
    remote_root: []const u8,
) !void {
    const command = try std.fmt.allocPrint(
        gpa,
        "nohup {s} tcp:7779 --allow-exec --engine {s} >{s}/probe.log 2>&1 </dev/null &",
        .{ remote_probe, remote_engine, remote_root },
    );
    defer gpa.free(command);
    // One argv element for the whole remote command. `adb shell` joins
    // its arguments with spaces and applies NO quoting, so a separate
    // `sh -c <command>` arrives on the device as `sh -c nohup <rest>`
    // — sh takes only the word after -c as the command and the probe
    // never starts (verified on-device). The device shell parses the
    // single string correctly, redirections and `&` included.
    try adbChecked(gpa, io, &.{ "adb", "-s", serial, "shell", command });
}

fn adbChecked(gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8) !void {
    const result = try std.process.run(gpa, io, .{
        .argv = argv,
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) return error.AdbCommandFailed;
}

test "remote path is stable per workspace and differs across workspaces" {
    var first_buf: [96]u8 = undefined;
    var again_buf: [96]u8 = undefined;
    var other_buf: [96]u8 = undefined;
    const first = remoteWorkspacePath("/tmp/worktree-a", &first_buf);
    const again = remoteWorkspacePath("/tmp/worktree-a", &again_buf);
    const other = remoteWorkspacePath("/tmp/worktree-b", &other_buf);
    try std.testing.expectEqualStrings(first, again);
    try std.testing.expect(!std.mem.eql(u8, first, other));
    try std.testing.expect(std.mem.startsWith(u8, first, "/data/local/tmp/zzz-"));
}

test "matching remote binary still receives executable permissions" {
    const digest = [_]u8{0x5a} ** 32;
    const plan = syncPlan(digest, digest);
    try std.testing.expect(!plan.upload);
    try std.testing.expect(plan.chmod);
}
