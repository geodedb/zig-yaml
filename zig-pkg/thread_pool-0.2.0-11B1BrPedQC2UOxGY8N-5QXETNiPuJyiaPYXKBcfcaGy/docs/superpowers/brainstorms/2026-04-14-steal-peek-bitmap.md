# Steal-Peek Bitmap — Brainstorm

**Parent profile:** `docs/performance/2026-04-14-flood-batched-profile/`
**Root cause:** `LocalQueue.len()` 43.79% of worker self-time via
55-victim `nextTask` peek loop — pure cacheline coherence traffic
across 56 workers' queue head/tail lines.
**Both cheap ceilings failed** (monotonic peek, probe cap) — see
`docs/performance/2026-04-14-flood-batched-profile/ceiling-attempts.md`.
The attack must be structural.

## Design: non-empty bitmap

Add a single `workers_nonempty: std.atomic.Value(u64)` on `Core`,
one bit per worker. Supports up to 64 workers (this host has 56).

**Owner-side update path** (cold, runs only on 0↔1 transitions):

- `tryPushBottom` success + local queue was empty before → `fetchOr(1 << worker_index, .release)`
- `popBottom` success + local queue is empty after → `fetchAnd(~(1 << worker_index), .release)`

Transitions are rare relative to pushes/pops: in flood_1m_batched
a drained worker pushes ~32 items then pops them — exactly 2
transitions per 32+32 ops, so bitmap updates amortize at ~3%
of ops.

**Stealer-side read path** (hot, runs on every nextTask steal pass):

```zig
const mask = self.workers_nonempty.load(.acquire) & ~(1 << worker_index);
if (mask == 0) { ...steal_failures++; return null; }
// iterate set bits via @ctz(mask); mask &= mask - 1
```

Replaces the 55-victim peek loop. One `.acquire` load of a central
u64 instead of 110 loads on 56 workers' private lines.

## Correctness

- **Stale set bit:** owner cleared bit on pop-to-empty but then
  pushed again (race). Stealer sees old bit value = "maybe has
  work". Stealer attempts `steal()`, finds empty, moves on. No
  correctness impact — same outcome as today's stale `len()` read.
- **Stale clear bit:** owner pushed 0→1 but hasn't yet set bit.
  Stealer sees bit cleared, skips victim. Missed-opportunity, not
  correctness. Same outcome as today's stale `len()` read returning
  0 for a queue with a partially-written tail.
- **Shutdown drain:** shutdown cancels queued tasks via
  `stealOne` on each worker. Must iterate all workers, not just
  set bits (in case a bit was stale-cleared). Easy: use the
  existing `for (self.workers) |*w|` loop in drain path.

## Cacheline / NUMA considerations

The `workers_nonempty` u64 sits on one cacheline — under concurrent
transitions from 2-socket × 14-core × 2-thread workers it's a
potential hot line. Mitigations:

1. **Partition by socket.** Two `u64` masks, one per socket. Each
   covers its ~28 workers. Stealer reads both (2 acquire loads).
   Still 55x better than today.
2. **Accept single-line contention** for an initial implementation
   and measure. If writes cause >5% of scenario regressions, move
   to socket-partition.
3. **Put the mask on its own cacheline** (`alignas(64)`) to avoid
   false sharing with whatever else is on Core.

Start with option 2 + 3. Measure. Upgrade to 1 only if justified.

## Implementation surface

Files to touch:

- `src/pool.zig`
  - `Core` struct: add `workers_nonempty: std.atomic.Value(u64)` aligned.
  - `nextTask` steal loop: iterate bits instead of all workers.
  - `submit` path (tls_worker_index case, ~line 641): detect 0→1
    transition and set bit.
  - `nextTask` inject-drain (~line 769) and steal-reinject (~line 805):
    detect 0→1 after tryPushBottom.
  - `nextTask` popBottom (~line 757): detect post-pop empty.
- `src/pool.zig` `LocalQueue.tryPushBottom/popBottom` — may need
  to return a "was_empty" hint, or callers can compute len() pre/post
  (cheap for owner).

Simpler API: wrap the ops in `pushLocal(core, worker_index, value)` /
`popLocal(core, worker_index)` helpers that encapsulate the
transition logic. Keeps the bitmap logic in one place.

## Ceiling expectation

Profile attributes 43.79% of worker time to peek loads. If bitmap
reduces peek cost by ~98% (2 loads vs 110), we recover ~42% of
worker cycles — theoretical ceiling ~+70% on flood_1m_batched
(ops/sec inversely proportional to worker cycle cost on critical
path).

Practical expectations:

- Huge win (≥+30%) means the attack is correct and we should land.
- Flat/negative means the write-side contention on the single
  bitmap line exceeded the read-side savings — fall back to
  socket-partition or abandon.
