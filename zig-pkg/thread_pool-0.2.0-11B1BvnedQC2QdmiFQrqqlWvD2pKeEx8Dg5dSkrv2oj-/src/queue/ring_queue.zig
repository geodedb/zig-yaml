const std = @import("std");

/// Lock-free SPMC ring queue modelled after Tokio's
/// `runtime/scheduler/multi_thread/queue.rs` and Go's `runq*` in
/// `runtime/proc.go`. Single producer (owner) pushes to `tail` and pops
/// from `tail` LIFO. Any thread may steal from `head` in batches.
///
/// Correctness sketch:
/// - Owner is the sole writer of `tail` and of slot contents.
/// - Stealers synchronize with each other via a seq_cst CAS on `head`.
///   The CAS is the linearization point: all slot reads within a single
///   batch are committed atomically from the stealer's POV.
/// - Owner never writes to any index `i` where `head <= i < tail`, so
///   stealers that copy slots between their `head` load and their CAS on
///   `head` cannot race the owner — worst case another stealer wins
///   the CAS and this stealer's slot reads are discarded.
/// - Owner-vs-stealer race on the last element: same pattern as
///   Chase-Lev's `popBottom`. Owner does a seq_cst fence and re-reads
///   `head` before claiming the slot; if the stealer has moved head past
///   the slot, the owner backs off.
///
/// Buffer size must be a power of 2.
pub fn RingQueue(comptime T: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        buffer: []std.atomic.Value(T),
        mask: u32,
        head: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
        tail: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

        pub fn init(allocator: std.mem.Allocator, size: usize) !Self {
            std.debug.assert(size > 0 and (size & (size - 1)) == 0);
            std.debug.assert(size <= std.math.maxInt(u32) / 2);
            const buf = try allocator.alloc(std.atomic.Value(T), size);
            for (buf) |*slot| slot.* = std.atomic.Value(T).init(undefined);
            return .{
                .allocator = allocator,
                .buffer = buf,
                .mask = @intCast(size - 1),
            };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.buffer);
            self.* = undefined;
        }

        pub fn capacity(self: *const Self) usize {
            return self.buffer.len;
        }

        /// Approximate count. Safe from any thread; may be stale.
        pub fn len(self: *const Self) usize {
            const t = self.tail.load(.acquire);
            const h = self.head.load(.acquire);
            const diff = t -% h;
            // Owner's `pop` transiently stores `tail = t-1` before the empty-check;
            // a stealer reading that intermediate tail with a still-current head
            // computes `t -% h` as a wrapped value > capacity. Clamp to 0 so
            // callers (stats peak tracking, empty-victim skip) see a consistent
            // "empty or near-empty" state rather than ~u32_max.
            if (diff > @as(u32, @intCast(self.buffer.len))) return 0;
            return diff;
        }

        /// Owner-only. Push an item to the tail. Returns false if full.
        pub fn tryPush(self: *Self, value: T) bool {
            const t = self.tail.load(.monotonic);
            const h = self.head.load(.acquire);
            if (t -% h >= @as(u32, @intCast(self.buffer.len))) return false;
            self.buffer[t & self.mask].store(value, .unordered);
            // Release ensures the slot write is visible before tail advances.
            self.tail.store(t +% 1, .release);
            return true;
        }

        /// Owner-only. Pop from the tail (LIFO). Returns null if empty.
        pub fn pop(self: *Self) ?T {
            const t = self.tail.load(.monotonic);
            const new_tail = t -% 1;
            // Reserve the slot by dropping tail first; seq_cst pair with
            // stealers' CAS on head resolves the last-element race.
            self.tail.store(new_tail, .seq_cst);
            const h = self.head.load(.seq_cst);
            if (h == t) {
                // Queue was empty — restore tail and bail.
                self.tail.store(t, .monotonic);
                return null;
            }
            const value = self.buffer[new_tail & self.mask].load(.monotonic);
            if (h == new_tail) {
                // Last element: race with stealers.
                if (self.head.cmpxchgStrong(h, h +% 1, .seq_cst, .monotonic) != null) {
                    // A stealer won; queue is now empty.
                    self.tail.store(t, .monotonic);
                    return null;
                }
                // We won — publish the empty state.
                self.tail.store(t, .monotonic);
            }
            return value;
        }

        /// Any thread. Steal up to `(len+1)/2` items into `dst`. Returns the
        /// number stolen (0..dst.len). Copies happen *before* the CAS; on
        /// CAS failure we retry the whole batch. No ABA because `head` is
        /// monotonically increasing within the u32 range we actually use.
        pub fn stealHalf(self: *Self, dst: []T) usize {
            if (dst.len == 0) return 0;
            // Retry budget. The transient `avail > capacity` window (owner
            // mid-pop) and CAS-contention retries should resolve within a
            // handful of iterations; anything longer signals either a genuine
            // livelock (e.g. pre-existing head-past-tail wrap state reached
            // via a still-uncharacterized race in pop/steal) or a degenerate
            // contention pattern that's better served by moving to the next
            // victim. Cap rather than spin forever so shutdown cannot stall
            // waiting for a livelocked worker to leave stealHalf.
            var retries: u32 = 0;
            while (true) {
                if (retries >= 256) return 0;
                retries += 1;
                const h = self.head.load(.acquire);
                // Acquire on tail pairs with the owner's release on push.
                const t = self.tail.load(.acquire);
                const avail = t -% h;
                if (avail == 0) return 0;
                // Owner's `pop` transiently stores `tail = t-1` before checking
                // for the empty race; a stealer observing that intermediate
                // tail alongside an unchanged head sees `avail` wrap past
                // buffer capacity. Treat it as a transient inconsistent read
                // and retry rather than trusting the value.
                if (avail > @as(u32, @intCast(self.buffer.len))) continue;
                // Steal half (round up) — matches Tokio/Go.
                var n: u32 = (avail + 1) / 2;
                if (n > @as(u32, @intCast(dst.len))) n = @intCast(dst.len);

                var i: u32 = 0;
                while (i < n) : (i += 1) {
                    dst[i] = self.buffer[(h +% i) & self.mask].load(.monotonic);
                }

                if (self.head.cmpxchgStrong(h, h +% n, .seq_cst, .monotonic) == null) {
                    return n;
                }
                // CAS failed: another stealer (or owner last-element race)
                // moved head. Retry — the slot reads are discarded.
            }
        }
    };
}

