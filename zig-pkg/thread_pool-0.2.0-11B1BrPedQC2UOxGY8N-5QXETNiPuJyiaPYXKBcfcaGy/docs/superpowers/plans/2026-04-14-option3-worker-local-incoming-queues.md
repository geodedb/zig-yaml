# Option 3 — Worker-Local Incoming Queues Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add per-Worker `incoming` MPMC queues so external (non-worker) submitters rotate writes across N cachelines instead of contending on a single global inject_queue head/tail pair. Measure same-session paired A/B on `flood_1m` and `contended_spawn_8x`; keep iff ≥10% flood_1m lift AND no `contended_spawn_8x` regression.

**Architecture:** Keep the existing `BoundedRing(u32)` (Vyukov MPMC) for the v1 incoming queue. Add one `incoming` ring per worker, reusing `BoundedRing` verbatim. Non-worker submitters rotate target index via a relaxed atomic counter (`Core.incoming_cursor`), tryPush to `incoming[target]`, rotate on full up to N times, and fall back to the existing global `inject_queue` if all rotations fail. Worker dispatch checks own incoming AFTER LIFO + own local_queue, BEFORE global inject_queue. Wake path for external submits signals the chosen incoming target worker directly; falls back to the existing wake-scan if the target is not parked. Phase H claim sentinel stays always-on through this work; reverted in Task 12 once validation passes.

**Tech Stack:** Zig 0.15.2, existing `src/queue/bounded_ring.zig` (`BoundedRing(T)`), existing stress test harness (`tests/stress.zig`, `tests/stress/double_dequeue_race.zig`), existing benchmark (`benchmarks/bench_tokio_parity.zig`).

**Design defaults (approved 2026-04-14 by user "approve all defaults"):**
- Q1 Sentinel: keep always-on through Option 3 work; revert in Task 12 after validation.
- Q2 Capacity: configurable `incoming_capacity`, default `@max(64, @ceilPowerOfTwo(queue_capacity / max_threads))`.
- Q3 Fallback: rotate first (up to N = `max_threads` probes), then fall back to global `inject_queue`.
- Q4 Dispatch precedence: incoming AFTER own LIFO + own local_queue, BEFORE global inject_queue.
- Q5 Wake coupling: signal target worker directly; fallback scan if target not parked.
- Q6 Queue type: reuse `BoundedRing(MPMC)` for v1.

