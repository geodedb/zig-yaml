# Lock-Free MPMC Inject Queue (PERF-007) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the mutex-protected `BoundedRing` inject queue with a lock-free MPMC bounded queue (Vyukov design), eliminating the global mutex that serializes all external submitters and all worker dequeue operations.

**Architecture:** Vyukov's bounded MPMC queue uses per-slot sequence numbers. Each slot has `(sequence: atomic(usize), value: T)`. Producers CAS `tail` to claim a slot, then write the value and advance the slot's sequence. Consumers CAS `head` to claim a slot, then read the value and advance the sequence. The sequence acts as a per-slot handoff signal — no global mutex needed. Buffer must be power-of-2 for bitmask indexing.

**Tech Stack:** Zig 0.15.2, `std.atomic.Value`, CAS loops

**Closes:** PERF-007

**Depends on:** Config.normalized() must round `queue_capacity` to power-of-2 (add in Task 1).

---

## File Structure

| File | Action | Responsibility |
|------|--------|---------------|
| `src/thread_pool/queue/bounded_ring.zig` | **Rewrite** | Lock-free Vyukov MPMC queue with identical public API |
| `src/thread_pool/types.zig` | **Modify** | Round queue_capacity to power-of-2 in normalized() |

---

## Task 1: Round queue_capacity to power-of-2

**Files:**

- Modify: `src/thread_pool/types.zig`

- [ ] **Step 1: Add test**

```zig
test "Config normalized rounds queue_capacity to power of two" {
    const cfg = (Config{ .queue_capacity = 1000 }).normalized();
    try std.testing.expectEqual(@as(usize, 1024), cfg.queue_capacity);
}
```

- [ ] **Step 2: Add rounding in normalized()**

After the `local_queue_capacity` rounding block, add:

```zig
        if (cfg.queue_capacity != 0) {
            cfg.queue_capacity = std.math.ceilPowerOfTwo(usize, cfg.queue_capacity) catch cfg.queue_capacity;
        }
```

- [ ] **Step 3: Run tests and commit**

```bash
./zig-0.15.2/zig build test --summary all
git add src/thread_pool/types.zig
git commit -m "feat: round queue_capacity to power-of-2 in Config.normalized

Preparation for lock-free MPMC inject queue requiring power-of-2 buffer.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: Implement lock-free Vyukov MPMC queue

**Files:**

- Rewrite: `src/thread_pool/queue/bounded_ring.zig`

- [ ] **Step 1: Write the replacement**

Replace `bounded_ring.zig` entirely:

```zig
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

        /// Try to push a value. Returns false if full.
        pub fn tryPush(self: *Self, value: T) bool {
            var tail = self.tail.load(.monotonic);
            while (true) {
                const slot = &self.buffer[tail & self.mask];
                const seq = slot.sequence.load(.acquire);
                const diff = @as(isize, @intCast(seq)) -% @as(isize, @intCast(tail));
                if (diff == 0) {
                    // Slot is available for writing
                    if (self.tail.cmpxchgWeak(tail, tail +% 1, .monotonic, .monotonic)) |actual| {
                        tail = actual; // CAS failed, retry with updated tail
                        continue;
                    }
                    // Won the slot
                    slot.value = value;
                    slot.sequence.store(tail +% 1, .release);
                    return true;
                } else if (diff < 0) {
                    // Queue is full
                    return false;
                } else {
                    // Another producer advanced tail, reload
                    tail = self.tail.load(.monotonic);
                }
            }
        }

        /// Try to pop a value. Returns null if empty.
        pub fn pop(self: *Self) ?T {
            var head = self.head.load(.monotonic);
            while (true) {
                const slot = &self.buffer[head & self.mask];
                const seq = slot.sequence.load(.acquire);
                const diff = @as(isize, @intCast(seq)) -% @as(isize, @intCast(head +% 1));
                if (diff == 0) {
                    // Slot has data ready
                    if (self.head.cmpxchgWeak(head, head +% 1, .monotonic, .monotonic)) |actual| {
                        head = actual;
                        continue;
                    }
                    const value = slot.value;
                    slot.sequence.store(head +% self.buffer.len, .release);
                    return value;
                } else if (diff < 0) {
                    // Queue is empty
                    return null;
                } else {
                    head = self.head.load(.monotonic);
                }
            }
        }

        /// Approximate count. Safe from any thread.
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

test "bounded ring wraparound" {
    const Ring = BoundedRing(u32);
    var ring = try Ring.init(std.testing.allocator, 4);
    defer ring.deinit();

    // Fill and drain twice to exercise wraparound
    for (0..2) |round| {
        for (0..4) |i| {
            try std.testing.expect(ring.tryPush(@intCast(round * 4 + i)));
        }
        for (0..4) |i| {
            try std.testing.expectEqual(@as(?u32, @intCast(round * 4 + i)), ring.pop());
        }
    }
}
```

- [ ] **Step 2: Run all tests**

Run: `./zig-0.15.2/zig build test --summary all && ./zig-0.15.2/zig build test-integration --summary all && timeout 120 ./zig-0.15.2/zig build test-stress --summary all && ./zig-0.15.2/zig build cross-check`

- [ ] **Step 3: Commit**

```bash
git add src/thread_pool/queue/bounded_ring.zig
git commit -m "feat: replace mutex BoundedRing with lock-free Vyukov MPMC queue

Per-slot sequence numbers provide lock-free push and pop without
a global mutex. Buffer size must be power-of-2 for bitmask indexing.

Closes PERF-007 (inject_queue.mutex serialized all submitters and
all worker dequeues, causing 26x latency increase under contention).

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: Benchmark and document

- [ ] **Step 1: Run benchmarks**

Focus on `producer_contention` where inject queue mutex was the bottleneck.

- [ ] **Step 2: Update PERF_GAP_ANALYSIS.md**

Mark PERF-007 as Closed with evidence.

- [ ] **Step 3: Commit**

```bash
git add docs/PERF_GAP_ANALYSIS.md
git commit -m "docs: close PERF-007 in tracking

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```
