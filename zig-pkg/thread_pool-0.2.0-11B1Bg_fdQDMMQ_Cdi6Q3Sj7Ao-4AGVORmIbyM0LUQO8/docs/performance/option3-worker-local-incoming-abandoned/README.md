# Option 3 — Worker-Local Incoming Queues — ABANDONED 2026-04-14

**Status:** Attempted, validated, rejected by paired A/B. Branch preserved as audit trail; NOT merged.

## Outcome

| Benchmark | main median | option3 median | delta |
|---|---|---|---|
| flood_1m | 397K ops/s | 207K ops/s | **−48%** |
| contended_spawn_8x | 554K ops/s | 654K ops/s | +18% |

flood_1m regressed decisively — every option3 run came in BELOW main's minimum (distributions do not overlap). Per the plan's go/no-go criteria (≥ +10% flood_1m lift required, no contended_spawn_8x regression permitted), the verdict is REVERT.

## Where to find everything

- **Plan:** `docs/superpowers/plans/2026-04-14-option3-worker-local-incoming-queues.md` (on main).
- **Brainstorm:** `docs/superpowers/brainstorms/2026-04-14-option3-worker-local-incoming-queues.md` (on main).
- **Full A/B analysis + raw data:** `docs/performance/option3-worker-local-incoming/SUMMARY.md` (on branch `feat/option3-worker-local-incoming` ONLY — not on main).
- **Implementation commits:** see branch `feat/option3-worker-local-incoming` commits between `404c2a0..371d8ce`.

## Why it regressed (headline)

Single-submitter flood_1m submitter rotates across 56 per-worker incoming cachelines. Each rotation = one cold-line miss. The OLD design had the submitter hammering ONE hot cacheline (inject_queue.tail, always in submitter's L1). On flood_1m's 1M-submit hot loop, cold-line traversal cost exceeded the saved cacheline-coherence storm. The mechanism was explicitly predicted in the brainstorm's cost sketch.

## What might still be worth trying

- **Hybrid routing:** use incoming queues only when `Core.incoming_cursor` shows actual contention (multiple concurrent submitters racing on the fetchAdd). flood_1m single-submitter would fall through to inject; multi-submitter would spread. Conjectural.
- **Async-context-aware submit:** Tokio's design tracks which async task the submitter is running in, enabling true locality. A fundamentally different distribution model than this microbench-driven iteration.
- **Multi-submitter-first benchmarks:** if the project ever reprioritizes toward multi-submitter workloads, Option 3 could ship as-is for that regime (+18% contended_spawn_8x is real).

## Do NOT

- Re-attempt Option 3 without a plan for why flood_1m's cold-line cost won't dominate this time.
- Cite the +18% contended_spawn_8x number as an Option 3 win without the flood_1m −48% context.