test "ring queue: push/pop LIFO" {
    const Q = RingQueue(u32);
    var q = try Q.init(std.testing.allocator, 8);
    defer q.deinit();

    try std.testing.expect(q.tryPush(1));
    try std.testing.expect(q.tryPush(2));
    try std.testing.expect(q.tryPush(3));
    try std.testing.expectEqual(@as(?u32, 3), q.pop());
    try std.testing.expectEqual(@as(?u32, 2), q.pop());
    try std.testing.expectEqual(@as(?u32, 1), q.pop());
    try std.testing.expectEqual(@as(?u32, null), q.pop());
}

test "ring queue: full rejects push" {
    const Q = RingQueue(u32);
    var q = try Q.init(std.testing.allocator, 2);
    defer q.deinit();

    try std.testing.expect(q.tryPush(10));
    try std.testing.expect(q.tryPush(20));
    try std.testing.expect(!q.tryPush(30));
    try std.testing.expectEqual(@as(usize, 2), q.len());
}

test "ring queue: stealHalf copies half and advances head" {
    const Q = RingQueue(u32);
    var q = try Q.init(std.testing.allocator, 16);
    defer q.deinit();
    var i: u32 = 0;
    while (i < 10) : (i += 1) _ = q.tryPush(i);

    var out: [16]u32 = undefined;
    const n = q.stealHalf(out[0..]);
    // (10+1)/2 = 5
    try std.testing.expectEqual(@as(usize, 5), n);
    try std.testing.expectEqual(@as(u32, 0), out[0]);
    try std.testing.expectEqual(@as(u32, 4), out[4]);
    try std.testing.expectEqual(@as(usize, 5), q.len());
}

test "ring queue: stealHalf empty returns 0" {
    const Q = RingQueue(u32);
    var q = try Q.init(std.testing.allocator, 16);
    defer q.deinit();
    var out: [4]u32 = undefined;
    try std.testing.expectEqual(@as(usize, 0), q.stealHalf(out[0..]));
}

test "ring queue: stealHalf caps at dst.len" {
    const Q = RingQueue(u32);
    var q = try Q.init(std.testing.allocator, 16);
    defer q.deinit();
    var i: u32 = 0;
    while (i < 10) : (i += 1) _ = q.tryPush(i);

    var out: [2]u32 = undefined;
    const n = q.stealHalf(out[0..]);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqual(@as(u32, 0), out[0]);
    try std.testing.expectEqual(@as(u32, 1), out[1]);
}

test "ring queue: wraparound via head advance" {
    const Q = RingQueue(u32);
    var q = try Q.init(std.testing.allocator, 4);
    defer q.deinit();
    try std.testing.expect(q.tryPush(1));
    try std.testing.expect(q.tryPush(2));
    var out: [1]u32 = undefined;
    _ = q.stealHalf(out[0..]); // consumes 1 (since (2+1)/2 = 1)
    try std.testing.expect(q.tryPush(3));
    try std.testing.expect(q.tryPush(4));
    try std.testing.expect(q.tryPush(5));
    try std.testing.expect(!q.tryPush(6)); // full (head=1, tail=5, capacity=4)
}
