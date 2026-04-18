# Phase F1b: Reserved Hot-Spin Workers Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reserve N workers that never park (`Config.hot_spinners`, default 0 opt-in) so the submitter can skip `futex_wake` on the common path; reserved workers propagate wakes every `Config.wake_every_n_tasks` (default 64) to recruit parked workers when load exceeds single-spinner consumption. Target: `flood_1m` ≥ 450K ops/s with `hot_spinners=1` (A/B-verified ceiling 506K).

**Architecture:** Add two `Config` fields (`hot_spinners`, `wake_every_n_tasks`) with validation. Fork `workerMain` at entry — if `worker_index < hot_spinners`, run a new `hotSpinnerLoop` that never parks and issues consumer-side wakes. Extract the existing wake scan into `wakeOneParkedWorker` (shared by the `enqueueTask` cold path and the hot-spinner's propagation). `enqueueTask` skips the wake unconditionally when `hot_spinners > 0`.

**Tech Stack:** Zig 0.15.2, existing `std.atomic`, `Config.validate` pattern, `workerMain`/`nextTask`/`runTask` primitives. No new dependencies.

**Reference design spec:** `docs/superpowers/specs/2026-04-12-phase-f1b-reserved-hot-spinners-design.md` — all design decisions locked there. This plan is the mechanical execution.

**Performance Targets:**

| Metric | Baseline | hot_spinners=0 | hot_spinners=1 | Stretch |
|---|---:|---:|---:|---:|
| `flood_1m` ops/s | 335K | ≈ 335K | **≥ 450K** | ≥ 500K |
| `contended_spawn_8x` ops/s | 534K | ≈ 534K | — | — |
| Submit p50 (single-worker micro) | 917 ns | ≤ 1000 ns | ≤ 1000 ns | ≤ 950 ns |
| `test-stress` 5× consecutive (hot_spinners=0) | pass | pass | — | — |
| `test-stress` 5× consecutive (hot_spinners=1) | — | — | pass | — |
| Hot-spinner CPU at idle with no work | — | — | 100% (1 core) | — |

**Rollback floor:** `flood_1m` median with `hot_spinners=1` < 400K. Triggers immediate revert.

**Post-impl A/B gate (MANDATORY):** Per Phase F1's methodology lesson — measure `hot_spinners=0` and `hot_spinners=1` on the same build. 0-case must match baseline within noise (same logical path). 1-case must hit ≥ 450K target. If 1-case matches 0-case, mechanic isn't engaging → rollback.

---

## File Structure

**Modified files:**

- `src/types.zig` — add `Config.hot_spinners: u32 = 0`, `Config.wake_every_n_tasks: u32 = 64`, validation (`InvalidHotSpinners`, `InvalidWakeThreshold`), field doc comments.
- `src/pool.zig` — add private `hotSpinnerLoop` method, extract `wakeOneParkedWorker` from current `enqueueTask`, fork in `workerMain`, conditional wake in `enqueueTask`.
- `tests/unit.zig` — validation tests + hot-spinner basic correctness + wake propagation test.
- `tests/stress.zig` — wide-pool flood with `hot_spinners=1`.
- `docs/PERFORMANCE_TRACKING.md` — Phase F1b entry with measurements.
- `benchmarks/results/baseline.json` — rebaseline on success.

**New files:** none.

---

## Task Ordering Rationale

The mechanic spans four integration points: config, worker fork, helper extraction, and submitter conditional. Landing them out of order risks breaking intermediate states. The plan interleaves refactoring (helper extraction, inert) with feature additions (worker fork, activation) so each commit keeps all tests passing with `hot_spinners=0`:

1. Config knobs + validation (pure addition, inert).
2. Extract `wakeOneParkedWorker` from `enqueueTask` (pure refactor, no behavior change).
3. Add `hotSpinnerLoop` + fork in `workerMain` (activated only when `hot_spinners > 0`).
4. `enqueueTask` conditional (activated only when `hot_spinners > 0`).
5. Tests (correctness + wake propagation + wide-pool stress).
6. A/B gate measurement (the critical pre-merge check).
7. Formal measurement + rebaseline (only if A/B gate passes).
8. Documentation.

After each of steps 1–4, `hot_spinners=0` behavior is unchanged; tests pass. After step 4, setting `hot_spinners=1` activates the new mechanic.

---

## Task 1: Add `hot_spinners` and `wake_every_n_tasks` config fields + validation

**Files:**

- Modify: `src/types.zig` (`Config` struct fields + `validate()`)
- Test: `tests/unit.zig` (append)

### Step 1: Write the failing tests

Append to `tests/unit.zig`:

```zig
test "Config validate rejects hot_spinners >= max_threads" {
    const cfg = thread_pool.Config{ .max_threads = 4, .min_threads = 1, .hot_spinners = 4 };
    try std.testing.expectError(error.InvalidHotSpinners, cfg.validate());
}

test "Config validate accepts hot_spinners < max_threads" {
    const cfg = thread_pool.Config{ .max_threads = 4, .min_threads = 1, .hot_spinners = 1 };
    try cfg.validate();
}

test "Config validate rejects hot_spinners > 0 with wake_every_n_tasks == 0" {
    const cfg = thread_pool.Config{
        .max_threads = 4,
        .min_threads = 1,
        .hot_spinners = 1,
        .wake_every_n_tasks = 0,
    };
    try std.testing.expectError(error.InvalidWakeThreshold, cfg.validate());
}

test "Config validate accepts hot_spinners = 0 with wake_every_n_tasks = 0" {
    // When feature is disabled, the threshold is don't-care.
    const cfg = thread_pool.Config{
        .max_threads = 4,
        .min_threads = 1,
        .hot_spinners = 0,
        .wake_every_n_tasks = 0,
    };
    try cfg.validate();
}
```

### Step 2: Run to verify failures

```bash
cd /home/benji/src/devnw/zig/thread-pool-phase-f && zig build test -- --test-filter "hot_spinners"
```

Expected: compile errors — `hot_spinners` and `wake_every_n_tasks` fields don't exist yet.

### Step 3: Add the fields to `Config`

In `src/types.zig`, locate the `Config` struct around line 66-97. Insert these fields after `wake_coalesce_batch` (already present) and before `worker_scratch_cap_bytes`:

```zig
    /// Number of workers reserved as always-spinning hot workers.
    /// These workers never park; they consume 1 core each at 100% CPU
    /// but catch submits without requiring a futex wake. When > 0, the
    /// submitter skips the wake scan entirely — hot-spinners propagate
    /// wakes themselves every `wake_every_n_tasks` tasks executed.
    ///
    /// Default 0 disables the feature (preserves current behavior).
    /// Must be strictly less than `max_threads` — at least one
    /// non-hot worker is required for the parked-worker fallback.
    /// See docs/superpowers/specs/2026-04-12-phase-f1b-reserved-hot-spinners-design.md.
    hot_spinners: u32 = 0,

    /// Hot-spinner wake propagation threshold. After executing this
    /// many tasks, a hot-spinner issues one `futex_wake` to recruit a
    /// parked worker. Amortizes wake cost across many submits while
    /// bounding worst-case wake latency to ~K × per-task duration.
    /// Ignored when `hot_spinners == 0`. Setting this to 0 while
    /// `hot_spinners > 0` is rejected by `validate()` — would starve
    /// parked workers on long-running tasks.
    wake_every_n_tasks: u32 = 64,
```

### Step 4: Add validation rules to `validate()`

In `src/types.zig`, locate `pub fn validate(self: Config) !void` (around line 126). Append these two checks after the existing `inject_batch_size == 0` check and before the closing `}`:

```zig
        if (self.hot_spinners >= self.max_threads) return error.InvalidHotSpinners;
        if (self.hot_spinners > 0 and self.wake_every_n_tasks == 0) return error.InvalidWakeThreshold;
```

The full `validate()` body should now end:

```zig
        if (self.inject_batch_size == 0) return error.InvalidInjectBatchSize;
        if (self.hot_spinners >= self.max_threads) return error.InvalidHotSpinners;
        if (self.hot_spinners > 0 and self.wake_every_n_tasks == 0) return error.InvalidWakeThreshold;
    }
```

### Step 5: Run tests to verify they pass

```bash
cd /home/benji/src/devnw/zig/thread-pool-phase-f && zig build test -- --test-filter "hot_spinners"
```

Expected: 4 new tests PASS.

### Step 6: Run full test suite

```bash
cd /home/benji/src/devnw/zig/thread-pool-phase-f && zig build test
```

Expected: all tests pass (no regression from the new fields — they're defaults, existing configs are unaffected).

### Step 7: Commit

```bash
cd /home/benji/src/devnw/zig/thread-pool-phase-f && git add src/types.zig tests/unit.zig && git commit -m "feat(types): add hot_spinners + wake_every_n_tasks config fields"
```

---

## Task 2: Extract `wakeOneParkedWorker` helper (pure refactor)

**Files:**

- Modify: `src/pool.zig` (`enqueueTask`, lines ~586-603)

Pure refactor: extract the existing wake scan into a private method with no behavior change. Future tasks (3, 4) will call this helper from both the hot-spinner loop and the conditional submitter path.

### Step 1: Locate the current wake scan

In `src/pool.zig`, `enqueueTask` around lines 586-603:

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
            if (w.is_parked.load(.monotonic) == 1) {
                w.park_cond.signal();
            }
            w.park_mutex.unlock();
            break;
        }
    }
