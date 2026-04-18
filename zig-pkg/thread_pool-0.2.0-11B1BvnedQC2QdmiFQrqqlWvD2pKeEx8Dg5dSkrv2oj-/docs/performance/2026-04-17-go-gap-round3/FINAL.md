# Go-gap round 3 — FINAL (FAILED)

**Date:** 2026-04-17
**Plan:** [`docs/superpowers/plans/2026-04-17-go-gap-round3.md`](../../superpowers/plans/2026-04-17-go-gap-round3.md)
**Verdict:** ❌ **FAILED kill gate — reverted.**
**Reverts:** `1e5d23e` reverts `58eb37d`; `786cea9` reverts `0908631`. Tree restored
byte-identical to `018fb10` for `src/pool.zig` and `tests/unit.zig`.

## Phase 1: Externalise per-worker DescCache → `Core.worker_desc_caches`

### Hypothesis

Round 1 Phase 3 appended a `desc_cache: DescCache = .{}` field to the `Worker`
struct, growing Worker size 1912 B → 2048 B. That Phase 3 landing regressed
submitter-context scenarios `-5 to -10%` even as it delivered Phase 3's
`nested_fanout_4x +81.26%` gain (see
[`../2026-04-16-go-gap-contended/FINAL.md`](../2026-04-16-go-gap-contended/FINAL.md)).

Hypothesis for round 3: move the worker-end DescCaches off the Worker struct
into a separate `[]DescCache` slice owned by `Core` (exactly how the
per-submitter DescCaches already live). Worker shrinks back to ~1920 B,
L1-DC footprint reduces, victim-scan cacheline traffic drops. Expected:
recover the submitter-context regression (+5% gate on `contended_spawn_8x`,
+3% on `contended_cpu_10us`) without giving back Phase 3's worker-context
`nested_fanout_4x` gain (−3% do-no-harm gate).

### Measurement protocol

Same-session paired A/B per repo protocol:

- A leg = pre-refactor: `018fb10` (plan doc commit; src tree byte-identical
  to `2c99e2b` = round 2 FINAL = Go-gap round 1 FINAL `a666ec3`).
- B leg = post-refactor: `58eb37d` (Task 2 landing).
- n = 10 interleaved sample pairs (`A1, B1, A2, B2, …, A10, B10`).
- `bench-runtime-zig -Doptimize=ReleaseFast`, `--samples 7 --warmup-discard 1`.
- Host: `linux x86_64`, 56 workers, 2-socket / 1-NUMA-node.

Binary hashes (confirm distinct legs):

- A: `d9a7b52383f1829463b56138b720d6e71f61998bcc3162f70da7d5c764b40a65`
- B: `cb4b1c5edf0fad9338dc99d5bdbf4bb4e5e2593fd69025439fc35483a683d040`

Raw artefacts: [`runs/phase1-{A,B}-{1..10}.json`](runs/) (20 files).
Aggregation: [`runs/phase1-ab.md`](runs/phase1-ab.md).

### Result

| Scenario              | A median   | B median   |    Δ%    | Gate     | Pass |
|-----------------------|-----------:|-----------:|---------:|:--------:|:----:|
| `contended_spawn_8x`  |  1,039,027 |    855,701 |  -17.64% | ≥ +5 %   | ❌   |
| `contended_cpu_10us`  |  1,152,276 |    904,796 |  -21.48% | ≥ +3 %   | ❌   |
| `nested_fanout_4x`    |  1,099,808 |    865,374 |  -21.32% | ≥ -3 %   | ❌   |
| `flood_1m`            |    910,801 |    873,634 |   -4.08% | ≥ -3 %   | ❌   |
| `cpu_work_10us`       |    907,009 |    941,301 |   +3.78% | ≥ -3 %   | ✅   |
| `cpu_work_100us`      |    450,516 |    421,812 |   -6.37% | ≥ -3 %   | ❌   |
| `burst_drain_burst`   |    162,281 |    161,845 |   -0.27% | ≥ -3 %   | ✅   |
| `mixed_fast_slow`     |    240,500 |    242,089 |   +0.66% | ≥ -3 %   | ✅   |

**Primary targets:** FAIL (0 / 2 pass; both primary gates missed by a wide
margin).
**Do-no-harm:** FAIL (3 / 6 miss: `nested_fanout_4x`, `flood_1m`,
`cpu_work_100us`).
**Overall gate:** FAIL.

### Why it failed

The refactor trades one L1-DC-resident field load for a two-step slice
indirection:

```zig
pre:   worker.desc_cache.tryPop()           // worker struct already hot
post:  core.worker_desc_caches[wi].tryPop() // slice base + index + load
```

The per-worker DescCache is on the **hottest path** for both enqueue
(worker-TLS submit) and dispatch (drain-on-release). Each op pays:

1. `Core.worker_desc_caches` slice-base load (cold the first time per
   cacheline, then in L1).
2. Index shift `* sizeOf(DescCache)` (one `imul` or `lea`).
3. DescCache base address load (a second line separate from `Worker`, so a
   second L1-DC resident line, not one fewer).

The Round 1 hypothesis that "Worker 2048 B is too big" overweighted the
victim-scan/steal-cacheline side. In practice, `Worker` is accessed
*locally* overwhelmingly — the DescCache lives on the same owner thread as
every read and write to it, so the per-worker line was already hot whenever
the owner touched it. Moving it off-struct only added a second indirection
without reducing the **local working set**, while losing the co-location
that made the round-1 Phase-3 cache refill amortise across the
`workerMain` inner loop.

Distribution note: contended scenarios showed a narrow B distribution
centred below A — no bimodality, no overlap — consistent with a structural
indirection cost rather than contention artefact. `nested_fanout_4x`
dropped 21.32%, giving back roughly a quarter of the Phase-3 gain on a
single commit.

### Closed plane

**Externalised per-worker DescCache is closed.** Any future attempt to
reduce Worker size must leave the DescCache field in place, or target a
different field whose local-access frequency is materially lower.

### Post-mortem / next candidates

The round-2 FINAL already enumerated two speculative follow-ups. Round 3
eliminates one of them and re-weights the other:

1. ~~**Comptime opt-out of per-Worker DescCache.**~~ **Upgraded from
   "speculative" to "favoured next move."** Instead of *moving* the field
   off the Worker struct at runtime, gate it behind a `-Dworker-desc-cache`
   comptime flag so multi-submitter-dominated workloads can elide the
   field entirely (reclaiming round-1 Phase-2's 1.33 M ops/s
   `contended_*` ceiling) while default builds keep the Phase-3
   `nested_fanout_4x` gain. This is a per-build trade, not a per-runtime
   trade, so it sidesteps the indirection penalty that killed Phase 1.
   Sized as "round 4 candidate" pending future user green-light.

2. **Accept the 1.4–2.7x Go gap as structural.** Unchanged from round 2.
   Go's in-runtime local-P queue with cross-thread zero-cost spawn is a
   scheduler-primitive advantage that no C-ABI-compatible external pool
   has closed.

## References

- [Plan](../../superpowers/plans/2026-04-17-go-gap-round3.md)
- [Runsheet](runs/phase1-ab.md)
- [Round 2 FINAL (closed planes: lifo-rotate, batched submitBatch)](../2026-04-17-go-gap-round2/FINAL.md)
- [Round 1 FINAL (DescCache landing: contended_spawn_8x +35.98%, nested_fanout_4x +81.26%)](../2026-04-16-go-gap-contended/FINAL.md)
