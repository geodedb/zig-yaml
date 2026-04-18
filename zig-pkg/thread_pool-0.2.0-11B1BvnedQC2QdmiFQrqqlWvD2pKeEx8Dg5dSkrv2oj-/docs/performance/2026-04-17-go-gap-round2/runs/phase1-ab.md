# Phase 1 A/B — lifo_slot rotate on worker-context submit

## Legs

- **A** = `a666ec3` — Phase-0 baseline (Go-gap round 1 FINAL HEAD). Worker-context default-lane branch of `enqueuePush` uses "only-when-empty" semantics: `load(.monotonic)` on `lifo_slot`; if empty, `store(entry, .release)`; else fall through to `tryPushBottom` on `local_queue`.
- **B** = `d69af65` — Phase-1 HEAD. Same branch now does `swap(entry, .acq_rel)` unconditionally. On non-empty `prev`, push `prev` to `local_queue`; on `tryPushBottom(prev)` failure, `store(prev, .release)` back to `lifo_slot` and fall through to submitter/inject paths with `entry`. Matches Go `runqput` / Tokio `LifoSlot` next-g semantics.
  Commits between legs: `e9f2d8e` (rotate impl + 5 public test helpers + 2 private Core helpers + rotate unit test), `d69af65` (pure comment clarification — teardown ordering safety note).

## Protocol

Paired balanced-order A/B (A, B, A, B, …), n=10 rounds, ReleaseFast, 56 workers. `./scripts/run-runtime-comparison.sh --samples 3 --warmup-discard 1` per invocation → 2 retained samples per run → 20 raw Zig samples per leg aggregated as the `median_ops_per_sec` of the 2 samples per run, then median-of-10 across rounds.

Median of 10 = mean of the 5th and 6th sorted-ascending entries.

Zig-only binaries built fresh per leg from isolated git worktrees:

- A (baseline): `.cache/worktrees/baseline-a666ec3` → SHA256 `31f56e3d1ab00ee15e11ac1dfc53b44b39894b6dc89e098f33d43e9aca86ec67`
- B (phase1): `.cache/worktrees/phase1-HEAD` → SHA256 `c03cf0b38ea6f54b4ea87ad6429ac2cf7e4db32f6422ad5f0d249264ae505299`

Host state: 56-core, 2-socket / 1-NUMA-node. End-of-run load avg: `11.32/7.76/4.33` (1/5/15m). No co-tenant > 10% CPU during runs.

All 20 runs completed without error or timeout.

## Results

Median-of-10 per leg; kill gate scoped to `nested_fanout_4x` (+5%), non-target gate -3%.

| Scenario             | A median (Phase-0) | B median (Phase-1) |     Δ%    | Gate    | Pass |
|----------------------|-------------------:|-------------------:|----------:|:-------:|:----:|
| contended_spawn_8x   |          1,201,175 |          1,216,882 |   +1.31%  | ≥ −3%  | ✅   |
| contended_cpu_10us   |          1,217,134 |          1,182,965 |   −2.81%  | ≥ −3%  | ✅   |
| **nested_fanout_4x** |      **1,121,818** |      **1,131,088** | **+0.83%**| **≥ +5%** | **❌** |
| mixed_fast_slow      |            239,392 |            240,289 |   +0.37%  | ≥ −3%  | ✅   |
| flood_1m             |            962,011 |            960,220 |   −0.19%  | ≥ −3%  | ✅   |
| cpu_work_10us        |          1,034,439 |          1,055,214 |   +2.01%  | ≥ −3%  | ✅   |
| cpu_work_100us       |            418,814 |            431,306 |   +2.98%  | ≥ −3%  | ✅   |
| burst_drain_burst    |            162,745 |            162,960 |   +0.13%  | ≥ −3%  | ✅   |

**Kill gate verdict: FAIL on target.**

- `nested_fanout_4x` +0.83% vs the +5% target gate. Signal is within noise (~6× below the gate) and well inside the A-leg spread — the A-leg range is 1,036K–1,243K, a ±10% band around the median.
- Non-target regressions: worst is `contended_cpu_10us` at −2.81%, just inside the −3% gate. No regression exceeded the non-target gate.

## Interpretation

The rotate hypothesis — that every worker-context submit gaining the single-atomic-store hot path, plus the next-pop returning the freshest entry, would materially accelerate `nested_fanout_4x` — did not bear out at the throughput level. The +0.83% delta is noise-dominated. Plausible explanations:

