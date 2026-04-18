# Lock-Free Backpressure Wait Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eliminate the backpressure `Condition` from the descriptor-release hot path so submitters never block on a mutex/futex and `releaseDescriptor` never enters a signaling path. Close the ~66% gap on `bench_tokio_parity/flood_1m` (340K → ≥ 600K ops/s) without reintroducing the `test-stress` hang that caused the Phase C coalesced-wake revert (commit `a77003d`).

**Architecture:** Replace the shared `backpressure_mutex` + `backpressure_cond` + `backpressure_waiters` triple with a **spin-backoff wait loop** inside `waitForCapacity`. The release hot path (`releaseDescriptor`) no longer touches any submitter-side synchronization primitive — it only returns the descriptor to the free list (already lock-free via CAS) and wakes parked *workers* (unchanged). Blocked submitters poll `enqueueTask` on an exponential backoff (spin → `Thread.yield` → `Thread.sleep` with capped backoff) until they either succeed, hit their `block_with_timeout` deadline, or observe pool shutdown. Because there is no wakeup channel, there is no lost-wakeup bug class; the 1 µs–1 ms backoff steps bound CPU cost and latency.

**Why this over re-attempted coalescing:**
- The Phase C coalesced-wake revert left the root cause of the `test-stress` intermittent hang unresolved. Re-landing any variant of the condvar-based design risks re-triggering it.
- The flood_1m bottleneck is ~1M `backpressure_mutex.lock/unlock + signal` round trips per 1M tasks (one per `releaseDescriptor`). Removing the primitive entirely eliminates 100% of that cost, not just a fraction.
- Spin-backoff is the pattern Tokio uses for its unbounded channel fast-path and for its `semaphore::batch_semaphore::Waiter` futex-free path. It's well-trodden.
- Correctness is provable by absence: no signal means no lost-signal race.

**Tech Stack:** Zig 0.15.2, `std.atomic.Value`, `std.Thread.yield`, `std.Thread.sleep`, existing `benchmarks/common.zig` + `bench_tokio_parity` harness.

**Performance Targets (success criteria):**

| Metric | Current (post-revert main) | Target | Rationale |
|---|---|---|---|
| `bench_tokio_parity/flood_1m` ops/s | 340K | ≥ 600K | ≥ 80% improvement; path is the bottleneck |
| `bench_tokio_parity/contended_spawn_8x` ops/s | 534K | ≥ 700K | Multi-submitter contention benefits from no shared mutex |
| `releaseDescriptor` mutex acquisitions / 1M tasks (q=4096) | ~1M | 0 | Primitive removed |
| Submit p50 (no-contention, 1 worker) | 917 ns | ≤ 1000 ns | No regression |
| Submit p99 (4 producers) | 12.8 µs | ≤ 12.8 µs | No regression; spin-backoff only active when queue full |
| `test-stress` 10-run pass rate | 10/10 after revert | 10/10 | Same or better |
| `coalesced wake: submitter never stalls forever` stress test wall time | N/A (passes) | ≤ 3 s | Spin-backoff must unblock quickly |

---

## File Structure

**New files:** none.

**Modified files:**
- `src/pool.zig` — remove `Sync.backpressure_mutex`, `Sync.backpressure_cond`, `Sync.backpressure_waiters`. Rewrite `waitForCapacity` as a spin-backoff loop that re-calls `enqueueTask`. Rewrite the one `shutdown` caller that reused `waitForCapacity` to spin-backoff on its own two counters (`queued_tasks == 0 && active_tasks == 0`). Delete the `backpressure_cond.broadcast()` calls in `joinAllWorkers`. Remove the `if (backpressure_waiters > 0)` fast-path block in `releaseDescriptor`.
- `src/types.zig` — mark `Config.wake_coalesce_batch` deprecated; keep the field but make it inert (no behavior) so we don't break existing callers. Add a doc comment explaining the deprecation.
- `tests/stress.zig` — update `"coalesced wake: submitter never stalls forever on backpressure"` test to use the new path. Rename to `"backpressure backoff: submitter never stalls forever"`. Keep the invariant.
- `tests/unit.zig` — add a unit test that exercises the spin-backoff deadline path (backpressure timeout returns `error.Timeout`).
- `docs/PERFORMANCE_TRACKING.md` — add Phase D section with new numbers and verdict.
- `benchmarks/results/baseline.json` — rebaseline after the change lands.

