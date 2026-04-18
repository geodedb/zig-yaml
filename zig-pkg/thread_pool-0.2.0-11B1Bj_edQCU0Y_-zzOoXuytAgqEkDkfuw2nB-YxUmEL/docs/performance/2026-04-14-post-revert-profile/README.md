# 2026-04-14 — Post-revert hot-path profile

Profile of `main` at commit `7ef4ae9` (post slice-A revert) on the freshly
booted host (uptime ~1.5h, load avg < 1.0). Goal: identify the real
flood_1m bottleneck now that single-atomic candidates are exhausted and
structural redesigns (Option 3, idle-queue) have been proved negative.

## Environment

- CPU: Intel Xeon E5-2680 v4 @ 2.40GHz, 14 cores × 2 sockets (28 physical,
  56 logical)
- Governor: `schedutil`
- Perf paranoid: `0`
- Bench binary: `.zig-cache/o/d4fda13a0207d4b4926c662e78481e75/thread-pool-tokio-parity`
  (ReleaseFast, debug info preserved, not stripped)

## `perf stat` — whole-program counters

```text
40,078,977,117  cycles                       (65.74%)
14,086,667,099  instructions    #  0.35 IPC  (83.11%)
   424,383,567  cache-references             (83.72%)
   165,062,981  cache-misses    # 38.89% of all cache refs
    94,713,649  LLC-loads                    (83.80%)
    34,596,741  LLC-load-misses # 36.53% of all LL-cache accesses
     1,088,873  context-switches
        20,104  cpu-migrations

3.009 seconds time elapsed, 15.824 user + 16.431 sys
```

**Headline:** 0.35 IPC with 38.89% L1 miss + 36.53% LLC miss means the
benchmark is fully memory-bound on cross-core coherence traffic, not
CPU-bound. Any optimization that only shaves instruction count is
rearranging deck chairs; structural cacheline-contention reductions are
where the real wins live.

**Side note:** 1.09M context switches for 1M tasks indicates workers are
park/wake oscillating heavily — each task cycle crosses the kernel boundary
roughly once on average. 20K CPU migrations means the kernel is also
bouncing workers across cores faster than the pool can keep L1 cache hot.

## `perf record` — worker-thread hotspots (self + inline stack, DWARF call-graph)

Captured via `perf record -F 997 --call-graph=dwarf`, sample count 127K.
All overhead percentages are share of worker-thread cycles (`spawn`
entryFn) which is 77.32% of total program cycles.

| % | Path | What's actually happening |
|---|---|---|
| 18.91% | `TaskState.cmpxchgStrong` in `runTask` | Phase H queued→running CAS on `TaskDescriptor.state`. One CAS per dispatched task; cacheline is cold in the worker's L1 (descriptor was written by the submitter). |
| 14.23% | `runTask` (residual) | Task body invocation, releaseDescriptor tail, stats updates. |
| **10.75%** | `LocalQueue.len` inside `nextTask`'s steal-loop peek | `src/pool.zig:725` — when local+inject are empty, 55 × 2 acquire loads per scan across all other workers' `bottom`/`top` atomics. **Pure coherence storm.** |
| 9.92% | `nextTask` residual | Dispatch-loop infrastructure. |
| 3.90% | RingQueue atomic store in `LocalQueue.popBottom` | Owner's own deque pop. |
| 3.53% | `LocalQueue.popBottom` residual | |
| 1.78% | `atomic.Value(u32).swap` | LIFO slot swap-to-empty at top of `nextTask`. |
| 1.74% | `fetchAdd(u64)` under LatencyHistogram.observe + runTask | Per-task stats updates; `timestamp_mode = .full` (default). |
| 1.54% | `fetchSub(u64)` in `releaseDescriptor` | `active_tasks` decrement. |
| 1.47% | `cmpxchgWeak(u64)` in `releaseDescriptor` | Free-stack push. |
| 1.34% | `BoundedRing.pop` inject_queue | Head-advance path. |
| 1.11% | `cmpxchgWeak(usize)` in BoundedRing.pop | Inject-queue head CAS. |
| 1.07% | Various u64 loads (mostly `releaseDescriptor`) | |
| 0.85% | u32 atomic loads (RingQueue.pop) | |
| 0.80% | PoolState load in `shouldExit` | |

## Top three targets (ranked by likely payoff)

### 1. `LocalQueue.len` steal-loop peek — 10.75% of worker cycles

`nextTask` at `src/pool.zig:713-746`, when local+inject are empty, loops
over all other workers doing `self.local_queues[victim_index].len() == 0`
as a cheap peek. Each `len()` is 2 acquire loads on the victim's
`bottom`/`top` — cachelines that are written by the owner worker on every
push/pop. So when work is scarce (the tail of flood_1m, or steady-state
contended), 56 workers each pound on the other 55 workers' hot atomics.

