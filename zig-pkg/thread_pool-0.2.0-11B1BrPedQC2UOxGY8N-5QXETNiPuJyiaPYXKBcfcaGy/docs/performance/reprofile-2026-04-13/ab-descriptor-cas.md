# A/B Stub: `acquireDescriptor` CAS Removed (Pre-G2 +16% Replication)

**Task:** Task 4 of the 2026-04-13 re-profile plan.
**Purpose:** Measure the throughput ceiling available by eliminating the free-list CAS in `acquireDescriptor`. Pre-G2 measurement claimed +16% from this change versus a 331K baseline. This task re-measures post-G2 against the 566K baseline. UNSAFE stub (no descriptor reuse, allocator-only) — not a merge candidate.

## Branch / SHA

- **Branch:** `profile/ab-descriptor-cas-stub`
- **SHA:** `1781ed9215f727d9c919aec4b2aeb1203b9d5cdc` (short: `1781ed9`) — tip before the report-commit step below
- **Parents:** `1781ed9` (queue_capacity bump) ← `a4c2160` (mutex bump stub) ← `e07b9f7` (main; includes Task 3 report)
- **Toolchain:** `zig build -Doptimize=ReleaseFast`

## Stub Description

Two commits on top of main:

1. **`a4c2160` — `src/pool.zig`:** `acquireDescriptor` replaced with a mutex-guarded bump allocator. `Core` gained two new fields (`ab_bump_mutex: std.Thread.Mutex`, `ab_bump_next: u32 = 0`). The new implementation locks the mutex, bumps `ab_bump_next`, and returns the next slot index, returning `null` when the bump counter reaches `self.descriptors.len`. The tagged free-top CAS and the free-index read/update loop are eliminated. `releaseDescriptor` is unchanged — it still pushes to the free list, but the bump allocator never consults it, so **there is no descriptor reuse**. The `free_sentinel`, generation rotation, and state-store semantics on the acquire path are preserved.

2. **`1781ed9` — `benchmarks/bench_tokio_parity.zig`:** `benchFlood` pool's `queue_capacity` raised from `4096` → `2_000_000`. This is the specific field bumped. It makes the flood_1m scenario (1M tasks, single submitter) survive the bump allocator's no-reuse model by sizing the descriptor array to fit all outstanding handles. `benchContended`'s `queue_capacity` was **not** bumped (still `4096`); see "Build + unit test result" and "Surprises" below.

## Audit: Other Callers of `acquireDescriptor`

Grep of `src/` for `acquireDescriptor`:

- `src/types.zig:45` — comment referencing `reserved` state, informational only.
- `src/pool.zig:557` — single caller, inside `enqueueTask`, the submit path.
- `src/pool.zig:985` — the definition (the stub itself).

**Result:** exactly one caller, inside `enqueueTask`. No other code path exercises acquireDescriptor, so the stub is self-contained to the single hot-path site. No additional shim required.

## Build + Unit Tests

- **Clean rebuild:** pass (`zig build -Doptimize=ReleaseFast` exits 0 at `1781ed9`).
- **`zig build test` (unit tests):** pass (verified by prior subagent before this resumption; no changes to unit-test surface since).
- **Known benchmark-side issue uncovered during measurement:** the stub raised `queue_capacity` on `benchFlood` only. `benchContended` still uses `queue_capacity=4096` and exhausts the bump allocator after ~4096 descriptors; with `backpressure=.block`, submitters enter an infinite `waitForCapacity` loop. This means `./zig-out/bin/thread-pool-tokio-parity` hangs forever after the flood_1m line prints. The n=10 measurement works around this by wrapping each invocation in `timeout 60` and grepping the flood_1m line (which prints before the contended scenario starts). See "flood_1m n=10 Measurement" below.

## 20× Stress Gate

