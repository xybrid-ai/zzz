//! Socket operations used by zzzprobe and zzzbench.
//!
//! Zig 0.16 removed `socket`, `bind`, `listen`, `accept`, `connect`,
//! `getsockopt`, `fcntl`, `write`, and `close` from `std.posix`, and
//! deleted `std.net` entirely, in favor of the `std.Io.net` vtable
//! interface. The tools run a single-client `poll()` event loop: the probe
//! streams 10 Hz telemetry to one bench viewer over one socket.
//!
//! This module provides the required calls, routing
//! to raw `std.os.linux` syscalls on Linux/Android (where zzzprobe
//! ships, often without libc) and to libc on Darwin (where zzzbench, the
//! host TUI, runs and already links libc for `ioctl`/`TIOCGWINSZ`).
//!
//! Functions that survived the 0.16 cull — `setsockopt`, `poll`, `read`
//! — are still called as `std.posix.*` directly at the use sites; only
//! the removed ones are re-exported here.

const std = @import("std");
const builtin = @import("builtin");

const linux = std.os.linux;
const is_linux = builtin.os.tag == .linux;

pub const fd_t = std.posix.fd_t;
pub const socklen_t = std.posix.socklen_t;
pub const sockaddr = std.posix.sockaddr;

/// Errors surfaced to the tools. The set is intentionally narrow: the
/// `poll()`-driven call sites only branch on `WouldBlock`, `BrokenPipe`,
/// and `ConnectionResetByPeer`; everything else is a fail-fast setup
/// error that aborts the connection attempt.
pub const Error = error{
    WouldBlock,
    BrokenPipe,
    ConnectionResetByPeer,
    ConnectionRefused,
    /// Bind target already in use — typically a probe is already running
    /// on this port/path. The common operator error; surfaced distinctly
    /// so the message says what to do (kill the other probe) instead of
    /// the opaque catch-all.
    AddressInUse,
    AddressNotAvailable,
    PermissionDenied,
    SocketError,
};

/// Decode a raw Linux syscall return into the kept-narrow `Error` set,
/// or `null` on success. `std.os.linux.errno` maps the `[-4095, -1]`
/// return range to an `E` enum (`.SUCCESS` otherwise).
fn linuxErr(rc: usize) ?Error {
    return switch (linux.errno(rc)) {
        .SUCCESS => null,
        .AGAIN => Error.WouldBlock,
        .INPROGRESS => Error.WouldBlock,
        .PIPE => Error.BrokenPipe,
        .CONNRESET => Error.ConnectionResetByPeer,
        .CONNREFUSED => Error.ConnectionRefused,
        .ADDRINUSE => Error.AddressInUse,
        .ADDRNOTAVAIL => Error.AddressNotAvailable,
        .ACCES => Error.PermissionDenied,
        else => Error.SocketError,
    };
}

/// Decode a libc return (`-1` sentinel + thread-local errno) into the
/// kept-narrow `Error` set, or `null` on success.
fn libcErr(rc: anytype) ?Error {
    return switch (std.posix.errno(rc)) {
        .SUCCESS => null,
        .AGAIN => Error.WouldBlock,
        .INPROGRESS => Error.WouldBlock,
        .PIPE => Error.BrokenPipe,
        .CONNRESET => Error.ConnectionResetByPeer,
        .CONNREFUSED => Error.ConnectionRefused,
        .ADDRINUSE => Error.AddressInUse,
        .ADDRNOTAVAIL => Error.AddressNotAvailable,
        .ACCES => Error.PermissionDenied,
        else => Error.SocketError,
    };
}

