//! Writes the dashboard golden frames to stdout for `zig build update-golden`,
//! which copies them over `ui/testdata/dashboard.golden`. Review the diff
//! before committing it.

const std = @import("std");
const dashboard = @import("ui/dashboard.zig");
const tty = @import("tty.zig");

var frames_buf: [dashboard.golden_buf_size]u8 = undefined;

pub fn main() !void {
    var out: std.Io.Writer = .fixed(&frames_buf);
    try dashboard.goldenFrames(&out);
    try tty.write(out.buffered());
}
