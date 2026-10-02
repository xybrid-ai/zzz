//! Self-contained, styled snapshots of the exact terminal frame.
//! Only the SGR colors emitted by our renderer become HTML; text is
//! escaped and terminal control commands never become page content.

const std = @import("std");
const theme = @import("theme.zig");

pub const path_capacity = 96;

pub fn save(io: std.Io, parent: std.Io.Dir, bytes: []const u8, timestamp: i64, path_buf: *[path_capacity]u8) ![]const u8 {
    try parent.createDirPath(io, "exports");
    const dir = try parent.openDir(io, "exports", .{});
    defer dir.close(io);
    var stamp_buf: [32]u8 = undefined;
    const stamp = timestampName(timestamp, &stamp_buf);
    for (0..1000) |attempt| {
        var stem_buf: [64]u8 = undefined;
        const stem = if (attempt == 0)
            try std.fmt.bufPrint(&stem_buf, "bench-{s}", .{stamp})
        else
            try std.fmt.bufPrint(&stem_buf, "bench-{s}-{d}", .{ stamp, attempt + 1 });
        writePair(io, dir, stem, bytes) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => return err,
        };
        return std.fmt.bufPrint(path_buf, "exports/{s}.html", .{stem});
    }
    return error.TooManyExports;
}

fn timestampName(timestamp: i64, buf: *[32]u8) []const u8 {
    const epoch = std.time.epoch.EpochSeconds{ .secs = @intCast(@max(0, timestamp)) };
    const year_day = epoch.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_secs = epoch.getDaySeconds();
    return std.fmt.bufPrint(buf, "{d:0>4}{d:0>2}{d:0>2}-{d:0>2}{d:0>2}{d:0>2}", .{
        year_day.year,              @intFromEnum(month_day.month), month_day.day_index + 1,
        day_secs.getHoursIntoDay(), day_secs.getMinutesIntoHour(), day_secs.getSecondsIntoMinute(),
    }) catch unreachable;
}

/// Both files are exclusive creations. A failure removes only files
/// created by this attempt; an earlier export is never overwritten.
fn writePair(io: std.Io, dir: std.Io.Dir, stem: []const u8, bytes: []const u8) !void {
    var html_buf: [72]u8 = undefined;
    var text_buf: [72]u8 = undefined;
    const html_path = try std.fmt.bufPrint(&html_buf, "{s}.html", .{stem});
    const text_path = try std.fmt.bufPrint(&text_buf, "{s}.txt", .{stem});
    const html = try dir.createFile(io, html_path, .{ .exclusive = true });
    defer html.close(io);
    errdefer dir.deleteFile(io, html_path) catch {};
    const text = try dir.createFile(io, text_path, .{ .exclusive = true });
    defer text.close(io);
    errdefer dir.deleteFile(io, text_path) catch {};
    var buffer: [4096]u8 = undefined;
    var writer = html.writer(io, &buffer);
    try renderHtml(&writer.interface, bytes);
    try writer.interface.flush();
    try text.writeStreamingAll(io, bytes);
}

pub fn renderHtml(out: *std.Io.Writer, bytes: []const u8) !void {
    try out.writeAll(
        \\<!doctype html>
        \\<html lang="en"><meta charset="utf-8">
        \\<meta name="viewport" content="width=device-width, initial-scale=1">
        \\<title>zzzbench — benchmark snapshot</title>
        \\<style>
        \\*{box-sizing:border-box}body{margin:0;padding:24px;}
        \\main{width:max-content;min-width:100%;padding:24px 12px;}
        \\pre{margin:0;font-family:ui-monospace,"SFMono-Regular",Menlo,Consolas,monospace;font-size:14px;line-height:1;font-variant-ligatures:none;white-space:pre;}
        \\@media print{body{padding:0;}main{min-width:0;}pre{font-size:8px;}}
    );
    try out.print("body{{background:{s};color:{s};}}</style><body><main><pre>", .{ theme.export_background, theme.text_hex });
    var style: TextStyle = .{};
    var in_span = false;
    var index: usize = 0;
    while (index < bytes.len) {
        if (bytes[index] == 0x1b) {
            const length = escapeLength(bytes[index..]);
            const escape = bytes[index..][0..length];
            if (escape.len >= 3 and escape[1] == '[' and escape[escape.len - 1] == 'm') {
                if (in_span) try out.writeAll("</span>");
                style.apply(escape[2 .. escape.len - 1]);
                try style.openSpan(out);
                in_span = true;
            }
            index += length;
            continue;
        }
        try writeEscapedByte(out, bytes[index]);
        index += 1;
    }
    if (in_span) try out.writeAll("</span>");
    try out.writeAll("</pre></main></body></html>\n");
}

fn writeEscapedByte(out: *std.Io.Writer, byte: u8) !void {
    switch (byte) {
        '&' => try out.writeAll("&amp;"),
        '<' => try out.writeAll("&lt;"),
        '>' => try out.writeAll("&gt;"),
        '"' => try out.writeAll("&quot;"),
        '\'' => try out.writeAll("&#39;"),
        '\n', '\t' => try out.writeByte(byte),
        else => if (byte >= 0x20 and byte != 0x7f) try out.writeByte(byte),
    }
}

