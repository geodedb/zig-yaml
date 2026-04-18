# A/B Stub: `counters.submitted.fetchAdd` Removed (G3 Ceiling Measurement)

**Task:** Task 3 of the 2026-04-13 re-profile plan.
**Purpose:** Measure the absolute throughput ceiling available by eliminating the submit-path `counters.submitted` atomic fetchAdd and its two downstream readers. This is an UNSAFE stub used for measurement only — it breaks the snapshot getter at `src/pool.zig:501` which would always read 0 for submitted. Not a merge candidate.

## Branch / SHA

- **Branch:** `profile/ab-submitted-fetchadd-stub`
- **SHA:** `df8d7b0a41e843a8be2ad9b232f8a24ce4bb69ee` (short: `df8d7b0`)
- **Main baseline:** `df8d7b0` (main HEAD at start of task)
- **Toolchain:** `zig build -Doptimize=ReleaseFast`

## Stub Lines (src/pool.zig)

Three edits, all in `src/pool.zig`:

1. **Line 597** — fetchAdd removed on submit hot path:

   ```zig
   // AB-STUB: submitted.fetchAdd removed to measure ceiling. Do not merge.
   ```

   (was: `_ = self.counters.submitted.fetchAdd(1, .monotonic);`)

2. **Line 607** — wake-hint reader removed:

   ```zig
   const submitted: u64 = 0; // AB-STUB: submitted reader removed
   ```

   (was: `const submitted = self.counters.submitted.load(.monotonic);`)

3. **Line 700** — steal-scan mixing removed:

   ```zig
   const start = worker_index % self.workers.len; // AB-STUB: submitted mixing removed
   ```

   (was: `const start = (worker_index +% @as(usize, @truncate(self.counters.submitted.load(.monotonic)))) % self.workers.len;`)

## Audit: Consumers of `counters.submitted`

Grep over `src/`, `benchmarks/`, `tests/` for `counters\.submitted` and `\.submitted`:

- **`src/pool.zig:501`** — snapshot getter `.submitted = self.counters.submitted.load(.acquire)`. With the stub, this always returns 0. Pre-approved as "tolerable" in the plan (see `docs/superpowers/plans/2026-04-13-reprofile-post-g2.md`, Step 2). It is a read-only observability path, not on the hot path.
- **`src/pool.zig:346, 349`** — these use a different `.submitted` field (local return-struct tagged field, `SpawnManyResult.submitted`), unrelated to `counters.submitted`.
- **`benchmarks/common.zig`** — references `submitted_at_ns` timestamps on a task struct; unrelated.
- **`tests/integration.zig:52`** — uses `SpawnManyResult.submitted`; unrelated.

**Result:** Only one additional consumer (`src/pool.zig:501`) exists, it is the expected snapshot reader, and it is non-hot-path. Stub is safe for measurement purposes.

## Build + Unit Tests

- **Clean rebuild:** pass (`rm -rf zig-out/ .zig-cache/ && zig build -Doptimize=ReleaseFast` succeeded).
- **`zig build test`:** pass (exit 0). All unit tests green with the stub applied.

## 20× Stress Gate

- **Command:** `zig build test-stress -Doptimize=ReleaseFast` × 20.
- **Result:** pass=20, fail=0.
- Log: `docs/performance/reprofile-2026-04-13/ab-submitted-stress.txt`.

## flood_1m n=10 Measurement

- Binary: `zig-out/bin/thread-pool-tokio-parity flood_1m`.
- Raw: `docs/performance/reprofile-2026-04-13/ab-submitted-raw.txt`.

| Metric | Value |
|--------|-------|
| n      | 10    |
| min    | 657,766 ops/s |
| median | 803,425 ops/s |
| max    | 1,027,592 ops/s |

Per-run ops/s (sorted): 657766, 663223, 716328, 723100, 734180, 872670, 929269, 970612, 979643, 1027592.

## Lift Computation

- **Baseline (Task 1, commit `3506b29`):** 566,000 ops/s (median of 10 flood_1m runs).
- **Stubbed median:** 803,425 ops/s.
- **Relative lift:** `(803425 - 566000) / 566000 * 100 = +41.95%`.
- **Absolute lift:** 803,425 - 566,000 = **+237,425 ops/s**.

### Comparison to Pre-G2 Ceiling

Per the plan, the pre-G2 A/B equivalent measured +28% versus a 331K ops/s pre-G2 baseline, i.e., 331000 × 1.28 = 423,680 ops/s, an absolute lift of +92,680 ops/s at that baseline level.

Translating that prediction to the current 566K baseline:

- If the same +28% relative factor held, expected stubbed = 566000 × 1.28 = **724,480 ops/s** (absolute lift +158,480 ops/s).
- If the same +92,680 absolute compute savings held, expected stubbed ≈ **658,680 ops/s**.

**Observed:** 803,425 ops/s / +237,425 absolute. This **exceeds both projections**:

- Relative: +41.95% vs +28% predicted (≈1.5× the predicted relative lift).
- Absolute: +237K vs +158K (relative-scaled) or +93K (absolute-held) predicted.

## Interpretation (in light of Task 2)

Task 2 established that the submitter thread is 100% CPU-bound with zero voluntary blocks — so any compute saved on the submit hot path converts directly to throughput. The A/B stub confirms this mechanistically:

- The submit-side `fetchAdd` is on the dominant hot path, hit once per task (1M times in flood_1m).
- Removing it (plus the two downstream readers) yields a +42% throughput lift — substantially larger than the pre-G2 prediction because the fresh baseline already has the G2 wake/idle simplifications, which raises the share of remaining submit-path overhead that the stub addresses.
- The stress suite is unaffected (20/20), meaning the `counters.submitted` dependency is not load-bearing for correctness in the current steady-state paths — only the snapshot reader at :501 is affected, and it is observability-only.

**The +42% ceiling is real and well-beyond noise**: min 657K already exceeds baseline median 566K by +16%, i.e., every stubbed run beat the baseline median.

## Recommendation

**PRIORITIZE.** The ceiling is large (+42% / +237K ops/s), reproducible (10/10 runs above baseline median), and safe with respect to the test harness (20/20 stress, 100% unit tests). Replacing `counters.submitted` with either:

1. a per-worker counter summed on the read path (snapshot getter at :501, test-only), or
2. approximate mixing that does not require cross-thread coherency (e.g., per-submitter thread-local counter, or pseudo-random from the task pointer), or
3. eliminating the wake-hint rotation entirely if benchmarks show the uniform `worker_index`-only start is adequate,

should recover the bulk of this ceiling. The stress stability indicates the rotation-based load spread is not a correctness requirement for the current wake path; it is only a load-distribution heuristic.

**Next step (outside this task):** design a per-worker or pointer-derived replacement, A/B it against this stub to see how much of the 42% ceiling a real (non-stubbed) replacement captures.

## Files

- Stub diff on branch `profile/ab-submitted-fetchadd-stub`: `src/pool.zig` (3 lines).
- Raw flood_1m: `docs/performance/reprofile-2026-04-13/ab-submitted-raw.txt`.
- Stress log: `docs/performance/reprofile-2026-04-13/ab-submitted-stress.txt`.
- This report: `docs/performance/reprofile-2026-04-13/ab-submitted-fetchadd.md`.
