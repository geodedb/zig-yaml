# Phase F1b: Reserved Hot-Spin Workers Design Spec

**Date:** 2026-04-12
**Status:** Design approved, ready for implementation plan
**Successor to:** Phase F1 (`docs/superpowers/plans/2026-04-12-phase-f-hot-spin-wake.md`) — negative result, reverted after A/B-disable gate caught the mechanic not engaging

## Problem

`bench_tokio_parity/flood_1m` runs at 335K ops/s vs Tokio's 5–15M ops/s. A wall-clock `perf sched record` profile (2026-04-12, commit `3b0ca5b`, 56-core host) identified the submitter at 89.3% CPU-bound with 50% of cycles in the `futex_wake` chain inside `enqueueTask`. An A/B-disable experiment (stub the wake block to a no-op) yielded 335K → 506K ops/s (+51%), confirming the wake path is a real, addressable ceiling.

Phase F1 attempted to capture this ceiling by bracketing the existing `idle()` short-spin (`spin_before_park_iters = 128` iters, ~128 ns) with an `active_spinners` counter and making the submitter skip the wake when any worker was spinning. Result: 383K default vs 386K with spin disabled — **the mechanic did not engage**. Root cause: the spin window is ~128 ns but the inter-submit interval is ~3 µs; P(submitter catches any worker spinning) was effectively zero. See `PERFORMANCE_TRACKING.md` Phase F1 section.

**F1b addresses the engagement failure directly: reserve N workers that never park, guaranteeing the submitter always has a catchable non-parked worker.**

## A/B-verified impact ceiling (unchanged from F1)

Stubbing the entire wake block in `enqueueTask`:

| Configuration | flood_1m ops/s |
|---|---:|
| Baseline | 335K |
| Wake stubbed (no-op) | 506K |

Addressable gain: **+51% (335K → 506K).** F1b aims to capture most of that ceiling while handling the "hot-spinner busy mid-task" failure mode that would otherwise starve parked workers.

## Goal

Eliminate the per-submit `futex_wake` on the common path by:

1. Reserving N workers that never park (always either running a task or spinning).
2. Making the submitter unconditionally skip the wake scan when `hot_spinners > 0`.
3. Having the reserved hot-spinners propagate wakes to parked workers on a task-count threshold, so that when submits outpace a single hot-spinner's consumption, other workers are recruited within a bounded task count.

