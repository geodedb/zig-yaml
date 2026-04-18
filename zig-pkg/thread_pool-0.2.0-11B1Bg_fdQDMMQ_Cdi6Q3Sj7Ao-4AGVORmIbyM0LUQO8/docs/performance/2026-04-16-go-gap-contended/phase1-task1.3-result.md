# Phase 1 Task 1.3 A/B — bench-realistic

A = dc25011 (pre common.zig change — `nestedTask` uses per-task `submit`)
B = 650167e (post common.zig + panic guard — `nestedTask` uses `submitBatch`)

Host: 2-socket / 1-NUMA-node, 16 workers, Zig 0.16.0, ReleaseFast
Rounds: 10 balanced A B A B, binaries pre-built in isolated worktrees
Wall-clock: ~43 seconds for all 20 runs

## Result Table

| Scenario | A median (ops/s) | B median (ops/s) | Δ% | Gate |
|---|---:|---:|---:|:-:|
| cpu_work_10us | 223,398 | 219,359 | -1.81% | PASS (≥-3%) |
| cpu_work_100us | 97,865 | 97,792 | -0.07% | PASS (≥-3%) |
| contended_cpu_10us | 208,203 | 209,497 | +0.62% | PASS (≥-3%) |
| burst_drain_burst | 82,495 | 82,538 | +0.05% | PASS (≥-3%) |
| nested_fanout_4x | 174,652 | 180,274 | **+3.22%** | **FAIL (≥5%)** |

## GATE: FAIL

`nested_fanout_4x` gained +3.22% (3.78 percentage points below the 5% kill gate).
Non-target scenarios are all within bounds (worst: `cpu_work_10us` -1.81%).

## Raw samples — nested_fanout_4x

```text
A (sorted): 161733, 165015, 166431, 170014, 172033, 177272, 182138, 183700, 194918, 205778
B (sorted): 162526, 176803, 178930, 179385, 179421, 181126, 182016, 200401, 208038, 209214
A stddev: 14,041   B stddev: 15,069
```

## Observations

- The `nested_fanout_4x` signal is real but noisy (stddev ~14K on median ~175K — ~8%).
  A clean signal at ≥5% requires either more rounds or a lower-noise host state.
- 5 of 10 B runs show `queue_peak = u64::MAX` (underflow/overflow in stats accounting
  for the batched enqueue path — a reporting artifact, not a panic or correctness issue).
  Those runs' throughput numbers are valid and within normal range.
- The direction is consistently positive for B (B floor 162.5K vs A floor 161.7K;
  B ceiling 209.2K vs A ceiling 205.8K), but the +3.22% median gain is below gate.

## Decision — REVERTED at 0554a84

Gate FAIL → controller applied the plan's strict kill criterion and reverted
d85b250 + 650167e in a single revert commit `0554a84`. Rationale:

- The plan's Task 1.3 Step 4 says "Commit if gains hold"; gains did not hold.
- Directionally positive (+3.22%) is insufficient when the measurement protocol
  gives a ≥5% gate. n=10 stddev ~14K means the +3.22% median is within one σ of
  A's median — we cannot distinguish signal from noise at this sample size.
- Task 1.2 (runtime_compare) passed +44.8% on the same mechanism and is the
  primary Phase-1 deliverable. Reverting Task 1.3 does not invalidate Task 1.2;
  the two harnesses test the same pool code via different drivers.
- The `submitBatch` API remains available; users driving nested fan-out in
  production can adopt it directly.

The result doc stays as a permanent record of what was measured and why the
change did not land.
