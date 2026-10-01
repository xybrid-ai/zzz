//! What one device is asked to run: how many threads, and how many
//! tokens of prefill and decode.
//!
//! One policy per device: devices can have different CPU core counts and
//! scheduling characteristics. `RunSpec` carries the settings per frame.

const std = @import("std");

/// Kernel-selection request sent to the supplied engine.
///
/// **Read `reach` before trusting an A/B against this.** The pin is
/// process-wide but does not necessarily affect every operation.
///
/// `auto` picks by build and runtime feature detection and is what
/// every ordinary run wants.
///
/// The tag values are the wire values in `RunSpec`. Zero selects `auto`
/// when the optional field is unset.
pub const Kernel = enum(u8) {
    auto = 0,
    sdot = 1,
    vector = 2,
    scalar = 3,

    pub fn label(self: Kernel) []const u8 {
        return switch (self) {
            .auto => "auto",
            .sdot => "sdot",
            .vector => "vector",
            .scalar => "scalar",
        };
    }

    pub fn parse(text: []const u8) ?Kernel {
        inline for (@typeInfo(Kernel).@"enum".fields) |field| {
            if (std.ascii.eqlIgnoreCase(text, field.name)) return @enumFromInt(field.value);
        }
        return null;
    }

    /// Anything the wire does not name is `auto`. A bench newer than
    /// this probe could send a kernel it has never heard of, and
    /// running the default beats refusing the frame.
    pub fn fromWire(value: u8) Kernel {
        return std.enums.fromInt(Kernel, value) orelse .auto;
    }
};

/// Scope of the supplied zzz engine's kernel-selection option. Keep this
/// user-visible limitation explicit when comparing pinned configurations;
/// selecting a mode does not affect every supported weight format.
pub const reach = "Scope depends on the supplied engine; a selected mode may not affect every operation.";

pub const RunPolicy = struct {
    threads: u32 = 4,
    n_prompt: u32 = 16,
    n_generate: u32 = 32,
    kernel: Kernel = .auto,

    /// Field-wise, never `std.mem.asBytes`. `kernel` is one byte, so
    /// the struct carries three bytes of unspecified padding — and a
    /// byte comparison would call two policies different because of
    /// bytes that mean nothing, which here would throw away a finished
    /// run's metrics for no reason.
    pub fn eql(self: RunPolicy, other: RunPolicy) bool {
        return self.threads == other.threads and
            self.n_prompt == other.n_prompt and
            self.n_generate == other.n_generate and
            self.kernel == other.kernel;
    }

    pub fn get(self: RunPolicy, field: Field) u32 {
        return switch (field) {
            .threads => self.threads,
            .n_prompt => self.n_prompt,
            .n_generate => self.n_generate,
            .kernel => @intFromEnum(self.kernel),
        };
    }

    /// This policy with `field` moved `steps` notches, clamped to the
    /// field's range. Clamps rather than wraps: rolling 1 thread down
    /// into 32 would be a very expensive slip to make with one
    /// keypress.
    pub fn adjusted(self: RunPolicy, field: Field, steps: i32) RunPolicy {
        var out = self;
        const range = field.range();
        const current: i64 = self.get(field);
        const moved = current + @as(i64, steps) * range.step;
        const clamped: u32 = @intCast(std.math.clamp(moved, range.min, range.max));
        switch (field) {
            .threads => out.threads = clamped,
            .n_prompt => out.n_prompt = clamped,
            .n_generate => out.n_generate = clamped,
            .kernel => out.kernel = Kernel.fromWire(@intCast(clamped)),
        }
        return out;
    }
};

/// What one device will run, as the dashboard is entitled to state it.
pub const Shown = struct {
    policy: RunPolicy,
    /// A `--prompt` replaces the engine's synthetic prefill, so it
    /// prefills the prompt's own encoded length and ignores
    /// `n_prompt` entirely. Printing that number anyway would label a
    /// result `512/60` when the engine prefilled whatever the prompt
    /// happened to encode to.
    prompt_overrides_prefill: bool = false,
};

