# Go-gap round 2 — FINAL

Plan: [`docs/superpowers/plans/2026-04-17-go-gap-round2.md`](../../superpowers/plans/2026-04-17-go-gap-round2.md)
Range: `a666ec3` (Phase-0 baseline / Go-gap round 1 FINAL) … HEAD (post-revert)
Date: 2026-04-17
Verdict: **Both attacks FAILED kill gate. Main tree reverted to the Phase-0 baseline behaviour. No code lands from this plan.**

## Headline

Two attacks targeted the three contended/nested scenarios identified in the plan:

| Scenario              | Phase-0 Zig | Go        | Gap at Phase-0 | Gap at HEAD (post-revert) |
|-----------------------|------------:|----------:|:--------------:|:-------------------------:|
| `nested_fanout_4x`    |   1,127,801 | 2,954,402 | 2.62x behind   | 2.62x behind              |
| `contended_spawn_8x`  |   1,141,570 | 3,042,676 | 2.67x behind   | 2.67x behind              |
| `contended_cpu_10us`  |   1,244,836 | 1,783,701 | 1.43x behind   | 1.43x behind              |

Numbers from `benchmarks/results/runtime-comparison-latest.json` at HEAD (code-identical to `a666ec3`). Cross-snapshot drift vs CLAUDE.md's prior snapshot is Go thermal drift (2.57M → 1.78M on `contended_cpu_10us`, 4.14M → 2.95M on `nested_fanout_4x` across a few-hour window on the same host — the documented 30–75% Go variance).

**Nothing moved, because nothing landed.** The plan's two attacks both failed their kill gates and both were reverted. The main-tree code at HEAD equals `a666ec3` byte-for-byte (`git diff a666ec3 HEAD -- src/ tests/ benchmarks/*.zig` is empty).

## Phase-by-phase results

All Zig-side, ReleaseFast, 56 workers, balanced-order same-session paired A/B, n=10 per leg, median-of-10 (mean of 5th and 6th sorted).

### Phase 1 — LIFO-slot rotate (`runqput` / Tokio `LifoSlot` next-g semantics)

Source: [`runs/phase1-ab.md`](runs/phase1-ab.md). A = `a666ec3`, B = `d69af65`.

| Scenario             | A median   | B median   |    Δ%    | Gate     | Pass |
|----------------------|-----------:|-----------:|---------:|:--------:|:----:|
| **nested_fanout_4x** |  1,121,818 |  1,131,088 | **+0.83%** | **≥ +5%** | ❌   |
| contended_spawn_8x   |  1,201,175 |  1,216,882 |   +1.31% | ≥ −3%    | ✅   |
| contended_cpu_10us   |  1,217,134 |  1,182,965 |   −2.81% | ≥ −3%    | ✅   |
| mixed_fast_slow      |    239,392 |    240,289 |   +0.37% | ≥ −3%    | ✅   |
| flood_1m             |    962,011 |    960,220 |   −0.19% | ≥ −3%    | ✅   |
| cpu_work_10us        |  1,034,439 |  1,055,214 |   +2.01% | ≥ −3%    | ✅   |
| cpu_work_100us       |    418,814 |    431,306 |   +2.98% | ≥ −3%    | ✅   |
| burst_drain_burst    |    162,745 |    162,960 |   +0.13% | ≥ −3%    | ✅   |

**Verdict: FAIL on target gate.** `nested_fanout_4x` delivered +0.83% vs +5% required — ~6× below the gate, noise-dominated (A-leg range is ±10% of median). The rotate semantics are behaviourally equivalent to Go/Tokio and did not introduce regressions beyond the near-gate −2.81% on `contended_cpu_10us`, but the plan gates strictly and the win did not materialise.

Reverted at `13387c7` (`revert(pool): lifo_slot rotate — failed kill gate`).

### Phase 2 — Batched `submitBatch` fast path (`tryPushBottomN` / `tryPushN`)

Source: [`runs/phase2-ab.md`](runs/phase2-ab.md). A = `a666ec3`, B = `3b9fa1b`.

