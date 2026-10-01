//! Single-model chooser. The dashboard already owns raw mode and the
//! alternate screen, so this module only reads a bounded key burst and
//! asks `ui/picker_screen.zig` for the frame.

const std = @import("std");
const catalog = @import("model_catalog.zig");
const keys = @import("keys.zig");
const picker_screen = @import("ui/picker_screen.zig");

pub fn interactive(models: []const catalog.Model) !usize {
    if (models.len == 0) return error.NoModels;
    // The frame goes to stdout, the same channel the dashboard draws
    // through, and keys come from stdin. Both have to be a terminal.
    if (std.c.isatty(std.posix.STDIN_FILENO) == 0 or std.c.isatty(std.posix.STDOUT_FILENO) == 0) {
        return error.InteractiveSelectionNeedsTty;
    }
    var cursor = initialCursor(models);
    while (true) {
        try picker_screen.renderPicker(models, cursor, picker_screen.visibleRows(models.len));
        var pfd = [_]std.posix.pollfd{.{ .fd = std.posix.STDIN_FILENO, .events = std.posix.POLL.IN, .revents = 0 }};
        _ = try std.posix.poll(&pfd, -1);
        var input: [32]u8 = undefined;
        const n = try std.posix.read(std.posix.STDIN_FILENO, &input);
        if (n == 0) return error.SelectionCancelled;
        var burst: keys.Iterator = .{ .bytes = input[0..n] };
        while (burst.next()) |key| switch (key) {
            .cancel => return error.SelectionCancelled,
            .select => if (selection(models, cursor)) |index| return index,
            .up => cursor = previous(cursor, models.len),
            .down => cursor = next(cursor, models.len),
            .toggle, .left, .right, .unknown => {},
        };
    }
}

fn initialCursor(models: []const catalog.Model) usize {
    for (models, 0..) |_, index| {
        if (selection(models, index) != null) return index;
    }
    return 0;
}

fn selection(models: []const catalog.Model, cursor: usize) ?usize {
    if (cursor >= models.len or models[cursor].unavailableReason() != null) return null;
    return cursor;
}

fn previous(cursor: usize, len: usize) usize {
    return if (cursor == 0) len - 1 else cursor - 1;
}

fn next(cursor: usize, len: usize) usize {
    return (cursor + 1) % len;
}

test "model picker navigation wraps in both directions" {
    try std.testing.expectEqual(@as(usize, 2), previous(0, 3));
    try std.testing.expectEqual(@as(usize, 0), next(2, 3));
}

test "model picker starts on a decode model and refuses an embedding model" {
    const bge: catalog.Model = .{
        .path = "/models/bge.gguf",
        .name = "BGE",
        .quant = "F16",
        .architecture = "bert",
        .parameter_count = 33_000_000,
        .size_bytes = 67_000_000,
        .source = .huggingface,
    };
    var gemma = bge;
    gemma.architecture = "gemma3";
    const models = [_]catalog.Model{ bge, gemma };
    try std.testing.expectEqual(@as(usize, 1), initialCursor(&models));
    try std.testing.expect(selection(&models, 0) == null);
    try std.testing.expectEqual(@as(?usize, 1), selection(&models, 1));
    try std.testing.expect(selection(&models, 2) == null);
    try std.testing.expect(selection(&.{bge}, initialCursor(&.{bge})) == null);
}