/// `t8 · 128/60` — the whole policy in one glance, for the title bar
/// and each peer band. `t8 · 60` when a prompt is in force, since the
/// prefill count is then not ours to claim.
///
/// This is on screen at all times on purpose. A tok/s figure without
/// its thread count beside it is not a result, it is a number: the
/// same phone reads 2.66x apart at two thread counts, and a screencap
/// that omits which one it ran is the exact shape of mistake this
/// repo keeps paying for.
pub fn writeSummary(lw: anytype, shown: Shown) !void {
    if (shown.prompt_overrides_prefill) {
        try lw.print("t{d} · {d}", .{ shown.policy.threads, shown.policy.n_generate });
    } else {
        try lw.print("t{d} · {d}/{d}", .{
            shown.policy.threads,
            shown.policy.n_prompt,
            shown.policy.n_generate,
        });
    }
    // Named only when it is not the default. `auto` on every frame is
    // noise; a pinned kernel changes the number and has to be visible
    // beside it.
    if (shown.policy.kernel != .auto) try lw.print(" · {s}", .{shown.policy.kernel.label()});
}

test "a prompt run does not claim a prefill count it did not use" {
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeSummary(&w, .{ .policy = .{ .threads = 8, .n_prompt = 512, .n_generate = 60 } });
    try std.testing.expectEqualStrings("t8 · 512/60", w.buffered());

    var prompt_buf: [64]u8 = undefined;
    var pw: std.Io.Writer = .fixed(&prompt_buf);
    try writeSummary(&pw, .{
        .policy = .{ .threads = 8, .n_prompt = 512, .n_generate = 60 },
        .prompt_overrides_prefill = true,
    });
    try std.testing.expectEqualStrings("t8 · 60", pw.buffered());
}

pub const Field = enum {
    threads,
    n_prompt,
    n_generate,
    kernel,

    pub const all = [_]Field{ .threads, .n_prompt, .n_generate, .kernel };

    pub fn label(self: Field) []const u8 {
        return switch (self) {
            .threads => "threads",
            .n_prompt => "prompt tokens",
            .n_generate => "generate tokens",
            // Neither "q4_0 kernel" nor "all quants" — both were
            // wrong. What it reaches is `reach`, footnoted by the grid
            // when a pin is set.
            .kernel => "gemv kernel",
        };
    }

    /// How this field's value reads in a grid cell. Every field moves
    /// by the same +/- steps; only the rendering differs, which is why
    /// an enum row fits an otherwise numeric editor without a special
    /// case in the input handling.
    pub fn cellText(self: Field, value: u32, buf: []u8) []const u8 {
        return switch (self) {
            .kernel => Kernel.fromWire(@intCast(value)).label(),
            else => std.fmt.bufPrint(buf, "{d}", .{value}) catch "?",
        };
    }

    pub const Range = struct { min: i64, max: i64, step: i64 };

    pub fn range(self: Field) Range {
        return switch (self) {
            // Above the core count of anything this bench runs on, so
            // an oversubscription experiment stays reachable.
            .threads => .{ .min = 1, .max = 64, .step = 1 },
            // Token counts move in 16s: single-token steps would take
            // 30 keypresses to get anywhere useful.
            .n_prompt => .{ .min = 16, .max = 8192, .step = 16 },
            .n_generate => .{ .min = 16, .max = 4096, .step = 16 },
            // One step per kernel, clamped at both ends like every
            // other row: wrapping from `scalar` back to `auto` would
            // make a single keypress silently undo an A/B.
            .kernel => .{ .min = 0, .max = 3, .step = 1 },
        };
    }
};

