# Batched Submit API — Brainstorm

> **Status:** implemented and measured. See `docs/performance/2026-04-14-batched-submit/README.md` for the paired A/B (flood_1m_batched +130% median, no distribution overlap) and the wake-one design decision that diverged from this brainstorm's wake-count assumption. Spawned from `docs/performance/2026-04-14-ceiling-stubs/README.md` which closed the flood_1m single-task optimization track (top 2 hotspots both cleared <5% ceiling) and recommended a batched-submit API as one of three productive alternative directions.

## What currently exists

`BatchTask` struct is defined (`src/pool.zig:36`) and `submitBatch` is exposed at both `Core` and `ThreadPool` levels (`src/pool.zig:351`, `src/pool.zig:1142`). **The current implementation is a naive loop over `self.submit(...)` — no amortization.** Each iteration pays the full per-submit atomic cost, which per the post-revert profile and the parent audit includes:

1. `inject_queue.tryPush` — one `tail.cmpxchgWeak` RMW + slot `sequence.store(.release)`.
2. `counters.submitted.fetchAdd(1, .monotonic)` — cheap on x86 (lock xadd), but still a cacheline bounce.
3. `incrementQueued` — `queued_tasks.fetchAdd(1, .seq_cst)`, the **park/wake mfence** and the most expensive per-submit atomic by far.
4. Wake-scan: acquire-loads on `is_parked` across up to N workers; on hit, takes `park_mutex` + signals `park_cond`.

Item 3 (`seq_cst`) is the single biggest submitter-side cost. Items 1+2 are individually cheap but pay cacheline transit.

## What batching wants to amortize

For a real batch of size `K`:

| Atomic | Current cost | Batched cost | Savings |
|---|---|---|---|
| inject_queue tail CAS | K × cmpxchgWeak | **1 × `tail.fetchAdd(K)`** reserving all K slots + K slot stores | ~(K-1) cross-core CAS |
| counters.submitted | K × fetchAdd(1) | 1 × fetchAdd(K) | (K-1) monotonic RMW |
| incrementQueued | K × fetchAdd(1, seq_cst) | 1 × fetchAdd(K, seq_cst) | **(K-1) seq_cst fences** |
| Wake scan | K × full-pool scan | 1 × scan waking ≤ min(K, parked) workers | (K-1) O(N) scans |
| Wake signal | K × mutex lock+signal+unlock | ≤ min(K, parked) × same | (K-1) mutex operations on same parked workers |

At K=16, total per-submit amortized atomic cost drops by ~93% on the submitter side.

## Will this actually speed up flood_1m?

**Open question — must be verified with a ceiling A/B before committing to implementation.** The post-revert profile showed:

- Worker cycles account for 77.32% of program time; submitter is only ~22%.
- Of submitter time, the `queued_tasks.fetchAdd(seq_cst)` is the dominant per-submit cost.
- The benchmark is memory-bound (0.35 IPC). Freeing submitter CPU cycles may or may not translate to throughput if the workers become the bottleneck.

**Hypothesis:** with batching the submitter can stay farther ahead of the workers, reducing worker park events (currently 1.09M context switches for 1M tasks → ~1 park/wake per task). Fewer park cycles → less coherence storm on `is_parked` + `queued_tasks` → potentially material throughput gain.

**Counter-hypothesis:** the benchmark is already submitter-starved-of-CPU on a single-core. Batching doesn't make the submitter run faster per-task; it just amortizes shared state. If the real bottleneck is work dispatch through inject_queue to workers (the pop side) or the worker state CAS itself, batching the submit side alone won't help.

## Ceiling A/B design (gate before implementation)

Stub `submitInternal` to skip the expensive atomics and measure the ceiling:

