# Phase G1: Sharded Wake Targeting Design Spec

**Date:** 2026-04-12
**Status:** Design approved, ready for implementation plan
**Successor to:** Phase F1b (`docs/superpowers/plans/2026-04-12-phase-f1b-reserved-hot-spinners.md`) — reverted. See `PERFORMANCE_TRACKING.md` Phase F1b section for the deep re-profile findings that motivated G1.

## Problem

`bench_tokio_parity/flood_1m` runs at 331K ops/s vs Tokio's 5-15M. A systematic A/B-disable profile (2026-04-12) decomposed the submit hot path into four overlapping contention sources:

| Stubbed alone | Lift | New median |
|---|---:|---:|
| Wake scan (`is_parked[]` N-way SC load + futex_wake) | **+47%** | **488K** |
| `queued_tasks` SC fetchAdd + idle-spin load × 56 workers | +26% | 417K |
| `submitted.fetchAdd` + `hint_idx` round-robin | +28% | 422K |
| Descriptor CAS | +16% | 383K |
| All three shared atomics simultaneously | +210% | ~1.0M |
| Inject queue + downstream | — | 9.51M (not primary) |

**The wake scan is the single largest individual contributor (+47%).** Phase G1 targets it specifically: replace the O(N) `is_parked[]` sequential scan with an O(1) bitmap-driven targeted wake.

## A/B-verified impact ceiling (specific to G1)

From the re-profile experiment (stubbed the entire wake block in `wakeOneParkedWorker`): median 488K, 5 runs: {481K, 488K, 493K, 494K, 484K}. **+47% addressable gain for this mechanic alone.**

## Goal

On every submit where a worker is parked, wake exactly one in O(1) time via a `@ctz` on a u64 bitmap — replacing the current O(N) loop over `workers[*].is_parked`.

## Non-Goals (deferred to G2/G3)

- `queued_tasks` SC fetchAdd elimination (Phase G2, +26% A/B-measured).
- `submitted.fetchAdd` elimination (Phase G3, +28% A/B-measured).
- Descriptor CAS rework (Phase H, +16%).
- Inject queue / local queue changes (not bottlenecks).
- `hot_spinners` config knob from F1b (retained as no-op API; future phases may re-wire it).

## Design

### Component: `Core.parked_mask: std.atomic.Value(u64)`

A single cacheline-aligned atomic bitmap. Bit `i` set ⇔ worker `i` is parked. Written by the owning worker during the park handshake; read by submitters in the wake path.

`MAX_WORKERS = 64` is already enforced in `Config.validate()` (retained from earlier Phase E Task 1, survived the Phase E rollback — verify via `grep MAX_WORKERS src/types.zig`). G1 does not change this cap.

### Park handshake update (in `idle()`)

The existing Phase A park handshake in `src/pool.zig` around lines 787-830 uses SC on `worker.is_parked` and SC load on `queued_tasks`. G1 adds `parked_mask` maintenance alongside, in the same critical section structure:

```zig
// Before: is_parked.store(1, .seq_cst)
worker.is_parked.store(1, .seq_cst);
_ = self.parked_mask.fetchOr(workerBit(worker_index), .seq_cst);

// ... existing queued_tasks / state re-check unchanged ...

// Before: is_parked.store(0, .release) on wake-abort or wakeup
_ = self.parked_mask.fetchAnd(~workerBit(worker_index), .release);
worker.is_parked.store(0, .release);
```

Both `is_parked` and `parked_mask` are maintained. `is_parked` remains because `wakeOneParkedWorker` uses it under `park_mutex` for the "don't signal a worker who just unparked" double-check. G1's bitmap is the *fast targeting*; the bit+mutex is the *correctness fence*.

### Wake path rewrite (`wakeOneParkedWorker`)

Current O(N) scan (around lines 576-603 of `src/pool.zig`):

```zig
// Current: scan workers[0..N], find one with is_parked == 1, wake it
const submitted = self.counters.submitted.load(.monotonic);
const hint_idx = submitted % self.workers.len;
for off in 0..N { /* ... is_parked.load(.seq_cst) scan ... */ }
```

New O(1) path:

