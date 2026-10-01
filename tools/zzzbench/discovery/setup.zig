//! Orchestrates discovery selection and transport preparation, then
//! composes the result with explicit/manual endpoints for the existing
//! dashboard session shape.

const std = @import("std");

const cli = @import("../cli.zig");
const picker = @import("../device_picker.zig");
const device_comparison = @import("../device_comparison.zig");
const Peer = @import("../peer.zig").Peer;
const bootstrap_android = @import("bootstrap_android.zig");
const catalog = @import("catalog.zig");
const device = @import("device.zig");
const wire = @import("../wire.zig");
const model_sync = @import("../model_sync.zig");

pub const Result = struct {
    endpoint: []const u8,
    peer_count: usize,
    discovered_count: usize,
    bootstrapped_count: usize,
    model_targets: [picker.max_selected]model_sync.Target,
    model_target_count: usize,
};

pub const Target = struct {
    label: []const u8,
    endpoint: []const u8,
    model: model_sync.Target = .{ .kind = .unsupported },
};

pub fn run(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    io: std.Io,
    workspace_path: []const u8,
    opts: cli.Options,
    peer_buf: []Peer,
) !Result {
    var search_status = picker.SearchStatus.begin(searchScope(opts.platform));
    defer search_status.clear();
    const candidates = try catalog.scan(gpa, arena, io, catalogFilter(opts.platform));
    search_status.clear();
    if (candidates.len == 0 and !allowsEmptyDiscovery(opts)) return error.NoDevices;
    const picked: picker.Selection = if (candidates.len == 0)
        .{}
    else if (opts.devices.len > 0)
        try picker.selectByIds(candidates, opts.devices)
    else if (opts.select_all)
        picker.selectAll(candidates)
    else
        try picker.interactive(candidates);
    // The local runner writes the primary's results. Use the same ordering
    // at startup as the dashboard's device picker, even with phone-first IDs.
    const selection = device_comparison.hostFirst(candidates, picked);
    const total_targets = targetCount(selection.len, opts.peer_count, opts.explicit_endpoint);
    if (total_targets > picker.max_selected) return error.TooManyDevices;
    if (opts.select_all and candidates.len > picker.max_selected) {
        std.debug.print(
            "zzzbench: {d} devices found; --all uses the first {d} (dashboard limit)\n",
            .{ candidates.len, picker.max_selected },
        );
    }

    var prepared: [picker.max_selected]Target = undefined;
    var prepared_len: usize = 0;
    var bootstrapped: usize = 0;
    const foreign = foreignProbePolicy(
        opts.replace_probe,
        std.c.isatty(std.posix.STDIN_FILENO) != 0 and std.c.isatty(std.posix.STDERR_FILENO) != 0,
    );
    for (selection.indices[0..selection.len]) |index| {
        const candidate = candidates[index];
        const target = try prepareCandidate(
            gpa,
            arena,
            io,
            workspace_path,
            candidate,
            &bootstrapped,
            foreign,
        );
        prepared[prepared_len] = target;
        prepared_len += 1;
    }

    const manual_count = opts.peer_count;
    var manual: [cli.max_peers]Target = undefined;
    for (peer_buf[0..manual_count], 0..) |peer, index| {
        manual[index] = .{ .label = peer.label, .endpoint = peer.endpoint };
    }
    const assembled = try compose(
        if (opts.explicit_endpoint) .{ .label = "primary", .endpoint = opts.endpoint } else null,
        prepared[0..prepared_len],
        manual[0..manual_count],
        peer_buf,
    );
    return .{
        .endpoint = assembled.endpoint,
        .peer_count = assembled.peer_count,
        .discovered_count = prepared_len,
        .bootstrapped_count = bootstrapped,
        .model_targets = assembled.model_targets,
        .model_target_count = assembled.model_target_count,
    };
}

/// Startup runs in the operator's normal terminal, so a foreign probe
/// can be asked about there. Without one — a script, CI —
/// nobody can answer, and the safe answer is to leave it running.
pub fn foreignProbePolicy(replace_probe: bool, interactive: bool) bootstrap_android.ForeignProbe {
    if (replace_probe) return .replace;
    return if (interactive) .ask else .refuse;
}

test "a foreign probe is stopped only when someone said so" {
    try std.testing.expectEqual(bootstrap_android.ForeignProbe.replace, foreignProbePolicy(true, false));
    try std.testing.expectEqual(bootstrap_android.ForeignProbe.replace, foreignProbePolicy(true, true));
    try std.testing.expectEqual(bootstrap_android.ForeignProbe.ask, foreignProbePolicy(false, true));
    try std.testing.expectEqual(bootstrap_android.ForeignProbe.refuse, foreignProbePolicy(false, false));
}

