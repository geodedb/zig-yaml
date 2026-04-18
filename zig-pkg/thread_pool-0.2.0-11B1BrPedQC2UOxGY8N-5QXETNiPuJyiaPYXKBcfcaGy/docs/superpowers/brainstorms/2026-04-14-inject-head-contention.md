# Inject-Queue Head Contention — Brainstorm (direction closed)

> **Status (final):** Option A landed partial (commit cd15524).
> Option B measured at N=2 and N=4, both FAIL the primary gate;
> direction abandoned. Inject-queue head CAS is no longer the
> binding constraint for flood_1m_batched — bottleneck lives
> deeper. See `docs/performance/2026-04-14-option-b-abandoned/`.
>
> **Option A (`popMany`) landed:** fixed n=20 paired A/B
> (authoritative, `ceilA_fixed_raw.txt`): flood_1m_batched +3.8%
> overlap, contended_spawn_8x +9.0% CLEAN, flood_1m +4.7% overlap,
> contended_spawn_8x_batched +6.2% overlap. Landed at cd15524
> because the +9% CLEAN on contended_spawn_8x is real and the
> `popMany` primitive is reusable.
>
> **Option B (sharded inject) abandoned:** n=10 paired A/B vs
> Option A baseline. N=4: flood_1m_batched **-7.6% CLEAN
> (negative)**, contended_spawn_8x +8.3% CLEAN, others near-flat.
> N=2: flood_1m_batched -1.0% overlap, contended_spawn_8x +8.8%
> CLEAN (redundant with Option A's own +9%). Submitter-side cost of
> rotating across N cachelines outweighs consumer-side win on
> single-submitter flood. Direction closed.
>
> **Option C (MSQueue) and Option D (Treiber) not pursued** — both
> ruled out by brainstorm analysis as not attacking the measured
> bottleneck differently enough to justify upheaval.
>
> **Forward:** per brainstorm's own "if both flat/negative,
> bottleneck lives deeper" clause, flood_1m_batched needs a new
> profile to identify what's actually binding at ~940K. Candidates:
> slot read cacheline footprint, runTask state CAS, task dispatch
> overhead, wait_group.done cost. NOT a micro-optimization direction
> until re-profile reveals a new target.
>
> History: Option A's initial n=20 run measured +13.8% IQR-clean
> flood_1m_batched, but that was against a buggy `nextTask` path
> that silently dropped items on local-queue overflow. The bug was
> caught via `zig build test` hang, fixed, and re-measured. The
> fixed result is less optimistic but honest.
>
> Spawned from
> `docs/performance/2026-04-14-cascading-wake-abandoned/README.md`
> which closed the wake-side direction and named inject_queue head
> CAS as the bottleneck blocking flood_1m_batched above ~900K ops/s.
> Submitter-side atomics are already cheap (batched-submit landed
> at 3177308). Wake-side mechanisms are ruled out (Ceiling B negative).
> The remaining attack surface is the pop path.

## Current pop path

`Core.nextTask` (src/pool.zig:761) pops from `inject_queue` (a single
Vyukov MPMC `BoundedRing(u32)`) after LIFO slot and local deque miss.
The drain loop:

```zig
if (self.inject_queue.pop()) |descriptor_index| {  // head CAS #1
    var moved: usize = 1;
    while (moved < self.config.inject_batch_size) : (moved += 1) {
        const extra = self.inject_queue.pop() orelse break;  // head CAS #N
        if (!lq.tryPushBottom(extra)) { ...; break; }
        moved += 1;
    }
    return descriptor_index;
}
```

With `inject_batch_size = 32` (default), each "drain round" by one
worker issues up to **32 head CAS operations** back-to-back. The head
CAS sits on one cacheline shared by all poppers. The workers that
miss the drain (because a peer got there first) retry.

On flood_1m_batched with ~20 active workers measured (see cascading
wake audit), this yields thousands of head-CAS events per wall-clock
millisecond, all on one line. perf-stat showed IPC 0.09 and 36%
cache-miss rate — classic shared-line coherence storm.

## What Ceiling B proved (negative)

Keeping ALL workers active instead of ~20 regresses flood_1m_batched
by 44.6%. So the solution is not "wake more workers." The solution
must reduce **per-event head-CAS contention** for the workers we
already have.

## Option A: batched pop via single head RMW

**Idea:** replace the 32-CAS drain loop with ONE head RMW that
reserves K slots at once. Currently Vyukov's `pop()` is one CAS per
item. A `popMany(buf[0..K])` primitive can:

1. `head.fetchAdd(K, .monotonic)` — reserves K consecutive slots in
   one RMW (one cacheline transit for the whole batch).
2. For i in 0..K: spin on `slot[head+i].sequence == head+i+1` (ready
   signal from producer), read `slot[head+i].value`, then store
   `slot.sequence = head+i+buffer.len` to release back to producers.

Correctness: producers still push via `tail.cmpxchgWeak(tail, tail+1)`
plus slot-sequence store. The sequence protocol doesn't care whether
consumers advance head one slot at a time or K at a time; producers
see available slots via sequence, not head. The K-slot reservation
is atomic because `fetchAdd` is atomic.

One subtlety: if the producer hasn't filled slot `head+3` yet but did
fill `head+0..2`, the consumer's sequence-spin on slot 3 blocks
reading slots 3..K-1 until the producer catches up. This is a
**consumer-side stall** that doesn't exist in the current per-item
pop path (which just returns `null` on a not-ready slot).

Mitigations:

- On stall after some timeout, return partial: yield out `i` items
  already consumed, leave head advanced past `head+i..head+K-1`
  ghost-reserved. But a ghost-reserved slot blocks other consumers
  from advancing past it — **cannot be safely released without new
  machinery**. This breaks the design.
- Better: `popMany` only commits the RMW if all K slots are already
  ready. Pre-check: `tail - head >= K` with acquire loads, then
  `head.cmpxchg(head, head+K)` to commit. If tail moves, retry; if
  tail is less than head+K, fall back to single pop. This keeps the
  fast path clean and adds a cheap slow-path.
- Even better: adaptive K. If tail-head >= K, grab K. Else grab
  tail-head. Requires re-reading tail after the cmpxchg succeeds —
  but that's just an acquire load, cheap.

**Head-CAS reduction:** 32:1 for the hot path. 20 workers × 1
CAS/drain × 30K drains = 600K head CAS events total vs today's
~~1M head CAS events (before the batch kicks in). ~~ Actually the
current inject_batch_size=32 drain pattern already does 32 pops per
successful first-pop, but they are 32 **separate** CAS-on-head
events, not one. So the savings is still ~32x on CAS rate at the
cacheline level.

**Risk:** if the precondition `tail-head >= K` rarely holds under
submitter-pacing, the fast path falls through to per-item pop every
time and no savings materialize. Needs measurement: what fraction of
drain rounds have tail-head >= 32 at entry?

## Option B: sharded inject (N small rings)

**Idea:** replace `inject_queue: BoundedRing` with
`inject_shards: [N]BoundedRing` where N is small (2, 4, or 8).
Submitter picks shard via round-robin cursor on the Core. Workers
rotate their own cursor when popping. Head CAS distributes across
N cachelines — N-way less contention per line.

Why this differs from abandoned Option 3 (per-worker incoming):

| | Option 3 (abandoned) | Option B (small N) |
|---|---|---|
| Shard count | 56 (one per worker) | 2-8 |
| Submitter cacheline spread | 56 lines → all cold | 2-8 lines → all in L1 |
| Worker locality on pop | 1 shard (own) | rotates, ≤N shards |
| flood_1m submitter cost | cold-miss every submit | ~none |

The Option 3 failure was SUBMITTER cold-miss on rotating through 56
lines. Small N avoids that: even N=8 keeps all 8 shard tails in L1
for a single submitter because cacheline footprint is ~8 × 128B = 1KB,
well within L1d. Submitter round-robins: for flood_1m_batched (one
submitter), each shard gets a burst of 8 tasks (batch/N). Sequential
access, all-hot.

**Head-CAS reduction:** N:1 by definition. N=4 → 4x less contention
per line. With 20 workers distributed across 4 shards, each shard has
~5 poppers instead of 20.

**Pop side:** worker needs to rotate its cursor. On empty shard,
advance to next shard. That's potentially N-1 wasted CAS attempts on
empty shards if work is concentrated on one shard. Mitigation: peek
`len()` on each shard before CAS (acquire-load head+tail, cheap).

**Risk 1:** submitter-side — even with N=4 and batch=64, each shard
gets 16 tasks/batch. Tail CAS per shard is `batch_size/N = 16` per
batch submit. So submitter pays 64 total CAS (same as unsharded
inject with batch=64 minus its 1-RMW amortization for counters).
Actually worse: submitter now CAS-ing 4 shards' tails per batch
instead of 1 shard's tail 64 times. One CAS × 4 shards = 4 CAS
events on 4 different cachelines per batch vs 64 CAS on 1 shard's
line. 4 line transitions on submitter side vs 64 uncontended CAS on
one line (submitter's L1). The 64-CAS-on-one-line case is "hot line"
but only submitter writes it — no contention. So submitter cost
might actually INCREASE. Requires measurement.

**Risk 2:** workload skew. If submitter's round-robin hashing pushes
to shard 0 slightly faster than 1-3, workers pile up on shard 0's
head and the contention relocates rather than distributes. Can be
mitigated with randomized submitter selection (fetch & increment
on per-core state).

**Risk 3 (unique to this approach):** re-balancing. If shard 0 has
1000 items and shard 1 has 0, a worker on shard 1 can't drain
shard 0's backlog without a full rotation. Could add steal-from-
shard after worker's local+own-shard both empty. But that's a
search-space similar to what the local_queues steal loop already
does. Incremental.

## Option C: MSQueue (lockfree linked list)

**Idea:** replace the Vyukov ring with a Michael-Scott queue. Nodes
are cacheline-isolated; `head` and `tail` pointers are on different
cachelines by design.

Reasons to rule this out as primary:

1. **Allocation cost.** Per-enqueue node alloc is ~50-100 ns on
   an arena-free allocator. At 1M tasks/sec, that's 50-100 ms of
   pure alloc time per second of benchmark, or 5-10% overhead.
   The descriptor pool already exists for task metadata; making
   MSQueue nodes reuse descriptors is non-trivial.
2. **No bound.** Vyukov's bounded ring gives backpressure "for free"
   via push-fail. MSQueue is unbounded (or requires separate counter).
   Changing the bounded-queue semantics cascades into
   `options.backpressure` handling.
3. **Head CAS is still contended.** MSQueue's head CAS is on one
   line (head pointer), same as Vyukov. The cacheline is smaller
   footprint (just a pointer vs 128B sequence+value), so fewer
   aliased misses, but the CAS rate is identical.

So MSQueue doesn't attack the bottleneck differently enough to
justify the upheaval. Not worth pursuing as a standalone direction.
Mention here for completeness — can revisit as sub-component of a
larger design.

## Option D: treiber stack

**Idea:** inject as a LIFO Treiber stack. Each push is one
`head.cmpxchgWeak` on a pointer; each pop is same.

Ruled out: LIFO semantics invert submission order — bad fit for the
"flood" scenario and changes latency semantics for users. Also same
head-CAS cost as Vyukov. No structural win.

## Ceiling A/B design (gate before implementation)

**Two separate stubs**, both cheap, both reversible:

### Ceiling A: "batched pop cheat"

Modify the pop path to skip the per-item loop and instead do a single
`head.fetchAdd(32)` RMW, reading 32 slot values linearly. Skip the
sequence-spin entirely (unsafe — relies on submitter being ahead,
which it is in flood_1m_batched). This is **not correct code**; it is
a ceiling stub that measures "what if head-CAS rate dropped 32x." If
the ceiling is ≥ +15% flood_1m_batched with clean separation, Option
A is worth implementing for real. If <5%, head-CAS rate is not the
binding constraint and we rethink.

### Ceiling B: N=4 parallel inject rings stub

Add `extra_inject_queues: [3]BoundedRing` alongside the main
inject_queue. Modify submit path's tail CAS to round-robin across
4 rings (including the existing one). Modify pop path to rotate
through them. No re-balancing, no steal — minimum viable. Measure
flood_1m_batched. If ≥ +15% with clean separation, Option B is
justified. If <5%, sharding doesn't help.

Run both ceilings. The higher-ceiling option is the one to build.
If both >15%, A is simpler to land — prefer A. If only B wins,
build B with proper engineering.

## Implementation-level design questions (post-ceiling)

These only matter if a ceiling justifies:

1. **API shape for popMany.** Add `BoundedRing.popMany(buf: []T) usize`
   that fills buf and returns count consumed. Worker passes its
   local-queue scratch slice directly.

2. **Sequence-spin bound.** On `popMany`, bound the per-slot spin at
   some small iteration count; on timeout, commit the ghost
   reservation by storing the expected "available" sequence on the
   stalled slot (so the producer can still publish later and the
   consumer sees a ready slot). Ugly — needs review.

3. **Adaptive K.** If `tail.load() - head < K`, reduce K to
   `tail - head`. Recompute on each drain entry.

4. **Shard count for Option B.** Start with N=4. Parameterize via
   `Config.inject_shards`. Measure N=2 and N=8 as sensitivity.

5. **Cursor for Option B.** Submitter uses
   `counters.submitted % N`. Worker uses `worker_index % N` for
   initial shard; on empty-shard, rotate (worker_index+1) % N.
   Avoids a shared cursor atomic.

6. **Interaction with backpressure.** For Option B, `.block` on
   shard full must NOT deadlock if another shard has capacity.
   Either (a) rotate to next shard on full, or (b) block on specific
   shard. Prefer (a) for single-submitter flood; prefer (b) under
   multi-submitter to avoid thundering hand-off.

## Risks summary

1. **Option A correctness.** Ghost-reserved slots block forward
   progress if left hanging. Real implementation needs the
   adaptive-K precheck to avoid reserving beyond tail. The ceiling
   stub skips this — expected divergence between ceiling and real.

2. **Option B submitter cost.** N cachelines written per batch vs
   1 could offset the consumer-side win. Ceiling B will reveal.

3. **Interaction with cancellation.** `cancelQueuedTasks` currently
   drains `inject_queue` to skip queued descriptors. Option B
   requires draining all N shards. Straightforward but must not be
   forgotten.

4. **Observability.** Existing stats (`queue_depth_peak`) track one
   queue. Option B needs per-shard stats or combined. Minor.

## Proposed next step

Run Ceiling A first — it is the smallest code change and directly
tests the "head-CAS rate is the binding cost" hypothesis. If Ceiling
A wins, Option A is the implementation direction (smaller blast
radius, no API changes). If Ceiling A is near-flat, run Ceiling B.
If both flat/negative, the bottleneck lives deeper (cacheline
footprint of slot reads themselves, or something in runTask state
CAS) and we need a new profile before picking a direction.

Gate thresholds:

- ≥ +15% flood_1m_batched median, clean distribution separation →
  pursue
- +5% to +15% → revisit ceiling measurement (check host, n=20)
- <+5% → abandon this option, try the other

Open questions above become implementation-phase decisions — this
brainstorm does not claim to answer them, only to gate the whole
direction on the Ceiling A/B measurement.