```zig
fn wakeOneParkedWorker(self: *Core) void {
    const mask = self.parked_mask.load(.seq_cst);
    if (mask == 0) return; // no parked workers, common case when pool saturated

    // @ctz finds the lowest set bit. Rotate by a per-pool counter so
    // successive wakes don't always target the same worker.
    //
    // Use the existing `submitted` counter as the rotation seed — it
    // increments on every submit so rotation varies naturally. This
    // costs one monotonic load (already present in the old path) and
    // zero additional writes. G3 will replace this with a submitter-
    // local source; for G1 it preserves current semantics.
    const rot: u6 = @intCast(self.counters.submitted.load(.monotonic) & 63);
    const rotated = std.math.rotr(u64, mask, rot);
    const tz: u6 = @intCast(@ctz(rotated));
    const idx = (@as(usize, tz) + @as(usize, rot)) & 63;
    if (idx >= self.workers.len) return; // rotation may alias past N

    const w = &self.workers[idx];
    // Fast-path recheck without mutex: worker may have unparked between
    // our load and now. parked_mask is SC so we see a consistent state.
    if (w.is_parked.load(.seq_cst) != 1) return;
    w.park_mutex.lock();
    if (w.is_parked.load(.monotonic) == 1) {
        w.park_cond.signal();
    }
    w.park_mutex.unlock();
}
```

**Properties:**

- `parked_mask.load(.seq_cst)` — one load vs N loads previously.
- `@ctz` on x86 compiles to `tzcnt`/`bsf` (1 instruction).
- Rotation preserves load-balancing so stealers/submitters don't herd on worker 0.
- `is_parked` re-check before mutex avoids unnecessary locks.

### Data flow

```text
Submit (unchanged except the wake path):
  enqueueTask
    → inject_queue.tryPush / local_queues[wi].tryPushBottom  (unchanged)
    → counters.submitted++, queued_tasks++                    (unchanged)
    → wakeOneParkedWorker  [MODIFIED: O(1) bitmap lookup]

Park handshake in idle() [MODIFIED]:
  → spin on queued_tasks (unchanged; G2 will remove)
  → worker.is_parked := 1   [unchanged]
  → parked_mask.fetchOr     [NEW]
  → load queued_tasks / state  [unchanged]
  → if abort: parked_mask.fetchAnd + is_parked := 0  [NEW / unchanged]
  → else: timedWait, on wake: parked_mask.fetchAnd + is_parked := 0  [NEW / unchanged]
```

### Memory ordering analysis

**Invariant preserved:** If a worker has set both `is_parked := 1` and `parked_mask` bit, and submitter's `queued_tasks` fetchAdd has not yet happened, then submitter will observe the parked state after its fetchAdd (SC total-order cross-pair). If submitter's fetchAdd happens before worker's SC stores, worker's SC load of queued_tasks will see the increment and abort the park.

The argument is the same SC-total-order handshake as Phase A's original `is_parked` / `queued_tasks` pair, extended to `parked_mask` via co-located SC operations on both sides. The SC fetchOr on parked_mask joins the same total order as the is_parked SC store.

**The SC fetchOr/fetchAnd may be over-strong for the bit-toggle itself** — release/acquire would suffice if the handshake used `is_parked` alone for ordering. G1 uses SC on parked_mask to reduce cognitive load: the invariant "parked_mask reflects current parked state consistently with queued_tasks increments" maps one-to-one with the existing is_parked invariant. G2 can relax this if its measurement shows a gain.

### Race cases

**Case A: Worker parks, submitter pushes, submitter reads parked_mask with worker bit set.** Submitter enters mutex, checks is_parked (still 1 because worker hasn't woken), signals cond. Worker wakes, clears is_parked + parked_mask, runs task. OK.

**Case B: Worker is parking (handshake mid-flight), submitter's push interleaves.** If worker's SC stores (is_parked, parked_mask) are visible to submitter, submitter wakes normally (Case A). If not, worker's SC load of queued_tasks must observe submitter's SC fetchAdd (total order), aborts park, clears its bit. Task served via normal scan of local/inject queue.

**Case C: Submitter reads parked_mask == 0.** No wake issued. At least one of: (i) no worker is actually parked (task will be picked up by a running/spinning worker), (ii) a worker's park stores haven't become visible yet (worker's SC queued_tasks load will observe submitter's push, aborts park, serves task). OK.

**Case D: Submitter reads parked_mask, @ctz returns a worker that unparked just before the read. is_parked.load → 0 in the fast-path recheck.** Return without wake. Task will be picked up by that worker or another. OK.

**Case E: Rotation alias — `(tz + rot) & 63` yields an index ≥ `workers.len` when `max_threads < 64`.** Skip. Could retry with a different rotation, but single miss is cheap and fairness is preserved across submits via varying rot. Acceptable for v1; optimize only if measurement shows wake-skip rate is too high.

### Error Handling

- No new config fields; no new validation rules.
- All atomic ops are total; no runtime failure modes.
- `MAX_WORKERS = 64` cap already enforced — no change needed.

### Testing Strategy

| Test | Level | Purpose |
|---|---|---|
| Existing park-handshake lost-wakeup stress test passes | Stress | Regression guard; current test at `tests/stress.zig:~63` |
| New: 56-worker flood with wake-heavy pattern — all tasks complete | Stress | Bitmap wake correctness under load |
| New: single-task submit after quiesce wakes a specific parked worker | Unit | Targeted-wake correctness |
| A/B gate: scan-mode build (via `grep` the diff, not runtime flag) matches baseline | Benchmark | Verify the old path didn't regress (it's gone) |
| `bench_tokio_parity/flood_1m` ≥ 450K ops/s | Benchmark | Primary perf gate |
| Post-impl A/B gate: stub the bitmap maintenance (set parked_mask to 0 always) → should regress to baseline | Benchmark | Confirms bitmap is the mechanism |

