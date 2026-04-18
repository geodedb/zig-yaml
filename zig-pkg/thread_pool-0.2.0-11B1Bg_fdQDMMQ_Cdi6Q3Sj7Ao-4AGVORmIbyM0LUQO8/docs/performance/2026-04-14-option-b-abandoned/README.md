# Option B (Sharded Inject) — Ceiling Negative, Abandoned

**Date:** 2026-04-14
**Brainstorm:** `docs/superpowers/brainstorms/2026-04-14-inject-head-contention.md`
**Baseline commit:** `cd15524` (Option A `popMany` landed)

## TL;DR

Sharded inject-queue (Option B in the brainstorm) was measured at
N=4 and N=2. Both FAIL the `≥ +15% flood_1m_batched CLEAN` gate.
N=4 actively regresses the primary target by -7.6% with clean
IQR separation. N=2 is neutral (-1.0% overlap) on the target but
gives no lift. Direction closed.

The +8% CLEAN uplift on `contended_spawn_8x` (8 submitters) that
sharding produces at both N=2 and N=4 confirms the brainstorm's
consumer-side intuition — but for flood_1m_batched (single
submitter), the submitter-side cost of rotating across N
cachelines outweighs the consumer-side win.

## Measurements

n=10 round paired A/B BSSB (20 samples per arm), same-session,
baseline is `cd15524` (Option A landed). Raw data:
`ceilB_n4_raw.txt` (N=4) and `ceilB_n2_raw.txt` (N=2) in
`docs/performance/2026-04-14-inject-head-contention/`.

### N=4 sharded inject

| Scenario | Option A base | N=4 stub | Δ | IQR separation |
|---|---:|---:|---:|:---|
| flood_1m | 407,527 | 401,594 | -1.5% | overlap |
| flood_1m_batched | 990,396 | 914,922 | **-7.6%** | **CLEAN (negative)** |
| contended_spawn_8x | 653,294 | 707,488 | **+8.3%** | **CLEAN** |
| contended_spawn_8x_batched | 683,348 | 664,026 | -2.8% | overlap |

### N=2 sharded inject

| Scenario | Option A base | N=2 stub | Δ | IQR separation |
|---|---:|---:|---:|:---|
| flood_1m | 410,884 | 396,836 | -3.4% | overlap |
| flood_1m_batched | 936,110 | 926,591 | -1.0% | overlap |
| contended_spawn_8x | 640,148 | 696,715 | **+8.8%** | **CLEAN** |
| contended_spawn_8x_batched | 670,816 | 675,098 | +0.6% | overlap |

Note N=2's contended_spawn_8x +8.8% is already covered by Option A's
native +9% CLEAN — it is not new uplift.

Trend: as N grows, flood_1m_batched gets worse (-1% → -7.6%). N=8
would be worse still; not measured.

## Root cause

Single-submitter flood_1m_batched has NO head-CAS contention to
relieve — there's only one consumer racing the head at any time, and
the submitter holds exclusive write access to its one (or with
sharding, N) tail cachelines.

Option A's win came from reducing consumer-side head CAS rate by 32x
(popMany) for the multi-producer `contended_spawn_8x` case where 8
submitters + many consumers ALL hit one head line. That's a real
contention scenario.

Option B's sharding distributes consumer-side contention further,
which helps `contended_spawn_8x` a bit (+8%). But for flood_1m_batched
(single submitter), the submitter now pays:

- Per batch of 64 pushes: submitter writes to N shard-tail cachelines
  instead of 1. On N=4, that's 4 line invalidations per 64 pushes
  rotated through shard cursor. The single-line hot path stayed in L1.
- The `inject_submit_cursor` atomic fetchAdd adds 1 RMW per push.
  Single-thread contention-free but still ~5-10ns each.

At flood_1m_batched's ~940K ops/sec (1.06 µs per task) budget, even
small per-push overhead is proportionally significant.

## What this definitively closes

1. **Sharded inject cannot raise flood_1m_batched above ~940K.** N=2
   and N=4 both fail. N=8 would fail worse. Sharding is the wrong
   attack.
2. **The real flood_1m_batched bottleneck is NOT inject head-CAS
   contention.** That was the brainstorm hypothesis; data falsifies
   it for the single-submitter case. The remaining candidates from
   the brainstorm are:
   - cacheline footprint of slot reads themselves
   - runTask state CAS rate
   - task-function dispatch / wait_group.done overhead
   - deeper profile needed
3. **Option C (MSQueue) is not worth trying** — it doesn't change
   head-CAS rate, only node allocation, which doesn't attack this
   bottleneck.

## What remains open

- flood_1m_batched is genuinely flat at ~940K with the currently-
  landed Option A. The target scenario needs a NEW profile to
  identify the true bottleneck.
- contended_spawn_8x at ~650-700K could be pushed further with
  sharding IF it becomes a primary target. But the flood_1m_batched
  regression under N=4 makes this a per-scenario trade-off that
  would need a config knob or scenario-specific dispatch.
- Multi-producer scenarios in general benefit from sharding. If a
  future workload dominated by multi-submitter pressure becomes the
  target, Option B could land with a gate measured against that
  scenario instead.

## Gate decision

Brainstorm gate: `≥ +15% flood_1m_batched CLEAN → pursue`.
Measured:

- N=4: **-7.6% CLEAN (negative)** on flood_1m_batched.
- N=2: **-1.0% overlap** on flood_1m_batched.

Both below the +5% hard-abandon threshold. Direction closed.

Per the brainstorm's own "if both flat/negative, bottleneck lives
deeper" clause, the next step is a new profile (perf-record on
flood_1m_batched) to identify what's actually binding at ~940K.
Not a micro-optimization direction — a re-profile is required first.

## Files

- `docs/performance/2026-04-14-inject-head-contention/ceilB_raw.txt` —
  N=4 paired bench output (n=10 rounds)
- `docs/performance/2026-04-14-inject-head-contention/ceilB_n2_raw.txt` —
  N=2 paired bench output (n=10 rounds)
- `docs/superpowers/brainstorms/2026-04-14-inject-head-contention.md` —
  brainstorm (status updated to include Option B closure)

No source code changes landed. Stub was reverted via `git checkout
src/pool.zig` after measurement.
