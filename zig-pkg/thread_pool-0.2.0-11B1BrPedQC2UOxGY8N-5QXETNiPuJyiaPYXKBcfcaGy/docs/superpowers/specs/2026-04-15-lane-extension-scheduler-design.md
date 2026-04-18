# Lane Extension Scheduler Design Spec

**Date:** 2026-04-15
**Status:** Design proposal, pending approval before implementation
**Successor to:** Throughput plateau pivot — see `memory/project_throughput_plateau_pivot.md`

## Problem

The public API already exposes a lane concept:

- `TaskLane = enum { default, blocking }` (types.zig:9)
- `SubmitOptions.lane: TaskLane = .default` (types.zig:193)
- `Config.allow_blocking_lane: bool = false` (types.zig:121)
- `SchedulerVariant.lane_extension` (types.zig:6, rejected by `validate()` at types.zig:180)

But the lane tag has no runtime effect. All tasks share one worker pool, one inject queue, one backpressure policy. A user calling a syscall-heavy task with `.lane = .blocking` gets identical behavior to `.lane = .default` — the blocking task contends with CPU-bound tasks for the same worker set and can starve the pool.

Five consecutive iteration failures (iters 7-11) plus Slice 3 kill confirm the `flood_1m_batched` throughput plateau is architectural (see `project_throughput_plateau_pivot.md`). Time to close the lane-support feature gap instead.

## Goal

Make the lane tag load-bearing by:

1. Reserving a subset of workers that serve the blocking lane.
2. Routing tasks to the correct lane at submit time.
3. Keeping CPU-bound tasks isolated from blocking tasks so a misbehaving syscall cannot starve the CPU pool.
4. Handling three realistic failure modes:
   - **Blocking backlog while CPU pool idle** — dynamic rebalancing.
   - **Default-lane task that turns out to be blocking** — watchdog-driven promotion.
   - **One lane saturates and its backpressure policy differs** — per-lane backpressure.

## Non-Goals