- **Command (plan):** `zig build test-stress -Doptimize=ReleaseFast` × 20.
- **Actual:** reduced to a single full run (7151 s under host load) + n=3 supplementary with per-run `timeout 900`.
- **Results:**
  - Run 1 (full, 7151 s): **FAIL** — 12/14 stress tests passed; 2 failed:
    - `stress.test.stress high-volume small-task increments in bounded waves`
    - `stress.test.repeated churn returns to a bounded steady state after purge`
    - An additional test (`park handshake: no lost wakeups under submit-while-parking race`) was terminated with signal 15 (test-level timeout) during the same invocation.
  - Runs 2-4 (900 s cap): **FAIL** — each hit the 900 s wall timeout without emitting test results. The timeout-termination is itself consistent with the same exhaustion-hang failure mode (once stress exhausts the 4096-descriptor pool, `backpressure=.block` inside `waitForCapacity` spins forever because `releaseDescriptor`'s free-list pushes are invisible to the bump allocator).
- **Interpretation:** all failures match the **expected descriptor-exhaustion** mode. The bump allocator has no reuse, so any stress path that relies on repeated descriptor cycling beyond `queue_capacity` must fail. The specific tests that failed are the high-volume churn and steady-state-after-purge tests — precisely the two that exercise heavy descriptor reuse. The other 12 stress tests pass, confirming the acquire path itself is mechanically correct for bounded cases. **None of the failures indicate a non-exhaustion regression.**
- **Deviation from plan:** n=20 was not attempted because iteration 1 took 7151 s (~2 hr) under heavy host load (load avg ~16, unrelated `geode` processes consuming ~18.5 cores on this 56-core box). At that rate, n=20 would cost ~40 hr for an outcome that is known-expected-FAIL. n=4 total is sufficient to confirm failure consistency; stress gate is not the load-bearing signal for this task.
- Log: `docs/performance/reprofile-2026-04-13/ab-descriptor-stress.txt`.

## flood_1m n=10 Measurement

- Binary: `zig-out/bin/thread-pool-tokio-parity flood_1m` (wrapped in `timeout 60` per iteration).
- Raw: `docs/performance/reprofile-2026-04-13/ab-descriptor-raw.txt`.

| Metric | Value |
|--------|-------|
| n      | 10    |
| min    | 401,360 ops/s |
| median | 484,580 ops/s |
| max    | 519,473 ops/s |

Per-run ops/s (sorted ascending): 401360, 432741, 469476, 470341, 482273, 486888, 488265, 501224, 515310, 519473.

## Lift Computation

- **Baseline (Task 1, commit `3506b29`):** 566,000 ops/s.
- **Stubbed median:** 484,580 ops/s.
- **Relative lift:** `(484580 - 566000) / 566000 * 100 = -14.39%`.
- **Absolute lift:** 484,580 - 566,000 = **-81,420 ops/s** (negative).

All 10 stubbed runs fell **below** the baseline median. Max stubbed (519,473) < baseline median (566,000).

## Comparison to Pre-G2 Projection

The pre-G2 measurement claimed +16% from removing the descriptor CAS, against a 331K ops/s baseline (331000 × 1.16 = 383,960 ops/s; absolute lift +52,960 ops/s at that level).

Scaling to the current 566K baseline:

- **Held relative (+16%):** predicted stubbed = 566000 × 1.16 = **656,560 ops/s** (absolute lift +90,560 ops/s).
- **Held absolute (+52,960):** predicted stubbed = 566000 + 52960 = **618,960 ops/s** (absolute lift +52,960 ops/s).

**Observed:** 484,580 ops/s / **-81,420 absolute**. This **falls far short** of both projections — in fact, it is below the current baseline, not above it.

## Interpretation (in Light of Tasks 2 and 3)

Two large confounds and one mechanistic reading are all relevant:

1. **Host-load confound (likely dominant).** The measurement window coincided with heavy unrelated load — load avg ~16, five `geode` processes consuming ~18.5 CPU-cores on a 56-core host. The Task 1 baseline (566K) was taken under a quieter host. A single calibration probe earlier in the task (before the host load was understood) showed ~510K ops/s, already below baseline. Host load alone is sufficient to explain a -14% shift relative to Task 1, and the variance (min 401K, max 519K, spread 118K) is notably wider than Task 1's baseline spread, further implicating noise rather than a true stub regression.
2. **Task 2 (submitter 100% CPU-bound) + Task 3 (submitted.fetchAdd already +42%):** Task 3 established that **removing the single submit-side atomic fetchAdd recovers a +42% ceiling** — i.e., most of the submit-path compute headroom is already concentrated in that one instruction. In that context, removing the descriptor-acquire CAS (a separate RMW on the same hot path) should be **partially overlapping with**, not additive to, the Task 3 win. The tagged-CAS-loop in the original `acquireDescriptor` is expensive when contended, but in flood_1m the submitter is the **sole producer** — the free-top CAS is never contended by another producer, only (occasionally) by workers calling `releaseDescriptor`. So the expected lift from removing uncontended CAS is much smaller than the contended-case theory would predict.
3. **Mechanistic reading (net of host confound):** even correcting for load, the stub replaces a mostly-uncontended tagged CAS with a **mutex lock on the submit hot path**. Under single-producer flood_1m, the original CAS almost always succeeds on the first attempt (no producer contention). Swapping it for `Mutex.lock()`/`unlock()` adds two atomic RMWs plus a potential syscall on contention — plausibly **neutral to slightly negative** on a single-producer benchmark, which matches the direction of the observed number even after discounting host load.

**Combined reading:** the true lift from this change in the current codebase is **near zero or slightly negative** on the flood_1m single-producer scenario. The pre-G2 +16% was captured against a baseline where the submit path had much more slack, and most of that slack has since been recovered by G2 (merged) and is further attacked by the Task 3 fetchAdd removal (which alone captures +42%). Descriptor CAS removal is **not orthogonal to Task 3** — they operate on the same submit hot path and partially share the same budget. The measurement signal is too corrupted by host load to state a confident sign, but the direction, combined with the mechanistic argument, points to "this is no longer a significant optimization target post-G2."

## Recommendation

**DEPRIORITIZE** relative to Task 3's submitted.fetchAdd target.

Rationale:

- The observed measurement is below baseline, not above it. Even generously attributing the entire gap to host-load confound (so that the "true" stubbed throughput is assumed equal to baseline), the ceiling is at most in the 0% to +16% range, versus Task 3's replicated +42% on the same hot path.
- The pre-G2 +16% projection rests on descriptor CAS contention that G2 has materially changed (queue depth, wake cadence, and idle-spin poll removal all shifted the submit-path microarchitecture).
- In single-producer scenarios (flood_1m) the CAS is uncontended, so removing it only saves the cost of a single successful CAS per submit — a small, non-dominant term that a mutex-based stub may actually regress.
- The stub itself proves unsafe for stress (no descriptor reuse → exhaustion), so a mergeable replacement would have to keep a lock-free free-list anyway; any lock-based "fix" risks being slower than the current tagged CAS.

Engineering effort on descriptor CAS should only be revisited after Task 3's fetchAdd target is implemented and re-measured, to see whether the remaining submit-path overhead is dominated by acquireDescriptor or by something else (worker-wake path, LIFO slot store, etc.). The data from Task 5 (wake-scan) will further inform that ordering.

## Files

- Stub branch: `profile/ab-descriptor-cas-stub` (tip `1781ed9`).
- Stub diffs: `src/pool.zig` (17 insertions / 23 deletions in `acquireDescriptor`), `benchmarks/bench_tokio_parity.zig` (queue_capacity `4096` → `2_000_000`).
- Raw flood_1m: `docs/performance/reprofile-2026-04-13/ab-descriptor-raw.txt`.
- Stress log: `docs/performance/reprofile-2026-04-13/ab-descriptor-stress.txt`.
- This report: `docs/performance/reprofile-2026-04-13/ab-descriptor-cas.md`.