### Performance Targets

| Metric | Baseline | Target | Stretch | A/B isolation measurement |
|---|---:|---:|---:|---:|
| `bench_tokio_parity/flood_1m` ops/s | 331K | **≥ 450K** | ≥ 485K | 488K (wake stubbed) |
| `bench_tokio_parity/contended_spawn_8x` ops/s | 534K | ≥ 600K | ≥ 650K | — |
| Submit p50 (1 worker, 100k samples) | 917 ns | ≤ 1000 ns | ≤ 900 ns | — |
| Submit p99 | 1690 ns | ≤ 1800 ns | ≤ 1500 ns | — |
| `perf stat` cache-miss rate | 34% | ≤ 20% | ≤ 10% | — |
| `test-stress` 5× consecutive | pass | pass | pass | — |

**Rollback floor:** `flood_1m` median < 400K. Below that, the rewrite didn't realize the A/B ceiling and something's wrong (maybe the SC fetchOr/fetchAnd is adding back the contention it was supposed to eliminate, or the @ctz rotation misses too often).

**Post-impl A/B gate (mandatory per methodology):** Stub the bitmap maintenance (force `parked_mask.fetchOr` and `fetchAnd` to no-ops, force `parked_mask.load` to return 0) — this regresses wake to full-miss mode (no wakes ever issued). Throughput should match baseline (wakes ineffective but inject_queue still works). If it doesn't regress, the bitmap isn't the source of the lift.

### Planned follow-up phases (not in G1 scope)

- **G2: Remove `queued_tasks` from idle-spin.** +26% A/B-measured. Workers stop loading the submitter's cache line every spin iteration. Rebuild park handshake on `is_parked` + `parked_mask` alone (queued_tasks stays for metrics/shutdown).
- **G3: Submitter-local counter** replacing `submitted.fetchAdd` + `hint_idx` round-robin. +28% A/B-measured. Replace the global atomic with a thread-local counter; the `parked_mask` rotation seed in G1 becomes a thread-local source.
- **Phase H: Descriptor CAS rework.** +16% A/B-measured. Per-worker free-list, arena-style.

## File Structure

**Modified files:**

- `src/pool.zig` — add `Core.parked_mask` field; update `idle()` to maintain it on both park-abort and park-wake paths; rewrite `wakeOneParkedWorker` to use `@ctz`.
- `tests/unit.zig` — targeted-wake correctness test.
- `tests/stress.zig` — bitmap-wake correctness under wide-pool flood.
- `docs/PERFORMANCE_TRACKING.md` — Phase G1 entry with measurements.
- `benchmarks/results/baseline.json` — rebaseline on success.

**New files:** none.

## Out of Scope

- `src/queue/**` — unchanged.
- Backpressure / waitForCapacity — unchanged.
- LIFO slot — unchanged.
- Steal scan — unchanged.
- `hot_spinners` / `wake_every_n_tasks` config (F1b retained) — remain as documented no-ops; future phases may re-wire.

## Open Questions

None — all design decisions locked in 2026-04-12 session.

## Methodology Addendum

G1's spec codifies the rule refined through F1/F1b:

1. **Pre-plan A/B-disable on the target.** Done — 488K ceiling measured by stubbing the wake block entirely.
2. **Post-impl A/B-disable on the mechanic.** Gate built into the test matrix: force bitmap to "always zero" and verify throughput regresses to baseline. If it doesn't, the measured lift isn't coming from the mechanic.
3. **Mechanism must literally remove the work on every submit**, not conditionally skip it. G1's rewrite replaces the O(N) scan with O(1) lookup *on every submit unconditionally* — this is the structural difference from F1/F1b's conditional-skip approach.
