# Re-Profile Summary — 2026-04-13 (main tip ce0d56b, post G2 Re-Land)

## Baseline

- flood_1m median: **566K ops/s** (n=10, ReleaseFast, direct binary; Task 1 commit `3506b29`).
- Submitter: 100% running (zero voluntary blocks during flood_1m), 17 context switches in 2.94s.
- Worker median: 8% running, 56/56 workers >50% blocked.
- Critical path: submitter, producer-bound, not contention-bound.
- **Shift vs pre-G2:** submitter went from 89% → 100% running; G2 Re-Land consumed the remaining 11 pp of off-CPU submit-path time. Remaining optimization surface is pure on-CPU compute.

## Fresh single-atomic ceilings (vs 566K baseline)

| Target | Fresh lift | Fresh absolute | Pre-G2 lift (vs 331K) | Interpretation | Blast radius |
|---|---|---|---|---|---|
| submitted.fetchAdd (G3) | **+42%** | 803K | +28% | Ceiling grew — fresh baseline has less idle time so submit-path compute is a larger share. Clean measurement. | Small (1 snapshot reader; per-worker counter replacement trivial) |
| Descriptor CAS | -14% (SUSPECT, under host load ~15) | 485K | +16% | Under-load measurement is noise. Mechanistic: tagged CAS is uncontended in single-producer flood_1m; mutex replacement is a regression, not a lift. | Would be small if positive (per-worker freelist shards), but direction is wrong. |
| Wake scan | **+34.8%** (under load 22-30, likely conservative) | 763K | +47% | Below pre-G2 as expected — G2 ate 11 pp of off-CPU time that wake-scan removal used to recoup. Remainder is pure compute. | Hard (no bitmap per G1 lesson; sharded/orthogonal-gate only) |

## Methodology flags

- **Host-load confound:** Tasks 4 and 5 measured under host load 15–30 vs Task 1's clean state. Task 4's -14% is dominated by noise; Task 5's +34.8% direction and magnitude order are sound but probably conservative. An idle-host re-measurement of wake-scan is worth doing if user wants the precise ceiling.
- **Tasks 3 and 5 cannibalization:** Both target submit-path compute post-`incrementQueued()`. Naive additive compound (×1.42 × ×1.348 ≈ 1083K, +91%) will not hold. The submit path is already at 100% CPU; total savings are bounded by total remaining compute. A COMBINED stub (both atomics removed at once) would disambiguate; not measured here.
- **Phase H CAS gate:** Present in all stubs. Race defense is path-agnostic; stubs did not expose new races (see Task 3 20/20, Task 5 20/20 stress).

## Compound/cannibalization estimate

Absolute ceiling if G3 + wake-scan fully additive: 566K × 1.42 × 1.348 ≈ **1083K** (≈ +91%).
Realistic best-case (assume 50% cannibalization): **820K–950K**.
Empirical combined-stub measurement: NOT TAKEN (ambient host load would have contaminated it). Recommend measuring under idle host before implementing both.

## Tokio-gap accounting

- Target: 5-15M ops/s.
- Current: 566K.
- Post-single-atomic best case (all three realized, even ignoring Task 4): ~900K-1.1M.
- **Remaining gap after single-atomic exhaustion: 4.5-14× (80-90% of total).**
- Architectural work (Chase-Lev deque, event-driven wake, lock-free inject queue) is required to close the rest. Pre-existing plans at `docs/superpowers/plans/2026-04-11-*.md`.

## Ordered next-phase recommendation

1. **G3 (submitted.fetchAdd replacement)** — rationale: +42% ceiling with clean measurement and 20/20 stress; smallest blast radius among positive targets (1 snapshot reader to fix; per-worker counter replacement straightforward). Expected real implementation captures a large fraction of the 42% since the snapshot reader is the only non-hot-path consumer.
2. **Wake-scan redesign** — rationale: +34.8% measured (conservative), highest realistic ceiling remaining after G3. Must NOT be a bitmap (G1 lesson #7). Candidates: (a) orthogonal global `parked_count` gate so submitter fast-exits when 0; (b) sharded `is_parked[]` per NUMA group; (c) restructure wake to be triggered only on worker state transition, not per-submit. Hardest of the three. Consider doing G3 first, re-measuring, THEN designing wake-scan redesign with fresh evidence.
3. **Descriptor CAS (DEPRIORITIZE)** — rationale: mechanistic reasoning shows the tagged CAS is uncontended in flood_1m's single-producer shape. Per-worker freelist shards might help multi-producer workloads (contended_spawn_8x) but not flood_1m. Deprioritize until a multi-producer scenario becomes the bound target.
4. **Architectural pivot** — after G3 and wake-scan, ~900K-1.1M is the realistic ceiling from this single-atomic iteration path. To reach Tokio parity (5-15M), begin work on Chase-Lev WSD deque + event-driven wake + lock-free inject queue per the 2026-04-11 plans. These interact; consider one combined plan.

## Decision for the user

**Recommended next step:** land G3 first (smallest blast radius, largest ceiling, clean evidence). Then re-measure to inform the wake-scan redesign under fresh conditions. Then decide whether to continue single-atomic iteration (diminishing returns) or pivot to architectural changes.

If user wants to skip straight to architectural work: that's defensible given the single-atomic ceiling is only ~1.1M (<10% of Tokio target). But G3 is cheap enough that it's worth banking before the pivot.
