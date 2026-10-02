//! Synthetic renderer fixtures, generated without brand or project artwork.
//! Used only by tests; the application catalogue remains empty.
const tui = @import("tuiz");
const splash = @import("splash.zig");

pub const bitmap = makeBitmap(24, 14);
pub const wide_bitmap = makeBitmap(56, 22);
pub const mask = makeMask(21, 14);
pub const small_mask = makeMask(15, 10);

fn makeBitmap(comptime width: usize, comptime height: usize) splash.Mark {
    const pixels = comptime blk: {
        @setEvalBranchQuota(4 * width * height);
        var out: [width * height]?tui.Rgb = undefined;
        for (&out, 0..) |*pixel, i| {
            // Vary both subpixels to exercise the colour escape budget.
            pixel.* = .{ .r = @intCast(i % 251), .g = 120, .b = @intCast((i / width) % 251) };
        }
        break :blk out;
    };
    return .{ .bitmap = .{ .w = width, .h = height, .px = &pixels } };
}

fn makeMask(comptime width: usize, comptime height: usize) splash.Mark {
    const bits = [_]u8{0x55} ** (((width + 7) / 8) * height);
    return .{ .mask = .{
        .art = .{ .w = width, .h = height, .bits = &bits },
        .ink = .{ .r = 180, .g = 180, .b = 180 },
    } };
}
