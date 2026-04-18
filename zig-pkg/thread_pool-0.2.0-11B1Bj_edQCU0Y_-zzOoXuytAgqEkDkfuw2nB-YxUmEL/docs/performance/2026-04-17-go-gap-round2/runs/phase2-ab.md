# Phase 2 A/B — batched submitBatch fast path (tryPushBottomN / tryPushN)

## Legs

- **A** = `a666ec3` — Phase-0 baseline (Go-gap round 1 FINAL HEAD). `submitBatch` is the pre-existing per-task loop over `enqueuePush`, with per-submitter and per-worker `DescCache` already in place.
- **B** = `3b9fa1b` — Phase-2 HEAD. Adds batched producer-push primitives and wires a fast path through `submitBatch`:
  - `WorkDeque.tryPushBottomN` (dfdf9f9): bulk-store N values at `bottom..bottom+n`, then single `.release` publish of the new bottom.
  - `RingQueue.tryPushN` (71e9b9b): SPSC equivalent for per-submitter queues.
  - `LocalQueue.tryPushBottomN` (37c7c00): union dispatcher for the Chase–Lev / ring variants.
  - `submitBatchWorkerFast` / `submitBatchSubmitterFast` (4b16750): bulk-acquire N descriptors from `DescCache`/freelist, initialize all bodies, lifo-rotate NEWEST into `lifo_slot` (worker-context only), push the rest via `tryPushBottomN`. On short-push, partial rollback releases unused descriptors and falls through to the slow per-task loop for the tail.
  - Descriptor-leak fix (3b9fa1b): rollback path now lets `releaseDescriptor`'s internal `.queued → .free` CAS handle cleanup rather than flipping state externally (which short-circuited `task_desc_live.fetchSub` and the freelist re-push).
  - Plus Task 2.1/2.2/2.4 boundary + regression unit tests (d4025f1, 4b16750 test body, 3b9fa1b C-1 regression test).

## Protocol

Paired balanced-order A/B (A, B, A, B, …), n=10 rounds, ReleaseFast, 56 workers. `./scripts/run-runtime-comparison.sh --samples 3 --warmup-discard 1` per invocation → 2 retained samples per run → 20 raw Zig samples per leg aggregated as the `median_ops_per_sec` of the 2 samples per run, then median-of-10 across rounds.

Median of 10 = mean of the 5th and 6th sorted-ascending entries.

Zig-only binaries built fresh per leg from isolated git worktrees:

- A (baseline): `.cache/worktrees/baseline-a666ec3` → SHA256 `31f56e3d1ab00ee15e11ac1dfc53b44b39894b6dc89e098f33d43e9aca86ec67`
- B (phase2): `.cache/worktrees/phase2-HEAD` → SHA256 `04907722033566dd690b7db8c5d27cce1670d6f16557d7de8e71fbef0b4291df`

Host state: 56-core, 2-socket / 1-NUMA-node. Load avg start → end: `2.05/2.64/1.72` → `5.01/5.14/3.25` (1/5/15m). No co-tenant > 10% CPU during runs.

All 20 runs completed without error or timeout.

## Results

Median-of-10 per leg; kill gate = weighted-avg Δ across the three target scenarios ≥ +5% AND no non-target < −3%.

| Scenario             | A median (Phase-0) | B median (Phase-2) |     Δ%    | Gate            | Pass |
|----------------------|-------------------:|-------------------:|----------:|:---------------:|:----:|
| **contended_spawn_8x**   |      **1,206,550** |      **1,189,721** |  **−1.39%** | **weighted ≥ +5%** | **❌** |
| **contended_cpu_10us**   |      **1,197,748** |      **1,190,498** |  **−0.61%** | **weighted ≥ +5%** | **❌** |
| **nested_fanout_4x**     |      **1,093,998** |        **878,673** | **−19.68%** | **weighted ≥ +5%** | **❌** |
| mixed_fast_slow      |            247,627 |            259,277 |   +4.70%  | ≥ −3%          | ✅   |
| flood_1m             |            951,668 |            949,633 |   −0.21%  | ≥ −3%          | ✅   |
| cpu_work_10us        |          1,059,753 |          1,041,915 |   −1.68%  | ≥ −3%          | ✅   |
| cpu_work_100us       |            459,913 |            453,711 |   −1.35%  | ≥ −3%          | ✅   |
| burst_drain_burst    |            163,061 |            162,553 |   −0.31%  | ≥ −3%          | ✅   |

**Weighted-avg Δ over targets: −7.23%.**
**Kill gate verdict: FAIL — all three targets regressed, primary target `nested_fanout_4x` by −19.68%.**

- Non-target regressions: all within the −3% gate. Worst is `cpu_work_10us` at −1.68%; none exceed the non-target gate.

## Interpretation

Phase 2 decisively failed. All three targeted contended / nested scenarios regressed, and the *primary* target `nested_fanout_4x` — the scenario the attack was designed to help — dropped 19.68%.

The B-leg `nested_fanout_4x` distribution is bimodal with a pronounced low tail:

```text
B: 469483 647083 692499 808326 876777 | 880569 944158 996681 1116161 1145340
```

vs the A-leg's tight band:

```text
A: 969613 1030791 1032213 1040345 1077821 | 1110174 1111827 1194794 1207101 1214772
```

B-leg minimum (469K) is less than half the A-leg minimum (969K). This is not a steady-state slowdown — it is intermittent catastrophic contention. Plausible mechanisms:

