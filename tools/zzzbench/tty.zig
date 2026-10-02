//! The bench's one channel to the terminal.
//!
//! Lives here rather than in the `tuiz` module on purpose: the toolkit
//! renders into a caller-supplied writer and never picks an I/O
//! backend, so the choice of `net_compat` (which restores the socket
//! and EINTR-retrying `write` that Zig 0.16 removed from `std.posix`)
//! stays an application concern.

const std = @import("std");
const builtin = @import("builtin");
const net = @import("net_compat");

/// Write every byte to stdout, tolerating short writes.
pub fn write(bytes: []const u8) !void {
    try writeFd(std.posix.STDOUT_FILENO, bytes);
}

/// The same, to stderr. The device picker draws here rather than on
/// stdout: it runs before the dashboard exists, and requiring stdout
/// to be a terminal would break `zzzbench | tee`, which used to reach
/// the picker fine.
pub fn writeErr(bytes: []const u8) !void {
    try writeFd(std.posix.STDERR_FILENO, bytes);
}

/// Format-and-write a single diagnostic line to stderr. Stack-buffered
/// so the diagnostic stays predictable under CI / scripted use.
/// Logging goes to stderr: stdout is reserved for the engine's actual
/// model output (the TUI render path is the one exception, since it
/// owns the terminal display). Tests assert on the UI state instead,
/// so a passing run stays silent.
pub fn diagLine(comptime fmt: []const u8, args: anytype) !void {
    if (builtin.is_test) return;
    var buf: [1024]u8 = undefined;
    const s = try std.fmt.bufPrint(&buf, fmt, args);
    try writeFd(std.posix.STDERR_FILENO, s);
}

fn writeFd(fd: std.posix.fd_t, bytes: []const u8) !void {
    var written: usize = 0;
    while (written < bytes.len) {
        const n = try net.write(fd, bytes[written..]);
        if (n == 0) return;
        written += n;
    }
}
