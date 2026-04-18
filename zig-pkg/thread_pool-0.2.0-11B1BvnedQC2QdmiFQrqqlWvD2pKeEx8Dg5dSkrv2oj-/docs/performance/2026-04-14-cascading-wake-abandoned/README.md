# Cascading Wake — Abandoned (Ceiling B negative)

**Date:** 2026-04-14
**Brainstorm:** `docs/superpowers/brainstorms/2026-04-14-cascading-wake.md`
**Gate:** "If B is small or negative, stop here and pivot direction."
**Outcome:** B is **decisively negative for flood_1m_batched**.
Direction abandoned. No code changes land.

## What we measured

Ceiling B as defined in the brainstorm: "static-pinned workers, no
park/unpark." Implemented by stubbing `Core.idle` so it immediately
returns instead of parking on `park_cond`. Workers stay hot in the
work-search loop for the entire benchmark run — exactly the "all 56
workers active from tick zero" steady state that a perfect cascade
would approximate.

The stub was local to a throwaway build; `git diff src/pool.zig` is
clean on the post-measurement tree. Binaries saved to
`/tmp/bench_base` (baseline `main` at `b940d08`) and `/tmp/bench_stub`
(same tree + idle stub).

## Paired n=10 A/B, balanced order (BSSB × 5)

Each round ran `thread-pool-tokio-parity` with order
baseline, stub, stub, baseline — then repeated 5 times. n=10 per
condition per scenario. Host: 56-core machine, load average
`1.95 / 4.00 / 5.00` at run start.

| Scenario | Baseline median | Stub median | Δ | Distribution |
|---|---:|---:|---:|:---|
| flood_1m | 396,529 | 299,220 | **-24.5%** | overlap |
| flood_1m_batched | 893,076 | 495,178 | **-44.6%** | **CLEAN** |
| contended_spawn_8x | 560,214 | 525,271 | -6.2% | overlap |
| contended_spawn_8x_batched | 633,981 | 655,265 | +3.4% | overlap |

flood_1m_batched — our target scenario — has clean distribution
separation: stub max (572K) < baseline min (755K). Every stub run was
strictly slower than every baseline run. This is as decisive as an
n=10 same-session paired A/B gets.

Raw data: `ceilB_raw.txt` in this directory.

## Why this closes the direction

Cascading wake's best-case output is "workers ramp from parked to
active until active-count matches submitter rate, with per-worker
activation staggered by one task-dispatch." Its theoretical ceiling
is the all-active state — which is precisely what Ceiling B puts the
system in, with zero scheduling overhead.

If the all-active state performs worse than the current wake-one
state on flood_1m_batched by a factor of ~1.8, no wake-scheduling
mechanism can extract a win: the cascade has nowhere to cascade
toward. The `inject_queue` head cacheline is the bottleneck, not the
park/unpark cost. More workers hammering head CAS costs more than the
parallelism they add.

This also retroactively explains the wake-count sweep result from the
batched-submit brainstorm (`docs/performance/2026-04-14-batched-submit/
README.md`): wake=1 was optimal because waking more workers pulled
them directly onto the contended head cacheline. Same mechanism,
different trigger path.

## Sibling implication: contended_spawn_8x_batched is NOT head-bound

The all-active stub was +3.4% (overlapping) on contended batched,
meaning more workers is neutral there. The 8-submitter contended
scenario distributes inject pushes across submitters and submitter
local push patterns differently; head-CAS contention is not the
dominant cost. Implication for future work: contended_spawn_8x's
ceiling is not congruent with flood_1m_batched's and needs its own
profile.

## Where to look next (not in this audit — options only)

Given head-CAS on `inject_queue` is the bound:

1. **Sharded inject.** N independent Vyukov rings; submitters hash to
   one; workers round-robin pop across shards. Cuts head-CAS
   contention roughly N-fold at the cost of tail coordination.
   Non-trivial design; previous `option3-worker-local-incoming`
   attempt was abandoned (-48% flood_1m regression), so the shape
   matters a lot.
2. **Lockfree linked-list inject** (MSQueue-style). Replaces per-slot
   sequence numbers with next-pointer enqueue/dequeue. Different
   contention profile — may or may not be better.
3. **Accept current ceiling and pivot.** Move to yield-heavy or
   chained-spawn Tokio parity scenarios (not yet implemented here),
   or to observability / API features.

Each of those requires its own brainstorm + ceiling measurement
before any code lands. This audit just closes cascading wake.

## Files touched

- `docs/superpowers/brainstorms/2026-04-14-cascading-wake.md` —
  status updated to ABANDONED with Ceiling B result inline
- `docs/performance/2026-04-14-cascading-wake-abandoned/README.md` —
  this file
- `docs/performance/2026-04-14-cascading-wake-abandoned/ceilB_raw.txt` —
  raw n=10 paired bench output