Candidate mitigations (need their own brainstorm + same-session A/B at
default Config):

- **Parked-worker bitmap skip.** Before scanning, consult a sharded atomic
  bitmap of "workers with definitely-empty deques" and skip them. Trick:
  bitmap update must be cheaper than the steal-scan saves. Prior attempts
  (Phase G1 sharded wake, Phase F1b hot spinners) regressed — any re-try
  needs to learn from those failures, particularly around the per-push
  bitmap write cost.
- **Age-limited steal attempts.** Don't rescan 55 victims every iteration;
  track "last-seen-empty" time per victim and skip recently-empty ones for
  N microseconds.
- **Direct `steal()` without peek.** `steal()` returns 0 cheaply on empty
  queues if implemented right — but the current `RingQueue.steal` / Chase-
  Lev `steal` CAS-on-top, which may be expensive under contention. Needs
  measurement.

### 2. `TaskState.cmpxchgStrong` — 18.91% of worker cycles

This is the Phase H race fix. The CAS is on a cacheline that's cold in the
worker's L1 (submitter just wrote it). The CAS itself then requires
exclusive ownership of the line — so the cost is really "cold-line
read-for-ownership + CAS." 1M tasks × 56 workers means every descriptor
line crosses cores roughly 2× during its lifecycle (submitter → worker on
dispatch, worker → system on release).

Candidate mitigations:

- **Batch the state transition.** If nextTask pops N descriptors at once
  from inject_queue (we have `inject_batch_size` config already), do one
  batched CAS on a segment of state bytes rather than N individual CASes.
  Requires state packing or SIMD; non-trivial.
- **Skip the CAS when provenance is proven.** If the descriptor came off
  our OWN local_queue (i.e., we pushed it during inject batch-move), no
  other worker could be racing on its state — a non-atomic store of
  `.running` is safe. This would cover the "batched inject drain" path,
  which per the profile is hot.
- **Inline the state into the queue slot.** Instead of
  `queue<index> → descriptor<index>.state`, pack state directly into the
  queue slot. Each pop already does a CAS on the slot sequence; piggyback
  the state transition. Fundamental restructuring — full brainstorm
  required.

### 3. Sentinel dispatch — evaluated and ruled out

Hypothesis going in: flipping `claim_sentinel_enabled = true` to
`std.debug.runtime_safety` would drop one CAS per dispatch (the `claimed_by`
i32 CAS) and recover ~5-10% of the 18.9% state-CAS hotspot.

Measured via n=10 balanced-order paired A/B (`7ef4ae9` vs candidate):

| Scenario | PREV (sentinel on) | POST (sentinel=runtime_safety) | Δ median |
|----------|-------------------:|-------------------------------:|---------:|
| flood_1m | 383,083 | 384,674 | +0.4% |
| contended_spawn_8x | 578,690 | 567,636 | −1.9% |

Both deltas are within noise (distributions overlap heavily). The sentinel
revert is **perf-neutral, not a perf win**. The 18.9% state-CAS hotspot in
the profile is purely the `TaskState` CAS, not the `claimed_by` CAS; the
compiler fused or co-located them on the same cacheline such that the
second CAS was essentially free.

The sentinel revert is still a worthwhile cleanup — it closes the Phase H
TODO, removes ~6 lines from pool.zig, and keeps the race detector active
in Debug / ReleaseSafe (where the 20× stress gate runs with
`claim_sentinel_enabled = true` always). But it does NOT meaningfully move
the Tokio-parity needle.

## Host conditions during measurement

- Uptime: ~1.5h at start of profile; ~2h at end of sentinel A/B
- Load avg: 0.44 → 1.42 (load rose during back-to-back bench runs; all
  measurements were paired so the rise affects both variants equally)
- No co-tenants
- 20× ReleaseFast stress gate on post-sentinel code: 0/20 failures

## What to do next session

1. **Pick one of targets #1 or #2** and build a full brainstorm doc
   following `docs/superpowers/brainstorms/` conventions. Include
   worst-case analysis (predicted regression mechanisms — the Option 3
   brainstorm's worst-case analysis materialized exactly; trust the
   pattern).
2. **Before any code change, A/B-disable the target.** For #1, stub out
   the steal loop entirely and measure the ceiling (bench will deadlock
   since no steals happen — but the submitter-only phase throughput will
   reveal whether steal-scan is even the bottleneck at submitter-feeding
   rates). For #2, stub the CAS to unconditional store and measure.
3. **If both ceilings are small (<5%), stop chasing flood_1m.** The
   current 380-400K ops/s may be the architectural ceiling on this
   machine for this submit model, and further Tokio-parity gains require
   a different benchmark (yield-heavy, spawn-chain) or a different
   submit API (batched submit).
