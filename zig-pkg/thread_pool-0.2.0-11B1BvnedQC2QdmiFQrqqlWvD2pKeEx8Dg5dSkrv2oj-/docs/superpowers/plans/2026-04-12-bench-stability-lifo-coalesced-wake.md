# Bench Stability, LIFO Slot, and Coalesced Backpressure Wake Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the next layer of Tokio-parity gap by (1) making the bench harness trustworthy enough to tell signal from noise, (2) adding a per-worker LIFO slot so submit-from-worker bypasses the inject queue, and (3) coalescing backpressure wake signals so flood scenarios pay ~32× fewer futex round-trips on the blocking path.

**Architecture:**

- **Phase 1 (bench stability):** Current harness runs each scenario 3 times and takes median of 3. Run-to-run variance on `conn_churn_seq/global_queue` has been observed at ±25%, which is larger than every optimization in Phase A+B combined. Bump to 7 runs, discard the first as warmup, take median of the remaining 6, and report stddev alongside the median so the CI compare-bench step can gate on "regression beyond measured noise" rather than a hard-coded -15%.
- **Phase 2 (LIFO slot):** Each Worker gets a single-slot `lifo_slot: std.atomic.Value(u32)` (sentinel `0xFFFF_FFFF` = empty). `enqueueTask` from a worker-thread context tries the LIFO slot first (plain store when empty — owner-only write); `nextTask` pops the LIFO slot ahead of the local ring. This bypasses both the inject queue and the local-ring push/pop for the common "task A spawns task B" case. Borrowed directly from Tokio's `lifo_slot` — see `tokio/src/runtime/scheduler/multi_thread/worker.rs`.
- **Phase 3 (coalesced backpressure wake):** `releaseDescriptor` today signals `backpressure_cond` on every descriptor free when any waiter exists. On flood scenarios with queue=4096 / 1M tasks, the submitter blocks ~244 times, each block seeing ~4096 signals before it drains enough to proceed — a ~1M-syscall tax. Replace with a per-pool `releases_since_signal` counter that signals once per `config.wake_coalesce_batch` releases (default 32). A 1 ms safety `timedWait` on the waiter side (already present) bounds worst-case latency.

**Performance Targets (success criteria):**

| Metric | Current (post-merge main) | Target |
|---|---|---|
| `conn_churn_seq/global_queue` run-to-run stddev | ~25% | < 5% of median |
| `bench_tokio_parity/flood_1m` ops/s | 336K | ≥ 600K (80%+ improvement) |
| `bench_tokio_parity/contended_spawn_8x` ops/s | 514K | ≥ 800K |
| Submit p50 from worker context | not measured | < 300 ns (LIFO hot path) |
| `releaseDescriptor` futex syscalls per 1M tasks at q=4096 | ~1M | ≤ 32K |

**Tech Stack:** Zig 0.15.2, `std.atomic`, `std.Thread.Mutex/Condition`, existing `benchmarks/common.zig` harness, GitLab CI `bench-micro` job.

