# A/B Stub: Wake-Scan Removal (Task 5)

## Metadata

- **Task:** 5 of `docs/superpowers/plans/2026-04-13-reprofile-post-g2.md`
- **Branch:** `profile/ab-wake-scan-stub`
- **Stub commit SHA:** `663105c` ("perf(ab-stub): remove wake-scan in spawn — DO NOT MERGE")
- **Base:** `5eaec43` (main HEAD, Task 4 report cherry-picked)
- **Build:** `zig build -Doptimize=ReleaseFast`
- **Date:** 2026-04-13

## Stub Variant Used

**PRIMARY (no-wake)**. The full 56-iteration `is_parked[]` scan + mutex + `park_cond.signal()` block at `src/pool.zig:607-624` was replaced with a 3-line comment. The weaker fallback (Step 5a) was NOT needed — flood_1m completed on first attempt.

Diff summary: -18 lines / +3 lines in `spawn()` post-`incrementQueued()`.

## Build + Unit Test Result

`zig build` succeeded. `zig build test`:

- 38/39 unit tests passed
- 1 FAILED: `unit.test.phase g2: worker returns from idle when lifo slot filled during spin window`
  - Asserts `ran_at != 0` at `tests/unit.zig:523` — a task pushed to LIFO never ran. This is EXACTLY a lost-wakeup symptom, entirely expected under the stub since the submit path no longer signals a parked worker.
- The remaining test `unit.test.phase h regression: state CAS gate rejects duplicate descriptor dispatch` did not execute because the prior test failure aborted the cache segment (transitive failure, NOT an independent regression).

**Classification:** wake-related; expected; non-blocking for the A/B measurement.

## Load Captures

| Measurement block | uptime / load avg (1m, 5m, 15m) |
|---|---|
| Branch creation (pre-stub) | `19:58:53 up 4 days, 2:52, load avg: 15.12, 14.68, 14.74` |
| Stress gate — end          | `20:01:26 up 4 days, 2:55, load avg: 24.31, 17.13, 15.55` |
| flood_1m n=10 — start      | `20:01:36 up 4 days, 2:55, load avg: 22.07, 16.98, 15.53` |
| flood_1m n=10 — end        | `20:01:51 up 4 days, 2:55, load avg: 29.93, 19.06, 16.24` |

Host load AVERAGED ~20 across measurements, trending UPWARD during the runs (1m load doubled from ~15 to ~30). Geode background processes confirmed still active per plan warning.

Baseline (Task 1, commit `3506b29`) was captured at a notably lower load — Task 1 median of 566K ops/s is the reference, but the baseline was collected before the current geode spike. This biases toward UNDER-estimating the stubbed lift (same stubbed code would likely produce higher ops/s on an idle host).

## Stress Result (20× gate)

- **Completed:** 20/20 iterations (target=20)
- **Pass:** 20
- **Fail:** 0
- **Per-iteration wall-clock distribution:** 1× 17s (cold cache on run 1), 19× in [2s, 3s]. Median ≈ 3s. No hangs, no 5-min timeouts.
- **Expected-vs-unexpected:** Going in, the plan predicted "many stress tests will hang or fail". Surprising result — ALL stress scenarios passed. Interpretation: the stress test workloads keep workers busy enough in their steal loops that workers rarely (or never) transition to fully parked during the test. The lost-wakeup failure mode only manifested in the targeted `phase g2` unit test, which deliberately waits for a worker to park before pushing a LIFO task.

This contradicts the plan's prior assumption that the wake-scan is essential for stress correctness at this workload intensity. It remains essential for intermittent-load or quiescent-then-burst workloads (see the unit-test failure).

## flood_1m n=10 Results

| Stat | ops/s |
|---|---|
| min | 573,029 |
| median | 763,160 |
| max | 875,518 |
| n (valid) | 10/10 |
| TIMEOUT/CRASH | 0 |

Raw runs: 681315, 721415, 850834, 776665, 678090, 875518, 780506, 573029, 839907, 749656.

### Lift vs baseline

```text
lift = (763160 - 566000) / 566000 * 100 = +34.8%
```

Baseline 566K ops/s → stubbed 763K ops/s = **+34.8%**.

## Pre-G2 Ceiling Caveat

