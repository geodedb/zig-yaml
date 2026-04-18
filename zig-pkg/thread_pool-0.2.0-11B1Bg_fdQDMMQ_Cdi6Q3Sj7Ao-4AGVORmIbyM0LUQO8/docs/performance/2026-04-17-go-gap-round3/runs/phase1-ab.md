# Go-gap round 3 — Phase 1 runsheet

**Date:** 2026-04-17
**Protocol:** same-session paired A/B, interleaved, n = 10 sample pairs.
**Binary:** `bench-runtime-zig -Doptimize=ReleaseFast`, `--samples 7
--warmup-discard 1`.

## Binaries

| Leg | Commit   | Tree state                         | SHA-256 |
|-----|----------|------------------------------------|---------|
| A   | `018fb10`| pre-refactor (plan-doc commit only)| `d9a7b52383f1829463b56138b720d6e71f61998bcc3162f70da7d5c764b40a65` |
| B   | `58eb37d`| DescCache externalised to Core slice | `cb4b1c5edf0fad9338dc99d5bdbf4bb4e5e2593fd69025439fc35483a683d040` |

Distinct hashes confirm each leg ran its own binary (the initial
`.zig-cache` first run produced identical hashes and was discarded;
binaries recovered from `.zig-cache/o/<hash>/thread-pool-runtime-compare-zig`).

## Results (median of n = 10 ops/sec)

| Scenario              | A median   | B median   |    Δ%    | Gate     | Pass |
|-----------------------|-----------:|-----------:|---------:|:--------:|:----:|
| `contended_spawn_8x`  |  1,039,027 |    855,701 |  -17.64% | ≥ +5 %   | ❌   |
| `contended_cpu_10us`  |  1,152,276 |    904,796 |  -21.48% | ≥ +3 %   | ❌   |
| `nested_fanout_4x`    |  1,099,808 |    865,374 |  -21.32% | ≥ -3 %   | ❌   |
| `flood_1m`            |    910,801 |    873,634 |   -4.08% | ≥ -3 %   | ❌   |
| `cpu_work_10us`       |    907,009 |    941,301 |   +3.78% | ≥ -3 %   | ✅   |
| `cpu_work_100us`      |    450,516 |    421,812 |   -6.37% | ≥ -3 %   | ❌   |
| `burst_drain_burst`   |    162,281 |    161,845 |   -0.27% | ≥ -3 %   | ✅   |
| `mixed_fast_slow`     |    240,500 |    242,089 |   +0.66% | ≥ -3 %   | ✅   |

**primary targets:** FAIL
**do-no-harm:** FAIL
**overall gate:** FAIL

## Raw samples (ops/sec)

- `contended_spawn_8x`:
  - A: [974200, 1044645, 1127391, 1002652, 1058631, 1095656, 1218934, 1022160, 915952, 1033408]
  - B: [859547, 828865, 808175, 827822, 756266, 885448, 860713, 851854, 899352, 877347]
- `contended_cpu_10us`:
  - A: [1264927, 1195740, 1109506, 1203575, 1104566, 1195045, 1059631, 1224180, 1042336, 1075749]
  - B: [931075, 875832, 940448, 959903, 867165, 949927, 883766, 916310, 625286, 893280]
- `nested_fanout_4x`:
  - A: [1095202, 1178970, 1143421, 1066171, 1051983, 1156460, 1104414, 801448, 743601, 1177176]
  - B: [875687, 872223, 887136, 858523, 803057, 853783, 854593, 873690, 888500, 829495]
- `flood_1m`:
  - A: [957135, 934142, 947095, 901127, 865701, 920474, 862258, 871992, 846551, 936326]
  - B: [898739, 948951, 818725, 767468, 863717, 762893, 1016982, 867765, 879502, 932255]
- `cpu_work_10us`:
  - A: [584333, 1200474, 933853, 851687, 1112434, 1116111, 880165, 709556, 1079710, 620970]
  - B: [948506, 540791, 934094, 791623, 962909, 1008226, 976528, 669569, 963028, 625161]
- `cpu_work_100us`:
  - A: [498383, 507085, 374732, 445009, 487125, 372251, 456023, 431486, 409018, 505080]
  - B: [428843, 373432, 465267, 383074, 389265, 414780, 481190, 466708, 488466, 382570]
- `burst_drain_burst`:
  - A: [157246, 163897, 164231, 160489, 163081, 159460, 162127, 162435, 154251, 163637]
  - B: [162174, 156474, 163597, 161941, 159873, 161748, 159292, 162429, 156910, 164645]
- `mixed_fast_slow`:
  - A: [233643, 225839, 257754, 255547, 247355, 191022, 259563, 224265, 189301, 258263]
  - B: [223992, 224072, 248843, 235334, 259073, 259387, 259969, 205441, 202269, 259527]

## Verdict

Kill gate FAIL on 5 of 8 scenarios, including both primary targets by wide
margins (-17.64% and -21.48%). REVERT path executed: see
[`../FINAL.md`](../FINAL.md).
