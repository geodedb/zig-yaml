# Ceiling Attempt: Bitmap-Steal Before Inject popMany

**Parent:** `README.md` (v2 profile identifying
`BoundedRing.popMany` at 16.64% worker self-time as new #1).
**Baseline:** `4a536d2` (`e533955` bitmap + v2 profile docs).
**Date:** 2026-04-15.

## Hypothesis

Reorder `nextTask` so bitmap-driven peer-steal runs BEFORE the
inject popMany drain. Rationale: if peers have stealable work,
prefer that (cheap — bitmap is 1.49% in profile) over the inject
head-CAS race (16.64%). This naturally throttles inject drainers
to just workers that found no stealable peer.

## Result

**FAILED — correctness regression.** Reorder introduced
nondeterministic SIGSEGV in 3+ stress tests:

- `phase g2: aggressive spin flood - no lost wakeups`
- `phase h: double-dequeue race reproducer`
- `backpressure backoff: 4 submitters, queue=256, 2 workers`

Observed failure rate: ~4/10 runs at n=10 paired retries. All
failures are SIGSEGV in shutdown-adjacent code paths. HEAD stress
is clean (5/5 runs on revert).

## What the reorder changed

Old order:

1. LIFO slot
2. popBottom (own local)
3. popMany (inject drain)
4. bitmap-steal (peer locals)

New order:

1. LIFO slot
2. popBottom (own local)
3. bitmap-steal (peer locals)
4. popMany (inject drain)

The edit was a straight block swap; fall-through semantics
preserved. Both branches still update `owned_queue_len` and
`workers_nonempty` identically.

## Why it broke (hypothesis — not fully nailed down)

The swap appears to expose a race between worker's bitmap-steal
and concurrent `cancelQueuedTasks` during shutdown. When shutdown
drains local queues via `stealOne` (pool.zig:1074-1078), the
bitmap bits aren't atomically updated. A worker mid-nextTask can
read the bitmap, see bit set, call `steal()` on a victim whose
local is being concurrently nulled out by shutdown — and either
double-dequeue or hit torn pointer state that doesn't manifest
when popMany runs first (popMany's early head-CAS-race serves as
a natural ordering barrier with shutdown's inject drain).

Root cause unconfirmed — pursuing this direction requires
instrumenting the SEGV (core dump + addr2line on crash RIP) to
pinpoint which load/store faulted, OR redesigning shutdown to
gate bitmap iteration.

## Closed

Revert preserved; no changes landed.

## Next direction candidates (still open)

Per v2 profile README `What this opens`:

- **A. Inject-nonempty flag.** Producers `store(1)` on push
  success; consumers read flag before calling popMany. Doesn't
  help saturation (inject usually nonempty then) but avoids
  empty-popMany cost in lower-load scenarios.
- **B. FetchAdd-based drain reservation.** Replace head
  `cmpxchgStrong` with `fetchAdd(take)`. Eliminates CAS retry
  race. Requires post-fetchAdd tail re-check with rollback
  semantics when over-claimed — nontrivial.
- **C. Owner-side drain by wake target.** Submitter wakes one
  worker; that worker alone drains inject, distributes via local
  queue + bitmap. Requires a wake-target marking mechanism.
- **D. Drain-before-park only.** Inject popMany only runs as the
  last step before parking (instead of before bitmap-steal). If
  bitmap-steal fails AND LIFO fails AND popBottom fails, only
  THEN pay popMany. This is what the reorder attempted — but
  broke shutdown. Could be redesigned with explicit shutdown
  synchronization.

Gate unchanged: ≥+15% flood_1m_batched CLEAN → land; no CLEAN
regression elsewhere.
