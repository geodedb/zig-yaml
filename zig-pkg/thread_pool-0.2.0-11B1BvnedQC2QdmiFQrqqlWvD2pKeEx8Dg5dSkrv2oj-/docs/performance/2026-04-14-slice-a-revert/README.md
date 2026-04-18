# 2026-04-14 — Slice A Revert (idle-queue infrastructure)

## Summary

Partial revert of `c3c7066` (`feat(pool): add scratch fast path and idle wake
queue`). Kept the scratch fast-path and purge-predicate strengthening (slices
B+C); removed the idle-queue wake strategy plumbing (slice A) from `main`.

## Motivation

Fresh-host n=10 paired A/B on 2026-04-14 (clean host: uptime ~20 min, load
avg 0.54, no co-tenants) reproduced the prior-session regression of `c3c7066`
vs its parent, ruling out host-load as the cause. Slicing the commit
identified idle-queue infrastructure (slice A) as the sole regression source:
even though the default `wake_strategy = .scan_parked_workers` never runs the
new code paths, slice A still pays ambient cost via Core struct growth,
per-submit `self.config.wake_strategy` branch, and new `idle()` call sites
that guard-and-return.

## Evidence

### Initial regression confirmation (HEAD vs parent)

Balanced-order n=10, ReleaseFast, default Config (`scan_parked_workers`):

| Scenario | BASE (670047a) | HEAD (c3c7066) | Δ median |
|----------|---------------:|---------------:|---------:|
| flood_1m | 371,092 | 354,150 | **−4.6%** |
| contended_spawn_8x | 581,738 | 520,622 | **−10.5%** |

`contended_spawn_8x` had **no distribution overlap** (HEAD max 535,129 <
BASE min 547,525).

### Slice isolation (3-way)

Rotating-order n=10; BC = baseline + B (purge predicate) + C (scratch
fast-path), no A:

| Scenario | BASE | BC only | HEAD (c3c7066) |
|----------|-----:|--------:|---------------:|
| flood_1m | 363,384 | 367,166 (+1.0%) | 346,141 (−4.7%) |
| contended_spawn_8x | 568,818 | 583,144 (+2.5%) | 512,188 (−10.0%) |

BC alone is neutral-to-slightly-positive — the regression is 100% slice A.

### Post-revert verification (this commit vs pre-revert vs baseline)

Rotating-order n=10, same host session:

| Scenario | BASE | POST (this commit) | PRE (c3c7066) |
|----------|-----:|-------------------:|--------------:|
| flood_1m | 366,155 | 379,448 (+3.6% vs BASE, +12.9% vs PRE) | 336,196 |
| contended_spawn_8x | 582,227 | 586,196 (+0.7% vs BASE, +15.7% vs PRE) | 506,802 |

`contended_spawn_8x` POST vs PRE: POST min 561,844 > PRE max 522,725 — **no
overlap**, decisive win.

## Regression mechanism (why slice A cost perf even in the dead path)

1. **Core struct layout shift.** Added three fields
   (`idle_queues: ?[]BoundedRing(u32)`, `idle_queue_shard_mask: usize`,
   `idle_ticket_states: ?[]std.atomic.Value(u8)`) between `inject_queue` and
   `sync`/`counters`. `counters` has `align(std.atomic.cache_line)`, so
   that one stays deterministic, but `sync` and every following non-aligned
   field shift, changing their cacheline residency.
2. **Per-submit branch.** `submitInternal` gained a
   `if (self.config.wake_strategy == .scan_parked_workers)` check around the
   wake path, adding a Config load per submit.
3. **Per-idle call overhead.** `idle()` calls both
   `self.clearConsumedIdleTicket(worker_index)` and
   `self.publishIdleWorker(worker_index)`. Both guard with
   `self.config.wake_strategy != .idle_queue` and early-return, but if the
   compiler doesn't fully inline them, the call + config load is per-park.

## What the revert kept

- **Slice B — purge predicate.** `purgeWorkerCaches` now rejects with
  `error.PoolBusy` unless `active_tasks == 0 && queued_tasks == 0`, not just
  `active_tasks == 0`. Closes a correctness gap where purge could race with
  in-flight queued work.
- **Slice C — scratch fast-path.** `WorkerScratch.beginTask` and
  `WorkerScratch.alloc` no longer take the mutex. Purge keeps a dedicated
  `purge_mutex` (renamed from `mutex`) that serializes only overlapping
  purge callers, so the owning-worker task path is lock-free. Buffer
  allocation is deferred from `beginTask` until first `alloc`.

## What the revert removed

- `WakeStrategy` / `RuntimePreset` enums and the associated `Config` fields
  plus `normalized()` preset logic.
- `Core.idle_queues`, `Core.idle_queue_shard_mask`, `Core.idle_ticket_states`
  fields and their init/deinit.
- `wakeOneIdleWorkerFromQueue`, `publishIdleWorker`,
  `clearConsumedIdleTicket`, `idleQueueCapacity`, `idleQueueShardCount`,
  `idleQueueShardSlots` functions.
- Submit-path `wake_strategy` branch; `idle()` ticket-management calls.
- `src/root.zig` re-exports of `WakeStrategy` and `RuntimePreset`.
- Two test changes that opted into `.wake_strategy = .idle_queue` in
  `tests/stress.zig` (reverted to defaults).
- Unit test "idle queue wake strategy: submit wakes a parked worker"
  (removed).

The unit test "worker cache purge rejects queued work even when no task is
active" (slice B's test) was **kept**.

## If idle-queue wake strategy is re-pursued

Any re-land must:

1. Avoid the Core struct layout shift (e.g., place the new fields after
   `counters` so cacheline residency of `sync` / hot fields is preserved, or
   move them to a separately-allocated side struct).
2. Eliminate the per-submit `self.config.wake_strategy` branch (e.g.,
   comptime-specialize by selecting a submit function at init, or dispatch
   via a function pointer set once).
3. Ensure `clearConsumedIdleTicket` / `publishIdleWorker` are fully inlined
   and produce zero ambient cost in the default-strategy case.
4. Demonstrate same-session n=10 A/B vs baseline at **default Config** (not
   just under the opt-in preset) showing no regression.

Until those criteria are met, the idle-queue design stays off `main`.

## Correctness validation

- `zig build test --summary all` — 41/41 pass
- `zig build test-integration --summary all` — 3/3 pass
- `zig build test-stress --summary all` — 14/14 pass
- 20× ReleaseFast stress gate — 0/20 failures (sentinel
  `claim_sentinel_enabled = true` active throughout)

## Host conditions

- Uptime ~20 min (fresh boot) at session start; ~1h by revert verification
- Load average: 0.54 (session start) → 1-2 range during measurement
- Governor: `schedutil`
- CPU count: 56
- No co-tenants (geode stopped; no long-lived claude/node processes from
  prior session — fresh server)
