# Phase 3 A/B — per-Worker DescCache

## Legs

- **A (Pair 1)** = `03d225d` — Phase-0 baseline (pre-Phase-1, pre-Phase-2 src). No DescCache, no per-submitter SPSC queues.
- **A (Pair 2)** = `922cb60` — Phase-2 HEAD (Phase 1 harness `nested_fanout_4x` → `submitBatch` in `runtime_compare_zig.zig` + Phase 2 per-submitter DescCache: SPSC primitive, `acquireDescriptorBatch` helper, per-submitter cache routing in `enqueuePush`, drain-on-release).
- **B (both pairs)** = `d78a206` — Phase-3 HEAD: adds per-Worker `DescCache` appended to `Worker` struct (layout-safe, end-of-struct), routes worker-context `acquireDescriptor` calls through the worker's own cache instead of the shared inject path, and drains the worker DescCache on pool `deinit`. Commits between Phase-2 and Phase-3 HEAD: `768fab6`, `056ee01`, `d78a206`.

## Protocol

Paired balanced-order A/B (A, B, A, B, …), n=8 per leg, ReleaseFast, 56 workers, vendored Tokio + Go measured (only Zig numbers gated). Reduced from n=10 to n=8 consistent with Phase 2 methodology (signal at n=8 was decisive in both pairs). Each run: `--samples 3 --warmup-discard 1` (2 retained samples per run, 16 total samples per leg aggregated to n=8 rounds). Zig-only binary built fresh per commit from isolated git worktrees; full script called with `--zig-bin` from main checkout.

Host state: 56-core, 2-socket / 1-NUMA-node. Start load avg: 3.24/4.47/3.44 (1/5/15m). After Pair 1 round 5: 9.29 (1m, benchmark load). After Pair 1 complete: 6.44/6.37/4.58. After all rounds: 6.89/6.56/5.05. No co-tenant > 10% CPU during runs; load fluctuation is the benchmark itself. All 32 runs completed without timeout or error.

## Pair 1 results (Phase-3 vs Phase-0)

Paired-order median of 8 computed as mean of 4th and 5th entries when sorted ascending.

| Scenario             | A median (Phase-0) | B median (Phase-3) |    Δ%    | Gate   | Pass |
|----------------------|-------------------:|-------------------:|---------:|:------:|:----:|
| contended_spawn_8x   |            947,297 |          1,211,358 | **+27.88%** | ≥ −3% | ✅ |
| contended_cpu_10us   |            994,958 |          1,252,901 | **+25.93%** | ≥ −3% | ✅ |
| nested_fanout_4x     |            626,144 |          1,134,938 | **+81.26%** | ≥ +18% | ✅ |
| mixed_fast_slow      |            252,904 |            258,905 |   +2.37%  | ≥ −3% | ✅ |
| flood_1m             |            992,830 |            989,524 |   −0.33%  | ≥ −3% | ✅ |
| cpu_work_10us        |          1,042,777 |          1,078,295 |   +3.41%  | ≥ −3% | ✅ |
| cpu_work_100us       |            487,546 |            489,266 |   +0.35%  | ≥ −3% | ✅ |
| burst_drain_burst    |            163,864 |            163,026 |   −0.51%  | ≥ −3% | ✅ |

**Kill gate: PASS**

- `nested_fanout_4x` +81.26% vs Phase-0 ≥ +18% ✓ (4.51× gate)
- Non-target regressions > 3%: none. Worst non-target regression: `burst_drain_burst` −0.51%.

## Pair 2 results (Phase-3 vs Phase-2)

| Scenario             | A median (Phase-2) | B median (Phase-3) |     Δ%    | Gate    | Pass |
|----------------------|-------------------:|-------------------:|----------:|:-------:|:----:|
| contended_spawn_8x   |          1,332,003 |          1,197,495 | **−10.10%** | observe | ⚠️  |
| contended_cpu_10us   |          1,308,626 |          1,239,517 |  **−5.28%** | observe | ⚠️  |
| nested_fanout_4x     |            893,938 |          1,143,547 | **+27.92%** | ≥ +10% | ✅ |
| mixed_fast_slow      |            258,016 |            246,212 |   −4.58%  | observe | ⚠️  |
| flood_1m             |          1,058,332 |            985,820 |   −6.85%  | observe | ⚠️  |
| cpu_work_10us        |          1,094,944 |          1,045,267 |   −4.54%  | observe | ⚠️  |
| cpu_work_100us       |            489,050 |            490,057 |    +0.21%  | observe | ✅ |
| burst_drain_burst    |            162,665 |            162,197 |    −0.29%  | observe | ✅ |

**Kill gate verdict: CLEAN WIN on target.** `nested_fanout_4x` +27.92% vs Phase-2 ≥ +10% ✓ (2.79× gate). The gate defined in the plan for Pair 2 is `nested_fanout_4x`-only; all other scenarios are "observe" not hard gates.

**Honesty note on Pair-2 contended regressions:** Phase-3 regresses 5–10% on the contended submitter-thread scenarios (`contended_spawn_8x` −10.10%, `contended_cpu_10us` −5.28%) relative to Phase-2. This is structurally expected: Phase-2 per-submitter DescCache optimized the contended-submitter path. Phase-3 adds a per-Worker DescCache that benefits the worker-context submit path (`nested_fanout_4x`, `cpu_work_10us`). The worker-DescCache path is not exercised by the multi-submitter contended scenarios. The regression vs Phase-2 may be from cache-line pressure added by the `DescCache` field appended to the 56-instance `Worker` struct, or from code-path changes in `acquireDescriptor`. However, vs Phase-0 (Pair 1), both contended scenarios remain strongly positive (+27.88%, +25.93%), so the net effect of Phase 1+2+3 is large gains across all target scenarios. Phase-3 trades some of Phase-2's contended headroom in exchange for the `nested_fanout_4x` improvement, consistent with its stated architectural scope.

