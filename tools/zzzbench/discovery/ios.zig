//! `--auto-ios`: discover paired physical iOS devices via CoreDevice
//! (`xcrun devicectl`) and connect to a zzzprobe-compatible app on
//! each over its CoreDevice hostname.
//!
//! Unlike Android there is no adb-style port forward here: the iOS
//! probe app must already be installed, launched, and listening.

const std = @import("std");
const tui = @import("tuiz");

const device = @import("device.zig");
const Peer = @import("../peer.zig").Peer;

/// On-device port the iOS probe app is expected to listen on.
/// Deliberately matches zzzprobe's default and Android's device port.
pub const device_port: u16 = 7779;

pub const Setup = struct {
    primary_endpoint: []const u8,
    peer_count: usize,
};

const Device = struct {
    label: []const u8,
    hostname: []const u8,
    identifier: []const u8,
};

/// Inventory-only iOS discovery. The probe app is never launched here;
/// CoreDevice discovery is read-only and selection remains side-effect free.
pub fn scan(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    io: std.Io,
) ![]device.Candidate {
    const stdout = try listDevicesJson(gpa, io);
    defer gpa.free(stdout);
    const found = try parseDevices(gpa, stdout);
    defer freeDevices(gpa, found);

    var candidates: std.ArrayListUnmanaged(device.Candidate) = .empty;
    defer candidates.deinit(gpa);
    for (found) |entry| {
        try candidates.append(gpa, .{
            .platform = .ios,
            .id = try arena.dupe(u8, entry.identifier),
            .name = try arena.dupe(u8, entry.label),
            .transport = "coredevice",
            .transport_state = "paired",
            .endpoint = try std.fmt.allocPrint(arena, "tcp:{s}:{d}", .{ entry.hostname, device_port }),
        });
    }
    return try arena.dupe(device.Candidate, candidates.items);
}

/// The subset of `devicectl list devices --json-output` we read.
/// Field names mirror the JSON, so they intentionally break the Zig
/// naming convention.
const DevicectlList = struct {
    result: Result = .{},

    const Result = struct {
        devices: []Device_ = &.{},
    };

    const Device_ = struct {
        identifier: []const u8 = "",
        connectionProperties: ConnectionProperties = .{},
        deviceProperties: DeviceProperties = .{},
        hardwareProperties: HardwareProperties = .{},
    };

    const ConnectionProperties = struct {
        pairingState: []const u8 = "",
        potentialHostnames: []const []const u8 = &.{},
        tunnelState: []const u8 = "",
    };

    const DeviceProperties = struct {
        name: []const u8 = "",
    };

    const HardwareProperties = struct {
        platform: []const u8 = "",
        productType: []const u8 = "",
        reality: []const u8 = "",
    };
};

pub fn discover(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    io: std.Io,
    peer_buf: []Peer,
) !Setup {
    const devices_stdout = try listDevicesJson(gpa, io);
    defer gpa.free(devices_stdout);

    const discovered = try parseDevices(gpa, devices_stdout);
    defer freeDevices(gpa, discovered);
    if (discovered.len == 0) {
        std.debug.print("zzzbench: --auto-ios: no paired physical iOS devices found (try `xcrun devicectl list devices` directly)\n", .{});
        return error.NoDevices;
    }

    const max_devices = peer_buf.len + 1;
    const used = @min(discovered.len, max_devices);
    if (discovered.len > max_devices) {
        std.debug.print("zzzbench: --auto-ios: {d} devices found, capping at {d} (bench's per-window peer limit)\n", .{ discovered.len, max_devices });
    }
    std.debug.print("zzzbench: discovered {d} iOS device{s} via devicectl\n", .{ used, if (used == 1) @as([]const u8, "") else @as([]const u8, "s") });
    std.debug.print("zzzbench: --auto-ios expects a zzzprobe-compatible iOS app already listening on device port {d}\n", .{device_port});

    var primary_endpoint: []const u8 = "";
    var peers_used: usize = 0;
    for (discovered[0..used]) |dev| {
        const endpoint = try std.fmt.allocPrint(arena, "tcp:{s}:{d}", .{ dev.hostname, device_port });
        const label = try arena.dupe(u8, dev.label);
        if (primary_endpoint.len == 0) {
            primary_endpoint = endpoint;
            std.debug.print("zzzbench:   primary  {s}  -> {s}\n", .{ label, endpoint });
        } else if (peers_used < peer_buf.len) {
            peer_buf[peers_used] = .{ .label = label, .endpoint = endpoint };
            peers_used += 1;
            std.debug.print("zzzbench:   peer     {s}  -> {s}\n", .{ label, endpoint });
        }
    }

    return .{ .primary_endpoint = primary_endpoint, .peer_count = peers_used };
}

fn freeDevices(allocator: std.mem.Allocator, devices: []Device) void {
    for (devices) |dev| {
        allocator.free(dev.label);
        allocator.free(dev.hostname);
        allocator.free(dev.identifier);
    }
    allocator.free(devices);
}

