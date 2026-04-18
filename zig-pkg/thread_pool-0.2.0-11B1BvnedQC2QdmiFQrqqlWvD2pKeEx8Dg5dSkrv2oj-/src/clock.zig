//! Clock wrappers that preserve the zero-arg API of 0.15.2
//! (`std.time.nanoTimestamp`, `std.Thread.sleep`) on top of 0.16.0 primitives.
//!
//! `nanoTimestamp` uses `std.Io.Clock.Timestamp.now` on the static
//! `global_single_threaded` Io (the `now` vtable fn ignores `userdata`).
//!
//! `sleep` uses `std.posix.system.nanosleep` on POSIX and `ntdll.NtDelayExecution`
//! on Windows (the old `kernel32.Sleep` wrapper is gone in 0.16). Both are
//! uncancelable and do not require any async state.

const std = @import("std");
const builtin = @import("builtin");

pub fn nanoTimestamp() i96 {
    const io = std.Io.Threaded.global_single_threaded.io();
    return std.Io.Clock.Timestamp.now(io, .real).raw.nanoseconds;
}

pub fn sleep(nanoseconds: u64) void {
    if (builtin.os.tag == .windows) {
        // Negative DelayInterval = relative in 100ns units (NtDelayExecution
        // contract). Cap at i64 max to avoid overflow for huge sleeps.
        const ns_100: u64 = nanoseconds / 100;
        const clamped: u64 = @min(ns_100, @as(u64, std.math.maxInt(i64)));
        const interval: std.os.windows.LARGE_INTEGER = -@as(std.os.windows.LARGE_INTEGER, @intCast(clamped));
        _ = std.os.windows.ntdll.NtDelayExecution(.FALSE, &interval);
        return;
    }

    const ns_per_s = std.time.ns_per_s;
    const sec: u64 = nanoseconds / ns_per_s;
    const nsec: u64 = nanoseconds % ns_per_s;
    var req: std.posix.timespec = .{
        .sec = @intCast(sec),
        .nsec = @intCast(nsec),
    };
    var rem: std.posix.timespec = undefined;
    while (true) {
        const rc = std.posix.system.nanosleep(&req, &rem);
        const err = std.posix.errno(rc);
        switch (err) {
            .SUCCESS => return,
            .INTR => {
                req = rem;
                continue;
            },
            else => return,
        }
    }
}