This moves wake coalescing from the submitter thread (where Phase C's attempt hung stress tests) to a worker thread (no backpressure interaction, no lost-wakeup races).

## Non-Goals (in F1b)

- Dynamic hot-spinner count — see planned follow-up phases.
- NUMA-aware hot-spinners — see planned follow-up phases.
- `submitBatch` integration — see planned follow-up phases.
- Worker-side wake-latency reduction (parked workers wake within µs today; the bottleneck is the submitter issuing the wake, not the worker receiving it).
- Scheduler variants other than `work_stealing` — hot-spin applies only to that path. `global_queue` untouched.

## Design

### Component: `Config.hot_spinners: u32 = 0`

Number of workers reserved as always-spinning. Default 0 preserves current behavior (opt-in). Validated `0 <= hot_spinners < max_threads`; a pool must always have at least one non-hot worker so parked-worker fallback remains functional.

### Component: `Config.wake_every_n_tasks: u32 = 64`

Hot-spinner's wake-propagation threshold. After executing `wake_every_n_tasks` tasks, a hot-spinner issues one `futex_wake` to a parked worker. This amortizes wake cost across many submits while bounding worst-case wake latency to ~K × inter-task interval.

At 335K ops/s with K=64, worst-case: 64 × ~3 µs = ~200 µs from task enqueue to a parked worker observing wake. Within acceptable tail for throughput benchmarks; users with strict latency SLOs can reduce K.

Validation: if `hot_spinners > 0 and wake_every_n_tasks == 0`, return `error.InvalidWakeThreshold` — this combination would enable hot-spinners without propagation, starving parked workers on long-running tasks.

### Component: `Core.hotSpinnerLoop`

New private method running in workers with `worker_index < self.config.hot_spinners`. Replaces the `workerMain` body for reserved workers; normal `workerMain` is unchanged for the rest.

```zig
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

- Never calls `idle()`, so never parks.
- `tasks_since_wake` is a plain local counter (not atomic) — thread-local to this worker.
- `shouldExit()` observable every loop iteration so shutdown is prompt (worst case: one task's duration).
- `spinLoopHint` on empty-queue path tells the CPU we're not doing real work; reduces thermal cost.

### Component: `Core.wakeOneParkedWorker`

Extract the existing wake scan from `enqueueTask` into a private method:

```zig
fn wakeOneParkedWorker(self: *Core) void {
    const submitted = self.counters.submitted.load(.monotonic);
    const hint_idx: usize = @intCast(submitted % self.workers.len);
    var off: usize = 0;
    while (off < self.workers.len) : (off += 1) {
        const idx = (hint_idx + off) % self.workers.len;
        if (idx < self.config.hot_spinners) continue; // hot-spinners never park
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

The `continue` on `idx < hot_spinners` ensures the scan never tries to wake a reserved worker (they're always running).

### `enqueueTask` hot-path change

Modify the wake block to skip entirely when `hot_spinners > 0`:

```zig
    _ = self.counters.submitted.fetchAdd(1, .monotonic);
    self.incrementQueued();

    // If any hot-spinners are configured, they're always running and
    // will catch our push via nextTask (inject queue / local queue).
    // They issue wakes themselves, every wake_every_n_tasks tasks, to
    // recruit parked workers when load exceeds a single spinner's
    // consumption. A/B-verified ceiling: stubbing the wake block lifts
    // flood_1m 335K → 506K.
    if (self.config.hot_spinners == 0) {
        self.wakeOneParkedWorker();
    }
```

The cold-path scan is now extracted into `wakeOneParkedWorker` (called only when hot-spinners are disabled). `hot_spinners = 0` exercises the same logical path as today — same submit counters, same `is_parked` scan, same `park_cond.signal`. The one mechanical difference: `wakeOneParkedWorker` has a `if (idx < self.config.hot_spinners) continue;` branch inside the scan loop. When `hot_spinners = 0` this branch is always not-taken and fully branch-predicted after the first iteration; the overhead is below measurement noise.

### `workerMain` fork

The existing `workerMain` adds a one-line branch at the top:

```zig
fn workerMain(self: *Core, worker_index: usize) void {
    if (worker_index < self.config.hot_spinners) {
        self.hotSpinnerLoop(worker_index);
        return;
    }
    // existing body unchanged
}
```

### Data Flow

```text
Submit (hot_spinners > 0):
  enqueueTask
    -> inject_queue.tryPush / local_queues[wi].tryPushBottom  (unchanged)
    -> counters.submitted++, queued_tasks++                   (unchanged)
    -> if (hot_spinners > 0): return  [NEW fast path, NO wake]
    -> else: wakeOneParkedWorker()  (extracted from original inline block)

Hot-spinner loop (worker_index < hot_spinners):
  loop until shutdown:
    -> nextTask (LIFO → local → inject → steal)  (unchanged)
    -> if found: runTask; tasks_since_wake++
       -> if counter >= wake_every_n_tasks:
          wakeOneParkedWorker()  [worker-side coalesce]
          reset counter
    -> else: spinLoopHint, loop

Normal worker (worker_index >= hot_spinners):
  existing workerMain / nextTask / idle() / park  (unchanged)
```

### Memory ordering

- `tasks_since_wake`: thread-local `u32`; no atomics.
- `self.counters.submitted.load(.monotonic)` inside `wakeOneParkedWorker`: same as current inline code. No change.
- `w.is_parked` with `.seq_cst` / `.monotonic`: preserves existing Phase A park handshake semantics.
- `self.config.hot_spinners` is read-only after pool init; no synchronization needed.

### Correctness Cases

**Case A: `hot_spinners = 0` (default).** `enqueueTask` calls `wakeOneParkedWorker` on every submit — identical to current behavior. `workerMain` takes the original non-fork path. Absolutely no behavior change.

**Case B: `hot_spinners > 0`, at least one hot-spinner spinning when submitter pushes.** Spinner's next `nextTask` call observes the push via `inject_queue.pop` (with `.acquire`). Task executes. After every K tasks, spinner issues one wake to recruit a parked worker. No lost tasks.

**Case C: `hot_spinners > 0`, ALL hot-spinners busy mid-task when submit arrives.** Submit lands in `inject_queue`. Submitter returns. Other workers may be parked. The first hot-spinner to finish its current task returns to the loop, calls `nextTask`, picks up the queued task. Its task-count counter increments; when it crosses K, it wakes a parked worker. Worst-case latency: `(K tasks × per-task duration)`. For flood_1m with trivial tasks at ~1 µs each, K=64 yields ~64 µs tail. Acceptable.

**Case D: `hot_spinners > 0`, all hot-spinners spinning on an empty queue when shutdown requested.** `shouldExit()` becomes true; hot-spinner loop exits. Thread joins cleanly.

**Case E: Task submitted with `hot_spinners = N, N >= workers.len - 0`**. Prevented by `validate()` returning `error.InvalidHotSpinners`.

**Case F: `hot_spinners = 1, wake_every_n_tasks = 0`.** Prevented by `validate()` returning `error.InvalidWakeThreshold` — would starve parked workers.

### Error Handling

- `Config.validate()`:
  - `error.InvalidHotSpinners` if `hot_spinners >= max_threads`.
  - `error.InvalidWakeThreshold` if `hot_spinners > 0 and wake_every_n_tasks == 0`.
- `Config.normalized()`: no changes.
- All atomic ops and wake calls are total; no runtime failure modes.

### Testing Strategy

| Test | Level | Purpose |
|---|---|---|
| `InvalidHotSpinners` returned when `hot_spinners >= max_threads` | Unit | Validation path |
| `InvalidWakeThreshold` returned when `hot_spinners > 0, wake_every_n_tasks == 0` | Unit | Footgun guard |
| `hot_spinners = 0` is byte-for-byte identical to current behavior | Integration (whole existing suite) | No regression for non-opt-in users |
| 4-worker pool, `hot_spinners = 1`: 10k tasks execute, counter matches | Integration | Basic correctness |
| 4-worker pool, `hot_spinners = 1, wake_every_n_tasks = 8`: slow-task stress — parked workers recruited within 8 tasks | Integration | Wake propagation correctness |
| 56-worker pool, `hot_spinners = 1`, `flood_1m`-shape workload: 1M tasks complete | Stress | No lost tasks under high load |
| Shutdown during `hotSpinnerLoop`: `pool.shutdown(.drain)` completes cleanly | Stress | `shouldExit` observable |
| `bench_tokio_parity/flood_1m` with `hot_spinners = 1` ≥ 450K ops/s | Benchmark | Primary perf gate |
| **Post-impl A/B gate:** same build, `hot_spinners = 0` matches baseline; `hot_spinners = 1` hits target | Mandatory | Confirms mechanic is source of gain (methodology rule) |

### Performance Targets

| Metric | Baseline | hot_spinners=0 | hot_spinners=1 | Stretch |
|---|---:|---:|---:|---:|
| `flood_1m` ops/s | 335K | 335K (= baseline) | **≥ 450K** | ≥ 500K |
| `contended_spawn_8x` ops/s (hot_spinners=2) | 534K | 534K | ≥ 600K | ≥ 640K |
| Submitter CPU in futex_wake (hot_spinners=1) | ~50% | ~50% | ≤ 5% | ≤ 2% |
| Hot-spinner CPU at idle with no work | — | — | 100% (expected 1 core/spinner) | — |
| `test-stress` 5× consecutive (hot_spinners=0) | pass | pass | — | — |
| `test-stress` 5× consecutive (hot_spinners=1) | — | — | pass | — |

**Rollback floor:** `flood_1m` median with `hot_spinners = 1` < 400K. Below that, the consumer-side wake propagation isn't covering the "submits outpace single spinner" case adequately.

**Post-impl A/B gate (mandatory per methodology lesson from F1):** Measure `hot_spinners = 0` and `hot_spinners = 1` on the same build. The 0-case must match current baseline (~335K) within measurement noise — same logical path exercised. The 1-case must hit the ≥ 450K target. If 0-case regresses meaningfully, the `enqueueTask` refactor (extracting `wakeOneParkedWorker`) introduced a real cost and needs fixing. If 1-case matches 0-case, the mechanic isn't engaging — design iteration required.

## File Structure

**Modified files:**

- `src/types.zig` — add `Config.hot_spinners`, `Config.wake_every_n_tasks`, validation, doc comments.
- `src/pool.zig` — add `hotSpinnerLoop`, `wakeOneParkedWorker`; fork in `workerMain`; conditional wake in `enqueueTask`.
- `tests/unit.zig` — validation tests + basic hot-spinner correctness.
- `tests/stress.zig` — slow-task wake propagation stress + wide-pool flood with `hot_spinners = 1`.
- `docs/PERFORMANCE_TRACKING.md` — Phase F1b entry with measurements.
- `benchmarks/results/baseline.json` — rebaseline on success.

**New files:** none.

## Out of Scope

- `src/queue/**` — unchanged.
- Backpressure path — unchanged.
- `is_parked` / `park_cond` / park-handshake machinery — unchanged (hot-spinners don't park; non-hot workers use the existing path verbatim).
- Any mechanism for turning hot-spinners on/off at runtime. Pool config is frozen post-init.

## Planned follow-up phases (not in F1b scope)

These are explicitly visible and committed-to but separated to preserve attribution clarity (per the D/E/F1 lesson: bundled changes with multiple mechanics = unclear which one drove the result).

- **F1b-rotation: dynamic hot-spinner rotation.** Rotate which worker is the hot-spinner every N tasks so no single core monopolizes the spin burden. Unlocks better thermal distribution on long-running pools. Requires its own spec + rotation-correctness-under-races design (hand-off protocol has non-trivial invariants: always exactly `hot_spinners` workers spinning, no races on takeover).
- **F1c-NUMA: per-NUMA-node hot-spinners.** On multi-socket hardware, reserve a hot-spinner per NUMA node and shard the `inject_queue` per node. Requires NUMA detection (syscalls / procfs), thread affinity pinning, per-node queue distribution. Significant architectural change — the thread-pool today has zero NUMA awareness. Needed for scaling beyond ~64 cores but not blocking F1b on this hardware.
- **F2: submitBatch integration.** Adopt `submitBatch` API in `flood_1m` benchmark to amortize wakes across many pushes per submit call. Orthogonal to F1b — can ship concurrently once both have their own A/B ceilings measured. May be unnecessary if F1b hits its target.

Each gets its own spec + pre-plan A/B ceiling + implementation + post-impl A/B gate.

## Open Questions

None — all design decisions locked in brainstorm session 2026-04-12.

## Methodology Addendum

Phase F1's revert added a **mandatory post-implementation A/B-disable gate** to the phase-process rule set. F1b's Performance Targets section explicitly includes this gate as a test. The full rule set (from `~/.claude/projects/-home-benji-src-devnw-zig-thread-pool/memory/feedback_perf_profiling.md`):

1. Wall-clock per-thread measurement before planning.
2. Pre-plan A/B-disable on the target.
3. **Post-implementation A/B-disable on the MECHANIC.** (Added after F1.)
4. Cumulative profiles are a secondary signal; pair with per-thread views.
5. Probability-of-engagement is a first-class design constraint.

For F1b specifically: rule 5 was the failure mode in F1 (128 ns spin : 3 µs submit = never engaged). F1b sidesteps this by making the condition-true-duration ∞ (hot-spinners never park). Rule 3's gate is built into the test matrix (`hot_spinners = 0` vs `1` on the same build).
