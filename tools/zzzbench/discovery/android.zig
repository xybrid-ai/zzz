//! `--auto-android`: discover attached devices via `adb devices`, set
//! up one `adb forward` per device, and hand back a primary endpoint
//! plus filled-in peers.
//!
//! Replaces the multi-terminal `adb -s SERIAL forward …` + `--probe
//! LABEL:ENDPOINT` ritual.

const std = @import("std");
const tui = @import("tuiz");

const device = @import("device.zig");
const Peer = @import("../peer.zig").Peer;

/// On-device port the probe is expected to listen on. Matches
/// zzzprobe's default. A per-device override would be a flag if
/// anyone needed one; auto-discovery assumes the probe was started
/// here.
pub const device_port: u16 = 7779;

pub const Setup = struct {
    primary_endpoint: []const u8,
    peer_count: usize,
};

/// One line of `adb devices`. Kept whole (including unusable states)
/// so the parser stays pure and `discover` owns the reporting.
const Entry = struct {
    serial: []const u8,
    state: []const u8,
    model: []const u8 = "",

    fn usable(self: Entry) bool {
        return std.mem.eql(u8, self.state, "device");
    }
};

/// Inventory-only Android discovery. Unlike `discover`, this does not
/// create forwards: selection must remain side-effect free.
pub fn scan(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    io: std.Io,
) ![]device.Candidate {
    const result = std.process.run(gpa, io, .{
        .argv = &.{ "adb", "devices", "-l" },
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(16 * 1024),
    }) catch return error.AdbMissing;
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) return error.AdbDevicesFailed;

    const entries = try parseEntries(gpa, result.stdout);
    defer gpa.free(entries);
    var candidates: std.ArrayListUnmanaged(device.Candidate) = .empty;
    defer candidates.deinit(gpa);
    try appendCandidates(gpa, arena, io, entries, &candidates);
    return try arena.dupe(device.Candidate, candidates.items);
}

fn appendCandidates(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    io: std.Io,
    entries: []const Entry,
    candidates: *std.ArrayListUnmanaged(device.Candidate),
) !void {
    for (entries) |entry| {
        var serial_buf: [128]u8 = undefined;
        var model_buf: [128]u8 = undefined;
        var state_buf: [32]u8 = undefined;
        const safe_serial = tui.sanitize.into(&serial_buf, entry.serial);
        const safe_model = tui.sanitize.into(&model_buf, if (entry.model.len > 0) entry.model else entry.serial);
        const safe_state = tui.sanitize.into(&state_buf, entry.state);
        const soc = if (entry.usable())
            getProp(gpa, arena, io, entry.serial, "ro.soc.model") catch ""
        else
            "";
        try candidates.append(gpa, .{
            .platform = .android,
            .id = try arena.dupe(u8, safe_serial),
            .name = try arena.dupe(u8, safe_model),
            .soc = soc,
            .transport = if (std.mem.indexOfScalar(u8, entry.serial, ':') != null) "adb-wifi" else "adb-usb",
            .transport_state = try arena.dupe(u8, safe_state),
            .selectable = entry.usable(),
            .probe_state = if (entry.usable()) probeState(gpa, io, entry.serial) else .unknown,
        });
    }
}

fn getProp(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    io: std.Io,
    serial: []const u8,
    key: []const u8,
) ![]const u8 {
    const result = try std.process.run(gpa, io, .{
        .argv = &.{ "adb", "-s", serial, "shell", "getprop", key },
        .stdout_limit = .limited(1024),
        .stderr_limit = .limited(1024),
    });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) return error.GetpropFailed;
    const value = std.mem.trim(u8, result.stdout, " \t\r\n");
    var safe_buf: [128]u8 = undefined;
    return try arena.dupe(u8, tui.sanitize.into(&safe_buf, value));
}