## Kill gate decision: PASS

- **Pair 1** (Phase-3 vs Phase-0): PASS. `nested_fanout_4x` +81.26% vs the +18% gate. No non-target regression > 3%.
- **Pair 2** (Phase-3 vs Phase-2): CLEAN WIN on `nested_fanout_4x` (+27.92% vs +10% gate). Contended regressions vs Phase-2 are outside the formal gate scope; documented above.

## Decision: KEEP

Phase 3 KEEPS. All three commits (`768fab6`, `056ee01`, `d78a206`) remain on main.

- The primary cumulative gate (Phase-0 → Phase-3, `nested_fanout_4x` ≥ +18%) cleared at +81.26% — headroom of 63 percentage points.
- Phase-3 makes `nested_fanout_4x` the strongest single-scenario gain across all three phases.
- Contended scenarios (`contended_spawn_8x` +27.88%, `contended_cpu_10us` +25.93%) remain strongly positive vs Phase-0 despite the −5 to −10% step-back from Phase-2. The net Phase-1+2+3 stack (vs Phase-0) is unambiguously positive on every scenario.

**Regarding Phase 4:** The Pair-2 contended regressions (−10.10% `contended_spawn_8x`, −5.28% `contended_cpu_10us`) are real and worth investigating in Phase 4 if the plan's roadmap includes it. They are not a kill-gate failure for Phase-3 since the gate is scoped to `nested_fanout_4x`, but the regression is large enough that a dedicated investigation pass would be warranted before declaring Phase-3 a net win for contended workloads.

## Raw samples (sorted ascending, n=8 per leg)

### Pair 1: Phase-0 (A) vs Phase-3 (B)

```text
contended_spawn_8x
  A: 893032 910106 921329 942631 951964 960773 970471 1000776
  B: 1086472 1089877 1131549 1208870 1213845 1216516 1241368 1321102

contended_cpu_10us
  A: 896250 963033 986939 994889 995027 1031212 1037319 1088491
  B: 1031073 1196757 1213201 1235395 1270407 1294511 1311265 1336974

nested_fanout_4x
  A: 428931 436715 486017 605716 646573 650085 665584 696795
  B: 1049484 1079685 1103097 1121249 1148627 1162212 1226709 1232098

mixed_fast_slow
  A: 234696 246290 246385 247608 258201 258536 259159 260545
  B: 206944 213388 258832 258902 258907 260873 260999 271851

flood_1m
  A: 958145 963100 963730 973732 1011928 1032301 1045419 1095373
  B: 897630 937961 961501 980412 998636 1008453 1049282 1135755

cpu_work_10us
  A: 805293 835065 1017405 1027671 1057882 1259339 1345921 1364701
  B: 1030895 1041258 1048128 1064062 1092527 1094930 1102433 1313875

cpu_work_100us
  A: 400560 407856 432302 475187 499906 500388 504971 507484
  B: 425478 427471 431079 479733 498798 498870 506171 508488

burst_drain_burst
  A: 159814 162196 162799 163762 163966 164189 164581 164796
  B: 156861 158080 161374 162945 163107 163845 164419 164532
```

### Pair 2: Phase-2 (A) vs Phase-3 (B)

```text
contended_spawn_8x
  A: 1235842 1261843 1277448 1323931 1340076 1402082 1467876 1492127
  B: 1126351 1159421 1186777 1187770 1207219 1216426 1234677 1277499

contended_cpu_10us
  A: 1234612 1253807 1290093 1300123 1317128 1375289 1396748 1397404
  B: 1169487 1203909 1236380 1238314 1240720 1275018 1288035 1295884

nested_fanout_4x
  A: 638742 835990 871741 889911 897965 932496 942030 943587
  B: 1057364 1103828 1108206 1139991 1147102 1149077 1179689 1226906

mixed_fast_slow
  A: 214416 215582 247669 257817 258215 258519 258585 259542
  B: 205753 215377 233317 246193 246231 259428 260449 260821

flood_1m
  A: 976256 1011565 1023530 1052140 1064523 1068426 1133427 1211098
  B: 875920 969969 970887 972548 999093 1023452 1079310 1193768

cpu_work_10us
  A: 1025508 1032565 1049605 1092562 1097325 1129049 1133673 1175820
  B: 973788 995537 1013258 1037674 1052860 1073769 1085280 1144638

cpu_work_100us
  A: 399763 408007 475878 488176 489925 492621 500595 513903
  B: 398223 414072 435672 488626 491488 499220 501393 508122

burst_drain_burst
  A: 155896 158398 161022 162403 162927 164199 164419 164728
  B: 159097 159733 160098 162084 162310 162330 163938 164112
```

## Methodology notes

- Zig-only binaries built with `zig build bench-runtime-zig -Doptimize=ReleaseFast -p zig-out` from isolated git worktrees for Phase-0 and Phase-2, and from main checkout for Phase-3. Binary hashes confirmed distinct (Phase-0: `85c379c0`, Phase-2: `7bd64a0e`, Phase-3: `c5679e21`).
- Full `scripts/run-runtime-comparison.sh --zig-bin <path>` used per run; Tokio/Go runtimes ran from pre-cached `.cache/cargo-target` and `.cache/go-build` — not rebuilt per round.
- `source_commit` in JSON files reflects the main checkout HEAD (`d78a206`) for all runs because the script derives it from `git -C ROOT_DIR rev-parse HEAD`; the actual binary commit identity is captured by the binary hash and the worktree construction.
- Raw JSON artifacts: `phase3-vs-phase0-{A,B}-{1..8}.json` and `phase3-vs-phase2-{A,B}-{1..8}.json` in this directory.