**Responsibility split:**
- `src/pool.zig` owns the spin-backoff parameters (constants at file top). Keep them private. No new public API surface.
- `src/types.zig` stays free of concurrency primitives — it's just config types.
- Tests cover (a) happy-path submit under pressure, (b) deadline expiration, (c) shutdown during blocked submit, (d) 4-submitter stress with small queue (the scenario that hung on the reverted coalesced-wake commit).

---

## Phase 1: Remove Backpressure Condvar From Release Hot Path

**Rationale:** Every release today takes `backpressure_waiters.load(.monotonic)` + (if >0) `mutex.lock + cond.signal + mutex.unlock`. Removing this is a necessary precondition for the spin-backoff side to work, because we need `releaseDescriptor` to be a pure CAS-based free-list push with no submitter-visible side effects.

### Task 1: Add a failing stress test that exercises the 4-submitter small-queue scenario

**Files:**
- Modify: `tests/stress.zig` (add new test at end of file)

- [ ] **Step 1: Write the failing test**

Append this test to `tests/stress.zig`:

```zig
test "backpressure backoff: 4 submitters, queue=256, 2 workers, deadline-bounded" {
    // Repro scenario matching the previous coalesced-wake stress test that
    // hung intermittently. With the lock-free backoff design, this MUST
    // complete in well under the 30s test timeout. The 5s per-submit deadline
    // is the functional bound we verify.
    var pool = try thread_pool.ThreadPool.init(std.testing.allocator, .{
        .min_threads = 2,
        .max_threads = 2,
        .queue_capacity = 256,
        .local_queue_capacity = 64,
        .scheduler_variant = .work_stealing,
    });
    defer pool.deinit();

    var counter = common.Counter{};
    const total_per_submitter: u64 = 5_000;
    const n_submitters: u32 = 4;
    const total = total_per_submitter * n_submitters;

    const Submitter = struct {
        fn run(p: *thread_pool.ThreadPool, c: *common.Counter, n: u64) void {
            var i: u64 = 0;
            while (i < n) : (i += 1) {
                _ = p.submit(common.counterTask, @ptrCast(c), .{
                    .backpressure = .block_with_timeout,
                    .timeout_ns = 5 * std.time.ns_per_s,
                }) catch break;
            }
        }
    };

    const start_ns = std.time.nanoTimestamp();
    var threads: [n_submitters]std.Thread = undefined;
    for (&threads) |*t| {
        t.* = try std.Thread.spawn(.{}, Submitter.run, .{ &pool, &counter, total_per_submitter });
    }
    for (&threads) |*t| t.join();
    try pool.shutdown(.drain, null);
    const elapsed_ns = std.time.nanoTimestamp() - start_ns;

    try std.testing.expectEqual(total, counter.value.load(.acquire));
    // Sanity: must complete in under 10s. Hang detection.
    try std.testing.expect(elapsed_ns < 10 * std.time.ns_per_s);
}
```

- [ ] **Step 2: Run test to verify current behavior**

Run: `zig build test-stress -- --test-filter "backpressure backoff"`
Expected: PASS (current condvar path works correctly for this workload; the test is primarily a regression guard that MUST continue passing after the refactor in Phase 2).

Note: this test is a *regression guard*, not a red-bar failing test — the current condvar implementation is functionally correct for this scenario. The goal is to ensure the rewritten spin-backoff implementation preserves that correctness.

- [ ] **Step 3: Commit**

```bash
git add tests/stress.zig
git commit -m "test(stress): regression guard for 4-submitter small-queue backpressure"
```