pub fn socket(domain: u32, socket_type: u32, protocol: u32) Error!fd_t {
    if (is_linux) {
        // Linux accepts SOCK_NONBLOCK / SOCK_CLOEXEC OR'd into the type
        // argument directly.
        const rc = linux.socket(domain, socket_type, protocol);
        if (linuxErr(rc)) |e| return e;
        return @intCast(rc);
    }
    // Darwin's socket(2) rejects the Linux-only SOCK_NONBLOCK /
    // SOCK_CLOEXEC type bits (EINVAL). Strip them, create the socket,
    // then apply non-blocking via fcntl.
    const nonblock_requested = socket_type & std.posix.SOCK.NONBLOCK != 0;
    const filtered = socket_type & ~@as(u32, std.posix.SOCK.NONBLOCK | std.posix.SOCK.CLOEXEC);
    const rc = std.c.socket(@intCast(domain), @intCast(filtered), @intCast(protocol));
    if (libcErr(rc)) |e| return e;
    const fd: fd_t = rc;
    if (nonblock_requested) {
        setNonBlocking(fd) catch {
            close(fd);
            return Error.SocketError;
        };
    }
    return fd;
}

pub fn bind(fd: fd_t, addr: *const sockaddr, len: socklen_t) Error!void {
    if (is_linux) {
        if (linuxErr(linux.bind(fd, addr, len))) |e| return e;
        return;
    }
    if (libcErr(std.c.bind(fd, addr, len))) |e| return e;
}

pub fn listen(fd: fd_t, backlog: u31) Error!void {
    if (is_linux) {
        if (linuxErr(linux.listen(fd, backlog))) |e| return e;
        return;
    }
    if (libcErr(std.c.listen(fd, backlog))) |e| return e;
}

/// Accept a connection. `flags` accepts `std.posix.SOCK.NONBLOCK`. On
/// Linux this maps to `accept4`'s flags argument; on Darwin (no
/// `accept4`) the flag is applied with a follow-up `fcntl` so callers
/// get identical non-blocking semantics on both platforms.
pub fn accept(
    fd: fd_t,
    addr: ?*sockaddr,
    addr_len: ?*socklen_t,
    flags: u32,
) Error!fd_t {
    if (is_linux) {
        const rc = linux.accept4(fd, addr, addr_len, flags);
        if (linuxErr(rc)) |e| return e;
        return @intCast(rc);
    }
    const rc = std.c.accept(fd, addr, addr_len);
    if (libcErr(rc)) |e| return e;
    const client: fd_t = rc;
    if (flags & std.posix.SOCK.NONBLOCK != 0) {
        setNonBlocking(client) catch {
            close(client);
            return Error.SocketError;
        };
    }
    return client;
}

pub fn connect(fd: fd_t, addr: *const sockaddr, len: socklen_t) Error!void {
    if (is_linux) {
        if (linuxErr(linux.connect(fd, addr, len))) |e| return e;
        return;
    }
    if (libcErr(std.c.connect(fd, addr, len))) |e| return e;
}

pub fn getsockopt(fd: fd_t, level: i32, optname: u32, opt: []u8) Error!void {
    var len: socklen_t = @intCast(opt.len);
    if (is_linux) {
        if (linuxErr(linux.getsockopt(fd, level, optname, opt.ptr, &len))) |e| return e;
        return;
    }
    if (libcErr(std.c.getsockopt(fd, level, optname, opt.ptr, &len))) |e| return e;
}

/// Write all-or-some. Returns bytes written (> 0) or one of
/// `WouldBlock` / `BrokenPipe` / `ConnectionResetByPeer`, matching the
/// errors the tool write loops already branch on.
///
/// `EINTR` is retried internally (bounded) rather than surfaced — a
/// signal arriving mid-write (e.g. SIGWINCH while zzzbench is painting
/// the TUI to stdout, which now routes through this shim) must not
/// collapse to a fatal `SocketError` and tear down the render loop.
/// Retrying `EINTR` keeps interrupted writes from failing the render loop.
pub fn write(fd: fd_t, bytes: []const u8) Error!usize {
    var retries: u32 = 0;
    const retries_max: u32 = 256;
    while (true) {
        // Intercept EINTR for the retry, then delegate every other
        // outcome to the shared errno helpers — keeps each backend block
        // straightforward and consistent with the rest of the file.
        if (is_linux) {
            const rc = linux.write(fd, bytes.ptr, bytes.len);
            if (linux.errno(rc) == .INTR) {
                retries += 1;
                if (retries >= retries_max) return Error.SocketError;
                continue;
            }
            if (linuxErr(rc)) |e| return e;
            return @intCast(rc);
        } else {
            const rc = std.c.write(fd, bytes.ptr, bytes.len);
            if (std.posix.errno(rc) == .INTR) {
                retries += 1;
                if (retries >= retries_max) return Error.SocketError;
                continue;
            }
            if (libcErr(rc)) |e| return e;
            return @intCast(rc);
        }
    }
}

