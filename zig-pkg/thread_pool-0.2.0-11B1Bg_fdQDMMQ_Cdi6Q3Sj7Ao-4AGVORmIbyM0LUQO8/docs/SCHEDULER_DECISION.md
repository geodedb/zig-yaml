# Scheduler Decision

## Current Default

`global_queue` is the current default scheduler.

## Evidence

Baseline file: [benchmarks/results/baseline.json](../benchmarks/results/baseline.json)

Current measured highlights from the initial CI-safe benchmark run:

- `conn_churn_seq`
  - `global_queue`: ~1.50M ops/s, `p95` completion latency ~44.6 µs, RSS ~260 KiB
  - `work_stealing`: ~478k ops/s, `p95` completion latency ~201.6 µs, RSS ~288 KiB
- `producer_contention`
  - `global_queue`: ~502k ops/s, `p95` completion latency ~68.4 µs, RSS ~340 KiB
  - `work_stealing`: ~397k ops/s, `p95` completion latency ~121.3 µs, RSS ~392 KiB

## Rationale

- The measured CI-safe baseline currently favors the simpler scheduler on throughput, tail latency, and RSS.
- The work-stealing scheduler remains in-tree specifically because larger or more affinity-sensitive scenarios may still reverse that result.
- The default should change only if future benchmark evidence clearly favors the candidate scheduler across the guarded scenario set.

## Fallback Conditions

Prefer `work_stealing` when:

- a consumer has evidence that worker-local routing improves locality,
- producer contention dominates and the benchmark suite is expanded to match that shape,
- keyed or affinity-like follow-on work needs local ownership semantics.

## Follow-on Work

- Expand the scale benchmark coverage before making any stronger claims about oversubscription and blocking-lane behavior.
- Revisit the default if future memory-focused runs show a sustained RSS advantage for the baseline scheduler.
