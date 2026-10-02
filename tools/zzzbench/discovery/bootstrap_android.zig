//! Android probe preparation: forward an existing probe when possible,
//! otherwise validate supplied executables, checksum, push, launch, and verify workspace-scoped
//! artifacts before the dashboard starts.

const std = @import("std");
const proto = @import("proto");
const tui = @import("tuiz");

const android = @import("android.zig");
const bundle = @import("../bundle.zig");
const wire = @import("../wire.zig");

pub const Prepared = struct {
    endpoint: []const u8,
    bootstrapped: bool,
};

/// What to do when device port 7779 belongs to a probe another
/// workspace launched. Never a silent kill: the device may be shared,
/// and a blind `pkill zzzprobe` would end someone else's run.
pub const ForeignProbe = enum {
    /// Name it and stop. The only safe choice without a terminal, where
    /// nobody is there to say whose probe it is.
    refuse,
    /// Name it, show how long it has been up, and ask.
    ask,
    /// `--replace-probe`: the operator already said yes.
    replace,
};

pub fn prepare(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    io: std.Io,
    workspace_path: []const u8,
    serial: []const u8,
    foreign: ForeignProbe,
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

    var remote_buf: [96]u8 = undefined;
    const remote_root = remoteWorkspacePath(workspace_path, &remote_buf);
    const remote_probe = try std.fmt.allocPrint(gpa, "{s}/zzzprobe", .{remote_root});
    defer gpa.free(remote_probe);
    const remote_engine = try std.fmt.allocPrint(gpa, "{s}/zzz", .{remote_root});
    defer gpa.free(remote_engine);

    // Both, because each misses a case the other sees. A probe busy with
    // another client never answers a second Hello — it is single-client —
    // so Hello alone reads a held port as free and the launch below dies
    // on bind. `ps` cannot say whether the probe speaks a protocol we can
    // drive.
    const running_hello = wire.probeHello(endpoint);
    var running_buf: ProbeBuffers = undefined;
    const running = findRunningProbe(gpa, io, serial, &running_buf);
    if (running_hello) |hello| {
        const adopt = adoptRunning(gpa, io, serial, .{
            .hello = hello,
            .running = running,
            .probe_path = probe_path,
            .engine_path = engine_path,
            .remote_probe = remote_probe,
            .foreign = foreign,
        });
        if (adopt) return .{ .endpoint = endpoint, .bootstrapped = false };
    }

    try adbChecked(gpa, io, &.{ "adb", "-s", serial, "shell", "mkdir", "-p", remote_root });
    if (running_hello != null or running != null) {
        try clearPort(gpa, io, serial, endpoint, remote_probe, remote_root, foreign);
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

/// What `adoptRunning` weighs.
const Adoption = struct {
    hello: proto.Hello,
    running: ?RunningProbe,
    probe_path: []const u8,
    engine_path: []const u8,
    remote_probe: []const u8,
    foreign: ForeignProbe,
};

/// Whether to keep the probe that answered Hello instead of launching
/// ours. Says why when it will not.
fn adoptRunning(gpa: std.mem.Allocator, io: std.Io, serial: []const u8, c: Adoption) bool {
    if (c.hello.proto_version < proto.run_spec_min_version or c.hello.has_engine != 1) {
        std.debug.print("zzzbench: {s}: replacing probe without run-time model support\n", .{serial});
        return false;
    }
    switch (reuseDecisionFor(gpa, io, serial, c.running, c.probe_path, c.engine_path)) {
        .reuse => {},
        .replace_stale => {
            std.debug.print("zzzbench: {s}: replacing probe — the one running is a different binary\n", .{serial});
            return false;
        },
        .replace_unverifiable => {
            std.debug.print("zzzbench: {s}: replacing probe — cannot tell which binary it is\n", .{serial});
            return false;
        },
    }
    // `.reuse` means `ps` found it, so `running` is set. The same bytes
    // are not enough under `--replace-probe`: another workspace's probe
    // runs the engine at *its* path, which that workspace overwrites on
    // its next launch, and it keeps serving that workspace's dashboard.
    if (c.foreign == .replace and !isOurProbe(c.running.?.path, c.remote_probe)) {
        std.debug.print(
            "zzzbench: {s}: replacing probe — same binary, but another workspace launched it (--replace-probe)\n",
            .{serial},
        );
        return false;
    }
    std.debug.print("zzzbench: {s}: reusing already-running probe (same binary)\n", .{serial});
    return true;
}

/// Free device port 7779 for this workspace's probe. Ours is stopped
/// outright; another workspace's only as `foreign` allows.
fn clearPort(
    gpa: std.mem.Allocator,
    io: std.Io,
    serial: []const u8,
    endpoint: []const u8,
    remote_probe: []const u8,
    remote_root: []const u8,
    foreign: ForeignProbe,
) !void {
    var buf: ProbeBuffers = undefined;
    const running = findRunningProbe(gpa, io, serial, &buf);
    // Ours or a stranger's? An exact match on the full remote path,
    // not a prefix: `zzz-abc-backup` starts with `zzz-abc`, and a
    // prefix test would classify a neighbouring workspace's probe
    // as ours and kill it without asking.
    //
    // Kill by PID rather than by argv pattern: a probe started with
    // a relative path has an argv that no absolute pattern matches,
    // and a `pkill` that quietly matches nothing looks exactly like
    // a probe that refused to die.
    const ours = running != null and isOurProbe(running.?.path, remote_probe);
    if (ours) {
        try killProbeTree(gpa, io, serial, running.?.pid);
    } else {
        try stopWorkspaceProbe(gpa, io, serial, remote_root);
    }
    // Waiting only helps a probe we just signalled. One that belongs to
    // another workspace was not touched, so go straight to asking.
    const probe = if (ours) null else running;
    if (probe == null) {
        if (stillHeld(gpa, io, serial, endpoint)) return error.IncompatibleProbeRunning;
        return;
    }
    if (!mayStopForeign(gpa, io, serial, probe.?, foreign)) return error.IncompatibleProbeRunning;
    if (!try killIfStillHolder(gpa, io, serial, probe.?)) {
        std.debug.print("  it changed while you were asked; nothing was stopped — retry\n", .{});
        return error.IncompatibleProbeRunning;
    }
    if (stillHeld(gpa, io, serial, endpoint)) return error.IncompatibleProbeRunning;
}

/// Whether a probe holds device port 7779, busy or idle. `ps` first,
/// because a probe serving another client never answers our Hello.
fn portHeld(gpa: std.mem.Allocator, io: std.Io, serial: []const u8, endpoint: []const u8) bool {
    var buf: ProbeBuffers = undefined;
    if (findRunningProbe(gpa, io, serial, &buf) != null) return true;
    return wire.probeHealthy(endpoint);
}

/// Give a just-signalled probe about a second to release the port.
fn stillHeld(gpa: std.mem.Allocator, io: std.Io, serial: []const u8, endpoint: []const u8) bool {
    var attempt: usize = 0;
    while (attempt < 10 and portHeld(gpa, io, serial, endpoint)) : (attempt += 1) {
        std.Io.sleep(io, .fromMilliseconds(25), .awake) catch {};
    }
    return portHeld(gpa, io, serial, endpoint);
}

/// Kill `probe` only if it is still the one process on the port.
///
/// Its pid was read before the operator was asked, and an unbounded
/// prompt is long enough for it to exit and Android to hand the number
/// to something unrelated. Re-reading `ps` narrows that window to one
/// adb round trip.
fn killIfStillHolder(
    gpa: std.mem.Allocator,
    io: std.Io,
    serial: []const u8,
    probe: RunningProbe,
) !bool {
    const ps = devicePs(gpa, io, serial) orelse return false;
    defer gpa.free(ps);
    if (!soleHolder(ps, device_endpoint, probe)) return false;
    try killProbeTree(gpa, io, serial, probe.pid);
    return true;
}

/// Most processes `killProbeTree` collects: the probe, its engine or
/// exec child, and whatever that spawned.
const max_tree = 32;

/// Kill a probe and everything it spawned, in one `kill -9`.
///
/// The probe runs its engine and exec requests as child processes.
/// SIGKILL gives it no chance to stop them, and nothing guarantees an
/// engine exits when its output closes, so a run in flight could keep
/// decoding beside the replacement and take cores from its first
/// measurement.
/// The probe is frozen first so it cannot start another child between
/// reading the tree and killing it.
fn killProbeTree(gpa: std.mem.Allocator, io: std.Io, serial: []const u8, pid: []const u8) !void {
    try adbChecked(gpa, io, &.{ "adb", "-s", serial, "shell", "kill", "-STOP", pid });
    // Without the table, kill the probe alone rather than leave it frozen.
    const table = deviceOutput(gpa, io, &.{ "adb", "-s", serial, "shell", "ps -A -o PID,PPID" }) catch null;
    defer if (table) |bytes| gpa.free(bytes);
    var tree_buf: [max_tree][]const u8 = undefined;
    const tree = if (table) |bytes| processTree(bytes, pid, &tree_buf) else blk: {
        tree_buf[0] = pid;
        break :blk tree_buf[0..1];
    };
    // Pids are digits only (`isPid`), so one unquoted command is safe.
    var command_buf: [16 + max_tree * 11]u8 = undefined;
    var command: std.Io.Writer = .fixed(&command_buf);
    command.writeAll("kill -9") catch unreachable;
    for (tree) |member| command.print(" {s}", .{member}) catch unreachable;
    try adbChecked(gpa, io, &.{ "adb", "-s", serial, "shell", command.buffered() });
}

/// `root` and every process descended from it, read from
/// `ps -A -o PID,PPID`. `root` comes first; the rest borrow `ps_output`.
pub fn processTree(ps_output: []const u8, root: []const u8, out: [][]const u8) []const []const u8 {
    out[0] = root;
    var len: usize = 1;
    // One pass per generation: a child can be listed before its parent
    // has been collected.
    var grew = true;
    while (grew and len < out.len) {
        grew = false;
        var lines = std.mem.tokenizeScalar(u8, ps_output, '\n');
        while (lines.next()) |line| {
            var fields = std.mem.tokenizeAny(u8, line, " \t\r");
            const pid = fields.next() orelse continue;
            const ppid = fields.next() orelse continue;
            if (!isPid(pid) or !isPid(ppid)) continue;
            if (contains(out[0..len], pid) or !contains(out[0..len], ppid)) continue;
            if (len == out.len) break;
            out[len] = pid;
            len += 1;
            grew = true;
        }
    }
    return out[0..len];
}

fn contains(set: []const []const u8, pid: []const u8) bool {
    for (set) |member| if (std.mem.eql(u8, member, pid)) return true;
    return false;
}

test "replacing a probe takes its engine and exec children with it" {
    var buf: [max_tree][]const u8 = undefined;
    // The shape toybox prints, with a grandchild listed before its
    // parent and an unrelated tree beside it.
    const table =
        "  PID  PPID\n" ++
        "    1     0\n" ++
        "  414     1\n" ++
        "10512 10511\n" ++ // exec child's own child, listed first
        "10509     1\n" ++ // the probe, reparented to init
        "10510 10509\n" ++ // its engine
        "10511 10509\n" ++ // an exec request
        "20000   414\n"; // unrelated
    const tree = processTree(table, "10509", &buf);
    try std.testing.expectEqual(@as(usize, 4), tree.len);
    try std.testing.expectEqualStrings("10509", tree[0]);
    for ([_][]const u8{ "10510", "10511", "10512" }) |pid| {
        try std.testing.expect(contains(tree, pid));
    }
    try std.testing.expect(!contains(tree, "20000"));
    try std.testing.expect(!contains(tree, "414"));

    // A probe with no children is a tree of one.
    try std.testing.expectEqual(@as(usize, 1), processTree(table, "20000", &buf).len);
    // A full buffer stops collecting instead of overrunning.
    var small: [2][]const u8 = undefined;
    try std.testing.expectEqual(@as(usize, 2), processTree(table, "10509", &small).len);
}

/// Whether `expected` is still the only probe advertising `endpoint`:
/// same pid, same executable, same engine, and no second claimant to
/// make it unclear which one actually holds the port. A row whose path
/// cannot be recovered still counts as a claimant.
pub fn soleHolder(ps_output: []const u8, endpoint: []const u8, expected: RunningProbe) bool {
    var buf: [256]u8 = undefined;
    var probes: ProbeLines = .init(ps_output, endpoint, &buf);
    const first = probes.next() orelse return false;
    const same = std.mem.eql(u8, first.pid, expected.pid) and
        std.mem.eql(u8, first.path, expected.path) and
        std.mem.eql(u8, first.engine, expected.engine);
    return same and probes.next() == null;
}

test "a foreign probe is killed only while it is still the one on the port" {
    const shown: RunningProbe = .{
        .pid = "21040",
        .path = "/data/local/tmp/zzz-other/zzzprobe",
        .engine = "/data/local/tmp/zzz-other/zzz",
    };
    const header = "  PID ARGS\n    1 /system/bin/init second_stage\n";
    const same = header ++ "21040 zzzprobe tcp:7779 --allow-exec --engine /data/local/tmp/zzz-other/zzz\n";
    try std.testing.expect(soleHolder(same, device_endpoint, shown));

    // It exited during the prompt and the pid now belongs to something
    // that is not a probe at all.
    const reused = header ++ "21040 /system/bin/logcat -b all\n";
    try std.testing.expect(!soleHolder(reused, device_endpoint, shown));
    // Or to a different workspace's probe that took the port over.
    const taken_over = header ++ "21040 zzzprobe tcp:7779 --allow-exec --engine /data/local/tmp/zzz-third/zzz\n";
    try std.testing.expect(!soleHolder(taken_over, device_endpoint, shown));
    // Same probe, new pid: restarted, so not the process that was shown.
    const restarted = header ++ "22000 zzzprobe tcp:7779 --allow-exec --engine /data/local/tmp/zzz-other/zzz\n";
    try std.testing.expect(!soleHolder(restarted, device_endpoint, shown));
    // Gone entirely.
    try std.testing.expect(!soleHolder(header, device_endpoint, shown));
    // Two processes advertise the port: only one can hold it, and `ps`
    // cannot say which.
    const contested = same ++ "22000 zzzprobe tcp:7779 --allow-exec --engine /data/local/tmp/zzz-third/zzz\n";
    try std.testing.expect(!soleHolder(contested, device_endpoint, shown));
    // A probe on another port is not a claimant.
    const elsewhere = same ++ "4000 zzzprobe tcp:7999 --engine /data/local/tmp/zzz-third/zzz\n";
    try std.testing.expect(soleHolder(elsewhere, device_endpoint, shown));

    // Claimants whose executable cannot be recovered still contest the
    // port, before or after the expected row: a bare name with no
    // `--engine`, and a path too long to hold.
    const bare = "22000 zzzprobe tcp:7779\n";
    try std.testing.expect(!soleHolder(same ++ bare, device_endpoint, shown));
    try std.testing.expect(!soleHolder(header ++ bare ++ same[header.len..], device_endpoint, shown));
    const long = "22000 /data/local/tmp/" ++ "x" ** 300 ++ "/zzzprobe tcp:7779\n";
    try std.testing.expect(!soleHolder(same ++ long, device_endpoint, shown));

    // A probe whose path is unknown can itself be the one to replace,
    // still pinned by pid.
    const unnamed: RunningProbe = .{ .pid = "22000", .path = "", .engine = "" };
    try std.testing.expect(soleHolder(header ++ bare, device_endpoint, unnamed));
    try std.testing.expect(!soleHolder(header ++ "22001 zzzprobe tcp:7779\n", device_endpoint, unnamed));
}

test "a pid is all digits or it is not a pid" {
    try std.testing.expect(isPid("21040"));
    try std.testing.expect(!isPid("PID"));
    try std.testing.expect(!isPid(""));
    // It would be spliced into `adb shell kill -9 <pid>` unquoted.
    try std.testing.expect(!isPid("21040;reboot"));
    try std.testing.expect(!isPid("12345678901"));
    var buf: [256]u8 = undefined;
    try std.testing.expectEqual(
        @as(?RunningProbe, null),
        runningProbeLine("21040;reboot zzzprobe tcp:7779 --engine /d/zzz\n", device_endpoint, &buf),
    );
}

/// Name the probe holding the port, then decide whether to stop it.
/// The uptime is the useful part: a week-old leftover and a run someone
/// else started a minute ago look identical otherwise.
fn mayStopForeign(
    gpa: std.mem.Allocator,
    io: std.Io,
    serial: []const u8,
    probe: RunningProbe,
    foreign: ForeignProbe,
) bool {
    // The path and uptime are whatever the device's `ps` printed, and a
    // hand-launched probe's argv can carry terminal escapes. The pid is
    // all digits by construction (`ProbeLines`).
    var uptime_buf: [32]u8 = undefined;
    var path_buf: [256]u8 = undefined;
    var safe_uptime_buf: [32]u8 = undefined;
    const uptime = probeUptime(gpa, io, serial, probe.pid, &uptime_buf);
    std.debug.print(
        "zzzbench: {s}: port 7779 is held by a probe outside this workspace:\n  {s} (pid {s}, up {s})\n",
        .{
            serial,
            if (probe.path.len > 0) tui.sanitize.into(&path_buf, probe.path) else "(path unknown)",
            probe.pid,
            tui.sanitize.into(&safe_uptime_buf, uptime),
        },
    );
    switch (foreign) {
        .refuse => {
            std.debug.print("  stop it with: adb -s {s} shell kill {s}\n", .{ serial, probe.pid });
            return false;
        },
        .replace => {
            std.debug.print("  stopping it (--replace-probe)\n", .{});
            return true;
        },
        .ask => {
            std.debug.print(
                "  Stopping it ends any run that workspace has in flight on this device.\n" ++
                    "  Stop it and launch this workspace's probe? [y/N] ",
                .{},
            );
            var answer: [16]u8 = undefined;
            const n = std.posix.read(std.posix.STDIN_FILENO, &answer) catch return false;
            return isYes(answer[0..n]);
        },
    }
}

/// Elapsed time as toybox `ps` prints it (`7-01:35:12`), or `?`.
fn probeUptime(
    gpa: std.mem.Allocator,
    io: std.Io,
    serial: []const u8,
    pid: []const u8,
    buf: *[32]u8,
) []const u8 {
    var command_buf: [64]u8 = undefined;
    // One argv element: `adb shell` joins its arguments unquoted.
    const command = std.fmt.bufPrint(&command_buf, "ps -o ETIME= -p {s}", .{pid}) catch return "?";
    const output = deviceOutput(gpa, io, &.{ "adb", "-s", serial, "shell", command }) catch return "?";
    defer gpa.free(output);
    const text = std.mem.trim(u8, output, " \t\r\n");
    if (text.len == 0 or text.len > buf.len) return "?";
    @memcpy(buf[0..text.len], text);
    return buf[0..text.len];
}

/// Only an explicit yes stops another workspace's probe. Empty input,
/// EOF, and anything unrecognised are a no.
fn isYes(answer: []const u8) bool {
    const word = std.mem.trim(u8, answer, " \t\r\n");
    return std.ascii.eqlIgnoreCase(word, "y") or std.ascii.eqlIgnoreCase(word, "yes");
}

test "only an explicit yes stops another workspace's probe" {
    try std.testing.expect(isYes("y\n"));
    try std.testing.expect(isYes("YES\r\n"));
    try std.testing.expect(isYes("  yes "));
    // Enter alone takes the default, which is to leave it running.
    try std.testing.expect(!isYes("\n"));
    try std.testing.expect(!isYes(""));
    try std.testing.expect(!isYes("n\n"));
    try std.testing.expect(!isYes("yep\n"));
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
    /// Its executable. Empty when `ps` does not say: a bare `zzzprobe`
    /// with no `--engine`, or a path too long to hold.
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
    found: ?RunningProbe,
    probe_path: []const u8,
    engine_path: []const u8,
) Reuse {
    const running = found orelse return .replace_unverifiable;

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
    const ps = devicePs(gpa, io, serial) orelse return null;
    defer gpa.free(ps);

    // `path` is written into the caller's buffer; `pid` still slices
    // `ps`, which the defer above frees as this returns, so it is
    // copied out too. Returning a borrow of freed stdout was a
    // use-after-free the caller had no way to see.
    // An engine path too long to copy is unknown, not "no probe": the
    // process is still there, and still holds the port.
    const found = runningProbeLine(ps, device_endpoint, &buf.path) orelse return null;
    const engine = if (found.engine.len <= buf.engine.len) found.engine else "";
    @memcpy(buf.pid[0..found.pid.len], found.pid);
    @memcpy(buf.engine[0..engine.len], engine);
    return .{
        .pid = buf.pid[0..found.pid.len],
        .path = found.path,
        .engine = buf.engine[0..engine.len],
    };
}

/// The device's `ps -A -o PID,ARGS`, or null when it cannot be read.
/// The caller frees it.
fn devicePs(gpa: std.mem.Allocator, io: std.Io, serial: []const u8) ?[]u8 {
    // One argv element for the whole remote command: `adb shell` joins
    // its arguments with no quoting, so a multi-word command passed as
    // separate arguments silently does the wrong thing on device.
    const result = std.process.run(gpa, io, .{
        .argv = &.{ "adb", "-s", serial, "shell", "ps -A -o PID,ARGS" },
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(64 * 1024),
    }) catch return null;
    gpa.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) {
        gpa.free(result.stdout);
        return null;
    }
    return result.stdout;
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
    var probes: ProbeLines = .init(ps_output, endpoint, buf);
    return probes.next();
}

/// Every `ps` row for a probe advertising `endpoint`, in order. A row
/// whose executable cannot be recovered — a bare `zzzprobe` with no
/// `--engine`, or a path longer than `buf` — still comes back, with an
/// empty `path`: it is still a process that may hold the port, and
/// dropping it made a busy one invisible. `path` lives in `buf` until
/// the next call.
const ProbeLines = struct {
    lines: std.mem.TokenIterator(u8, .scalar),
    endpoint: []const u8,
    buf: []u8,

    fn init(ps_output: []const u8, endpoint: []const u8, buf: []u8) ProbeLines {
        return .{ .lines = std.mem.tokenizeScalar(u8, ps_output, '\n'), .endpoint = endpoint, .buf = buf };
    }

    fn next(self: *ProbeLines) ?RunningProbe {
        while (self.lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            var fields = std.mem.tokenizeScalar(u8, line, ' ');
            // All digits, not just the first: the pid ends up in an
            // `adb shell kill` command line, which adb joins unquoted.
            const pid = fields.next() orelse continue;
            if (!isPid(pid)) continue;
            const argv0 = fields.next() orelse continue;
            const is_probe = std.mem.eql(u8, argv0, "zzzprobe") or
                std.mem.endsWith(u8, argv0, "/zzzprobe");
            if (!is_probe) continue;

            // The probe's first argument is its endpoint.
            const arg_endpoint = fields.next() orelse continue;
            if (!std.mem.eql(u8, arg_endpoint, self.endpoint)) continue;

            // `--engine` is wanted either way: as the probe's location
            // when argv[0] is bare, and always as the engine to verify.
            var engine: []const u8 = "";
            var rest = fields;
            while (rest.next()) |field| {
                if (!std.mem.eql(u8, field, "--engine")) continue;
                engine = rest.next() orelse "";
                break;
            }
            return .{ .pid = pid, .path = self.probePath(argv0, engine), .engine = engine };
        }
        return null;
    }

    /// A hand-launched probe carries its path as argv[0]. One launched
    /// through `nohup` inside `sh -c` reports a bare argv[0], and its
    /// `--engine` names the directory it lives in. Empty when neither.
    fn probePath(self: *ProbeLines, argv0: []const u8, engine: []const u8) []const u8 {
        if (std.mem.indexOfScalar(u8, argv0, '/') != null) {
            return std.fmt.bufPrint(self.buf, "{s}", .{argv0}) catch "";
        }
        const dir = std.fs.path.dirname(engine) orelse return "";
        return std.fmt.bufPrint(self.buf, "{s}/zzzprobe", .{dir}) catch "";
    }
};

/// Bounded as well as numeric, so every pid fits `ProbeBuffers.pid`;
/// Linux tops out at 4194304.
fn isPid(field: []const u8) bool {
    if (field.len == 0 or field.len > 10) return false;
    for (field) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
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

    // Nothing to find.
    try std.testing.expectEqual(
        @as(?RunningProbe, null),
        runningProbeLine("  PID ARGS\n 1 /system/bin/init\n", device_endpoint, &buf),
    );
    // A bare name with no `--engine` to locate it by is still a probe on
    // the port — just one whose executable is unknown. Dropping it made a
    // busy one invisible, and the launch that followed died on bind.
    const bare = runningProbeLine(" 12 zzzprobe tcp:7779\n", device_endpoint, &buf).?;
    try std.testing.expectEqualStrings("12", bare.pid);
    try std.testing.expectEqualStrings("", bare.path);
    const long = runningProbeLine(" 13 /" ++ "x" ** 300 ++ "/zzzprobe tcp:7779\n", device_endpoint, &buf).?;
    try std.testing.expectEqualStrings("13", long.pid);
    try std.testing.expectEqualStrings("", long.path);
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
    // `zzz`, not `zzzprobe`: the engine a run spawned lives in the same
    // root, and outlives a probe killed underneath it. The `/` after the
    // root keeps `zzz-abc-backup` out, and `[z]` keeps this command's own
    // `sh -c` from matching.
    const command = try std.fmt.allocPrint(
        gpa,
        "pkill -f '{s}/[z]zz' >/dev/null 2>&1 || true",
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
