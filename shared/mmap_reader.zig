const std = @import("std");

const page_align = std.heap.page_size_min;

pub const MmapReader = struct {
    data: []align(page_align) const u8,
    pos: usize,

    pub fn init(path: []const u8) !MmapReader {
        var threaded: std.Io.Threaded = .init_single_threaded;
        const io = threaded.io();
        const file = try std.Io.Dir.cwd().openFile(io, path, .{});
        defer file.close(io);
        const stat = try file.stat(io);
        if (stat.size == 0) return error.EmptyFile;
        const mapped = try std.posix.mmap(
            null,
            stat.size,
            .{ .READ = true },
            .{ .TYPE = .PRIVATE },
            file.handle,
            0,
        );
        return .{ .data = mapped, .pos = 0 };
    }

    pub fn deinit(self: *MmapReader) void {
        std.posix.munmap(self.data);
    }

    /// Bounds-check `n` more bytes from the cursor.
    ///
    /// `n` is frequently a length prefix read straight out of the file, so
    /// the addition must be checked: `self.pos + n` wraps for a crafted
    /// `n` near `maxInt(usize)`, and a wrapped sum passes the `>` test.
    /// In ReleaseFast (the shipped optimize mode) there is no overflow
    /// trap to catch it, so the caller would go on to build a slice whose
    /// `start > end` and read gigabytes past the mapping.
    fn ensure(self: *const MmapReader, n: usize) !void {
        const end = std.math.add(usize, self.pos, n) catch return error.UnexpectedEof;
        if (end > self.data.len) return error.UnexpectedEof;
    }

    pub fn readU8(self: *MmapReader) !u8 {
        try self.ensure(1);
        const v = self.data[self.pos];
        self.pos += 1;
        return v;
    }

    pub fn readI8(self: *MmapReader) !i8 {
        return @bitCast(try self.readU8());
    }

    pub fn readU16(self: *MmapReader) !u16 {
        try self.ensure(2);
        const v = std.mem.readInt(u16, self.data[self.pos..][0..2], .little);
        self.pos += 2;
        return v;
    }

    pub fn readI16(self: *MmapReader) !i16 {
        return @bitCast(try self.readU16());
    }

    pub fn readU32(self: *MmapReader) !u32 {
        try self.ensure(4);
        const v = std.mem.readInt(u32, self.data[self.pos..][0..4], .little);
        self.pos += 4;
        return v;
    }

    pub fn readI32(self: *MmapReader) !i32 {
        return @bitCast(try self.readU32());
    }

    pub fn readU64(self: *MmapReader) !u64 {
        try self.ensure(8);
        const v = std.mem.readInt(u64, self.data[self.pos..][0..8], .little);
        self.pos += 8;
        return v;
    }

    pub fn readI64(self: *MmapReader) !i64 {
        return @bitCast(try self.readU64());
    }

    pub fn readF32(self: *MmapReader) !f32 {
        return @bitCast(try self.readU32());
    }

    pub fn readF64(self: *MmapReader) !f64 {
        return @bitCast(try self.readU64());
    }

    pub fn readBool(self: *MmapReader) !bool {
        return (try self.readU8()) != 0;
    }

    pub fn readString(self: *MmapReader) ![]const u8 {
        // The raw u64 is file-supplied. `@intCast` to usize is a no-op on
        // 64-bit and illegal behaviour on 32-bit, so range-check first;
        // `ensure` then rejects anything that doesn't fit the mapping.
        const raw = try self.readU64();
        const len = std.math.cast(usize, raw) orelse return error.UnexpectedEof;
        try self.ensure(len);
        const start = self.pos;
        self.pos += len;
        return self.data[start..self.pos];
    }

    pub fn skip(self: *MmapReader, n: usize) !void {
        try self.ensure(n);
        self.pos += n;
    }
};
