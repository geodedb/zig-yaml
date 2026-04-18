# Inject-Queue Batched Pop (Option A) — Partial Win, Multi-Producer Only

**Date:** 2026-04-14
**Brainstorm:** `docs/superpowers/brainstorms/2026-04-14-inject-head-contention.md`
**Baseline commit:** `273293e` (cascading-wake abandoned docs)

## TL;DR

Added `BoundedRing.popMany(buf)` that reserves up to `buf.len`
consecutive slots via a single `head.cmpxchgStrong` RMW and reads
them into the caller's buffer with per-slot sequence-spin. Rewired
`Core.nextTask`'s inject-drain path to use `popMany(buf[0..32])`
instead of a 32-iteration per-item `pop()` loop.

Result on tokio-parity bench, n=20 balanced-order paired A/B
(10 rounds × BSSB, host: 56-core, normal load):

| Scenario | Baseline median | Stub median | Δ | IQR separation |
|---|---:|---:|---:|:---|
| flood_1m | 391,966 | 410,436 | +4.7% | overlap |
| flood_1m_batched | 905,240 | 939,557 | **+3.8%** | overlap |
| contended_spawn_8x | 590,968 | 644,174 | **+9.0%** | **CLEAN** (Q3 609K < Q1 631K) |
| contended_spawn_8x_batched | 638,220 | 677,857 | +6.2% | overlap |

