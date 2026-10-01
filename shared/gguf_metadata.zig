//! Metadata-only GGUF catalogue. No tensor loading, inference, or quantization code.
const std = @import("std");
pub const MmapReader = @import("mmap_reader.zig").MmapReader;

pub const Summary = struct {
    architecture: []const u8 = "unknown",
    parameters: u64 = 0,
    quant: []const u8 = "unknown",
};

const Cursor = struct {
    data: []const u8,
    pos: usize = 0,
    budget: usize = 4 * 1024 * 1024,

    fn take(self: *Cursor, n: u64) ![]const u8 {
        if (n > self.data.len - self.pos) return error.TruncatedMetadata;
        const size: usize = @intCast(n);
        defer self.pos += size;
        return self.data[self.pos..][0..size];
    }

    fn int(self: *Cursor, comptime T: type) !T {
        return std.mem.readInt(T, (try self.take(@sizeOf(T)))[0..@sizeOf(T)], .little);
    }

    fn string(self: *Cursor) ![]const u8 {
        return self.take(try self.int(u64));
    }

    fn skip(self: *Cursor, tag: u32, depth: u8) anyerror!void {
        if (depth > 8 or self.budget == 0) return error.MetadataTooLarge;
        self.budget -= 1;
        switch (tag) {
            0, 1, 7 => _ = try self.take(1),
            2, 3 => _ = try self.take(2),
            4, 5, 6 => _ = try self.take(4),
            10, 11, 12 => _ = try self.take(8),
            8 => _ = try self.string(),
            9 => {
                const item = try self.int(u32);
                if (item > 12) return error.InvalidValueType;
                const count = try self.int(u64);
                if (count > self.budget) return error.MetadataTooLarge;
                for (0..@intCast(count)) |_| try self.skip(item, depth + 1);
            },
            else => return error.InvalidValueType,
        }
    }
};

pub fn parse(data: []const u8) !Summary {
    var cursor: Cursor = .{ .data = data };
    if (try cursor.int(u32) != 0x46554747) return error.InvalidMagic;
    const version = try cursor.int(u32);
    if (version != 2 and version != 3) return error.UnsupportedVersion;
    const tensors = try cursor.int(u64);
    const entries = try cursor.int(u64);
    if (tensors > 1_000_000 or entries > 1_000_000) return error.MetadataTooLarge;
    var summary: Summary = .{};
    for (0..@intCast(entries)) |_| {
        const key = try cursor.string();
        const tag = try cursor.int(u32);
        if (std.mem.eql(u8, key, "general.architecture") and tag == 8) {
            summary.architecture = try cursor.string();
        } else try cursor.skip(tag, 0);
    }
    // Indexed by GGUF type ID; higher IDs still count toward `parameters`.
    var elements_by_type: [256]u64 = @splat(0);
    for (0..@intCast(tensors)) |_| {
        _ = try cursor.string();
        const dims = try cursor.int(u32);
        if (dims == 0 or dims > 4) return error.InvalidDimensions;
        var elements: u64 = 1;
        for (0..dims) |_| {
            const dim = try cursor.int(u64);
            if (dim == 0) return error.InvalidDimensions;
            elements = try std.math.mul(u64, elements, dim);
        }
        const kind = try cursor.int(u32);
        _ = try cursor.int(u64); // Tensor offset: payload is deliberately never accessed.
        summary.parameters = try std.math.add(u64, summary.parameters, elements);
        if (kind < elements_by_type.len) {
            elements_by_type[kind] = try std.math.add(u64, elements_by_type[kind], elements);
        }
    }
    var largest: u64 = 0;
    for (elements_by_type, 0..) |elements, kind| {
        if (elements > largest) {
            largest = elements;
            summary.quant = quantLabel(kind);
        }
    }
    return summary;
}

fn quantLabel(kind: usize) []const u8 {
    return switch (kind) {
        0 => "F32",
        1 => "F16",
        2 => "Q4_0",
        3 => "Q4_1",
        6 => "Q5_0",
        7 => "Q5_1",
        8 => "Q8_0",
        9 => "Q8_1",
        10 => "Q2_K",
        11 => "Q3_K",
        12 => "Q4_K",
        13 => "Q5_K",
        14 => "Q6_K",
        30 => "BF16",
        else => "unknown",
    };
}

/// A header-only GGUF v3 file: one architecture key and one 32x64 tensor.
fn writeOneTensorFile(w: *std.Io.Writer, kind: u32) !void {
    try w.writeInt(u32, 0x46554747, .little);
    try w.writeInt(u32, 3, .little);
    try w.writeInt(u64, 1, .little);
    try w.writeInt(u64, 1, .little);
    try w.writeInt(u64, "general.architecture".len, .little);
    try w.writeAll("general.architecture");
    try w.writeInt(u32, 8, .little);
    try w.writeInt(u64, 5, .little);
    try w.writeAll("llama");
    try w.writeInt(u64, 1, .little);
    try w.writeAll("w");
    try w.writeInt(u32, 2, .little);
    try w.writeInt(u64, 32, .little);
    try w.writeInt(u64, 64, .little);
    try w.writeInt(u32, kind, .little);
    try w.writeInt(u64, 0, .little);
}

test "catalogue reads architecture and tensor dimensions without tensor payloads" {
    var buffer: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buffer);
    try writeOneTensorFile(&w, 2);
    const data = w.buffered();
    const result = try parse(data);
    try std.testing.expectEqualStrings("llama", result.architecture);
    try std.testing.expectEqualStrings("Q4_0", result.quant);
    try std.testing.expectEqual(@as(u64, 2048), result.parameters);
    for (0..data.len) |length| {
        if (parse(data[0..length])) |_| return error.AcceptedTruncatedHeader else |_| {}
    }
}

test "catalogue preserves metadata for unrecognized tensor types" {
    for ([_]u32{ 255, 65535 }) |kind| {
        var buffer: [256]u8 = undefined;
        var w = std.Io.Writer.fixed(&buffer);
        try writeOneTensorFile(&w, kind);
        const result = try parse(w.buffered());
        try std.testing.expectEqualStrings("unknown", result.quant);
        try std.testing.expectEqualStrings("llama", result.architecture);
        try std.testing.expectEqual(@as(u64, 2048), result.parameters);
    }
}

test "catalogue bounds malicious array lengths and recursive nesting" {
    var bytes: [12]u8 = @splat(0xff);
    std.mem.writeInt(u32, bytes[0..4], 8, .little);
    var cursor: Cursor = .{ .data = &bytes };
    try std.testing.expectError(error.MetadataTooLarge, cursor.skip(9, 0));
    try std.testing.expectError(error.MetadataTooLarge, cursor.skip(9, 9));
    cursor = .{ .data = &bytes };
    try std.testing.expectError(error.TruncatedMetadata, cursor.string());
}
