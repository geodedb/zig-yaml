# Lock-Free Chase-Lev Work-Stealing Deque Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the mutex-backed WorkDeque with a lock-free Chase-Lev deque to make the work-stealing scheduler faster than the global-queue scheduler (currently 3.1x slower due to mutex contention).

**Architecture:** The Chase-Lev deque (Arora/Blumofe/Plaxton 1998, refined by Le et al.) uses atomic `bottom` and `top` indices with no mutex. The owner thread pushes/pops from `bottom` (wait-free). Stealers CAS `top` to claim items (lock-free). The critical single-element race is resolved with a CAS on `top` in the owner's `popBottom`. Buffer size is constrained to power-of-2 for bitmask index wrapping (eliminates modulo, closes PERF-009).

**Tech Stack:** Zig 0.15.2, `std.atomic.Value`, `std.atomic.fence`

**Closes:** PERF-001, PERF-009, PERF-013, SEC-015

---

## File Structure

| File | Action | Responsibility |
|------|--------|---------------|
| `src/thread_pool/queue/work_deque.zig` | **Rewrite** | Lock-free Chase-Lev deque with identical public API |
| `src/thread_pool/pool.zig` | **Modify (3 sites)** | Fix `cancelQueuedTasks` foreign-thread popBottom; remove redundant `len()` in drain loop; streamline peak tracking |
| `src/thread_pool/types.zig` | **Modify (1 site)** | Enforce power-of-2 `local_queue_capacity` in `normalized()` |
| `tests/unit.zig` | **Modify (append)** | Add concurrent deque stress test |

---

## Task 1: Enforce Power-of-2 Local Queue Capacity

**Files:**

- Modify: `src/thread_pool/types.zig:61-77` (normalized function)
- Test: inline test in `src/thread_pool/types.zig`

- [ ] **Step 1: Write the failing test**

Add to the bottom of `types.zig`, after the existing tests:

```zig
test "Config normalized rounds local_queue_capacity to power of two" {
    const cfg = (Config{ .local_queue_capacity = 100 }).normalized();
    try std.testing.expectEqual(@as(usize, 128), cfg.local_queue_capacity);

    const cfg2 = (Config{ .local_queue_capacity = 256 }).normalized();
    try std.testing.expectEqual(@as(usize, 256), cfg2.local_queue_capacity);

    const cfg3 = (Config{ .local_queue_capacity = 1 }).normalized();
    try std.testing.expectEqual(@as(usize, 1), cfg3.local_queue_capacity);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./zig-0.15.2/zig build test --summary all`
Expected: FAIL — `cfg.local_queue_capacity` is 100, not 128.

- [ ] **Step 3: Add power-of-2 rounding in normalized()**

In `types.zig`, inside `pub fn normalized(self: Config) Config`, add after the `inject_batch_size` normalization (after line 75):

```zig
        if (cfg.local_queue_capacity != 0) {
            cfg.local_queue_capacity = std.math.ceilPowerOfTwo(usize, cfg.local_queue_capacity) catch cfg.local_queue_capacity;
        }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `./zig-0.15.2/zig build test --summary all`
Expected: All tests pass including the new one.

- [ ] **Step 5: Commit**

```bash
git add src/thread_pool/types.zig
git commit -m "feat: round local_queue_capacity to power-of-2 in Config.normalized

Preparation for Chase-Lev deque which requires power-of-2 buffer sizes
for bitmask index wrapping (eliminates modulo, closes PERF-009).

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: Implement the Lock-Free Chase-Lev Deque

**Files:**

- Rewrite: `src/thread_pool/queue/work_deque.zig`

This is the core algorithm. The public API stays identical: `init`, `deinit`, `tryPushBottom`, `popBottom`, `stealTop`, `len`, `capacity`.

- [ ] **Step 1: Write the new deque with single-threaded tests**

Replace `src/thread_pool/queue/work_deque.zig` entirely with:

```zig
const std = @import("std");

/// Lock-free Chase-Lev work-stealing deque.
///
/// The owner thread calls `tryPushBottom` and `popBottom` (both wait-free).
/// Any thread may call `stealTop` (lock-free via CAS on `top`).
/// Buffer size must be a power of 2.
pub fn WorkDeque(comptime T: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        buffer: []std.atomic.Value(T),
        mask: usize,
        top: std.atomic.Value(isize) = std.atomic.Value(isize).init(0),
        bottom: std.atomic.Value(isize) = std.atomic.Value(isize).init(0),

        pub fn init(allocator: std.mem.Allocator, size: usize) !Self {
            std.debug.assert(size > 0 and (size & (size - 1)) == 0);
            const buf = try allocator.alloc(std.atomic.Value(T), size);
            for (buf) |*slot| slot.* = std.atomic.Value(T).init(undefined);
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

        /// Owner-only. Push an item to the bottom of the deque.
        /// Returns false if full.
        pub fn tryPushBottom(self: *Self, value: T) bool {
            const b = self.bottom.load(.monotonic);
            const t = self.top.load(.acquire);
            if (b -% t >= @as(isize, @intCast(self.buffer.len))) return false;
            self.buffer[@as(usize, @intCast(b)) & self.mask].store(value, .monotonic);
            std.atomic.fence(.release);
            self.bottom.store(b +% 1, .monotonic);
            return true;
        }

        /// Owner-only. Pop an item from the bottom of the deque (LIFO).
        /// Returns null if empty.
        pub fn popBottom(self: *Self) ?T {
            const b = self.bottom.load(.monotonic) -% 1;
            self.bottom.store(b, .monotonic);
            std.atomic.fence(.seq_cst);
            const t = self.top.load(.monotonic);

            if (t <= b) {
                // Non-empty: at least one element remains.
                const value = self.buffer[@as(usize, @intCast(b)) & self.mask].load(.monotonic);
                if (t == b) {
                    // Last element: race with stealers.
                    if (self.top.cmpxchgStrong(t, t +% 1, .seq_cst, .monotonic) != null) {
                        // A stealer won. Deque is now empty.
                        self.bottom.store(t +% 1, .monotonic);
                        return null;
                    }
                    self.bottom.store(t +% 1, .monotonic);
                }
                return value;
            } else {
                // Empty.
                self.bottom.store(t, .monotonic);
                return null;
            }
        }

        /// Any thread. Steal an item from the top of the deque (FIFO).
        /// Returns null if empty or contended.
        pub fn stealTop(self: *Self) ?T {
            const t = self.top.load(.acquire);
            std.atomic.fence(.seq_cst);
            const b = self.bottom.load(.acquire);

            if (t >= b) return null;

            const value = self.buffer[@as(usize, @intCast(t)) & self.mask].load(.monotonic);

            if (self.top.cmpxchgStrong(t, t +% 1, .seq_cst, .monotonic) != null) {
                // Another stealer won this slot. Return empty rather than retry
                // to let the caller try another victim.
                return null;
            }

            return value;
        }

        /// Approximate count. Safe to call from any thread.
        /// May momentarily return a slightly stale value.
        pub fn len(self: *Self) usize {
            const b = self.bottom.load(.acquire);
            const t = self.top.load(.acquire);
            const diff = b -% t;
            return if (diff < 0) 0 else @as(usize, @intCast(diff));
        }

        pub fn capacity(self: *Self) usize {
            return self.buffer.len;
        }
    };
}

test "work deque wraparound and stealing" {
    const Deque = WorkDeque(u32);
    var deque = try Deque.init(std.testing.allocator, 4);
    defer deque.deinit();

    // Push two items
    try std.testing.expect(deque.tryPushBottom(1));
    try std.testing.expect(deque.tryPushBottom(2));

    // Steal from top (FIFO): expect 1
    try std.testing.expectEqual(@as(?u32, 1), deque.stealTop());

    // Push two more (wraps around in a 4-slot buffer)
    try std.testing.expect(deque.tryPushBottom(3));
    try std.testing.expect(deque.tryPushBottom(4));

    // Pop from bottom (LIFO): expect 4
    try std.testing.expectEqual(@as(?u32, 4), deque.popBottom());

    // Steal from top: expect 2
    try std.testing.expectEqual(@as(?u32, 2), deque.stealTop());

    // Pop from bottom: expect 3
    try std.testing.expectEqual(@as(?u32, 3), deque.popBottom());

    // Empty
    try std.testing.expectEqual(@as(?u32, null), deque.popBottom());
    try std.testing.expectEqual(@as(?u32, null), deque.stealTop());
}

test "work deque full rejection" {
    const Deque = WorkDeque(u32);
    var deque = try Deque.init(std.testing.allocator, 2);
    defer deque.deinit();

    try std.testing.expect(deque.tryPushBottom(10));
    try std.testing.expect(deque.tryPushBottom(20));
    try std.testing.expect(!deque.tryPushBottom(30)); // Full

    try std.testing.expectEqual(@as(usize, 2), deque.len());
}

test "work deque last-element owner-vs-steal race (single-threaded)" {
    const Deque = WorkDeque(u32);
    var deque = try Deque.init(std.testing.allocator, 4);
    defer deque.deinit();

    try std.testing.expect(deque.tryPushBottom(42));
    // Only one element: popBottom should succeed (no concurrent stealer)
    try std.testing.expectEqual(@as(?u32, 42), deque.popBottom());
    try std.testing.expectEqual(@as(usize, 0), deque.len());
}
```