fn parseDevices(allocator: std.mem.Allocator, output: []const u8) ![]Device {
    const parsed = try std.json.parseFromSlice(DevicectlList, allocator, output, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    var devices: std.ArrayListUnmanaged(Device) = .empty;
    errdefer {
        for (devices.items) |dev| {
            allocator.free(dev.label);
            allocator.free(dev.hostname);
            allocator.free(dev.identifier);
        }
        devices.deinit(allocator);
    }

    for (parsed.value.result.devices) |dev| {
        if (!std.mem.eql(u8, dev.hardwareProperties.platform, "iOS")) continue;
        if (dev.hardwareProperties.reality.len > 0 and !std.mem.eql(u8, dev.hardwareProperties.reality, "physical")) continue;
        if (dev.connectionProperties.pairingState.len > 0 and !std.mem.eql(u8, dev.connectionProperties.pairingState, "paired")) continue;
        // `disconnected` only means CoreDevice has not opened its own
        // tunnel; zzzbench connects through the advertised hostname.
        if (std.mem.eql(u8, dev.connectionProperties.tunnelState, "unavailable")) continue;
        if (dev.connectionProperties.potentialHostnames.len == 0) continue;

        const label_src = if (dev.deviceProperties.name.len > 0)
            dev.deviceProperties.name
        else if (dev.hardwareProperties.productType.len > 0)
            dev.hardwareProperties.productType
        else
            dev.identifier;
        const identifier_src = if (dev.identifier.len > 0) dev.identifier else label_src;

        // Filtered at ingress rather than at each print: these strings
        // are user-set device names off an untrusted device, and they
        // go on to be rendered on every dashboard frame.
        var label_buf: [128]u8 = undefined;
        var hostname_buf: [256]u8 = undefined;
        var identifier_buf: [128]u8 = undefined;
        try devices.append(allocator, .{
            .label = try allocator.dupe(u8, tui.sanitize.into(&label_buf, label_src)),
            .hostname = try allocator.dupe(u8, tui.sanitize.into(
                &hostname_buf,
                dev.connectionProperties.potentialHostnames[0],
            )),
            .identifier = try allocator.dupe(u8, tui.sanitize.into(&identifier_buf, identifier_src)),
        });
    }

    return try devices.toOwnedSlice(allocator);
}

/// CoreDevice sometimes needs a retry right after the phone is
/// reconnected or unlocked, so this retries before reporting failure.
fn listDevicesJson(gpa: std.mem.Allocator, io: std.Io) ![]u8 {
    const max_attempts = 3;
    var last_stdout: ?[]u8 = null;
    var last_stderr: ?[]u8 = null;
    defer if (last_stdout) |s| gpa.free(s);
    defer if (last_stderr) |s| gpa.free(s);

    var attempt: usize = 0;
    while (attempt < max_attempts) : (attempt += 1) {
        const devices_res = std.process.run(gpa, io, .{
            .argv = &.{ "xcrun", "devicectl", "-q", "list", "devices", "--json-output", "-" },
            .stdout_limit = .limited(256 * 1024),
            .stderr_limit = .limited(16 * 1024),
        }) catch |e| {
            std.debug.print("zzzbench: --auto-ios requires Xcode's `xcrun devicectl` ({s})\n", .{@errorName(e)});
            return error.DevicectlMissing;
        };

        if (devices_res.term == .exited and devices_res.term.exited == 0) {
            if (last_stdout) |s| {
                gpa.free(s);
                last_stdout = null;
            }
            if (last_stderr) |s| {
                gpa.free(s);
                last_stderr = null;
            }
            gpa.free(devices_res.stderr);
            return devices_res.stdout;
        }

        if (last_stdout) |s| gpa.free(s);
        if (last_stderr) |s| gpa.free(s);
        last_stdout = devices_res.stdout;
        last_stderr = devices_res.stderr;
    }

    // devicectl's output is relayed to the user's terminal, and it can
    // quote a device-supplied name — filtered, and bounded so a large
    // JSON dump can't flood the screen.
    var relay_buf: [512]u8 = undefined;
    const stderr = if (last_stderr) |s| std.mem.trim(u8, s, " \t\r\n") else "";
    const stdout = if (last_stdout) |s| std.mem.trim(u8, s, " \t\r\n") else "";
    if (stderr.len > 0) {
        std.debug.print("zzzbench: `xcrun devicectl list devices` failed after {d} attempts (stderr: {s})\n", .{
            max_attempts, tui.sanitize.into(&relay_buf, stderr),
        });
    } else if (stdout.len > 0) {
        std.debug.print("zzzbench: `xcrun devicectl list devices` failed after {d} attempts (stdout: {s})\n", .{
            max_attempts, tui.sanitize.into(&relay_buf, stdout),
        });
    } else {
        std.debug.print("zzzbench: `xcrun devicectl list devices` failed after {d} attempts with no stdout/stderr\n", .{max_attempts});
    }
    std.debug.print("zzzbench: try `xcrun devicectl list devices` directly; CoreDevice sometimes needs a retry after reconnecting/unlocking the iPhone\n", .{});
    return error.DevicectlDevicesFailed;
}

test "parseDevices keeps paired physical iOS devices with hostnames" {
    const input =
        \\{
        \\  "result": {
        \\    "devices": [
        \\      {
        \\        "identifier": "watch-id",
        \\        "connectionProperties": {"pairingState": "paired", "potentialHostnames": ["watch.coredevice.local"]},
        \\        "deviceProperties": {"name": "Watch"},
        \\        "hardwareProperties": {"platform": "watchOS", "productType": "Watch5,10", "reality": "physical"}
        \\      },
        \\      {
        \\        "identifier": "iphone-id",
        \\        "connectionProperties": {"pairingState": "paired", "potentialHostnames": ["iphone.coredevice.local"]},
        \\        "deviceProperties": {"name": "iPhone Pro"},
        \\        "hardwareProperties": {"platform": "iOS", "productType": "iPhone15,2", "reality": "physical"}
        \\      },
        \\      {
        \\        "identifier": "sim-id",
        \\        "connectionProperties": {"pairingState": "paired", "potentialHostnames": ["sim.coredevice.local"]},
        \\        "deviceProperties": {"name": "Simulator"},
        \\        "hardwareProperties": {"platform": "iOS", "productType": "iPhone17,1", "reality": "virtual"}
        \\      }
        \\    ]
        \\  }
        \\}
    ;
    const allocator = std.testing.allocator;
    const devices = try parseDevices(allocator, input);
    defer freeDevices(allocator, devices);
    try std.testing.expectEqual(@as(usize, 1), devices.len);
    try std.testing.expectEqualStrings("iPhone Pro", devices[0].label);
    try std.testing.expectEqualStrings("iphone.coredevice.local", devices[0].hostname);
    try std.testing.expectEqualStrings("iphone-id", devices[0].identifier);
}

test "parseDevices preserves CoreDevice iPad hostname" {
    const input =
        \\{
        \\  "result": {
        \\    "devices": [
        \\      {
        \\        "identifier": "ipad-id",
        \\        "connectionProperties": {"pairingState": "paired", "potentialHostnames": ["ipad.coredevice.local"]},
        \\        "deviceProperties": {"name": "iPad Pro"},
        \\        "hardwareProperties": {"platform": "iOS", "productType": "iPad14,3", "reality": "physical"}
        \\      }
        \\    ]
        \\  }
        \\}
    ;
    const allocator = std.testing.allocator;
    const devices = try parseDevices(allocator, input);
    defer freeDevices(allocator, devices);
    try std.testing.expectEqual(@as(usize, 1), devices.len);
    try std.testing.expectEqualStrings("iPad Pro", devices[0].label);
    try std.testing.expectEqualStrings("ipad.coredevice.local", devices[0].hostname);
    try std.testing.expectEqualStrings("ipad-id", devices[0].identifier);
}

test "parseDevices keeps wired iOS devices when the CoreDevice tunnel is disconnected" {
    const input =
        \\{
        \\  "result": {
        \\    "devices": [
        \\      {
        \\        "identifier": "ipad-id",
        \\        "connectionProperties": {
        \\          "pairingState": "paired",
        \\          "potentialHostnames": ["ipad.coredevice.local"],
        \\          "tunnelState": "unavailable"
        \\        },
        \\        "deviceProperties": {"developerModeStatus": "enabled", "name": "iPad Pro"},
        \\        "hardwareProperties": {"platform": "iOS", "productType": "iPad14,3", "reality": "physical"}
        \\      },
        \\      {
        \\        "identifier": "iphone-id",
        \\        "connectionProperties": {
        \\          "pairingState": "paired",
        \\          "potentialHostnames": ["iphone.coredevice.local"],
        \\          "transportType": "wired",
        \\          "tunnelState": "disconnected"
        \\        },
        \\        "deviceProperties": {"bootState": "booted", "developerModeStatus": "enabled", "name": "iPhone Pro"},
        \\        "hardwareProperties": {"platform": "iOS", "productType": "iPhone15,2", "reality": "physical"}
        \\      }
        \\    ]
        \\  }
        \\}
    ;
    const allocator = std.testing.allocator;
    const devices = try parseDevices(allocator, input);
    defer freeDevices(allocator, devices);
    try std.testing.expectEqual(@as(usize, 1), devices.len);
    try std.testing.expectEqualStrings("iPhone Pro", devices[0].label);
    try std.testing.expectEqualStrings("iphone.coredevice.local", devices[0].hostname);
    try std.testing.expectEqualStrings("iphone-id", devices[0].identifier);
}