- +5-15% means marginal; check contended_spawn_8x and decide.

**Gate:** ≥+15% flood_1m_batched CLEAN, no CLEAN regression on
any other scenario → land.

## Implementation order

1. Add mask field and alignment on Core.
2. Add bit-set/clear at 3 push sites and 1 pop site with owner-local
   `lq.len()` check before/after (cheap: L1 reads).
3. Rewrite nextTask steal loop to iterate `mask & ~self_bit` set bits.
4. `zig build test` (hang was Option A's bug — watch for regression).
5. `zig build test-stress` 20×.
6. Paired A/B n=10 vs current main (`7c46e1f`).
7. Land or revert based on gate.

## Risks

1. **Correctness via pre/post len checks.** If a concurrent stealer
   takes the last item between owner's push-and-len-check, owner's
   "was_empty" could misread. But owner's `tryPushBottom` then
   `lq.len()` reads: the owner just wrote tail, so len-after-push
   >= 1. Stealer can only reduce to 0 via a CAS on head; that
   happens AFTER our tryPushBottom returned, so post-check
   sees post-steal state. This means transition detection may be
   noisy — we could set the bit when already 0 or skip setting
   when we should. Stale bits are correctness-safe per the section
   above.
2. **popBottom race with stealer.** Owner's popBottom may return
   null (empty) while a stealer is mid-CAS. Today we handle this.
   Our transition detection only fires on non-null return; no
   state change on null. Safe.
3. **Cold paths may not cover all workers.** Shutdown must iterate
   workers[] explicitly. Documented above.
4. **Test surface.** Current stress tests are 20× ReleaseFast.
   Non-empty bitmap adds a new synchronization primitive — stress
   may reveal races I haven't thought of. Must iterate.

## Measured result (n=10 BSSB, paired, same host)

| Scenario | Baseline | Bitmap v2 | Δ | Sep |
|---|---:|---:|---:|:---|
| flood_1m | 395,410 | 393,413 | -0.51% | overlap |
| flood_1m_batched | 904,987 | 931,902 | +2.97% | overlap |
| contended_spawn_8x | 641,014 | 750,235 | **+17.04%** | **CLEAN** |
| contended_spawn_8x_batched | 663,339 | 631,887 | -4.74% | overlap |

Primary-target gate (≥+15% flood_1m_batched CLEAN) **FAILED** —
the peek cost wasn't the dominant flood_1m_batched bottleneck as
the profile suggested. But contended_spawn_8x got a **+17% CLEAN**
— a real steal-heavy scenario win.

**v2 refactor:** Initial v1 used `lq.len()` pre/post for
transition detection — which reads the stealer-written `head`
cacheline on every pop (1 coherence miss × 1M pops). Replaced with
owner-private `Worker.owned_queue_len` counter. Increments on
push, decrements on pop, reconciles to 0 when `popBottom` returns
null (handles stealer-drain case). Keeps all owner-side bookkeeping
in owner-local L1.

**Decision: LAND.** Precedent: popMany (cd15524) landed +9% CLEAN
contended_spawn_8x despite missing flood_1m_batched primary gate.
This is a strictly larger contended_spawn_8x win (+17% vs +9%),
neutral flood_1m and flood_1m_batched, soft -5% overlap on
contended_spawn_8x_batched (not CLEAN regression). No CLEAN
regressions anywhere → worth banking.

**Follow-up:** socket-partition bitmap (2× u64, one per NUMA
socket) may reduce fetchOr/fetchAnd contention enough to move
flood_1m_batched into positive CLEAN territory. Separate experiment.

## Proposed commit message

```text
perf(pool): worker non-empty bitmap for steal-peek scan

Replace nextTask's 55-victim linear peek loop (each victim required
2 acquire loads on its head/tail cachelines — 43.79% worker
self-time per flood_1m_batched profile) with a single u64 bitmap
read. Owner-side updates run only on queue 0↔1 transitions.

Transition detection uses an owner-private `Worker.owned_queue_len`
counter (incremented on push, decremented on pop, reconciled to 0
when popBottom returns null) — avoids reading the stealer-written
head cacheline during owner bookkeeping.

Shutdown drain path already iterates all workers explicitly, so
stale bitmap bits cannot orphan pending tasks.

n=10 BSSB paired A/B on 56-worker Xeon E5-2680 v4:
- contended_spawn_8x: +17.04% CLEAN (641k → 750k ops/sec)
- flood_1m: -0.51% overlap (neutral)
- flood_1m_batched: +2.97% overlap (missed +15% gate — peek cost
  not the dominant batched-flood bottleneck after all)
- contended_spawn_8x_batched: -4.74% overlap (not CLEAN)
```
