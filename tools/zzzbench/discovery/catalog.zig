//! Unified, best-effort device inventory. A missing transport tool does
//! not hide devices from the other transports.

const std = @import("std");

const android = @import("android.zig");
const device = @import("device.zig");
const ios = @import("ios.zig");
const wire = @import("../wire.zig");

pub const Filter = enum { all, android, ios, host };

pub fn scan(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    io: std.Io,
    filter: Filter,
) ![]device.Candidate {
    var candidates: std.ArrayListUnmanaged(device.Candidate) = .empty;
    defer candidates.deinit(gpa);

    if (filter == .all or filter == .android) {
        const found = android.scan(gpa, arena, io) catch |err| android_failure: {
            try handleScannerFailure(filter, .android, err);
            break :android_failure &.{};
        };
        try candidates.appendSlice(gpa, found);
    }
    if (filter == .all or filter == .ios) {
        const found = ios.scan(gpa, arena, io) catch |err| ios_failure: {
            try handleScannerFailure(filter, .ios, err);
            break :ios_failure null;
        };
        if (found) |slice| {
            for (slice) |*candidate| candidate.probe_state = endpointProbeState(candidate.endpoint);
            try candidates.appendSlice(gpa, slice);
        }
    }
    if (filter == .all or filter == .host) {
        var host: device.Candidate = .{
            .platform = .host,
            .id = "localhost",
            .name = "Mac",
            .transport = "local",
            .endpoint = "tcp:7779",
        };
        host.probe_state = endpointProbeState(host.endpoint);
        try candidates.append(gpa, host);
    }
    return try arena.dupe(device.Candidate, candidates.items);
}

fn handleScannerFailure(filter: Filter, scanner: Filter, err: anyerror) !void {
    if (err == error.OutOfMemory or filter == scanner) return err;
}

fn endpointProbeState(endpoint: []const u8) device.ProbeState {
    return if (wire.probeHealthy(endpoint)) .live else .missing;
}

pub fn writeTable(writer: *std.Io.Writer, candidates: []const device.Candidate) !void {
    try writer.writeAll("ID                       PLATFORM  TRANSPORT   STATE         PROBE     NAME                   SOC\n");
    for (candidates) |candidate| {
        try writer.print("{s: <24} {s: <9} {s: <11} {s: <13} {s: <9} {s: <22} {s}\n", .{
            candidate.id,
            candidate.platform.label(),
            candidate.transport,
            candidate.transport_state,
            candidate.probe_state.label(),
            candidate.name,
            candidate.soc,
        });
    }
}

pub fn writeJson(writer: *std.Io.Writer, candidates: []const device.Candidate) !void {
    var json: std.json.Stringify = .{ .writer = writer, .options = .{} };
    try json.beginArray();
    for (candidates) |candidate| {
        try json.beginObject();
        try json.objectField("id");
        try json.write(candidate.id);
        try json.objectField("platform");
        try json.write(candidate.platform.label());
        try json.objectField("name");
        try json.write(candidate.name);
        try json.objectField("soc");
        try json.write(candidate.soc);
        try json.objectField("transport");
        try json.write(candidate.transport);
        try json.objectField("transport_state");
        try json.write(candidate.transport_state);
        try json.objectField("selectable");
        try json.write(candidate.selectable);
        try json.objectField("probe_state");
        try json.write(candidate.probe_state.label());
        try json.endObject();
    }
    try json.endArray();
    try writer.writeByte('\n');
}

test "device JSON is stable and scriptable" {
    const candidates = [_]device.Candidate{.{
        .platform = .android,
        .id = "pixel",
        .name = "Pixel 8",
        .transport = "adb-usb",
        .probe_state = .live,
    }};
    var buf: [512]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try writeJson(&writer, &candidates);
    try std.testing.expectEqualStrings(
        "[{\"id\":\"pixel\",\"platform\":\"android\",\"name\":\"Pixel 8\",\"soc\":\"\",\"transport\":\"adb-usb\",\"transport_state\":\"ready\",\"selectable\":true,\"probe_state\":\"live\"}]\n",
        writer.buffered(),
    );
}

test "filtered discovery propagates its scanner failure" {
    try std.testing.expectError(error.AdbMissing, handleScannerFailure(.android, .android, error.AdbMissing));
    try std.testing.expectError(error.DevicectlMissing, handleScannerFailure(.ios, .ios, error.DevicectlMissing));
}

test "all-platform discovery tolerates one scanner failure" {
    try handleScannerFailure(.all, .android, error.AdbMissing);
    try handleScannerFailure(.all, .ios, error.DevicectlMissing);
    try std.testing.expectError(error.OutOfMemory, handleScannerFailure(.all, .android, error.OutOfMemory));
}
