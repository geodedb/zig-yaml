# Scratch Fast Path + Idle Queue Attempt — 2026-04-14

## Status

Implemented in the current working tree only. Not merged to `main`.

This archive covers the late 2026-04-14 attempt driven by
`docs/codex-review-2026-04-14.md`:

- remove per-task scratch locking from the worker hot path
- replace submit-path O(N) parked-worker scanning with an idle-worker queue
- add a first-class parity-mode preset
- preserve the existing `queued_tasks` / `is_parked` lost-wakeup model

## Code changes in the workspace

- `src/memory/scratch.zig`
  - `beginTask()`, `alloc()`, and `finishTask()` are lock-free on the normal
    owning-worker path
  - backing buffer allocation stays lazy
  - code comments now document the quiescent-purge invariant
- `src/pool.zig`
  - `purgeWorkerCaches()` now returns `error.PoolBusy` unless
    `active_tasks == 0 && queued_tasks == 0`
  - added idle-worker ticket queues and the `idle_queue` wake strategy
  - kept the existing SC `queued_tasks` / `is_parked` handshake intact
- `src/types.zig` / `src/root.zig`
  - exported `WakeStrategy` and `RuntimePreset`
  - `RuntimePreset.tokio_parity` currently enables
    `timestamp_mode = .disabled` and `wake_strategy = .idle_queue`
- `tests/unit.zig` / `tests/stress.zig`
  - added regression coverage for quiescent purge, idle-queue wake behavior,
    and lost-wakeup stress under `wake_strategy = .idle_queue`

## Correctness finding from the attempt

The first cut of the scratch fast-path refactor introduced a real race:
idle-time purge and external quiescent purge could overlap and double-free a
scratch buffer. The symptom was an intermittent `SIGSEGV` in
`stress.test.repeated churn returns to a bounded steady state after purge`.

Final fix:

- keep the task fast path lock-free
- add a slow-path-only purge mutex so overlapping purge callers serialize

That preserves the hot-path goal while closing the double-free.

## Validation on the final workspace

- `zig build test --summary all` PASS
- `zig build test-integration --summary all` PASS
- `zig build test-stress --summary all` PASS
- focused purge/churn regression loop:
  `zig build test-stress -- --test-filter "repeated churn returns to a bounded steady state after purge"`
  30/30 PASS
- required `ReleaseFast` stress gate:
  `zig build test-stress --summary all`
  20/20 PASS

## Benchmark method

Same-session A/B versus a clean baseline worktree at `HEAD`:

- baseline worktree: `/tmp/thread-pool-baseline`
- candidate: current dirty workspace
- build mode: `ReleaseFast`
- run count: n=10 baseline, n=10 candidate
- ordering: balanced order, alternating which binary runs first per pair

Raw outputs:

- `baseline-balanced-n10.txt`
- `after-balanced-n10.txt`

## Host state during measurement

The host was under substantial unrelated load during the benchmark run:

- `uptime`: `load average: 12.89, 13.63, 11.13`
- `ps -eo pid,comm,%cpu,%mem --sort=-%cpu | head -n 12` showed several
  unrelated `geode` processes consuming significant CPU

This must be acknowledged for benchmark variance and absolute numbers. It does
**not** invalidate the correctness regression that was fixed, and it does not
justify claiming a perf win that the same-session A/B does not show.

## Results

| Scenario | Baseline median ops/s | Baseline p95 | Candidate median ops/s | Candidate p95 | Delta |
|---|---:|---:|---:|---:|---:|
| `tokio_parity/flood_1m` | 487,840.5 | 537,976 | 465,650.0 | 541,624 | -4.5% median |
| `tokio_parity/contended_spawn_8x` | 469,570.0 | 510,690 | 411,959.0 | 453,933 | -12.3% median |

## Additional note on parity preset

During the session, the benchmark harness was briefly changed to force
`runtime_preset = .tokio_parity`. On this host that made the measured parity
benchmarks worse, so the harness was restored to its stable config. The preset
remains available as an explicit runtime option; it is not forced by the
benchmark binary.

## Verdict

This attempt improved the implementation shape and closed a real purge race,
but it did **not** meet the performance success criteria:

- `flood_1m` did not show a same-session improvement
- `contended_spawn_8x` regressed materially on the measured host
- the idle-queue wake path is therefore not ready to become the default

The next session should treat this as:

- a correctness-clean, tested workspace
- useful infrastructure for further wake-path investigation
- not yet a benchmark-positive patch to ship as-is