1. **Rotate-in-`submitBatchWorkerFast`**: when a worker thread calls `submitBatch(N)` from inside a running task, the fast path swaps the NEWEST descriptor into `lifo_slot` (matching Phase-1 rotate semantics) and pushes prev + the remaining N−1 via `tryPushBottomN`. Under `nested_fanout_4x`'s tight child-spawn waves, every parent task does this simultaneously across 56 workers, displacing prev entries that other workers are also attempting to consume. Combined with `WorkDeque`'s concurrent-steal semantics, this concentrates coherence traffic on `bottom` and the buffer tail in a way the per-task loop did not (the slow path rotates once per task, not once per batch, and serializes over `bottom` advance).

2. **Partial-rollback thrash**: when `tryPushBottomN(N)` returns < N (local_queue full), the fast path releases unused descriptors and falls through to the slow per-task loop for the tail. Under `nested_fanout_4x` worker-context submits, local_queues fill quickly; partial rollback does ~2× work (N descriptor acquires + body writes + partial commit + rollback + re-acquire via slow path). The B-leg's low-tail 469K/647K samples are consistent with a run where rollback fires on most batches.

3. **DescCache bulk-take contention**: Phase-2 changed `DescCache` acquisition from single-entry to up to N per call. Under contended worker-context submits the underlying `task_desc_live` fetchAdd and freelist-CAS concentrate more coherence traffic per call. Unlike (1) and (2) this should be amortized by the batch, but if the DescCache frequently short-takes (< N available) the bulk call converts to a per-entry loop internally.

Neither the plan nor the evidence calls for distinguishing between these — the change is a clean FAIL on the kill gate. Further root-causing would be cheaper on a follow-up attack than here.

## Decision

Per plan Task 2.5 Step 6: FAIL path is to revert all Phase-2 commits and proceed to Phase 3 artifacts (FINAL.md summarising both Phase-1 and Phase-2 attacks).

The queue primitives themselves (`tryPushBottomN` / `tryPushN`) are defensible plumbing — they are correct, boundary-tested, and match producer-push semantics in Go `runqput` and Tokio's local queue. A user operating outside this plan's gate framework could reasonably keep them as building blocks for future experiments. But this plan's gate is the authority, and it says revert.

**Decision: REVERT all six Phase-2 commits (`dfdf9f9`, `d4025f1`, `71e9b9b`, `37c7c00`, `4b16750`, `3b9fa1b`) as a single squashed revert. Proceed to Phase 3 artifacts.**

## Raw samples (sorted ascending, n=10 per leg)

```text
contended_spawn_8x
  A: 1092707 1107838 1119215 1180498 1201687 1211413 1215388 1231740 1239784 1301404
  B: 1059633 1066273 1123700 1181490 1186436 1193005 1203785 1254706 1266016 1278362

contended_cpu_10us
  A: 1071969 1097827 1103350 1166356 1180728 1214766 1229829 1229859 1247632 1268736
  B: 1106539 1119727 1156187 1173506 1190082 1190913 1205421 1211637 1250181 1269566

nested_fanout_4x
  A: 969613 1030791 1032213 1040345 1077821 1110174 1111827 1194794 1207101 1214772
  B: 469483 647083 692499 808326 876777 880569 944158 996681 1116161 1145340

mixed_fast_slow
  A: 215717 235860 243694 246345 246696 248557 258785 259586 261150 261295
  B: 216262 242193 245267 246593 259060 259492 259633 261013 261125 272773

flood_1m
  A: 873097 893818 921021 943800 948270 955066 955330 1035145 1043824 1086160
  B: 902731 917743 931067 935463 945733 953533 958987 998325 1023589 1175041

cpu_work_10us
  A: 960900 972846 1046748 1047070 1052980 1066526 1071942 1106058 1139439 1140289
  B: 1005074 1014572 1018863 1034995 1036812 1047017 1048714 1091970 1118328 1256778

cpu_work_100us
  A: 402521 402841 433859 453210 455090 464736 482026 485767 508842 515837
  B: 383050 406218 417259 442050 453440 453982 490183 491595 507401 514087

burst_drain_burst
  A: 159110 159987 160325 160579 163057 163063 163339 163715 163873 164279
  B: 157760 159968 161095 161429 162413 162691 162949 163809 163865 164447
```

## Methodology notes

- Zig-only binaries built with `zig build -Doptimize=ReleaseFast -p zig-out` from isolated git worktrees (baseline from pre-existing `.cache/worktrees/baseline-a666ec3`, Phase-2 from fresh `.cache/worktrees/phase2-HEAD` at `3b9fa1b`). Binary SHA256 hashes are distinct (confirmed above).
- Full `scripts/run-runtime-comparison.sh --zig-bin <path>` used per run; Tokio/Go runtimes ran from pre-cached `.cache/cargo-target` and `.cache/go-build`, not rebuilt per round.
- Raw JSON artefacts: `phase2-A-{1..10}.json` and `phase2-B-{1..10}.json` in this directory. Host-state log: `phase2-host-state.log`.
- `source_commit` field in the JSON files reflects main-checkout HEAD (`3b9fa1b`) for all runs; the actual binary identity is captured by the SHA256 hashes and worktree paths.
- Orchestrator: `.cache/phase2-ab-loop.sh`. Aggregator: `.cache/phase2-aggregate.py`.
- 20x ReleaseFast stress gate re-run on the revert HEAD after the FAIL decision: 20/20 pass.