- [ ] **Step 2: Run single-threaded tests**

Run: `./zig-0.15.2/zig build test --summary all`
Expected: All tests pass (existing pool tests use the new deque via the unchanged API).

- [ ] **Step 3: Run integration and stress tests**

Run: `./zig-0.15.2/zig build test-integration --summary all && timeout 60 ./zig-0.15.2/zig build test-stress --summary all`
Expected: All pass. The API is identical so pool.zig callers work unchanged.

- [ ] **Step 4: Run cross-compile check**

Run: `./zig-0.15.2/zig build cross-check`
Expected: PASS for all 3 targets (x86_64-linux, aarch64-macos, x86_64-windows-gnu).

- [ ] **Step 5: Commit**

```bash
git add src/thread_pool/queue/work_deque.zig
git commit -m "feat: replace mutex WorkDeque with lock-free Chase-Lev deque

Owner push/pop are wait-free (no CAS on the fast path). Stealers use
CAS on the top index (lock-free). Buffer size must be power-of-2 for
bitmask wrapping (no modulo).

Closes PERF-001 (mutex-backed deque made work-stealing 3.1x slower
than global_queue) and PERF-009 (modulo replaced with bitmask).

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: Fix pool.zig Integration Points

**Files:**

- Modify: `src/thread_pool/pool.zig` (3 sites)

Three changes required for correctness and to eliminate the PERF-013 redundant `len()` calls.

- [ ] **Step 1: Fix cancelQueuedTasks — replace popBottom with stealTop**

In `pool.zig`, in `fn cancelQueuedTasks`, change line ~526:

Before:

```zig
                while (worker.local_queue.popBottom()) |descriptor_index| {
```

After:

```zig
                while (worker.local_queue.stealTop()) |descriptor_index| {
```

This is required because `cancelQueuedTasks` is called from the shutdown caller's thread (not a worker thread). In the Chase-Lev model, `popBottom` is owner-only. `stealTop` is safe from any thread. The drain ordering (LIFO vs FIFO) is irrelevant for cancellation — all queued items are cancelled regardless of order.

- [ ] **Step 2: Remove redundant len() in drain loop**

In `pool.zig`, in `fn nextTask`, the inject-to-local drain loop currently calls `worker.local_queue.len()` every iteration to check capacity. Replace with a local counter:

Before (lines ~385-396):

```zig
            if (self.inject_queue.pop()) |descriptor_index| {
                var moved: usize = 1;
                while (moved < self.config.inject_batch_size) : (moved += 1) {
                    if (worker.local_queue.len() >= worker.local_queue.capacity()) break;
                    const extra = self.inject_queue.pop() orelse break;
                    if (!worker.local_queue.tryPushBottom(extra)) {
                        _ = self.inject_queue.tryPush(extra);
                        break;
                    }
                    worker.local_queue_peak = @max(worker.local_queue_peak, @as(u32, @intCast(worker.local_queue.len())));
                }
                self.decrementQueued();
                return descriptor_index;
            }
```

After:

```zig
            if (self.inject_queue.pop()) |descriptor_index| {
                var moved: usize = 1;
                while (moved < self.config.inject_batch_size) : (moved += 1) {
                    const extra = self.inject_queue.pop() orelse break;
                    if (!worker.local_queue.tryPushBottom(extra)) {
                        _ = self.inject_queue.tryPush(extra);
                        break;
                    }
                }
                const local_len = @as(u32, @intCast(worker.local_queue.len()));
                worker.local_queue_peak = @max(worker.local_queue_peak, local_len);
                self.decrementQueued();
                return descriptor_index;
            }
```

Changes: (a) removed the `len() >= capacity()` check — `tryPushBottom` already returns false when full; (b) moved `local_queue_peak` update outside the loop — one `len()` call after all drains instead of one per drain; (c) eliminated up to 31 unnecessary `len()` calls per batch.

- [ ] **Step 3: Streamline peak tracking after enqueue push**

In `pool.zig`, in `fn enqueueTask`, after the local push (lines ~331-335):

Before:

```zig
            queued = worker.local_queue.tryPushBottom(descriptor_index);
            if (queued) {
                worker.local_queue_peak = @max(worker.local_queue_peak, @as(u32, @intCast(worker.local_queue.len())));
            }
```

After:

```zig
            queued = worker.local_queue.tryPushBottom(descriptor_index);
            if (queued) {
                const local_len = @as(u32, @intCast(worker.local_queue.len()));
                worker.local_queue_peak = @max(worker.local_queue_peak, local_len);
            }
```

This is a readability improvement (no functional change) — the `len()` call is now on its own line.

- [ ] **Step 4: Run all tests**

Run: `./zig-0.15.2/zig build test --summary all && ./zig-0.15.2/zig build test-integration --summary all && timeout 60 ./zig-0.15.2/zig build test-stress --summary all`
Expected: All pass.

- [ ] **Step 5: Commit**

```bash
git add src/thread_pool/pool.zig
git commit -m "fix: adapt pool.zig for Chase-Lev deque constraints

- cancelQueuedTasks: use stealTop instead of popBottom for cross-thread
  drain (popBottom is owner-only in Chase-Lev). Closes SEC-015.
- nextTask drain loop: remove redundant len() call per iteration;
  rely on tryPushBottom returning false when full. Closes PERF-013.
- enqueueTask: streamline peak tracking readability.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: Add Concurrent Deque Stress Test

**Files:**

- Modify: `tests/unit.zig` (append new test)

- [ ] **Step 1: Write a concurrent push+steal stress test**

Append to `tests/unit.zig`:

```zig
test "concurrent push-pop-steal does not lose or duplicate items" {
    // Direct deque test: owner thread pushes and pops, stealer threads steal.
    // Verifies no items are lost or duplicated under concurrency.
    const WorkDeque = @import("thread_pool").WorkDeque;
    const Deque = WorkDeque(u32);
    var deque = try Deque.init(std.testing.allocator, 256);
    defer deque.deinit();

    const total_items: u32 = 10_000;
    var owner_collected = std.atomic.Value(u32).init(0);
    var stolen_collected = std.atomic.Value(u32).init(0);

    const Stealer = struct {
        fn run(d: *Deque, collected: *std.atomic.Value(u32)) void {
            var count: u32 = 0;
            while (true) {
                if (d.stealTop()) |_| {
                    count += 1;
                } else {
                    // Check if owner is done pushing and deque is empty
                    if (d.len() == 0 and collected.load(.acquire) > 0) {
                        // Re-check after seeing "done" signal
                        if (d.stealTop()) |_| {
                            count += 1;
                        } else break;
                    }
                    std.Thread.yield() catch {};
                }
            }
            _ = collected.fetchAdd(count, .release);
        }
    };

    // Spawn 3 stealer threads
    var threads: [3]std.Thread = undefined;
    for (&threads) |*t| {
        t.* = try std.Thread.spawn(.{}, Stealer.run, .{ &deque, &stolen_collected });
    }

    // Owner: push items, interleave with pops
    var owner_count: u32 = 0;
    var pushed: u32 = 0;
    while (pushed < total_items) {
        if (deque.tryPushBottom(pushed)) {
            pushed += 1;
        }
        // Pop every 4th push to exercise the owner-vs-stealer last-element race
        if (pushed % 4 == 0) {
            if (deque.popBottom()) |_| {
                owner_count += 1;
            }
        }
    }
    // Drain remaining
    while (deque.popBottom()) |_| {
        owner_count += 1;
    }

    // Signal stealers that owner is done
    _ = owner_collected.fetchAdd(owner_count, .release);

    // Join stealers
    for (&threads) |t| t.join();

    const total_recovered = owner_collected.load(.acquire) + stolen_collected.load(.acquire);
    try std.testing.expectEqual(total_items, total_recovered);
}
```

- [ ] **Step 2: Run test to verify it passes**

Run: `./zig-0.15.2/zig build test --summary all`
Expected: All tests pass including the new concurrent test.

- [ ] **Step 3: Run stress tests for regression check**

Run: `timeout 60 ./zig-0.15.2/zig build test-stress --summary all`
Expected: 2/2 pass.

- [ ] **Step 4: Commit**

```bash
git add tests/unit.zig
git commit -m "test: add concurrent push-pop-steal deque stress test

Spawns 3 stealer threads + 1 owner doing interleaved push/pop.
Verifies total items recovered equals total items pushed with no
loss or duplication. Exercises the Chase-Lev last-element race.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: Re-Export WorkDeque and Verify Public API

**Files:**

- Modify: `src/root.zig` (add re-export if not present)

- [ ] **Step 1: Verify WorkDeque is accessible to tests**

Check that `tests/unit.zig` can access `WorkDeque` via `@import("thread_pool").WorkDeque`. If not, add the re-export in `src/root.zig`:

```zig
pub const WorkDeque = @import("thread_pool/queue/work_deque.zig").WorkDeque;
```

- [ ] **Step 2: Run full test suite**

Run: `./zig-0.15.2/zig build test --summary all && ./zig-0.15.2/zig build test-integration --summary all && timeout 60 ./zig-0.15.2/zig build test-stress --summary all && ./zig-0.15.2/zig build cross-check && ./zig-0.15.2/zig fmt --check src tests benchmarks examples build.zig`
Expected: All pass.

- [ ] **Step 3: Commit if changes were needed**

```bash
git add src/root.zig
git commit -m "feat: re-export WorkDeque for direct test access

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

## Task 6: Benchmark and Record New Baseline

**Files:**

- None modified (benchmark run only)

- [ ] **Step 1: Run benchmark and compare**

```bash
./zig-0.15.2/zig build bench -- --output /tmp/chase_lev_bench.json
./zig-0.15.2/zig build compare-bench -- --baseline benchmarks/results/baseline.json --current /tmp/chase_lev_bench.json
```

Expected: work_stealing throughput should be competitive with or exceed global_queue (~1.5M ops/s). The 15% regression gate should pass.

- [ ] **Step 2: Record observations**

Note the measured numbers. If work_stealing is now faster than global_queue on `conn_churn_seq`, the Chase-Lev implementation is successful.

- [ ] **Step 3: Update baseline if improved**

```bash
cp /tmp/chase_lev_bench.json benchmarks/results/baseline.json
cp /tmp/chase_lev_bench.json benchmarks/results/latest.json
git add benchmarks/results/
git commit -m "perf: update benchmark baseline after Chase-Lev deque

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

## Task 7: Update Documentation

**Files:**

- Modify: `docs/DESIGN.md`
- Modify: `docs/PERF_GAP_ANALYSIS.md`

- [ ] **Step 1: Update DESIGN.md**

Find the "Known Gaps" section mentioning the mutex-backed deque. Replace with:

```markdown
The local deque uses a lock-free Chase-Lev design. The owner thread
pushes and pops wait-free (no CAS). Stealers use a CAS on the top
index. Buffer size is constrained to power-of-2 for bitmask wrapping.
```

- [ ] **Step 2: Update PERF_GAP_ANALYSIS.md**

Mark PERF-001, PERF-009, and PERF-013 as Closed with evidence (benchmark numbers from Task 6).

- [ ] **Step 3: Commit**

```bash
git add docs/DESIGN.md docs/PERF_GAP_ANALYSIS.md
git commit -m "docs: close PERF-001, PERF-009, PERF-013 after Chase-Lev deque

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```