- Stackful task migration. Zig has no coroutines; a task mid-execution cannot be moved. "Promotion" means reclassifying accounting and spawning overflow capacity, not moving the running task.
- Syscall-entry hooks (Go's P/M split). Requires wrapping every syscall; out of scope.
- More than two lanes. `TaskLane` is deliberately binary; a future generalization could use a `u8` lane id but is not warranted today.
- Affinity between lanes and sockets. Slice 3a killed socket-pinning; blocking workers inherit CFS placement.
- Lane-aware work stealing across lane boundaries by default. Cross-lane steal is only a fallback under explicit rebalancing conditions.

## Design

### Component: `Config.blocking_workers: u32 = 0`

Number of workers reserved to serve the blocking lane. Carved out of `max_threads` (not additive): if `max_threads = 8` and `blocking_workers = 2`, the pool spawns 8 threads, 2 of which serve blocking and 6 of which serve default.

Validation:

- `blocking_workers < max_threads` (must leave at least one CPU worker).
- `blocking_workers > 0 and allow_blocking_lane == false` → `error.BlockingLaneWithoutFlag` (catches misconfig where the user reserved blocking workers but forgot to enable the lane).
- `scheduler_variant == .lane_extension and blocking_workers == 0` → `error.LaneExtensionRequiresBlockingWorkers`.

Default 0 preserves current behavior (opt-in).

### Component: `Config.blocking_queue_capacity: usize = 0`

Capacity of the blocking-lane inject queue. 0 means "use `queue_capacity`" (the existing single-queue config). When `blocking_workers == 0`, ignored.

Validation: rounded to power-of-two in `normalized()`, same as `queue_capacity`.

### Component: `Config.blocking_backpressure: ?BackpressurePolicy = null`

Per-lane override of `SubmitOptions.backpressure`. `null` means "inherit the caller's `SubmitOptions.backpressure`" (no change from today). Non-null forces blocking-lane submissions to use this policy regardless of the caller's option — lets operators enforce "blocking tasks always return error on full; never block the submitter" as a pool-wide invariant.

Same pattern for `Config.default_backpressure: ?BackpressurePolicy = null`.

### Component: `Core.blocking_inject: ?BoundedRing`

A second inject ring, allocated only when `blocking_workers > 0`. Protocol and layout identical to the existing `inject_queue`; no structural sharing, no tagging inside the ring. This isolates cacheline traffic between lanes.

Blocking-lane submit path:

1. Check `allow_blocking_lane`; if false, return `error.BlockingLaneDisabled`.
2. Apply `Config.blocking_backpressure` override if set.
3. Push to `blocking_inject` under the configured policy.
4. Wake one blocking-capable worker via lane-scoped `notifySubmits`.

### Component: `Worker.serves_lane: TaskLane`

A new field on `Worker`. Workers with `worker_index < Config.blocking_workers` are assigned `serves_lane = .blocking`; the rest are `.default`. Set once at spawn; never mutated.

Steal/drain policy:

- **Default workers**: drain `inject_queue` (default lane); steal from other `.default` workers' local queues. Never touch `blocking_inject` or blocking workers' local queues.
- **Blocking workers**: drain `blocking_inject` first, then `inject_queue` as a fallback (this is the "rebalancing" path — see below). Steal from other `.blocking` workers' local queues first, then `.default` workers' local queues (only under rebalancing conditions).

This asymmetry is intentional: a blocking task landing in a CPU-worker's local queue would violate isolation. A CPU task landing in a blocking-worker's local queue under rebalancing is fine — the user already opted into blocking workers, so the loss is capacity, not correctness.

### Component: lane-scoped `notifySubmits`

Today's `notifySubmits` scans all 56 `is_parked` flags. Under lane extension it must scan only workers that serve the submitted task's lane. Two sub-scans:

- `notifyDefaultSubmits`: scan workers `[blocking_workers .. total)`.
- `notifyBlockingSubmits`: scan workers `[0 .. blocking_workers)`.

Because `notifySubmits` is documented as a structural ceiling (`project_iter9_closed_and_notify_ceiling.md`), this split **must not make the default-lane scan longer** than today's unified scan. When `blocking_workers = 0` (default config), the code path is identical to today's — validated by A/B against current main on `flood_1m_batched`.

### Component: dynamic lane rebalancing

Problem: operator reserves 2 blocking workers; all blocking submissions have completed; CPU lane now has backlog. The 2 blocking workers sit parked while CPU workers saturate.

Mechanism: when a blocking worker finds `blocking_inject` empty and no blocking-lane steal victims, it falls back to:

1. Poll `inject_queue` once (bounded: single `popMany` of up to `steal_batch_size`).
2. If empty, attempt to steal from one `.default` worker (picked via existing bitmap scan restricted to `.default` workers).
3. If still empty, park on the blocking-lane futex word (not the default-lane one), so the next `.blocking` submit wakes it directly.

Converse (CPU worker helping blocking lane) is **disabled by default** — it violates the "CPU workers never touch blocking lane" invariant, and a blocking task arriving at a CPU worker's local queue makes subsequent CPU-lane steals see blocking-tagged work they shouldn't execute. Opt-in via `Config.cpu_helps_blocking: bool = false` for users who accept the leak for capacity.

Rebalancing rate-limiting: a blocking worker that drained from `inject_queue` checks its own lane first before each subsequent task, so it returns to blocking duty as soon as new blocking work arrives. No sticky cross-lane affinity.

### Component: blocking-timeout promotion (watchdog)

Problem: user submits `.lane = .default` assuming a CPU-bound task, but the task stalls on a lock for 500ms. One CPU worker is stuck; the rest keep up; eventually CPU pool is short one worker for the stall's duration.

Mechanism: an optional watchdog thread (spawned when `Config.watchdog_interval_ns > 0`).

- Every `watchdog_interval_ns`, walk each `.default` worker.
- For each, read `worker.current_task_started_ns` (new field, set in `workerMain` at task-dispatch time).
- If `(now - started) > Config.blocking_promotion_timeout_ns` AND `inject_queue` is non-empty AND no other `.default` worker is parked AND `overflow_workers_active < Config.max_overflow_workers` → spawn an overflow worker.

Overflow worker: serves `.default` lane, exits when:

- Its local queue drains, AND
- `inject_queue` is empty, AND
- No `.default` worker is currently stalled.

This gives Go-runtime-style elasticity without syscall hooks. The stalled worker is unaffected — when its task eventually finishes, it re-enters the normal pool; the overflow worker self-retires shortly after.

Config knobs:

- `watchdog_interval_ns: u64 = 0` (0 disables)
- `blocking_promotion_timeout_ns: u64 = 10_000_000` (10ms default, ignored if watchdog disabled)
- `max_overflow_workers: u32 = 0` (hard cap; 0 disables even with watchdog on)

Default: all three zero → zero overhead, zero behavior change.

### Component: lane-specific backpressure

Already covered by `blocking_queue_capacity` and `blocking_backpressure` above. The key invariant: **the blocking lane's full queue never blocks default-lane submitters**. Because the queues are physically separate and backpressure signaling per-queue, this falls out of the design — no extra code needed beyond the two condition variables.

Tests must verify:

- Fill blocking queue with `.blocking` backpressure-block policy; default-lane submitter returns immediately.
- Fill default queue with `.default` backpressure-block policy; blocking-lane submitter returns immediately.

## Validation

Extension to `Config.validate()`:

```zig
if (blocking_workers >= max_threads) return error.InvalidBlockingWorkers;
if (blocking_workers > 0 and !allow_blocking_lane) return error.BlockingLaneWithoutFlag;
if (scheduler_variant == .lane_extension and blocking_workers == 0)
    return error.LaneExtensionRequiresBlockingWorkers;
if (watchdog_interval_ns > 0 and max_overflow_workers == 0)
    return error.WatchdogWithoutOverflowCap;
if (max_overflow_workers > max_threads)
    return error.OverflowCapExceedsPool;
```

`scheduler_variant == .lane_extension` becomes accepted when paired with `blocking_workers > 0`. `global_queue` and `work_stealing` variants continue to work when `blocking_workers == 0`; they reject `.blocking` submissions with `error.BlockingLaneDisabled` when `allow_blocking_lane = false`, or fall back to the default lane when `true` (a user said yes to blocking but didn't reserve workers — log and route to default rather than error).

## Tests

### Unit

- `Config.validate` rejects each invalid combination above.
- `submit` with `.lane = .blocking` and `allow_blocking_lane = false` → `error.BlockingLaneDisabled`.
- `submit` with `.lane = .blocking` routes to `blocking_inject`, not `inject_queue`.
- Default worker never dequeues from `blocking_inject`.

### Stress

- **Isolation:** 8 blocking tasks that each `sleep(1s)` submitted concurrently with 1M CPU tasks; CPU throughput must match no-blocking baseline within 10%.
- **Rebalancing:** blocking queue idle + CPU backlog → blocking workers assist. Assert blocking-worker steal count > 0 via stats.
- **Watchdog:** single default task calling `sleep(50ms)` with `blocking_promotion_timeout_ns = 10ms` → exactly one overflow worker spawned; overflow worker retired within `watchdog_interval_ns * 2` of stall end.
- **Per-lane backpressure:** fill blocking queue with block-policy submits from one thread; default-lane submits from another thread continue without blocking.

### Bench (regression gates)

- `flood_1m_batched` with `blocking_workers = 0`: match current main within ±2% (no-effect invariant).
- `flood_1m_batched` with `blocking_workers = 8, allow_blocking_lane = true, no .blocking submissions`: match default within ±3% (empty-blocking-queue overhead budget).

## Implementation phasing

Recommended slice order (each slice is independently landable and measurable):

1. **Slice L1: static lane routing.** Config fields, second inject queue, `serves_lane` field, routing at submit, lane-scoped `notifySubmits`. Validation. No rebalancing, no watchdog, no per-lane backpressure.
2. **Slice L2: per-lane backpressure.** `blocking_queue_capacity`, `blocking_backpressure`, separate condition variables.
3. **Slice L3: dynamic lane rebalancing.** Blocking-worker fallback to default queue; `cpu_helps_blocking` opt-in.
4. **Slice L4: watchdog-driven overflow workers.** Watchdog thread, `current_task_started_ns` field, overflow-worker spawn/retire, all associated config.

Each slice lands with its own stress test and `flood_1m_batched` regression gate (must be within ±2% of prior slice's committed baseline).

## Open questions

- **Do we need a third lane** for "latency-sensitive small tasks" distinct from default? Not today — bench evidence that `default` alone has slack is absent. Revisit only if a user asks.
- **Should overflow workers auto-tune their count** based on historical stall rate? Not in v1 — a hard cap is predictable; auto-tuning deferred.
- **Should watchdog run on a dedicated thread or piggyback on an existing worker's idle loop?** Dedicated for simplicity in v1; revisit if its ~1% idle CPU shows up in profiles.
- **Does `ShutdownMode.drain` drain both lanes?** Yes — cancel semantics apply symmetrically. Stress test must cover blocking-lane shutdown.

## Risks

- **notifySubmits regression when `blocking_workers == 0`.** Mitigated by keeping the unified scan as a compile-time branch (`if (config.blocking_workers == 0) unified_scan() else split_scan()`) and A/B-gating against current main.
- **Watchdog thread false positives** (e.g., GC pause, thread preempted at task-start). Mitigated by requiring ALL of: stall timeout exceeded, inject backlog present, no parked workers. A lone stalled task with an idle pool doesn't trigger spawn.
- **Overflow worker thrash** under oscillating load. Mitigated by `max_overflow_workers` cap and retire hysteresis (overflow worker waits one watchdog interval of empty queue before exiting).
- **Scope creep.** Four slices is ~1-2 weeks of work. Each slice is independently useful; land one at a time, A/B-gate each, stop if evidence says the ROI isn't there.
