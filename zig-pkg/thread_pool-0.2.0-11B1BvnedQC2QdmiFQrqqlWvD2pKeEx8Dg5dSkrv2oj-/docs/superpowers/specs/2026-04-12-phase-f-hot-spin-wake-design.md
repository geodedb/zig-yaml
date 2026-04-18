# Phase F1: Hot-Spin Wake Elimination Design Spec

**Date:** 2026-04-12
**Status:** Design approved, ready for implementation plan
**Successor to:** Phase E (`docs/superpowers/plans/2026-04-12-steal-scan-bitmap.md`) — negative result, reverted

## Problem

`bench_tokio_parity/flood_1m` runs at 337K ops/s vs Tokio's 5–15M ops/s. A wall-clock `perf sched record` profile on 2026-04-12 (commit `3b0ca5b`, 56-core host) identified the critical path:

- **Submitter thread:** 89.3% running on CPU, 0.0005% blocked on futex. Not backpressure-bound, not queue-bound — CPU-bound on its own enqueue loop.
- **Workers:** 73.5% parked (aggregate). 26.5% running. Ample spare capacity.
- **Submitter CPU breakdown:** ~50% in kernel `futex_wake` chain (`futex_wake_mark`, `ttwu_queue_wakelist`, `available_idle_cpu`, `psi_group_change`, etc.), reached via `park_cond.signal()` in `enqueueTask` at `src/pool.zig:586-603`.

On every submit, after `inject_queue.tryPush` succeeds, the code scans `workers[*].is_parked` looking for a parked worker, then takes that worker's `park_mutex`, calls `park_cond.signal()` → `futex(FUTEX_WAKE)`. Because workers are 73% parked, this fires ~every submit. Per-fire cost is ~1.5 µs of kernel work. At 337K submits/s that's ~0.5 s of kernel wake work out of ~3 s wall time — the headline 50% of submitter CPU.

## A/B-verified impact ceiling

A no-op stub replacing the entire wake block (lines 586-603) was measured on the same host:

| Configuration | flood_1m ops/s | elapsed |
|---|---:|---:|
| Baseline (current wake path) | 334,902 | 2.99 s |
| Wake stubbed (no-op) | 505,889 (mean of 3) | 1.98 s |

**Maximum addressable gain from this target alone: +51% throughput (335K → 506K).** Remaining ~20% of submitter CPU is elsewhere (counters, queue push, descriptor allocation) and out of scope for this phase.

This A/B result is the primary evidence that Phase F's target is real. Phases D and E failed to perform this check before committing plans; both returned ~0%.

## Goal

Eliminate the per-submit kernel wake on the common path where at least one worker is momentarily idle. Preserve correctness: no lost wakeups, no starvation of parked workers during true low-activity periods.

## Non-Goals

- Worker-side wake latency: out of scope. Workers wake within ~µs already; the bottleneck is the submitter issuing the wake, not the worker receiving it.
- Park/unpark infrastructure redesign: unchanged. Per-worker `park_mutex`/`park_cond` remain for the cold-start fallback.
- `submitBatch` adoption or wake coalescing: deferred to Phase F2/F3. This spec is F1 only.
- Backpressure path: unchanged. A/B confirmed it's not a bottleneck.
- Scheduler variant other than `work_stealing`: hot-spin applies only to the work-stealing path. `global_queue` variant untouched.

## Design

### Component: `Core.active_spinners: std.atomic.Value(u32)`

Single atomic counter tracking how many workers are currently in the short spin-before-park phase. Incremented when a worker enters spin, decremented when it exits (either by finding work or by transitioning to full park).

Cacheline placement: adjacent to other hot submit-path atomics. Read on every submit, written on worker state transitions (roughly one RMW per idle→spin→running cycle per worker).

### Component: `WORKER_SPIN_LIMIT` constant

