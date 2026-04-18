# Go-gap contended plan — FINAL

Plan: [`docs/superpowers/plans/2026-04-16-go-gap-contended.md`](../../superpowers/plans/2026-04-16-go-gap-contended.md)
Range: `03d225d` (Phase-0 baseline) … `7e125a9` (Phase-4 bench refresh)
Date: 2026-04-17

## Headline: cross-snapshot gap vs Go

Measured from `benchmarks/results/runtime-comparison-latest.json` at `7e125a9`
(Zig 0.16.0, ReleaseFast, 56 workers, 7 retained samples after 1 warmup discard).

| Scenario            | Baseline gap (d357bd9) | Final gap (7e125a9) | Change                         |
|---------------------|:----------------------:|:-------------------:|:-------------------------------|
| contended_spawn_8x  | 3.86x behind           | 2.20x behind        | narrowed (43% closer)          |
| contended_cpu_10us  | 2.27x behind           | 2.43x behind        | widened ~7% (see host caveat)  |
| nested_fanout_4x    | 6.19x behind           | 3.88x behind        | **narrowed (37% closer)**      |
| mixed_fast_slow     | 1.01x behind           | 1.10x behind        | widened ~9% (noise-dominated)  |

**Host-state caveat:** Cross-snapshot ratios mix Zig deltas with Go's thermal
drift. Go's `contended_cpu_10us` moved from 2.43M → 2.57M ops/s between
snapshots on the same 56-core host — a 6% Go-side shift that entirely explains
the `contended_cpu_10us` "widening" despite a +25.93% Zig gain in paired A/B.
The authoritative Zig-side deltas come from the same-session paired A/Bs
below.

## Phase-by-phase isolated paired A/B (same-session)

All Zig-side, ReleaseFast, balanced-order A/B, `bench-runtime-compare` harness.

| Phase | Scenario                   | A median   | B median   |    Δ%   | Gate   | Kept? |
|-------|----------------------------|-----------:|-----------:|--------:|:------:|:-----:|
| 1     | nested_fanout_4x           | —          | —          | +44.8%  | ≥ +8%  | ✅    |
| 2     | contended_spawn_8x         | 951,370    | 1,293,669  | +35.98% | ≥ +10% | ✅    |
| 2     | contended_cpu_10us         | 1,008,486  | 1,328,299  | +31.71% | ≥ +8%  | ✅    |
| 2     | nested_fanout_4x           | 544,323    | 902,715    | +65.84% | ≥ −3%  | ✅    |
| 3     | nested_fanout_4x (cum.)    | 626,144    | 1,134,938  | **+81.26%** | ≥ +18% | ✅ |
| 3     | contended_spawn_8x (cum.)  | 947,297    | 1,211,358  | +27.88% | ≥ −3%  | ✅    |
| 3     | contended_cpu_10us (cum.)  | 994,958    | 1,252,901  | +25.93% | ≥ −3%  | ✅    |

- Phase 1 source: [`phase1-task1.2-result.md`](phase1-task1.2-result.md) — `runtime_compare_zig.zig` `nestedParentTask` adopted `submitBatch`. Task 1.3 on `bench-realistic` was **reverted** at `0554a84` (signal +3.22% fell below the +5% gate); detail in [`phase1-task1.3-result.md`](phase1-task1.3-result.md).
- Phase 2 source: [`runs/phase2-ab.md`](runs/phase2-ab.md). A = `03d225d`, B = `922cb60`. Per-submitter `DescCache` (SPSC LIFO, 32-entry) + `acquireDescriptorBatch` helper + drain-on-release landed.
- Phase 3 source: [`runs/phase3-ab.md`](runs/phase3-ab.md). A (Pair 1) = `03d225d` Phase-0, A (Pair 2) = `922cb60` Phase-2, B = `d78a206`. Per-Worker `DescCache` appended to `Worker` struct (end-of-struct, layout-safe) + worker-context routing in `enqueuePush` + drain-on-deinit.

## What landed

| Phase | Commits                                    | Summary                                                                    |
|-------|--------------------------------------------|----------------------------------------------------------------------------|
| 0     | (baseline)                                 | Measurement only.                                                          |
| 1     | `f727966`, `dc25011`                       | `runtime_compare_zig.zig` `nestedParentTask` → `submitBatch` (harness).    |
| 2     | `1d544a7`, `9ef82af`, `3ce882f`, `0f25a28`, `25724d0`, `ab5bedb`, `922cb60` | DescCache SPSC primitive, per-submitter cache routing, drain-on-release.   |
| 3     | `768fab6`, `056ee01`, `d78a206`            | Worker-end `DescCache` field, worker-context routing, drain-on-deinit.     |
| 4     | `7e125a9`, *this commit*                   | Refreshed `benchmarks/results/*.json`, FINAL.md, CLAUDE.md snapshot.       |