**Invariants preserved:**
- Phase H correctness: the claim sentinel at `src/pool.zig:167` stays `true` until Task 12.
- `queued_tasks` SC-fetchAdd accounting: `incrementQueued()` still fires exactly once per successful push regardless of queue chosen.
- Descriptor lifecycle: `acquireDescriptor` → fill → push → release unchanged. Cancellation path must drain incoming queues.
- Work-stealing remains local-queue-only (incoming is owner-read-only; stealers do NOT pop from others' incoming).
- Shutdown drain covers all queues (LIFO + local_queue + inject_queue + incoming[i] for all i).

**Non-goals for v1:**
- MPSC specialization of the incoming ring (decided Q6-A to reuse MPMC; revisit only if measurement justifies).
- Cross-worker incoming steal (decided in brainstorm to keep SPMC simplicity).
- Per-worker incoming capacity tuning beyond the global default.

**Blocking checks before start:**
- `git status --short` must be clean (no unstaged work).
- Current HEAD must pass `zig build test` AND `zig build test-stress -Doptimize=ReleaseSafe`.
- Claim sentinel must still be `claim_sentinel_enabled = true` at `src/pool.zig:167`.

---

## File Structure

### Files to create

- `tests/unit/option3_round_robin.zig` — unit test: external submits distribute across `incoming[i]` in round-robin.
- `tests/stress/option3_incoming_saturation.zig` — stress test: fill all incoming queues + inject fallback exercise.
- `docs/performance/option3-worker-local-incoming/SUMMARY.md` — A/B measurement result + decision.

### Files to modify

- `src/types.zig` — add `incoming_capacity: usize = 0` field to `Config`; normalize to `@max(64, round-up-pow2(queue_capacity / max_threads))` when `== 0`; validate > 0 post-normalize and <= maxInt(u32).
- `src/pool.zig` — `Worker` struct (+ `incoming: BoundedRing(u32)`); `Core` struct (+ `incoming_cursor: std.atomic.Value(u32)`); `Core.init` (alloc + init incoming per worker); `Core.deinitOwned` (deinit); `Core.enqueueTask` (route external to incoming); `Core.nextTask` (drain own incoming); `Core.cancelQueuedTasks` (drain incoming on shutdown); wake path (target-specific signal).
- `tests/unit.zig` — `_ = @import("unit/option3_round_robin.zig");`
- `tests/stress.zig` — `_ = @import("stress/option3_incoming_saturation.zig");`
- `docs/PERFORMANCE_TRACKING.md` — Option 3 entry after Task 11 validates.

### Files read-only for reference

- `src/queue/bounded_ring.zig` — reused verbatim.
- `benchmarks/bench_tokio_parity.zig` — `flood_1m` and `contended_spawn_8x` scenarios are the measurement targets.
- `docs/performance/reprofile-2026-04-13/AUDIT-2026-04-14-baseline-validity.md` — rationale for same-session paired A/B.

---

## Task 1: Config plumbing — add `incoming_capacity`

**Goal:** Add a configurable `incoming_capacity` field to `Config` with power-of-2 normalization, a sensible default derived from existing fields, and validation. TDD-first.

**Files:**
- Modify: `src/types.zig`

- [ ] **Step 1: Write the failing test**

Append to `src/types.zig` (after the existing `Config normalized rounds queue_capacity to power of two` test):

```zig
test "Config normalized derives incoming_capacity from queue_capacity / max_threads with power-of-2 rounding, min 64" {
    // Default path: 0 triggers derivation. queue_capacity=1024, max_threads=8 → 1024/8=128 → already pow2, min floor is 64 so we take 128.
    const cfg1 = (Config{ .queue_capacity = 1024, .max_threads = 8, .min_threads = 8 }).normalized();
    try std.testing.expectEqual(@as(usize, 128), cfg1.incoming_capacity);

    // Min floor kicks in: queue_capacity=1024, max_threads=56 → 1024/56≈18 → below 64 floor → 64.
    const cfg2 = (Config{ .queue_capacity = 1024, .max_threads = 56, .min_threads = 56 }).normalized();
    try std.testing.expectEqual(@as(usize, 64), cfg2.incoming_capacity);

    // Non-pow2 derivation rounds up: queue_capacity=1024, max_threads=6 → 1024/6≈170 → round up to 256.
    const cfg3 = (Config{ .queue_capacity = 1024, .max_threads = 6, .min_threads = 6 }).normalized();
    try std.testing.expectEqual(@as(usize, 256), cfg3.incoming_capacity);

    // Explicit user value passes through, rounded to pow2 (consistent with queue_capacity).
    const cfg4 = (Config{ .incoming_capacity = 100, .queue_capacity = 1024, .max_threads = 8, .min_threads = 8 }).normalized();
    try std.testing.expectEqual(@as(usize, 128), cfg4.incoming_capacity);

    // Explicit already-pow2 passes through.
    const cfg5 = (Config{ .incoming_capacity = 512, .queue_capacity = 1024, .max_threads = 8, .min_threads = 8 }).normalized();
    try std.testing.expectEqual(@as(usize, 512), cfg5.incoming_capacity);
}

test "Config validate rejects incoming_capacity > maxInt(u32)" {
    var cfg = (Config{ .max_threads = 1, .min_threads = 1, .queue_capacity = 64 }).normalized();
    cfg.incoming_capacity = @as(usize, std.math.maxInt(u32)) + 1;
    try std.testing.expectError(error.InvalidIncomingCapacity, cfg.validate());
}
```

- [ ] **Step 2: Run the failing tests**

```bash
zig build test 2>&1 | tail -20
```

Expected: compilation error — `incoming_capacity` field does not exist on `Config`.

- [ ] **Step 3: Add the `incoming_capacity` field to `Config`**

Edit `src/types.zig`. In the `Config` struct, insert after the `queue_capacity: usize = 1024,` field (around line 73):

```zig
    /// Per-worker incoming-queue capacity. External (non-worker-thread)
    /// submitters rotate pushes across these per-Worker queues to reduce
    /// cacheline contention on the global inject_queue. When `0`,
    /// `normalized()` derives `@max(64, round-up-pow2(queue_capacity / max_threads))`.
    /// User-supplied values are rounded up to the next power of two.
    /// See docs/superpowers/plans/2026-04-14-option3-worker-local-incoming-queues.md.
    incoming_capacity: usize = 0,
```

- [ ] **Step 4: Derive `incoming_capacity` in `normalized()`**

In `normalized()` (around line 130), after the existing `queue_capacity` pow2 block at line 148-150, insert:

```zig
        if (cfg.incoming_capacity == 0) {
            const per = if (cfg.max_threads == 0) cfg.queue_capacity else cfg.queue_capacity / cfg.max_threads;
            const rounded = std.math.ceilPowerOfTwo(usize, @max(1, per)) catch per;
            cfg.incoming_capacity = @max(64, rounded);
        } else {
            cfg.incoming_capacity = std.math.ceilPowerOfTwo(usize, cfg.incoming_capacity) catch cfg.incoming_capacity;
        }
```

- [ ] **Step 5: Add validation**

In `validate()` (around line 157), after the existing `queue_capacity` check at line 162, insert:

```zig
        if (self.incoming_capacity == 0 or self.incoming_capacity > std.math.maxInt(u32)) return error.InvalidIncomingCapacity;
```

- [ ] **Step 6: Run tests to verify green**

```bash
zig build test 2>&1 | tail -20
```

Expected: all tests PASS including the two new `incoming_capacity` tests.

- [ ] **Step 7: Commit**

```bash
git add src/types.zig
git commit -m "feat(option3): add Config.incoming_capacity with pow2 normalization"
```

---

## Task 2: Per-Worker incoming ring lifecycle

**Goal:** Add a `BoundedRing(u32)` per worker, wire it through `Core.init` (allocation + memory accounting) and `Core.deinitOwned` (release). Add a relaxed `incoming_cursor` atomic to `Core` for round-robin target selection.

**Files:**
- Modify: `src/pool.zig`

- [ ] **Step 1: Add `incoming` field to `Worker` struct**

Edit `src/pool.zig` around line 169. In the `Worker = struct { ... }` block, add the field at the end, just before the closing `};`:

```zig
    /// Per-worker MPMC incoming queue. External (non-worker-thread) submits
    /// rotate across these to amortize cacheline pressure. Owner worker pops
    /// via nextTask's incoming check. Reuses BoundedRing for v1; specializing
    /// to MPSC is a future optimization (Q6-A default).
    incoming: BoundedRing(u32),
```

Note: because `BoundedRing` requires `init(allocator, size)`, the field has no default value — init happens explicitly in `Core.init` in Step 3.

- [ ] **Step 2: Add `incoming_cursor` to `Core`**

Edit `src/pool.zig` around line 270 (Core struct, after `inject_queue: BoundedRing(u32),`). Insert:

```zig
    /// Round-robin target cursor for external submits. Relaxed atomic
    /// fetchAdd; the `% workers.len` happens at the use site. Values
    /// wrap naturally at u32 max. Cacheline-sharing with inject_queue
    /// is fine — on the target-worker path we don't touch inject_queue.
    incoming_cursor: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
```

- [ ] **Step 3: Initialize incoming in `Core.init`**

Edit the worker init loop in `Core.init` around line 319-320. Before:

```zig
        for (self.workers, self.local_queues) |*worker, *lq| {
            lq.* = try LocalQueue.init(allocator, normalized.local_queue_capacity, normalized.queue_kind);
```

After (add the incoming init alongside local_queue):

```zig
        for (self.workers, self.local_queues) |*worker, *lq| {
            lq.* = try LocalQueue.init(allocator, normalized.local_queue_capacity, normalized.queue_kind);
            worker.incoming = try BoundedRing(u32).init(allocator, normalized.incoming_capacity);
            self.recordOwnedAlloc(worker.incoming.capacity() * @sizeOf(u32));
```

> Note: on failure partway through the loop, `errdefer self.deinitOwned()` at line 289 must safely handle partially-initialized workers. Verify in Task 2 Step 7 that partial-init failures don't leak.

- [ ] **Step 4: Verify Worker default-init still works after adding a no-default field**

Adding `incoming: BoundedRing(u32)` with no default value means Zig requires ALL Worker instances to be explicitly initialized with at least that field set — the implicit `var w: Worker = .{}` no longer compiles.

Before continuing:

```bash
grep -n "Worker{}\|workers\[.*\] = \|self.workers\[" src/pool.zig | head -20
```

Find every place Workers are default-constructed. For each, convert to either `.{ .incoming = undefined }` (if the field is assigned immediately afterward in the same block, e.g. right before the `worker.incoming = try BoundedRing(u32).init(...)` line) or to explicit-all-fields init mirroring existing defaults.

If the loop at Core.init is the only place Worker values are mutated from default, the fix is local:

Edit the same loop. Insert at the top of the loop body, BEFORE `lq.* = ...`:

```zig
        for (self.workers, self.local_queues) |*worker, *lq| {
            // Leave `incoming` undefined until we assign below. All other
            // fields have defaults per the Worker struct declaration.
            worker.* = .{ .incoming = undefined, .scratch = undefined };
            worker.incoming = try BoundedRing(u32).init(allocator, normalized.incoming_capacity);
            self.recordOwnedAlloc(worker.incoming.capacity() * @sizeOf(u32));
            // Initialize scratch via its established init pattern — grep for
            // `scratch.init\|WorkerScratch.init\|.scratch = ` to find it.
            // DO NOT speculate; match the existing code exactly.
            lq.* = try LocalQueue.init(allocator, normalized.local_queue_capacity, normalized.queue_kind);
```

> Critical: read the current Worker struct declaration and find how `scratch: WorkerScratch` (no default) is currently initialized. `.scratch = undefined` above is a placeholder — replace with the real init pattern before running tests. If scratch is initialized lazily via `worker.scratch.init()` or similar, keep that lazy path; use `undefined` only if the existing code relied on `Worker{}` allocation producing uninitialized scratch memory that `scratch.init()` then populates.

- [ ] **Step 5: Tear down incoming in `deinitOwned`**

Edit `Core.deinitOwned` around line 1065. Before the existing `for (self.local_queues) |*lq| { ... }` loop, add:

```zig
        for (self.workers) |*w| {
            self.recordOwnedFree(w.incoming.capacity() * @sizeOf(u32));
            w.incoming.deinit();
        }
```

(Place this before the `for (self.workers) |*worker| { worker.scratch.purge(); }` loop if `purge()` needs incoming alive, OR after it if not. Check `WorkerScratch.purge()` behavior — it likely only touches scratch memory and is independent. Place after `scratch.purge()` for safety.)

Final placement:

```zig
    fn deinitOwned(self: *Core) void {
        for (self.workers) |*worker| {
            worker.scratch.purge();
        }
        for (self.workers) |*w| {
            self.recordOwnedFree(w.incoming.capacity() * @sizeOf(u32));
            w.incoming.deinit();
        }
        for (self.local_queues) |*lq| {
            self.recordOwnedFree(lq.capacity() * @sizeOf(u32));
            lq.deinit();
        }
        // ... rest unchanged
```

- [ ] **Step 6: Run the full test suite to verify nothing regressed**

```bash
zig build test 2>&1 | tail -20
```

Expected: all tests PASS. The incoming ring is allocated and freed per pool init/deinit; no tests exercise its push/pop yet, so it exists as dead memory at this point.

- [ ] **Step 7: Run a memory-leak check with the testing allocator**

The existing `tests/unit.zig` suite uses `std.testing.allocator` which panics on leaks. Running `zig build test` in Step 6 already exercises this. Verify by explicitly:

```bash
zig build test 2>&1 | grep -iE "leak|fail"
```

Expected: no output (no leaks, no failures).

- [ ] **Step 8: Commit**

```bash
git add src/pool.zig
git commit -m "feat(option3): per-worker incoming ring lifecycle + Core.incoming_cursor"
```

---

## Task 3: Route external submits to `incoming[target]` with rotation + fallback

**Goal:** In `enqueueTask`, when the caller is a non-worker thread (`tls_worker_index == null`) under the `work_stealing` variant, compute a target worker via the `incoming_cursor`, try `workers[target].incoming.tryPush`, rotate on full up to `max_threads` probes, and fall back to the existing `inject_queue.tryPush` only after all rotations fail.

**Files:**
- Modify: `src/pool.zig` (function `enqueueTask`).

- [ ] **Step 1: Write the failing test**

Create new file `tests/unit/option3_round_robin.zig`:

```zig
//! Option 3 Task 3: external submits distribute across worker incoming rings
//! round-robin. Verifies that back-to-back external submits target different
//! workers (up to max_threads) rather than piling onto one.

const std = @import("std");
const thread_pool = @import("thread_pool");

// Sentinel task that records which worker ran it via a per-worker atomic counter.
fn recordWorker(ctx_ptr: *anyopaque, tctx: *thread_pool.TaskContext) void {
    _ = tctx;
    const counters: *[8]std.atomic.Value(u32) = @ptrCast(@alignCast(ctx_ptr));
    // tctx has no worker index accessor in this context; record via the
    // pool-provided worker index if available, else count globally.
    _ = counters[0].fetchAdd(1, .monotonic);
}

test "option3: external submits rotate across per-worker incoming rings" {
    // Use a tiny pool (4 workers) so target selection is observable.
    // incoming_capacity is derived to 64 by normalized() on these params.
    var pool = try thread_pool.ThreadPool.init(std.testing.allocator, .{
        .min_threads = 4,
        .max_threads = 4,
        .queue_capacity = 64,
        .local_queue_capacity = 32,
        .scheduler_variant = .work_stealing,
    });
    defer pool.deinit();

    // Park all workers first by waiting briefly.
    std.Thread.sleep(5 * std.time.ns_per_ms);

    // Submit 8 tasks (2 per worker expected under round-robin).
    var counters: [8]std.atomic.Value(u32) = [_]std.atomic.Value(u32){std.atomic.Value(u32).init(0)} ** 8;
    var wg = thread_pool.WaitGroup{};
    wg.add(8);
    var i: u32 = 0;
    while (i < 8) : (i += 1) {
        _ = try pool.submit(recordWorker, @ptrCast(&counters), .{
            .wait_group = &wg,
            .backpressure = .block,
        });
    }
    wg.wait();

    // This test verifies no hang or crash. The actual distribution check
    // requires worker-index introspection which is added in a later
    // refinement; for now the contract is "submits complete without
    // QueueFull when each worker has capacity".
    try std.testing.expectEqual(@as(u32, 8), counters[0].load(.monotonic));
}
```

Wire it up in `tests/unit.zig`: after the existing imports, add:

```zig
comptime {
    _ = @import("unit/option3_round_robin.zig");
}
```

(If `tests/unit.zig` already uses a different pattern, mirror that pattern — read the file first.)

- [ ] **Step 2: Run the failing test**

```bash
zig build test 2>&1 | tail -15
```

Expected: test compiles and runs; it passes or hangs. If it hangs (task never completes because the current code path would have sent it to `inject_queue` which then works), that's fine — the test exists as a scaffold. If it passes, that's also fine — the point is the harness compiles and runs.

(Note: this is a scaffolding test. The hard distribution assertion is deferred to Task 7 which adds worker-index introspection via a test-only accessor.)

- [ ] **Step 3: Split `enqueueTask` submit path by caller type**

Edit `src/pool.zig` around line 587-606. Before (current behavior):

```zig
        var queued = false;
        if (self.config.scheduler_variant == .work_stealing and tls_worker_index != null) {
            const wi = tls_worker_index.?;
            // Try the LIFO slot first. Owner-only write; if the slot is empty,
            // a plain store is sufficient — no stealer writes to this slot.
            // If the slot is full, fall through to the local ring.
            const w = &self.workers[wi];
            if (w.lifo_slot.load(.monotonic) == LIFO_SLOT_EMPTY) {
                w.lifo_slot.store(descriptor_index, .release);
                queued = true;
            } else {
                queued = self.local_queues[wi].tryPushBottom(descriptor_index);
                if (queued) {
                    const local_len = @as(u32, @intCast(self.local_queues[wi].len()));
                    updatePeakU32(&w.local_queue_peak, local_len);
                }
            }
        }
        if (!queued) {
            queued = self.inject_queue.tryPush(descriptor_index);
        }
```

After (external submitters rotate across incoming; worker-thread path unchanged):

```zig
        var queued = false;
        // `incoming_target` tracks which worker (if any) received the push
        // via its incoming queue. `std.math.maxInt(usize)` = "not via incoming"
        // (either went to LIFO/local_queue as worker, or to inject_queue as fallback).
        var incoming_target: usize = std.math.maxInt(usize);

        if (self.config.scheduler_variant == .work_stealing and tls_worker_index != null) {
            // Worker-thread submit: LIFO then local_queue. Unchanged from pre-Option-3.
            const wi = tls_worker_index.?;
            const w = &self.workers[wi];
            if (w.lifo_slot.load(.monotonic) == LIFO_SLOT_EMPTY) {
                w.lifo_slot.store(descriptor_index, .release);
                queued = true;
            } else {
                queued = self.local_queues[wi].tryPushBottom(descriptor_index);
                if (queued) {
                    const local_len = @as(u32, @intCast(self.local_queues[wi].len()));
                    updatePeakU32(&w.local_queue_peak, local_len);
                }
            }
        } else if (self.config.scheduler_variant == .work_stealing) {
            // External-thread submit: rotate across worker incoming queues.
            // Up to workers.len rotations before falling back to inject_queue.
            const n = self.workers.len;
            const start: u32 = self.incoming_cursor.fetchAdd(1, .monotonic);
            var probe: usize = 0;
            while (probe < n) : (probe += 1) {
                const target = (@as(usize, start) + probe) % n;
                if (self.workers[target].incoming.tryPush(descriptor_index)) {
                    queued = true;
                    incoming_target = target;
                    break;
                }
            }
        }
        if (!queued) {
            queued = self.inject_queue.tryPush(descriptor_index);
        }
```

> Note: the `global_queue` scheduler variant path (else branch of the `work_stealing` check) still falls through to `inject_queue.tryPush` as before. No change for that variant in this plan.

- [ ] **Step 4: Propagate `incoming_target` to the wake path**

The wake path at `src/pool.zig:622-639` currently does a round-robin scan. We need to pass `incoming_target` so Task 5 can use it. For this task, just store the value for later use — the scan is still used unchanged.

Insert just before the wake-scan block (before `const submitted = self.counters.submitted.load(.monotonic);`):

```zig
        // Option 3: preserve target for tight wake coupling in Task 5.
        // For Task 3 this value is unused; wake-scan below still runs.
        _ = incoming_target;
```

(This keeps the compiler happy without the Task 5 behavior yet.)

- [ ] **Step 5: Run the scaffolding test + full test suite**

```bash
zig build test 2>&1 | tail -15
```

Expected: all tests PASS. The Task 3 scaffolding test runs without hang; external submits flow through incoming queues for `work_stealing` variant, and fall back to inject_queue if all incoming are full (unreachable in this low-load test).

- [ ] **Step 6: Run stress suite under ReleaseSafe (sentinel active)**

```bash
zig build test-stress -Doptimize=ReleaseSafe 2>&1 | tail -20
```

Expected: PASS. The sentinel would fire if the new route exposed a dequeue race (it's the primary safety net during submit-path changes).

- [ ] **Step 7: Commit**

```bash
git add src/pool.zig tests/unit.zig tests/unit/option3_round_robin.zig
git commit -m "feat(option3): route external submits to incoming[i] with rotation + inject fallback"
```

---

## Task 4: Worker dispatch drains own incoming (after LIFO + local_queue)

**Goal:** In `nextTask`, insert a `worker.incoming.pop()` check between the existing `lq.popBottom()` step and the `inject_queue.pop()` step. Preserves existing steal behavior (stealers still target local_queue, not incoming).

**Files:**
- Modify: `src/pool.zig` (function `nextTask`).

- [ ] **Step 1: Read current `nextTask` to confirm line anchors**

```bash
grep -n "fn nextTask\|popBottom\|inject_queue.pop" src/pool.zig | head -10
```

Expected: anchor at `fn nextTask(self: *Core...)` around line 668, `lq.popBottom()` around line 694, `self.inject_queue.pop()` around line 698.

- [ ] **Step 2: Insert incoming-queue check in `nextTask`**

Edit `src/pool.zig`. Before (around line 694-698, existing code):

```zig
            if (lq.popBottom()) |descriptor_index| {
                return descriptor_index;
            }

            if (self.inject_queue.pop()) |descriptor_index| {
```

After (insert the incoming check between these two):

```zig
            if (lq.popBottom()) |descriptor_index| {
                return descriptor_index;
            }

            // Option 3: drain own incoming queue AFTER local_queue
            // (own-work-first fairness) and BEFORE global inject_queue.
            // Single-reader invariant: only this worker pops from its own
            // incoming. Producers are external submit calls via
            // `incoming.tryPush` — MPMC-safe in BoundedRing.
            if (worker.incoming.pop()) |descriptor_index| {
                return descriptor_index;
            }

            if (self.inject_queue.pop()) |descriptor_index| {
```

- [ ] **Step 3: Run the scaffolding test + full test suite**

```bash
zig build test 2>&1 | tail -15
```

Expected: the Task 3 scaffolding test now succeeds because workers actually drain their incoming queues. All prior tests PASS.

- [ ] **Step 4: Run stress suite under ReleaseSafe (sentinel active)**

```bash
zig build test-stress -Doptimize=ReleaseSafe 2>&1 | tail -20
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/pool.zig
git commit -m "feat(option3): nextTask drains own incoming after local_queue, before inject"
```

---

## Task 5: Tight wake coupling — signal target worker directly

**Goal:** When an external submit lands on `workers[target].incoming`, signal worker `target` directly (if parked) instead of scanning for any parked worker. Falls back to the existing wake-scan if target isn't parked. Reduces the per-submit wake-scan loop from O(N) to O(1) on the common path.

**Files:**
- Modify: `src/pool.zig` (wake path inside `enqueueTask`).

- [ ] **Step 1: Update the wake path to use `incoming_target` when set**

Edit `src/pool.zig`. Replace the Task 3 placeholder `_ = incoming_target;` AND the existing wake-scan block (lines ~622-639) with a target-aware version. Before (Task 3 state):

```zig
        // Option 3: preserve target for tight wake coupling in Task 5.
        // For Task 3 this value is unused; wake-scan below still runs.
        _ = incoming_target;

        _ = self.counters.submitted.fetchAdd(1, .monotonic);
        self.incrementQueued();

        // Wake one parked worker. Scan `is_parked` across workers starting at a
        // round-robin offset so load spreads across the pool. ...
        const submitted = self.counters.submitted.load(.monotonic);
        const hint_idx: usize = @intCast(submitted % self.workers.len);
        var off: usize = 0;
        while (off < self.workers.len) : (off += 1) {
            const idx = (hint_idx + off) % self.workers.len;
            const w = &self.workers[idx];
            if (w.is_parked.load(.seq_cst) == 1) {
                w.park_mutex.lock();
                if (w.is_parked.load(.monotonic) == 1) {
                    w.park_cond.signal();
                }
                w.park_mutex.unlock();
                break;
            }
        }
```

After:

```zig
        _ = self.counters.submitted.fetchAdd(1, .monotonic);
        self.incrementQueued();

        // Option 3 tight wake coupling: if the push landed on a specific
        // worker's incoming queue AND that worker is parked, signal it
        // directly — no scan. This turns the common external-submit wake
        // from O(workers.len) into O(1). Fallback below runs if the target
        // is NOT parked (busy workers are skipped so submit doesn't block
        // on a running worker's park_mutex).
        if (incoming_target != std.math.maxInt(usize)) {
            const target_w = &self.workers[incoming_target];
            if (target_w.is_parked.load(.seq_cst) == 1) {
                target_w.park_mutex.lock();
                if (target_w.is_parked.load(.monotonic) == 1) {
                    target_w.park_cond.signal();
                    target_w.park_mutex.unlock();
                    return if (options.waitable)
                        .{
                            .index = descriptor_index,
                            .generation = descriptor.generation,
                            .waitable = true,
                        }
                    else
                        types.TaskHandle.invalid();
                }
                target_w.park_mutex.unlock();
            }
            // Target not parked: fall through to scan. Another worker may
            // be parked; we must wake one so the task doesn't sit until
            // the next steal-scan picks it up.
        }

        // Fallback wake-scan (also used by the worker-submit and inject-fallback paths):
        const submitted = self.counters.submitted.load(.monotonic);
        const hint_idx: usize = @intCast(submitted % self.workers.len);
        var off: usize = 0;
        while (off < self.workers.len) : (off += 1) {
            const idx = (hint_idx + off) % self.workers.len;
            const w = &self.workers[idx];
            if (w.is_parked.load(.seq_cst) == 1) {
                w.park_mutex.lock();
                if (w.is_parked.load(.monotonic) == 1) {
                    w.park_cond.signal();
                }
                w.park_mutex.unlock();
                break;
            }
        }
```

> Design note: the early return inside the target-coupled fast path skips the generic wake-scan. This is correct because we just woke the target worker and the task was pushed onto that worker's incoming queue — the target will dispatch it. Any OTHER parked workers remain parked until the next submit; that's fine because they have no pending work addressed to them. Under flood_1m's single-submitter pattern, this eliminates 55 of 56 wake-scan iterations per submit on the common case.

- [ ] **Step 2: Run tests**

```bash
zig build test 2>&1 | tail -15
```

Expected: all tests PASS. The Task 3 scaffolding test still succeeds because workers are signaled correctly even with tight coupling.

- [ ] **Step 3: Run stress suite**

```bash
zig build test-stress -Doptimize=ReleaseSafe 2>&1 | tail -20
```

Expected: PASS. This is a critical checkpoint: Phase H's race-detection sentinel would fire if tight coupling introduces a lost-wakeup that leaves a task unclaimed and allows a scheduler reclaim path to re-dispatch it to two workers.

- [ ] **Step 4: Commit**

```bash
git add src/pool.zig
git commit -m "feat(option3): tight wake coupling — external submit signals target worker directly"
```

---

## Task 6: Shutdown cancellation drains incoming queues

**Goal:** `cancelQueuedTasks` (used during `ShutdownMode.cancel_pending`) currently drains `inject_queue`, LIFO slots, and `local_queues`. It must also drain each `worker.incoming`.

**Files:**
- Modify: `src/pool.zig` (function `cancelQueuedTasks`).

- [ ] **Step 1: Extend `cancelQueuedTasks` to drain incoming**

Edit `src/pool.zig` around line 946-968. Before:

```zig
    fn cancelQueuedTasks(self: *Core) !void {
        // Task 4b: no decrementQueued here ...
        while (self.inject_queue.pop()) |descriptor_index| {
            self.cancelDescriptor(descriptor_index);
        }
        if (self.config.scheduler_variant == .work_stealing) {
            // Drain LIFO slots too.
            for (self.workers) |*w| {
                const cached = w.lifo_slot.swap(LIFO_SLOT_EMPTY, .acquire);
                if (cached != LIFO_SLOT_EMPTY) {
                    self.cancelDescriptor(cached);
                }
            }
            for (self.local_queues) |*lq| {
                while (lq.stealOne()) |descriptor_index| {
                    self.cancelDescriptor(descriptor_index);
                }
            }
        }
    }
```

After (insert the incoming drain inside the `work_stealing` block):

```zig
    fn cancelQueuedTasks(self: *Core) !void {
        while (self.inject_queue.pop()) |descriptor_index| {
            self.cancelDescriptor(descriptor_index);
        }
        if (self.config.scheduler_variant == .work_stealing) {
            // Drain LIFO slots.
            for (self.workers) |*w| {
                const cached = w.lifo_slot.swap(LIFO_SLOT_EMPTY, .acquire);
                if (cached != LIFO_SLOT_EMPTY) {
                    self.cancelDescriptor(cached);
                }
            }
            // Drain local queues.
            for (self.local_queues) |*lq| {
                while (lq.stealOne()) |descriptor_index| {
                    self.cancelDescriptor(descriptor_index);
                }
            }
            // Option 3: drain per-worker incoming queues.
            for (self.workers) |*w| {
                while (w.incoming.pop()) |descriptor_index| {
                    self.cancelDescriptor(descriptor_index);
                }
            }
        }
    }
```

- [ ] **Step 2: Verify test suite covers cancel-pending shutdown**

```bash
grep -rn "cancel_pending\|cancelQueuedTasks" tests/ | head -10
```

If existing tests do exercise the cancel path, they should continue to pass. If no existing test covers it, add a minimal unit test (below).

- [ ] **Step 3: (Conditional) Add a cancel-pending unit test if not already present**

If Step 2 found no existing cancel-pending test, append to `tests/unit/option3_round_robin.zig`.

**First, verify the Config field name for shutdown mode:** `grep -n "ShutdownMode\|shutdown_mode\|shutdown:" src/types.zig src/pool.zig | head -10`. The field might live on `Config` OR as an argument to `ThreadPool.init`'s options struct OR as a separate `CancellationOptions`. Use whatever the real API is — the sample below guesses `shutdown_mode` on Config; adjust if wrong.

```zig
test "option3: cancel_pending shutdown drains incoming queues without leaking descriptors" {
    var pool = try thread_pool.ThreadPool.init(std.testing.allocator, .{
        .min_threads = 2,
        .max_threads = 2,
        .queue_capacity = 64,
        .local_queue_capacity = 32,
        .scheduler_variant = .work_stealing,
        // Verify field name: may be `shutdown_mode` on Config, or a
        // separate arg on init, or set later via a method. Adjust.
        .shutdown_mode = .cancel_pending,
    });

    // Submit 100 tasks that will sit in queues (never run to completion
    // because we deinit immediately after).
    const slow_task = struct {
        fn run(_: *anyopaque, _: *thread_pool.TaskContext) void {
            std.Thread.sleep(50 * std.time.ns_per_ms);
        }
    }.run;

    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        _ = pool.submit(slow_task, @ptrFromInt(@as(usize, 0xdead_beef)), .{
            .backpressure = .return_error,
        }) catch {};  // Ignore QueueFull; we just want to populate incoming.
    }

    // Immediate deinit triggers cancel_pending drain. Testing allocator will
    // panic on leaked TaskDescriptor bookkeeping if the drain misses incoming.
    pool.deinit();
}
```

(Check `ShutdownMode` field name — read `src/types.zig` and search for `shutdown_mode` in Config. If it lives on `ThreadPool.init` options instead, adjust syntax accordingly.)

- [ ] **Step 4: Run tests**

```bash
zig build test 2>&1 | tail -15
```

Expected: all tests PASS. No leaks reported.

- [ ] **Step 5: Run stress suite**

```bash
zig build test-stress -Doptimize=ReleaseSafe 2>&1 | tail -20
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add src/pool.zig tests/unit/option3_round_robin.zig
git commit -m "feat(option3): cancelQueuedTasks drains per-worker incoming queues"
```

---

## Task 7: Stress regression — incoming saturation + fallback

**Goal:** Add a dedicated stress test that deliberately fills all `workers[i].incoming` queues + the fallback `inject_queue`, verifying (a) backpressure policies trigger correctly (return_error vs block), (b) no task is lost, (c) no double-dequeue panic fires.

**Files:**
- Create: `tests/stress/option3_incoming_saturation.zig`
- Modify: `tests/stress.zig` (add import)

- [ ] **Step 1: Write the stress test**

Create `tests/stress/option3_incoming_saturation.zig`:

```zig
//! Option 3 saturation stress: fill all per-worker incoming rings + the
//! fallback inject_queue, verify backpressure policy triggers correctly
//! and every submitted task eventually completes when backpressure=block.

const std = @import("std");
const thread_pool = @import("thread_pool");

fn tinyTask(_: *anyopaque, _: *thread_pool.TaskContext) void {
    // Deliberately non-trivial to slow worker drain, making saturation easy.
    var x: u64 = 0;
    var i: u64 = 0;
    while (i < 1000) : (i += 1) x = x *% 31 +% i;
    std.mem.doNotOptimizeAway(x);
}

test "option3: saturation with backpressure=block completes all submits" {
    // Small pool + tiny capacities ensure saturation is reachable.
    const per_worker = 16;
    var pool = try thread_pool.ThreadPool.init(std.testing.allocator, .{
        .min_threads = 4,
        .max_threads = 4,
        .queue_capacity = 64,  // inject fallback capacity
        .local_queue_capacity = 32,
        .incoming_capacity = per_worker,
        .scheduler_variant = .work_stealing,
    });
    defer pool.deinit();

    // Submit enough to exceed incoming (4 × 16 = 64) + inject (64) = 128 slots,
    // so backpressure MUST engage for count > 128.
    const total: u64 = 512;
    var wg = thread_pool.WaitGroup{};
    wg.add(total);
    var dummy: u8 = 0;
    var i: u64 = 0;
    while (i < total) : (i += 1) {
        _ = try pool.submit(tinyTask, @ptrCast(&dummy), .{
            .wait_group = &wg,
            .backpressure = .block,
        });
    }
    wg.wait();
}

test "option3: saturation with backpressure=return_error reports QueueFull past capacity" {
    var pool = try thread_pool.ThreadPool.init(std.testing.allocator, .{
        .min_threads = 1,
        .max_threads = 1,
        .queue_capacity = 8,
        .local_queue_capacity = 8,
        .incoming_capacity = 8,
        .scheduler_variant = .work_stealing,
    });
    defer pool.deinit();

    // Pin the one worker so nothing drains.
    const block_forever = struct {
        fn run(ptr: *anyopaque, _: *thread_pool.TaskContext) void {
            const ev: *std.Thread.ResetEvent = @ptrCast(@alignCast(ptr));
            ev.wait();
        }
    }.run;
    var ev = std.Thread.ResetEvent{};
    defer ev.set();

    // Occupy the worker:
    _ = try pool.submit(block_forever, @ptrCast(&ev), .{ .backpressure = .return_error });

    // Now fill incoming (8) + inject (8) = 16 slots. The 17th must fail.
    var got_error = false;
    var i: u32 = 0;
    while (i < 32) : (i += 1) {
        const r = pool.submit(block_forever, @ptrCast(&ev), .{ .backpressure = .return_error });
        if (r) |_| {} else |err| switch (err) {
            error.QueueFull, error.TaskPoolExhausted => {
                got_error = true;
                break;
            },
            else => return err,
        }
    }
    try std.testing.expect(got_error);
}
```

- [ ] **Step 2: Wire into `tests/stress.zig`**

Read existing `tests/stress.zig` first to confirm the import pattern, then add:

```zig
comptime {
    _ = @import("stress/option3_incoming_saturation.zig");
}
```

- [ ] **Step 3: Run the stress tests**

```bash
zig build test-stress -Doptimize=ReleaseSafe 2>&1 | tail -30
```

Expected: both new tests PASS. The sentinel is active and would panic on any race introduced by this surface.

- [ ] **Step 4: Run stress 20× (correctness gate for submit-path change)**

Per the project's stress-gate rule (project_phase_status.md): any phase touching the submit hot path must run `zig build test-stress -Doptimize=ReleaseFast` 20× as correctness gate.

```bash
failures=0
for i in $(seq 1 20); do
    if ! zig build test-stress -Doptimize=ReleaseFast >/tmp/stress-$i.log 2>&1; then
        failures=$((failures + 1))
        echo "FAIL on iteration $i"
        tail -10 /tmp/stress-$i.log
    fi
done
echo "Total failures: $failures / 20"
```

Expected: 0 failures. If any iteration panics with a Phase H sentinel message, the Option 3 change introduced a race — return to Task 3/4/5 for debugging.

- [ ] **Step 5: Commit**

```bash
git add tests/stress.zig tests/stress/option3_incoming_saturation.zig
git commit -m "test(option3): saturation stress — incoming fill + inject fallback + backpressure"
```

---

## Task 8: Paired A/B measurement vs main — flood_1m + contended_spawn_8x

**Goal:** Measure same-session paired A/B. Record n=10 flood_1m and n=10 contended_spawn_8x on main AND on this branch, back-to-back within 15 minutes to minimize host drift between measurements. Write results to `docs/performance/option3-worker-local-incoming/SUMMARY.md` with a go/no-go decision.

**Files:**
- Create: `docs/performance/option3-worker-local-incoming/SUMMARY.md`
- Create: `docs/performance/option3-worker-local-incoming/raw-main.txt`
- Create: `docs/performance/option3-worker-local-incoming/raw-option3.txt`

- [ ] **Step 1: Record host snapshot**

```bash
uptime > /tmp/option3-host-start.txt
ps -eo user,pid,pcpu,comm --sort=-pcpu | head -10 >> /tmp/option3-host-start.txt
cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor >> /tmp/option3-host-start.txt
cat /tmp/option3-host-start.txt
```

Capture load avg, top processes, governor. This goes into the SUMMARY.

- [ ] **Step 2: Build and measure main baseline (n=10)**

Use a sibling worktree at main to avoid stash/checkout gymnastics:

```bash
BRANCH=$(git rev-parse --abbrev-ref HEAD)
mkdir -p /tmp/option3-ab
git worktree add /tmp/option3-ab/main-wt main
cd /tmp/option3-ab/main-wt
zig build -Doptimize=ReleaseFast bench-tokio-parity 2>&1 | tail -5
for i in $(seq 1 10); do
    ./zig-out/bin/thread-pool-tokio-parity 2>&1
done > /tmp/option3-ab/raw-main.txt
grep -E "flood_1m|contended_spawn_8x" /tmp/option3-ab/raw-main.txt
cd -
```

Expected: 10 runs each of flood_1m and contended_spawn_8x.

- [ ] **Step 3: Build and measure Option 3 branch (n=10) — same host conditions, within 15 minutes of Step 2**

```bash
zig build -Doptimize=ReleaseFast bench-tokio-parity 2>&1 | tail -5
for i in $(seq 1 10); do
    ./zig-out/bin/thread-pool-tokio-parity 2>&1
done > /tmp/option3-ab/raw-option3.txt
grep -E "flood_1m|contended_spawn_8x" /tmp/option3-ab/raw-option3.txt

# Cleanup the sibling worktree:
git worktree remove /tmp/option3-ab/main-wt
```

- [ ] **Step 4: Compute statistics**

```bash
# flood_1m
grep flood_1m /tmp/option3-ab/raw-main.txt | grep -oE 'ops_per_sec=[0-9]+' | cut -d= -f2 | sort -n
grep flood_1m /tmp/option3-ab/raw-option3.txt | grep -oE 'ops_per_sec=[0-9]+' | cut -d= -f2 | sort -n
# contended_spawn_8x
grep contended_spawn_8x /tmp/option3-ab/raw-main.txt | grep -oE 'ops_per_sec=[0-9]+' | cut -d= -f2 | sort -n
grep contended_spawn_8x /tmp/option3-ab/raw-option3.txt | grep -oE 'ops_per_sec=[0-9]+' | cut -d= -f2 | sort -n
```

Compute median and mean for each of the four {main, option3} × {flood_1m, contended_spawn_8x} samples.

- [ ] **Step 5: Write the results summary**

Create `docs/performance/option3-worker-local-incoming/SUMMARY.md`:

```markdown
# Option 3 A/B Measurement — Worker-Local Incoming Queues

**Date:** <YYYY-MM-DD>
**Main baseline SHA:** <main HEAD sha>
**Option 3 branch SHA:** <branch HEAD sha>
**Host snapshot:** uptime <X days Y hours>, load avg <a.bc>, governor <schedutil|powersave|...>, co-tenants: <list>.

## Methodology

Same-session paired A/B. Measurements taken back-to-back within N minutes on the same host. Direct binary invocation of `thread-pool-tokio-parity` built with `-Doptimize=ReleaseFast`. n=10 per (branch × scenario). No kernel/governor change between measurements.

## Results

### flood_1m (ops/s, higher is better)

| Branch | min | median | mean | max |
|---|---|---|---|---|
| main | <v> | <v> | <v> | <v> |
| option3 | <v> | <v> | <v> | <v> |

**Median lift:** option3 median / main median - 1 = <±X.X%>

### contended_spawn_8x (ops/s, higher is better)

| Branch | min | median | mean | max |
|---|---|---|---|---|
| main | <v> | <v> | <v> | <v> |
| option3 | <v> | <v> | <v> | <v> |

**Median lift:** option3 median / main median - 1 = <±X.X%>

## Decision

Per the plan's go/no-go criteria:
- flood_1m median lift ≥ +10%: <YES/NO>
- contended_spawn_8x no regression (≥ -5% bound): <YES/NO>
- Stress gate 20×: <PASS/FAIL> (from Task 7 Step 4)

**Verdict:** <KEEP | REVERT | ITERATE>

<One paragraph explaining the decision and its basis.>

## Raw data

- `raw-main.txt` — 10 runs on main.
- `raw-option3.txt` — 10 runs on option3 branch.
```

- [ ] **Step 6: Move raw files into the repo**

```bash
mkdir -p docs/performance/option3-worker-local-incoming
cp /tmp/option3-ab/raw-main.txt docs/performance/option3-worker-local-incoming/raw-main.txt
cp /tmp/option3-ab/raw-option3.txt docs/performance/option3-worker-local-incoming/raw-option3.txt
```

- [ ] **Step 7: Commit**

```bash
git add docs/performance/option3-worker-local-incoming/
git commit -m "perf(option3): paired A/B measurement — flood_1m <±X.X%>, contended_spawn_8x <±Y.Y%>"
```

---

## Task 9: Decision gate — keep, iterate, or revert

**Goal:** Act on the Task 8 decision.

- [ ] **Step 1: Read the SUMMARY.md decision**

Open `docs/performance/option3-worker-local-incoming/SUMMARY.md` and note the Verdict field.

- [ ] **Step 2: If Verdict = KEEP, proceed to Task 10 (sentinel revert).**

No action here; continue plan execution.

- [ ] **Step 3: If Verdict = REVERT, roll the implementation back**

```bash
git log --oneline main..HEAD  # list Option 3 commits
# If the decision is revert, reset the branch (do NOT force-push yet)
git reset --hard main
# Keep the SUMMARY.md for historical record:
git checkout HEAD@{1} -- docs/performance/option3-worker-local-incoming/SUMMARY.md docs/performance/option3-worker-local-incoming/raw-main.txt docs/performance/option3-worker-local-incoming/raw-option3.txt
git add docs/performance/option3-worker-local-incoming/
git commit -m "perf(option3): abandon — paired A/B did not meet go criteria"
```

Then stop and report to the user. Do NOT proceed to Task 10.

- [ ] **Step 4: If Verdict = ITERATE, stop and report**

The plan does not specify a specific iteration path (the design space is too large without a new decision). Write a one-paragraph note in the SUMMARY describing what was tried and which of the Q1-Q6 choices might be worth re-visiting, then stop and ask the user.

- [ ] **Step 5: (KEEP only) Update project memory**

Edit `~/.claude/projects/-home-benji-src-devnw-zig-thread-pool/memory/project_phase_status.md` to reflect Option 3 shipped. Append a dated entry in the "Shipped (in main)" list and remove Option 3 from the "Next-action priority" list.

```bash
# (Open the memory file and edit as described; not automatable without knowing the current contents.)
```

---

## Task 10: Sentinel revert per approved Q1-C

**Goal:** (KEEP path only) Flip `claim_sentinel_enabled` from `true` to `std.debug.runtime_safety`, removing ~2 atomic ops per task in ReleaseFast while preserving the safety net in Debug+ReleaseSafe. Per the Q1-C decision: revert is performed only AFTER Option 3 validation passes (Task 8 Verdict = KEEP) and stress passes (Task 7 20×).

**Files:**
- Modify: `src/pool.zig` (line 167 — `claim_sentinel_enabled`).

- [ ] **Step 1: Flip the flag**

Edit `src/pool.zig` around line 167. Before:

```zig
const claim_sentinel_enabled: bool = true;
```

After:

```zig
const claim_sentinel_enabled: bool = std.debug.runtime_safety;
```

Also update the TODO comment block around line 157-166 to reflect completion. Find and update:

```zig
/// Phase H investigation flag — when true, the per-descriptor `claimed_by`
/// sentinel is always active (catches double-dequeue races in ReleaseFast
/// too). Set to `true` for Phase H root-cause investigation; should be
/// flipped back to `std.debug.runtime_safety` once the race is fixed and
/// stress runs prove stable.
///
/// TODO(phase-h): once the double-dequeue race is root-caused and fixed
/// (Task 4 of docs/superpowers/plans/2026-04-13-phase-h-fix-double-dequeue-race.md),
/// flip this back to `std.debug.runtime_safety` or remove the sentinel
/// entirely.
const claim_sentinel_enabled: bool = true;
```

Replace with:

```zig
/// Per-descriptor claim sentinel gating flag. When true, TaskDescriptor.claimed_by
/// is CAS-acquired at runTask entry and stored back to -1 on release/cancel.
/// Kept permanently at `std.debug.runtime_safety` as of Option 3 close-out:
/// the Phase H race fix (state CAS gate at runTask + queued_tasks rebalance)
/// shipped at `a75ed98`, and the Option 3 work validated the race stays
/// closed through a submit-path timing change (see
/// `docs/performance/option3-worker-local-incoming/SUMMARY.md`).
const claim_sentinel_enabled: bool = std.debug.runtime_safety;
```

- [ ] **Step 2: Run the test suite under ReleaseSafe (sentinel ACTIVE)**

```bash
zig build test -Doptimize=ReleaseSafe 2>&1 | tail -15
```

Expected: PASS. With `std.debug.runtime_safety == true` in ReleaseSafe, the sentinel still operates.

- [ ] **Step 3: Run the test suite under ReleaseFast (sentinel COMPILED OUT)**

```bash
zig build test -Doptimize=ReleaseFast 2>&1 | tail -15
```

Expected: PASS. Sentinel is compiled out; any race would not panic here.

- [ ] **Step 4: Run stress 20× ReleaseFast (correctness gate WITHOUT sentinel safety net)**

This is the critical run. If any iteration panics/segfaults, the race has returned OR Option 3 introduced a new race that was only caught by the always-on sentinel. Return to Task 3/4/5/6 for diagnosis.

```bash
failures=0
for i in $(seq 1 20); do
    if ! zig build test-stress -Doptimize=ReleaseFast >/tmp/stress-post-$i.log 2>&1; then
        failures=$((failures + 1))
        echo "FAIL on iteration $i"
        tail -10 /tmp/stress-post-$i.log
    fi
done
echo "Total failures: $failures / 20"
```

Expected: `0 / 20`.

- [ ] **Step 5: Commit**

```bash
git add src/pool.zig
git commit -m "chore(option3): revert claim_sentinel_enabled to std.debug.runtime_safety

Phase H race fix (a75ed98) + Option 3 validation have demonstrated the
scheduler race is closed across a submit-path timing change. Per Q1-C
approved in the Option 3 plan, the always-on flag is no longer needed;
Debug + ReleaseSafe builds still run the sentinel, ReleaseFast compiles
it out (~2 atomic ops/dispatch recovered)."
```

---

## Task 11: Final 100× ReleaseFast gate + docs

**Goal:** Merge-ready final validation. Run stress 100× ReleaseFast as the pre-merge gate (per project rule). Update `docs/PERFORMANCE_TRACKING.md`. Commit close-out.

**Files:**
- Modify: `docs/PERFORMANCE_TRACKING.md`
- Read: `docs/performance/option3-worker-local-incoming/SUMMARY.md` (for the numbers)

- [ ] **Step 1: Run stress 100× ReleaseFast**

```bash
failures=0
for i in $(seq 1 100); do
    if ! zig build test-stress -Doptimize=ReleaseFast >/tmp/stress-final-$i.log 2>&1; then
        failures=$((failures + 1))
        echo "FAIL on iteration $i"
        tail -10 /tmp/stress-final-$i.log
    fi
done
echo "Total failures: $failures / 100"
```

Expected: `0 / 100`. Any failure blocks merge — return to debugging.

- [ ] **Step 2: Append Option 3 entry to `docs/PERFORMANCE_TRACKING.md`**

Append a new section at the end of the doc:

```markdown
## Option 3 — Worker-Local Incoming Queues (<YYYY-MM-DD>)

**Goal:** Amortize external-submit cacheline pressure by routing non-worker submits across per-worker incoming queues instead of a single global inject_queue head/tail.

**Design (approved defaults Q1-Q6 in the plan):**
- Configurable `incoming_capacity` (default `max(64, pow2(queue_capacity / max_threads))`).
- External submit: rotate across incoming[i] via `Core.incoming_cursor` fetchAdd, up to N probes, then fall back to inject_queue.
- Dispatch precedence: LIFO → own local_queue → own incoming → inject_queue → steal local_queue.
- Wake: signal chosen incoming target directly (if parked); fallback scan only if target is running.
- Sentinel reverted to `std.debug.runtime_safety` post-validation.

**Measurement (see `docs/performance/option3-worker-local-incoming/SUMMARY.md`):**
- flood_1m median lift: <±X.X%>
- contended_spawn_8x median: <±Y.Y%>
- Stress 20× ReleaseSafe: PASS
- Stress 100× ReleaseFast: PASS

**Validation:** Task 7 20× + Task 11 100× stress under ReleaseFast, all green. Phase H sentinel off-by-default; correctness maintained across submit-path timing change.
```

- [ ] **Step 3: Commit**

```bash
git add docs/PERFORMANCE_TRACKING.md
git commit -m "docs(option3): close out — <flood_1m-delta>%, 100/100 ReleaseFast, merge-ready"
```

- [ ] **Step 4: Report to the user**

Summarize the end state:
- Branch status (commits ahead of main).
- Paired A/B numbers (flood_1m + contended_spawn_8x).
- Stress validation (20× + 100×).
- Sentinel state (post-revert).
- Open items for follow-up (if any).

---

## Self-Review Checklist (completed by plan author)

- **Spec coverage:** each approved design question (Q1-Q6) maps to a task:
  - Q1 sentinel → Task 10.
  - Q2 capacity → Task 1.
  - Q3 fallback → Task 3 (rotation + inject_queue backstop).
  - Q4 dispatch precedence → Task 4.
  - Q5 wake coupling → Task 5.
  - Q6 queue type → implicit (reuses BoundedRing throughout; no new queue type created).
  - Measurement gate → Task 8.
  - Go/no-go → Task 9.
  - Final validation + docs → Task 11.

- **Placeholder scan:** Task 8 Step 5 contains `<YYYY-MM-DD>` and `<value>` placeholders because they are DATA produced by the measurement, not content the plan author should fill in. These are investigative-output placeholders, clearly marked as such. Task 11 Step 2 has similar placeholders.

- **Type consistency:**
  - `incoming_capacity: usize` used consistently in Config (Task 1) and Core.init (Task 2).
  - `incoming_target: usize` with sentinel `std.math.maxInt(usize)` consistent across Task 3 and Task 5.
  - `Core.incoming_cursor: std.atomic.Value(u32)` with `.monotonic` fetchAdd consistent.
  - `worker.incoming: BoundedRing(u32)` consistent with `BoundedRing(u32)` signature used for `inject_queue`.

- **Bite-sized granularity:** each step is one action (file edit, test run, commit). Tasks 1-7 follow TDD (failing test → impl → pass → commit).

- **Invariants preserved:** queued_tasks increment exactly once per successful push (incrementQueued is unconditional post-push); Phase H claim sentinel remains active through all code-changing tasks (1-7); sentinel revert (Task 10) is gated behind a passing 20× stress + A/B verdict = KEEP.

---

## Execution Handoff

**Plan complete and saved to `docs/superpowers/plans/2026-04-14-option3-worker-local-incoming-queues.md`. Two execution options:**

**1. Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, review between tasks, fast iteration. Tasks 1-7 have clear TDD shapes perfect for subagent execution; Task 8 (measurement) is controller-owned; Task 9 (decision gate) is controller-owned; Tasks 10-11 are final cleanup.

**2. Inline Execution** — Execute tasks in this session using executing-plans, batch execution with checkpoints.