fn escapeLength(bytes: []const u8) usize {
    if (bytes.len < 2) return 1;
    if (bytes[1] == '[') {
        for (bytes[2..], 2..) |byte, index| {
            if (byte >= 0x40 and byte <= 0x7e) return index + 1;
        }
        return bytes.len;
    }
    if (bytes[1] == ']') {
        for (bytes[2..], 2..) |byte, index| {
            if (byte == 7) return index + 1;
            if (byte == 0x1b and index + 1 < bytes.len and bytes[index + 1] == '\\') return index + 2;
        }
        return bytes.len;
    }
    return 2;
}

const TextStyle = struct {
    fg: ?[3]u8 = null,
    bg: ?[3]u8 = null,
    bold: bool = false,

    fn apply(self: *TextStyle, sgr: []const u8) void {
        var args: [32]u16 = undefined;
        var count: usize = 0;
        var parts = std.mem.splitScalar(u8, sgr, ';');
        while (parts.next()) |part| {
            if (count == args.len) return;
            args[count] = if (part.len == 0) 0 else std.fmt.parseInt(u16, part, 10) catch return;
            count += 1;
        }
        var index: usize = 0;
        while (index < count) : (index += 1) switch (args[index]) {
            0 => self.* = .{},
            1 => self.bold = true,
            22 => self.bold = false,
            39 => self.fg = null,
            49 => self.bg = null,
            38, 48 => |kind| {
                if (index + 4 >= count or args[index + 1] != 2) return;
                const rgb = args[index + 2 ..][0..3];
                for (rgb) |channel| if (channel > 255) return;
                const color = [3]u8{ @intCast(rgb[0]), @intCast(rgb[1]), @intCast(rgb[2]) };
                if (kind == 38) self.fg = color else self.bg = color;
                index += 4;
            },
            else => {},
        };
    }

    fn openSpan(self: TextStyle, out: *std.Io.Writer) !void {
        try out.writeAll("<span style=\"");
        if (self.fg) |rgb| try out.print("color:rgb({d},{d},{d});", .{ rgb[0], rgb[1], rgb[2] });
        if (self.bg) |rgb| try out.print("background-color:rgb({d},{d},{d});", .{ rgb[0], rgb[1], rgb[2] });
        if (self.bold) try out.writeAll("font-weight:700;");
        try out.writeAll("\">");
    }
};

test "HTML preserves colors and chart cells while escaping text and dropping terminal controls" {
    var buf: [8192]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    const frame = "\x1b[H\x1b[1;38;2;245;197;24mMac <script>&\x1b[0m\n\x1b[48;2;1;2;3m▀▄\x1b[49m✓\x1b[K\x1b[J\x1b]8;;https://example.invalid\x07device\x1b]8;;\x07";
    try renderHtml(&out, frame);
    const html = out.buffered();
    try std.testing.expect(std.mem.indexOf(u8, html, "color:rgb(245,197,24);font-weight:700;") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "background-color:rgb(1,2,3);") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "Mac &lt;script&gt;&amp;") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "▀▄") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "✓") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<script>") == null);
    try std.testing.expect(std.mem.indexOf(u8, html, "example.invalid") == null);
    try std.testing.expect(std.mem.indexOfScalar(u8, html, 0x1b) == null);
}

test "repeated exports preserve earlier snapshots and both representations" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    var path_buf: [path_capacity]u8 = undefined;
    const first = try save(io, tmp.dir, "\x1b[HMac 42.00\x1b[J", 0, &path_buf);
    try std.testing.expectEqualStrings("exports/bench-19700101-000000.html", first);
    const first_html = try tmp.dir.readFileAlloc(io, first, std.testing.allocator, .limited(8192));
    defer std.testing.allocator.free(first_html);
    try std.testing.expect(std.mem.indexOf(u8, first_html, "Mac 42.00") != null);
    const second = try save(io, tmp.dir, "Mac 43.00", 0, &path_buf);
    try std.testing.expectEqualStrings("exports/bench-19700101-000000-2.html", second);
    const raw = try tmp.dir.readFileAlloc(io, "exports/bench-19700101-000000.txt", std.testing.allocator, .limited(8192));
    defer std.testing.allocator.free(raw);
    try std.testing.expectEqualStrings("\x1b[HMac 42.00\x1b[J", raw);
    const second_html = try tmp.dir.readFileAlloc(io, second, std.testing.allocator, .limited(8192));
    defer std.testing.allocator.free(second_html);
    try std.testing.expect(std.mem.indexOf(u8, second_html, "Mac 43.00") != null);
}

test "an existing terminal snapshot is preserved and a failed pair leaves no HTML behind" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.writeFile(io, .{ .sub_path = "existing.txt", .data = "keep me" });
    try std.testing.expectError(error.PathAlreadyExists, writePair(io, tmp.dir, "existing", "new frame"));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "existing.html", .{}));
    const raw = try tmp.dir.readFileAlloc(io, "existing.txt", std.testing.allocator, .limited(8192));
    defer std.testing.allocator.free(raw);
    try std.testing.expectEqualStrings("keep me", raw);
}
