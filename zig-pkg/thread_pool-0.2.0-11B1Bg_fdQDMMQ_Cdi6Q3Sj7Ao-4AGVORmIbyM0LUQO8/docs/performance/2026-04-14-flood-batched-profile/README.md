# flood_1m_batched Profile — Steal-Peek Cacheline Storm

**Date:** 2026-04-14
**HEAD:** `36aaa04` (Option B abandoned, Option A + popMany landed)
**Host:** Intel Xeon E5-2680 v4, 2 sockets × 14 cores = 56 threads, 2 NUMA nodes
**Binary:** `zig-out/bin/thread-pool-tokio-parity` ReleaseFast with debug info
**Profile method:** `perf record -F 999 -g --call-graph dwarf` over 30 iterations of
`benchFloodBatched` (1M tasks × 30 = 30M tasks total), 1.07M samples, 1343 MB raw.

## TL;DR

The inject-queue head-CAS hypothesis (Option A/B) was wrong. At
~940K ops/sec the dominant worker cost is **`LocalQueue.len()`
called from the steal-victim peek loop**: **43.79% of worker
self-time**. This is a cacheline-coherence storm, not a head-CAS
storm.

Each call to `nextTask` that reaches the steal loop issues
**55 `len()` probes** (one per non-self victim). Each probe
reads `head` and `tail` from ANOTHER worker's local queue with
`.acquire` ordering — i.e. 2 cold-line loads per probe, 110 per
steal pass. Under flood_1m_batched's many-idle-stealer pattern,
workers mutually invalidate each other's cachelines while
probing. This is the binding cost at ~940K.

The Option A/B brainstorm's "slot read cacheline footprint"
candidate was closest but underestimated the magnitude: the cost
is in the **steal-peek** path, not the slot-read path.

## Top self-overhead

Flat report filtered to `cycles:P` samples within the worker
thread entry point (87.39% of all samples, the remaining ~13%
is submitter/idle/kernel):

| % self | Path | Cost class |
|-------:|------|-----------|
| **43.79%** | `LocalQueue.len` → `nextTask` | **victim-peek coherence** |
| 14.00% | `nextTask` (unattributed within function) | dispatch/branching |
| 3.84% | `cmpxchgWeak` → `releaseDescriptor` → `runTask` | descriptor release |
| 3.04% | `Value(u64).load` (mix of sites) | cold loads |
| 2.xx% | `popMany` inside `nextTask` | inject drain |
| 2.59% | `popBottom` inside `nextTask` | own-queue fast path |

Children-sorted view (top-down):

```text
 56.96% nextTask
  ├─ 43.79% LocalQueue.len          ← dominant
  ├─  4.86% popMany (inject drain)
  └─  2.59% popBottom
 13.60% idle (futex timedWait)
 12.63% runTask
  └─  7.27% releaseDescriptor
        └─  3.39% cmpxchgWeak
```

Raw reports: `perf_flat.txt`, `perf_children.txt`.

## Root cause

`Core.nextTask` (src/pool.zig:786-815) steal loop:

```zig
var offset: usize = 0;
while (offset < self.workers.len) : (offset += 1) {
    const victim_index = (start + offset) % self.workers.len;
    if (victim_index == worker_index) continue;
    // Cheap peek before paying the seq_cst CAS cost in steal().
    if (self.local_queues[victim_index].len() == 0) continue;
    ...
}
```

`RingQueue.len()` (src/queue/ring_queue.zig:55-66):

```zig
pub fn len(self: *const Self) usize {
    const t = self.tail.load(.acquire);
    const h = self.head.load(.acquire);
    const diff = t -% h;
    if (diff > @as(u32, @intCast(self.buffer.len))) return 0;
    return diff;
}
```

Two `.acquire` loads per probe. `head` and `tail` live on separate
cachelines (intentional — they're written by disjoint thread sets).
Probing 55 victims means 110 loads against cachelines owned by
**other workers' owner-writes** (for `tail`) or other stealers'
recent CAS wins (for `head`).

Under flood_1m_batched saturation:

- The single submitter pushes to inject_queue at batch size 64.
- ~20+ workers drain, but work distribution via local-queue
  steal means workers alternate "drain from own queue" and
  "steal pass". When own-queue drains (fast, L1-resident), the
  steal pass follows with cold probes across the NUMA topology.
- Two-socket Xeon: probing victim 28..55 crosses the socket
  boundary — inter-socket coherence traffic dominates.

## What this closes and opens

### Closes

1. **"Inject head-CAS is the bottleneck" hypothesis** — falsified
   independently by Option B (sharded inject regressed -7.6%) AND
   by this profile. Inject-queue popMany accounts for only ~5% of
   worker time; reducing its CAS rate further cannot unlock the
   scenario.
2. **"Slot-read cacheline footprint" candidate** — partial match.
   The cacheline footprint IS the bottleneck but it's in the
   *peek path*, not the *drain path*. Slot reads themselves are
   cheap once a steal/pop commits.

### Opens (new attack surface)

1. **Cheaper victim peek.** The comment at src/pool.zig:790 already
   says stale reads are fine. Demote acquire → monotonic on the
   peek loads. Cost: 0 correctness (comment is authoritative).
   Ceiling: removes the x86 memory fence; still pays the coherence
   miss. Expected <+15% since the cacheline traffic is the real
   cost, not the fence.
2. **Reduce probe count.** Instead of 55-victim linear scan per
   nextTask, cap at K=4 probes then park. Parked-worker wake is
   cheap relative to a 110-load coherence storm. Ceiling: could
   be dramatic if probes dominate over actual work.
3. **Per-socket victim bitmap.** Maintain a per-socket `u64`
   where bit `i = 1` if worker `i`'s local queue is non-empty.
   Owner sets/clears on push/pop transitions (not every op).
   Stealers read ONE `u64` to find candidate victims. Expensive
   to implement but collapses 55 probes to 1 read.
4. **Co-locate head/tail on same line.** Today they're separate
   cachelines to avoid owner/stealer false sharing on WRITES.
   For peek-only reads, that's still 2 loads. If peek reads only
   `tail` (and trusts that "tail is near head when queue is empty"
   heuristically), it's 1 load per victim — 2x reduction.
5. **Probe-free steal.** Skip the peek entirely and go straight
   to `stealHalf` on the victim. Pay the seq_cst CAS cost but
   avoid the 2 acquire loads. Probably a loss at N=56 since most
   victims will be empty, but worth a ceiling measurement.

## Recommended next step

Measure **attack 1 (monotonic peek)** first — smallest change,
no correctness risk per existing comment, directly tests whether
the fence-cost component is meaningful. If large win, land and
move on. If small win (<5%), the remaining 35%+ cost is pure
coherence miss and the fix must be structural (attack 2, 3, or 4).

Gate thresholds (applied to flood_1m_batched as primary):

- ≥+15% CLEAN → land
- +5%..+15% → land if contended_spawn_8x doesn't regress
- <+5% → shelf; coherence miss dominates, pursue attack 2/3/4

## Files

- `perf_flat.txt` — flat `perf report --no-children`
- `perf_children.txt` — call-graph `perf report` (default)
- Source profile data at `/tmp/profile_flood/flood_batched.data`
  (1.3 GB, not committed)
- Bench binary temporarily edited to loop `benchFloodBatched` 30×;
  edit reverted immediately after capture.
