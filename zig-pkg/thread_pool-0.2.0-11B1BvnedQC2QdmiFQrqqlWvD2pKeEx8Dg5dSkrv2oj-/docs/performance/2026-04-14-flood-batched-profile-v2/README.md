# flood_1m_batched Profile v2 — Post-Bitmap

**Date:** 2026-04-14
**HEAD:** `e533955` (steal-peek bitmap landed)
**Host:** Intel Xeon E5-2680 v4, 2 sockets × 14 cores = 56 threads
**Method:** `perf record -F 999 -g --call-graph dwarf` over 30 iterations
of `benchFloodBatched` (1M tasks × 30 = 30M tasks total), 1.5M samples.

## TL;DR

The bitmap worked as designed. `LocalQueue.len` — the 43.79%
hotspot in the v1 profile — is **completely gone** from the top
attribution. Steal-peek coherence storm is closed.

The new dominant hotspot is **`BoundedRing.popMany` at 16.64%** of
worker self-time within `nextTask` — specifically the inject queue
drain when a worker's local queue is empty. 13.43% is pure atomic
loads on the `inject_queue.head` / slot `sequence` cachelines.

## Top self-overhead (children-sorted, nextTask inner)

```text
93.00% worker entry
├── 42.96% nextTask
│   ├── 16.64% BoundedRing.popMany (inject drain)
│   │   ├── 13.43% atomic.load (head + slot sequence)
│   │   └──  2.64% cmpxchgStrong on head
│   ├──  2.95% u64.load (misc)
│   ├──  2.75% LocalQueue.popBottom
│   │   └──  2.08% RingQueue.pop
│   ├──  1.64% u32.swap (LIFO slot)
│   ├──  1.49% LocalQueue.steal (actual steal — fast path now)
│   └──  0.78% u64.fetchAdd (stats)
├── 21.89% Core.idle (park/wake)
│   └──  4.93% futex timedWait
└── 17.87% runTask
    └── 10.71% releaseDescriptor
        └──  4.79% cmpxchgWeak
```

Raw: `perf_flat.txt`, `perf_children.txt`.

## What this closes

- **Steal-peek coherence storm** — the 43.79% `LocalQueue.len`
  cost is gone. Bitmap v2 (e533955) structurally eliminated it.

## What this opens

1. **Inject-queue head contention (new #1).** 56 workers whose
   local queues drain concurrently all attempt `popMany` on the
   single `inject_queue`. Each attempt: one `head.load`, one
   `tail.load`, one `cmpxchgStrong`. One winner drains 32 items; 55 losers burn
   cacheline traffic on head+tail. Option B (sharded inject) was
   tried and failed; structural fix must come from a different
   angle.

2. **Per-slot sequence spin.** Inside a successful popMany, each
   of the 32 reserved slots is checked via
   `sequence.load(.acquire)` in a spin loop until the producer's
   `sequence.store` becomes visible. Producer-consumer rate
   mismatch forces this spin. 32 slots × N workers = heavy
   sequence-cacheline traffic.

3. **releaseDescriptor cmpxchgWeak at 4.79%.** Each task
   completion does a state CAS to cancel vs release. Possibly
   amenable to a fast-path `store` when no waiters exist.

4. **u64 loads (2.95% in nextTask + 9.75% overall).** Mostly the
   `counters.queued_tasks` / `counters.submitted` cross-core
   reads used for park heuristics and steal-start hinting. Might
   be reducible by making these owner-private estimates that
   reconcile only on transitions.

## Recommended next step

Attack #1 (inject-queue head contention) is the clear #1 target.
Strategies to evaluate:

- **A. Inject-nonempty flag** (analogue of bitmap for inject). Workers
  skip `popMany` entirely when flag is clear. Collapses 55 failed
  head.load/cmpxchg attempts to 1 u64 load per nextTask when
  inject is empty. Won't help during saturated submission (all
  pops succeed).

- **B. Fetch-add based drain reservation.** Replace head CAS
  with `head.fetchAdd(take)`. Eliminates CAS retries; workers
  just claim their chunk. Complicates empty-detection because
  fetchAdd can over-claim past `tail`; resolved by re-checking
  `tail` after fetchAdd and rolling back excess via a per-slot
  "skip" marker.

- **C. Owner-side inject drain by wake target.** Submitter wakes
  one worker; that worker alone drains. Others skip inject
  entirely and rely on bitmap-stealing. Simple, but depends on
  wake-target actually being the first to try drain.

- **D. Multi-slot batching at push side.** Submitter pushes N
  items under one head reservation — already implemented via
  submitBatch. Further batching across submissions isn't
  possible.

Gate remains ≥+15% flood_1m_batched CLEAN → land; +5..+15% with
no other CLEAN regression → land; <+5% → shelf.

## Files

- `perf_flat.txt` — `perf report --no-children`
- `perf_children.txt` — call-graph `perf report` (graph 0.3)
- Raw 13 GB perf.data deleted post-extract.