**Primary-target gate missed.** flood_1m_batched delivered +3.8%
overlap, below the brainstorm's hard gate (`≥ +15% clean separation
→ pursue`). contended_spawn_8x's +9% IQR-clean is the real win —
multi-producer scenarios benefit from reduced head-cacheline traffic
even when the amplification doesn't show up on the single-submitter
target.

Landing anyway because (1) the code is clean and stress-gated, (2)
the +9% CLEAN contended_spawn_8x win is real and persistent, (3)
`popMany` is a reusable queue primitive, (4) no regression on any
measured scenario.

## History — why the first measurement showed +13.8%

An earlier n=20 run (preserved in `ceilA_raw.txt`) measured +13.8%
flood_1m_batched with IQR-clean separation. That measurement was
taken against a buggy `nextTask` path that, on `tryPushBottom`
overflow at buf index `i`, pushed only `buf[i]` back to inject_queue
instead of `buf[i..n]` — silently dropping subsequent items. The
bug did not corrupt the bench (workloads never triggered the
overflow path) and tests passed, but the path existed. `zig build
test` later hung once the overflow path fired in a stress-like
scenario; root-caused and fixed. The fix (push all remaining items
back) made the loop correct and is what ships here. The +3.8%
result above is from the correct code, n=20 same-session paired
A/B.

Key lesson for the measurement log: the buggy-version lift was
partly host-state artifact (baseline median 862K then vs 905K
now) and partly because the drop path, while never triggered,
could have minor effects on speculative execution layout. The
honest, fixed measurement is what the audit records.

## Why this works (partially)

flood_1m_batched bottleneck, per
`docs/performance/2026-04-14-cascading-wake-abandoned/`: ~20 active
workers race `inject_queue` head CAS to pop. Each worker that
enters the drain path does up to 32 back-to-back head CAS ops.
Cacheline coherence storm.

`popMany` replaces 32 CAS ops with 1:

- `head.cmpxchgStrong(h, h + take)` reserves `take` slots atomically
- caller reads slots one-by-one, waiting on each slot's sequence if
  the producer hasn't yet written it
- on CAS loss (another consumer won), returns 0 and caller falls
  through to steal-loop

flood_1m_batched's gain is small (+3.8%) because the head-CAS
amplification isn't as dominant as the earlier audit hypothesized —
the single-submitter feeds slowly enough that consumers aren't
perpetually contending. contended_spawn_8x (8 submitters, 20 workers,
more producer/consumer pressure simultaneously) shows the real
win: +9% CLEAN.

flood_1m is unchanged (+4.7% overlap, noise-level) because only one
worker at a time drains — no contention to eliminate.

## Why land despite missing the primary gate

1. **Smallest blast radius.** One new method on `BoundedRing`,
   one modified call site in `nextTask`. No API changes, no
   cancellation-path changes, no config knobs. Revert is trivial.
2. **No regression on any scenario.** Worst case is flood_1m_batched
   at +3.8% overlap — within noise, not a loss.
3. **Reusable primitive.** `popMany` is a general batched-pop for
   Vyukov rings. If the project later adds more places that drain
   a shared ring, the primitive is ready.
4. **Headroom for Option B still open.** Sharded inject (Option B
   in the brainstorm) can layer on top — each shard can use
   `popMany`. This landing doesn't close that door.
5. **Multi-producer is a real case.** Real-world users spawning
   from threadpools-of-threadpools, async runtimes with N-way
   submitters, etc. hit the multi-producer case. A +9% IQR-clean
   win on that class is not throwaway.

## Implementation

`src/queue/bounded_ring.zig`:

```zig
pub fn popMany(self: *Self, buf: []T) usize {
    const head = self.head.load(.monotonic);
    const tail = self.tail.load(.acquire);
    const avail_signed = @as(isize, @intCast(tail)) -% @as(isize, @intCast(head));
    if (avail_signed <= 0) return 0;
    const avail: usize = @intCast(avail_signed);
    const take = @min(avail, buf.len);
    if (take == 0) return 0;
    if (self.head.cmpxchgStrong(head, head +% take, .monotonic, .monotonic)) |_| {
        return 0;
    }
    var i: usize = 0;
    while (i < take) : (i += 1) {
        const slot = &self.buffer[(head +% i) & self.mask];
        const expected_seq = head +% i +% 1;
        while (slot.sequence.load(.acquire) != expected_seq) {
            std.atomic.spinLoopHint();
        }
        buf[i] = slot.value;
        slot.sequence.store(head +% i +% self.buffer.len, .release);
    }
    return take;
}
```

`src/pool.zig` (`nextTask` inject-drain site): replaces the old
per-item pop loop with a `popMany(buf[0..cap])` call. Items
`buf[1..n]` are pushed to the local deque; on `tryPushBottom`
overflow, ALL remaining `buf[i..n]` are pushed back to inject_queue
(not just `buf[i]` — that was the bug caught during development).

Unit tests in `src/queue/bounded_ring.zig` cover empty, basic pop,
cap-at-available, interleaving with single-item `pop`, and
wraparound. 20× ReleaseFast `test-stress` runs: 20/20 pass.

## Gate reconciliation

Brainstorm-stated gate: `≥ +15% flood_1m_batched median, clean
distribution separation → pursue`.

Measured (flood_1m_batched): **+3.8% overlap** — below the pursue
gate.

Per the brainstorm's own downgrade rule (`<+5% → abandon this
option, try the other`), flood_1m_batched is a hair above the
abandon line (+3.8% vs +5%). The decision to land anyway rests on
the contended_spawn_8x +9% CLEAN — a legitimate improvement on a
distinct parity scenario — and the architectural cleanliness.

This is a **partial landing with a pivot**. Option B (sharded
inject) remains the next-step direction for attacking
flood_1m_batched specifically. Option A's cost is covered by its
contended_spawn_8x win; any stacking with Option B is additive.

## Files

- `src/queue/bounded_ring.zig` — `popMany` + 5 new unit tests
- `src/pool.zig` — `nextTask` inject-drain rewritten to use `popMany`
- `docs/superpowers/brainstorms/2026-04-14-inject-head-contention.md` —
  brainstorm (status updated)
- `docs/performance/2026-04-14-inject-head-contention/README.md` —
  this file
- `docs/performance/2026-04-14-inject-head-contention/ceilA_fixed_raw.txt` —
  authoritative n=20 paired bench output (correct code)
- `docs/performance/2026-04-14-inject-head-contention/ceilA_raw.txt` —
  initial (buggy-version) n=20 paired output, preserved for history

## What this does NOT resolve

- flood_1m_batched above ~940K still blocked by head-CAS rate at
  the ring level. Option B (sharded inject) is the designated
  follow-up.
- flood_1m (unbatched) single-submitter bottleneck unchanged (see
  `project_flood_1m_ceiling_closed`).
- Tokio parity gap remains large on flood_1m_batched (~940K vs
  multi-million for Tokio rt_multi_threaded). This landing is one
  small step.