File-local constant in `src/pool.zig`. Default: `128` (rough guess based on Phase D's `BACKPRESSURE_SPIN_ITERS=64` precedent). Tuning knob — see Measurement / Tuning below.

### Submitter change

In `enqueueTask` at `src/pool.zig:586-603`, the current wake block is:

```zig
// Wake one parked worker. Scan `is_parked` across workers ...
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

Becomes:

```zig
// Hot path: if any worker is spinning, they will self-discover this
// task via their idle-loop re-try of nextTask. Zero kernel calls.
if (self.active_spinners.load(.monotonic) > 0) {
    return ...; // normal return path
}
// Cold path: no spinners — all workers parked. Wake one via existing
// per-worker signal. Unchanged from current code.
const submitted = self.counters.submitted.load(.monotonic);
// ... (existing is_parked scan + park_cond.signal logic preserved verbatim)
```

**Key properties:**

- Hot path: **one atomic load**, one compare-to-zero branch. No locks, no kernel calls.
- Cold path: identical to today. No behavior change when all workers truly parked.
- Memory ordering on `active_spinners` load: `.monotonic` is sufficient because the synchronization edge (submitter push is visible to worker) is already established by `inject_queue.tryPush` (CAS with `.release`) paired with the worker's `inject_queue.pop` (CAS with `.acquire`). `active_spinners` is only a hint about "is anyone actively polling"; a stale read of 0 when a worker just entered spinning is fine — submitter takes the cold path, wakes a parked worker (which may be a no-op if the worker already transitioned to spinning), and the spinning worker also picks up the task. Worst case: one extra wake. A stale read of > 0 when the last spinner just exited is also fine — submitter skips the wake, but the exiting spinner will re-check and park via the full park handshake (see below), where it re-loads `queued_tasks` and observes our push.

### Worker idle-loop change

In `Core.idle` (or wherever the worker's "no work found, about to park" path lives in `src/pool.zig` around the `workerMain` loop), insert a spin phase **before** the full park-condvar wait.

Pseudocode (adjust to match actual function structure):

```zig
// Called from workerMain when nextTask() returned null.
fn idle(self: *Core, worker_index: usize) void {
    _ = self.active_spinners.fetchAdd(1, .acq_rel);
    var spins: usize = 0;
    while (spins < WORKER_SPIN_LIMIT) : (spins += 1) {
        std.atomic.spinLoopHint();
        // Re-try nextTask every 8 iterations. inject_queue.pop is a
        // single CAS — cheap when the queue is empty.
        if (spins & 7 == 0) {
            if (self.shouldExit()) {
                _ = self.active_spinners.fetchSub(1, .acq_rel);
                return;
            }
            if (self.nextTask(worker_index)) |descriptor_index| {
                _ = self.active_spinners.fetchSub(1, .acq_rel);
                self.runTask(worker_index, descriptor_index);
                return;
            }
        }
    }
    _ = self.active_spinners.fetchSub(1, .acq_rel);
    // Exhausted spins — fall through to existing park logic.
    // (existing idle() body runs here unchanged)
}
```

**Key properties:**

- Spin duration: `128` iterations, checking `nextTask` every 8. Wall-clock: a few hundred ns at most.
- After spin exhaustion, falls through to the existing park logic unchanged. Preserves the Phase A park handshake (`is_parked := 1` store ordered with `queued_tasks` reload).
- `fetchAdd`/`fetchSub` on `active_spinners` use `.acq_rel` to establish happens-before with the submitter's `.monotonic` load → wait, this is a mismatch. See memory-ordering analysis below.

### Memory ordering analysis

The submitter's hot-path load is `active_spinners.load(.monotonic)`. This is sufficient because:

1. The submitter has already performed `inject_queue.tryPush(idx)` with `.release` semantics inside the queue implementation. This publishes the task to any thread that does a matching `.acquire` load on the inject queue.
2. A spinning worker's `nextTask` call performs `inject_queue.pop` with `.acquire`. This observes the submitter's push.
3. `active_spinners` is a pure hint: its value tells the submitter whether a spinner exists, but the actual work-handoff synchronization is done entirely through the queue's atomics. A stale `active_spinners` read cannot cause a missed task — only an extra (unnecessary) wake, or a skipped (unnecessary) wake covered by the spinner's own discovery.

Worker side: `.acq_rel` on `fetchAdd`/`fetchSub` provides more ordering than strictly needed but matches the existing codebase style for similar state-transition counters and costs nothing meaningful. Keep `.acq_rel` for consistency.

### Correctness case analysis

**Case A: Submitter sees `active_spinners > 0`, skips wake.** At least one spinner exists (or existed at load time). That spinner's re-try-every-8-spins loop will observe the pushed task within ~400 ns. If all spinners transition out before finding the task: they each decrement `active_spinners`; if it hits 0, any future submit will take the cold path. Meanwhile, our already-pushed task is still in the inject queue; the worker that enters the full park path does the Phase A handshake (stores `is_parked := 1`, then re-reads `queued_tasks`) and will see our increment, abort the park, and go back to search. No lost task.

**Case B: Submitter sees `active_spinners == 0`, takes cold path.** Behaves identically to current code — scans `is_parked[]`, wakes one parked worker. Worst case: a worker just entered the spin phase (decrement → increment race); submitter wakes a parked worker AND the new spinner also finds the task. One of them gets it; the other re-parks. One extra wake; correctness preserved.

**Case C: Worker finishes spin with no work, enters park.** Park handshake (Phase A) prevents lost wakeup. Falls through to today's well-tested path.

**Case D: Worker in spin phase, `shouldExit()` becomes true.** Spin loop checks `shouldExit()` every 8 iterations, decrements `active_spinners`, and returns cleanly.

### Data flow

```text
Submit (hot path):
  enqueueTask
    -> local-queue or inject_queue push  (unchanged)
    -> queued_tasks increment            (unchanged)
    -> active_spinners.load(.monotonic)  [NEW]
       if > 0: return (no wake needed)
       else: fall through to cold-path wake (unchanged)

Worker idle (hot path):
  workerMain loop: nextTask() returned null
    -> active_spinners.fetchAdd(1)       [NEW]
    -> spin WORKER_SPIN_LIMIT iters with nextTask re-try every 8 [NEW]
       if found: active_spinners.fetchSub(1); run task
       else: active_spinners.fetchSub(1); fall through to park
    -> existing idle()/park logic        (unchanged)
```

### Error Handling

None — the design adds no failure modes. All atomic ops are total; the spin loop has a bounded iteration count; the fall-through to park preserves existing behavior.

### Testing Strategy

| Test | Level | Purpose |
|---|---|---|
| `active_spinners` wraps around zero under multi-thread enter/exit | Unit | Protocol correctness under concurrency |
| flood_1m run with WORKER_SPIN_LIMIT=0 matches baseline | Integration | Sanity: disabling spin phase restores current behavior |
| flood_1m with default WORKER_SPIN_LIMIT matches acceptance gate | Benchmark | Primary perf gate |
| All existing stress tests pass 5× consecutive | Stress | Correctness under mixed-workload pressure |
| `perf sched` on submitter: confirms blocking time ≈ 0 (unchanged from Phase E post-revert) | Observation | Confirms mechanic (submitter still CPU-bound but on cheaper code) |

### Performance Targets

| Metric | Baseline | Target | Stretch | Rationale |
|---|---:|---:|---:|---|
| `bench_tokio_parity/flood_1m` ops/s | 335K | **≥ 450K** | ≥ 500K | Target: 67% of A/B ceiling (+34%); stretch: 98% of ceiling |
| `bench_tokio_parity/contended_spawn_8x` ops/s | 534K | ≥ 600K | ≥ 640K | A/B showed 634K with wake stubbed |
| `perf stat` cache-miss rate | 34% | ≤ 25% | ≤ 15% | Less cross-core traffic from is_parked scan |
| `perf stat` IPC | 0.19 | ≥ 0.35 | ≥ 0.5 | Scales with cache-miss reduction |
| Submitter CPU in futex_wake chain | ~50% | ≤ 10% | ≤ 5% | Direct signal that target is eliminated |
| Context-switches / 1M tasks | ~0.88M | ≤ 0.5M | ≤ 0.2M | Workers spin more, park less |
| Submit p50 (single-worker bench) | 917 ns | ≤ 1000 ns | ≤ 950 ns | No regression; single-worker path unchanged |
| `test-stress` 5× consecutive | pass | pass | pass | Correctness |

**Rollback floor:** `flood_1m` median < 400K. Below that, the mechanic isn't working — `active_spinners` coordination overhead exceeds the wake savings, or workers are dropping out of spin too quickly to matter. Triggers immediate revert.

### Tuning methodology

After the implementation lands and passes primary gates, sweep `WORKER_SPIN_LIMIT` across {64, 128, 256, 512} and measure `flood_1m` + idle-worker CPU. Pick the value that maximizes throughput without causing > 5% CPU burn at idle (measured by running a 10-second no-op test). Record the sweep in `PERFORMANCE_TRACKING.md`.

### Relationship to Phase F2 / F3

- **F2 (submitBatch adoption):** orthogonal to F1. Can be attempted independently after F1 lands. If F1 alone reaches 500K+, F2's marginal value shrinks.
- **F3 (coalesced wake):** only considered if F1 + (optional F2) fall short of ~480K. Would require root-causing the Phase C stress-test hang first.

This spec covers F1 only.

## File Structure

**Modified files:**

- `src/pool.zig` — add `active_spinners` field on `Core`, add `WORKER_SPIN_LIMIT` constant, modify the wake block in `enqueueTask`, modify the worker idle path (locate it first — likely `idle()` around line 745 or inside `workerMain`).
- `tests/unit.zig` — add `active_spinners` concurrency test.
- `docs/PERFORMANCE_TRACKING.md` — Phase F entry.
- `benchmarks/results/baseline.json` — rebaseline on success.

**New files:** none.

## Out of Scope

- `src/queue/**` — unchanged.
- Backpressure path — unchanged.
- Bitmap-based steal scan — not re-added.
- `submitBatch` API usage — deferred to F2.

## Open Questions

None — all design decisions locked in brainstorm session 2026-04-12.

## Process Addendum (lesson from Phases D, E)

Phases D and E both committed plans without first running an A/B-disable sanity check. Both returned ~0%. **This spec's Problem section includes A/B-verified evidence** (335K → 506K with wake stubbed) as a concrete ceiling. Future phase specs should follow the same pattern:

1. Identify candidate target.
2. Run A/B-disable (stub the target to a no-op) in 5 minutes or less.
3. Record the measured ceiling in the spec.
4. Only proceed to planning if the A/B shows a material improvement.

If a phase spec cannot point to an A/B-verified ceiling, it is not ready for planning.