- Skip `counters.submitted.fetchAdd` (stats won't tally).
- Skip `incrementQueued` (park/wake will mis-behave — use a helper bench flag to suppress parking entirely for the A/B, or keep incrementQueued but move it out of the per-submit loop).
- Still push to `inject_queue` so workers can actually run tasks.

If that stub's flood_1m median exceeds baseline by ≥10% with decisive distribution separation, the batched API is worth building (real batching will capture a fraction of this). If <5%, the atomics aren't the real submitter bottleneck and we should rethink.

## Implementation-level design questions

1. **API shape.** Current: `submitBatch(tasks: []const BatchTask, options: SubmitOptions) !SubmitBatchResult`. Keep it. One `SubmitOptions` applies to all tasks in the batch — no per-task overrides on the first cut. If callers need per-task options, they call the single `submit` loop.

2. **Descriptor acquisition.** The free-stack uses `cmpxchgWeak(u64)` per `acquireDescriptor`. Batched version wants to reserve K descriptors in one call. Option A: loop K times (no free-stack amortization). Option B: claim a segment of the free-stack in one CAS via a `next` chain walk. Option B is complex; Option A is fine for the first cut because the free-stack hit-rate under steady-state is high (one CAS per claim is cheap and uncontended).

3. **inject_queue batch push.** Current `BoundedRing.tryPush` (`src/queue/bounded_ring.zig:44`) has a `tail.cmpxchgWeak` per item. A real batch push needs one of:
   - **`tail.fetchAdd(K)`** reserving K slots in one RMW, then checking each slot's sequence. On any slot being occupied, we have to "un-reserve" — Vyukov doesn't support that cleanly. Tricky.
   - **Fast-path: single producer assumption.** If we know the caller is the only producer (external submitter thread in flood_1m), a simpler path works: load tail, check K slots, single tail store at end. Not safe under multi-producer.
   - **Compromise:** do one CAS on tail to `tail+K`, treating the full reservation atomically; on success write all K slots' values and sequence.release (each slot independently). If the slots happen to be occupied (queue is full partway through the batch), the push is committed only for non-occupied slots and we return partial success. This requires careful analysis — maybe skip in first cut.
   - **First-cut:** loop `tryPush` K times inside `submitBatch`, but DO batch the counter updates + wake scan. Measures the seq_cst/wake savings in isolation from the ring CAS savings. If this moves the needle, the ring CAS is the next target.

4. **Wake-scan amortization.** After K pushes, scan for min(K, parked) parked workers and signal each. Simplest implementation: scan until K signals delivered or scan completes. Keep existing "cheap check without mutex" pattern — no mutex work for running workers.

5. **Backpressure.** Current `submitInternal` has a blocking path for `options.backpressure == .block_with_timeout`. Batched version is harder: if the queue is full on item 3 of 16, do we block until 3..16 fit, or return partial? **First cut: `submitBatch` returns `.{ .submitted = n }` immediately if any push fails; caller decides whether to retry.** No blocking; matches current API semantics ("block until partial completion" has no clean batch meaning).

6. **WaitGroup semantics.** If `options.wait_group` is set, the batched version must call `wait_group.add(K)` once (not K times). That's a batch-friendly atomic already.

7. **Bench variant.** Add `benchFloodBatched` to `bench_tokio_parity.zig` with batch size 16 or 32 (match `inject_batch_size` default). Output line: `scenario=flood_1m_batched`. Keep original `flood_1m` untouched for direct comparison.

## Risks

1. **Worker pop side bottleneck revealed.** If submitter batching removes its bottleneck, the next constraint is worker pop + runTask CAS. That's exactly target #2 from the profile, which we just ruled out at <2% ceiling. Could become **the new** bottleneck but still be far below Tokio-parity.

2. **Capacity pressure.** Batching makes transient queue saturation more likely (16 tasks arrive at once vs 1). inject_queue `queue_capacity = 4096` (default) is fine for K=16-64, but if callers batch K=1024 the fail-partial path matters.

3. **Correctness: seq_cst ordering.** `queued_tasks.fetchAdd(K, .seq_cst)` must happen AFTER all K inject pushes are visible, so workers reloading `queued_tasks` can't see the counter bump before the tasks. Current `submitInternal` does push-before-increment already; batched version preserves this by doing all pushes first, then one increment.

4. **Partial-batch rollback.** If push 5/16 fails, pushes 0-4 are already visible to workers. That's fine — they execute normally. The return `.{ .submitted = 5 }` tells the caller only 5 succeeded; items 5..16 are the caller's responsibility to retry. Matches the current stub semantics.

## Proposed next step after brainstorm

Ceiling A/B first (gate). Stub the per-task atomic overhead and measure flood_1m. If ≥10% decisive gain, proceed with first-cut implementation (loop `tryPush`, batch counters + wake). Else, reconsider direction.

Open questions above become implementation-phase decisions — this brainstorm does not claim to answer them, only to surface them.