### Task 2: Rewrite `waitForCapacity` as a spin-backoff loop

**Files:**
- Modify: `src/pool.zig` (`waitForCapacity`, lines 413-431)
- Modify: `src/pool.zig` (`submitInternal`, lines 512-531 — the loop changes shape)

- [ ] **Step 1: Add backoff constants to `src/pool.zig`**

Near the top of the file (after imports, before `const tls_worker_index`), add:

```zig
// Backpressure spin-backoff parameters. Blocked submitters (backpressure=block)
// poll enqueueTask with exponential sleep backoff rather than a condvar wait.
// The release path is lock-free, so there is no wake-signal to miss.
// Rationale: flood_1m at q=4096 blocks the submitter ~244 times per 1M tasks.
// With condvar: ~1M mutex+futex round-trips total. With this design: 0.
const BACKPRESSURE_SPIN_ITERS: u32 = 64;          // pause-loop iterations before yielding
const BACKPRESSURE_SLEEP_START_NS: u64 = 1_000;   // 1 µs first sleep
const BACKPRESSURE_SLEEP_MAX_NS: u64 = 1_000_000; // 1 ms cap
const BACKPRESSURE_SLEEP_MULT: u64 = 2;           // doubling backoff
```

- [ ] **Step 2: Replace the body of `waitForCapacity`**

Replace the entire current body of `waitForCapacity` (lines 416-431) with a spin-backoff implementation that does not touch any mutex:

```zig
/// Wait for descriptor/queue capacity to free up, bounded by `deadline`
/// (absolute nanoseconds; 0 = no deadline). Uses spin → yield → exponential
/// sleep backoff; the release path is lock-free, so there is no wakeup
/// channel to miss. The caller (`submitInternal`) will retry `enqueueTask`
/// after this returns — this function only provides the wait between retries.
fn waitForCapacity(self: *Core, deadline: u64) void {
    // Phase 1: short spin. Under flood, a releaseDescriptor likely fires
    // within tens of ns of our queue-full observation, so a few pause
    // iterations often suffice.
    var i: u32 = 0;
    while (i < BACKPRESSURE_SPIN_ITERS) : (i += 1) {
        std.atomic.spinLoopHint();
        if (self.state.load(.monotonic) != .running) return;
    }

    // Phase 2: cooperative yield. Give other threads (workers, other
    // submitters) a chance to run on this core.
    std.Thread.yield() catch {};
    if (self.state.load(.monotonic) != .running) return;

    // Phase 3: exponential sleep backoff. 1 µs → 2 µs → … → 1 ms cap.
    var sleep_ns: u64 = BACKPRESSURE_SLEEP_START_NS;
    while (true) {
        if (self.state.load(.monotonic) != .running) return;
        if (deadline != 0) {
            const now = nowNs();
            if (now >= deadline) return;
            const remaining = deadline - now;
            if (remaining < sleep_ns) {
                // Final sleep clipped to the deadline so we return promptly.
                std.Thread.sleep(remaining);
                return;
            }
        }
        std.Thread.sleep(sleep_ns);
        // One iteration per call. Caller loop will re-invoke us if still blocked,
        // re-entering at Phase 1 each time. This caps per-submit tail latency
        // at `sleep_ns` before the caller re-checks `enqueueTask`.
        return;
    }
}
```

**Notes on design choice:**
- Each call to `waitForCapacity` returns quickly (after one sleep, or sooner if shutdown/deadline). The caller loop in `submitInternal` re-invokes `enqueueTask` then calls us again. This is intentional: we don't want to stay in a long sleep without re-checking capacity.
- The per-submitter backoff state (growing `sleep_ns`) is NOT persisted across calls — each call restarts at 1 µs. That's acceptable because under genuine pressure the queue fills quickly so the first sleep is likely too long anyway; if pressure is light, restarting gives faster recovery.
- A future refinement can track per-submitter backoff state via a stack variable in `submitInternal`. Leave that out of v1.

