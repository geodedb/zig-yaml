# Steal-Scan Bitmap Design Spec

**Date:** 2026-04-12
**Status:** Design approved, ready for implementation plan
**Successor to:** Phase D (`docs/superpowers/plans/2026-04-12-lock-free-backpressure.md`) — negative result, reverted

## Problem

`bench_tokio_parity/flood_1m` runs at 340K ops/s vs Tokio's 5–15M ops/s (15–45× gap). A `perf record --call-graph dwarf` profile on commit `850b0b5` (56-core host, Debian 13, kernel 6.12.74) attributed **42.1% of cumulative cycles** to a single hot path: `Core.nextTask` calling `LocalQueue.len()` on every sibling worker during the steal scan. Each call does two `acquire` loads on remote atomics (`bottom` and `top`), and with 56 workers each scanning 55 siblings the cross-core cacheline traffic is all-to-all. The machine runs at IPC 0.19 and 34.1% cache-miss rate — classic memory-stall-dominated ping-pong.

The current `src/pool.zig:686` skip-empty optimization is correct but paying the full cost anyway: the `len()` read to check "is it empty" is itself what drags the cacheline into the stealer's L1, and the owner pays to drag it back every push/pop.

## Goal

Eliminate the O(N²) sibling-peek pattern. Stealers consult an O(1) bitmap to find candidate victims instead of peeking every sibling's `(top, bottom)` atomic pair.

## Non-Goals

- Worker park/unpark (~17% of cycles): out of scope. Bitmap may reduce park frequency as a side effect; measure but do not target directly. Separate Phase F plan.
- Inject queue (~7.7%): unchanged.
- Descriptor CAS free-list (~2.7%): unchanged.
- Backpressure wait path: unchanged (Phase D confirmed <1% of cycles).
- Scheduler variant other than `work_stealing`: bitmap is only consulted in that path. `global_queue` variant untouched.

## Design

### Component: `Core.non_empty_workers`

A single cacheline-aligned `std.atomic.Value(u64)` on `Core`. Bit `i` is set when `local_queues[i].len() > 0` (modulo the inherent slack of the lazy-clear protocol below).

**Capacity:** 64 workers maximum. Enforced by `Config.validate()` — `max_threads > 64` returns `error.TooManyWorkers`. Documented in the `Config.max_threads` field comment. Future multi-word generalization is out of scope; the scan currently pays O(N²) in N so >64 workers is itself a design smell worth re-evaluating if it ever arises.

### Component: `worker_bit` helper

File-local pure function: `inline fn worker_bit(i: usize) u64 { return @as(u64, 1) << @intCast(i); }`. Used by all three bit-update sites and by the stealer scan.

### Bit-maintenance protocol

**Invariant:** if `local_queues[i].len() > 0`, then bit `i` is eventually set. Transient clears are tolerated by the re-check pattern.

Three update sites:

**1. Owner push** (`enqueueTask` in `src/pool.zig`, inside the `tryPushBottom` branch):

```zig
if (local_queues[wi].tryPushBottom(idx)) {
    self.non_empty_workers.fetchOr(worker_bit(wi), .release);
    // ...
}
```

Idempotent — bit is usually already set. `fetchOr` is a single RMW; overhead is ~5 ns and amortizes over the push.

**2. Owner pop-to-empty** (`nextTask` in `src/pool.zig`, after `popBottom` succeeds):

```zig
if (lq.popBottom()) |idx| {
    if (lq.len() == 0) {
        self.non_empty_workers.fetchAnd(~worker_bit(wi), .release);
        if (lq.len() != 0) {
            self.non_empty_workers.fetchOr(worker_bit(wi), .release);
        }
    }
    return idx;
}
```

Re-check pattern: the clear may race with a concurrent push; if the queue is non-empty after the clear, re-set the bit. Cost: one extra `len()` read on the empty-transition edge. Non-empty-transition pops skip the bit update entirely.

**3. Successful steal** (`stealFrom` in `src/pool.zig`, after `stealHalf` / `steal` returns a descriptor):

```zig
if (victim_lq.len() == 0) {
    self.non_empty_workers.fetchAnd(~worker_bit(victim_index), .release);
    if (victim_lq.len() != 0) {
        self.non_empty_workers.fetchOr(worker_bit(victim_index), .release);
    }
}
```

Stealer writes to the victim's bit. Safe because `fetchAnd`/`fetchOr` are atomic RMW and serialize with the owner's push/pop ops.

### Stealer scan

Rewrite `stealFrom` (around `src/pool.zig:680-710`):

```zig
fn stealFrom(self: *Core, worker_index: usize) ?u32 {
    const self_bit = worker_bit(worker_index);
    const raw = self.non_empty_workers.load(.acquire) & ~self_bit;
    const w = &self.workers[worker_index];
    const rot: u6 = @truncate(w.steal_rot_seed);
    w.steal_rot_seed +%= 1;
    var bitmap = std.math.rotr(u64, raw, rot);
    while (bitmap != 0) {
        const tz = @ctz(bitmap);
        const victim_index = (@as(usize, tz) + rot) % self.workers.len;
        bitmap &= bitmap - 1;
        const victim_lq = &self.local_queues[victim_index];
        if (victim_lq.stealHalf(&self.local_queues[worker_index])) |desc| {
            // Post-steal bit maintenance
            if (victim_lq.len() == 0) {
                self.non_empty_workers.fetchAnd(~worker_bit(victim_index), .release);
                if (victim_lq.len() != 0) {
                    self.non_empty_workers.fetchOr(worker_bit(victim_index), .release);
                }
            }
            return desc;
        }
    }
    return self.inject_queue.pop();
}
```

