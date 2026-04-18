# Cascading Wake — Brainstorm (ABANDONED)

> **Status:** ABANDONED after Ceiling B decisively negative. See
> `docs/performance/2026-04-14-cascading-wake-abandoned/README.md`
> for the full n=10 balanced-order paired A/B. Short version:
> stubbing `idle()` to spin instead of park (so all 56 workers stay
> active throughout the bench) regressed flood_1m_batched by 44.6%
> (893K → 495K median, clean distribution separation — stub max
> 572K < baseline min 755K). Per this doc's own
> pre-registered gate ("If B is small or negative, stop here and pivot
> direction"), cascading wake cannot help — it would drive the system
> toward the same all-active worker state that Ceiling B just measured
> as worse. The fundamental bottleneck is head-CAS contention on
> `inject_queue` when multiple workers race to pop; cascading wake
> would produce that same contention with extra scheduling overhead.
> Leaving the rest of this doc intact as design rationale for the gate
> decision and as a reference if we later investigate queue-side
> changes (sharded inject, per-worker incoming) that attack the
> head-CAS bottleneck directly.
>
> Spawned from follow-up on
> `docs/performance/2026-04-14-batched-submit/README.md` after paired
> A/B sweeps (wake-count 1..16, inject_batch_size 32..256) confirmed
> wake-one is optimal for the current design and we've exhausted
> single-knob tuning. Current ceiling is ~900K-1M ops/s on
> flood_1m_batched with only ~20/56 CPUs active.

## Current wake design

`Core.notifySubmits(count)` (src/pool.zig:687) wakes exactly one
parked worker per call. Workers do not wake peers. The submit path is
the **only** wake source.

Consequence for flood_1m_batched (batch=64, 15625 batches):

- Each batch wakes 1 worker. Worker drains up to 32 inject items via
  the nextTask batch-drain, runs them, may park again if local+inject
  empty.
- Active worker count is bounded by how quickly batches arrive relative
  to per-task runtime. Measured: ~20/56 CPUs active.
- perf stat shows IPC 0.09 and 36% cache-miss rate — memory-bound on
  inject_queue head cacheline coherence with ~20 workers racing CAS.

## What Tokio does: "searching" cascade

Tokio's multi-threaded runtime
(`tokio-rs/tokio/src/runtime/scheduler/multi_thread/worker.rs`) has a
`num_searching` atomic counter plus a `searching` per-worker flag.
Flow:

1. Submitter pushes to inject + wakes at most 1 parked worker (same
   as us today, via `notify_one`).
2. A worker coming out of park enters **searching** state
   (`num_searching += 1`). It searches inject, then rotates through
   steal targets.
3. When it finds a task and transitions to **running**, it
   decrements `num_searching`. **If it was the last searcher**
   (pre-decrement == 1), it wakes another parked worker (which
   enters searching). This is the "torch hand-off".
4. Running worker finishes task, goes back to searching if local has
   work, or idles if fully drained.
5. Cap: Tokio also caps `num_searching <= num_workers/2` via the
   notify-parked path to prevent all workers from searching at once.

Net effect: submitter's 1 wake propagates through the pool as workers
find-and-hand-off. Coverage grows organically without thundering
herd.

## Why it might help our flood_1m_batched

**Hypothesis:** workers currently park between batches. A batch's
first wake gets the one worker that's round-robin-next. That worker
drains up to 32 from inject, runs them in ~32 × Y ns. If the next
submit batch arrives during that window, submitter wakes worker B.
But worker A is still draining — so only A is popping inject during
that window. No parallelism on the pop side.

With cascading wake: when A pops its first task and starts running
it, A wakes B. B enters searching, pops the NEXT 32 from inject.
Now A and B are draining in parallel. B can wake C. Etc.

With 64-task batches arriving every ~70 µs (15625 batches / 1.07 s)
and workers able to wake a peer on task-dispatch, we'd ramp up active
worker count until the submitter's rate is matched.

**Predicted ceiling:** if IPC holds and we scale from 20 → 40 active
workers, throughput could scale to ~1.8M ops/s. If IPC degrades
(more head-CAS contention), scaling is sub-linear.

## Counter-hypothesis (must be taken seriously)

We already measured wake-count=4 per batch regressed flood_1m_batched
877K → 780K (n=5 sweep in this session). More simultaneous workers on
inject_queue head == more head-CAS contention == lower throughput.
Cascading wake would produce the SAME outcome if the cascade happens
faster than workers can drain their share.

The fundamental question: **does cascading wake produce a
qualitatively different worker arrival pattern than wake-many?**

Possibly yes:

1. Wake-many (what we tested): all N workers wake simultaneously.
   They all start in nextTask, all hit inject_queue.pop at the same
   instant. Head CAS is hammered N-ways.
2. Cascading (theoretical): worker A wakes, pops from inject into
   local, starts running. At the point where A runs its first task
   body, A wakes B. B starts draining inject → its local. B's drain
   is staggered from A's by ~one task-runtime. Head CAS is hammered
   at rate proportional to task-dispatch rate, not wake-rate.

The staggering is the key — if it exists, cascading wake avoids the
thundering-herd. If the stagger is too small (runTask is
nanoseconds), the cascade collapses to wake-many in practice.

Noop runTask is ~hundreds of ns worst case. 56 cores × 56 wakes ×
hundreds of ns = plenty of stagger for each wake to meaningfully
decouple from its predecessor.

## Ceiling A/B design (gate before implementation)

**Two separate measurements** to bound the win:

### Ceiling A: unconditional wake-all on batch start

Modify `notifySubmits` to wake **every** parked worker (K wakes per
batch). Measure flood_1m_batched. This is the wake-storm ceiling — an
upper bound on "what if all workers were active from batch 0".

We already have n=5 data from the wake sweep that suggests this is
NEGATIVE (wake=4 was worse than wake=1). A targeted n=10 wake-all
A/B confirms: if the ceiling is negative, cascading wake cannot save
us because even if the cascade mechanism is perfect, having all
workers active is bad.

### Ceiling B: static-pinned workers (no park/unpark)

Modify worker `idle()` to spin instead of park. All 56 workers stay
active throughout the bench. Measure flood_1m_batched. This removes
the park/unpark overhead entirely and tests pure "all-workers-active
throughput."

If A is negative and B is positive: the bottleneck is "workers active
but racing on inject_queue head". Cascading wake won't solve this —
the solution is a better queue (sharded inject, or per-worker
incoming).

If A is negative and B is negative too: there's no headroom at
all-active worker count. Cascading wake is pointless. Accept current
ceiling.

If A is positive: wake-more is simply better. Increase WAKE_COUNT_CAP
or implement cascade.

## Implementation-level design questions (if ceiling justifies)

1. **Searching-state representation.** Atomic `num_searching: u32` on
   Core + per-worker `searching: bool`. Tokio uses relaxed-ordering
   RMW; the handoff is protected by the park_mutex.

2. **Torch hand-off site.** Worker dispatches a task → BEFORE calling
   the task body, if `searching` was true, transition to running:
   `num_searching.fetchSub(1, .acq_rel)`. If the pre-decrement value
   was 1, wake one peer (inline the notifySubmits wake scan).

3. **Search cap.** Tokio: `num_searching <= num_workers/2`. Enforced
   in the wake path (don't wake if the cap is already reached). Same
   rule here — if cap hit, wake is a no-op.

4. **Park path cleanup.** Worker entering park: if it was searching,
   decrement `num_searching`. Worker leaving park (found work): set
   `searching=false` + decrement after task-find.

5. **Correctness under shutdown.** Shutdown already broadcasts
   park_cond. The new searching counter doesn't interact with
   shutdown — OK.

6. **WaitGroup interaction.** None — searching is purely a scheduler
   concern, not affecting task lifecycle.

## Risks

1. **Cascade collapse.** If runTask is too short to stagger the
   wakes, the cascade degenerates to wake-many and we regress. Noop
   tasks are the worst case (shortest runtime). If ceiling A is
   clearly negative, we likely have this problem.

2. **Search cap tuning.** Too low → workers park too often. Too
   high → too much steal-loop contention when pool is mostly idle.
   Tokio's `num_workers/2` is a well-tested heuristic but our
   workload may differ.

3. **Added per-task atomic.** The `num_searching.fetchSub` adds one
   RMW per dispatched task. On a 0.09 IPC hot loop, this may cost
   more than the parallelism saves. Needs measurement.

4. **Interaction with descriptor lifecycle.** None expected — searching
   is independent of descriptor state CAS. But watch for coincidental
   cacheline collisions with other atomics on Core.

## Proposed next step

Run ceiling B (static-pinned workers, no park) **first** because it's
the strictly larger ceiling — it bounds what any wake strategy can
hope to achieve. If B is ≥ +15% on flood_1m_batched with clean
distribution separation, ceiling A becomes worth running and cascade
design becomes worth building. If B is small or negative, stop here
and pivot direction.

If B looks promising but A is negative, the answer isn't cascade —
it's a different queue design (sharded inject, lockfree list) that
doesn't have the all-workers-on-one-cacheline problem.

Open questions above become implementation-phase decisions — this
brainstorm does not claim to answer them, only to gate the whole
direction on the B-then-A ceiling measurement.

## Ceiling B result — gate closed (2026-04-14)

Ran Ceiling B by stubbing `Core.idle()` to skip the park path
entirely (workers call `spinLoopHint` + a shutdown check, then return
to the work-search loop). All 56 workers stay active throughout the
bench. Full ReleaseFast, n=10 balanced-order paired A/B vs baseline.

| Scenario | Baseline median | Ceiling B median | Δ | Distribution |
|---|---:|---:|---:|:---|
| flood_1m | 396,529 | 299,220 | **-24.5%** | overlap |
| flood_1m_batched | 893,076 | 495,178 | **-44.6%** | **CLEAN** |
| contended_spawn_8x | 560,214 | 525,271 | -6.2% | overlap |
| contended_spawn_8x_batched | 633,981 | 655,265 | +3.4% | overlap |

flood_1m_batched — our target scenario — regresses by 44.6% with
**clean distribution separation** (every stub run strictly slower
than every baseline run). More workers racing on `inject_queue` head
CAS costs far more than the parallelism they provide.

Cascading wake's best-case is "workers wake in staggered succession
until active-count matches submitter rate." But Ceiling B shows that
*even if the cascade mechanism were perfect and free*, the resulting
all-active worker state is worse than the current wake-one state. The
direction is ruled out.

Per the pre-registered gate on line 188 ("If B is small or negative,
stop here and pivot direction"): **stop, pivot**. Head-CAS on
inject_queue is the real bottleneck, and it requires a queue-side
redesign (sharded inject, per-worker incoming), not a wake-side
change. See `docs/performance/2026-04-14-cascading-wake-abandoned/`
for the full n=5 data and raw runs.