- [ ] **Step 3: Verify `submitInternal` loop still calls `waitForCapacity` correctly**

Open `src/pool.zig` around lines 512-531. Confirm the loop body (unchanged):

```zig
while (true) {
    if (self.state.load(.acquire) != .running) return error.ShutdownInProgress;
    if (self.enqueueTask(task_fn, ctx, options)) |handle| {
        return handle;
    } else |err| switch (err) {
        error.QueueFull, error.TaskPoolExhausted => {
            if (!allow_block or options.backpressure == .return_error) return err;
            if (deadline != 0 and nowNs() >= deadline) return error.Timeout;
            self.waitForCapacity(deadline);
        },
        else => return err,
    }
}
```

No changes needed here — the loop structure already matches our new contract.

- [ ] **Step 4: Build**

Run: `zig build -Doptimize=Debug`
Expected: SUCCESS. If it fails on `self.sync.backpressure_*` references (those still exist — we remove them in Task 3), temporarily leave those fields in `Sync` and proceed.

- [ ] **Step 5: Run the regression test from Task 1**

Run: `zig build test-stress -- --test-filter "backpressure backoff"`
Expected: PASS, wall time < 1 s.

- [ ] **Step 6: Commit**

```bash
git add src/pool.zig
git commit -m "perf(pool): replace backpressure condvar with spin-backoff wait"
```

### Task 3: Strip dead `backpressure_mutex`/`backpressure_cond`/`backpressure_waiters` state

**Files:**
- Modify: `src/pool.zig` (`Sync` struct, lines 183-193; `joinAllWorkers`, lines 387-402; `releaseDescriptor`, lines 924-931)

- [ ] **Step 1: Remove the three backpressure fields from `Sync`**

In `src/pool.zig`, locate the `Sync` struct (around line 183). Delete lines 183-193 entirely (the block comment, `backpressure_mutex`, `backpressure_cond`, `backpressure_waiters`). Do NOT remove `completion_mutex` / `completion_cond` — those are used for `wait(handle)` and are unrelated.

Final `Sync` struct should contain only `completion_mutex`, `completion_cond`, and nothing else — verify by reading the struct after the delete.

- [ ] **Step 2: Remove the `backpressure_cond.broadcast()` block from `joinAllWorkers`**

Locate `joinAllWorkers` (around line 387). Delete lines 396-401 (the comment plus the `backpressure_mutex.lock / cond.broadcast / unlock` block). The `state.store(.stopping)` + per-worker `park_cond.broadcast()` remains — that's what wakes workers. Blocked submitters observe `state != .running` via the `waitForCapacity` Phase 1 spin check added in Task 2.

- [ ] **Step 3: Remove the `if (backpressure_waiters > 0)` block from `releaseDescriptor`**

Locate `releaseDescriptor` (around line 901). Delete lines 924-931 (the comment + the `if (self.sync.backpressure_waiters.load(...) > 0) { mutex.lock(); cond.signal(); mutex.unlock(); }` block). After this change, `releaseDescriptor` ends after the CAS-push loop — it has no submitter-side effect.

- [ ] **Step 4: Find and fix the `shutdown` call that reused `waitForCapacity`**

Locate `shutdown` (around line 357). Around line 371-382 it has:

```zig
while (true) {
    const queued = self.counters.queued_tasks.load(.acquire);
    const active = self.counters.active_tasks.load(.acquire);
    if (queued == 0 and active == 0) break;
    if (deadline != 0 and nowNs() >= deadline) return error.Timeout;
    self.waitForCapacity(deadline);
}
```

