# Phase 2 A/B — per-submitter descriptor cache

## Legs

- **A** = `03d225d` — Phase-0 baseline (pre-Phase-1, pre-Phase-2 src).
- **B** = `922cb60` — post Phase 1 (harness `nested_fanout_4x` → `submitBatch` in `runtime_compare_zig.zig`) + Phase 2 (DescCache SPSC primitive, `acquireDescriptorBatch` helper, per-submitter cache routing in `enqueuePush`, drain-on-release).

Phase 2 src commits between A and B: `1d544a7`, `9ef82af`, `3ce882f`, `0f25a28`, `25724d0`, `ab5bedb`, `922cb60`.

## Protocol

Paired balanced-order A/B, ReleaseFast, 56 workers, vendored Tokio + Go (measured but only Zig numbers gated). Intended n=10 per leg; first dispatch stalled after round 8, second dispatch inherited the rounds-1–8 artifacts and the strength of signal (targets at 3.6× and 3.96× gate) made continuing to round 10 unnecessary. **Retained n=8 paired.**

Host state: 56-core, 2-socket / 1-NUMA-node. Start load ~1.04, end load 0.41 (1m) / 1.25 (5m) / 2.82 (15m). No co-tenant > 10% CPU.

## Results (Zig runtime only)

Samples are `median_ops_per_sec` per bench run, sorted ascending; paired-order median of 8 computed as mean of 4th and 5th entries.

| Scenario             | A median     | B median     | Δ%       | Gate      | Pass |
|----------------------|-------------:|-------------:|---------:|:---------:|:----:|
| contended_spawn_8x   |      951,370 |    1,293,669 | **+35.98%** | ≥ +10% | ✅ |
| contended_cpu_10us   |    1,008,486 |    1,328,299 | **+31.71%** | ≥ +8%  | ✅ |
| nested_fanout_4x     |      544,323 |      902,715 | +65.84%  | ≥ −3%     | ✅ |
| mixed_fast_slow      |      240,622 |      257,342 |  +6.95%  | ≥ −3%     | ✅ |
| flood_1m             |      961,547 |    1,007,230 |  +4.75%  | ≥ −3%     | ✅ |
| cpu_work_10us        |      985,677 |    1,064,090 |  +7.96%  | ≥ −3%     | ✅ |
| cpu_work_100us       |      439,625 |      461,889 |  +5.06%  | ≥ −3%     | ✅ |
| burst_drain_burst    |      161,804 |      162,012 |  +0.13%  | ≥ −3%     | ✅ |

## Kill gate: PASS

- Target A: `contended_spawn_8x` +35.98% ≥ +10% ✓ (3.6× gate)
- Target B: `contended_cpu_10us` +31.71% ≥ +8%  ✓ (3.96× gate)
- Non-target regressions (Δ < −3%): none

Both Phase 2 targets hit with massive headroom, no non-target regression, every single scenario directionally positive.

## Raw samples (sorted, n=8 per leg)

```text
contended_spawn_8x
  A: 860702 865002 923394 949847 952892 954441 985231 999150
  B: 1232476 1235796 1270862 1289407 1297931 1310826 1312256 1318000
contended_cpu_10us
  A: 947586 958156 995510 997751 1019221 1040478 1052151 1078680
  B: 1263208 1266687 1291808 1308312 1348286 1364612 1378471 1384187
nested_fanout_4x
  A: 518237 519832 523734 524706 563939 567534 576413 593599
  B: 736006 843928 882765 902337 903092 903997 930745 933023
mixed_fast_slow
  A: 231077 234337 234848 235846 245398 246478 256170 258384
  B: 223482 246394 248062 257305 257378 258423 258964 259538
flood_1m
  A: 937104 941949 959692 960962 962131 981844 1049463 1050901
  B: 927640 965406 976349 999287 1015173 1054366 1057563 1123298
cpu_work_10us
  A: 809068 946496 964893 982055 989298 1051237 1096100 1131965
  B: 725221 841878 1012345 1051984 1076195 1078116 1115944 1116857
cpu_work_100us
  A: 385924 416818 425040 428784 450465 473947 483317 498544
  B: 406881 450797 451429 453088 470690 483415 487450 488930
burst_drain_burst
  A: 159657 160641 161265 161751 161857 162100 162633 162929
  B: 158358 161115 161856 161877 162146 162970 163023 163068
```

## Notes on nested_fanout_4x +65.84%

The nested_fanout_4x delta combines Phase 1's +44.8% runtime-compare `submitBatch` gain (which was the headline Phase 1 deliverable) with Phase 2's per-submitter DescCache effect on the main-thread submitter path. The Phase-2-only contribution is not cleanly isolatable from this A/B (A is pre-Phase-1 baseline); the plan's non-target regression gate here is ≥ −3%, which it clears by >68 percentage points.

## Decision

Phase 2 **KEEPS**. All commits remain on main. Proceed to Phase 3 (per-worker DescCache for the worker-context submit path; targets `nested_fanout_4x` on top of current Phase-2 gain, kill gate `nested_fanout_4x` Phase-1+Phase-3 cumulative ≥ +18% vs Phase-0 baseline).

Raw JSON artifacts archived as `phase2-A-{1..8}.json` and `phase2-B-{1..8}.json` in this directory.
