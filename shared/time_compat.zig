//! Compatibility shim for `std.time.nanoTimestamp`, which was removed in
//! Zig 0.16 in favor of `std.Io.Clock.now(io, .monotonic)`.
//!
//! Threading an `Io` parameter into every bench/test that times a
//! section is an unfeasible amount of churn for what is fundamentally an
//! OS-level monotonic-clock read. This module preserves the 0.15
//! ergonomics by calling `std.c.clock_gettime` / `std.os.linux.clock_gettime`
//! directly. The values returned are equivalent (CLOCK_MONOTONIC, ns).
//!
//! Drop this file when zzz follows the rest of the engine into the
//! Io-threaded clock API.

const std = @import("std");
const builtin = @import("builtin");

const linux = std.os.linux;

/// Returns the current value of the monotonic clock in nanoseconds.
/// Equivalent to the removed `std.time.nanoTimestamp()`.
///
/// `clock_gettime(CLOCK_MONOTONIC)` cannot fail under any documented
/// errno on a kernel that supports the clock (all targets we ship to —
/// Linux >= 2.6.39, Darwin 10.12+, Android). We assert success rather
/// than swallowing the return code so a future toolchain regression
/// surfaces immediately at the timing site instead of as a 0-ns delta.
pub fn nanoTimestamp() i128 {
    // Both the raw Linux syscall (returns `usize`, 0 on success) and the
    // libc shim (returns `c_int`, 0 on success / -1 on failure with
    // errno set) report success as 0 — comparing `rc == 0` works on
    // both paths without needing platform-specific errno decoding.
    if (builtin.os.tag == .linux and !builtin.link_libc) {
        var ts: linux.timespec = undefined;
        const rc = linux.clock_gettime(.MONOTONIC, &ts);
        std.debug.assert(rc == 0);
        return @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
    }
    var ts: std.c.timespec = undefined;
    const rc = std.c.clock_gettime(.MONOTONIC, &ts);
    std.debug.assert(rc == 0);
    return @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
}

/// Returns wall-clock (realtime) seconds since the Unix epoch.
/// Replacement for the removed `std.time.timestamp()`. For human-facing
/// timestamps (e.g. export filenames), not interval measurement — use
/// `nanoTimestamp` for that.
pub fn realtimeSeconds() i64 {
    if (builtin.os.tag == .linux and !builtin.link_libc) {
        var ts: linux.timespec = undefined;
        const rc = linux.clock_gettime(.REALTIME, &ts);
        std.debug.assert(rc == 0);
        return @intCast(ts.sec);
    }
    var ts: std.c.timespec = undefined;
    const rc = std.c.clock_gettime(.REALTIME, &ts);
    std.debug.assert(rc == 0);
    return @intCast(ts.sec);
}
