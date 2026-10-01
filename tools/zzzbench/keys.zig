//! Splits one raw-mode read into the keys it actually carries.
//!
//! A single `read()` in raw mode is not one keypress. Terminals coalesce
//! auto-repeat (holding `j` arrives as `jjjj`), and every arrow key is a
//! three-byte CSI sequence. A picker that inspects only `input[0]` drops
//! the rest of the burst, which reads to the operator as a list that
//! ignores keypresses — the failure this iterator exists to prevent.

const std = @import("std");

pub const Key = enum { up, down, left, right, select, toggle, cancel, unknown };

pub const Iterator = struct {
    bytes: []const u8,
    pos: usize = 0,

    pub fn next(self: *Iterator) ?Key {
        if (self.pos >= self.bytes.len) return null;
        const b = self.bytes[self.pos];
        if (b == 0x1b) return self.escape();
        self.pos += 1;
        return switch (b) {
            'k', 'K' => .up,
            'j', 'J' => .down,
            'h', 'H' => .left,
            'l', 'L' => .right,
            '\r', '\n' => .select,
            ' ' => .toggle,
            // Ctrl-C cancels: raw mode means no SIGINT is coming.
            'q', 'Q', 0x03 => .cancel,
            else => .unknown,
        };
    }

    /// An ESC at the cursor. Consumes the whole CSI sequence when one
    /// is here, so its `[` and final byte never come back around as
    /// keys of their own.
    fn escape(self: *Iterator) Key {
        const rest = self.bytes[self.pos + 1 ..];
        if (rest.len >= 2 and rest[0] == '[') {
            const final = rest[1];
            self.pos += 3;
            return switch (final) {
                'A' => .up,
                'B' => .down,
                'C' => .right,
                'D' => .left,
                else => .unknown,
            };
        }
        // Anything else starting with ESC is either a bare Escape or a
        // sequence the terminal split across reads — a slow pty can
        // hand over `\x1b[` and `A` separately. Only a burst that is
        // exactly one ESC is read as a deliberate cancel; treating a
        // split prefix that way aborts the picker on a plain arrow
        // press.
        self.pos = self.bytes.len;
        return if (self.bytes.len == 1) .cancel else .unknown;
    }
};

test "a coalesced auto-repeat burst yields every key" {
    var it: Iterator = .{ .bytes = "jjk" };
    try std.testing.expectEqual(Key.down, it.next().?);
    try std.testing.expectEqual(Key.down, it.next().?);
    try std.testing.expectEqual(Key.up, it.next().?);
    try std.testing.expectEqual(@as(?Key, null), it.next());
}

test "arrow sequences are consumed whole" {
    var it: Iterator = .{ .bytes = "\x1b[B\x1b[A\x1b[C\x1b[D\r" };
    try std.testing.expectEqual(Key.down, it.next().?);
    try std.testing.expectEqual(Key.up, it.next().?);
    try std.testing.expectEqual(Key.right, it.next().?);
    try std.testing.expectEqual(Key.left, it.next().?);
    try std.testing.expectEqual(Key.select, it.next().?);
    try std.testing.expectEqual(@as(?Key, null), it.next());
}

test "hjkl moves the same way the arrows do" {
    var it: Iterator = .{ .bytes = "hjkl" };
    try std.testing.expectEqual(Key.left, it.next().?);
    try std.testing.expectEqual(Key.down, it.next().?);
    try std.testing.expectEqual(Key.up, it.next().?);
    try std.testing.expectEqual(Key.right, it.next().?);
}

test "a bare escape cancels but an escape sequence does not" {
    var lone: Iterator = .{ .bytes = "\x1b" };
    try std.testing.expectEqual(Key.cancel, lone.next().?);

    var arrow: Iterator = .{ .bytes = "\x1b[A" };
    try std.testing.expectEqual(Key.up, arrow.next().?);
    try std.testing.expectEqual(@as(?Key, null), arrow.next());
}

test "a CSI sequence split across reads never reads as cancel" {
    // `\x1b[` now, `A` on the next read: the picker must survive it.
    var head: Iterator = .{ .bytes = "\x1b[" };
    try std.testing.expectEqual(Key.unknown, head.next().?);
    try std.testing.expectEqual(@as(?Key, null), head.next());

    var tail: Iterator = .{ .bytes = "A" };
    try std.testing.expectEqual(Key.unknown, tail.next().?);

    // An ESC riding at the end of a longer burst is the same case.
    var trailing: Iterator = .{ .bytes = "j\x1b" };
    try std.testing.expectEqual(Key.down, trailing.next().?);
    try std.testing.expectEqual(Key.unknown, trailing.next().?);
    try std.testing.expectEqual(@as(?Key, null), trailing.next());
}

test "unknown bytes are reported rather than silently skipped" {
    var it: Iterator = .{ .bytes = "x \x1b[Z" };
    try std.testing.expectEqual(Key.unknown, it.next().?);
    try std.testing.expectEqual(Key.toggle, it.next().?);
    try std.testing.expectEqual(Key.unknown, it.next().?);
    try std.testing.expectEqual(@as(?Key, null), it.next());
}