This still works correctly with the new `waitForCapacity` (it's just a backoff sleep). No changes needed. Verify the code reads as above after Task 2 edits — the comment about "condvar which releaseDescriptor signals on every completion" is now stale; update it:

```zig
while (true) {
    const queued = self.counters.queued_tasks.load(.acquire);
    const active = self.counters.active_tasks.load(.acquire);
    if (queued == 0 and active == 0) break;
    if (deadline != 0 and nowNs() >= deadline) return error.Timeout;
    // Backoff sleep; workers drain the queue in the background.
    self.waitForCapacity(deadline);
}
```

- [ ] **Step 5: Build**

Run: `zig build -Doptimize=Debug 2>&1 | head -50`
Expected: SUCCESS with zero references to `backpressure_mutex`, `backpressure_cond`, or `backpressure_waiters`.

If the build fails with "no field named 'backpressure_*'" in a file outside `src/pool.zig`, grep for the symbol and remove those references too:

```
Grep pattern: "backpressure_(mutex|cond|waiters)" in src/**
```

Expected result: 0 matches after cleanup.

- [ ] **Step 6: Run full test suite**

Run: `zig build test`
Expected: All tests pass.

- [ ] **Step 7: Run stress tests 5 times in a row**

Run (repeat 5 times):
```bash
for i in 1 2 3 4 5; do echo "=== run $i ==="; zig build test-stress || break; done
```
Expected: 5/5 pass. This is the smoke test for the Phase C hang — if any iteration hangs or fails, STOP and diagnose before proceeding.

- [ ] **Step 8: Commit**

```bash
git add src/pool.zig
git commit -m "refactor(pool): remove dead backpressure condvar state"
```

### Task 4: Mark `Config.wake_coalesce_batch` as deprecated and inert

**Files:**
- Modify: `src/types.zig` (lines 72-77, 122)

- [ ] **Step 1: Update the doc comment on `wake_coalesce_batch`**

Replace the existing doc comment on the `wake_coalesce_batch` field (lines 72-77) with:

```zig
/// DEPRECATED (2026-04-12): no longer has any effect. The backpressure
/// wait path is now lock-free (spin-backoff in `waitForCapacity`) and
/// performs zero signal operations on the release hot path, so there is
/// nothing to coalesce. Field retained to preserve API compatibility for
/// existing callers. Will be removed in a future major release.
wake_coalesce_batch: u32 = 32,
```

- [ ] **Step 2: Keep the `normalized()` clamp**

Line 122's `if (cfg.wake_coalesce_batch > 1024) cfg.wake_coalesce_batch = 1024;` stays as-is — it's harmless and preserves any existing user-visible validation.

- [ ] **Step 3: Verify no production code reads `wake_coalesce_batch`**

Run:
```
Grep pattern: "wake_coalesce_batch" in src/**
```
Expected: only the two hits in `src/types.zig` (field definition + clamp). Any hit in `src/pool.zig` is a leftover from the Phase C revert and must be deleted.

Run:
```
Grep pattern: "wake_coalesce_batch" in tests/**
```
Expected: one hit in `tests/stress.zig` (the Phase C test from before revert still sets the field). It's inert now, but the test should be updated in Task 5 to remove the no-op config.

- [ ] **Step 4: Build and test**

Run: `zig build test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/types.zig
git commit -m "deprecate(types): wake_coalesce_batch now inert under lock-free backpressure"
```

---

## Phase 2: Test Cleanup and New Coverage

### Task 5: Update Phase C stress test to reflect new design

**Files:**
- Modify: `tests/stress.zig` (lines 201-240, the `"coalesced wake: submitter never stalls forever on backpressure"` test)

- [ ] **Step 1: Read the current test**

Open `tests/stress.zig` lines 201-240.

- [ ] **Step 2: Rewrite test name and remove the obsolete `wake_coalesce_batch` config**

Replace the test at lines 201-240 with:

```zig
test "backpressure backoff: submitter never stalls forever on backpressure" {
    // Small queue + 4 submitters + 2 workers: submitters must block
    // frequently. Under lock-free spin-backoff, each blocked submitter
    // returns from waitForCapacity within ≤ 1 ms and retries enqueue.
    var pool = try thread_pool.ThreadPool.init(std.testing.allocator, .{
        .min_threads = 2,
        .max_threads = 2,
        .queue_capacity = 256, // small — force backpressure
        .local_queue_capacity = 64,
        .scheduler_variant = .work_stealing,
    });
    defer pool.deinit();

    var counter = common.Counter{};
    const total_per_submitter: u64 = 5_000;
    const n_submitters: u32 = 4;
    const total = total_per_submitter * n_submitters;

    const Submitter = struct {
        fn run(p: *thread_pool.ThreadPool, c: *common.Counter, n: u64) void {
            var i: u64 = 0;
            while (i < n) : (i += 1) {
                _ = p.submit(common.counterTask, @ptrCast(c), .{
                    .backpressure = .block_with_timeout,
                    .timeout_ns = 5 * std.time.ns_per_s,
                }) catch break;
            }
        }
    };

    var threads: [n_submitters]std.Thread = undefined;
    for (&threads) |*t| {
        t.* = try std.Thread.spawn(.{}, Submitter.run, .{ &pool, &counter, total_per_submitter });
    }
    for (&threads) |*t| t.join();
    try pool.shutdown(.drain, null);

    try std.testing.expectEqual(total, counter.value.load(.acquire));
}
```

The only change versus Phase C is removing the `.wake_coalesce_batch = 32` line and renaming the test. This is now duplicative with the Task 1 regression guard; delete the Task 1 test (`"backpressure backoff: 4 submitters, queue=256, 2 workers, deadline-bounded"`) to avoid two near-identical tests, keeping this one (which has the preferred name and matches the Phase C test's intent).

- [ ] **Step 3: Run the test**

Run: `zig build test-stress -- --test-filter "backpressure backoff"`
Expected: PASS, < 1 s wall time.

- [ ] **Step 4: Commit**

```bash
git add tests/stress.zig
git commit -m "test(stress): update backpressure test for lock-free design"
```

### Task 6: Add unit test for deadline expiration in the backoff path

**Files:**
- Modify: `tests/unit.zig` (append new test)

- [ ] **Step 1: Write the failing test**

Append to `tests/unit.zig`:

```zig
test "backpressure deadline: returns error.Timeout when queue stays full" {
    // Queue=2, no workers will process — submit 2 tasks that block forever,
    // then attempt a 3rd submit with a tight deadline. Must return Timeout,
    // not hang.
    var pool = try thread_pool.ThreadPool.init(std.testing.allocator, .{
        .min_threads = 1,
        .max_threads = 1,
        .queue_capacity = 2,
        .local_queue_capacity = 2,
    });
    defer pool.deinit();

    var block_sem = std.Thread.Semaphore{};

    const BlockCtx = struct {
        sem: *std.Thread.Semaphore,
        fn run(raw: *anyopaque, rt: *thread_pool.TaskContext) void {
            _ = rt;
            const ctx: *@This() = @ptrCast(@alignCast(raw));
            ctx.sem.wait();
        }
    };
    var bctx = BlockCtx{ .sem = &block_sem };

    // Fill the queue with blocking tasks.
    _ = try pool.submit(BlockCtx.run, @ptrCast(&bctx), .{});
    _ = try pool.submit(BlockCtx.run, @ptrCast(&bctx), .{});
    // Third submit must time out within ~20 ms.
    const start = std.time.nanoTimestamp();
    const result = pool.submit(BlockCtx.run, @ptrCast(&bctx), .{
        .backpressure = .block_with_timeout,
        .timeout_ns = 10 * std.time.ns_per_ms,
    });
    const elapsed = std.time.nanoTimestamp() - start;
    try std.testing.expectError(error.Timeout, result);
    try std.testing.expect(elapsed >= 10 * std.time.ns_per_ms);
    try std.testing.expect(elapsed < 100 * std.time.ns_per_ms); // hang guard

    // Release the blocked tasks so shutdown drains cleanly.
    block_sem.post();
    block_sem.post();
}
```

- [ ] **Step 2: Run the test**

Run: `zig build test-unit -- --test-filter "backpressure deadline"`
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add tests/unit.zig
git commit -m "test(unit): backpressure deadline returns Timeout, not hang"
```

---

## Phase 3: Measure, Rebaseline, Document

### Task 7: Measure `flood_1m` and `contended_spawn_8x` (median of 5 runs)

**Files:** none modified in this task (measurement only).

- [ ] **Step 1: Build ReleaseFast**

Run: `zig build -Doptimize=ReleaseFast`
Expected: SUCCESS.

- [ ] **Step 2: Run `bench-tokio-parity` 5 times, record ops/s**

Run (repeat 5 times, record result each time):
```bash
zig build bench-tokio-parity -Doptimize=ReleaseFast
```

For each run, capture the `flood_1m` ops/s and `contended_spawn_8x` ops/s from stdout. Record the 5 values for each in a scratch file.

- [ ] **Step 3: Compute median**

Sort each list of 5, take the middle value. Acceptance:
- `flood_1m` median ≥ 600K ops/s. If < 600K, STOP and diagnose with `perf` / `strace -c` before claiming the change works. Expected sources of residual cost: descriptor-pool CAS contention under very high multi-submitter pressure (Task 8 follow-up), or worker wake path latency.
- `contended_spawn_8x` median ≥ 700K ops/s.

- [ ] **Step 4: Run standard bench to confirm no regressions elsewhere**

Run: `zig build bench -Doptimize=ReleaseFast` (7-run harness, already in place from Phase C).
Expected: No scenario regresses beyond its stddev gate.

- [ ] **Step 5: Run the submit_latency micro**

Run: `zig build bench-micro -Dbench=submit_latency -Doptimize=ReleaseFast` and capture p50/p95/p99.
Acceptance:
- p50 ≤ 1000 ns (no regression vs 917 ns current).
- p99 ≤ 1700 ns (no regression vs 1690 ns Phase A).

- [ ] **Step 6: Rebaseline**

If all acceptance criteria pass:

Run: `zig build bench-rebaseline -Doptimize=ReleaseFast`
This writes `benchmarks/results/baseline.json`.

- [ ] **Step 7: Commit baseline**

```bash
git add benchmarks/results/baseline.json
git commit -m "bench: rebaseline after lock-free backpressure"
```

### Task 8: Update `PERFORMANCE_TRACKING.md` with Phase D section

**Files:**
- Modify: `docs/PERFORMANCE_TRACKING.md` (append new Phase D section after the existing Phase C section, before "## Bench Stability")

- [ ] **Step 1: Append Phase D section**

Insert after the Phase C block (after line 131, before `## Bench Stability`):

````markdown
## Phase D: Lock-Free Backpressure

**Shipped:**

1. **Removed `backpressure_mutex` / `backpressure_cond` / `backpressure_waiters`** from `src/pool.zig`. The release hot path now has zero submitter-side signaling — it's a pure CAS push onto the descriptor free list.
2. **Spin-backoff `waitForCapacity`:** blocked submitters spin (64 pause iters) → `Thread.yield` → exponential `Thread.sleep` (1 µs doubling to 1 ms cap), re-checking pool state each step. No wakeup channel means no lost-wakeup bug class.
3. **`Config.wake_coalesce_batch` marked deprecated/inert.** Kept for API compat; field has no effect.

**Root-cause note on Phase C revert:** The Phase C coalesced-wake commit (`949cf74`, reverted in `a77003d`) hung `test-stress` intermittently. This plan sidesteps the issue entirely by eliminating the condvar rather than refining its coalescing. The 4-submitter/q=256 scenario is now covered by an explicit regression test in `tests/stress.zig`.

### Phase D measurements (git SHA TBD, median of 5 runs ReleaseFast)

| Metric | Phase C | Phase D | Delta | Target | Met? |
|---|---:|---:|---:|---:|---:|
| Tokio flood_1m | 340K | TBD | TBD | ≥ 600K | TBD |
| Tokio contended_spawn_8x | 534K | TBD | TBD | ≥ 700K | TBD |
| Submit p50 (1 worker, 100k samples) | 917 ns | TBD | TBD | ≤ 1000 ns | TBD |
| Submit p99 (1 worker, 100k samples) | 1690 ns* | TBD | TBD | ≤ 1700 ns | TBD |
| `conn_churn_seq/global_queue` | 758K | TBD | TBD | within 3×stddev | TBD |
| `conn_churn_seq/work_stealing` | 683K | TBD | TBD | within 3×stddev | TBD |
| `test-stress` 10-run pass rate | 10/10 | TBD | TBD | 10/10 | TBD |

*Phase A number; Phase C didn't re-measure p99.

### Residual gap to Tokio parity

If flood_1m reaches ≥ 600K with this change, the residual gap (600K vs 5–15M) localizes to:
1. **Descriptor-pool free-list CAS contention** — tagged-pointer ABA-safe push/pop scales poorly above ~4 submitters. Next-pass: move to a Treiber-stack-per-worker or Michael-Scott queue for the free list.
2. **Worker wake path** — still a per-worker `park_cond.signal()` under `park_mutex` on every new submit. Amortize via per-pool `notified` atomic + futex (event-based wake).
3. **Allocator cost** — `std.heap.smp_allocator` shows up non-trivially in flood_1m profiles. Next-pass: measure with `page_allocator` + per-worker task arena.

Each of these is a separate plan — keep this one focused on the backpressure primitive.
````

Fill in the TBD cells with the numbers from Task 7 before committing.

- [ ] **Step 2: Update the top-of-file "Verdict vs Targets" table**

Locate the row for `bench_tokio_parity/flood_1m ≥ 1M ops/s` (line 21) and append the Phase D number to the "After plan" cell, e.g.:

```
| `bench_tokio_parity/flood_1m` ≥ 1M ops/s | 297K | 340K (Phase C) / TBD (Phase D) | ⚠️ / ❓ |
```

Same for `contended_spawn_8x` (line 22).

- [ ] **Step 3: Commit**

```bash
git add docs/PERFORMANCE_TRACKING.md
git commit -m "docs(perf): Phase D verdict, rebaseline after lock-free backpressure"
```

---

## Self-Review Checklist

Before declaring the plan complete:

- [ ] All `backpressure_mutex`, `backpressure_cond`, `backpressure_waiters` references removed from production code (`src/**`).
- [ ] `test-stress` passes 5 consecutive runs.
- [ ] `flood_1m` median improves ≥ 80% (340K → ≥ 600K).
- [ ] No submit latency regression (p50 ≤ 1000 ns, p99 ≤ 1700 ns).
- [ ] `shutdown` with a blocked submitter returns within ~2 ms (one sleep cycle).
- [ ] `Config.wake_coalesce_batch` still compiles in callers but has no effect (manual check: set it to 0 and to 1024, behavior identical).
- [ ] Baseline updated and committed.
- [ ] `PERFORMANCE_TRACKING.md` filled in with measured numbers, not TBD.

## Rollback Criteria

If any of these conditions hold after Task 7:
- `flood_1m` median < 450K ops/s (less than 32% improvement — too small to justify the churn),
- any stress test hangs or fails under 5 consecutive runs,
- submit p50 regresses beyond 10% (917 ns → >1010 ns),
- any integration test fails,

then revert Phase 1 + Phase 2 commits (preserve the regression test from Task 1 as a permanent guard) and file a follow-up: the CAS free-list or the worker-wake path is the bottleneck, not the backpressure condvar — a different plan is needed.

## Execution Handoff

**Plan complete and saved to `docs/superpowers/plans/2026-04-12-lock-free-backpressure.md`. Two execution options:**

**1. Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, review between tasks, fast iteration. The stress-test smoke in Task 3 Step 7 is the critical gate — a reviewer should hold there before letting any downstream task merge.

**2. Inline Execution** — Execute tasks in this session using executing-plans, batch execution with checkpoints.

**Which approach?**
