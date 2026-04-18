# Harness submitter-registration audit

Captured: 2026-04-16T20:15:00Z

## Summary

Only `runContendedSample` in `benchmarks/runtime_compare_zig.zig` registers
submitter threads today. Every other multi-submitter scenario (and every
main-thread-only scenario) hits the inject-queue head directly via
`pool.submit()`, which is serialised through a single MPMC tail CAS.

## Scenarios that do NOT register submitters (and should)

| Scenario | File | Lines | Submitter threads | Current config |
|----------|------|-------|-------------------:|----------------|
| `contended_cpu_10us`   | `runtime_compare_zig.zig` | 423-506 | 4 | `max_submitter_queues=0` |
| `nested_fanout_4x`     | `runtime_compare_zig.zig` | 508-580 | 1 (main) | `max_submitter_queues=0` |
| `mixed_fast_slow`      | `runtime_compare_zig.zig` | 650-699 | 1 (main) | `max_submitter_queues=0` |
| `cpu_work_10us`        | `runtime_compare_zig.zig` | 415-417  | 1 (main) | `max_submitter_queues=0` |
| `cpu_work_100us`       | `runtime_compare_zig.zig` | 419-421  | 1 (main) | `max_submitter_queues=0` |
| `burst_drain_burst`    | `runtime_compare_zig.zig` | 582-648 | 1 (main) | `max_submitter_queues=0` |
| `flood_1m`             | `runtime_compare_zig.zig` | 305-326 | 1 (main) | `max_submitter_queues=0` |
| `bench-realistic` all  | `common.zig`              | 351-374 | 1..N | `max_submitter_queues=0` |

## Priority

Phase 1 fixes the three in-scope scenarios only:

- `contended_cpu_10us` (multi-submitter; largest expected delta).
- `nested_fanout_4x` (single main submitter; smaller delta but still a gap).
- `mixed_fast_slow` (single main submitter; smallest expected delta).

The other five are left alone in Phase 1 to preserve apples-to-apples vs
baseline for the non-target scenarios. If Phase 1 + Phase 3 close the gap
meaningfully, a follow-up plan can audit the remaining five.

## Expected gain

Based on the 2026-04-15 `contended_spawn_8x` result when `registerSubmitter()`
was first added (+17.2%, 837K→981K ops/sec), we expect:

- `contended_cpu_10us`: 8–20% gain (similar pattern, 4 submitters).
- `nested_fanout_4x`: 0–5% gain (main thread submits 2k parents once; child
  submission already routes through worker LIFO slot, so the registered
  submitter only matters for the parent-push phase).
- `mixed_fast_slow`: 0–3% gain (1 submitter; submitter queue just deflects
  the slow-path fall-through to inject_queue).

Absolute gain is conservative; the scenarios with nested/child submissions
from worker context are already on the fast path.