```

### Step 2: Add the `wakeOneParkedWorker` method

Add a new private method to `Core` (anywhere after `runTask` is a logical spot — or immediately before `workerMain` at line 615). Insert:

```zig
    /// Wake one parked worker. Scans `workers[*].is_parked` starting at a
    /// round-robin offset so load spreads across the pool. Skips indices
    /// `< self.config.hot_spinners` because reserved workers never park.
    /// The Phase A park-handshake guarantees no lost wakeup: either we
    /// observe `is_parked == 1` and signal, or the worker reloads
    /// queued_tasks and sees our push.
    fn wakeOneParkedWorker(self: *Core) void {
        const submitted = self.counters.submitted.load(.monotonic);
        const hint_idx: usize = @intCast(submitted % self.workers.len);
        var off: usize = 0;
        while (off < self.workers.len) : (off += 1) {
            const idx = (hint_idx + off) % self.workers.len;
            if (idx < self.config.hot_spinners) continue;
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
    }
```

The `if (idx < self.config.hot_spinners) continue;` is the one semantic addition vs the inline original — when `hot_spinners=0` it's always false (idx is usize, so `< 0` is false), so this is a fully branch-predicted no-op for default users.

### Step 3: Replace the inline scan in `enqueueTask` with a call

In `src/pool.zig`, replace the entire block from `// Wake one parked worker.` comment through the closing `}` of the `while (off < self.workers.len)` loop with:

```zig
    // Wake one parked worker via the extracted helper. The Phase A
    // park-handshake (see idle()) guarantees no lost wakeup.
    self.wakeOneParkedWorker();
```

### Step 4: Build

Run: `cd /home/benji/src/devnw/zig/thread-pool-phase-f && zig build`
Expected: SUCCESS.

### Step 5: Run full test suite

Run: `cd /home/benji/src/devnw/zig/thread-pool-phase-f && zig build test`
Expected: all tests pass. Pure refactor — behavior is unchanged for all current configs (hot_spinners defaults to 0).

### Step 6: Run stress tests 3× to confirm no regression

```bash
cd /home/benji/src/devnw/zig/thread-pool-phase-f && for i in 1 2 3; do echo "=== $i ==="; zig build test-stress --summary all || exit 1; done
```

Expected: 3/3 pass with consistent wall times.

### Step 7: Commit

```bash
cd /home/benji/src/devnw/zig/thread-pool-phase-f && git add src/pool.zig && git commit -m "refactor(pool): extract wakeOneParkedWorker from enqueueTask"
```

---

## Task 3: Add `hotSpinnerLoop` + fork in `workerMain`

**Files:**

- Modify: `src/pool.zig` (`workerMain` + new method)

After this task, `hot_spinners > 0` activates the worker-side half of the mechanic (reserved workers never park, propagate wakes). The submitter still always wakes on every submit (`enqueueTask` conditional comes in Task 4). This intermediate state is correct and safe: reserved workers still discover tasks via `nextTask`, and redundant submitter wakes are wasted CPU but not a correctness problem.

### Step 1: Locate `workerMain`

In `src/pool.zig`, `workerMain` around lines 615-629:

```zig
    fn workerMain(self: *Core, worker_index: usize) void {
        tls_worker_index = worker_index;
        defer tls_worker_index = null;

        while (true) {
            if (self.shouldExit()) break;

            const maybe_descriptor = self.nextTask(worker_index);
            if (maybe_descriptor == null) {
                self.idle(worker_index);
                continue;
            }

            self.runTask(worker_index, maybe_descriptor.?);
        }
    }
```

### Step 2: Add fork at entry

Modify `workerMain` to branch on hot-spinner status at the top:

```zig
    fn workerMain(self: *Core, worker_index: usize) void {
        if (worker_index < self.config.hot_spinners) {
            self.hotSpinnerLoop(worker_index);
            return;
        }

        tls_worker_index = worker_index;
        defer tls_worker_index = null;

        while (true) {
            if (self.shouldExit()) break;

            const maybe_descriptor = self.nextTask(worker_index);
            if (maybe_descriptor == null) {
                self.idle(worker_index);
                continue;
            }

            self.runTask(worker_index, maybe_descriptor.?);
        }
    }
```

### Step 3: Add `hotSpinnerLoop`

Add a new private method to `Core` immediately after `workerMain`:

```zig
    /// Loop body for workers with `worker_index < self.config.hot_spinners`.
    /// Never parks — spins between tasks so the submitter can skip futex_wake.
    /// Propagates wakes every `config.wake_every_n_tasks` tasks to recruit
    /// parked workers when submits outpace single-spinner consumption.
    /// See docs/superpowers/specs/2026-04-12-phase-f1b-reserved-hot-spinners-design.md.
    fn hotSpinnerLoop(self: *Core, worker_index: usize) void {
        tls_worker_index = worker_index;
        defer tls_worker_index = null;

        var tasks_since_wake: u32 = 0;
        while (!self.shouldExit()) {
            if (self.nextTask(worker_index)) |descriptor_index| {
                self.runTask(worker_index, descriptor_index);
                tasks_since_wake += 1;
                if (tasks_since_wake >= self.config.wake_every_n_tasks) {
                    tasks_since_wake = 0;
                    self.wakeOneParkedWorker();
                }
            } else {
                std.atomic.spinLoopHint();
            }
        }
    }
```

Properties:
- `tasks_since_wake` is a local variable (thread-local scope of the function call) — no atomic needed.
- `shouldExit()` checked every loop iteration — shutdown latency bounded by one task's duration.
- `nextTask` handles LIFO slot + local queue + inject queue + steal scan (all unchanged).
- Empty-queue path does `spinLoopHint` — low thermal cost.

### Step 4: Build

Run: `cd /home/benji/src/devnw/zig/thread-pool-phase-f && zig build`
Expected: SUCCESS.

### Step 5: Run full test suite

```bash
cd /home/benji/src/devnw/zig/thread-pool-phase-f && zig build test
```

Expected: all tests pass (no test uses `hot_spinners > 0` yet; default 0 takes the non-fork path).

### Step 6: Run stress tests 3× to confirm no regression

```bash
cd /home/benji/src/devnw/zig/thread-pool-phase-f && for i in 1 2 3; do echo "=== $i ==="; zig build test-stress --summary all || exit 1; done
```

Expected: 3/3 pass.

### Step 7: Commit

```bash
cd /home/benji/src/devnw/zig/thread-pool-phase-f && git add src/pool.zig && git commit -m "feat(pool): add hotSpinnerLoop for reserved never-park workers"
```

---

## Task 4: `enqueueTask` conditional skip-wake when `hot_spinners > 0`

**Files:**

- Modify: `src/pool.zig` (`enqueueTask`, the `wakeOneParkedWorker` call site)

### Step 1: Locate the `wakeOneParkedWorker` call in `enqueueTask`

After Task 2, the call site in `enqueueTask` looks like:

```zig
    _ = self.counters.submitted.fetchAdd(1, .monotonic);
    self.incrementQueued();

    // Wake one parked worker via the extracted helper. The Phase A
    // park-handshake (see idle()) guarantees no lost wakeup.
    self.wakeOneParkedWorker();
```

### Step 2: Add the hot-spinner skip

Wrap the call in an `if (self.config.hot_spinners == 0)` guard:

```zig
    _ = self.counters.submitted.fetchAdd(1, .monotonic);
    self.incrementQueued();

    // If any hot-spinners are configured, they're always running and will
    // catch our push via nextTask (inject / local queue). They issue wakes
    // themselves, every wake_every_n_tasks tasks, to recruit parked workers
    // when load exceeds a single spinner's consumption. A/B-verified ceiling:
    // stubbing the wake lifts flood_1m 335K → 506K on this host.
    if (self.config.hot_spinners == 0) {
        // Cold path: no reserved spinners — wake one parked worker.
        // The Phase A park-handshake (see idle()) guarantees no lost wakeup.
        self.wakeOneParkedWorker();
    }
```

### Step 3: Build

Run: `cd /home/benji/src/devnw/zig/thread-pool-phase-f && zig build`
Expected: SUCCESS.

### Step 4: Run full test suite

```bash
cd /home/benji/src/devnw/zig/thread-pool-phase-f && zig build test
```

Expected: PASS. Default `hot_spinners=0` exercises the cold-path branch (unchanged semantics from pre-F1b).

### Step 5: Run stress tests 5× consecutive (correctness gate)

```bash
cd /home/benji/src/devnw/zig/thread-pool-phase-f && for i in 1 2 3 4 5; do echo "=== run $i ==="; zig build test-stress --summary all || exit 1; done
```

Expected: 5/5 pass. Default hot_spinners=0 is unchanged behavior; the skip-wake path isn't exercised by default tests.

### Step 6: Commit

```bash
cd /home/benji/src/devnw/zig/thread-pool-phase-f && git add src/pool.zig && git commit -m "perf(pool): submitter skips wake when hot_spinners > 0"
```

---

## Task 5: Basic hot-spinner correctness test

**Files:**

- Modify: `tests/unit.zig` (append)

### Step 1: Write the test

Append to `tests/unit.zig`:

```zig
test "hot_spinners = 1 executes all submitted tasks" {
    var pool = try thread_pool.ThreadPool.init(std.testing.allocator, .{
        .min_threads = 4,
        .max_threads = 4,
        .queue_capacity = 4096,
        .local_queue_capacity = 256,
        .scheduler_variant = .work_stealing,
        .hot_spinners = 1,
        .wake_every_n_tasks = 8,
    });
    defer pool.deinit();

    var counter = common.Counter{};
    var wg = pool.waitGroup();

    const total: u64 = 10_000;
    var i: u64 = 0;
    while (i < total) : (i += 1) {
        _ = try pool.submit(common.counterTask, @ptrCast(&counter), .{ .wait_group = &wg });
    }
    wg.wait();
    try std.testing.expectEqual(total, counter.value.load(.acquire));
}

test "hot_spinners = 1 executes follow-up task after quiesce" {
    // Regression guard: after the initial burst drains, the hot-spinner
    // must still execute the next submitted task without requiring any
    // external wake.
    var pool = try thread_pool.ThreadPool.init(std.testing.allocator, .{
        .min_threads = 2,
        .max_threads = 2,
        .queue_capacity = 1024,
        .local_queue_capacity = 128,
        .scheduler_variant = .work_stealing,
        .hot_spinners = 1,
        .wake_every_n_tasks = 4,
    });
    defer pool.deinit();

    var counter = common.Counter{};
    var wg = pool.waitGroup();
    var i: u64 = 0;
    while (i < 500) : (i += 1) {
        _ = try pool.submit(common.counterTask, @ptrCast(&counter), .{ .wait_group = &wg });
    }
    wg.wait();
    try std.testing.expectEqual(@as(u64, 500), counter.value.load(.acquire));

    // Brief idle period so the non-hot worker parks.
    std.Thread.sleep(10 * std.time.ns_per_ms);

    // One more task — must execute via the hot-spinner.
    var solo = common.Counter{};
    var solo_wg = pool.waitGroup();
    _ = try pool.submit(common.counterTask, @ptrCast(&solo), .{ .wait_group = &solo_wg });
    solo_wg.wait();
    try std.testing.expectEqual(@as(u64, 1), solo.value.load(.acquire));
}
```

### Step 2: Run the tests

```bash
cd /home/benji/src/devnw/zig/thread-pool-phase-f && zig build test -- --test-filter "hot_spinners"
```

Expected: both tests PASS within ~1s each.

### Step 3: Run full test suite

```bash
cd /home/benji/src/devnw/zig/thread-pool-phase-f && zig build test
```

Expected: all tests pass.

### Step 4: Commit

```bash
cd /home/benji/src/devnw/zig/thread-pool-phase-f && git add tests/unit.zig && git commit -m "test(unit): hot_spinners = 1 basic correctness"
```

---

## Task 6: Wake propagation test (ensures parked workers get recruited)

**Files:**

- Modify: `tests/stress.zig` (append)

### Step 1: Write the test

Append to `tests/stress.zig`:

```zig
test "hot_spinners: slow tasks force parked worker recruitment via propagation" {
    // hot_spinners=1 with slow tasks (100µs each). After the first
    // wake_every_n_tasks=4 tasks complete, the spinner must wake a
    // parked worker. If propagation is broken, all work stays on the
    // single hot-spinner and the test takes ~N × 100µs instead of
    // running in parallel.
    var pool = try thread_pool.ThreadPool.init(std.testing.allocator, .{
        .min_threads = 4,
        .max_threads = 4,
        .queue_capacity = 2048,
        .local_queue_capacity = 128,
        .scheduler_variant = .work_stealing,
        .hot_spinners = 1,
        .wake_every_n_tasks = 4,
        .idle_park_after_ns = 50_000,
    });
    defer pool.deinit();

    const SlowCtx = struct {
        counter: *common.Counter,
        sleep_ns: u64,
        fn run(raw: *anyopaque, rt: *thread_pool.TaskContext) void {
            _ = rt;
            const ctx: *@This() = @ptrCast(@alignCast(raw));
            std.Thread.sleep(ctx.sleep_ns);
            _ = ctx.counter.value.fetchAdd(1, .monotonic);
        }
    };

    var counter = common.Counter{};
    var slow = SlowCtx{ .counter = &counter, .sleep_ns = 100_000 };
    var wg = pool.waitGroup();
    const total: u64 = 80;
    var i: u64 = 0;
    while (i < total) : (i += 1) {
        _ = try pool.submit(SlowCtx.run, @ptrCast(&slow), .{ .wait_group = &wg });
    }
    const start_ns = std.time.nanoTimestamp();
    wg.wait();
    const elapsed_ns = std.time.nanoTimestamp() - start_ns;

    try std.testing.expectEqual(total, counter.value.load(.acquire));

    // Serial execution on 1 hot-spinner: 80 * 100µs = 8ms.
    // With propagation recruiting 3 parked workers: ~80/4 * 100µs ≈ 2ms.
    // Allow generous 6ms ceiling to absorb noise; serial behavior would
    // clearly exceed this.
    try std.testing.expect(elapsed_ns < 6 * std.time.ns_per_ms);
}
```

### Step 2: Run the test

```bash
cd /home/benji/src/devnw/zig/thread-pool-phase-f && zig build test-stress -- --test-filter "hot_spinners: slow tasks"
```

Expected: PASS, elapsed < 6ms.

### Step 3: Run full stress suite

```bash
cd /home/benji/src/devnw/zig/thread-pool-phase-f && zig build test-stress --summary all
```

Expected: `N/N tests passed`.

### Step 4: Commit

```bash
cd /home/benji/src/devnw/zig/thread-pool-phase-f && git add tests/stress.zig && git commit -m "test(stress): hot_spinners wake propagation recruits parked workers"
```

---

## Task 7: Wide-pool flood stress test with `hot_spinners=1`

**Files:**

- Modify: `tests/stress.zig` (append)

### Step 1: Write the test

Append to `tests/stress.zig`:

```zig
test "hot_spinners: wide-pool flood with cpu-count workers, hot_spinners=1" {
    // High-worker-count stress: cpu_count (clamped to 64) workers,
    // 1 reserved hot-spinner, 200k tasks, single submitter.
    // Regression guard for correctness under realistic flood load.
    const cpu_count = @min(std.Thread.getCpuCount() catch 4, 64);
    if (cpu_count < 2) return; // need at least 2 workers for hot_spinners=1 to leave a non-hot worker

    var pool = try thread_pool.ThreadPool.init(std.testing.allocator, .{
        .min_threads = cpu_count,
        .max_threads = cpu_count,
        .queue_capacity = 4096,
        .local_queue_capacity = 256,
        .scheduler_variant = .work_stealing,
        .hot_spinners = 1,
        .wake_every_n_tasks = 64,
    });
    defer pool.deinit();

    var counter = common.Counter{};
    var wg = pool.waitGroup();
    const total: u64 = 200_000;
    var i: u64 = 0;
    while (i < total) : (i += 1) {
        while (true) {
            _ = pool.submit(common.counterTask, @ptrCast(&counter), .{
                .wait_group = &wg,
            }) catch {
                std.Thread.sleep(1_000);
                continue;
            };
            break;
        }
    }
    wg.wait();
    try std.testing.expectEqual(total, counter.value.load(.acquire));
}
```

### Step 2: Run the test

```bash
cd /home/benji/src/devnw/zig/thread-pool-phase-f && zig build test-stress -- --test-filter "hot_spinners: wide-pool"
```

Expected: PASS, under 10s.

### Step 3: Run full stress suite 5× consecutive (correctness gate)

```bash
cd /home/benji/src/devnw/zig/thread-pool-phase-f && for i in 1 2 3 4 5; do echo "=== run $i ==="; zig build test-stress --summary all || exit 1; done
```

Expected: 5/5 pass.

### Step 4: Commit

```bash
cd /home/benji/src/devnw/zig/thread-pool-phase-f && git add tests/stress.zig && git commit -m "test(stress): hot_spinners=1 wide-pool flood regression guard"
```

---

## Task 8: A/B-disable gate (MANDATORY pre-merge check)

**Files:** none modified (measurement only; may temporarily edit benchmark source and revert).

Per Phase F1's methodology lesson: before accepting the mechanic is working, measure the same build with `hot_spinners=0` (must match baseline) and `hot_spinners=1` (must hit target). If `hot_spinners=1` doesn't beat `hot_spinners=0`, the mechanic isn't engaging.

### Step 1: Build ReleaseFast

```bash
cd /home/benji/src/devnw/zig/thread-pool-phase-f && zig build -Doptimize=ReleaseFast
```

Expected: SUCCESS.

### Step 2: Measure baseline (hot_spinners=0)

Find the tokio-parity bench config and verify `hot_spinners` is not set (defaults to 0):

```bash
cd /home/benji/src/devnw/zig/thread-pool-phase-f && grep -n "hot_spinners\|benchFlood\|ThreadPool.init" benchmarks/bench_tokio_parity.zig | head -20
```

If the bench defaults `hot_spinners=0`, proceed. If any override exists, temporarily remove it.

Run the bench binary directly to avoid build caching:

```bash
BIN=$(find /home/benji/src/devnw/zig/thread-pool-phase-f/.zig-cache/o -name "thread-pool-tokio-parity" -executable 2>/dev/null | head -1)
for i in 1 2 3; do echo "=== run $i ==="; $BIN; done
```

Record `flood_1m` ops/s for each run. Compute median.

**Gate A:** median should be ≈ 335K (within ~15% noise). If it regresses below ~300K, the `wakeOneParkedWorker` refactor or conditional introduced a real cost — STOP and diagnose.

### Step 3: Measure with hot_spinners=1

Edit `benchmarks/bench_tokio_parity.zig` in the `benchFlood` config (the `ThreadPool.init` call inside the flood scenario) to add:

```zig
        .hot_spinners = 1,
```

Rebuild:

```bash
cd /home/benji/src/devnw/zig/thread-pool-phase-f && zig build -Doptimize=ReleaseFast
```

Run 3 times:

```bash
BIN=$(find /home/benji/src/devnw/zig/thread-pool-phase-f/.zig-cache/o -name "thread-pool-tokio-parity" -executable 2>/dev/null | head -1)
for i in 1 2 3; do echo "=== hot_spinners=1 run $i ==="; $BIN; done
```

Record `flood_1m` ops/s. Compute median.

**Gate B:** median should be ≥ 450K. Rollback floor at 400K.

### Step 4: REVERT the bench edit

```bash
cd /home/benji/src/devnw/zig/thread-pool-phase-f && git checkout benchmarks/
cd /home/benji/src/devnw/zig/thread-pool-phase-f && git diff
```

Expected: `git diff` empty. If not, manually undo any remaining edits.

### Step 5: Evaluate gates

| Gate | Target | Measured | Pass? |
|---|---:|---:|---:|
| A: hot_spinners=0 median | ≈ 335K (within noise) | TBD | TBD |
| B: hot_spinners=1 median | ≥ 450K | TBD | TBD |
| Delta: B > A | yes, significant | TBD | TBD |

Decision tree:

- **A ≈ 335K AND B ≥ 450K:** CLEAN PASS. Mechanic engages, proceed to Task 9.
- **A regressed (< 300K):** BLOCKED. Refactor broke something; diagnose.
- **B < 400K:** ROLLBACK FLOOR. Report BLOCKED.
- **B in [400K, 450K):** PARTIAL. Report to controller; decision on whether to continue.
- **A ≈ 335K AND B ≈ A:** MECHANIC NOT ENGAGING. Report BLOCKED; hot-spinner loop isn't catching submits or wake-skip isn't saving meaningful cost. Iterate on design.

### Step 6: Record results for Task 10

Save the three runs for each config (six values total) — they go into Task 10's Phase F1b documentation. No commit yet.

---

## Task 9: Formal measurement + rebaseline

**Files:** `benchmarks/results/baseline.json` (only if gates pass).

Only execute this task if Task 8's A/B gate PASSED. Otherwise, STOP.

### Step 1: Run `bench-tokio-parity` 5 times (formal)

Still with `hot_spinners=0` (default, no bench edit needed). Record 5 runs each of `flood_1m` and `contended_spawn_8x`.

```bash
BIN=$(find /home/benji/src/devnw/zig/thread-pool-phase-f/.zig-cache/o -name "thread-pool-tokio-parity" -executable 2>/dev/null | head -1)
for i in 1 2 3 4 5; do echo "=== run $i ==="; $BIN; done
```

Record all values.

### Step 2: Run submit-latency micro

```bash
cd /home/benji/src/devnw/zig/thread-pool-phase-f && zig build bench-micro-submit -Doptimize=ReleaseFast
```

Record p50/p95/p99. Acceptance: p50 ≤ 1000 ns, p99 ≤ 1800 ns.

### Step 3: Run full CI bench suite

```bash
cd /home/benji/src/devnw/zig/thread-pool-phase-f && zig build bench -Doptimize=ReleaseFast
```

Expected: completes. Note any scenario regressing beyond its stddev gate.

### Step 4: Rebaseline

```bash
cd /home/benji/src/devnw/zig/thread-pool-phase-f && mkdir -p benchmarks/results && zig build bench -Doptimize=ReleaseFast -- --output benchmarks/results/baseline.json
```

Verify the file changed:

```bash
cd /home/benji/src/devnw/zig/thread-pool-phase-f && git diff benchmarks/results/baseline.json | head -20
```

### Step 5: Commit baseline

```bash
cd /home/benji/src/devnw/zig/thread-pool-phase-f && git add benchmarks/results/baseline.json && git commit -m "bench: rebaseline after Phase F1b reserved hot-spinners"
```

---

## Task 10: Document Phase F1b in `PERFORMANCE_TRACKING.md`

**Files:**

- Modify: `docs/PERFORMANCE_TRACKING.md`

### Step 1: Append Phase F1b section

In `docs/PERFORMANCE_TRACKING.md`, insert AFTER the existing `## Phase F1: Hot-Spin Wake Elimination (negative result ...)` section and BEFORE `## Bench Stability`. Fill in TBDs with numbers from Tasks 8 and 9:

````markdown
## Phase F1b: Reserved Hot-Spin Workers

**Shipped:**

1. **`Config.hot_spinners: u32 = 0`** — opt-in number of workers reserved as always-spinning. Validated `hot_spinners < max_threads`.
2. **`Config.wake_every_n_tasks: u32 = 64`** — hot-spinner wake propagation threshold. Validated against 0-with-hot-spinners-enabled combo.
3. **`Core.hotSpinnerLoop`** — never-park loop for reserved workers; propagates one `futex_wake` per `wake_every_n_tasks` tasks executed.
4. **`Core.wakeOneParkedWorker`** — extracted from `enqueueTask`; shared by the cold-path (hot_spinners=0) and hot-spinner propagation. Skips indices `< hot_spinners` in its scan.
5. **`enqueueTask` conditional skip** — when `hot_spinners > 0`, submitter bypasses the wake scan entirely.

**Design spec:** `docs/superpowers/specs/2026-04-12-phase-f1b-reserved-hot-spinners-design.md`.

**Rationale:** Phase F1 failed because its spin window (~128 ns) was 20× shorter than the inter-submit interval (~3 µs), so the `active_spinners > 0` check fired ~never. F1b sidesteps this by making reserved workers' "spinning" state unbounded in duration — they never park.

### Phase F1b measurements (git SHA TBD, median of 5 runs ReleaseFast, 56-core host)

| Metric | Baseline | hot_spinners=0 | hot_spinners=1 | Target | Met? |
|---|---:|---:|---:|---:|---:|
| `flood_1m` ops/s | 335K | TBD | TBD | ≥ 450K (h=1) | TBD |
| `contended_spawn_8x` ops/s | 534K | TBD | — | = baseline (h=0) | TBD |
| Submit p50 (1 worker, 100k samples) | 917 ns | TBD | — | ≤ 1000 ns | TBD |
| Submit p99 | 1690 ns | TBD | — | ≤ 1800 ns | TBD |
| `test-stress` 5× consecutive (h=0) | pass | pass | — | pass | TBD |
| `test-stress` 5× consecutive (h=1) | — | — | pass | pass | TBD |

### A/B-disable gate (mandatory per F1 methodology)

Measured on the same build by toggling `hot_spinners` in the flood_1m bench config. Gate A: h=0 must match baseline (within noise). Gate B: h=1 must beat h=0 meaningfully.

| Gate | Target | Measured (median of 3) | Verdict |
|---|---:|---:|---:|
| A: hot_spinners=0 matches baseline | ≈ 335K | TBD | TBD |
| B: hot_spinners=1 ≥ 450K | ≥ 450K | TBD | TBD |
| Delta | B > A, > 30% | TBD | TBD |

### Why this phase worked where F1 didn't

F1 added a short spin (~128 ns) and hoped submitters would catch workers during that window. They almost never did — P(spinning) × (spin_window / submit_interval) ≈ 0. F1b reserves workers whose "spinning window" is effectively ∞, guaranteeing engagement regardless of submit timing. The cost (1 core per hot-spinner at 100% CPU) is opt-in via the config knob; users who don't set it pay zero.

### CPU trade-off

With `hot_spinners=1` on flood_1m: ~1 core at 100% for the spinner + the remaining 55 workers mostly idle (73% parked pre-F1b). Net CPU change vs baseline is ~+1 core of user CPU minus whatever futex_wake cycles the submitter saves (profile: ~50% of one submitter core = ~0.5 core). Net cost: ~+0.5 cores for ~+35% throughput on this scenario. Acceptable for throughput-critical deployments; undesirable for latency-idle deployments (which should leave `hot_spinners=0`).

### Residual gap to Tokio parity

Tokio runs 5–15M ops/s on flood_1m-equivalent. F1b target is 450K — still 11–33× short. Follow-up phases:

1. **F1b-rotation:** rotate which worker is the hot-spinner every N tasks (thermal distribution on long-running pools).
2. **F1c-NUMA:** per-NUMA-node hot-spinners + inject-queue sharding. Required for multi-socket scaling.
3. **F2 (submitBatch):** amortize one wake over N pushes — orthogonal.
4. **Phase G:** descriptor-pool / inject-queue contention.
5. **Phase H:** worker-local allocation / cache locality.
````

Replace every `TBD` with the measured values from Tasks 8-9.

### Step 2: Update the top-of-file "Verdict vs Targets" table

Locate the `bench_tokio_parity/flood_1m ≥ 1M ops/s` row and update the "After plan" cell:

```
| `bench_tokio_parity/flood_1m` ≥ 1M ops/s | 297K | 340K (C) / 341K (D, reverted) / 322K (E, reverted) / 383K (F1, reverted) / TBD (F1b) | ⚠️ |
```

Same for the `contended_spawn_8x` row (F1b hot_spinners=0 should match current).

### Step 3: Commit

```bash
cd /home/benji/src/devnw/zig/thread-pool-phase-f && git add docs/PERFORMANCE_TRACKING.md && git commit -m "docs(perf): Phase F1b verdict, rebaseline after reserved hot-spinners"
```

---

## Self-Review Checklist

Before declaring the plan complete:

- [ ] `Config.hot_spinners: u32 = 0` field exists with doc comment.
- [ ] `Config.wake_every_n_tasks: u32 = 64` field exists with doc comment.
- [ ] `Config.validate()` returns `error.InvalidHotSpinners` when `hot_spinners >= max_threads`.
- [ ] `Config.validate()` returns `error.InvalidWakeThreshold` when `hot_spinners > 0 and wake_every_n_tasks == 0`.
- [ ] `Core.wakeOneParkedWorker` extracted with `idx < hot_spinners` skip.
- [ ] `Core.hotSpinnerLoop` exists and never calls `idle()`.
- [ ] `workerMain` forks at entry based on `worker_index < hot_spinners`.
- [ ] `enqueueTask` wraps the `wakeOneParkedWorker` call in `if (hot_spinners == 0)`.
- [ ] Hot-spinner basic correctness test passes.
- [ ] Wake propagation test passes (slow tasks, parallel execution observed).
- [ ] Wide-pool flood stress test passes.
- [ ] `test-stress` 5× consecutive with `hot_spinners=0` passes.
- [ ] **A/B gate: hot_spinners=0 matches baseline AND hot_spinners=1 ≥ 450K.**
- [ ] Baseline committed (only if gates pass).
- [ ] `PERFORMANCE_TRACKING.md` Phase F1b filled in with measured numbers.

## Rollback Criteria

- `flood_1m` median with `hot_spinners=1` < 400K → ROLLBACK Tasks 2-4 (keep Task 1 config fields + Tasks 5-7 tests as permanent improvements).
- hot_spinners=0 median regresses below ~300K → ROLLBACK Task 2 (refactor broke something).
- Any stress test hangs or fails 5× → ROLLBACK Tasks 3-4 (hot-spinner loop or skip-wake has a correctness bug).
- Submit p50 regresses beyond 20% → ROLLBACK.

## Execution Handoff

**Plan complete and saved to `docs/superpowers/plans/2026-04-12-phase-f1b-reserved-hot-spinners.md`. Two execution options:**

**1. Subagent-Driven (recommended)** — fresh subagent per task, review between tasks. Critical gates: Task 4 Step 5 (5× stress after mechanic activation), Task 7 Step 3 (5× stress with hot_spinners=1), Task 8 Step 5 (A/B gate — the crucial pre-merge check).

**2. Inline Execution** — execute tasks in this session using executing-plans, batch checkpoints.

**Which approach?**