pub fn close(fd: fd_t) void {
    if (is_linux) {
        _ = linux.close(fd);
        return;
    }
    _ = std.c.close(fd);
}

/// Remove a filesystem path. Used to clear a stale Unix-domain socket
/// node before re-binding (the listener path must not already exist).
/// `std.fs.deleteFileAbsolute` was removed in 0.16; this is the raw
/// `unlink(2)` equivalent. Errors are intentionally swallowed by the
/// single caller (a missing path is the common, fine case).
pub fn unlink(path: []const u8) void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    if (path.len >= buf.len) return;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    const z: [*:0]const u8 = @ptrCast(&buf);
    if (is_linux) {
        _ = linux.unlink(z);
        return;
    }
    _ = std.c.unlink(z);
}

/// Read an absolute-path file into `buf`, returning the filled slice or
/// `null` on any error. Loops `readStreaming` to fill the buffer (a
/// single read can be short). Used by the Linux sysfs sampler for small
/// `/proc` and `/sys` files. `std.fs.openFileAbsolute` + `readAll` were
/// removed/reworked in 0.16; this wrapper provides a bounded read.
pub fn readFileAbsolute(io: std.Io, path: []const u8, buf: []u8) ?[]u8 {
    const file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch return null;
    defer file.close(io);
    var total: usize = 0;
    while (total < buf.len) {
        // readStreaming signals EOF by *throwing* `error.EndOfStream`
        // (not by returning 0) — see std.Io.File.ReadStreamingError. EOF
        // is the normal terminator here, so break and return what we
        // read; any OTHER error is a genuine failure, so return null and
        // let the caller skip the sample. (An earlier `catch return null`
        // mistook EOF for failure and discarded every fully-read /proc
        // and /sys file, blanking all on-device telemetry.)
        const n = file.readStreaming(io, &.{buf[total..]}) catch |e| switch (e) {
            error.EndOfStream => break,
            else => return null,
        };
        if (n == 0) break;
        total += n;
    }
    return buf[0..total];
}

/// Set `O_NONBLOCK` on `fd` via `fcntl`. Used by the engine-stdout pipe
/// in zzzprobe and the Darwin `accept` path above.
pub fn setNonBlocking(fd: fd_t) Error!void {
    const nonblock_bit: usize = 1 << @bitOffsetOf(std.posix.O, "NONBLOCK");
    if (is_linux) {
        const flags = linux.fcntl(fd, std.posix.F.GETFL, 0);
        if (linuxErr(flags)) |e| return e;
        if (linuxErr(linux.fcntl(fd, std.posix.F.SETFL, flags | nonblock_bit))) |e| return e;
        return;
    }
    const flags = std.c.fcntl(fd, std.posix.F.GETFL);
    if (libcErr(flags)) |e| return e;
    const flags_u: usize = @intCast(flags);
    if (libcErr(std.c.fcntl(fd, std.posix.F.SETFL, flags_u | nonblock_bit))) |e| return e;
}

