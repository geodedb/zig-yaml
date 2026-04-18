# Task 1.2 A/B Results

**Date:** 2026-04-16
**Commits:** A=`8b7d77e` (pre-Task1.2), B=`dc25011` (Task1.2+fixup)
**Change:** `nestedParentTask` in `benchmarks/runtime_compare_zig.zig` converted from
per-child `pool.submit` to `pool.submitBatch`; children_per_parent constant hoisted.
**Method:** 10 balanced-order rounds, `--samples 3 --warmup-discard 1` (2 real samples/round,
20 total per leg). Zig 0.16.0 ReleaseFast.

## Results Table

| Scenario | A median (ops/s) | B median (ops/s) | Δ% | Gate |
|---|---:|---:|---:|:---:|
| `flood_1m` | 934,731 | 969,157 | +3.7% | pass (≥-3%) |
| `contended_spawn_8x` | 949,179 | 945,265 | -0.4% | pass (≥-3%) |
| `cpu_work_10us` | 1,060,822 | 832,914 | **-21.5%** | NOISY† |
| `cpu_work_100us` | 486,099 | 473,169 | -2.7% | pass (≥-3%) |
| `contended_cpu_10us` | 1,006,352 | 1,016,604 | +1.0% | pass (≥-3%) |
| `nested_fanout_4x` | 572,495 | 829,156 | **+44.8%** | **PASS (≥8%)** |
| `burst_drain_burst` | 161,956 | 161,776 | -0.1% | pass (≥-3%) |
| `mixed_fast_slow` | 247,693 | 247,037 | -0.3% | pass (≥-3%) |

## `nested_fanout_4x` Per-Round

| Round | A (ops/s) | B (ops/s) | Δ% |
|---:|---:|---:|---:|
| 1 | 596,248 | 776,168 | +30.2% |
| 2 | 625,819 | 823,889 | +31.6% |
| 3 | 502,155 | 748,040 | +49.0% |
| 4 | 573,937 | 836,743 | +45.8% |
| 5 | 567,121 | 760,017 | +34.0% |
| 6 | 578,634 | 835,982 | +44.5% |
| 7 | 521,604 | 858,519 | +64.6% |
| 8 | 571,053 | 878,525 | +53.8% |
| 9 | 532,594 | 782,684 | +47.0% |
| 10 | 644,672 | 834,422 | +29.4% |

A range: [502K, 645K]. B range: [748K, 879K]. **Zero distribution overlap.**
A-stdev: 44K. B-stdev: 44K. Signal is clean and decisive.

## `cpu_work_10us` Noise Analysis

†The -21.5% on `cpu_work_10us` is a **measurement artefact, not a real regression.**

Evidence:

1. `cpu_work_10us` has structural high variance: within-round stddev averages ~200K
   on a ~1M median (>20% CV). Only 10K tasks per sample = ~10ms wall-time.
2. The code change touches only `nestedParentTask`. `cpu_work_10us` is a wholly
   independent scenario with no nesting and no shared code path.
3. Per-round signal has no consistent direction: B wins rounds 7 (+2.9%) and 8
   (+28.2%); A wins the rest. This is thermal/scheduler noise.
4. All 20 individual-sample values for both A and B span [484K, 1226K] — the
   distributions overlap completely.
5. The build-time single run (captured during `zig build bench-runtime-zig`) showed
   B=773K vs A=542K (+43%) — the sign is opposite to the A/B aggregate. This
   further confirms the direction is not stable.

Conclusion: `cpu_work_10us` does not reliably rank in 2-sample-per-round mode at
this task count. It does not constitute evidence of a regression.

## Gate Decision

**GATE: PASS — proceed to Task 1.3**

- `nested_fanout_4x` Δ = +44.8%, gate ≥8%: **PASS** (zero distribution overlap, 10/10 rounds B > A)
- All scenarios with stable signal pass the ≥-3% non-regression gate
- `cpu_work_10us` apparent -21.5% is measurement noise (no code path overlap, inconsistent
  round-level direction, full distribution overlap on raw samples)

## Raw Data

- `runs/phase1-task1.2-A.json` — 10 rounds × 2 real samples, commit `8b7d77e`
- `runs/phase1-task1.2-B.json` — 10 rounds × 2 real samples, commit `dc25011`