The original plan cites a pre-G2 A/B ceiling of +47% (i.e. from 331K baseline → 488K absolute). Two adjustments:

1. **Submitter CPU state changed.** Task 2 showed submitter is now 100% on-CPU with zero voluntary context switches. Pre-G2 it was ~89% running. The +47% pre-G2 figure bundled off-CPU wakeup-and-recovery time that no longer exists, so we should expect the post-G2 ceiling to be LESS than +47%.
2. **Different baseline regime.** Post-G2 baseline is 566K, not 331K, so percentage gains should be evaluated on the post-G2 reference.

Observed +34.8% is lower than the pre-G2 +47% and consistent with adjustment (1). Additionally, the submitted.fetchAdd stub (Task 3) already delivered +42% — it is plausible that the fetchAdd load and the wake-scan overlap in cost or contend on the same cache line / submit stall, so stacking them may not simply add.

## Interpretation vs Tasks 2/3/4

- **Task 3 (submitted.fetchAdd stub):** +42% (566K → 803K median).
- **Task 5 (wake-scan stub):** +34.8% (566K → 763K median).
- **Task 4 (descriptor CAS stub):** -14% under host-load confound (DEPRIORITIZED).

The wake-scan is arguably the second-most promising target after submitted.fetchAdd. Two possibilities for stacking:

- **Orthogonal:** the wake-scan iterates `is_parked[]` + touches a per-worker mutex; submitted.fetchAdd is a single atomic on a shared counter. Different cache lines, different contention sources → stacking might approach the sum (~80% combined).
- **Cannibalized:** if the dominant cost is "time spent in spawn() post-push stalling the submitter thread on memory traffic", then removing either one unblocks the same bottleneck. The two stubs would recover most of the same wall-clock.

Task 2's perf-sched trace suggests the submitter is CPU-bound, not sched-bound, which is more consistent with memory/cache stalls than with lock/wake latency. That weakly favors the **cannibalized** hypothesis. A combined A/B (remove both in one stub) is the next investigative step to disambiguate.

The wake-scan stub's +34.8% is still a strong signal that *something* in the post-`incrementQueued()` block is on the critical path. It is additive to whatever G3/wake-design changes land — just not necessarily fully additive.

## Host-Load Confound

| Measurement | 1m load avg when captured | Comment |
|---|---|---|
| Task 1 baseline (566K) | pre-geode-spike (clean) | reference |
| Task 5 stress         | 24.3                    | 2× Task-1 baseline load |
| Task 5 flood_1m       | 22–30 (rising)          | significantly elevated |

Task 5 ran under substantially elevated host load (1m load avg 22–30 vs ~clean baseline). The stubbed measurement is therefore a CONSERVATIVE estimate of the true ceiling: +34.8% on a dirty host is likely a FLOOR for what this stub would achieve on an idle host. The direction of the bias is clear (positive result is still positive; actual lift could be higher).

However, unlike Task 4 where host load dragged stress wall-clock into pathological territory (7151s), Task 5's stress iterations stayed bounded at 2–3s. This suggests the wake-scan removal is NOT sensitive to host noise the way the descriptor-CAS stub was. We can be more confident in this measurement than in Task 4's.

**Verdict: measurement is SUSPECT due to load but the sign and rough magnitude are trustworthy. A re-measurement on an idle host is advisable before acting on the exact +34.8% figure.**

## Recommendation

**PRIORITIZE with caveat.** Wake-scan removal / redesign is the strongest non-G3 candidate we've measured. Direction and magnitude survive the host-load confound. The stubbed form is non-mergeable (breaks parked-worker wakeups), so the real work is to DESIGN a correctness-preserving replacement that captures the same wall-clock savings. Candidates:

- Replace the 56-iter scan with a lock-free parked bitmask and a trailing-zeros popcount pick.
- Bound the scan length (e.g. 1–4 iterations) plus a lazy broadcast fallback triggered by a separate "pushed-but-not-consumed" counter.
- Skip the scan entirely when `queued_tasks > workers.len` (workers will pick up via steal loop regardless of signal).

Before committing eng effort, Task 6 should re-measure this stub on an idle host to confirm the +34.8% figure and run a combined G3+wake-scan A/B to test the cannibalized-vs-additive hypothesis.
