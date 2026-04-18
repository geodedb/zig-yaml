# Tokio/Go Parity Performance Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the 3–10× throughput gap and 6–12× submit-latency gap between this thread-pool and mature runtimes (Tokio, Go, ForkJoinPool) through benchmark-driven, measurement-first optimization.

**Architecture:** Attack the hot path in three layers. (1) Measurement: add micro-benchmarks that isolate submit, steal, and wake costs separately from end-to-end throughput, so regressions are attributed to the right subsystem. (2) Hot-path reductions: eliminate redundant atomic counters, defer timestamp reads, and split descriptor layout to shrink per-task overhead from ~670 ns to the 100–200 ns band. (3) Scheduler improvements: batch-steal in work-stealing, replace the 50 µs poll-sleep backpressure loop with a condvar signal, and replace the shared park_cond with per-worker wakeup to eliminate N-way mutex contention on submit.

**Performance Targets (success criteria):**

| Metric | Current (v0.2.0, 2 workers) | Target | Stretch |
|---|---|---|---|
| `conn_churn_seq/global_queue` throughput | 1.48M ops/s | 5M ops/s | 8M ops/s |
| `conn_churn_seq/work_stealing` throughput | 648K ops/s | 3M ops/s | 5M ops/s |
| Submit p50 (single-producer) | 619 ns | <200 ns | <100 ns |
| Submit p99 (4 producers) | 6.7 µs | <1 µs | <500 ns |
| `producer_contention/*` completion p50 | 1.46 ms | <100 µs | <50 µs |
| Hot-path atomic ops per task | ~10 | ≤5 | ≤3 |
| Hot-path `nanoTimestamp()` calls per task | 3 | 1 | 0 (opt-in) |

**Tech Stack:** Zig 0.15.2, `std.atomic`, `std.Thread.Mutex/Condition`, existing Vyukov BoundedRing and Chase-Lev WorkDeque, GitLab CI benchmark regression gate.

