# API Reference

This page summarizes the public surface exported from
[src/root.zig](../src/root.zig).

## Primary Types

- `thread_pool.ThreadPool`: owned pool handle with submission, waiting,
  shutdown, and stats methods
- `thread_pool.Config`: pool configuration
- `thread_pool.SubmitOptions`: per-submit behavior such as backpressure, lane,
  waitability, and timeout
- `thread_pool.TaskHandle`: opaque handle returned by waitable submissions
- `thread_pool.WaitGroup`: task-group completion primitive
- `thread_pool.CancellationToken`: cooperative cancellation flag
- `thread_pool.Stats`: snapshot of task counts, latencies, queue depths, memory,
  and worker-local stats

## ThreadPool Methods

- `ThreadPool.init(allocator, config)`: create a pool
- `ThreadPool.deinit()`: shut down and release all owned resources
- `ThreadPool.submit(task_fn, ctx, options)`: enqueue a single task, optionally
  blocking on backpressure
- `ThreadPool.trySubmit(task_fn, ctx, options)`: never blocks; returns
  `error.QueueFull` or `error.TaskPoolExhausted` instead
- `ThreadPool.submitBatch(tasks, options)`: enqueue a slice of
  `thread_pool.BatchTask`
- `ThreadPool.wait(handle)`: wait for a handle created with
  `SubmitOptions.waitable = true`
- `ThreadPool.waitGroup()`: create a fresh wait group for grouping submissions
- `ThreadPool.shutdown(mode, timeout_ns)`: stop the pool with either drain or
  cancel semantics
- `ThreadPool.statsSnapshot()`: read a consistent stats view
- `ThreadPool.purgeWorkerCaches()`: purge per-worker scratch buffers when the
  pool is quiescent
- `ThreadPool.registerSubmitter()`: claim a per-submitter queue slot for this
  thread to enable the per-submitter fast path on dedicated submitter
  threads. Returns `!usize` (the slot index) or `error.NoSubmitterSlots`
  when the 64-slot bitmap is full. Idempotent per-thread — callers should
  pair each `registerSubmitter()` with exactly one `releaseSubmitter()`
  per registration. TLS state is pool-scoped (F-001) so the same thread
  can safely register on multiple pools.
- `ThreadPool.releaseSubmitter(idx)`: release a previously-registered
  submitter slot. Idempotent (F-005) — a double-release on the same
  `idx` bails via an atomic CAS on the free-mask rather than racing the
  drain. Out-of-range `idx` is silently ignored. Only clears the caller
  thread's TLS slot if this thread was the original owner.

## Config Highlights

Common fields:

- `min_threads`, `max_threads`
- `queue_capacity`, `local_queue_capacity`
- `inject_batch_size`
- `scheduler_variant`
- `allow_blocking_lane`, `blocking_workers`
- `worker_scratch_cap_bytes`
- `idle_park_after_ns`, `idle_purge_after_ns`
- `timestamp_mode`
- `steal_batch_size`

Important constraint: `Config.validate()` is intended for normalized configs.
If you are validating a hand-built config outside `ThreadPool.init()`, call
`config.normalized().validate()` rather than validating the raw struct.

## Scheduler Variants

- `global_queue`
- `work_stealing`
- `lane_extension`

## Submit Options

`SubmitOptions` supports:

- `waitable`
- `wait_group`
- `cancellation_token`
- `backpressure`
- `timeout_ns`
- `lane`

Backpressure policies:

- `return_error`
- `block`
- `block_with_timeout`

Task lanes:

- `default`
- `blocking`

## Queue Implementations

Public queue types are exported for low-level testing and experimentation:

- `thread_pool.BoundedRing`
- `thread_pool.WorkDeque`
- `thread_pool.RingQueue`

## Stats Snapshot

`Stats` includes:

- lifecycle counts: `submitted`, `started`, `completed`, `cancelled`
- queue state: `queue_depth_current`, `queue_depth_peak`
- worker activity: `steals`, `steal_failures`, `wakeups`, `parks`
- memory: process RSS plus pool allocation counters
- latencies: task wait and execution summaries
- per-worker scratch and queue stats

See [DESIGN.md](DESIGN.md) for the implementation-level meaning of each field.

## Build Options

Passed as `-D<name>[=<value>]` to `zig build`. All are optional; defaults
are the safe production settings.

| Option | Default | Purpose |
|---|---|---|
| `-Dtsan` | `false` | Enable ThreadSanitizer on unit, integration, stress, and fuzz artifacts. Forces the stress suite from ReleaseFast to Debug so races are not optimised away before TSan observes them. |
| `-Dsingle-pool` | `false` | Elide the F-001 per-pool TLS identity check on the hot submit path at compile time. **UNSAFE** when a process hosts more than one `ThreadPool` — restores the pre-F-001 cross-pool OOB hazard. Reclaims 6–17% throughput on `contended_spawn_8x` / `cpu_work_100us` / `mixed_fast_slow` for genuinely single-pool workloads. See [AppSec FINAL.md § Optimisation pass](performance/appsec-fixes-2026-04-15/FINAL.md#optimisation-pass----dsingle-pool-comptime-elision). |
| `-Doptimize={Debug,ReleaseSafe,ReleaseFast,ReleaseSmall}` | `Debug` | Standard Zig optimisation mode. Benchmarks are configured to always build under `ReleaseFast` regardless of this flag. |

Two build steps surface TSan directly:

- `zig build test-all -Dtsan` — all test suites under TSan (Debug only).
- `zig build fuzz -Dtsan [-Dsingle-pool=true]` — fuzz harness under TSan;
  drive iteration count with `FUZZ_SEED` / `FUZZ_ITERATIONS` env vars.