fn probeState(gpa: std.mem.Allocator, io: std.Io, serial: []const u8) device.ProbeState {
    const result = std.process.run(gpa, io, .{
        .argv = &.{ "adb", "-s", serial, "shell", "pidof", "zzzprobe" },
        .stdout_limit = .limited(1024),
        .stderr_limit = .limited(1024),
    }) catch return .unknown;
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    if (result.term != .exited) return .unknown;
    return if (result.term.exited == 0 and std.mem.trim(u8, result.stdout, " \t\r\n").len > 0) .live else .missing;
}

/// Shell out to adb, discover devices, set up `adb forward tcp:0
/// tcp:7779` per device (the kernel picks the host port). The first
/// device becomes primary; the rest fill `peer_buf` in discovery
/// order, up to the buffer's cap.
///
/// `gpa` is for transient work (the adb output, the parsed device
/// list) and is freed before return. The returned endpoint strings and
/// peer labels live for the whole program, so they come from `arena`
/// (process lifetime) — allocating them from `gpa` would have the
/// debug allocator flag them as leaks on quit.
pub fn discover(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    io: std.Io,
    peer_buf: []Peer,
) !Setup {
    const devices_res = std.process.run(gpa, io, .{
        .argv = &.{ "adb", "devices" },
        .stdout_limit = .limited(16 * 1024),
        .stderr_limit = .limited(16 * 1024),
    }) catch |e| {
        std.debug.print("zzzbench: --auto-android requires `adb` on PATH ({s})\n", .{@errorName(e)});
        return error.AdbMissing;
    };
    defer gpa.free(devices_res.stdout);
    defer gpa.free(devices_res.stderr);
    if (devices_res.term != .exited or devices_res.term.exited != 0) {
        std.debug.print("zzzbench: `adb devices` failed (stderr: {s})\n", .{devices_res.stderr});
        return error.AdbDevicesFailed;
    }

    const entries = try parseEntries(gpa, devices_res.stdout);
    defer gpa.free(entries);

    var usable: std.ArrayListUnmanaged(Entry) = .empty;
    defer usable.deinit(gpa);
    for (entries) |entry| {
        if (entry.usable()) {
            try usable.append(gpa, entry);
        } else {
            // Serials are device-supplied; stderr is a terminal.
            var serial_buf: [64]u8 = undefined;
            var state_buf: [32]u8 = undefined;
            std.debug.print("zzzbench:   skipping {s} (state={s})\n", .{
                tui.sanitize.into(&serial_buf, entry.serial),
                tui.sanitize.into(&state_buf, entry.state),
            });
        }
    }

    const discovered = usable.items;
    if (discovered.len == 0) {
        std.debug.print("zzzbench: --auto-android: no Android devices attached (try `adb devices` directly)\n", .{});
        return error.NoDevices;
    }

    const max_devices = peer_buf.len + 1; // primary + N peers
    const used = @min(discovered.len, max_devices);
    if (discovered.len > max_devices) {
        std.debug.print("zzzbench: --auto-android: {d} devices found, capping at {d} (bench's per-window peer limit)\n", .{ discovered.len, max_devices });
    }
    std.debug.print("zzzbench: discovered {d} device{s} via adb\n", .{ used, if (used == 1) @as([]const u8, "") else @as([]const u8, "s") });

    var primary_endpoint: []const u8 = "";
    var peers_used: usize = 0;
    for (discovered[0..used]) |dev| {
        var serial_buf: [64]u8 = undefined;
        const safe_serial = tui.sanitize.into(&serial_buf, dev.serial);
        const host_port = setupForward(gpa, io, dev.serial) catch |e| {
            std.debug.print("zzzbench:   skipping {s}: forward failed ({s})\n", .{ safe_serial, @errorName(e) });
            continue;
        };
        const endpoint = try std.fmt.allocPrint(arena, "tcp:{d}", .{host_port});
        // Filtered at ingress: the label outlives this function and is
        // rendered into the dashboard on every frame.
        const label = try arena.dupe(u8, safe_serial[0..@min(safe_serial.len, 8)]);
        if (primary_endpoint.len == 0) {
            primary_endpoint = endpoint;
            std.debug.print("zzzbench:   primary  {s: <8}  → tcp:{d} → device:{d}\n", .{ label, host_port, device_port });
        } else if (peers_used < peer_buf.len) {
            peer_buf[peers_used] = .{ .label = label, .endpoint = endpoint };
            peers_used += 1;
            std.debug.print("zzzbench:   peer     {s: <8}  → tcp:{d} → device:{d}\n", .{ label, host_port, device_port });
        }
    }

    if (primary_endpoint.len == 0) {
        std.debug.print("zzzbench: --auto-android: all device forwards failed\n", .{});
        return error.NoDevices;
    }

    return .{ .primary_endpoint = primary_endpoint, .peer_count = peers_used };
}

