//! Internal sync primitives that preserve the zero-arg API of 0.15.2
//! (`Mutex.lock/unlock`, `Condition.wait/signal/broadcast`, `Semaphore.wait/post`)
//! on top of 0.16.0's `std.Io`-based primitives.
//!
//! Implementation: call the `*Uncancelable` variants on a static
//! `std.Io.Threaded.global_single_threaded` instance. The futex vtable
//! functions in `std.Io.Threaded` ignore their `userdata` parameter for the
//! uncancelable path, so this is safe to call from any thread regardless of
//! whether it is registered with a `Threaded` runtime.

const std = @import("std");

inline fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

pub const Mutex = struct {
    inner: std.Io.Mutex = .init,

    pub fn lock(self: *Mutex) void {
        self.inner.lockUncancelable(io());
    }

    pub fn unlock(self: *Mutex) void {
        self.inner.unlock(io());
    }

    pub fn tryLock(self: *Mutex) bool {
        return self.inner.tryLock();
    }
};

pub const Condition = struct {
    state: std.atomic.Value(State) = .init(.{ .waiters = 0, .signals = 0 }),
    epoch: std.atomic.Value(u32) = .init(0),

    const State = packed struct(u32) {
        waiters: u16,
        signals: u16,
    };

    pub fn wait(self: *Condition, m: *Mutex) void {
        self.waitInner(m, .none) catch |err| switch (err) {
            error.Timeout => unreachable,
        };
    }

    pub fn timedWait(self: *Condition, m: *Mutex, timeout_ns: u64) error{Timeout}!void {
        return self.waitInner(m, .{ .duration = .{
            .raw = .fromNanoseconds(@intCast(timeout_ns)),
            .clock = .real,
        } });
    }

    fn waitInner(self: *Condition, m: *Mutex, timeout: std.Io.Timeout) error{Timeout}!void {
        var epoch = self.epoch.load(.acquire);
        {
            const prev_state = self.state.fetchAdd(.{ .waiters = 1, .signals = 0 }, .monotonic);
            std.debug.assert(prev_state.waiters < std.math.maxInt(u16));
        }

        m.inner.unlock(io());
        defer m.inner.lockUncancelable(io());

        const deadline: std.Io.Timeout = switch (timeout) {
            .none => .none,
            else => timeout.toDeadline(io()),
        };

        while (true) {
            switch (deadline) {
                .none => io().futexWaitUncancelable(u32, &self.epoch.raw, epoch),
                else => io().futexWaitTimeout(u32, &self.epoch.raw, epoch, deadline) catch {},
            }

            epoch = self.epoch.load(.acquire);

            // Try to consume a pending signal first.
            {
                var prev_state = self.state.load(.monotonic);
                while (prev_state.signals > 0) {
                    prev_state = self.state.cmpxchgWeak(prev_state, .{
                        .waiters = prev_state.waiters - 1,
                        .signals = prev_state.signals - 1,
                    }, .acquire, .monotonic) orelse return;
                }
            }

            // No signal: decide whether to loop or give up on timeout.
            switch (deadline) {
                .none => {}, // spurious wake; loop
                else => {
                    const remaining = deadline.toDurationFromNow(io()) orelse break;
                    if (remaining.raw.nanoseconds <= 0) break;
                },
            }
        }

        const prev_state = self.state.fetchSub(.{ .waiters = 1, .signals = 0 }, .monotonic);
        std.debug.assert(prev_state.waiters > 0);
        return error.Timeout;
    }

    pub fn signal(self: *Condition) void {
        var prev_state = self.state.load(.monotonic);
        while (prev_state.waiters > prev_state.signals) {
            prev_state = self.state.cmpxchgWeak(prev_state, .{
                .waiters = prev_state.waiters,
                .signals = prev_state.signals + 1,
            }, .release, .monotonic) orelse {
                _ = self.epoch.fetchAdd(1, .release);
                io().futexWake(u32, &self.epoch.raw, 1);
                return;
            };
        }
    }

    pub fn broadcast(self: *Condition) void {
        var prev_state = self.state.load(.monotonic);
        while (prev_state.waiters > prev_state.signals) {
            prev_state = self.state.cmpxchgWeak(prev_state, .{
                .waiters = prev_state.waiters,
                .signals = prev_state.waiters,
            }, .release, .monotonic) orelse {
                _ = self.epoch.fetchAdd(1, .release);
                io().futexWake(u32, &self.epoch.raw, prev_state.waiters - prev_state.signals);
                return;
            };
        }
    }
};

pub const Semaphore = struct {
    inner: std.Io.Semaphore = .{},

    pub fn wait(self: *Semaphore) void {
        self.inner.waitUncancelable(io());
    }

    pub fn post(self: *Semaphore) void {
        self.inner.post(io());
    }
};