fn allowsEmptyDiscovery(opts: cli.Options) bool {
    return opts.explicit_endpoint or opts.peer_count > 0;
}

fn searchScope(filter: cli.PlatformFilter) []const u8 {
    return switch (filter) {
        .all => "Android · iOS · this Mac",
        .android => "Android",
        .ios => "iOS",
        .host => "this Mac",
    };
}

fn targetCount(discovered: usize, manual: usize, has_explicit_primary: bool) usize {
    return discovered + manual + @intFromBool(has_explicit_primary);
}

pub fn prepareCandidate(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    io: std.Io,
    workspace_path: []const u8,
    candidate: device.Candidate,
    bootstrapped: *usize,
    foreign: bootstrap_android.ForeignProbe,
) !Target {
    switch (candidate.platform) {
        .host => {
            try prepareHost(gpa, io, workspace_path, candidate.endpoint);
            return .{
                .label = candidate.name,
                .endpoint = candidate.endpoint,
                .model = .{ .kind = .host, .id = candidate.id },
            };
        },
        .ios => {
            if (candidate.probe_state != .live) {
                std.debug.print(
                    "zzzbench: {s} probe app is not reachable; launch it on the unlocked device\n",
                    .{candidate.name},
                );
            }
            return .{ .label = candidate.name, .endpoint = candidate.endpoint };
        },
        .android => {},
    }
    std.debug.print("zzzbench: preparing {s} ({s}) via adb\n", .{ candidate.name, candidate.id });
    const result = try bootstrap_android.prepare(
        gpa,
        arena,
        io,
        workspace_path,
        candidate.id,
        foreign,
    );
    if (result.bootstrapped) bootstrapped.* += 1;
    return .{
        .label = candidate.name,
        .endpoint = result.endpoint,
        .model = .{ .kind = .android, .id = candidate.id },
    };
}

fn prepareHost(
    gpa: std.mem.Allocator,
    io: std.Io,
    workspace_path: []const u8,
    endpoint: []const u8,
) !void {
    if (wire.probeHealthy(endpoint)) return;
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe_len = try std.process.executablePath(io, &exe_buf);
    const exe_dir = std.fs.path.dirname(exe_buf[0..exe_len]) orelse ".";
    const configured = std.c.getenv("ZZZBENCH_PROBE_BIN");
    const probe_path = if (configured) |path|
        try gpa.dupe(u8, std.mem.span(path))
    else
        try std.fs.path.join(gpa, &.{ exe_dir, "zzzprobe" });
    defer gpa.free(probe_path);
    _ = workspace_path;
    std.Io.Dir.cwd().access(io, probe_path, .{ .execute = true }) catch {
        std.debug.print("zzzbench: supply a host probe beside zzzbench or set ZZZBENCH_PROBE_BIN ({s})\n", .{probe_path});
        return error.HostProbeMissing;
    };
    // Spawn directly rather than through `sh ... &`: the run helper
    // can reap the shell's process tree after returning. No inherited
    // terminal descriptors and a fresh process group make this daemon
    // independent of the bench TUI.
    _ = try std.process.spawn(io, .{
        .argv = &.{ probe_path, endpoint, "--allow-exec" },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
        .pgid = 0,
    });

    var attempt: usize = 0;
    while (attempt < 20) : (attempt += 1) {
        std.Io.sleep(io, .fromMilliseconds(25), .awake) catch {};
        if (wire.probeHealthy(endpoint)) return;
    }
    return error.HostProbeBootstrapFailed;
}

pub fn catalogFilter(filter: cli.PlatformFilter) catalog.Filter {
    return switch (filter) {
        .all => .all,
        .android => .android,
        .ios => .ios,
        .host => .host,
    };
}

const Composed = struct {
    endpoint: []const u8,
    peer_count: usize,
    model_targets: [picker.max_selected]model_sync.Target = @splat(.{ .kind = .unsupported }),
    model_target_count: usize = 0,
};

