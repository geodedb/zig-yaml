# Batch-Steal Deque & Park-Signal Simplification Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the two remaining performance gaps called out by the 2026-04-11 Tokio-parity plan's verdict:
1. Replace the per-worker park condvar's broadcast-fallback with a simpler single-signal handshake so the 2-worker hot path stops paying an N-way mutex hit on every submit.
2. Replace the Chase-Lev deque with an SPMC ring that admits a correct batch-steal operation, so `steal_batch_size > 1` becomes usable again and victim-to-stealer throughput recovers.

**Architecture:** Two independent, serial phases.

- **Phase A (park handshake):** Today's submit path reads `parked_workers`, scans `is_parked`, signals if it hits, and otherwise broadcasts to every worker under its `park_mutex`. The broadcast fires whenever a worker is mid-transition between `parked_workers++` and `is_parked := 1`, and at low worker counts that race window dominates. Fix: drop the `parked_workers` counter entirely, order the worker so `is_parked := 1` is visible *before* the re-check of `queued_tasks`, and have the submitter scan `is_parked` only. No fallback broadcast needed — the handshake is the canonical seq_cst lost-wakeup pattern used by Go's scheduler. The N-worker scan stays (we still don't have a parked-set data structure), but the broadcast-to-all path is gone.
- **Phase B (deque swap):** Build `src/queue/ring_queue.zig`, a Tokio-style SPMC ring. Owner increments `tail` (relaxed store after slot write, release fence); pops are LIFO via `tail--` with a seq_cst fence-and-reload of `head`; stealers CAS-increment `head` by a half-window and copy those slots into their own ring. This is the design Tokio and Go both ship: a single CAS per batch, slots are stable for stealers because owner never rewrites a slot until it wraps past `head`. Route `pool.zig` through this queue behind a new `Config.queue_kind` enum so we can ship both and flip the default atomically.

**Performance Targets (success criteria):**

| Metric | Current (v0.2.0 + 2026-04-11 plan) | Target |
|---|---|---|
| Submit p50 (1 worker, samples=100000) | ~1.8 µs | ≤ 600 ns |
| Wake p50 (2 workers, samples=5000) | ~12.7 µs | ≤ 10 µs |
| `steal_throughput` (2 workers, 200k tasks, batch=1) | ~677K ops/s | ≥ 1M ops/s |
| `steal_throughput` (batch=8) | not usable | ≥ 2M ops/s |
| `bench_tokio_parity/flood_1m` | 297K ops/s | ≥ 1M ops/s |
| `bench_tokio_parity/contended_spawn_8x` | 497K ops/s | ≥ 1M ops/s |
| Race-free under tsan and stress | passing | passing |

**Tech Stack:** Zig 0.15.2, `std.atomic`, `std.Thread.Mutex/Condition`, existing `BoundedRing` (inject queue), existing micro-bench harness (`benchmarks/micro/*`), GitLab CI `bench-micro` job.

**Reference designs:**
- Tokio multi-thread runtime worker queue: [`tokio/src/runtime/scheduler/multi_thread/queue.rs`](https://github.com/tokio-rs/tokio/blob/master/tokio/src/runtime/scheduler/multi_thread/queue.rs) — SPMC ring with `steal_into_and_pop` copying half.
- Go runtime local run queue: [`runtime/runtime2.go` `runq*`](https://github.com/golang/go/blob/master/src/runtime/proc.go) and `runqsteal` in proc.go.
- Lost-wakeup handshake invariant: Herlihy-Shavit *The Art of Multiprocessor Programming* §8 — mutex-held state transition before waiting.

---

## File Structure

**New files:**
- `src/queue/ring_queue.zig` — SPMC ring supporting `steal_half(dst)`. Replaces `WorkDeque` in the work-stealing path.
- `tests/unit/ring_queue_unit.zig` — owner-only semantics tests (push/pop/full/wrap).
- `tests/stress/ring_queue_stress.zig` — multi-threaded stress: N stealers vs 1 owner, correctness under tsan.
- `tests/stress/park_no_lost_wakeup.zig` — adversarial test: submitter interleaves with worker parking to prove no lost wakeups after the handshake rewrite.

**Modified files:**
- `src/pool.zig` — Phase A: `idle()` reorder + removal of `parked_workers` counter + submit-side scan. Phase B: `local_queues` type switch, `nextTask` steal loop, `runtime_stats()` dropping the removed counter.
- `src/types.zig` — add `QueueKind` enum + `Config.queue_kind` knob (default `.ring`), update `steal_batch_size` doc (no longer clamped to 1), remove `parked_workers` from `RuntimeStats` or document it as always-zero.
- `src/queue/work_deque.zig` — keep file but remove `stealTopBatch` (never correct); add a doc-comment pointing to `ring_queue.zig` as the default.
- `benchmarks/micro/steal_throughput.zig` — parametrize `queue_kind` via env/CLI so the same micro exercises both.
- `benchmarks/bench_tokio_parity.zig` — no code change, just rerun after the swap.
- `docs/PERFORMANCE_TRACKING.md` — add Phase A / Phase B rows with new numbers.
- `benchmarks/results/baseline.json` — rebaseline at the end.
- `build.zig` — wire the new unit/stress test files into their test steps.
- `.gitlab-ci.yml` — no change expected; the advisory `bench-micro` job picks up new numbers automatically.

**Deleted code (not whole files):**
- `src/pool.zig`: the broadcast-fallback loop in `submit()`; the `parked_workers` field of `Counters`; increments/decrements of that field in `idle()` and `shutdown()`.
- `src/queue/work_deque.zig`: `stealTopBatch` and its three tests.

---

## Phase A: Park-Signal Simplification

**Rationale:** The 2026-04-11 plan's Task 12 added per-worker park primitives to remove N-way mutex contention on submit. The implementation pays that cost only when `is_parked == 1` is observed, but falls back to a full N-worker broadcast whenever `parked_workers > 0` but no worker's `is_parked` flag is yet set. Measurement (see PERFORMANCE_TRACKING Phase 3 row) shows this fallback dominates at 2 workers: submit p50 regressed from 510 ns to ~1.8 µs. The fix is to eliminate the race window that motivates the fallback, by making `is_parked` the *single* source of truth and ordering the worker's state transitions so the seq_cst handshake with the submitter is enough.

**Invariant after this phase** (must hold; the stress test in Task A4 checks it):
> If `push + queued++` completes strictly before a worker finishes `is_parked := 1; reload queued_tasks`, then the submitter's subsequent `is_parked.load(seq_cst)` observes that worker parked, OR the worker's reload sees the enqueued task. One of the two branches fires; no lost wakeup.

### Task A1: Remove the `parked_workers` counter field and its uses

**Files:**
- Modify: `src/pool.zig` (`Counters` struct + `idle()` + `submit()` + `shutdown()` + `runtime_stats()`)
- Modify: `src/types.zig` (`RuntimeStats` if the field is exposed)
- Test: (none in this step — purely refactor; functional tests in A2-A4)

- [ ] **Step 1: Write a failing test for the no-op refactor**

Open `tests/unit.zig` (or wherever `runtime_stats()` is exercised). Add:

```zig
test "runtime_stats omits parked_workers counter after simplification" {
    const allocator = std.testing.allocator;
    var pool = try thread_pool.Pool.init(allocator, .{ .max_threads = 2 });
    defer pool.deinit();
    const stats = pool.runtime_stats();
    // This field no longer exists on RuntimeStats — compilation is the assertion.
    _ = stats;
}
```

(If `RuntimeStats` still exposes `parked_workers`, the compile fails.)

- [ ] **Step 2: Run — expect pass, test name compiles as-is**

Run: `zig build test-unit 2>&1 | tail -20`
Expected: existing tests pass; new test compiles and passes once field is removed in Step 4.

- [ ] **Step 3: Remove the field from `Counters`**

In `src/pool.zig` find the `Counters` struct (around line 126). Remove the line:

```zig
parked_workers: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
```

Drop the comment block above it if it only documents that field.

- [ ] **Step 4: Remove increments/decrements in `idle()`**

In `src/pool.zig` `fn idle()` (around line 709-743), delete:
```zig
_ = self.counters.parked_workers.fetchAdd(1, .monotonic);
...
_ = self.counters.parked_workers.fetchSub(1, .monotonic);
```
(both occurrences: the happy path and the bail-out branch)

- [ ] **Step 5: Remove the `parked_workers` load gate and broadcast fallback in `submit()`**

In `src/pool.zig` `fn submit()` (around line 485-533), replace the entire block starting at
`if (self.counters.parked_workers.load(.monotonic) > 0) { ... }`
with:

```zig
// Wake one parked worker. Scan `is_parked` across workers starting at a
// round-robin offset so load spreads across the pool. The submit-before-park
// handshake (see idle()) guarantees: if any worker is about to miss this
// task because it's heading to park, its `is_parked := 1` store is ordered
// with its reload of `queued_tasks`. So either we observe `is_parked == 1`
// and signal it, OR the worker reloads `queued_tasks` and sees our push —
// no lost wakeup. No broadcast fallback is needed.
const submitted = self.counters.submitted.load(.monotonic);
const hint_idx: usize = @intCast(submitted % self.workers.len);
var off: usize = 0;
while (off < self.workers.len) : (off += 1) {
    const idx = (hint_idx + off) % self.workers.len;
    const w = &self.workers[idx];
    if (w.is_parked.load(.seq_cst) == 1) {
        w.park_mutex.lock();
        // Re-check under the mutex: the worker may have unparked between our
        // load and this acquire. The signal is a no-op if it isn't parked —
        // but we do not want to hold the mutex for a worker that is running.
        if (w.is_parked.load(.monotonic) == 1) {
            w.park_cond.signal();
        }
        w.park_mutex.unlock();
        break;
    }
}
```

The `push + queued++` and the `.seq_cst` load of `is_parked` pair with the worker's `is_parked := 1 (seq_cst)` and `queued_tasks.load(.seq_cst)` (changed in Task A2).

- [ ] **Step 6: Update `shutdown()` so it doesn't need `parked_workers`**

In `src/pool.zig` find the shutdown loop around line 306. It already broadcasts on every worker — that's correct for shutdown (no hot-path concern). Leave as-is, but ensure it no longer references `parked_workers`.

- [ ] **Step 7: Update `runtime_stats()` to stop reporting the removed counter**

Around line 399: delete the line `.parked_workers = self.counters.parked_workers.load(.acquire),`. Correspondingly, remove `parked_workers: u64 = 0,` from `RuntimeStats` in `src/types.zig` (or wherever it's declared).

- [ ] **Step 8: Run the unit tests**

Run: `zig build test-unit 2>&1 | tail -30`
Expected: all pass, including the new "runtime_stats omits parked_workers" test.

- [ ] **Step 9: Commit**

```bash
git add src/pool.zig src/types.zig tests/unit.zig
git commit -m "perf(pool): remove parked_workers counter; rely on per-worker is_parked"
```

### Task A2: Reorder the park handshake so `is_parked := 1` seq_cst ordering is observable

**Files:**
- Modify: `src/pool.zig` (`fn idle()`)
- Test: new in Task A4; functional correctness checked by existing stress tests here

- [ ] **Step 1: Read the current idle() implementation**

Open `src/pool.zig` around line 709-751 and re-read the park sequence.

- [ ] **Step 2: Replace the park body with the invariant-preserving ordering**

Replace `fn idle()` body from the `worker.park_mutex.lock();` line through `worker.park_mutex.unlock();` with:

```zig
worker.park_mutex.lock();
// Publish "I am parking" before the re-check, with seq_cst ordering so a
// concurrent submitter's `push + queued++ + is_parked.load(.seq_cst)`
// is totally ordered with our `is_parked.store(.seq_cst) + queued_tasks.load(.seq_cst)`.
// Either the submitter observes is_parked == 1 (and will signal), or we
// observe the enqueued task in the reload below. One of the two branches
// always fires; no lost wakeup.
worker.is_parked.store(1, .seq_cst);
if (self.counters.queued_tasks.load(.seq_cst) != 0 or self.state.load(.acquire) != .running) {
    worker.is_parked.store(0, .release);
    worker.park_mutex.unlock();
    _ = worker.wakeups.fetchAdd(1, .release);
    return;
}
worker.park_cond.timedWait(&worker.park_mutex, self.config.idle_park_after_ns) catch {};
worker.is_parked.store(0, .release);
worker.park_mutex.unlock();
_ = worker.wakeups.fetchAdd(1, .release);
```

Key changes: (1) `is_parked := 1` now happens *before* the re-check, under the mutex; (2) seq_cst ordering pairs with the submitter's seq_cst load in Task A1.

- [ ] **Step 3: Run existing stress tests**

Run: `zig build test-stress 2>&1 | tail -30`
Expected: all pass. Shutdown, drain, and concurrent-submit tests all exercise the park handshake.

- [ ] **Step 4: Commit**

```bash
git add src/pool.zig
git commit -m "perf(pool): tighten park handshake to single seq_cst pair, no broadcast fallback"
```

### Task A3: Add a lost-wakeup stress test

**Files:**
- Create: `tests/stress/park_no_lost_wakeup.zig`
- Modify: `build.zig` (wire the new test into `test-stress`)

- [ ] **Step 1: Write the failing test first**

Create `tests/stress/park_no_lost_wakeup.zig`:

```zig
const std = @import("std");
const thread_pool = @import("thread_pool");

// Adversarial test: pound submit() against workers that cycle
// run → park → run. Any lost wakeup surfaces as a submitted task whose
// descriptor never reaches state=completed within the 5s window.

fn incrementTask(raw_ctx: *anyopaque, runtime: *thread_pool.TaskContext) void {
    _ = runtime;
    const counter: *std.atomic.Value(u64) = @ptrCast(@alignCast(raw_ctx));
    _ = counter.fetchAdd(1, .release);
}

test "park handshake: no lost wakeups under submit-while-parking race" {
    const allocator = std.testing.allocator;
    // Small idle_park_after_ns forces many park/unpark cycles so we land
    // inside the handshake window often.
    var pool = try thread_pool.Pool.init(allocator, .{
        .max_threads = 2,
        .min_threads = 2,
        .queue_capacity = 4096,
        .idle_park_after_ns = 50_000, // 50us
        .spin_before_park_iters = 4,  // minimal spin — force quick park
    });
    defer pool.deinit();

    var counter = std.atomic.Value(u64).init(0);
    const total: u64 = 200_000;

    const Submitter = struct {
        fn run(p: *thread_pool.Pool, c: *std.atomic.Value(u64), n: u64) void {
            var i: u64 = 0;
            while (i < n) : (i += 1) {
                while (true) {
                    _ = p.submit(.{ .ctx = c, .task_fn = incrementTask }, .{}) catch {
                        std.Thread.sleep(1_000);
                        continue;
                    };
                    break;
                }
            }
        }
    };

    const t1 = try std.Thread.spawn(.{}, Submitter.run, .{ &pool, &counter, total / 2 });
    const t2 = try std.Thread.spawn(.{}, Submitter.run, .{ &pool, &counter, total / 2 });
    t1.join();
    t2.join();

    // Wait up to 5s for all tasks to complete. If any wakeup is lost, the
    // counter stalls below `total` and this fails.
    const deadline = std.time.nanoTimestamp() + 5 * std.time.ns_per_s;
    while (std.time.nanoTimestamp() < deadline) {
        if (counter.load(.acquire) >= total) break;
        std.Thread.sleep(1_000_000);
    }

    try std.testing.expectEqual(total, counter.load(.acquire));
}
```

- [ ] **Step 2: Wire the test file into build.zig**

Open `build.zig`, find the `test-stress` step block. Add:

```zig
const park_test = b.addTest(.{
    .root_module = b.createModule(.{
        .root_source_file = b.path("tests/stress/park_no_lost_wakeup.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "thread_pool", .module = thread_pool_mod },
        },
    }),
});
const run_park_test = b.addRunArtifact(park_test);
test_stress_step.dependOn(&run_park_test.step);
```

(The exact idiom follows whatever pattern `build.zig` uses for `tests/stress.zig`; follow the existing pattern — don't invent new structure.)

- [ ] **Step 3: Run the stress test**

Run: `zig build test-stress -Doptimize=ReleaseSafe 2>&1 | tail -30`
Expected: passes within 5s.

- [ ] **Step 4: Commit**

```bash
git add tests/stress/park_no_lost_wakeup.zig build.zig
git commit -m "test(stress): add park handshake lost-wakeup adversarial test"
```

### Task A4: Re-measure submit and wake micro-benchmarks; record in PERFORMANCE_TRACKING

**Files:**
- Modify: `docs/PERFORMANCE_TRACKING.md`

- [ ] **Step 1: Run submit_latency five times and record the median p50/p95/p99**

Run: `for i in 1 2 3 4 5; do zig build bench-submit-latency -Doptimize=ReleaseFast 2>&1 | grep -E "^p50|^p95|^p99"; done`
Expected: p50 ≤ 600ns (target). Capture the median run's numbers.

- [ ] **Step 2: Run wake_latency five times**

Run: `for i in 1 2 3 4 5; do zig build bench-wake-latency -Doptimize=ReleaseFast 2>&1 | grep -E "^p50|^p95|^p99"; done`
Expected: p50 ≤ 10 µs (target).

- [ ] **Step 3: Append Phase A rows to both tables in `docs/PERFORMANCE_TRACKING.md`**

For `Micro: submit_latency`:
```markdown
| Phase A (park handshake simplification) | <p50> | <p95> | <p99> | Task A1+A2: removed parked_workers counter + broadcast fallback; `is_parked` under seq_cst handshake (median of 5 runs) |
```

For `Micro: wake_latency`:
```markdown
| Phase A (park handshake simplification) | <p50> | <p95> | <p99> | median of 5 runs; single-signal path, no N-way broadcast |
```

- [ ] **Step 4: Commit**

```bash
git add docs/PERFORMANCE_TRACKING.md
git commit -m "docs(perf): record Phase A (park simplification) micro-bench numbers"
```

---

## Phase B: SPMC Ring Queue for Correct Batch Steal

**Rationale:** Chase-Lev's single-item steal proof doesn't generalize to batches because `popBottom`'s last-element race resolves one slot at a time. Our current `stealTopBatch` attempts an atomic `top += n` CAS, but a concurrent `popBottom` can win the top-race for what the stealer believed was a *non-last* element, producing a slot that either is doubly-executed or lost depending on the load order. Result: `steal_batch_size` is clamped to 1, and the infrastructure is dead.

**Design:** Tokio's SPMC ring. Owner-exclusive tail; multi-stealer head. Owner push: write slot, release-store tail. Owner pop: decrement tail (conceptually; implemented with a seq_cst fence and re-read of head to resolve the single-item race just like Chase-Lev — this part is unchanged). Stealer: compute n as the owner's approximate depth divided by two, CAS head up by n, then copy the n slots into the stealer's own ring. Crucially: slot storage is stable for stealers between their CAS-on-head and the slot copy because the owner does not write to any index `< head` (only to `tail`-onwards). If tail races close enough to wrap around, the CAS is the synchronization point — see "correctness sketch" comment at top of `ring_queue.zig`.

### Task B1: Implement `src/queue/ring_queue.zig`

**Files:**
- Create: `src/queue/ring_queue.zig`
- Test: owner-only unit tests inline in the file (following repo convention — `work_deque.zig` does the same)

- [ ] **Step 1: Write the full ring queue implementation**

Create `src/queue/ring_queue.zig`:

```zig
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
            return t -% h;
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
            while (true) {
                const h = self.head.load(.acquire);
                // Acquire on tail pairs with the owner's release on push.
                const t = self.tail.load(.acquire);
                const avail = t -% h;
                if (avail == 0) return 0;
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
```

- [ ] **Step 2: Run the inline tests**

Run: `zig test src/queue/ring_queue.zig 2>&1 | tail -20`
Expected: all tests pass. If any fail, fix the implementation (not the tests — the semantics above are load-bearing).

- [ ] **Step 3: Commit**

```bash
git add src/queue/ring_queue.zig
git commit -m "feat(queue): add SPMC ring queue with correct stealHalf"
```

### Task B2: Add a multi-threaded stress test for the ring queue

**Files:**
- Create: `tests/stress/ring_queue_stress.zig`
- Modify: `build.zig`

- [ ] **Step 1: Write the stress test**

Create `tests/stress/ring_queue_stress.zig`:

```zig
const std = @import("std");
const RingQueue = @import("thread_pool").queue.RingQueue;

// Stress: 1 owner pushes N items, M stealers race. Every pushed item must
// be observed exactly once (by the owner via pop or some stealer via
// stealHalf). Counts must total N.

test "RingQueue: 1 owner + 4 stealers — no duplicates, no losses" {
    const allocator = std.testing.allocator;
    const N: u32 = 100_000;
    const M_stealers: u32 = 4;

    var q = try RingQueue(u32).init(allocator, 1024);
    defer q.deinit();

    var seen = try allocator.alloc(std.atomic.Value(u8), N);
    defer allocator.free(seen);
    for (seen) |*s| s.* = std.atomic.Value(u8).init(0);

    var pushed: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);
    var stolen: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);
    var popped: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);

    const Owner = struct {
        fn run(ptr_q: *RingQueue(u32), pushed_ctr: *std.atomic.Value(u32),
               popped_ctr: *std.atomic.Value(u32), seen_arr: []std.atomic.Value(u8),
               total: u32) void {
            var i: u32 = 0;
            while (i < total) {
                if (ptr_q.tryPush(i)) {
                    _ = pushed_ctr.fetchAdd(1, .release);
                    i += 1;
                } else {
                    // Drain a bit when full.
                    while (ptr_q.pop()) |v| {
                        const old = seen_arr[v].fetchAdd(1, .release);
                        std.debug.assert(old == 0); // no duplicate
                        _ = popped_ctr.fetchAdd(1, .release);
                    }
                }
            }
            // Drain remainder.
            while (ptr_q.pop()) |v| {
                const old = seen_arr[v].fetchAdd(1, .release);
                std.debug.assert(old == 0);
                _ = popped_ctr.fetchAdd(1, .release);
            }
        }
    };

    const Stealer = struct {
        fn run(ptr_q: *RingQueue(u32), stolen_ctr: *std.atomic.Value(u32),
               seen_arr: []std.atomic.Value(u8), done: *std.atomic.Value(u8)) void {
            var buf: [32]u32 = undefined;
            while (done.load(.acquire) == 0) {
                const n = ptr_q.stealHalf(buf[0..]);
                for (buf[0..n]) |v| {
                    const old = seen_arr[v].fetchAdd(1, .release);
                    std.debug.assert(old == 0);
                }
                _ = stolen_ctr.fetchAdd(@intCast(n), .release);
            }
            // Final drain pass.
            var buf2: [32]u32 = undefined;
            while (true) {
                const n = ptr_q.stealHalf(buf2[0..]);
                if (n == 0) break;
                for (buf2[0..n]) |v| {
                    const old = seen_arr[v].fetchAdd(1, .release);
                    std.debug.assert(old == 0);
                }
                _ = stolen_ctr.fetchAdd(@intCast(n), .release);
            }
        }
    };

    var done = std.atomic.Value(u8).init(0);
    var threads: [M_stealers]std.Thread = undefined;
    for (&threads) |*t| {
        t.* = try std.Thread.spawn(.{}, Stealer.run, .{ &q, &stolen, seen, &done });
    }
    const owner = try std.Thread.spawn(.{}, Owner.run, .{ &q, &pushed, &popped, seen, N });
    owner.join();
    done.store(1, .release);
    for (&threads) |*t| t.join();

    try std.testing.expectEqual(N, pushed.load(.acquire));
    try std.testing.expectEqual(N, popped.load(.acquire) + stolen.load(.acquire));
    // Every item seen exactly once.
    for (seen) |*s| try std.testing.expectEqual(@as(u8, 1), s.load(.acquire));
}
```

- [ ] **Step 2: Expose `RingQueue` through the `thread_pool` module**

In `src/root.zig` add (after the other re-exports):

```zig
pub const queue = struct {
    pub const RingQueue = @import("queue/ring_queue.zig").RingQueue;
};
```

- [ ] **Step 3: Wire into build.zig under `test-stress`**

Follow the same pattern as Task A3 Step 2, but for the new file.

- [ ] **Step 4: Run**

Run: `zig build test-stress -Doptimize=ReleaseSafe 2>&1 | tail -40`
Expected: all assertions hold. If any `old == 0` assertion fires, the implementation has a duplication bug — fix before moving on.

- [ ] **Step 5: Commit**

```bash
git add tests/stress/ring_queue_stress.zig src/root.zig build.zig
git commit -m "test(stress): ring queue 1-owner + 4-stealer no-loss/no-duplicate test"
```

### Task B3: Add `Config.queue_kind` knob

**Files:**
- Modify: `src/types.zig`

- [ ] **Step 1: Add the enum and field**

In `src/types.zig`, before `Config`:

```zig
pub const QueueKind = enum {
    /// Chase-Lev work-stealing deque. Correct for single-item steal only.
    chase_lev,
    /// Tokio-style SPMC ring. Supports batch-steal via stealHalf. Default.
    ring,
};
```

Inside `Config`, add:

```zig
queue_kind: QueueKind = .ring,
```

Update the `steal_batch_size` doc:

```zig
/// Maximum number of tasks a stealer takes from a single victim per steal
/// attempt. With `queue_kind = .ring`, true batch-steal via stealHalf is
/// used and values > 1 are correct. With `queue_kind = .chase_lev`,
/// only single-item steal is correct and the runtime forces this to 1.
steal_batch_size: usize = 8,
```

Change the clamp in `normalized()` so that `chase_lev` forces to 1:

```zig
cfg.steal_batch_size = std.math.clamp(cfg.steal_batch_size, 1, 32);
if (cfg.queue_kind == .chase_lev) cfg.steal_batch_size = 1;
```

- [ ] **Step 2: Run unit tests to confirm nothing broke**

Run: `zig build test-unit 2>&1 | tail -20`
Expected: pass (no uses of `queue_kind` in pool.zig yet — field is inert).

- [ ] **Step 3: Commit**

```bash
git add src/types.zig
git commit -m "feat(config): add queue_kind knob, default ring"
```

### Task B4: Wire `RingQueue` into `pool.zig` behind the `queue_kind` switch

**Files:**
- Modify: `src/pool.zig`

This task is the largest code change; it swaps the `local_queues` storage and the three call sites (push on submit, pop on nextTask, steal loop on nextTask). To keep the diff reviewable we use a tagged-union wrapper so both queue kinds share a single runtime type.

- [ ] **Step 1: Add a tagged-union wrapper type near the top of `pool.zig`**

After the existing `const WorkDeque = @import(...)` imports (around line 12-20), add:

```zig
const RingQueue = @import("queue/ring_queue.zig").RingQueue;

const LocalQueue = union(enum) {
    chase_lev: WorkDeque(u32),
    ring: RingQueue(u32),

    fn init(allocator: std.mem.Allocator, size: usize, kind: types.QueueKind) !LocalQueue {
        return switch (kind) {
            .chase_lev => .{ .chase_lev = try WorkDeque(u32).init(allocator, size) },
            .ring => .{ .ring = try RingQueue(u32).init(allocator, size) },
        };
    }

    fn deinit(self: *LocalQueue) void {
        switch (self.*) {
            .chase_lev => |*q| q.deinit(),
            .ring => |*q| q.deinit(),
        }
    }

    fn tryPushBottom(self: *LocalQueue, value: u32) bool {
        return switch (self.*) {
            .chase_lev => |*q| q.tryPushBottom(value),
            .ring => |*q| q.tryPush(value),
        };
    }

    fn popBottom(self: *LocalQueue) ?u32 {
        return switch (self.*) {
            .chase_lev => |*q| q.popBottom(),
            .ring => |*q| q.pop(),
        };
    }

    /// Steal up to `out.len` items. Semantics:
    /// - chase_lev: stealTop (single item; `out[0]` only populated when n==1)
    /// - ring: stealHalf (copies up to half of the victim's queue)
    fn steal(self: *LocalQueue, out: []u32) usize {
        return switch (self.*) {
            .chase_lev => |*q| if (q.stealTop()) |v| blk: {
                out[0] = v;
                break :blk 1;
            } else 0,
            .ring => |*q| q.stealHalf(out),
        };
    }

    fn stealAll(self: *LocalQueue) ?u32 {
        // Used by shutdown's cancelQueuedTasks to drain a victim queue.
        return switch (self.*) {
            .chase_lev => |*q| q.stealTop(),
            .ring => |*q| blk: {
                var buf: [1]u32 = undefined;
                if (q.stealHalf(buf[0..]) == 1) break :blk buf[0];
                break :blk null;
            },
        };
    }

    fn len(self: *const LocalQueue) usize {
        return switch (self.*) {
            .chase_lev => |*q| @constCast(q).len(),
            .ring => |*q| q.len(),
        };
    }
};
```

- [ ] **Step 2: Change `local_queues` field type in `Core`**

In `Core` struct (around line 144), change:
```zig
local_queues: []WorkDeque(u32),
```
to:
```zig
local_queues: []LocalQueue,
```

- [ ] **Step 3: Update `Core.init()`**

Around line 161 / 197-198 update the allocation and init loop. Replace the initialization of each `lq` with:

```zig
for (self.workers, self.local_queues) |*worker, *lq| {
    lq.* = try LocalQueue.init(allocator, normalized.local_queue_capacity, normalized.queue_kind);
    worker.* = .{ ... };
}
```

Update `allocator.alloc(WorkDeque(u32), ...)` to `allocator.alloc(LocalQueue, ...)` on the line where `local_queues` is allocated.

- [ ] **Step 4: Update `Core.deinitOwned()`**

Find the loop that calls `.deinit()` on each `lq` (search `local_queues`). It already calls `lq.deinit()` — with the union wrapper this dispatches correctly.

- [ ] **Step 5: Update `submit()` — the local-queue push**

Around line 468-473 in `submit()`, the call `self.local_queues[wi].tryPushBottom(descriptor_index)` now dispatches through the union — no code change needed.

- [ ] **Step 6: Update `nextTask()` steal scan**

In `nextTask` (around line 599-622), replace the stealTopBatch call with the unified `.steal()` method:

```zig
if (self.local_queues[victim_index].len() == 0) continue;
var stolen: [32]u32 = undefined;
const budget = @min(self.config.steal_batch_size, stolen.len);
const n = self.local_queues[victim_index].steal(stolen[0..budget]);
```

Everything else in that block (keep first, push rest to local deque, increment steals counter) stays the same.

- [ ] **Step 7: Update `cancelQueuedTasks()` drain loop**

Around line 764-770 it uses `lq.stealTop()`. Replace with:
```zig
while (lq.stealAll()) |descriptor_index| {
    self.decrementQueued();
    self.cancelDescriptor(descriptor_index);
}
```

- [ ] **Step 8: Update any other `lq.stealTop()` / `lq.popBottom()` / `lq.tryPushBottom()` / `lq.len()` direct callers**

Search with: grep usage patterns. The union's methods already cover them; check:

```
grep -n "stealTop\|popBottom\|tryPushBottom\|\.len()" src/pool.zig
```

All should resolve through the union methods with no further edits.

- [ ] **Step 9: Run all tests**

Run: `zig build test 2>&1 | tail -40`
Expected: all pass. If any stress test fails, the handoff between union arms is wrong — read the failure and fix.

- [ ] **Step 10: Commit**

```bash
git add src/pool.zig
git commit -m "feat(pool): route local_queues through LocalQueue union (chase_lev | ring)"
```

### Task B5: Sanity-check both queue kinds under `test-stress` via a test matrix

**Files:**
- Create: `tests/stress/queue_kind_matrix.zig`
- Modify: `build.zig`

- [ ] **Step 1: Write the matrix test**

Create `tests/stress/queue_kind_matrix.zig`:

```zig
const std = @import("std");
const thread_pool = @import("thread_pool");

fn countTask(raw: *anyopaque, _: *thread_pool.TaskContext) void {
    const c: *std.atomic.Value(u64) = @ptrCast(@alignCast(raw));
    _ = c.fetchAdd(1, .release);
}

fn runScenario(kind: thread_pool.Config.QueueKind, total: u64) !void {
    const allocator = std.testing.allocator;
    var pool = try thread_pool.Pool.init(allocator, .{
        .max_threads = 4,
        .min_threads = 4,
        .queue_capacity = 4096,
        .local_queue_capacity = 256,
        .queue_kind = kind,
        .scheduler_variant = .work_stealing,
        .steal_batch_size = if (kind == .ring) 8 else 1,
    });
    defer pool.deinit();

    var counter = std.atomic.Value(u64).init(0);
    var i: u64 = 0;
    while (i < total) : (i += 1) {
        while (true) {
            _ = pool.submit(.{ .ctx = &counter, .task_fn = countTask }, .{}) catch {
                std.Thread.sleep(1_000);
                continue;
            };
            break;
        }
    }
    try pool.drain();
    try std.testing.expectEqual(total, counter.load(.acquire));
}

test "queue_kind matrix: chase_lev executes all submitted tasks" {
    try runScenario(.chase_lev, 50_000);
}

test "queue_kind matrix: ring executes all submitted tasks" {
    try runScenario(.ring, 50_000);
}
```

(`Config.QueueKind` — export from `types.zig` via the `Config` namespace or re-export at the root. Pick whichever pattern this repo already uses.)

- [ ] **Step 2: Wire into build.zig**

Follow Task A3 Step 2 pattern.

- [ ] **Step 3: Run**

Run: `zig build test-stress 2>&1 | tail -20`
Expected: both scenarios pass.

- [ ] **Step 4: Commit**

```bash
git add tests/stress/queue_kind_matrix.zig build.zig
git commit -m "test(stress): queue_kind matrix exercises both chase_lev and ring"
```

### Task B6: Retune and re-measure `steal_throughput` micro-bench

**Files:**
- Modify: `docs/PERFORMANCE_TRACKING.md`

- [ ] **Step 1: Run `bench-steal-throughput` with batch=1 and batch=8, 5 runs each**

Run:
```
for b in 1 8; do
  for i in 1 2 3 4 5; do
    zig build bench-steal-throughput -Doptimize=ReleaseFast -- --steal_batch_size=$b 2>&1 | grep -E "ops/s|steals|steal_failures"
  done
done
```

If `bench-steal-throughput` doesn't take `--steal_batch_size` as a CLI arg, read its source and pipe the config through whatever flag it already uses, or temporarily edit the bench file's config and revert after measuring.

- [ ] **Step 2: Append Phase B rows to `steal_throughput` table in PERFORMANCE_TRACKING.md**

```markdown
| Phase B (ring queue, batch=1) | <ops/s> | <steals> | <failures> | Task B4: ring replaces Chase-Lev; `stealHalf` capped at 1 for apples-to-apples |
| Phase B (ring queue, batch=8) | <ops/s> | <steals> | <failures> | Task B4: true batch-steal, 8-way; target ≥ 2M ops/s |
```

- [ ] **Step 3: Commit**

```bash
git add docs/PERFORMANCE_TRACKING.md
git commit -m "docs(perf): record Phase B (ring queue) steal_throughput numbers"
```

### Task B7: Re-measure `bench_tokio_parity` against the new defaults

**Files:**
- Modify: `docs/PERFORMANCE_TRACKING.md`
- Modify: `benchmarks/results/baseline.json`

- [ ] **Step 1: Run Tokio-parity suite 3 times, median**

Run: `for i in 1 2 3; do zig build bench-tokio-parity -Doptimize=ReleaseFast 2>&1 | tail -20; done`

- [ ] **Step 2: Append a Phase A+B row to the Tokio-parity table**

```markdown
| flood_1m (Phase A+B) | <ops/s> | 1000000 | 1 | Park handshake simplified; ring queue batch-steal=8; median of 3 |
| contended_spawn_8x (Phase A+B) | <ops/s> | 100000 | 8 | Park handshake simplified; ring queue batch-steal=8; median of 3 |
```

- [ ] **Step 3: Rebaseline `benchmarks/results/baseline.json`**

Whatever command the CI uses to refresh the baseline — typically `zig build bench -Doptimize=ReleaseFast -Drebaseline=true` or similar. Check `benchmarks/compare.zig` for the canonical recipe. Commit the updated JSON.

- [ ] **Step 4: Commit**

```bash
git add docs/PERFORMANCE_TRACKING.md benchmarks/results/baseline.json
git commit -m "bench: rebaseline after park + ring-queue changes"
```

---

## Phase C: Cleanup

### Task C1: Remove dead code in `work_deque.zig`

**Files:**
- Modify: `src/queue/work_deque.zig`

- [ ] **Step 1: Remove `stealTopBatch` and its three tests**

Open `src/queue/work_deque.zig`. Delete:
- the `stealTopBatch` method (lines 94-124 in the current file)
- `test "WorkDeque.stealTopBatch steals multiple items"`
- `test "WorkDeque.stealTopBatch returns 0 on empty deque"`
- `test "WorkDeque.stealTopBatch caps at available count"`

- [ ] **Step 2: Add a deprecation doc-comment at the top of the file**

Replace the top doc-comment with:

```zig
/// Lock-free Chase-Lev work-stealing deque.
///
/// NOTE: kept for `queue_kind = .chase_lev` compatibility. Batch-steal is
/// not supported here (Chase-Lev's single-item steal proof does not
/// generalize). The default work-stealing path uses `RingQueue` in
/// `ring_queue.zig`, which supports a correct `stealHalf`.
```

- [ ] **Step 3: Run tests**

Run: `zig build test 2>&1 | tail -20`
Expected: pass; the three removed tests aren't referenced elsewhere.

- [ ] **Step 4: Commit**

```bash
git add src/queue/work_deque.zig
git commit -m "refactor(queue): drop Chase-Lev stealTopBatch (superseded by ring queue)"
```

### Task C2: Update README.md and final verdict in PERFORMANCE_TRACKING.md

**Files:**
- Modify: `docs/PERFORMANCE_TRACKING.md`
- Modify: `README.md` (only if it quotes concrete numbers — check first)

- [ ] **Step 1: Rewrite the "Verdict vs Targets" table rows that improved**

In `docs/PERFORMANCE_TRACKING.md`, update the rows for:
- `conn_churn_seq/global_queue` throughput
- `conn_churn_seq/work_stealing` throughput
- Submit p50 (single-producer)
- Submit p99 (4 producers)
- `producer_contention/*` completion p50

Change the "After plan" column to reflect the Phase A+B numbers and flip the "Met?" column where appropriate.

- [ ] **Step 2: Add a "Phase A+B final verdict" paragraph below the table**

```markdown
**Phase A+B net result:** The park-handshake simplification recovered the
~1100 ns submit-path regression introduced by the per-worker condvar's
broadcast fallback. The ring-queue swap unlocked `steal_batch_size > 1`,
which shows up most on the Tokio-parity suite's `flood_1m` and
`contended_spawn_8x` scenarios. Remaining gap to Tokio:
[describe honest residual — e.g., wake latency, allocator contention].
```

- [ ] **Step 3: Check README.md**

Run: `grep -n "ops/s\|submit p5\|Tokio" README.md | head -20`
If any concrete numbers are cited, update them; otherwise skip.

- [ ] **Step 4: Commit**

```bash
git add docs/PERFORMANCE_TRACKING.md README.md
git commit -m "docs: record final Phase A+B verdict and updated targets table"
```

### Task C3: CI advisory — bump `bench-micro` ceiling

**Files:**
- Modify: `.gitlab-ci.yml` (only if the `bench-micro` job has hard-coded thresholds)

- [ ] **Step 1: Check whether `bench-micro` has regression thresholds**

Run: `grep -n "submit\|wake\|steal\|threshold" .gitlab-ci.yml`

If the `bench-micro` job is purely advisory (prints numbers but doesn't fail), no change needed — skip to Step 3.

- [ ] **Step 2: Update thresholds to reflect new baseline**

If thresholds exist, tighten them to the new Phase A+B numbers (with headroom, e.g., 1.2x the measured median).

- [ ] **Step 3: Commit (if any changes)**

```bash
git add .gitlab-ci.yml
git commit -m "ci(bench): tighten bench-micro advisory thresholds post Phase A+B"
```

---

## Self-Review Checklist

- **Spec coverage:**
  - "true batch-steal needs a different deque design" → Phase B (Tasks B1-B7). ✓
  - "per-worker park condvar's broadcast fallback is hurting the simple hot path" → Phase A (Tasks A1-A4). ✓
- **Placeholder scan:** code blocks in A1, A2, A3, B1, B2, B4, B5 are complete. Performance-target `<p50>` / `<ops/s>` placeholders in A4, B6, B7, C2 are intentional — they're values to fill in from measurement.
- **Type consistency:**
  - `LocalQueue.steal(out: []u32) usize` is the one unified steal API; `nextTask` uses it uniformly.
  - `Config.queue_kind` is referenced consistently as `.chase_lev` / `.ring`.
  - `RingQueue` exposes `tryPush`, `pop`, `stealHalf`, `len`, `capacity` — matches call sites in the union wrapper.
  - `is_parked` stays `std.atomic.Value(u8)`; seq_cst operations are explicit.

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-04-12-batch-steal-and-park-simplification.md`. Two execution options:

**1. Subagent-Driven (recommended)** — dispatch fresh subagent per task, review between tasks, fast iteration.

**2. Inline Execution** — executing-plans skill, batch execution with checkpoints.

Which approach?
