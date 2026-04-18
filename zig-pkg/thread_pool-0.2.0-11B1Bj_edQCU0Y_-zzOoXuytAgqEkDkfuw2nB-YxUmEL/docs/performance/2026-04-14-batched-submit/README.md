# 2026-04-14 — Batched submit API

Follow-up to `docs/performance/2026-04-14-ceiling-stubs/README.md` (which
closed the flood_1m single-submitter optimization track) and
`docs/superpowers/brainstorms/2026-04-14-batched-submit.md` (brainstorm
that proposed this direction).

**Headline result:** batched submit lifts flood_1m throughput **+130%
median (2.3×)** with zero distribution overlap against baseline, while
leaving unbatched paths unchanged (neutral). 20× ReleaseFast stress gate
passes.

## Environment

- Host: 2× Xeon E5-2680 v4, 56 logical cores, schedutil, paranoid=0
- Binary: ReleaseFast, debug info preserved
- Method: paired same-session balanced-order (bin alternation per-iter), n=10
- Baseline tag: `faa0b14` (post ceiling-stubs audit). Treatment: HEAD of
  this branch with `submitBatch` rewrite + `flood_1m_batched` bench
  variant.

## What changed

1. `Core.submitBatch` rewritten from a naive `self.submit()` loop into
   a batched path that amortizes the three submitter-side atomics:
   - `counters.submitted.fetchAdd(count, .monotonic)` — 1 op per batch
     instead of K.
   - `counters.queued_tasks.fetchAdd(count, .seq_cst)` — **1 seq_cst
     fence per batch instead of K**. This was the dominant per-submit
     cost (the submit-before-park handshake mfence).
   - Parked-worker wake-scan — 1 wake attempt per batch instead of K.

2. `enqueueTask` refactored into `enqueuePush` + `notifySubmits(1)`.
   `enqueuePush` is the pure push path (descriptor acquire, field fill,
   LIFO/local/inject-queue push). `notifySubmits(count)` is the batched
   atomic/wake tail. The unbatched submit path is a one-liner that
   calls both — so the refactor does not change its atomic profile.

3. `submitBatch` retains per-task `tryPush` and `acquireDescriptor`
   (both are CAS-per-task). The brainstorm's Option B (segment-claim
   descriptor reservation) and multi-slot inject push are deferred —
   the counters+wake amortization alone captures the ceiling.

4. New bench scenario `flood_1m_batched` in `bench_tokio_parity.zig`
   with batch size 64, sharing the rest of flood_1m's setup.

## Key design decision: wake-one per batch, not wake-count

The first-cut implementation woke up to `count` parked workers per
batch, matching the intuition that K pushed tasks justify K wakes.
**Measured flood_1m_batched at ~360K ops/sec — a regression vs 390K
baseline flood_1m.** A wake-storm hypothesis: all parked workers woken
at once contend on `inject_queue` head CAS, causing cacheline bouncing
worse than the atomic costs saved by batching the counters.

Changing the wake policy to wake-one (matching the single-submit path)
lifted flood_1m_batched to ~900K ops/sec. Conclusion preserved in the
`notifySubmits` doc comment.

**Consequence for long-task workloads:** a batch of long-running tasks
with all workers parked will only wake 1 worker, and cascading wakes
happen only on subsequent batches (workers don't wake peers). For
flood_1m and reasonable steady-state loads this is fine; heavier-task
benchmarks should be measured separately before tuning. If found to
underperform, the fix is probably a cascading wake in `runTask` rather
than a larger wake-count here.

## Results — paired n=10 balanced-order

| Scenario | BASE median | TRT median | Δ | Distribution overlap? |
|----------|------------:|-----------:|---:|:---|
| flood_1m (unbatched) | 389,486 | 420,078 | **+7.9%** | Yes — heavy (BASE 357K..477K, TRT 385K..485K) |
| flood_1m_batched | — | **897,998** | vs TRT unbatched: **+114%**<br>vs BASE flood_1m: **+130%** | **No overlap** — batched min 689K > TRT unbatched max 485K |
| contended_spawn_8x | 586,514 | 589,982 | +0.6% | Yes — heavy (noise) |

Full distributions (ops_per_sec):

```text
flood_1m BASE:    min=357238 median=389486 max=476668 mean=392220 n=10
flood_1m TRT:     min=384508 median=420078 max=484869 mean=426153 n=10
flood_1m_batched: min=689429 median=897998 max=949133 mean=874453 n=10
cont BASE:        min=467612 median=586514 max=631204 mean=566727 n=10
cont TRT:         min=508574 median=589982 max=596929 mean=578425 n=10
```

flood_1m unbatched shifts up +7.9% median on TRT vs BASE — heavy
distribution overlap means this is noise-consistent, not a measured
gain. The refactor is neutral-to-slightly-positive on the unbatched
path. contended_spawn_8x is flat.

## Stress gate

20× `zig build test-stress -Doptimize=ReleaseFast`, all 20 runs exit=0.

## How this compares to the ceiling A/B

The 2026-04-14 ceiling brainstorm estimated an atomic-skip stub would
yield ~30% on flood_1m. The actual batched implementation delivers
**+130% median on the new flood_1m_batched scenario** — far exceeding
the projected ceiling, because:

1. The ceiling measured a purely synthetic stub (atomics skipped but
   otherwise per-task CAS-heavy submit). Real batching eliminates
   `(K-1)` seq_cst fences per batch, plus `(K-1)` wake-scan iterations
   per batch — a bigger effect than the ceiling isolation captured.
2. The batched submitter can stay further ahead of workers, reducing
   how often workers park + how much `is_parked` coherence churn
   happens. This feedback effect wasn't visible in the static ceiling
   measurement.

The unbatched `flood_1m` number is unchanged within noise — consistent
with the ceiling-stubs audit's conclusion that the single-submitter
path has a ~400K architectural ceiling on this host.

## Follow-ups worth considering (not done here)

1. Measure batched submit under heavier per-task work to confirm the
   wake-one policy doesn't leave workers parked unnecessarily. If
   underperforming, add a cascading wake in `runTask`.
2. Multi-producer batched variant — contended_spawn_8x-style with
   each submitter batching their own work. The current contended
   bench uses the single `submit` path.
3. Batched inject push (one `tail.fetchAdd(K)` instead of K CAS) —
   the brainstorm's Option B. Only worth pursuing if a profile of
   flood_1m_batched shows `inject_queue.tryPush` as the new top
   hotspot.