/// Parse the textual output of `adb devices` into one entry per
/// listed device, whatever its state. Returned slices alias the input
/// buffer; the caller decides when to copy them out.
fn parseEntries(allocator: std.mem.Allocator, output: []const u8) ![]Entry {
    var entries: std.ArrayListUnmanaged(Entry) = .empty;
    errdefer entries.deinit(allocator);
    var it = std.mem.splitScalar(u8, output, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        if (std.mem.eql(u8, trimmed, "List of devices attached")) continue;
        // adb separates SERIAL from STATE with a tab or spaces.
        const serial_end = std.mem.indexOfAny(u8, trimmed, " \t") orelse continue;
        const serial = trimmed[0..serial_end];
        const detail = std.mem.trim(u8, trimmed[serial_end..], " \t");
        if (detail.len == 0) continue;
        const state_end = std.mem.indexOfAny(u8, detail, " \t") orelse detail.len;
        const state = detail[0..state_end];
        const model = fieldValue(detail[state_end..], "model:") orelse "";
        if (serial.len == 0) continue;
        try entries.append(allocator, .{ .serial = serial, .state = state, .model = model });
    }
    return try entries.toOwnedSlice(allocator);
}

fn fieldValue(detail: []const u8, prefix: []const u8) ?[]const u8 {
    var fields = std.mem.tokenizeAny(u8, detail, " \t");
    while (fields.next()) |field| {
        if (std.mem.startsWith(u8, field, prefix) and field.len > prefix.len) return field[prefix.len..];
    }
    return null;
}

/// Run `adb -s SERIAL forward tcp:0 tcp:7779`; adb prints the
/// kernel-picked host port on stdout. Parse and return it.
pub fn setupForward(allocator: std.mem.Allocator, io: std.Io, serial: []const u8) !u16 {
    var device_port_buf: [16]u8 = undefined;
    const device_port_str = try std.fmt.bufPrint(&device_port_buf, "tcp:{d}", .{device_port});
    const res = try std.process.run(allocator, io, .{
        .argv = &.{ "adb", "-s", serial, "forward", "tcp:0", device_port_str },
        .stdout_limit = .limited(1024),
        .stderr_limit = .limited(1024),
    });
    defer allocator.free(res.stdout);
    defer allocator.free(res.stderr);
    // adb's own output is echoed back to the user's terminal, so it
    // gets the same filtering as anything else off the device.
    var serial_buf: [64]u8 = undefined;
    const safe_serial = tui.sanitize.into(&serial_buf, serial);
    if (res.term != .exited or res.term.exited != 0) {
        var err_buf: [512]u8 = undefined;
        std.debug.print("zzzbench:   adb forward failed for {s} (stderr: {s})\n", .{
            safe_serial,
            tui.sanitize.into(&err_buf, std.mem.trim(u8, res.stderr, " \n\r\t")),
        });
        return error.AdbForwardFailed;
    }
    const trimmed = std.mem.trim(u8, res.stdout, " \n\r\t");
    return std.fmt.parseInt(u16, trimmed, 10) catch {
        var out_buf: [128]u8 = undefined;
        std.debug.print("zzzbench:   adb forward returned unparseable port '{s}' for {s}\n", .{
            tui.sanitize.into(&out_buf, trimmed),
            safe_serial,
        });
        return error.AdbForwardUnparseable;
    };
}

