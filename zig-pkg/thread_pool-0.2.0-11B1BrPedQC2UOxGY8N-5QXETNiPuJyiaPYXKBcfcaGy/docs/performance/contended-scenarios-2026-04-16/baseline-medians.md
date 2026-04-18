# Baseline medians (HEAD 56c109a355eb4316450a216a74cc619b7809183b)

Captured: 2026-04-16T00:00:00Z

| Scenario | Zig median ops/sec | Go median ops/sec | Gap |
|----------|-------------------:|------------------:|----:|
| contended_spawn_8x   | 916,337   | 3,832,459 | 4.18x behind |
| contended_cpu_10us   | 918,624   | 1,807,198 | 1.97x behind |
| nested_fanout_4x     | 525,906   | 3,175,814 | 6.04x behind |
| mixed_fast_slow      | 223,581   | 249,514   | 1.12x behind |

Source: `baseline.json` (this directory).

## Post-Phase-1 medians (HEAD 1dde02e2657ede6d6f6d24eaf7c5ecde4b89cf6d)

Captured: 2026-04-16T22:01:52Z

| Scenario | Zig baseline | Zig post-Phase-1 | Delta | Go median | New gap |
|----------|-------------:|-----------------:|------:|----------:|--------:|
| contended_spawn_8x | 916,337 | 987,837 | +7.8% | 3,125,095 | 3.16x behind |
| contended_cpu_10us | 918,624 | 961,203 | +4.6% | 1,724,954 | 1.79x behind |
| nested_fanout_4x   | 525,906 | 645,206 | +22.7% | 2,812,471 | 4.36x behind |
| mixed_fast_slow    | 223,581 | 247,877 | +10.9% | 242,723 | 1.02x ahead |

Source: `phase1-after.json` (this directory).