test "the kernel row steps through the dispatchers and clamps" {
    const base: RunPolicy = .{};
    try std.testing.expectEqual(Kernel.auto, base.kernel);
    try std.testing.expectEqual(Kernel.sdot, base.adjusted(.kernel, 1).kernel);
    try std.testing.expectEqual(Kernel.scalar, base.adjusted(.kernel, 3).kernel);
    // Clamped, not wrapped: one keypress must not roll `scalar` back to
    // `auto` and silently undo an A/B.
    try std.testing.expectEqual(Kernel.scalar, base.adjusted(.kernel, 9).kernel);
    try std.testing.expectEqual(Kernel.auto, base.adjusted(.kernel, -1).kernel);
}

test "the kernel cell reads as a name, every other cell as a number" {
    var buf: [24]u8 = undefined;
    try std.testing.expectEqualStrings("sdot", Field.kernel.cellText(1, &buf));
    try std.testing.expectEqualStrings("auto", Field.kernel.cellText(0, &buf));
    try std.testing.expectEqualStrings("8", Field.threads.cellText(8, &buf));
    // A tag from a newer bench reads as the default rather than as
    // garbage.
    try std.testing.expectEqualStrings("auto", Field.kernel.cellText(99, &buf));
}

test "the summary names a pinned kernel and stays quiet about auto" {
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeSummary(&w, .{ .policy = .{ .threads = 8, .n_prompt = 32, .n_generate = 64 } });
    try std.testing.expectEqualStrings("t8 · 32/64", w.buffered());

    var pinned_buf: [64]u8 = undefined;
    var pw: std.Io.Writer = .fixed(&pinned_buf);
    try writeSummary(&pw, .{
        .policy = .{ .threads = 8, .n_prompt = 32, .n_generate = 64, .kernel = .scalar },
    });
    try std.testing.expectEqualStrings("t8 · 32/64 · scalar", pw.buffered());
}

test "equality reads the fields, so padding cannot fake a change" {
    const base: RunPolicy = .{ .threads = 8, .n_prompt = 32, .n_generate = 64, .kernel = .sdot };
    try std.testing.expect(base.eql(.{ .threads = 8, .n_prompt = 32, .n_generate = 64, .kernel = .sdot }));
    try std.testing.expect(!base.eql(.{ .threads = 7, .n_prompt = 32, .n_generate = 64, .kernel = .sdot }));
    try std.testing.expect(!base.eql(.{ .threads = 8, .n_prompt = 32, .n_generate = 64, .kernel = .auto }));

    // Round-tripping a value out and back is not a change.
    const nudged = base.adjusted(.threads, 1).adjusted(.threads, -1);
    try std.testing.expect(base.eql(nudged));
}

test "adjust clamps at both ends rather than wrapping" {
    const base: RunPolicy = .{ .threads = 1 };
    try std.testing.expectEqual(@as(u32, 1), base.adjusted(.threads, -1).threads);
    try std.testing.expectEqual(@as(u32, 2), base.adjusted(.threads, 1).threads);

    const high: RunPolicy = .{ .threads = 64 };
    try std.testing.expectEqual(@as(u32, 64), high.adjusted(.threads, 1).threads);
}

test "token fields move in sixteens" {
    const base: RunPolicy = .{ .n_prompt = 128, .n_generate = 32 };
    try std.testing.expectEqual(@as(u32, 144), base.adjusted(.n_prompt, 1).n_prompt);
    try std.testing.expectEqual(@as(u32, 96), base.adjusted(.n_prompt, -2).n_prompt);
    // The floor is a whole step, so decode never lands on zero tokens.
    try std.testing.expectEqual(@as(u32, 16), base.adjusted(.n_generate, -5).n_generate);
}

test "a big jump saturates instead of overflowing" {
    const base: RunPolicy = .{ .n_prompt = 8192 };
    try std.testing.expectEqual(@as(u32, 8192), base.adjusted(.n_prompt, 1_000_000).n_prompt);
    try std.testing.expectEqual(@as(u32, 16), base.adjusted(.n_prompt, -1_000_000).n_prompt);
}