| Scenario             | A median   | B median   |    Δ%    | Gate                | Pass |
|----------------------|-----------:|-----------:|---------:|:-------------------:|:----:|
| **nested_fanout_4x** |  1,093,998 |    878,673 | **−19.68%** | **weighted ≥ +5%** | ❌ |
| **contended_spawn_8x** | 1,206,550 | 1,189,721 | **−1.39%**  | **weighted ≥ +5%** | ❌ |
| **contended_cpu_10us** | 1,197,748 | 1,190,498 | **−0.61%**  | **weighted ≥ +5%** | ❌ |
| mixed_fast_slow      |    247,627 |    259,277 |   +4.70% | ≥ −3%              | ✅   |
| flood_1m             |    951,668 |    949,633 |   −0.21% | ≥ −3%              | ✅   |
| cpu_work_10us        |  1,059,753 |  1,041,915 |   −1.68% | ≥ −3%              | ✅   |
| cpu_work_100us       |    459,913 |    453,711 |   −1.35% | ≥ −3%              | ✅   |
| burst_drain_burst    |    163,061 |    162,553 |   −0.31% | ≥ −3%              | ✅   |

**Weighted-avg Δ over targets: −7.23%. Verdict: FAIL decisively.**

The primary target — `nested_fanout_4x`, the scenario the whole batched-push attack was designed to help — regressed 19.68%. B-leg distribution was bimodal (469K–1145K vs A's tight 969K–1215K band), signaling intermittent catastrophic contention under child-wave `submitBatch` rather than steady-state slowdown. Plausible mechanisms (not root-caused; reverted at the kill gate per plan):

1. Rotate-in-`submitBatchWorkerFast` concentrated displaced-entry coherence traffic on `local_queue`'s bottom pointer across 56 concurrent worker-context submits.
2. Partial-push rollback thrashed on local-queue-full, doing 2× work (acquire + init + commit-partial + rollback + re-acquire via slow path).
3. DescCache bulk-take short-took on worker-end caches under contended child waves, internally converting bulk calls to per-entry loops.

Reverted at `fb891a8` (`revert(pool): Phase-2 batched submitBatch fast path — failed kill gate`) as a single squashed revert of all six Task 2.1–2.5 commits.

## What landed

**Nothing in `src/` or `tests/`.** Main-tree code at HEAD is byte-identical to `a666ec3`.

| Phase | Status            | Commits                                                                                                            |
|-------|-------------------|--------------------------------------------------------------------------------------------------------------------|
| 0     | Baseline reference | `a666ec3` (Go-gap round 1 FINAL)                                                                                  |
| 1     | FAILED → reverted  | `e9f2d8e` + `d69af65` (impl) → `13387c7` (revert)                                                                 |
| 2     | FAILED → reverted  | `dfdf9f9`, `d4025f1`, `71e9b9b`, `37c7c00`, `4b16750`, `3b9fa1b` (impl) → `fb891a8` (squashed revert)              |
| 3     | Artifacts landed   | `6540614` (Phase-1 runsheet), `acb715d` (Phase-2 runsheet + 20 JSONs), *this commit* + `CLAUDE.md` refresh + bench |

## What was skipped (and why)

- Neither phase's mechanism was root-caused post-FAIL. The plan's measurement protocol gates strictly on a same-session paired A/B; once the gate is missed, the discipline is to revert and document, not to chase mechanism in a failed tree. Root-causing would also have required instrumentation that the Phase-2 attack didn't need during its design — it's cheaper to attempt a mechanism-specific fix in a new plan than to diagnose in a reverted one.
- The queue primitives themselves (`WorkDeque.tryPushBottomN`, `RingQueue.tryPushN`) are correct and boundary-tested. They could be resurrected for a different attack (e.g., bulk-steal, bulk-cancel) but are reverted here because keeping dead code in-tree confounds future A/B attribution. The plan's design would have had us keep them had Phase-2 only marginally missed; a −19.68% miss on the primary target is strong enough to revert cleanly.

## Why Phase 1 failed (hypothesis, not reproduced)

The rotate semantics gave every worker-context submit the single-atomic-store fast path, but `nextTask`'s existing `swap(LIFO_SLOT_EMPTY, .acquire)` pop-first-from-slot semantics already biased workers to the freshest owned entry in the pre-rotate variant — rotate just changed *which* submits got to use the slot. For `nested_fanout_4x` specifically, the pre-rotate "only-when-empty" path already hit the fast store on the first submit of each child wave, and children 2..N paid the deque-push cost in both variants. The hypothesis that the NEXT-POP cache locality would materially change throughput did not hold at the throughput level — the delta is below the noise floor.

## Why Phase 2 failed (hypothesis, not reproduced)

The batched push primitive is correct and reduces N release-stores to 1 on a clean batch. But the worker-context fast path also rotated the NEWEST entry through `lifo_slot` (inheriting Phase-1's semantics via a different code path) and pushed the displaced prev+older entries via a single `tryPushBottomN`. Under `nested_fanout_4x`'s child-wave pattern where 56 workers simultaneously call `submitBatch(children_per_parent)`, this concentrates coherence traffic on the shared `WorkDeque.bottom` pointer in a way the per-task loop did not — the per-task path serializes the bottom-advance over individual tasks with intervening work, giving the cache coherence protocol time to batch invalidations. The batched version writes all slots unordered then publishes bottom in a single release, which is cheaper per-task on a sequential thread but more expensive on highly concurrent same-deque producers. The bimodal B-leg distribution is consistent with this — under contention, some batches land cleanly and some cascade into mass invalidations.

Whether this is the actual mechanism is unproven. The plan's revert is the correct response regardless.

## Artifacts

- Paired A/B runsheets:
  - [`runs/phase1-ab.md`](runs/phase1-ab.md) — Phase-1 rotate (FAIL)
  - [`runs/phase2-ab.md`](runs/phase2-ab.md) — Phase-2 batched push (FAIL)
- Raw JSON: `runs/phase1-A-{1..10}.json`, `runs/phase1-B-{1..10}.json`, `runs/phase2-A-{1..10}.json`, `runs/phase2-B-{1..10}.json` (40 artifacts total)
- Fresh benchmark sweep at HEAD: `benchmarks/results/{latest,scale-latest,runtime-comparison-latest}.json`
- Orchestrators in `.cache/`: `phase2-ab-loop.sh`, `phase2-aggregate.py` (not checked in — local only)
- Binary SHA256 hashes recorded in each runsheet; Phase-0, Phase-1, Phase-2 binaries all distinct.

## Closed planes confirmed (did not re-attempt)

- **Shared parked-workers bitmap** (iter 7) — already closed.
- **Single-worker notifySubmits scan** (iter 8) — already closed.
- **notifySubmits cacheline-isolation** (iter 9) — already closed.
- **shouldExit off the hotpath** (iter 10) — already closed.
- **Per-worker active_tasks shard** (iter 11) — already closed.
- **Socket-aware worker pinning** (Slice 3a) — already closed.
- **Worker struct mid-reorder or growth** (Worker-size trade-off memory 2026-04-16) — respected: neither phase touched the Worker struct.

## New closed planes from this round

- **`lifo_slot` rotate semantics on worker-context submit (Phase 1)** — behaviourally correct, throughput-neutral in practice. The only-when-empty variant at HEAD is not materially slower than the rotating variant for any of the 8 measured scenarios. Do not revisit unless the measurement methodology changes or a new scenario surfaces that plausibly benefits from next-g pop locality at the throughput level.

- **Batched `submitBatch` fast path via `tryPushBottomN` with worker-context LIFO rotate (Phase 2)** — regresses `nested_fanout_4x` 19.68% with bimodal variance, signaling structural contention under child-wave submitBatch. Do not revisit the rotate-plus-batched-push combination. A batched-push-only variant (no rotate) on the submitter-context path is not individually ruled out but would need a fresh attack surface and hypothesis.

## Next

- The three target scenarios' Go gaps are effectively unchanged from the Go-gap round 1 snapshot. Within this library's API and architectural constraints, further narrowing likely requires a different attack plane than either LIFO rotate or producer-push batching. Two speculative directions, both out of scope here:

  1. **Per-Worker DescCache trade-off revisit**: Go-gap round 1 Phase-3 added a `DescCache` field at end-of-struct, growing `Worker` from 1912B → 2048B and regressing contended submitter-thread scenarios 5–10% vs the Phase-2 checkpoint. A comptime flag to opt the worker-end cache out for multi-submitter workloads could reclaim the Phase-2 ceiling on `contended_spawn_8x` / `contended_cpu_10us` without touching `nested_fanout_4x`.

  2. **Accept 2.2–2.7x as the sustainable gap**: Go's in-runtime per-P local queue, goroutine stack amortisation, and scheduler-integrated network poller are language-runtime features this C-ABI-compatible library cannot match without breaking its design. The 4-of-8 wins vs Go on the non-contended scenarios (`flood_1m`, `cpu_work_10us`, `cpu_work_100us`, `burst_drain_burst`) and the 7-of-8 wins vs Tokio already establish competitive positioning.

- The throughput-plateau pivot memory (`project_throughput_plateau_pivot.md`) remains the reference framing for this trade-off — lane isolation, latency, fairness, and observability remain more productive axes than further micro-optimisation of the worker-context submit path.
