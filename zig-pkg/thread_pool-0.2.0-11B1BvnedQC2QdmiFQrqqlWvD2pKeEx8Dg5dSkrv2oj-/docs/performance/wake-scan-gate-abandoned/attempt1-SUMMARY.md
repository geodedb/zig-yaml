# Wake-Scan Parked-Count Gate — Close-Out (Attempt 1)

## Result

| Measurement | Median | Min | Max | n |
|---|---|---|---|---|
| PRE-gate (main `fa371be`) | 401.9K | 369.5K | 526.0K | 10 |
| POST-gate (branch `9a088a9`) | 357.6K | 337.6K | 459.7K | 10 |

**Delta:** -11.01% relative, -44.2K ops/s absolute.

A/B ceiling reference: +34.8% (re-profile Task 5, wake-scan REMOVED entirely). Plan retained the scan for the non-fast-path case; realistic capture was expected to be partial.

**Capture fraction vs A/B ceiling:** -31.6% of the 34.8% ceiling (moved the opposite direction).

**Decision:** HOLD-REGRESSION (delta < -2% per Task 6 thresholds).

## CPU frequency (noise check)

- PRE-gate: min 2896 MHz / mean 2908 MHz / max 3300 MHz
- POST-gate: min 2896 MHz / mean 2911 MHz / max 3300 MHz

Mean delta: +0.1%. Well under the 10% noise-contamination threshold — paired comparison is valid. The regression is real, not a thermal/frequency artifact.

## Stress

- 20/20 PASS at ReleaseFast (`stress-20x.txt`, commit `9a088a9`).
- Unit test `wake-gate: no lost wakeup under park/submit interleave` PASSES (commit `b06e998`).

## Sub-changes (attempt 1)

1. Add `Sync.parked_count` field (commit `4f7c6fe`).
2. Worker maintenance in `idle()` park/unpark paths (commit `37d32e9`).
3. Submitter fast-exit in `enqueueTask` (commit `51183d5`).
4. Park/submit interleave regression test (commit `b06e998`).
5. Stress log (commit `9a088a9`).

## Host-load context

- Pre-gate load: start 3.48, end 5.08 (1-min)
- Post-gate load: start 4.19, end 5.91 (1-min)
- Co-tenant: `geode` PID 1826424 owned by user `geode` (cannot kill) at ~100% CPU throughout.
- Frequency stability (see above) implies the regression is not a load-drift artifact. 11% gap exceeds plausible load-drift noise for a benchmark where CPU frequency remained pinned.

## Triage candidates

The code reviewer on Task 3 already flagged **M1 (cacheline false-sharing)** as a concern: `Sync.parked_count` lives adjacent to `backpressure_waiters` with only mutex/cond members in between (which do not guarantee cacheline alignment). Under flood_1m:

1. **Cacheline false-sharing on `Sync.parked_count`.** Workers park/unpark frequently in flood_1m steady state (they grab a task, run, briefly park between batches). Each park writes parked_count (fetchAdd). Each unpark writes it again (fetchSub). The submitter reads it with `.acquire` on every single spawn (1M times for flood_1m). If parked_count shares a cacheline with any other hot Sync field (including `backpressure_waiters`, the mutexes' `Held` state, or the condvars' waiter lists), every write invalidates the submitter's cacheline and every read invalidates worker cachelines. The cacheline bouncing can easily exceed the 56 seq_cst loads we were trying to avoid.

2. **Hot-path `.acquire` fence cost on the fast path.** Even when `parked_count == 0`, the `.acquire` load on every `enqueueTask` call adds a memory-ordering fence that wasn't present before. On x86_64 an acquire load is just a mov (no mfence), so this is small, but it's not free — and it compounds across 1M calls.

3. **Contended RMW on parked_count during steady-state.** Workers repeatedly park/unpark during flood_1m. Every transition is a global atomic RMW contending across all 56 workers. Per-worker `is_parked[i]` slots avoid this contention; the gate reintroduces it at the park-cycle level.

## Next attempt (attempt 2 will follow)

Apply cacheline padding around `parked_count` — isolate it onto its own line so the worker park/unpark RMWs don't false-share with any hot submit-side read. If attempt 2 is still a regression, HOLD permanently and pivot.

## Raw data

- `flood_1m-pre-n10.txt` — pre-gate n=10 raw output.
- `flood_1m-post-n10.txt` — post-gate n=10 raw output.
- `cpu-freq-log.txt` — frequency samples during both phases.
- `stress-20x.txt` — 20× stress gate log.