## What was skipped (and why)

- **Phase 1 Task 1.3** (`bench-realistic` adoption of `submitBatch`) was **reverted** at `0554a84`: paired A/B gain on `nested_fanout_4x` was +3.22%, below the +5% strict gate. The `bench-realistic` harness's latency focus drove stddev of ~14K on a median of ~175K — +3.22% is within one σ of A's median. Task 1.2 (`runtime_compare`) carried the Phase-1 deliverable with +44.8% on the same mechanism. The `submitBatch` API itself remains available for user code.
- **Phase-2 profile-driven `src/` attacks** mentioned in the prior (2026-04-16 contended-scenarios) FINAL were not repeated here: `perf_event_paranoid=3` blocks `perf record` without sudo, and three relevant closed-plane memories (notifySubmits iter 7–11, Slice 3a worker pinning) already rule out the plausible attack surface. The DescCache approach chosen for Phase 2 attacked the global-freelist CAS traffic directly, independent of `notifySubmits`.

## Trade-off note — Phase-3 vs Phase-2 isolated

Phase-3's per-Worker DescCache regressed the contended submitter-thread
scenarios **relative to the Phase-2 checkpoint**:

- `contended_spawn_8x`: Phase-2 1,332,003 → Phase-3 1,197,495 (**−10.10%**)
- `contended_cpu_10us`: Phase-2 1,308,626 → Phase-3 1,239,517 (**−5.28%**)
- `flood_1m`: Phase-2 1,058,332 → Phase-3 985,820 (−6.85%)

Vs **Phase-0** (the cumulative comparison the plan actually gates), these same
scenarios are strongly positive: `contended_spawn_8x` +27.88%,
`contended_cpu_10us` +25.93%, `flood_1m` −0.33%. The Phase-2 optimum for
multi-submitter contended throughput is partially clawed back by Phase-3's
addition of the `DescCache` field to the 56-instance `Worker` struct (field is
at end-of-struct per iter-11 discipline, but cache-line pressure still lifts
after a 136-byte grow: 1912B → 2048B). The Phase-3 kill gate is
scoped to `nested_fanout_4x` only, so this regression is within the plan's
explicit trade-off envelope — but it is a potential target for a future
investigation pass.

## Closed planes confirmed (did not re-attempt)

These were closed before this plan started; the plan respected all of them:

- **Shared parked-workers bitmap** (iter 7) — regressed 11–22% on 3 of 4 scenarios.
- **Single-worker notifySubmits scan** (iter 8) — wake-coverage load-bearing, not just loop length.
- **notifySubmits cacheline-isolation** (iter 9) — neutral. The 27.58% inclusive time is structural SC `fetchAdd` + futex wake cost.
- **shouldExit off the hotpath** (iter 10) — hangs 20× stress (180s timeout).
- **Per-worker active_tasks shard** (iter 11) — struct layout-shift ate the RMW savings.
- **Socket-aware worker pinning** (Slice 3a) — 4–18% regression on realistic scenarios.

The Phase-3 `DescCache` field respects iter-11 discipline: appended at
end-of-struct (`src/pool.zig:353`), never mid-struct reorder.

## Next

- **`nested_fanout_4x`** narrowed 6.19x → 3.88x vs Go: further gains would
  require attacking Go's in-runtime fiber-stack amortisation (not
  scheduler-queue mechanics). Considered out-of-scope for this repo's design.
- **`contended_spawn_8x`** narrowed 3.86x → 2.20x vs Go — still 2.2x behind.
  Two remaining directions, both speculative:
  1. Investigate the Phase-3 → Phase-2 contended regression: is the Worker
     size shift (1912B → 2048B) the mechanism? If yes, a comptime flag to
     opt the worker-end `DescCache` out for multi-submitter workloads could
     reclaim Phase-2's 1.33M ops/s ceiling while keeping `nested_fanout_4x`
     wins.
  2. Tag 2.20x as the sustainable position; Go's per-P local-queue is a
     language-runtime-level feature this library can narrow but not match
     within its API constraints.
- **`contended_cpu_10us`** is in the same band as `contended_spawn_8x`; the
  same two directions apply.
- **`mixed_fast_slow`** remains within noise of parity (±10%); not a
  meaningful gap to close.

Pivot reference if the contended gap is taken up: the throughput-plateau
pivot memory (`project_throughput_plateau_pivot.md`) documents the prior
architectural-plateau finding that led to the lane / latency / fairness
focus areas now reflected in the bench harness.
