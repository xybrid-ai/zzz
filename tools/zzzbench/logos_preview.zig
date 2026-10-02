//! Compatibility entry point for the deferred artwork gallery.
const std = @import("std");
const tty = @import("tty.zig");

pub const message = "zzzbench: artwork is not included in this build; logos are deferred.\n";

pub fn run() !void {
    try tty.write(message);
}

pub fn draw(out: *std.Io.Writer) !void {
    try out.writeAll(message);
}

test "the deferred artwork preview is plain text" {
    var buf: [256]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    try draw(&out);
    try std.testing.expectEqualStrings(message, out.buffered());
    try std.testing.expect(std.mem.indexOfScalar(u8, out.buffered(), 0x1b) == null);
}
