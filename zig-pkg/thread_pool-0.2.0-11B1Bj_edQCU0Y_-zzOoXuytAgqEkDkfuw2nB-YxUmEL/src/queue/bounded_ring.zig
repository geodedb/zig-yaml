const std = @import("std");

/// Lock-free bounded MPMC queue (Vyukov design).
///
/// Multiple producers call `tryPush`. Multiple consumers call `pop`.
/// Buffer size must be a power of 2.
pub fn BoundedRing(comptime T: type) type {
    return struct {
        const Self = @This();

        const Slot = struct {
            sequence: std.atomic.Value(usize),
            value: T,
        };

        allocator: std.mem.Allocator,
        buffer: []Slot,
        mask: usize,
        head: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
        _pad_head: [std.atomic.cache_line - @sizeOf(std.atomic.Value(usize))]u8 = undefined,
        tail: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

        pub fn init(allocator: std.mem.Allocator, size: usize) !Self {
            std.debug.assert(size > 0 and (size & (size - 1)) == 0);
            const buf = try allocator.alloc(Slot, size);
            for (buf, 0..) |*slot, i| {
                slot.* = .{
                    .sequence = std.atomic.Value(usize).init(i),
                    .value = undefined,
                };
            }
            return .{
                .allocator = allocator,
                .buffer = buf,
                .mask = size - 1,
            };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.buffer);
            self.* = undefined;
        }

        pub fn tryPush(self: *Self, value: T) bool {
            var tail = self.tail.load(.monotonic);
            while (true) {
                const slot = &self.buffer[tail & self.mask];
                const seq = slot.sequence.load(.acquire);
                const diff = @as(isize, @intCast(seq)) -% @as(isize, @intCast(tail));
                if (diff == 0) {
                    if (self.tail.cmpxchgWeak(tail, tail +% 1, .monotonic, .monotonic)) |actual| {
                        tail = actual;
                        continue;
                    }
                    slot.value = value;
                    slot.sequence.store(tail +% 1, .release);
                    return true;
                } else if (diff < 0) {
                    return false;
                } else {
                    tail = self.tail.load(.monotonic);
                }
            }
        }

        pub fn pop(self: *Self) ?T {
            var head = self.head.load(.monotonic);
            while (true) {
                const slot = &self.buffer[head & self.mask];
                const seq = slot.sequence.load(.acquire);
                const diff = @as(isize, @intCast(seq)) -% @as(isize, @intCast(head +% 1));
                if (diff == 0) {
                    if (self.head.cmpxchgWeak(head, head +% 1, .monotonic, .monotonic)) |actual| {
                        head = actual;
                        continue;
                    }
                    const value = slot.value;
                    slot.sequence.store(head +% self.buffer.len, .release);
                    return value;
                } else if (diff < 0) {
                    return null;
                } else {
                    head = self.head.load(.monotonic);
                }
            }
        }

        /// Reserve up to `buf.len` items in one head RMW and read them out.
        /// Returns the count filled into `buf[0..n]`. Used by the thread pool
        /// inject-drain fast path to cut head-CAS rate by the drain-batch
        /// factor (flood_1m_batched median lift ~+14% at drain=32 vs
        /// per-item pop loop; see 2026-04-14-inject-head-contention audit).
        ///
        /// Correctness: tail-minus-head is re-checked under a strong head CAS
        /// before any slot is read, so we never reserve past the producer's
        /// committed writes. Per-slot sequence spin bounds the wait on a
        /// slow producer that may have advanced tail ahead of its value
        /// store. Returns 0 on CAS race (caller falls through to other
        /// work-search sources) rather than retrying — drain fast path
        /// prefers freshness over best-effort reservation.
        pub fn popMany(self: *Self, buf: []T) usize {
            const head = self.head.load(.monotonic);
            const tail = self.tail.load(.acquire);
            const avail_signed = @as(isize, @intCast(tail)) -% @as(isize, @intCast(head));
            if (avail_signed <= 0) return 0;
            const avail: usize = @intCast(avail_signed);
            const take = @min(avail, buf.len);
            if (take == 0) return 0;
            if (self.head.cmpxchgStrong(head, head +% take, .monotonic, .monotonic)) |_| {
                return 0;
            }
            var i: usize = 0;
            while (i < take) : (i += 1) {
                const slot = &self.buffer[(head +% i) & self.mask];
                const expected_seq = head +% i +% 1;
                while (slot.sequence.load(.acquire) != expected_seq) {
                    std.atomic.spinLoopHint();
                }
                buf[i] = slot.value;
                slot.sequence.store(head +% i +% self.buffer.len, .release);
            }
            return take;
        }

        pub fn len(self: *Self) usize {
            const t = self.tail.load(.acquire);
            const h = self.head.load(.acquire);
            const diff = @as(isize, @intCast(t)) -% @as(isize, @intCast(h));
            return if (diff < 0) 0 else @as(usize, @intCast(diff));
        }

        pub fn capacity(self: *Self) usize {
            return self.buffer.len;
        }
    };
}