fn compose(explicit: ?Target, discovered: []const Target, manual: []const Target, peers: []Peer) !Composed {
    var endpoint: []const u8 = "";
    var model_targets: [picker.max_selected]model_sync.Target = @splat(.{ .kind = .unsupported });
    var model_target_count: usize = 0;
    var next_discovered: usize = 0;
    var next_manual: usize = 0;
    if (explicit) |target| {
        endpoint = target.endpoint;
        model_targets[model_target_count] = target.model;
        model_target_count += 1;
    } else if (discovered.len > 0) {
        endpoint = discovered[0].endpoint;
        model_targets[model_target_count] = discovered[0].model;
        model_target_count += 1;
        next_discovered = 1;
    } else if (manual.len > 0) {
        endpoint = manual[0].endpoint;
        model_targets[model_target_count] = manual[0].model;
        model_target_count += 1;
        next_manual = 1;
    } else {
        return error.NoDevices;
    }

    var peer_count: usize = 0;
    for (discovered[next_discovered..]) |target| {
        if (peer_count == peers.len) return error.TooManyDevices;
        peers[peer_count] = .{ .label = target.label, .endpoint = target.endpoint };
        peer_count += 1;
        model_targets[model_target_count] = target.model;
        model_target_count += 1;
    }
    for (manual[next_manual..]) |target| {
        if (peer_count == peers.len) return error.TooManyDevices;
        peers[peer_count] = .{ .label = target.label, .endpoint = target.endpoint };
        peer_count += 1;
        model_targets[model_target_count] = target.model;
        model_target_count += 1;
    }
    return .{
        .endpoint = endpoint,
        .peer_count = peer_count,
        .model_targets = model_targets,
        .model_target_count = model_target_count,
    };
}

test "discovered primary and manual peers compose in order" {
    var peers: [cli.max_peers]Peer = undefined;
    const result = try compose(null, &.{
        .{ .label = "pixel", .endpoint = "tcp:1" },
        .{ .label = "iphone", .endpoint = "tcp:2" },
    }, &.{.{ .label = "pi", .endpoint = "tcp:3" }}, &peers);
    try std.testing.expectEqualStrings("tcp:1", result.endpoint);
    try std.testing.expectEqual(@as(usize, 2), result.peer_count);
    try std.testing.expectEqualStrings("iphone", peers[0].label);
    try std.testing.expectEqualStrings("pi", peers[1].label);
}

test "explicit endpoint remains primary when auto discovery is mixed in" {
    var peers: [cli.max_peers]Peer = undefined;
    const result = try compose(
        .{ .label = "primary", .endpoint = "tcp:9000" },
        &.{.{ .label = "pixel", .endpoint = "tcp:1" }},
        &.{},
        &peers,
    );
    try std.testing.expectEqualStrings("tcp:9000", result.endpoint);
    try std.testing.expectEqualStrings("pixel", peers[0].label);
}

test "explicit endpoint survives empty discovery" {
    var peers: [cli.max_peers]Peer = undefined;
    const result = try compose(
        .{ .label = "primary", .endpoint = "tcp:9000" },
        &.{},
        &.{},
        &peers,
    );
    try std.testing.expectEqualStrings("tcp:9000", result.endpoint);
    try std.testing.expectEqual(@as(usize, 0), result.peer_count);
}

test "manual peer becomes primary when discovery is empty" {
    var peers: [cli.max_peers]Peer = undefined;
    const result = try compose(
        null,
        &.{},
        &.{
            .{ .label = "pi", .endpoint = "tcp:3" },
            .{ .label = "lab", .endpoint = "tcp:4" },
        },
        &peers,
    );
    try std.testing.expectEqualStrings("tcp:3", result.endpoint);
    try std.testing.expectEqual(@as(usize, 1), result.peer_count);
    try std.testing.expectEqualStrings("lab", peers[0].label);
}

test "manual targets allow an empty discovery result" {
    var opts: cli.Options = .{};
    try std.testing.expect(!allowsEmptyDiscovery(opts));
    opts.explicit_endpoint = true;
    try std.testing.expect(allowsEmptyDiscovery(opts));
    opts.explicit_endpoint = false;
    opts.peer_count = 1;
    try std.testing.expect(allowsEmptyDiscovery(opts));
}

test "composition rejects more targets than the dashboard can render" {
    var peers: [1]Peer = undefined;
    try std.testing.expectError(error.TooManyDevices, compose(
        .{ .label = "primary", .endpoint = "tcp:0" },
        &.{
            .{ .label = "one", .endpoint = "tcp:1" },
            .{ .label = "two", .endpoint = "tcp:2" },
        },
        &.{},
        &peers,
    ));
}

test "preflight target count includes an explicit primary" {
    try std.testing.expectEqual(@as(usize, 5), targetCount(3, 1, true));
    try std.testing.expectEqual(@as(usize, 4), targetCount(3, 1, false));
}