1. The pre-rotate "only-when-empty" path was already hot enough on the first submit; the additional cost of the `tryPushBottom`-into-`local_queue` path for children 2..N on `submitBatch` was not a bottleneck for `nested_fanout_4x` throughput.
2. `nextTask`'s existing `swap(LIFO_SLOT_EMPTY, .acquire)` pop-first-from-slot semantics already bias workers to the freshest owned entry in both variants; rotate just changes *which* submits get to use the slot. When the local_queue is small and drained rapidly, both paths produce the same steady-state behaviour.
3. The per-submit cost difference (1 atomic swap vs 1 atomic load + 1 atomic store) is on the order of a single CPU cycle under cache-hot conditions; invisible against the scheduler-wake + `notifySubmits` path that dominates `nested_fanout_4x` (already documented as structural in the iter-9 closed-plane memory).

The change is *behaviourally* equivalent to Go `runqput` semantics and does not regress any non-target scenario beyond noise. However, the plan's kill gate is strict and scoped explicitly to `nested_fanout_4x ≥ +5%`, so this is a FAIL.

## Decision

Per plan Task 1.3 Step 5: FAIL path is to revert the Phase 1 implementation commit and jump to Phase 3 artifacts, keeping this runsheet as evidence of the attempted attack.

The rotate semantics themselves are defensible (they match Go + Tokio) and do not introduce a functional regression. A user operating outside this plan's gate framework could reasonably keep the rotate as a behavioural alignment with reference runtimes — but this plan's gate is the authority, and it says revert.

**Decision: REVERT `e9f2d8e` (rotate impl) and `d69af65` (doc-only follow-up). Proceed to Phase 3.**

## Raw samples (sorted ascending, n=10 per leg)

```text
contended_spawn_8x
  A: 1075706 1080678 1081804 1128234 1195412 1206937 1221134 1225635 1225681 1253701
  B: 1097341 1138425 1197256 1214440 1216594 1217168 1219514 1230040 1233280 1240988

contended_cpu_10us
  A: 1078276 1110991 1178540 1202701 1216173 1218095 1230228 1261154 1268203 1381743
  B: 938430 1069758 1113385 1174470 1175169 1190759 1209190 1242030 1286409 1301852

nested_fanout_4x
  A: 1036117 1073341 1085624 1096833 1101995 1141640 1166648 1168396 1178793 1243198
  B: 1052736 1065411 1095847 1105404 1112568 1149608 1168657 1172214 1189279 1217621

mixed_fast_slow
  A: 216072 223235 225345 228744 233848 244936 246651 247838 259705 260709
  B: 207088 216099 217536 234189 234998 245579 246547 247470 258726 271612

flood_1m
  A: 796691 843845 923339 925193 946035 977987 978907 1011042 1015235 1042960
  B: 874633 879830 883137 886904 950823 969615 981675 1007003 1020577 1092852

cpu_work_10us
  A: 879660 933163 938299 1022188 1023714 1045164 1050450 1075481 1147147 1276362
  B: 891417 1021852 1039351 1040677 1051041 1059387 1066979 1069636 1076751 1084561

cpu_work_100us
  A: 363603 399323 405476 416202 416485 421143 434933 507895 508566 519733
  B: 383956 397846 403497 407482 425753 436857 482127 486059 489969 507747

burst_drain_burst
  A: 156119 159855 160716 161167 162510 162979 163303 163930 164050 164367
  B: 156275 161229 161624 161972 162358 163562 163623 163660 163722 163866
```

## Methodology notes

- Zig-only binaries built with `zig build -Doptimize=ReleaseFast -p zig-out` from isolated git worktrees (baseline from pre-existing `.cache/worktrees/baseline-a666ec3`, Phase-1 from fresh `.cache/worktrees/phase1-HEAD` at `d69af65`). Binary SHA256 hashes are distinct (confirmed above).
- Full `scripts/run-runtime-comparison.sh --zig-bin <path>` used per run; Tokio/Go runtimes ran from pre-cached `.cache/cargo-target` and `.cache/go-build`, not rebuilt per round.
- Raw JSON artefacts: `phase1-A-{1..10}.json` and `phase1-B-{1..10}.json` in this directory. Host-state log: `phase1-host-state.log`.
- `source_commit` field in the JSON files reflects main-checkout HEAD (`d69af65`) for all runs; the actual binary identity is captured by the SHA256 hashes and worktree paths.