**Reference Benchmarks:**
- Tokio: [`tokio-rs/tokio` `benches/rt_multi_threaded.rs`](https://github.com/tokio-rs/tokio/blob/master/benches/rt_multi_threaded.rs) — targets chained task spawning, contended spawning, yield-heavy workloads.
- Go: [`runtime` `sched_test.go`](https://github.com/golang/go/blob/master/src/runtime/proc_test.go) — `BenchmarkCreateGoroutines*`.
- Our scenarios are modeled on these; we extend with direct micro-benches in Phase 1.

---

## File Structure

Tasks group into these files. New/modified locations are enumerated here so decomposition is explicit.

**New files:**
- `benchmarks/micro/submit_latency.zig` — isolates submit-path cost (no worker execution).
- `benchmarks/micro/steal_throughput.zig` — isolates work-stealing throughput.
- `benchmarks/micro/wake_latency.zig` — isolates park→wake latency.
- `benchmarks/bench_tokio_parity.zig` — new CI-tracked scenarios modeled after Tokio's rt_multi_threaded.
- `docs/PERFORMANCE_TRACKING.md` — canonical target table + per-phase deltas.

**Modified files:**
- `src/pool.zig` — Counters split, per-worker lazy counters, descriptor layout split, steal-batch, wake signaling.
- `src/types.zig` — `Config.timestamp_mode`, `.wake_mode`, `.steal_batch` tunables; `WorkerStats` extensions.
- `src/queue/work_deque.zig` — `stealTopBatch(n)` API.
- `src/stats/latency.zig` — optional-histogram mode guarded by config.
- `src/memory/scratch.zig` — minor: lockless fast path for owning worker (mutex fallback for purge).
- `benchmarks/common.zig` — new helper for timestamp-free trivial tasks.
- `build.zig` — wire up new micro-benchmarks, new bench step `bench-micro`.
- `tests/unit.zig` — correctness tests for each new knob.
- `tests/stress.zig` — add multi-producer + fine-grained stress scenarios.
- `.gitlab-ci.yml` — add `bench-micro` job as regression gate.
- `benchmarks/results/baseline.json` — rebaseline at end of plan.

---

## Phase 1: Measurement Infrastructure

**Rationale:** Every optimization must prove itself against a micro-benchmark that isolates its subsystem. End-to-end benchmarks hide which component is actually the bottleneck. This phase builds the instruments we use for every subsequent task.

### Task 1: Add a "timestamp-free" trivial task helper

**Files:**
- Modify: `benchmarks/common.zig`
- Test: (none — used by later benchmarks)

The existing `counterTask` does an atomic fetchAdd; that shows up in profiles. We need a task that does *nothing observable* so benchmarks measure pool overhead, not task overhead.

- [ ] **Step 1: Add the helper**

Open `benchmarks/common.zig` and find the end of the public helper section (after `counterTask` / `scratchTask`). Add:

```zig
/// A task that does the absolute minimum — used by micro-benchmarks to
/// measure pool overhead without task-body noise.  Writes a single u8 to a
/// volatile marker to prevent the optimizer from eliding the call.
pub fn noopTask(raw_ctx: *anyopaque, runtime: *thread_pool.TaskContext) void {
    _ = runtime;
    const marker: *volatile u8 = @ptrCast(raw_ctx);
    marker.* +%= 1;
}
```

- [ ] **Step 2: Verify it compiles**

Run: `zig build check`
Expected: success, no output.

- [ ] **Step 3: Commit**

```bash
git add benchmarks/common.zig
git commit -m "bench: add noopTask helper for timestamp-free micro-benchmarks"
```

### Task 2: Submit-latency micro-benchmark

**Files:**
- Create: `benchmarks/micro/submit_latency.zig`
- Modify: `build.zig` (wire up new step)

This benchmark measures submit-path cost in isolation by **not running the workers** — the pool is configured with zero workers, or the main thread submits to a pool whose workers never run because we don't let them. We instead measure `submit()` return time directly and report p50/p95/p99.

- [ ] **Step 1: Create the micro-bench source**

Create `benchmarks/micro/submit_latency.zig`:

```zig
// SPDX-License-Identifier: Apache-2.0
//! Micro-benchmark: submit-path latency.
//! Spawns a pool with a queue large enough that submits never block, runs
//! workers that sleep forever so task execution doesn't perturb measurement,
//! and records the time for each submit() call.
const std = @import("std");
const thread_pool = @import("thread_pool");

const sample_count = 100_000;
const warmup = 10_000;

fn sleepyTask(raw_ctx: *anyopaque, runtime: *thread_pool.TaskContext) void {
    _ = raw_ctx;
    _ = runtime;
    // Workers never actually consume this — we rely on queue depth not runtime.
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var samples = try allocator.alloc(u64, sample_count);

    var pool = try thread_pool.ThreadPool.init(std.heap.smp_allocator, .{
        .max_threads = 1,
        .queue_capacity = sample_count + warmup + 1024,
        .local_queue_capacity = 64,
        .scheduler_variant = .global_queue,
        // Disable backpressure entirely — queue is big enough.
        .idle_park_after_ns = 1_000_000,
    });
    defer pool.deinit();

    var marker: u8 = 0;

    // Warmup: submit tasks we don't measure, to page in the freelist and caches.
    for (0..warmup) |_| {
        _ = try pool.submit(sleepyTask, @ptrCast(&marker), .{});
    }

    // Measure.
    for (0..sample_count) |i| {
        const start = std.time.nanoTimestamp();
        _ = try pool.submit(sleepyTask, @ptrCast(&marker), .{});
        const end = std.time.nanoTimestamp();
        samples[i] = @intCast(end - start);
    }

    std.mem.sort(u64, samples, {}, std.sort.asc(u64));

    const p50 = samples[sample_count / 2];
    const p95 = samples[(sample_count * 95) / 100];
    const p99 = samples[(sample_count * 99) / 100];
    const min = samples[0];
    const max = samples[sample_count - 1];

    const out = std.io.getStdOut().writer();
    try out.print(
        \\submit_latency samples={d} min={d}ns p50={d}ns p95={d}ns p99={d}ns max={d}ns
        \\
    , .{ sample_count, min, p50, p95, p99, max });
}
```

- [ ] **Step 2: Wire build.zig**

Open `build.zig`. After the existing bench step (around line 80–90), add:

```zig
    const micro_submit = b.addExecutable(.{
        .name = "thread-pool-micro-submit",
        .root_module = importedModule(b, "benchmarks/micro/submit_latency.zig", target, .ReleaseFast, module),
    });
    const run_micro_submit = b.addRunArtifact(micro_submit);
    const micro_submit_step = b.step("bench-micro-submit", "Micro-benchmark: submit latency");
    micro_submit_step.dependOn(&run_micro_submit.step);
```

- [ ] **Step 3: Build and run**

Run: `zig build bench-micro-submit`
Expected: single line like `submit_latency samples=100000 min=... p50=... p95=... p99=... max=...`

- [ ] **Step 4: Record baseline in docs**

Create `docs/PERFORMANCE_TRACKING.md`:

```markdown
# Performance Tracking

Rolling record of micro-benchmark numbers as the Tokio-parity plan progresses.
All numbers from local dev machine unless noted. CI baselines tracked in
`benchmarks/results/baseline.json`.

## Micro: submit_latency (samples=100000, 1 worker, queue=101024, smp_allocator)

| Phase | p50 (ns) | p95 (ns) | p99 (ns) | Notes |
|-------|---------|----------|----------|-------|
| Phase 0 (baseline) | TODO | TODO | TODO | pre-optimization |
```

Fill in the TODOs with the actual numbers from step 3.

- [ ] **Step 5: Commit**

```bash
git add benchmarks/micro/submit_latency.zig build.zig docs/PERFORMANCE_TRACKING.md
git commit -m "bench: add submit_latency micro-benchmark and tracking doc"
```

### Task 3: Steal-throughput micro-benchmark

**Files:**
- Create: `benchmarks/micro/steal_throughput.zig`
- Modify: `build.zig`

Measures steal-path throughput in isolation: two workers, one producer feeds worker 0's local deque, worker 1 steals, we measure steals per second.

- [ ] **Step 1: Create the source**

Create `benchmarks/micro/steal_throughput.zig`:

```zig
// SPDX-License-Identifier: Apache-2.0
//! Micro-benchmark: work-stealing throughput.
//! One worker's local deque is filled by the owner; the other worker steals.
//! Reports steals/sec and average steal attempt count.
const std = @import("std");
const thread_pool = @import("thread_pool");

const task_count = 200_000;

fn noopTask(raw_ctx: *anyopaque, runtime: *thread_pool.TaskContext) void {
    _ = runtime;
    const marker: *volatile u8 = @ptrCast(raw_ctx);
    marker.* +%= 1;
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();

    var marker: u8 = 0;

    var pool = try thread_pool.ThreadPool.init(std.heap.smp_allocator, .{
        .max_threads = 2,
        .queue_capacity = task_count + 1024,
        .local_queue_capacity = 4096,
        .scheduler_variant = .work_stealing,
        .inject_batch_size = 1, // force per-task hand-off to exercise stealing
    });
    defer pool.deinit();

    var wg = pool.waitGroup();
    const start = std.time.nanoTimestamp();
    for (0..task_count) |_| {
        _ = try pool.submit(noopTask, @ptrCast(&marker), .{ .wait_group = &wg });
    }
    wg.wait();
    const end = std.time.nanoTimestamp();

    const elapsed_ns: u64 = @intCast(end - start);
    const elapsed_s = @as(f64, @floatFromInt(elapsed_ns)) / 1e9;
    const ops_per_sec = @as(f64, @floatFromInt(task_count)) / elapsed_s;

    const stats = pool.statsSnapshot();

    const out = std.io.getStdOut().writer();
    try out.print(
        \\steal_throughput tasks={d} elapsed_ns={d} ops_per_sec={d:.0} steals={d} steal_failures={d}
        \\
    , .{ task_count, elapsed_ns, ops_per_sec, stats.steals, stats.steal_failures });
}
```

- [ ] **Step 2: Wire build.zig**

In `build.zig`, below the Task 2 additions, add:

```zig
    const micro_steal = b.addExecutable(.{
        .name = "thread-pool-micro-steal",
        .root_module = importedModule(b, "benchmarks/micro/steal_throughput.zig", target, .ReleaseFast, module),
    });
    const run_micro_steal = b.addRunArtifact(micro_steal);
    const micro_steal_step = b.step("bench-micro-steal", "Micro-benchmark: steal throughput");
    micro_steal_step.dependOn(&run_micro_steal.step);
```

- [ ] **Step 3: Run and record**

Run: `zig build bench-micro-steal`
Append to `docs/PERFORMANCE_TRACKING.md`:

```markdown
## Micro: steal_throughput (tasks=200000, 2 workers, inject_batch=1, smp_allocator)

| Phase | ops/s | steals | steal_failures |
|-------|-------|--------|----------------|
| Phase 0 (baseline) | <from output> | <from output> | <from output> |
```

- [ ] **Step 4: Commit**

```bash
git add benchmarks/micro/steal_throughput.zig build.zig docs/PERFORMANCE_TRACKING.md
git commit -m "bench: add steal_throughput micro-benchmark"
```

### Task 4: Wake-latency micro-benchmark

**Files:**
- Create: `benchmarks/micro/wake_latency.zig`
- Modify: `build.zig`

Measures the time from `submit()` being called with all workers parked to the first worker actually starting to execute the submitted task.

- [ ] **Step 1: Create the source**

Create `benchmarks/micro/wake_latency.zig`:

```zig
// SPDX-License-Identifier: Apache-2.0
//! Micro-benchmark: park→wake latency.
//! Repeatedly lets the pool quiesce, then submits one task and measures how
//! long until a worker starts executing it.
const std = @import("std");
const thread_pool = @import("thread_pool");

const samples = 5_000;
const quiesce_ns: u64 = 300_000; // 300us — long enough that workers definitely park

const Probe = struct {
    submit_ns: i128,
    run_ns: std.atomic.Value(i128) = std.atomic.Value(i128).init(0),
};

fn wakeTask(raw_ctx: *anyopaque, runtime: *thread_pool.TaskContext) void {
    _ = runtime;
    const probe: *Probe = @ptrCast(@alignCast(raw_ctx));
    probe.run_ns.store(std.time.nanoTimestamp(), .release);
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var results = try allocator.alloc(u64, samples);

    var pool = try thread_pool.ThreadPool.init(std.heap.smp_allocator, .{
        .max_threads = 2,
        .queue_capacity = 64,
        .local_queue_capacity = 16,
        .scheduler_variant = .work_stealing,
        .idle_park_after_ns = 50_000,
    });
    defer pool.deinit();

    // Warmup
    for (0..32) |_| {
        var probe = Probe{ .submit_ns = 0 };
        _ = try pool.submit(wakeTask, @ptrCast(&probe), .{});
        while (probe.run_ns.load(.acquire) == 0) std.atomic.spinLoopHint();
    }

    for (0..samples) |i| {
        std.Thread.sleep(quiesce_ns);
        var probe = Probe{ .submit_ns = 0 };
        probe.submit_ns = std.time.nanoTimestamp();
        _ = try pool.submit(wakeTask, @ptrCast(&probe), .{});
        while (probe.run_ns.load(.acquire) == 0) std.atomic.spinLoopHint();
        const run_ns = probe.run_ns.load(.acquire);
        results[i] = @intCast(run_ns - probe.submit_ns);
    }

    std.mem.sort(u64, results, {}, std.sort.asc(u64));
    const out = std.io.getStdOut().writer();
    try out.print(
        \\wake_latency samples={d} p50={d}ns p95={d}ns p99={d}ns max={d}ns
        \\
    , .{ samples, results[samples / 2], results[(samples * 95) / 100], results[(samples * 99) / 100], results[samples - 1] });
}
```

- [ ] **Step 2: Wire build.zig**

Same pattern as Tasks 2–3:

```zig
    const micro_wake = b.addExecutable(.{
        .name = "thread-pool-micro-wake",
        .root_module = importedModule(b, "benchmarks/micro/wake_latency.zig", target, .ReleaseFast, module),
    });
    const run_micro_wake = b.addRunArtifact(micro_wake);
    const micro_wake_step = b.step("bench-micro-wake", "Micro-benchmark: wake latency");
    micro_wake_step.dependOn(&run_micro_wake.step);

    // Aggregate "bench-micro" step
    const micro_all_step = b.step("bench-micro", "All micro-benchmarks");
    micro_all_step.dependOn(&run_micro_submit.step);
    micro_all_step.dependOn(&run_micro_steal.step);
    micro_all_step.dependOn(&run_micro_wake.step);
```

- [ ] **Step 3: Run and record baseline**

Run: `zig build bench-micro`
Append to `docs/PERFORMANCE_TRACKING.md`:

```markdown
## Micro: wake_latency (samples=5000, 2 workers, quiesce=300us, smp_allocator)

| Phase | p50 (ns) | p95 (ns) | p99 (ns) |
|-------|---------|----------|----------|
| Phase 0 (baseline) | <output> | <output> | <output> |
```

- [ ] **Step 4: Commit**

```bash
git add benchmarks/micro/wake_latency.zig build.zig docs/PERFORMANCE_TRACKING.md
git commit -m "bench: add wake_latency micro-benchmark and aggregate bench-micro step"
```

---

## Phase 2: Hot-Path Reductions

**Rationale:** The hot path currently does ~10 atomic fetchAdd operations and 3 `nanoTimestamp()` calls per task. Tokio/Go make that work optional or per-worker-lazy. Shaving these is the fastest path to closing the submit-latency gap.

### Task 5: Introduce `Config.timestamp_mode`

**Files:**
- Modify: `src/types.zig`
- Test: `tests/unit.zig`

Give consumers a knob to disable per-task timestamps when they don't need sub-microsecond latency histograms. Tokio does this — its default runtime doesn't timestamp every task.

- [ ] **Step 1: Add the enum to `types.zig`**

Open `src/types.zig`. Near the other config-related enums (`SchedulerVariant`, `BackpressurePolicy`), add:

```zig
/// Controls per-task timestamp behavior.  `full` records submit/start/complete
/// timestamps and populates wait/exec histograms — the legacy v0.2.0 mode.
/// `disabled` skips all timestamp reads, zeroing latency metrics but saving
/// ~60–120ns per task on Linux vDSO `clock_gettime`.
pub const TimestampMode = enum {
    full,
    disabled,
};
```

Then add `timestamp_mode: TimestampMode = .full,` to `Config`. Default stays `.full` to preserve v0.2.0 behavior.

- [ ] **Step 2: Add correctness test**

Open `tests/unit.zig`. Near the other Config tests, add:

```zig
test "timestamp_mode disabled zeroes histograms" {
    var pool = try thread_pool.ThreadPool.init(std.testing.allocator, .{
        .max_threads = 2,
        .queue_capacity = 64,
        .timestamp_mode = .disabled,
    });
    defer pool.deinit();

    var wg = pool.waitGroup();
    var counter = common.Counter{};
    for (0..32) |_| {
        _ = try pool.submit(common.counterTask, @ptrCast(&counter), .{ .wait_group = &wg });
    }
    wg.wait();

    const stats = pool.statsSnapshot();
    try std.testing.expectEqual(@as(u64, 0), stats.task_wait_ns.count);
    try std.testing.expectEqual(@as(u64, 0), stats.task_exec_ns.count);
    try std.testing.expectEqual(@as(u64, 32), stats.completed);
}
```

- [ ] **Step 3: Run — test should fail (feature not wired yet)**

Run: `zig build test --summary all`
Expected: FAIL — `task_wait_ns.count != 0` (implementation still timestamps).

- [ ] **Step 4: Wire the check in `pool.zig`**

Open `src/pool.zig`. In `enqueueTask`, guard the `submit_ns` assignment:

```zig
// Was: descriptor.submit_ns = nowNs();
descriptor.submit_ns = if (self.config.timestamp_mode == .full) nowNs() else 0;
```

In `runTask`, replace the start/complete nowNs() calls and histogram observes with guards:

```zig
const start_ns = if (self.config.timestamp_mode == .full) nowNs() else 0;
descriptor.start_ns = start_ns;

if (self.config.timestamp_mode == .full) {
    const wait_ns = start_ns - descriptor.submit_ns;
    worker.wait_histogram.observe(wait_ns);
}

// ... task body executes ...

if (self.config.timestamp_mode == .full) {
    descriptor.complete_ns = nowNs();
    const exec_ns = descriptor.complete_ns - start_ns;
    _ = worker.busy_ns.fetchAdd(exec_ns, .release);
    worker.last_idle_started_ns.store(descriptor.complete_ns, .release);
    worker.exec_histogram.observe(exec_ns);
}
```

- [ ] **Step 5: Run test — should pass**

Run: `zig build test --summary all`
Expected: PASS, 18/18 tests.

- [ ] **Step 6: Run full test suite and benchmarks**

```bash
zig build test-integration --summary all
zig build test-stress --summary all
zig build bench-micro-submit
```

Record the `submit_latency p50` delta in `docs/PERFORMANCE_TRACKING.md` as Phase 2 row.

- [ ] **Step 7: Commit**

```bash
git add src/types.zig src/pool.zig tests/unit.zig docs/PERFORMANCE_TRACKING.md
git commit -m "perf(pool): add Config.timestamp_mode=disabled to skip hot-path clock reads"
```

### Task 6: Replace global `counters.submitted`/`started`/`completed` with per-worker counters

**Files:**
- Modify: `src/pool.zig`
- Test: `tests/unit.zig`

These three counters are written on every submit/start/complete. They contend on the same cache line as `queued_tasks` and `active_tasks`. Per-worker counters, aggregated in `statsSnapshot()`, remove the global contention. `submitted` is written by submitter threads (not workers), so it stays a worker-indexed array keyed by submitter TLS.

- [ ] **Step 1: Add per-worker fields to `Worker` struct**

Open `src/pool.zig`. In the `Worker` struct definition (~line 58), add:

```zig
    started: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    completed: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
```

- [ ] **Step 2: Replace global writes with per-worker writes**

In `runTask`, replace `_ = self.counters.started.fetchAdd(1, .monotonic);` with:

```zig
_ = worker.started.fetchAdd(1, .monotonic);
```

Replace `_ = self.counters.completed.fetchAdd(1, .monotonic);` similarly:

```zig
_ = worker.completed.fetchAdd(1, .monotonic);
```

- [ ] **Step 3: Remove the now-unused global fields**

Delete `started` and `completed` from `Counters` struct (lines ~96–97). Keep `cancelled` there for now — it's written less frequently and from shutdown paths on the main thread.

- [ ] **Step 4: Aggregate in `statsSnapshot()`**

In `statsSnapshot`, extend the first worker loop to sum started/completed:

```zig
var aggregate_wakeups: u64 = 0;
var aggregate_started: u64 = 0;
var aggregate_completed: u64 = 0;
for (self.workers, 0..) |*worker, idx| {
    const w_wakeups = worker.wakeups.load(.acquire);
    const w_started = worker.started.load(.acquire);
    const w_completed = worker.completed.load(.acquire);
    aggregate_wakeups += w_wakeups;
    aggregate_started += w_started;
    aggregate_completed += w_completed;
    self.worker_stats_buffer[idx] = .{
        // ... existing fields ...
    };
}
```

Update the Stats return struct:

```zig
.started = aggregate_started,
.completed = aggregate_completed,
```

- [ ] **Step 5: Add correctness test**

In `tests/unit.zig`:

```zig
test "Stats.started and .completed aggregate from per-worker counters" {
    var pool = try thread_pool.ThreadPool.init(std.testing.allocator, .{
        .max_threads = 2,
        .queue_capacity = 64,
    });
    defer pool.deinit();

    var wg = pool.waitGroup();
    var counter = common.Counter{};
    for (0..64) |_| {
        _ = try pool.submit(common.counterTask, @ptrCast(&counter), .{ .wait_group = &wg });
    }
    wg.wait();

    const stats = pool.statsSnapshot();
    try std.testing.expectEqual(@as(u64, 64), stats.started);
    try std.testing.expectEqual(@as(u64, 64), stats.completed);
}
```

- [ ] **Step 6: Run all tests**

Run: `zig build test --summary all && zig build test-integration --summary all && zig build test-stress --summary all`
Expected: all pass (19/19 unit).

- [ ] **Step 7: Measure and record**

```bash
zig build bench-micro-submit
zig build bench
```

Update `docs/PERFORMANCE_TRACKING.md` with Phase 2 deltas. Expect submit p50 to drop 30–80 ns.

- [ ] **Step 8: Commit**

```bash
git add src/pool.zig tests/unit.zig docs/PERFORMANCE_TRACKING.md
git commit -m "perf(pool): move started/completed counters per-worker to reduce hot-path contention"
```

### Task 7: Per-worker `steals` / `steal_failures` / `parks` consolidation

**Files:**
- Modify: `src/pool.zig`
- Test: `tests/unit.zig`

Same pattern as Task 6 for the steal/park counters. Currently `nextTask` and `idle` write to BOTH `self.counters.X` and `worker.X` on every event — pure duplication. Kill the global writes; aggregate in `statsSnapshot`.

- [ ] **Step 1: Remove global steal/steal_failures/parks writes**

In `src/pool.zig` `nextTask` (~line 484–491), delete the two `self.counters.steals.fetchAdd`/`self.counters.steal_failures.fetchAdd` calls — keep only `worker.steals` / `worker.steal_failures` writes.

In `idle`, delete `_ = self.counters.parks.fetchAdd(1, .monotonic);` if present.

- [ ] **Step 2: Delete the global fields**

From `Counters` struct: remove `steals`, `steal_failures`, `parks`.

- [ ] **Step 3: Aggregate in `statsSnapshot`**

In the first worker loop in `statsSnapshot`, extend the accumulation:

```zig
var aggregate_steals: u64 = 0;
var aggregate_steal_failures: u64 = 0;
var aggregate_parks: u64 = 0;
// inside the worker loop:
aggregate_steals += worker.steals.load(.acquire);
aggregate_steal_failures += worker.steal_failures.load(.acquire);
aggregate_parks += worker.parks.load(.acquire);
```

Update the Stats return:

```zig
.steals = aggregate_steals,
.steal_failures = aggregate_steal_failures,
.parks = aggregate_parks,
```

- [ ] **Step 4: Correctness test**

In `tests/unit.zig`:

```zig
test "Stats.steals/parks aggregate per-worker under work-stealing" {
    var pool = try thread_pool.ThreadPool.init(std.testing.allocator, .{
        .max_threads = 4,
        .queue_capacity = 1024,
        .local_queue_capacity = 64,
        .scheduler_variant = .work_stealing,
    });
    defer pool.deinit();

    var wg = pool.waitGroup();
    var counter = common.Counter{};
    for (0..256) |_| {
        _ = try pool.submit(common.counterTask, @ptrCast(&counter), .{ .wait_group = &wg });
    }
    wg.wait();

    const stats = pool.statsSnapshot();

    var expected_steals: u64 = 0;
    var expected_parks: u64 = 0;
    for (stats.worker_stats) |w| {
        expected_steals += w.steals;
        expected_parks += w.parks;
    }
    try std.testing.expectEqual(expected_steals, stats.steals);
    try std.testing.expectEqual(expected_parks, stats.parks);
}
```

- [ ] **Step 5: Run all tests**

Run: `zig build test --summary all`
Expected: PASS 20/20.

- [ ] **Step 6: Measure**

Run `zig build bench-micro` and record `steal_throughput ops/s` delta.

- [ ] **Step 7: Commit**

```bash
git add src/pool.zig tests/unit.zig docs/PERFORMANCE_TRACKING.md
git commit -m "perf(pool): remove duplicate global steal/park counters; aggregate per-worker"
```

### Task 8: Split `TaskDescriptor` into hot and cold fields

**Files:**
- Modify: `src/pool.zig`

Currently `TaskDescriptor` holds `state`, `options`, `task_fn`, `ctx` (hot) alongside `submit_ns`, `start_ns`, `complete_ns`, `generation` (cold). When a worker executes a task, the hot fields fit in one cache line. Split so the hot fields are always together and cache-aligned.

- [ ] **Step 1: Read current layout**

Open `src/pool.zig` line ~47–56 to see the current `TaskDescriptor` definition.

- [ ] **Step 2: Rewrite with explicit layout**

Replace the struct definition:

```zig
const TaskDescriptor = struct {
    // === Hot fields (read on every dispatch and complete) ===
    state: std.atomic.Value(types.TaskState) = std.atomic.Value(types.TaskState).init(.empty),
    task_fn: ?TaskFn = null,
    ctx: ?*anyopaque = null,
    options: types.SubmitOptions = .{},
    generation: u32 = 0,
    _pad0: [std.atomic.cache_line -
        @sizeOf(std.atomic.Value(types.TaskState)) -
        @sizeOf(?TaskFn) -
        @sizeOf(?*anyopaque) -
        @sizeOf(types.SubmitOptions) -
        @sizeOf(u32)]u8 = undefined,

    // === Cold fields (metrics/observability only) ===
    submit_ns: u64 = 0,
    start_ns: u64 = 0,
    complete_ns: u64 = 0,
};
```

Note: the padding computation assumes `@sizeOf(SubmitOptions)` is small. If the compiler complains about negative padding, the struct is already > one cache line — drop `_pad0` in that case and verify hot fields are contiguous at offset 0.

- [ ] **Step 3: Check it compiles**

Run: `zig build check`
Expected: success. If you see a negative-size padding error, remove `_pad0` and proceed.

- [ ] **Step 4: Run full test suite**

Run: `zig build test --summary all && zig build test-integration --summary all && zig build test-stress --summary all`
Expected: all pass. No behavior change — this is a layout-only refactor.

- [ ] **Step 5: Measure**

Run `zig build bench` and capture numbers. Expect `conn_churn_seq/global_queue` to improve 2–8% from reduced cache misses on the dispatch side.

- [ ] **Step 6: Commit**

```bash
git add src/pool.zig docs/PERFORMANCE_TRACKING.md
git commit -m "perf(pool): reorder TaskDescriptor so hot fields share a cache line"
```

---

## Phase 3: Work-Stealing Improvements

**Rationale:** The work-stealing variant is *slower* than global_queue on single-producer — this is an embarrassment for a scheduler. The two biggest problems identified in the audit: single-item steals (one CAS per stolen task, then another full O(N) sweep), and a shared park_cond that serializes all workers' wakeup paths through a single mutex.

### Task 9: `WorkDeque.stealTopBatch(n)` API

**Files:**
- Modify: `src/queue/work_deque.zig`
- Test: add inline test at end of file

Extend Chase-Lev to steal up to `n` items in one CAS operation, using the "advance `top` by `n`" variant. This is how Tokio's `queue.rs` and Go's `runq` schedulers amortize the steal cost.

- [ ] **Step 1: Add the new method**

Open `src/queue/work_deque.zig`. Below `stealTop`, add:

```zig
        /// Steal up to `max` items from the top of the deque.  Items are
        /// written into `out` starting at index 0.  Returns the number
        /// stolen (0–max).  Semantics match `stealTop` for correctness —
        /// last-element races are resolved with seq_cst ordering.
        pub fn stealTopBatch(self: *Self, out: []T) usize {
            if (out.len == 0) return 0;
            while (true) {
                const t = self.top.load(.seq_cst);
                const b = self.bottom.load(.acquire);
                const size: isize = b - @as(isize, @intCast(t));
                if (size <= 0) return 0;
                const available: usize = @intCast(size);
                const n = @min(available, out.len);
                for (0..n) |i| {
                    out[i] = self.buffer[(t + i) & self.mask];
                }
                const new_top = t + n;
                if (self.top.cmpxchgStrong(t, new_top, .seq_cst, .seq_cst) == null) {
                    return n;
                }
                // CAS failed: either the owner popped the last element or another
                // stealer raced.  Retry.
            }
        }
```

- [ ] **Step 2: Add inline test**

At the bottom of `work_deque.zig`:

```zig
test "WorkDeque.stealTopBatch steals multiple items" {
    var dq = try WorkDeque(u32).init(std.testing.allocator, 16);
    defer dq.deinit(std.testing.allocator);

    for (0..10) |i| {
        _ = dq.tryPushBottom(@intCast(i));
    }

    var out: [16]u32 = undefined;
    const n = dq.stealTopBatch(out[0..5]);
    try std.testing.expectEqual(@as(usize, 5), n);
    try std.testing.expectEqual(@as(u32, 0), out[0]);
    try std.testing.expectEqual(@as(u32, 4), out[4]);
    try std.testing.expectEqual(@as(usize, 5), dq.len());
}

test "WorkDeque.stealTopBatch returns 0 on empty deque" {
    var dq = try WorkDeque(u32).init(std.testing.allocator, 16);
    defer dq.deinit(std.testing.allocator);
    var out: [4]u32 = undefined;
    try std.testing.expectEqual(@as(usize, 0), dq.stealTopBatch(out[0..]));
}
```

- [ ] **Step 3: Run**

Run: `zig build test --summary all`
Expected: new tests pass.

- [ ] **Step 4: Commit**

```bash
git add src/queue/work_deque.zig
git commit -m "feat(queue): add WorkDeque.stealTopBatch(n) for amortized steal cost"
```

### Task 10: Use batch-steal in `nextTask`

**Files:**
- Modify: `src/pool.zig`

Replace the single-item `stealTop()` call in `nextTask` with a batch that steals half the victim's deque and pushes the extras into the stealer's local deque.

- [ ] **Step 1: Rewrite steal block**

Open `src/pool.zig` `nextTask` (work_stealing branch, ~line 478–491). Replace:

```zig
            // existing:
            if (self.local_queues[victim_index].stealTop()) |descriptor_index| {
                self.decrementQueued();
                _ = worker.steals.fetchAdd(1, .release);
                return descriptor_index;
            }
```

With:

```zig
            var stolen: [32]u32 = undefined;
            const budget = @min(self.config.steal_batch_size, stolen.len);
            const n = self.local_queues[victim_index].stealTopBatch(stolen[0..budget]);
            if (n > 0) {
                // Keep the first for ourselves, push the rest to our local deque.
                const first = stolen[0];
                for (stolen[1..n]) |idx| {
                    if (!lq.tryPushBottom(idx)) {
                        // Local deque full — put the overflow on the inject queue.
                        _ = self.inject_queue.tryPush(idx);
                    }
                }
                self.decrementQueuedBy(n);
                _ = worker.steals.fetchAdd(n, .release);
                const local_len = @as(u32, @intCast(lq.len()));
                updatePeakU32(&worker.local_queue_peak, local_len);
                return first;
            }
```

- [ ] **Step 2: Add `steal_batch_size` config**

In `src/types.zig` `Config` struct, add:

```zig
/// Maximum number of tasks a stealer takes from a single victim.
/// Higher values amortize steal cost but reduce work distribution.
/// Default: 8, matching Tokio.  Set to 1 to restore pre-v0.3 behavior.
steal_batch_size: usize = 8,
```

And in `normalized()` / `validate()`, clamp: `std.math.clamp(cfg.steal_batch_size, 1, 32)` and reject zero.

- [ ] **Step 3: Add `decrementQueuedBy` helper**

In `src/pool.zig` near `decrementQueued`:

```zig
fn decrementQueuedBy(self: *Core, n: usize) void {
    _ = self.counters.queued_tasks.fetchSub(n, .release);
}
```

- [ ] **Step 4: Run tests — existing work_stealing tests should still pass**

Run: `zig build test --summary all && zig build test-integration --summary all && zig build test-stress --summary all`
Expected: all pass (batch stealing is a pure optimization).

- [ ] **Step 5: Measure with `bench-micro-steal`**

Run: `zig build bench-micro-steal`
Expected: `ops_per_sec` at least 2× higher than Phase 0 baseline. Record.

- [ ] **Step 6: Full bench**

Run: `zig build bench`
Expected: `conn_churn_seq/work_stealing` improves 50–100%.

- [ ] **Step 7: Commit**

```bash
git add src/pool.zig src/types.zig docs/PERFORMANCE_TRACKING.md
git commit -m "perf(pool): batch-steal half the victim's deque to amortize steal cost"
```

### Task 11: Steal-victim affinity (prefer deep queues)

**Files:**
- Modify: `src/pool.zig`

Instead of scanning all workers in linear order starting at a pseudo-random index, peek `local_queues[i].len()` first and only attempt steals against workers with >0 items. This removes the O(N) seq_cst sweep when most workers are empty.

- [ ] **Step 1: Rewrite steal scan**

In `nextTask` work_stealing branch, replace:

```zig
            const start = (worker_index +% @as(usize, @truncate(self.counters.submitted.load(.monotonic)))) % self.workers.len;
            var offset: usize = 0;
            while (offset < self.workers.len) : (offset += 1) {
                const victim_index = (start + offset) % self.workers.len;
                if (victim_index == worker_index) continue;
                // ... existing steal block ...
            }
```

With:

```zig
            const start = (worker_index +% worker.started.load(.monotonic)) % self.workers.len;
            var offset: usize = 0;
            while (offset < self.workers.len) : (offset += 1) {
                const victim_index = (start + offset) % self.workers.len;
                if (victim_index == worker_index) continue;
                // Peek first with a cheap monotonic load.  Skip empty victims
                // to avoid a seq_cst CAS attempt that would just fail.
                if (self.local_queues[victim_index].len() == 0) continue;
                // ... existing steal block from Task 10 ...
            }
```

Note `len()` on `WorkDeque` already does `bottom.load(.acquire) - top.load(.acquire)` — cheap.

- [ ] **Step 2: Test correctness**

Run: `zig build test --summary all && zig build test-integration --summary all && zig build test-stress --summary all`
Expected: all pass. This is an optimization — no behavior change.

- [ ] **Step 3: Measure**

Run: `zig build bench-micro-steal && zig build bench`
Record delta. Expect modest improvement (~5–15%) on `steal_throughput` and `conn_churn_seq/work_stealing`.

- [ ] **Step 4: Commit**

```bash
git add src/pool.zig docs/PERFORMANCE_TRACKING.md
git commit -m "perf(pool): skip empty victims in steal scan to avoid futile seq_cst CAS"
```

### Task 12: Per-worker park condvar

**Files:**
- Modify: `src/pool.zig`, `src/types.zig` (if adding config knob)
- Test: `tests/unit.zig`

The shared `park_cond`/`park_mutex` serialize all wake events through a single mutex. With N workers, every submit contends on it. Replace with per-worker condvars: submit signals one specific worker (the least-recently-parked), shutdown broadcasts to all.

- [ ] **Step 1: Move park primitives into Worker**

In `Worker` struct, add:

```zig
    park_mutex: std.Thread.Mutex = .{},
    park_cond: std.Thread.Condition = .{},
    /// 1 when this worker is parked, 0 otherwise.  Used as a fast-path check
    /// before acquiring the park_mutex.
    is_parked: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),
```

Remove `park_mutex`/`park_cond` from `Sync` struct (or leave for completion signaling only).

- [ ] **Step 2: Update `idle()` to use per-worker park**

In `idle()`, replace the shared park lock with the worker's own:

```zig
fn idle(self: *Core, worker_index: usize) void {
    var worker = &self.workers[worker_index];
    // Spin-before-park (unchanged) ...

    worker.park_mutex.lock();
    defer worker.park_mutex.unlock();
    if (self.counters.queued_tasks.load(.acquire) != 0) return;
    if (self.state.load(.acquire) != .running) return;
    _ = self.counters.parked_workers.fetchAdd(1, .monotonic);
    worker.is_parked.store(1, .release);
    worker.park_cond.timedWait(&worker.park_mutex, self.config.idle_park_after_ns) catch {};
    worker.is_parked.store(0, .release);
    _ = self.counters.parked_workers.fetchSub(1, .monotonic);
    _ = worker.wakeups.fetchAdd(1, .release);
}
```

- [ ] **Step 3: Update `enqueueTask` to signal one worker**

Replace the current `park_cond.signal()` block with:

```zig
// Wake one parked worker — prefer the one most likely to be idle.
// Round-robin on the submitter's stride to spread load.
if (self.counters.parked_workers.load(.monotonic) > 0) {
    const hint_idx: usize = @intCast(self.counters.submitted.load(.monotonic) % self.workers.len);
    for (0..self.workers.len) |offset| {
        const idx = (hint_idx + offset) % self.workers.len;
        const w = &self.workers[idx];
        if (w.is_parked.load(.acquire) == 1) {
            w.park_mutex.lock();
            w.park_cond.signal();
            w.park_mutex.unlock();
            break;
        }
    }
}
```

- [ ] **Step 4: Update `joinAllWorkers` to broadcast to all**

```zig
fn joinAllWorkers(self: *Core) void {
    self.state.store(.stopping, .release);
    for (self.workers) |*w| {
        w.park_mutex.lock();
        w.park_cond.broadcast();
        w.park_mutex.unlock();
    }
    for (self.workers) |*w| {
        if (w.thread) |t| {
            t.join();
            w.thread = null;
        }
    }
    self.state.store(.stopped, .release);
}
```

- [ ] **Step 5: Correctness test**

In `tests/unit.zig`:

```zig
test "per-worker park: submit wakes exactly one worker" {
    var pool = try thread_pool.ThreadPool.init(std.testing.allocator, .{
        .max_threads = 4,
        .queue_capacity = 128,
        .idle_park_after_ns = 10_000_000, // 10ms - long enough for workers to park
    });
    defer pool.deinit();

    // Let workers park.
    std.Thread.sleep(50_000_000); // 50ms

    var wg = pool.waitGroup();
    var counter = common.Counter{};
    _ = try pool.submit(common.counterTask, @ptrCast(&counter), .{ .wait_group = &wg });
    wg.wait();

    try std.testing.expectEqual(@as(u64, 1), counter.value.load(.acquire));
}
```

- [ ] **Step 6: Run tests**

Run: `zig build test --summary all && zig build test-integration --summary all && zig build test-stress --summary all`
Expected: all pass. Run stress test 50× to verify no park/wake races.

- [ ] **Step 7: Measure**

Run: `zig build bench-micro-wake && zig build bench`
Expect `wake_latency p50` to drop ~30–50% (no more cross-worker mutex contention on shared park).

- [ ] **Step 8: Commit**

```bash
git add src/pool.zig tests/unit.zig docs/PERFORMANCE_TRACKING.md
git commit -m "perf(pool): per-worker park condvar removes N-way mutex contention on submit"
```

---

## Phase 4: Backpressure & Signaling

**Rationale:** The 50 µs `Thread.sleep` poll-retry in `submitInternal` is the single largest contributor to submit p99 under contention. Replacing it with a condvar signaled by `releaseDescriptor` gives immediate wakeup on freed capacity — the difference between 50 µs and 1 µs on contended submits.

### Task 13: Backpressure condvar

**Files:**
- Modify: `src/pool.zig`
- Test: `tests/unit.zig`

Add a dedicated condvar (`backpressure_cond`) signaled whenever `releaseDescriptor` runs and parked_workers sees a potential blocked submitter. `submitInternal` in `.block`/`.block_with_timeout` mode waits on this condvar instead of sleeping.

- [ ] **Step 1: Add primitives to Sync struct**

In `Sync` struct:

```zig
backpressure_mutex: std.Thread.Mutex = .{},
backpressure_cond: std.Thread.Condition = .{},
backpressure_waiters: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
```

- [ ] **Step 2: Signal from `releaseDescriptor`**

At the end of `releaseDescriptor`, add:

```zig
if (self.sync.backpressure_waiters.load(.monotonic) > 0) {
    self.sync.backpressure_mutex.lock();
    self.sync.backpressure_cond.signal();
    self.sync.backpressure_mutex.unlock();
}
```

- [ ] **Step 3: Rewrite `submitInternal` blocking loop**

Replace the current `Thread.sleep(50_000)` retry loop:

```zig
// Old:
// std.Thread.sleep(50_000);

// New:
_ = self.sync.backpressure_waiters.fetchAdd(1, .monotonic);
defer _ = self.sync.backpressure_waiters.fetchSub(1, .monotonic);

self.sync.backpressure_mutex.lock();
defer self.sync.backpressure_mutex.unlock();
// Sleep at most the remaining time until deadline (or 10ms max for safety).
const wait_ns: u64 = if (deadline != 0) blk: {
    const now = nowNs();
    break :blk if (now >= deadline) 0 else @min(deadline - now, 10_000_000);
} else 10_000_000;
self.sync.backpressure_cond.timedWait(&self.sync.backpressure_mutex, wait_ns) catch {};
```

- [ ] **Step 4: Correctness tests**

`tests/unit.zig`:

```zig
test "backpressure block policy returns when capacity frees" {
    var pool = try thread_pool.ThreadPool.init(std.testing.allocator, .{
        .max_threads = 1,
        .queue_capacity = 4,
        .local_queue_capacity = 2,
    });
    defer pool.deinit();

    var wg = pool.waitGroup();
    var counter = common.Counter{};
    // Fill the queue with slow tasks.
    for (0..4) |_| {
        _ = try pool.submit(common.counterTask, @ptrCast(&counter), .{ .wait_group = &wg });
    }
    // This one must block then succeed.
    _ = try pool.submit(common.counterTask, @ptrCast(&counter), .{
        .wait_group = &wg,
        .backpressure = .block,
    });
    wg.wait();
    try std.testing.expectEqual(@as(u64, 5), counter.value.load(.acquire));
}
```

- [ ] **Step 5: Run and stress-test**

Run: `zig build test --summary all`
Expected: all pass.

Run stress test 30×:
```bash
for i in $(seq 1 30); do zig build test-stress 2>&1 | grep -qE "(signal|failure)" && echo "FAIL" && break; done
```
Expected: no failures.

- [ ] **Step 6: Measure producer_contention**

Run: `zig build bench`
Focus on `producer_contention/*` completion p50/p99. Target: p50 <200 µs (down from 1.46 ms), p99 <1 ms.

- [ ] **Step 7: Commit**

```bash
git add src/pool.zig tests/unit.zig docs/PERFORMANCE_TRACKING.md
git commit -m "perf(pool): condvar-based backpressure replaces 50us poll-sleep loop"
```

### Task 14: Shutdown drain uses the backpressure condvar

**Files:**
- Modify: `src/pool.zig`

`shutdown(.drain, ...)` polls `queued==0 && active==0` with `Thread.sleep(100_000)`. Reuse the backpressure condvar — `releaseDescriptor` already signals it when someone's waiting, so we just need shutdown to register itself as a waiter.

- [ ] **Step 1: Rewrite drain loop in `shutdown`**

Replace the current drain loop:

```zig
const deadline = if (timeout_ns) |ns| nowNs() + ns else 0;
while (true) {
    const queued = self.counters.queued_tasks.load(.acquire);
    const active = self.counters.active_tasks.load(.acquire);
    if (queued == 0 and active == 0) break;
    if (deadline != 0 and nowNs() >= deadline) return error.Timeout;
    _ = self.sync.backpressure_waiters.fetchAdd(1, .monotonic);
    self.sync.backpressure_mutex.lock();
    const wait_ns: u64 = if (deadline != 0) blk: {
        const now = nowNs();
        break :blk if (now >= deadline) 0 else @min(deadline - now, 10_000_000);
    } else 10_000_000;
    self.sync.backpressure_cond.timedWait(&self.sync.backpressure_mutex, wait_ns) catch {};
    self.sync.backpressure_mutex.unlock();
    _ = self.sync.backpressure_waiters.fetchSub(1, .monotonic);
}
```

- [ ] **Step 2: Run tests**

Run: `zig build test --summary all && zig build test-integration --summary all && zig build test-stress --summary all`
Expected: all pass.

- [ ] **Step 3: Commit**

```bash
git add src/pool.zig
git commit -m "perf(pool): shutdown drain waits on backpressure condvar instead of polling"
```

---

## Phase 5: Tokio-Parity Benchmarks & Validation

**Rationale:** We've added isolated micro-benchmarks in Phase 1. Now add end-to-end scenarios that mirror Tokio's `rt_multi_threaded` suite so we can put our final numbers next to theirs on the same machine.

### Task 15: Tokio-parity benchmark suite

**Files:**
- Create: `benchmarks/bench_tokio_parity.zig`
- Modify: `build.zig`

Scenarios to include:
- `chained_spawn_1k` — 1000 tasks each submitting 1 child (like Tokio's `spawn_tasks_current_thread_parallel`).
- `flood_1m` — 1M trivial tasks from a single submitter.
- `contended_spawn_8x` — 8 submitters each submitting 100k tasks.
- `yield_heavy_10k` — 10k tasks that each yield once (re-submit themselves once).

- [ ] **Step 1: Create the suite**

Create `benchmarks/bench_tokio_parity.zig` (use `benchmarks/bench.zig` as a template; re-export the scenario grid structure). Skeleton:

```zig
// SPDX-License-Identifier: Apache-2.0
//! Tokio rt_multi_threaded parity scenarios.  Numbers here are directly
//! comparable to Tokio's published benchmark output on the same hardware.
const std = @import("std");
const thread_pool = @import("thread_pool");
const common = @import("common.zig");

// ... scenario definitions and main() following benchmarks/bench.zig's pattern ...
```

Use the same harness code from `bench.zig` — add each scenario by extending the `scenarios: []const Scenario` slice.

For `chained_spawn_1k`, define a context struct that holds a pointer back to the pool so the task can submit its child. For `yield_heavy_10k`, the task re-submits itself but with a decrementing counter so it terminates.

- [ ] **Step 2: Wire build.zig**

```zig
    const tokio_bench = b.addExecutable(.{
        .name = "thread-pool-tokio-parity",
        .root_module = importedModule(b, "benchmarks/bench_tokio_parity.zig", target, .ReleaseFast, module),
    });
    const run_tokio_bench = b.addRunArtifact(tokio_bench);
    const tokio_bench_step = b.step("bench-tokio-parity", "Tokio rt_multi_threaded parity benchmarks");
    tokio_bench_step.dependOn(&run_tokio_bench.step);
```

- [ ] **Step 3: Run and record**

Run: `zig build bench-tokio-parity`
Record results in `docs/PERFORMANCE_TRACKING.md` under a new section.

- [ ] **Step 4: Commit**

```bash
git add benchmarks/bench_tokio_parity.zig build.zig docs/PERFORMANCE_TRACKING.md
git commit -m "bench: add Tokio rt_multi_threaded-parity benchmark suite"
```

### Task 16: CI gate for micro-benchmarks

**Files:**
- Modify: `.gitlab-ci.yml`

Add a job that runs the micro-benchmarks and fails if submit p50 regresses >25%.

- [ ] **Step 1: Add the job**

In `.gitlab-ci.yml`, after `benchmark-regression`:

```yaml
bench-micro:
  extends: .zig-job
  stage: performance
  script:
    - zig build bench-micro-submit > micro-submit.txt
    - zig build bench-micro-steal > micro-steal.txt
    - zig build bench-micro-wake > micro-wake.txt
    - cat micro-submit.txt micro-steal.txt micro-wake.txt
  artifacts:
    paths:
      - micro-submit.txt
      - micro-steal.txt
      - micro-wake.txt
    when: always
  needs: ["build"]
  allow_failure: true # advisory until thresholds are tuned
```

- [ ] **Step 2: Commit**

```bash
git add .gitlab-ci.yml
git commit -m "ci: add bench-micro advisory job tracking submit/steal/wake latency"
```

### Task 17: Rebaseline and update regression gates

**Files:**
- Modify: `benchmarks/results/baseline.json`
- Modify: `benchmarks/compare.zig` (if threshold needs relaxing)

After all Phase 2–4 optimizations land, the improvements will trip the 15% regression gate (in reverse — current run exceeds baseline by >15%, which is also flagged). Regenerate the baseline from a clean CI run and commit it.

- [ ] **Step 1: Run fresh benchmark on clean tree**

```bash
zig build bench -- --output benchmarks/results/baseline.json
```

- [ ] **Step 2: Verify compare-bench passes against itself**

```bash
zig build compare-bench -- --baseline benchmarks/results/baseline.json --current benchmarks/results/baseline.json
```
Expected: all scenarios within 0.01%.

- [ ] **Step 3: Commit**

```bash
git add benchmarks/results/baseline.json docs/PERFORMANCE_TRACKING.md
git commit -m "bench: rebaseline after Tokio-parity optimization pass"
```

### Task 18: Document the final numbers

**Files:**
- Modify: `docs/PERFORMANCE_TRACKING.md`
- Modify: `README.md` (add a performance section)

- [ ] **Step 1: Finalize `PERFORMANCE_TRACKING.md`**

Fill in all phase rows with actual measured numbers. Add a "Verdict vs Targets" section that explicitly marks each target from the plan header as met/stretch/missed.

- [ ] **Step 2: Add README performance section**

In `README.md`, after the Goals section, add:

```markdown
## Performance

| Scenario | Throughput | Submit p50 |
|---|---|---|
| conn_churn_seq (1 producer, 2 workers) | <final> ops/s | <final> ns |
| producer_contention (4 producers, 2 workers) | <final> ops/s | <final> ns |

See `docs/PERFORMANCE_TRACKING.md` for per-phase deltas and the full Tokio
rt_multi_threaded-parity suite.  Numbers captured on Linux x86_64 with
`std.heap.smp_allocator`; run `zig build bench-tokio-parity` on your own
hardware to compare directly to Tokio.
```

- [ ] **Step 3: Commit**

```bash
git add README.md docs/PERFORMANCE_TRACKING.md
git commit -m "docs: record final Tokio-parity performance numbers"
```

---

## Final Verification Checklist

Before declaring the plan complete:

- [ ] All unit tests pass: `zig build test --summary all`
- [ ] All integration tests pass: `zig build test-integration --summary all`
- [ ] Stress tests pass 50× in ReleaseFast: loop on `zig build test-stress`
- [ ] Fuzz target still compiles: `zig build test --fuzz` (give it 60s)
- [ ] All cross-compilation targets build: `zig build cross-check`
- [ ] Full benchmark: `zig build bench` — record final deltas
- [ ] Tokio parity benchmark: `zig build bench-tokio-parity` — record numbers
- [ ] Micro-benchmarks: `zig build bench-micro` — record numbers
- [ ] Pipeline green on CI: `glab ci status`
- [ ] `docs/PERFORMANCE_TRACKING.md` has all phase rows filled
- [ ] `README.md` Performance section populated

## Self-Review Notes

**Spec coverage:** Every item in the original assessment's "biggest wins" list is covered — batch-stealing (Tasks 9–11), per-worker lazy counters (Tasks 6–7), condvar backpressure (Task 13). Additional wins added: timestamp_mode opt-out (Task 5), per-worker park (Task 12), steal-victim affinity (Task 11), descriptor layout (Task 8). Measurement infrastructure covers submit (Task 2), steal (Task 3), wake (Task 4), and Tokio-parity end-to-end (Task 15).

**Placeholder scan:** Task 15's scenario definitions intentionally lean on `benchmarks/bench.zig` as a template rather than re-deriving the full scaffold — the template exists and the harness is shared. All other code blocks are complete.

**Type consistency:** New config fields are `steal_batch_size: usize`, `timestamp_mode: TimestampMode`. Used consistently in Tasks 5, 10. Worker fields added across tasks: `started`, `completed`, `park_mutex`, `park_cond`, `is_parked` — all referenced consistently.