/// Drop-in for the removed `std.net.Address`, scoped to the two address
/// families the tools use: IPv4 loopback (TCP) and Unix-domain (path or
/// abstract). Holds the platform `sockaddr` inline so `ptr()`/`len()`
/// hand a stable pointer to `bind`/`connect`.
pub const Address = union(enum) {
    in: sockaddr.in,
    un: struct { sa: sockaddr.un, len: socklen_t },

    pub fn initIp4(addr_bytes: [4]u8, port: u16) Address {
        return .{
            .in = .{
                // Port is network byte order; the 4 address bytes are
                // already network order, so reinterpret them as a u32
                // without swapping.
                .port = std.mem.nativeToBig(u16, port),
                .addr = @bitCast(addr_bytes),
            },
        };
    }

    /// Build an IPv4 TCP address from either a dotted-quad literal or,
    /// on Darwin hosts, a DNS/mDNS hostname. zzzbench uses this for
    /// non-Android device probes such as `tcp:iphone.local:7779`.
    pub fn initIp4Host(host: []const u8, port: u16) Error!Address {
        if (parseIp4Bytes(host)) |bytes| return initIp4(bytes, port);

        // Linux/Android zzzprobe never needs outbound hostname connects.
        // Keep that path libc-free; Darwin zzzbench already depends on
        // libc for sockets and terminal sizing.
        if (is_linux) return Error.SocketError;

        var host_buf: [256]u8 = undefined;
        if (host.len == 0 or host.len >= host_buf.len) return Error.SocketError;
        @memcpy(host_buf[0..host.len], host);
        host_buf[host.len] = 0;
        const host_z: [*:0]const u8 = @ptrCast(&host_buf);

        var service_buf: [16]u8 = undefined;
        const service_z = std.fmt.bufPrintZ(&service_buf, "{d}", .{port}) catch return Error.SocketError;

        var hints = std.mem.zeroes(std.c.addrinfo);
        hints.family = @intCast(std.posix.AF.INET);
        hints.socktype = @intCast(std.posix.SOCK.STREAM);

        var resolved: ?*std.c.addrinfo = null;
        const rc = std.c.getaddrinfo(host_z, service_z.ptr, &hints, &resolved);
        if (@intFromEnum(rc) != 0) return Error.SocketError;
        const head = resolved orelse return Error.SocketError;
        defer std.c.freeaddrinfo(head);

        var it: ?*std.c.addrinfo = head;
        while (it) |ai| : (it = ai.next) {
            if (ai.family != std.posix.AF.INET) continue;
            const raw = ai.addr orelse continue;
            const sin: *const sockaddr.in = @ptrCast(@alignCast(raw));
            return .{ .in = sin.* };
        }
        return Error.SocketError;
    }

    /// Build a Unix-domain address. A leading '@' selects the Linux
    /// abstract namespace (first path byte is NUL, name follows). The
    /// returned `len` covers only the bytes actually used so the kernel
    /// doesn't read past the name.
    pub fn initUnix(path: []const u8) Error!Address {
        var sa = sockaddr.un{ .family = std.posix.AF.UNIX, .path = undefined };
        if (path.len >= sa.path.len) return Error.SocketError;
        @memset(&sa.path, 0);
        if (path.len > 0 and path[0] == '@') {
            // Abstract socket: leading NUL, then the name (sans '@').
            sa.path[0] = 0;
            @memcpy(sa.path[1 .. 1 + (path.len - 1)], path[1..]);
        } else {
            @memcpy(sa.path[0..path.len], path);
        }
        // Address length = sun_family offset + bytes of sun_path in use.
        // Abstract sockets use exactly `path.len` bytes (leading NUL +
        // the `path.len - 1` name chars) and must NOT include a trailing
        // NUL — appending one makes the name `\x00foo\x00`, which won't
        // match a peer bound to `\x00foo`. Filesystem sockets include
        // the NUL terminator, so `path.len + 1`.
        const is_abstract = path.len > 0 and path[0] == '@';
        const path_used: socklen_t = @intCast(if (is_abstract) path.len else path.len + 1);
        const family_len: socklen_t = @intCast(@offsetOf(sockaddr.un, "path"));
        return .{ .un = .{ .sa = sa, .len = family_len + path_used } };
    }

    pub fn ptr(self: *const Address) *const sockaddr {
        return switch (self.*) {
            .in => |*a| @ptrCast(a),
            .un => |*a| @ptrCast(&a.sa),
        };
    }

    pub fn len(self: *const Address) socklen_t {
        return switch (self.*) {
            .in => @sizeOf(sockaddr.in),
            .un => |a| a.len,
        };
    }
};

fn parseIp4Bytes(text: []const u8) ?[4]u8 {
    var parts: [4]u8 = undefined;
    var count: usize = 0;
    var it = std.mem.splitScalar(u8, text, '.');
    while (it.next()) |part| {
        if (count >= parts.len or part.len == 0) return null;
        parts[count] = std.fmt.parseInt(u8, part, 10) catch return null;
        count += 1;
    }
    if (count != parts.len) return null;
    return parts;
}