test "bounded ring push pop basic" {
    const Ring = BoundedRing(u32);
    var ring = try Ring.init(std.testing.allocator, 4);
    defer ring.deinit();

    try std.testing.expect(ring.tryPush(10));
    try std.testing.expect(ring.tryPush(20));
    try std.testing.expectEqual(@as(?u32, 10), ring.pop());
    try std.testing.expectEqual(@as(?u32, 20), ring.pop());
    try std.testing.expectEqual(@as(?u32, null), ring.pop());
}

test "bounded ring full rejection" {
    const Ring = BoundedRing(u32);
    var ring = try Ring.init(std.testing.allocator, 2);
    defer ring.deinit();

    try std.testing.expect(ring.tryPush(1));
    try std.testing.expect(ring.tryPush(2));
    try std.testing.expect(!ring.tryPush(3));
    try std.testing.expectEqual(@as(usize, 2), ring.len());
}

test "bounded ring popMany basic" {
    const Ring = BoundedRing(u32);
    var ring = try Ring.init(std.testing.allocator, 8);
    defer ring.deinit();

    for (0..5) |i| try std.testing.expect(ring.tryPush(@intCast(i * 10)));

    var buf: [4]u32 = undefined;
    const n = ring.popMany(buf[0..]);
    try std.testing.expectEqual(@as(usize, 4), n);
    try std.testing.expectEqual(@as(u32, 0), buf[0]);
    try std.testing.expectEqual(@as(u32, 10), buf[1]);
    try std.testing.expectEqual(@as(u32, 20), buf[2]);
    try std.testing.expectEqual(@as(u32, 30), buf[3]);
    try std.testing.expectEqual(@as(?u32, 40), ring.pop());
    try std.testing.expectEqual(@as(?u32, null), ring.pop());
}

test "bounded ring popMany empty returns zero" {
    const Ring = BoundedRing(u32);
    var ring = try Ring.init(std.testing.allocator, 4);
    defer ring.deinit();

    var buf: [8]u32 = undefined;
    try std.testing.expectEqual(@as(usize, 0), ring.popMany(buf[0..]));
}

test "bounded ring popMany caps at available" {
    const Ring = BoundedRing(u32);
    var ring = try Ring.init(std.testing.allocator, 8);
    defer ring.deinit();

    for (0..3) |i| try std.testing.expect(ring.tryPush(@intCast(i + 1)));

    var buf: [16]u32 = undefined;
    const n = ring.popMany(buf[0..]);
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqual(@as(u32, 1), buf[0]);
    try std.testing.expectEqual(@as(u32, 2), buf[1]);
    try std.testing.expectEqual(@as(u32, 3), buf[2]);
    try std.testing.expectEqual(@as(?u32, null), ring.pop());
}

test "bounded ring popMany interleaved with pop" {
    const Ring = BoundedRing(u32);
    var ring = try Ring.init(std.testing.allocator, 16);
    defer ring.deinit();

    for (0..10) |i| try std.testing.expect(ring.tryPush(@intCast(i)));

    try std.testing.expectEqual(@as(?u32, 0), ring.pop());

    var buf: [4]u32 = undefined;
    const n = ring.popMany(buf[0..]);
    try std.testing.expectEqual(@as(usize, 4), n);
    try std.testing.expectEqual(@as(u32, 1), buf[0]);
    try std.testing.expectEqual(@as(u32, 4), buf[3]);

    try std.testing.expectEqual(@as(?u32, 5), ring.pop());
}

test "bounded ring popMany after wraparound" {
    const Ring = BoundedRing(u32);
    var ring = try Ring.init(std.testing.allocator, 4);
    defer ring.deinit();

    for (0..4) |i| try std.testing.expect(ring.tryPush(@intCast(i)));
    for (0..4) |i| try std.testing.expectEqual(@as(?u32, @intCast(i)), ring.pop());

    for (0..4) |i| try std.testing.expect(ring.tryPush(@intCast(100 + i)));

    var buf: [4]u32 = undefined;
    const n = ring.popMany(buf[0..]);
    try std.testing.expectEqual(@as(usize, 4), n);
    try std.testing.expectEqual(@as(u32, 100), buf[0]);
    try std.testing.expectEqual(@as(u32, 103), buf[3]);
}

test "bounded ring wraparound" {
    const Ring = BoundedRing(u32);
    var ring = try Ring.init(std.testing.allocator, 4);
    defer ring.deinit();

    for (0..2) |round| {
        for (0..4) |i| {
            try std.testing.expect(ring.tryPush(@intCast(round * 4 + i)));
        }
        for (0..4) |i| {
            try std.testing.expectEqual(@as(?u32, @intCast(round * 4 + i)), ring.pop());
        }
    }
}
