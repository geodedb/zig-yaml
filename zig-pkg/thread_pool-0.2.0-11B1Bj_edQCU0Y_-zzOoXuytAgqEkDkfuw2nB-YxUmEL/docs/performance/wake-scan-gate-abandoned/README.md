# Wake-Scan Parked-Count Gate — Abandoned

## TL;DR

Three variants of a `parked_count` gate to short-circuit the O(N) `is_parked[]` scan in `enqueueTask` all regressed flood_1m on this host. Branch `feat/wake-scan-parked-count-gate` preserved for audit; not merged.

Plan that spawned this attempt: `docs/superpowers/plans/2026-04-13-wake-scan-parked-count-gate.md`.

## Results table

| Attempt | Change | Δ flood_1m (n=10 paired) | Notes |
|---|---|---|---|
| 1 | Basic gate (no alignment, `.acquire` load) | **-11.0%** | Reviewer had flagged false-sharing risk (M1) during Task 3 review |
| 2 | Add `align(std.atomic.cache_line)` on `parked_count` | **-2.5%** | Recovered 8.5pp — confirms alignment was part of the cost |
| 3 | Attempt 2 + `.monotonic` load (remove acquire fence) | **-8.9%** | No improvement; load variance confound possible, but sign consistent across all 3 |

CPU frequency verified stable across all three attempts (±0.1% mean drift). Regressions are signal, not thermal.

## Key finding

**Adding a shared atomic counter with worker-side RMW frequency proportional to park/unpark rate is a net loss on `flood_1m`.** The saved 56 `seq_cst` loads when `parked_count == 0` do not compensate for:

1. Cacheline bouncing of `parked_count` as workers contend on fetchAdd/fetchSub.
2. The submitter's `.acquire` or `.monotonic` load cost on every spawn (1M/workload).
3. Ancillary cost of the branch itself on the hot path.

`flood_1m` saturates workers so fully that the "no parked workers" skip rarely triggers during the benchmark's active phase. Workers do park briefly between batches, enough to keep the counter traffic hot, but not enough to let the gate amortize its own cost.

## Lesson for future wake-scan work

A gate that short-circuits the scan needs to:

- Avoid writer contention. The counter is written by every worker on every park/unpark cycle — that's the expensive part, not the scan.
- Alternative: **shard** `is_parked[]` checks by worker-group rather than adding a global counter. E.g., partition 56 workers into 8 groups of 7; a submitter can short-circuit per-group using a group-local `parked_count_group[i]`. Fewer workers per group → less contention on each group counter.
- Or: **predictive/cached** hint — cache the "last known parked worker index" and check it first. If it's still parked, skip the full scan. Invalidate on unpark. Avoids any RMW on the common case.
- Or: **submit-side state** — track the expected "active workers" count based on work in queue, skip wakes when active >= min(queued, N_workers). No cross-thread synchronization needed.

None of these were in scope for this plan; they are candidates for a future brainstorm.

## Branch state

- `feat/wake-scan-parked-count-gate` contains all three attempts + tests + docs + the 20/20 stress log (which passed — no correctness regression, only perf regression).
- Branch left unmerged for audit / future reference.
- Worktree at `/home/benji/src/devnw/zig/thread-pool-wake-gate` can be removed at any time.

## Commits on the branch (for reference)

```text
bd0b4a3 perf(wake-gate): relaxed-load fast path (attempt 3)
6082383 docs(wake-gate): attempt 2 paired measurement (-2.5%)
2b590bf perf(wake-gate): align parked_count to cacheline (attempt 2 fix)
1f52ba7 docs(wake-gate): attempt 1 close-out (-11%, HOLD)
9a088a9 test(wake-gate): 20x ReleaseFast stress gate validation
b06e998 test(wake-gate): park/submit interleave guard
51183d5 perf(wake-gate): short-circuit enqueueTask wake-scan on parked_count==0
37d32e9 perf(wake-gate): maintain parked_count in idle() park/unpark paths
4f7c6fe perf(wake-gate): add Sync.parked_count atomic (unused)
```

## Status of the re-profile's next-action priority

The re-profile (`docs/performance/reprofile-2026-04-13/SUMMARY.md`) ordered:

1. **G3** — done, shipped as correctness-only slice (`docs/performance/counters-layout-fix/README.md`). Perf was null on current host.
2. **Wake-scan redesign** — this plan. ABANDONED after 3 variants all regressed.
3. **Architectural pivot** — Chase-Lev + event-wake + lock-free inject. The first two are already shipped (landed prior to this session — see `src/queue/work_deque.zig`, `src/queue/ring_queue.zig`, and the per-worker condvar park in `idle()`). Only `lock-free-inject-queue` remains, and it targets `contended_spawn_8x` (multi-submitter) not `flood_1m` (single-submitter).

For flood_1m specifically, the session's evidence suggests **the single-atomic optimization surface is exhausted**. The remaining path to Tokio parity requires a structural change to either:

- The work-distribution model (e.g., submit directly to a worker-local slot rather than an inject queue).
- The wake model (e.g., replace the mutex+condvar park with a direct futex call tree, bypassing std.Thread.Condition).
- The descriptor lifecycle (e.g., pre-allocated per-submitter pools so no atomic CAS on acquire).

These are larger undertakings than what the session had time to complete cleanly.

## Recommendation

Accept current flood_1m perf as the host's operating point. Re-run the re-profile A/B under fresh conditions (clean host, no co-tenants) to see if the 566K baseline is reproducible there — if yes, the session's 380-400K numbers are purely host drift and no perf claim about G3/wake-gate can be made. If 566K is NOT reproducible even on quiet host, then the re-profile's ceiling data is also stale and a full re-measurement is needed before planning further work.