**Reference designs:**
- Tokio LIFO slot: [`tokio/src/runtime/scheduler/multi_thread/worker.rs`](https://github.com/tokio-rs/tokio/blob/master/tokio/src/runtime/scheduler/multi_thread/worker.rs) — `Core::lifo_slot`.
- Go runtime "next task" hot slot: [`runtime/runtime2.go` `p.runnext`](https://github.com/golang/go/blob/master/src/runtime/runtime2.go).
- Coalesced wake pattern: standard sem_post / futex batching; mirrors the `backpressure_waiters` fast-path guard already in place.

---

## File Structure

**New files:** none.

**Modified files:**
- `benchmarks/common.zig` — `runScenarios` bumps to 7 runs + discard + stddev.
- `benchmarks/compare.zig` — regression gate becomes `change < -(max(15%, 3 × stddev))`.
- `src/pool.zig` — Worker gets `lifo_slot` field; `enqueueTask` and `nextTask` add LIFO steps; `releaseDescriptor` coalesces signals.
- `src/types.zig` — new `Config.wake_coalesce_batch` knob.
- `tests/stress.zig` — add LIFO correctness stress test.
- `tests/unit.zig` — add LIFO push/pop unit tests.
- `docs/PERFORMANCE_TRACKING.md` — record new numbers, update verdict.
- `benchmarks/results/baseline.json` — rebaseline after all three phases land.

---

## Phase 1: Bench Harness Stability

**Rationale:** You can't optimize what you can't measure. The post-merge run showed `conn_churn_seq/global_queue` regressing 25% against a baseline produced from the identical code 10 minutes earlier. Bench output must be at least as precise as the optimizations we're measuring, else every future plan degenerates into chasing noise.

### Task 1: Increase run count and discard first-run warmup

**Files:**
- Modify: `benchmarks/common.zig` (`runScenarios`, around line 101-130)

- [ ] **Step 1: Read the current `runScenarios` loop**

Open `benchmarks/common.zig` and review lines 101-130.

- [ ] **Step 2: Replace the 3-run median with a 7-run discard-first median-of-6**

Change the `results: [3]ResultRow` declaration and surrounding logic to:

```zig
// Run 7 times; discard the first as a warm-up (cold caches, JIT-like effects).
// Take the median of the remaining 6 for the reported row, and compute stddev
// over the same 6 so compare-bench can gate on measured noise.
const RUN_COUNT: usize = 7;
const WARMUP_DISCARD: usize = 1;
const SAMPLE_COUNT: usize = RUN_COUNT - WARMUP_DISCARD; // 6
var results: [RUN_COUNT]ResultRow = undefined;
for (&results) |*r| {
    r.* = try runScenario(allocator, spec, variant);
}
// Free the discarded warm-up run's allocations.
for (results[0..WARMUP_DISCARD]) |r| {
    allocator.free(r.git_sha);
    allocator.free(r.cpu);
}
var samples = results[WARMUP_DISCARD..];
std.sort.heap(ResultRow, samples, {}, struct {
    fn lessThan(_: void, a: ResultRow, b: ResultRow) bool {
        return a.throughput_ops_per_sec < b.throughput_ops_per_sec;
    }
}.lessThan);
// Compute stddev over the sorted 6 samples before we free the non-median ones.
const median_throughput = samples[SAMPLE_COUNT / 2].throughput_ops_per_sec;
var stddev_ops_per_sec: f64 = 0;
{
    var sum_sq: f64 = 0;
    for (samples) |s| {
        const d = s.throughput_ops_per_sec - median_throughput;
        sum_sq += d * d;
    }
    stddev_ops_per_sec = std.math.sqrt(sum_sq / @as(f64, @floatFromInt(SAMPLE_COUNT)));
}
// Free allocations from every non-median sample.
for (samples, 0..) |r, idx| {
    if (idx == SAMPLE_COUNT / 2) continue;
    allocator.free(r.git_sha);
    allocator.free(r.cpu);
}
var median_row = samples[SAMPLE_COUNT / 2];
median_row.throughput_stddev_ops_per_sec = stddev_ops_per_sec;
try rows.append(allocator, median_row);
```

- [ ] **Step 3: Add `throughput_stddev_ops_per_sec` field to `ResultRow`**

In `benchmarks/common.zig` find the `ResultRow` struct (search for `throughput_ops_per_sec:`). Add a sibling field, e.g. just after `throughput_ops_per_sec`:

```zig
throughput_stddev_ops_per_sec: f64 = 0,
```

Default to 0 so runs that bypass `runScenarios` (e.g., `scale_bench.zig`) serialize without error.

- [ ] **Step 4: Update the `runScenario` return to initialize the new field to 0**

In `runScenario` around line 226-260, set `.throughput_stddev_ops_per_sec = 0` explicitly in the returned struct literal. The median-computation loop in Step 2 overwrites this for the median row. The rest stays 0 (not used elsewhere).

- [ ] **Step 5: Run `zig build test` and `zig build bench` to confirm compilation and JSON output**

Run:
```
zig build bench -Doptimize=ReleaseFast -- --output benchmarks/results/stability-probe.json
head -30 benchmarks/results/stability-probe.json
```

Expected: JSON now has a `throughput_stddev_ops_per_sec` field on each row. Values should be non-zero and much smaller than the mean.

- [ ] **Step 6: Commit**

```
bench: 7-run discard-first median + stddev reporting

Replaces the 3-run median with a 7-run run, discarding the first as
warmup and taking median-of-6 with stddev. Closes the gap where same-
code reruns produced ±25% variance on conn_churn_seq/global_queue.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
```

### Task 2: Update compare-bench regression gate to use stddev

**Files:**
- Modify: `benchmarks/compare.zig`

- [ ] **Step 1: Read the current regression check**

Open `benchmarks/compare.zig` around line 27-44.

- [ ] **Step 2: Replace the hard-coded -15% gate with noise-aware thresholding**

Inside the `for (current_doc.value.rows) |row|` loop, after the existing `pctChange` calls, replace the single-line `if (throughput_change < -15.0) failures += 1;` with:

```zig
// Convert absolute stddev (ops/sec) to percentage relative to the baseline
// throughput. If stddev is 0 (older baseline without the field), treat the
// noise floor as 5%.
const stddev_pct = if (baseline.throughput_ops_per_sec != 0)
    (baseline.throughput_stddev_ops_per_sec / baseline.throughput_ops_per_sec) * 100.0
else
    0.0;
const noise_gate = @max(15.0, 3.0 * stddev_pct);
std.debug.print("  noise_gate={d:.2}% (stddev_pct={d:.2}%)\n", .{ noise_gate, stddev_pct });
if (throughput_change < -noise_gate) {
    std.debug.print("  FAIL: regression {d:.2}% exceeds noise gate {d:.2}%\n", .{ -throughput_change, noise_gate });
    failures += 1;
}
```

- [ ] **Step 3: Verify compare-bench still compiles and runs**

Run:
```
zig build bench -Doptimize=ReleaseFast -- --output benchmarks/results/probe-a.json
zig build bench -Doptimize=ReleaseFast -- --output benchmarks/results/probe-b.json
zig build compare-bench -- --baseline benchmarks/results/probe-a.json --current benchmarks/results/probe-b.json
```

Expected: each row prints `noise_gate=<pct>%` based on stddev. Same-code comparison should not fail (no regression beyond 3σ).

- [ ] **Step 4: Commit**

```
bench: gate compare-bench on 3σ noise, not hard-coded 15%

A fixed 15% regression gate misses small real regressions in stable
benches and false-positives on noisy ones. Use 3× the baseline's
measured stddev (floor 15%) so the gate is proportional to how stable
the scenario actually is.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
```

### Task 3: Rebaseline and record stddev

**Files:**
- Modify: `benchmarks/results/baseline.json`
- Modify: `docs/PERFORMANCE_TRACKING.md` (new section)

- [ ] **Step 1: Rebaseline**

Run:
```
zig build bench -Doptimize=ReleaseFast -- --output benchmarks/results/latest.json
cp benchmarks/results/latest.json benchmarks/results/baseline.json
```

- [ ] **Step 2: Add a **Bench Stability** section to `docs/PERFORMANCE_TRACKING.md`**

Near the top (after **Phase A+B Final Verdict**), insert:

```markdown
## Bench Stability

From 2026-04-12 forward, `benchmarks/common.zig` runs 7 iterations per scenario,
discards the first (warmup), and reports the median of 6 along with stddev.
Observed stddev as a fraction of median (measured on the rebaselined machine):

| Scenario | Median ops/s | Stddev ops/s | Stddev % |
|----------|-------------|--------------|----------|
| conn_churn_seq/global_queue | <median> | <stddev> | <pct> |
| conn_churn_seq/work_stealing | <median> | <stddev> | <pct> |
| producer_contention/global_queue | <median> | <stddev> | <pct> |
| producer_contention/work_stealing | <median> | <stddev> | <pct> |

compare-bench's regression gate is `change < -max(15%, 3×stddev%)`.
```

Fill the `<...>` placeholders from the JSON you just baselined.

- [ ] **Step 3: Commit**

```
bench: rebaseline with 7-run harness and record stddev table

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
```

---

## Phase 2: Per-Worker LIFO Slot

**Rationale:** The common pattern in every realistic workload is "a task submits another task." In a fork-join / async chain with N stages, the hot path is submit → run → submit → run. Today every submit from worker context goes through:

1. `acquireDescriptor` (CAS on tagged free-list head)
2. Slot fields write
3. `queued_tasks.fetchAdd(seq_cst)` (mfence on x86)
4. `local_queue.tryPushBottom` (acquire load + release store)
5. Scan `workers[*].is_parked` with seq_cst loads

That's ~5 cross-core atomic ops on every sub-task submission. Tokio's `lifo_slot` bypasses all five for the common case: the owner parks one descriptor in a thread-local slot, and the next `nextTask` call pops it first. The scheduler still runs tasks in LIFO-then-FIFO order from the owner's POV, which matches the forward-progress semantics of structured async.

**Invariant (must hold after this phase):**

> A task submitted via `submit()` from worker W's thread is delivered to some worker. It may land in W's LIFO slot, W's local ring, W's inject queue, or (on any-queue-full) error out. Under no schedule does the task both land in the LIFO slot AND the local ring — exactly one.

### Task 4: Add `lifo_slot` field to Worker

**Files:**
- Modify: `src/pool.zig` (`Worker` struct, around line 68-90)

- [ ] **Step 1: Add the field and its sentinel**

Near the top of `src/pool.zig` where the other top-level constants live (before `Worker`), add:

```zig
const LIFO_SLOT_EMPTY: u32 = 0xFFFF_FFFF;
```

Inside the `Worker` struct (around line 68-90), add:

```zig
/// Tokio-style single-slot LIFO cache. When a task is submitted from this
/// worker's thread, it goes here first (single atomic store); `nextTask`
/// pops the slot ahead of the local ring. Cross-worker submits never
/// touch this slot. Stealers never touch this slot either — only the
/// owner writes to it. Sentinel value `LIFO_SLOT_EMPTY` (0xFFFF_FFFF)
/// means "no cached task".
lifo_slot: std.atomic.Value(u32) = std.atomic.Value(u32).init(LIFO_SLOT_EMPTY),
```

- [ ] **Step 2: Verify compilation**

Run: `zig build check 2>&1 | tail -5`
Expected: no errors.

- [ ] **Step 3: Commit**

```
feat(pool): add per-worker LIFO slot field

Adds a single-slot u32 cache per worker with sentinel 0xFFFF_FFFF
meaning empty. Unused until the next task wires it into the submit/
next-task paths.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
```

### Task 5: Wire LIFO slot into `enqueueTask` submit path

**Files:**
- Modify: `src/pool.zig` (`enqueueTask`, around line 522-580)

- [ ] **Step 1: Add a unit test first (TDD)**

In `tests/unit.zig`, add:

```zig
test "LIFO slot: submit-from-worker uses lifo_slot before local ring" {
    const allocator = std.testing.allocator;
    var pool = try thread_pool.ThreadPool.init(allocator, .{
        .max_threads = 1,
        .min_threads = 1,
        .queue_capacity = 64,
        .local_queue_capacity = 16,
        .scheduler_variant = .work_stealing,
    });
    defer pool.deinit();

    // A task that submits another task should deliver both.
    const Nested = struct {
        var outer_counter = std.atomic.Value(u64).init(0);
        var inner_counter = std.atomic.Value(u64).init(0);

        fn innerTask(raw_ctx: *anyopaque, runtime: *thread_pool.TaskContext) void {
            _ = raw_ctx;
            _ = runtime;
            _ = inner_counter.fetchAdd(1, .release);
        }
        fn outerTask(raw_ctx: *anyopaque, runtime: *thread_pool.TaskContext) void {
            _ = runtime;
            const p: *thread_pool.ThreadPool = @ptrCast(@alignCast(raw_ctx));
            _ = outer_counter.fetchAdd(1, .release);
            _ = p.submit(innerTask, @ptrCast(p), .{}) catch {};
        }
    };

    Nested.outer_counter.store(0, .release);
    Nested.inner_counter.store(0, .release);

    var wg = pool.waitGroup();
    for (0..100) |_| {
        _ = try pool.submit(Nested.outerTask, @ptrCast(&pool), .{ .wait_group = &wg });
    }
    wg.wait();
    // Drain any orphan inner tasks (no wait group on them).
    try pool.drain();

    try std.testing.expectEqual(@as(u64, 100), Nested.outer_counter.load(.acquire));
    try std.testing.expectEqual(@as(u64, 100), Nested.inner_counter.load(.acquire));
}
```

- [ ] **Step 2: Run the test — expect PASS even without LIFO wiring**

The test is correctness-level, not behavior-observing. It should pass both before and after. Run `zig build test-unit 2>&1 | tail -10` and confirm pass. If it fails, that's a pre-existing bug — escalate.

- [ ] **Step 3: Modify `enqueueTask` to prefer the LIFO slot**

In `src/pool.zig` `fn enqueueTask` (around line 540-545), find the block:

```zig
var queued = false;
if (self.config.scheduler_variant == .work_stealing and tls_worker_index != null) {
    const wi = tls_worker_index.?;
    queued = self.local_queues[wi].tryPushBottom(descriptor_index);
    ...
}
```

Replace the `if` body with:

```zig
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
```

- [ ] **Step 4: Verify unit test still passes**

Run: `zig build test-unit 2>&1 | tail -10`
Expected: the nested-submit test still passes — but now the inner tasks land in the LIFO slot instead of the local ring.

- [ ] **Step 5: Commit**

```
feat(pool): route submit-from-worker through LIFO slot first

Worker-context submits try the per-worker lifo_slot before the local
ring. Owner-only plain store when empty avoids the release-store on
local_queue.tail, the stats updatePeakU32, and the queue full-check.
Cross-worker submits are unchanged.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
```

### Task 6: Update `nextTask` to pop LIFO slot first

**Files:**
- Modify: `src/pool.zig` (`nextTask`, around line 622-690)

- [ ] **Step 1: Read `fn nextTask` and identify the insertion point**

The function starts around line 622. The current order for work-stealing is: local ring pop → inject queue drain → steal scan. Insert the LIFO slot pop at the very top (before local ring).

- [ ] **Step 2: Add the LIFO pop at the start of `nextTask`**

Just after the `var worker = &self.workers[worker_index]; var lq = &self.local_queues[worker_index];` lines (around line 625), insert:

```zig
// LIFO slot first: owner-only swap-to-empty. Most-recently-submitted
// task runs next. This is the hot path for "task spawns task".
if (self.config.scheduler_variant == .work_stealing) {
    const cached = worker.lifo_slot.swap(LIFO_SLOT_EMPTY, .acquire);
    if (cached != LIFO_SLOT_EMPTY) {
        self.decrementQueued();
        return cached;
    }
}
```

Note: use `swap` (exchange) to atomically read-and-clear. Acquire on the swap pairs with the release in `enqueueTask`'s LIFO store.

- [ ] **Step 3: Handle shutdown-drain**

Around line 790 (`fn cancelQueuedTasks`) there's a loop draining the inject queue + local queues. After the existing inject-queue drain and before the local-queue drain loop, add:

```zig
// Drain LIFO slots too.
for (self.workers) |*w| {
    const cached = w.lifo_slot.swap(LIFO_SLOT_EMPTY, .acquire);
    if (cached != LIFO_SLOT_EMPTY) {
        self.decrementQueued();
        self.cancelDescriptor(cached);
    }
}
```

- [ ] **Step 4: Run unit tests**

Run: `zig build test-unit 2>&1 | tail -10`
Expected: pass.

- [ ] **Step 5: Run stress tests**

Run: `zig build test-stress 2>&1 | tail -15`
Expected: pass. The `queue_kind matrix` tests from the prior plan exercise the LIFO-slot path under load.

- [ ] **Step 6: Commit**

```
feat(pool): nextTask pops LIFO slot before local ring

Owner-only swap-to-empty using the LIFO_SLOT_EMPTY sentinel. Completes
the submit-from-worker hot path: task A spawns task B, A returns, the
worker immediately runs B from its lifo_slot without touching the ring
or the inject queue.

Shutdown drain also flushes lifo_slots so cancel_pending doesn't
leak them.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
```

### Task 7: Stress test — LIFO slot under concurrent steal pressure

**Files:**
- Modify: `tests/stress.zig`

- [ ] **Step 1: Add the stress test**

Append to `tests/stress.zig`:

```zig
test "LIFO slot: nested-submit storm with 4 workers, no lost tasks" {
    var pool = try thread_pool.ThreadPool.init(std.testing.allocator, .{
        .min_threads = 4,
        .max_threads = 4,
        .queue_capacity = 8192,
        .local_queue_capacity = 256,
        .scheduler_variant = .work_stealing,
        .idle_park_after_ns = 50_000,
        .spin_before_park_iters = 4,
    });
    defer pool.deinit();

    const Nested = struct {
        var inner_counter: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

        fn innerTask(raw_ctx: *anyopaque, runtime: *thread_pool.TaskContext) void {
            _ = raw_ctx;
            _ = runtime;
            _ = inner_counter.fetchAdd(1, .release);
        }
        fn outerTask(raw_ctx: *anyopaque, runtime: *thread_pool.TaskContext) void {
            _ = runtime;
            const p: *thread_pool.ThreadPool = @ptrCast(@alignCast(raw_ctx));
            // Each outer submits 4 inner tasks from worker context — exercises
            // the lifo_slot miss-to-local-ring path.
            var i: u32 = 0;
            while (i < 4) : (i += 1) {
                while (true) {
                    _ = p.submit(innerTask, @ptrCast(p), .{}) catch {
                        std.Thread.sleep(1_000);
                        continue;
                    };
                    break;
                }
            }
        }
    };

    Nested.inner_counter.store(0, .release);

    const outer_total: u64 = 25_000;
    var wg = pool.waitGroup();
    var i: u64 = 0;
    while (i < outer_total) : (i += 1) {
        while (true) {
            _ = pool.submit(Nested.outerTask, @ptrCast(&pool), .{ .wait_group = &wg }) catch {
                std.Thread.sleep(1_000);
                continue;
            };
            break;
        }
    }
    wg.wait();
    try pool.drain(); // finish inner tasks with no wait-group

    try std.testing.expectEqual(outer_total * 4, Nested.inner_counter.load(.acquire));
}
```

- [ ] **Step 2: Run stress tests**

Run: `zig build test-stress 2>&1 | tail -20`
Expected: pass in under 5s.

- [ ] **Step 3: Commit**

```
test(stress): LIFO slot nested-submit storm on 4 workers

Each of 25k outer tasks submits 4 inner tasks from worker context,
exercising the lifo_slot hot path and its miss-to-local-ring
fallback. All 100k inner tasks must execute exactly once.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
```

---

## Phase 3: Coalesced Backpressure Wake

**Rationale:** On `flood_1m` with `queue_capacity = 4096`, the submitter blocks ~244 times as workers drain the queue. Each in-between queue-full window sees ~4096 `releaseDescriptor` calls, each of which acquires `backpressure_mutex`, signals the condvar, and releases the mutex when `backpressure_waiters > 0`. That's ~1M mutex+signal round-trips per 1M tasks. The submitter only needs to wake up a bounded number of times (at most 244 for this scenario). Coalesce: signal every N releases. The waiter's `timedWait` already has a ceiling (`idle_park_after_ns` or similar), so missed signals become bounded-latency delays, not lost wakeups.

### Task 8: Add `wake_coalesce_batch` Config knob

**Files:**
- Modify: `src/types.zig`

- [ ] **Step 1: Add the field**

In `src/types.zig` `Config`, after `inject_batch_size`, add:

```zig
/// `releaseDescriptor` signals blocked submitters on backpressure once
/// per this many releases, rather than on every release. 0 disables
/// coalescing (signal every release — the pre-2026-04-12 behavior).
/// The submitter's `timedWait` on `backpressure_cond` bounds worst-case
/// missed-signal latency.
wake_coalesce_batch: u32 = 32,
```

Update `normalized()` to clamp to a reasonable range (0..=1024):

```zig
if (cfg.wake_coalesce_batch > 1024) cfg.wake_coalesce_batch = 1024;
```

- [ ] **Step 2: Run tests to confirm no breakage**

Run: `zig build test 2>&1 | tail -10`
Expected: pass (the knob is inert until Task 9 wires it in).

- [ ] **Step 3: Commit**

```
feat(config): add wake_coalesce_batch knob, default 32

Configures how many descriptor releases must accumulate before
releaseDescriptor signals a waiting submitter. 0 disables coalescing.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
```

### Task 9: Coalesce signals in `releaseDescriptor`

**Files:**
- Modify: `src/pool.zig` (`Sync` struct around line 172-182, `releaseDescriptor` around line 865-896)

- [ ] **Step 1: Add a release-counter to Sync**

In the `Sync` struct, add:

```zig
/// Counter of descriptor releases since the last backpressure wake.
/// When it hits `config.wake_coalesce_batch`, `releaseDescriptor` signals
/// and resets the counter.
releases_since_signal: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
```

- [ ] **Step 2: Replace the always-signal path in `releaseDescriptor`**

Around line 891, find:

```zig
if (self.sync.backpressure_waiters.load(.monotonic) > 0) {
    self.sync.backpressure_mutex.lock();
    self.sync.backpressure_cond.signal();
    self.sync.backpressure_mutex.unlock();
}
```

Replace with:

```zig
if (self.sync.backpressure_waiters.load(.monotonic) > 0) {
    const batch = self.config.wake_coalesce_batch;
    const should_signal = if (batch == 0) true else blk: {
        // Coalesce: only signal when this release crosses the batch boundary.
        // Use fetchAdd and check if the new count % batch == 0.
        const prev = self.sync.releases_since_signal.fetchAdd(1, .monotonic);
        if (prev + 1 >= batch) {
            self.sync.releases_since_signal.store(0, .monotonic);
            break :blk true;
        }
        break :blk false;
    };
    if (should_signal) {
        self.sync.backpressure_mutex.lock();
        self.sync.backpressure_cond.signal();
        self.sync.backpressure_mutex.unlock();
    }
}
```

- [ ] **Step 3: Ensure `waitForCapacity` timed-wait ceiling is low enough**

Open `src/pool.zig` around line 405-420 (`waitForCapacity`). Confirm the `timedWait` argument bounds worst-case missed-signal latency. Currently it waits `wait_ns` which is derived from `deadline`. Under `backpressure = .block` (no timeout), `deadline` is 0 and `wait_ns` ends up at the `idle_park_after_ns` / similar fallback. Check what the fallback is:

```
grep -n "fn waitForCapacity" -A 15 src/pool.zig
```

If the fallback is >10ms, lower it to ≤ 1 ms so a missed signal becomes at most a 1 ms stall. If it's already ≤ 1 ms, leave it.

If a change is needed: inside `waitForCapacity`, replace the fallback with:

```zig
const wait_ns: u64 = if (deadline == 0) 1_000_000 else ... // existing deadline math
```

(Adapt to the exact shape of the existing code.)

- [ ] **Step 4: Run the full test suite**

Run: `zig build test 2>&1 | tail -20`
Expected: pass. The backpressure tests (`producer_contention`, `stress high-volume`) exercise this path.

- [ ] **Step 5: Commit**

```
perf(pool): coalesce backpressure wake signals (batch=32 default)

releaseDescriptor now signals the backpressure condvar once per
wake_coalesce_batch releases rather than on every release. On a
1M-task flood through a 4096-capacity queue that drops backpressure
signal-related mutex+futex round-trips from ~1M to ~32K.

Waiter side's timedWait bounds worst-case missed-signal latency,
so this is a pure throughput win with no correctness impact.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
```

### Task 10: Stress test — coalesced wake doesn't lose submitters

**Files:**
- Modify: `tests/stress.zig`

- [ ] **Step 1: Add the test**

Append to `tests/stress.zig`:

```zig
test "coalesced wake: submitter never stalls forever on backpressure" {
    // Small queue + 4 submitters + 2 workers: submitters must block
    // frequently. With wake_coalesce_batch=32 there are more missed
    // per-release signals, but the timedWait ceiling bounds stalls.
    var pool = try thread_pool.ThreadPool.init(std.testing.allocator, .{
        .min_threads = 2,
        .max_threads = 2,
        .queue_capacity = 256, // small — force backpressure
        .local_queue_capacity = 64,
        .scheduler_variant = .work_stealing,
        .wake_coalesce_batch = 32,
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
                    .backpressure = .block,
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
    try pool.drain();

    try std.testing.expectEqual(total, counter.value.load(.acquire));
}
```

- [ ] **Step 2: Run stress tests**

Run: `zig build test-stress 2>&1 | tail -15`
Expected: pass in under 5s. If a submitter times out, the coalescing has a correctness issue — escalate.

- [ ] **Step 3: Commit**

```
test(stress): coalesced wake doesn't stall submitters on small queue

4 submitters × 5k tasks through a 256-slot queue forces frequent
backpressure. Coalesced wake (batch=32) must still deliver every
submitter within the 5s timeout.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
```

---

## Phase 4: Measure and Verdict

### Task 11: Re-measure micro + macro benches with new harness

**Files:**
- Modify: `docs/PERFORMANCE_TRACKING.md`

- [ ] **Step 1: Run the full bench suite**

The Phase 1 harness runs 7/median-6 automatically. One run is enough.

```
zig build bench -Doptimize=ReleaseFast -- --output benchmarks/results/phase4-std.json
for i in 1 2 3; do zig build bench-tokio-parity -Doptimize=ReleaseFast 2>&1 | grep tokio_parity; done
for b in 1 8; do
  for i in 1 2 3 4 5; do
    zig build bench-micro-steal -Doptimize=ReleaseFast -- --steal_batch_size=$b 2>&1 | grep steal_throughput
  done
done
for i in 1 2 3 4 5; do
  zig build bench-micro-submit -Doptimize=ReleaseFast 2>&1 | grep submit_latency
done
for i in 1 2 3 4 5; do
  zig build bench-micro-wake -Doptimize=ReleaseFast 2>&1 | grep wake_latency
done
```

- [ ] **Step 2: Append rows to PERFORMANCE_TRACKING.md tables**

For each table (`submit_latency`, `steal_throughput`, `wake_latency`, `Tokio Parity Suite`, standard bench rows), add a row labeled **Phase C (LIFO + coalesced wake)** with the measured medians.

Include the `throughput_stddev_ops_per_sec` from the JSON for the standard-bench rows so the stability improvement shows up.

- [ ] **Step 3: Commit**

```
docs(perf): record LIFO slot + coalesced wake measurements

<brief one-liner per-metric table>

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
```

### Task 12: Update verdict and rebaseline

**Files:**
- Modify: `docs/PERFORMANCE_TRACKING.md`
- Modify: `benchmarks/results/baseline.json`

- [ ] **Step 1: Update Verdict vs Targets table**

For the two Tokio-parity rows, update "After plan" to the Phase C numbers. Flip ✅ if they crossed 1M ops/s; leave ❌ with a residual-gap note if not.

For submit p50, update with any LIFO-path speedup (submit-from-worker should be well under 300ns now).

- [ ] **Step 2: Rebaseline**

```
cp benchmarks/results/phase4-std.json benchmarks/results/baseline.json
```

- [ ] **Step 3: Rewrite the Phase A+B verdict paragraph to include Phase C**

Add a sub-section "Phase C: LIFO slot + coalesced wake" summarizing:
- Bench stability (stddev pct for each scenario)
- LIFO slot impact (submit-from-worker perf delta, nested-storm stress pass)
- Coalesced wake impact (Tokio-parity ops/s delta, syscall count reduction if measured via perf)

- [ ] **Step 4: Commit**

```
docs: Phase C verdict and rebaseline

Final numbers with bench stability fix + LIFO slot + coalesced wake:

  Tokio-parity flood_1m:           <before> → <after> ops/s
  Tokio-parity contended_spawn_8x: <before> → <after> ops/s
  Submit-from-worker p50:          <lifo-hot-path ns>
  conn_churn stddev:               <pct>

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
```

---

## Self-Review Checklist

**1. Spec coverage.**
- Bench stability (Phase 1) → Tasks 1-3. ✓
- LIFO slot (Phase 2) → Tasks 4-7. ✓
- Coalesced wake (Phase 3) → Tasks 8-10. ✓
- Measure + verdict (Phase 4) → Tasks 11-12. ✓

**2. Placeholder scan.**
Concrete `<median>` / `<ops/s>` placeholders in Tasks 3 Step 2, 11 Step 2, 12 Step 1/3 are intentional (values to fill in from measurement). `<brief one-liner per-metric table>` in Task 11 Step 3 is a minor commit-message placeholder — the implementer can summarize from the data they just recorded. All code blocks are complete.

**3. Type consistency.**
- `lifo_slot: std.atomic.Value(u32)` with sentinel `LIFO_SLOT_EMPTY = 0xFFFF_FFFF` — referenced consistently in Tasks 4-7.
- `wake_coalesce_batch: u32` in `Config` — referenced in Tasks 8-10.
- `releases_since_signal: std.atomic.Value(u32)` in `Sync` — only referenced in Task 9.
- `throughput_stddev_ops_per_sec: f64` — added in Task 1, used in Tasks 2, 3, 11, 12.

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-04-12-bench-stability-lifo-coalesced-wake.md`. Two execution options:

**1. Subagent-Driven (recommended)** — dispatch fresh subagent per task, review between tasks, fast iteration.

**2. Inline Execution** — `executing-plans` with checkpoints.

Which approach?
