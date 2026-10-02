//! The `p` screen: edit what each device is asked to run, without
//! restarting the bench.
//!
//! The dashboard already owns raw mode and the alternate screen, so
//! this module only moves a cursor over a grid and asks
//! `ui/picker_screen.zig` for the frame. Nothing is pushed and no
//! probe is restarted — `RunSpec` carries the numbers on the next `r`.
//!
//! Column 0 is ALL and writes to every device at once, because the
//! common case is one thread count for the window and the per-device
//! columns exist for the case that is *not* common: a Tensor G3 and a
//! Snapdragon 8 Elite want different counts, and using one for both is
//! a measurement error rather than a preference.

const std = @import("std");

const keys = @import("keys.zig");
const picker_screen = @import("ui/picker_screen.zig");
const run_policy = @import("run_policy.zig");
const RunPolicy = run_policy.RunPolicy;

/// Edits `policies` in place. Returns true when the operator applied
/// the change, false when they cancelled — on cancel the caller's copy
/// is untouched, since the working set is local until `enter`.
pub fn interactive(
    labels: []const []const u8,
    policies: []RunPolicy,
    managed: []const bool,
) !bool {
    if (policies.len == 0) return error.NoDevices;
    if (std.c.isatty(std.posix.STDIN_FILENO) == 0 or std.c.isatty(std.posix.STDOUT_FILENO) == 0) {
        return error.InteractiveSelectionNeedsTty;
    }

    var working: [max_columns]RunPolicy = undefined;
    if (policies.len > working.len) return error.TooManyDevices;
    @memcpy(working[0..policies.len], policies);
    const editing = working[0..policies.len];

    var field: usize = 0;
    var column: usize = 0;
    while (true) {
        // The cursor may only land on a column the frame is actually
        // drawing: a narrow terminal shows fewer devices, and letting
        // the cursor run past them would edit a device off screen.
        const columns = picker_screen.visibleParamColumns(editing.len);
        if (column >= columns) column = 0;
        try picker_screen.renderParams(labels, editing, managed, field, column);
        var pfd = [_]std.posix.pollfd{.{ .fd = std.posix.STDIN_FILENO, .events = std.posix.POLL.IN, .revents = 0 }};
        _ = try std.posix.poll(&pfd, -1);
        var input: [32]u8 = undefined;
        const n = try std.posix.read(std.posix.STDIN_FILENO, &input);
        if (n == 0) return false;
        var burst: keys.Iterator = .{ .bytes = input[0..n] };
        while (burst.next()) |key| switch (key) {
            .cancel => return false,
            .select => {
                @memcpy(policies, editing);
                return true;
            },
            .up => field = if (field == 0) run_policy.Field.all.len - 1 else field - 1,
            .down => field = (field + 1) % run_policy.Field.all.len,
            .left => adjust(editing, field, column, -1),
            .right => adjust(editing, field, column, 1),
            .toggle => column = (column + 1) % columns,
            .unknown => {},
        };
    }
}

/// Ceiling on the grid's width. Matches the dashboard's device cap;
/// the caller never has more policies than that.
const max_columns: usize = 8;

fn adjust(policies: []RunPolicy, field: usize, column: usize, steps: i32) void {
    const f = run_policy.Field.all[field];
    if (column == 0) {
        for (policies) |*policy| policy.* = policy.adjusted(f, steps);
        return;
    }
    const index = column - 1;
    if (index >= policies.len) return;
    policies[index] = policies[index].adjusted(f, steps);
}

test "the ALL column moves every device together" {
    var policies = [_]RunPolicy{ .{ .threads = 4 }, .{ .threads = 6 } };
    adjust(&policies, 0, 0, 2);
    try std.testing.expectEqual(@as(u32, 6), policies[0].threads);
    try std.testing.expectEqual(@as(u32, 8), policies[1].threads);
}

test "a device column moves only that device" {
    var policies = [_]RunPolicy{ .{ .threads = 4 }, .{ .threads = 4 } };
    adjust(&policies, 0, 2, 4);
    try std.testing.expectEqual(@as(u32, 4), policies[0].threads);
    try std.testing.expectEqual(@as(u32, 8), policies[1].threads);
}

test "adjusting past the last device is a no-op, not a write out of bounds" {
    var policies = [_]RunPolicy{.{ .threads = 4 }};
    adjust(&policies, 0, 9, 1);
    try std.testing.expectEqual(@as(u32, 4), policies[0].threads);
}

test "each field moves by its own step" {
    var policies = [_]RunPolicy{.{ .threads = 4, .n_prompt = 16, .n_generate = 32 }};
    adjust(&policies, 1, 1, 1); // prompt tokens, +16
    adjust(&policies, 2, 1, -1); // generate tokens, -16
    try std.testing.expectEqual(@as(u32, 32), policies[0].n_prompt);
    try std.testing.expectEqual(@as(u32, 16), policies[0].n_generate);
}