**Properties:**

- One `acquire` load per scan cycle.
- `@ctz` compiles to `tzcnt`/`bsf` (one instruction on x86).
- `bitmap & (bitmap - 1)` clears the lowest set bit in one instruction.
- Randomized start offset via `steal_rot_seed` preserves load balancing — different stealers don't herd on the lowest-indexed victim.
- The failed-steal case (bit was set but the queue drained between load and `stealHalf`) falls through to try the next set bit, then the inject queue.

### Data Flow

```text
Submit:
  enqueueTask
    -> local_queues[wi].tryPushBottom
    -> non_empty_workers.fetchOr(1 << wi)   [NEW]
    -> is_parked scan + wake  (unchanged)

Worker loop:
  nextTask
    -> LIFO slot check      (unchanged)
    -> popBottom local
         if drained: non_empty_workers.fetchAnd + re-check fetchOr   [NEW]
    -> stealFrom
         load non_empty_workers                                       [NEW]
         @ctz-iterate set bits                                        [NEW]
         stealHalf victim
           if drained: non_empty_workers.fetchAnd + re-check fetchOr  [NEW]
    -> inject_queue.pop      (unchanged)
```

### Error Handling

- `Config.validate()`: new error `error.TooManyWorkers` returned when `max_threads > 64`. Caller's existing error handling covers this.
- `Config.normalized()`: no change; the clamp remains a pure normalization with no validation semantics.
- All bitmap operations are total (no failure modes).

### Testing Strategy

| Test | Level | Purpose |
|---|---|---|
| `TooManyWorkers` returned for 65-thread config | Unit | Validation path |
| Bitmap invariant under racing threads (10k iterations, 16 workers, random push/pop mix) | Unit | Protocol correctness |
| Single submit wakes at least one worker; all tasks run | Integration | End-to-end wakeup with bitmap |
| 56-worker flood stress × 5 consecutive runs | Stress | Hang / lost-task guard |
| `bench_tokio_parity/flood_1m` ≥ 700K ops/s (median of 5) | Benchmark | Primary perf gate |

### Performance Targets

| Metric | Baseline (Phase C) | Target | Stretch |
|---|---:|---:|---:|
| `flood_1m` ops/s (median of 5) | 340K | **≥ 700K** | ≥ 900K |
| `contended_spawn_8x` ops/s | 534K | ≥ 900K | ≥ 1.1M |
| Cache-miss rate (`perf stat`) | 34.1% | ≤ 8% | ≤ 5% |
| IPC | 0.19 | ≥ 1.0 | ≥ 1.5 |
| Context-switches per 1M tasks | ~1.0M | ≤ 400K | ≤ 200K |
| Submit p50 | 917 ns | ≤ 1000 ns | ≤ 950 ns |
| Submit p99 | 1690 ns | ≤ 1800 ns | ≤ 1700 ns |
| `test-stress` 5× consecutive | pass | pass | pass |

**Ceiling analysis:** fully eliminating the 42% scan cost alone yields a ~587K ceiling. Targets above 587K presume second-order effects — cache-miss collapse benefiting all memory traffic, and reduced park/unpark as workers find work faster. Optimistic ceiling if both cascade: `340K / (1 − 0.421 − 0.17) ≈ 830K`.

**Rollback floor:** `flood_1m < 550K` median. Below that, bitmap maintenance cost is eating the scan win; the design needs per-worker cached bit-state (set only on empty→non-empty transition, not every push).

### Relationship to "Match Tokio" Goal

Tokio runs 5–15M ops/s on `flood_1m`-equivalent. Reaching 700K-900K here is 7-10× short but puts us on the correct trajectory. Follow-up phases needed:

1. **Phase F: park/unpark reduction** — after bitmap shows the park frequency in isolation, decide between keep-alive spin windows, notify-coalescing, or event-based worker wakes.
2. **Phase G: inject queue & descriptor pool** — re-profile post-F. Current profile shows 7.7% inject queue pop and 2.7% descriptor CAS; both grow in relative terms as other cost shrinks.
3. **Phase H: worker-local allocation / cache locality** — a per-worker descriptor arena would eliminate the single-shared free list entirely.

This design spec covers Phase E only.

## File Structure

**Modified files:**

- `src/pool.zig` — add `non_empty_workers` field, `worker_bit` helper, update `enqueueTask` / `nextTask` / `stealFrom`.
- `src/types.zig` — add `error.TooManyWorkers` to `Config.validate()`, document the 64-worker cap on `Config.max_threads`.
- `tests/unit.zig` — add two tests: `TooManyWorkers` validation, bitmap protocol invariant.
- `tests/stress.zig` — add 56-worker flood stress if hardware supports (fall back to `@min(cpu_count, 64)` for portability).
- `docs/PERFORMANCE_TRACKING.md` — Phase E entry.
- `benchmarks/results/baseline.json` — rebaseline on success.

**New files:** none.

## Out of Scope (Do Not Touch in This Plan)

- `src/queue/**` — local queue implementation unchanged.
- Backpressure / `waitForCapacity` — unchanged.
- Park/unpark path — unchanged.
- Inject queue — unchanged.
- LIFO slot — unchanged.

## Open Questions

None — all design decisions locked in brainstorm session 2026-04-12.
