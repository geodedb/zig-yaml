# Performance Targets

## Baseline Policy

This repository does not hardcode arbitrary throughput numbers up front. The first measured baseline is stored in `benchmarks/results/baseline.json`, and CI compares new results against that file.

## Workload Profiles

### CI-safe suite

- `conn_churn_seq`
- `producer_contention`

Command:

```bash
zig build bench -- --output benchmarks/results/latest.json
```

### Scheduled or manual suite

- `conn_churn_parallel`
- `short_long_mix`
- `idle_burst_idle`
- `nested_submit`
- `blocking_lane_sim`
- `oversubscription`

Command:

```bash
zig build scale-bench -- --output benchmarks/results/scale-current.json
```

## Regression Gates

### CPU gate

- `compare-bench` fails if throughput regresses by more than `15%` against the stored baseline for a matched row.

### Memory gate

- `compare-bench` fails if `rss_current_bytes` grows by more than `15%` against the stored baseline for a matched row.

### Manual review expectations

- Any sustained RSS increase under `conn_churn_seq` or `conn_churn_parallel` requires documenting the reason in `docs/GAP_ANALYSIS.md`.
- Any scheduler-default change requires refreshing `docs/SCHEDULER_DECISION.md`.

## Reproduction Commands

```bash
make bench-save
make bench-compare
make scale-bench
```

## Threshold Updates

Update thresholds only after:

1. capturing new baseline JSON,
2. recording the reason in a merge request,
3. updating `docs/SCHEDULER_DECISION.md` if scheduler-sensitive metrics changed materially,
4. updating `docs/GAP_ANALYSIS.md` evidence links.

## Open Gaps

- `alloc_count` is currently emitted as `0`; byte accounting is implemented, event-count accounting is not yet separate.
- CPU time falls back to wall time when the OS sample returns zero or is unavailable.
