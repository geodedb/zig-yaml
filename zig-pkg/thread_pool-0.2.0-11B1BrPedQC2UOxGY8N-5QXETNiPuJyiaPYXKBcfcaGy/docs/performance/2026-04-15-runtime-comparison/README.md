# 2026-04-15 Direct Runtime Comparison

This archive records the first in-repo direct comparison run against vendored
Tokio and Go source trees.

## Command

```bash
zig build bench-runtime-compare -Doptimize=ReleaseFast -- --output benchmarks/results/runtime-comparison-latest.json
```

## Environment

- host OS: Linux
- host arch: x86_64
- worker count: 56
- warmup discard: 1
- retained samples: 6

## Median Throughput

| Scenario | Zig thread-pool | Tokio | Go |
|---|---:|---:|---:|
| `flood_1m` | 535,989 ops/s | 603,864 ops/s | 1,058,859 ops/s |
| `contended_spawn_8x` | 858,960 ops/s | 656,727 ops/s | 3,313,113 ops/s |

## Notes

- This snapshot replaces assumption-based comparisons with direct local data.
- Tokio is only modestly ahead on `flood_1m` on this host.
- Go remains materially ahead on both workloads.
- The canonical machine-readable artifact is
  `benchmarks/results/runtime-comparison-latest.json`.
