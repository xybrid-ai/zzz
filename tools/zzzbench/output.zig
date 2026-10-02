//! The tail of the text a device actually generated.
//!
//! One of these per device. The engine streams `proto.TokenText`
//! chunks as it decodes; this keeps the most recent bytes of that
//! stream and nothing else.
//!
//! Bounded on purpose. A long run generates far more text than a panel
//! can show, so retaining all of it would be a leak whose only visible
//! effect is that the panel shows the same last few lines. When the
//! buffer fills, the oldest bytes go and `truncated` records it — the
//! panel says so rather than implying the run started mid-sentence.

const std = @import("std");
const proto = @import("proto");
const wire = @import("wire.zig");

pub const Output = struct {
    /// Bytes retained. Roughly a screenful of prose at any terminal
    /// width the dashboard accepts, with room to scroll past.
    pub const capacity: usize = 4096;

    buf: [capacity]u8 = undefined,
    len: usize = 0,
    /// Set once the oldest text has been dropped to make room.
    truncated: bool = false,
    /// Chunk index expected next. A mismatch means the stream lost or
    /// reordered a chunk, which matters because the result reads as
    /// fluent text either way — there is no visible corruption to
    /// notice.
    next_seq: u32 = 0,
    /// Set when a chunk arrived out of sequence.
    gap: bool = false,
    /// The engine sent its terminator, so this is the whole output
    /// rather than a stream still in flight.
    complete: bool = false,

    pub fn reset(self: *Output) void {
        self.len = 0;
        self.truncated = false;
        self.next_seq = 0;
        self.gap = false;
        self.complete = false;
    }

    pub fn slice(self: *const Output) []const u8 {
        return self.buf[0..self.len];
    }

    pub fn isEmpty(self: *const Output) bool {
        return self.len == 0;
    }

    /// Fold one wire chunk in. Returns true when something a reader
    /// would see changed.
    pub fn push(self: *Output, chunk: wire.TokenText) bool {
        var changed = false;
        if (chunk.seq != self.next_seq and !self.gap) {
            // The transition is itself render-visible: the panel's
            // incomplete-text warning hangs off this flag, and a gap
            // announced by an empty chunk would otherwise wait for the
            // next text to arrive before appearing.
            self.gap = true;
            changed = true;
        }
        // Track from what actually arrived, not from what was expected,
        // so one dropped chunk doesn't mark every later one as a gap.
        self.next_seq = chunk.seq +| 1;
        if (chunk.final and !self.complete) {
            self.complete = true;
            changed = true;
        }

        const text = chunk.slice();
        if (text.len == 0) return changed;

        self.append(text);
        return true;
    }

    /// Append, dropping oldest bytes if needed. A single chunk cannot
    /// exceed `proto.TokenText.max_payload`, which is well under
    /// `capacity`, so the shift below always leaves room.
    fn append(self: *Output, text: []const u8) void {
        std.debug.assert(text.len <= capacity);

        if (self.len + text.len > capacity) {
            const drop = self.len + text.len - capacity;
            std.mem.copyForwards(u8, self.buf[0 .. self.len - drop], self.buf[drop..self.len]);
            self.len -= drop;
            self.truncated = true;
        }
        @memcpy(self.buf[self.len..][0..text.len], text);
        self.len += text.len;
    }
};

fn chunkOf(seq: u32, text: []const u8, final: bool) wire.TokenText {
    var c: wire.TokenText = .{ .seq = seq, .final = final, .buf = undefined, .len = @intCast(text.len) };
    @memcpy(c.buf[0..text.len], text);
    return c;
}

test "chunks concatenate in arrival order" {
    var out: Output = .{};
    _ = out.push(chunkOf(0, "A bonsai", false));
    _ = out.push(chunkOf(1, " is a tree", false));
    _ = out.push(chunkOf(2, "", true));

    try std.testing.expectEqualStrings("A bonsai is a tree", out.slice());
    try std.testing.expect(out.complete);
    try std.testing.expect(!out.gap);
    try std.testing.expect(!out.truncated);
}

test "a sequence gap is recorded once, not for every chunk after it" {
    var out: Output = .{};
    _ = out.push(chunkOf(0, "a", false));
    _ = out.push(chunkOf(7, "b", false)); // 1..6 lost
    try std.testing.expect(out.gap);

    // Resyncing on what arrived means the next chunk is in sequence.
    out.gap = false;
    _ = out.push(chunkOf(8, "c", false));
    try std.testing.expect(!out.gap);
    try std.testing.expectEqualStrings("abc", out.slice());
}

test "overflow drops the oldest text and says so" {
    var out: Output = .{};
    // Filled a chunk at a time, because a chunk is bounded by the
    // wire's payload ceiling — the buffer only ever overflows across
    // many of them.
    const filler: [proto.TokenText.max_payload]u8 = @splat('x');
    var seq: u32 = 0;
    while (out.slice().len < Output.capacity) : (seq += 1) {
        _ = out.push(chunkOf(seq, &filler, false));
    }
    try std.testing.expect(!out.truncated);
    try std.testing.expectEqual(Output.capacity, out.slice().len);

    _ = out.push(chunkOf(seq, "TAIL", false));
    try std.testing.expect(out.truncated);
    try std.testing.expectEqual(Output.capacity, out.slice().len);
    try std.testing.expectEqualStrings("TAIL", out.slice()[Output.capacity - 4 ..]);
    // The dropped bytes came off the front, so nothing in the middle
    // was disturbed.
    try std.testing.expectEqual(@as(u8, 'x'), out.slice()[0]);
}

test "reset clears the run, not just the bytes" {
    var out: Output = .{};
    _ = out.push(chunkOf(0, "old run", true));
    out.reset();

    try std.testing.expect(out.isEmpty());
    try std.testing.expect(!out.complete);
    try std.testing.expectEqual(@as(u32, 0), out.next_seq);

    // A fresh run starts at seq 0 again, which must not read as a gap.
    _ = out.push(chunkOf(0, "new run", false));
    try std.testing.expect(!out.gap);
    try std.testing.expectEqualStrings("new run", out.slice());
}

test "a gap announced by an empty chunk repaints immediately" {
    // The warning hangs off the flag; a push that sets it must report
    // a visible change even with no payload, or the panel says nothing
    // until the next text happens to arrive.
    var out: Output = .{};
    _ = out.push(chunkOf(0, "a", false));
    try std.testing.expect(out.push(chunkOf(5, "", false)));
    try std.testing.expect(out.gap);
}