test "parseEntries skips the header and blank lines, keeps every state" {
    const input =
        "List of devices attached\n" ++
        "TESTANDROID001\tdevice\n" ++
        "test0002\tdevice\n" ++
        "dead-beef-feed\tunauthorized\n" ++
        "offline-test\toffline\n" ++
        "192.0.2.42:5555\tdevice\n" ++
        "\n";
    const allocator = std.testing.allocator;
    const entries = try parseEntries(allocator, input);
    defer allocator.free(entries);

    try std.testing.expectEqual(@as(usize, 5), entries.len);
    var usable_count: usize = 0;
    for (entries) |e| {
        if (e.usable()) usable_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), usable_count);
    try std.testing.expectEqualStrings("TESTANDROID001", entries[0].serial);
    try std.testing.expect(!entries[2].usable());
    try std.testing.expectEqualStrings("unauthorized", entries[2].state);
    try std.testing.expectEqualStrings("192.0.2.42:5555", entries[4].serial);
}

test "parseEntries returns empty when no devices" {
    const input = "List of devices attached\n\n";
    const allocator = std.testing.allocator;
    const entries = try parseEntries(allocator, input);
    defer allocator.free(entries);
    try std.testing.expectEqual(@as(usize, 0), entries.len);
}

test "parseEntries reads adb long-list model without corrupting state" {
    const input =
        "List of devices attached\n" ++
        "TESTANDROID001\tdevice product:shiba model:Pixel_8 device:shiba transport_id:4\n";
    const entries = try parseEntries(std.testing.allocator, input);
    defer std.testing.allocator.free(entries);
    try std.testing.expect(entries[0].usable());
    try std.testing.expectEqualStrings("Pixel_8", entries[0].model);
}

test "parseEntries accepts space-separated adb long-list output" {
    const input =
        "List of devices attached\n" ++
        "TESTANDROID001         device usb:0-2 product:shiba model:Pixel_8 device:shiba transport_id:14\n" ++
        "test0002               device usb:1-1 product:PHONE01 model:PHONE01 device:TESTBOARD transport_id:13\n";
    const entries = try parseEntries(std.testing.allocator, input);
    defer std.testing.allocator.free(entries);

    try std.testing.expectEqual(@as(usize, 2), entries.len);
    try std.testing.expectEqualStrings("TESTANDROID001", entries[0].serial);
    try std.testing.expectEqualStrings("device", entries[0].state);
    try std.testing.expectEqualStrings("Pixel_8", entries[0].model);
    try std.testing.expectEqualStrings("test0002", entries[1].serial);
    try std.testing.expectEqualStrings("device", entries[1].state);
    try std.testing.expectEqualStrings("PHONE01", entries[1].model);
}

test "unauthorized and offline entries remain visible candidates" {
    const input =
        "List of devices attached\n" ++
        "locked-phone\tunauthorized model:Pixel_8\n" ++
        "sleeping-phone\toffline model:PHONE01\n";
    const entries = try parseEntries(std.testing.allocator, input);
    defer std.testing.allocator.free(entries);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var candidates: std.ArrayListUnmanaged(device.Candidate) = .empty;
    defer candidates.deinit(std.testing.allocator);
    try appendCandidates(std.testing.allocator, arena_state.allocator(), std.testing.io, entries, &candidates);

    try std.testing.expectEqual(@as(usize, 2), candidates.items.len);
    try std.testing.expectEqualStrings("unauthorized", candidates.items[0].transport_state);
    try std.testing.expect(!candidates.items[0].selectable);
    try std.testing.expectEqualStrings("offline", candidates.items[1].transport_state);
    try std.testing.expect(!candidates.items[1].selectable);
}
