# Session Wrap-Up and Next Steps — 2026-04-13

> **2026-04-14 audit correction:** Two of the recommendations below are obsolete. Phase H race fix (cited as a blocker by the untracked `2026-04-13-phase-h-fix-double-dequeue-race.md`) is **SHIPPED** to main — see commits `a75ed98` (merge), `710a98f` (state CAS gate), `daedce6` (queued_tasks balance + stealHalf retry cap), `e7b6703` (close-out validation). **Option 5 (lock-free inject queue) is also obsolete**: `src/queue/bounded_ring.zig` is already a Vyukov MPMC implementation; the linked plan was authored against an older mutex-backed version that was already replaced. **Of the five non-trivial options below, only Option 3 remains shovel-ready, and it needs a fresh plan written.** Brainstorm for Option 3 was added at `docs/superpowers/brainstorms/2026-04-14-option3-worker-local-incoming-queues.md`.
>
> **2026-04-14 host-drift finding (correction to this doc's drift hypothesis):** Stopping the `geode` co-tenant service moved the flood_1m mean from ~392K to ~414K — well within noise. **Geode was NOT the dominant drift cause.** The 566K morning baseline does not reproduce by stopping geode alone; remaining suspects are 4-day uptime + long-lived user processes (claude/node sessions). Future sessions: do not assume killing co-tenants will recover the 566K reference. A reboot is the only remaining intervention within agent reach (and was not authorized this session). Paired same-session A/B is the only reliable measurement methodology under these conditions.

## What this document is

A forward-looking synthesis of the 2026-04-13 autonomous session's learnings for the next engineer / session to pick up from. Covers what was tried, what worked and didn't, and the concrete next-step options ranked by evidence-adjusted expected value.

## Session baseline

Entered the session at main `ce0d56b` (Phase G2 Re-Land merged). The earlier re-profile work in this session (`docs/performance/reprofile-2026-04-13/SUMMARY.md`) produced:

- `flood_1m` baseline: 566K ops/s n=10 ReleaseFast (morning, commit `3506b29`).
- Submitter: 100% CPU-bound, zero voluntary blocks during flood_1m.
- Workers: 8% running, 56/56 workers >50% blocked.
- A/B-disable ceilings (with atomic hot-path reads removed entirely):
  - `submitted.fetchAdd` (G3): +42%
  - Descriptor CAS: -14% (under load; mechanistic deprioritize regardless)
  - Wake scan: +34.8% (under load; conservative)
- Ordered recommendation: 1. G3, 2. Wake-scan redesign, 3. Architectural pivot.

## What this session landed on main

1. **Counters layout correctness fix** (`65f920d`) — split `counters.submitted` onto its own cacheline AND converted `Counters` to `extern struct` + `align(std.atomic.cache_line)` + `comptime @offsetOf` asserts. Caught a pre-existing latent bug: Zig's auto-layout was silently reordering the `_pad0`/`_pad1` padding fields to the struct's tail, so the padding that existed on main before this session was INERT. The fix is correctness-only; perf measurement under this session's drifted host showed null delta.
2. **G3 full plan + close-out doc** (`8432cc8`) — documents what was attempted.
3. **Wake-gate full plan + 3-attempt abandon doc** (`fa371be` + `4e55aa7`) — documents what was attempted and why each variant failed.
4. **Session wrap-up** (this document).

## What was tried and did NOT land

### G3 full branch (preserved at `feat/g3-submitted-replacement`, NOT merged)

Replaced hot-path reads of `counters.submitted` at pool.zig:607 (wake-hint mixing) and :700 (steal-start mixing) with dedicated rotation sources (`Core.wake_hint` relaxed-atomic u32, `Worker.steal_hint` per-worker u64). Measurement: +1.7% vs pre-G3 under equivalent conditions (noise). The `.fetchAdd` on `counters.submitted` for observability was retained.

**Why it didn't help:** the original hot-path loads of `counters.submitted` read a cacheline that the submitter was ALREADY writing (queued_tasks). Replacing with new rotation sources added new cacheline accesses (wake_hint on Core, steal_hint on Worker). Net: traded old-cacheline loads for new-cacheline loads. No net savings.

The correctness-fix slice (cacheline split + extern struct + asserts + observability test) WAS landed separately as a correctness-only PR — the bug it fixes (inert padding) is independent of the perf change.

### Wake-gate branch (preserved at `feat/wake-scan-parked-count-gate`, NOT merged)

Three attempts to short-circuit the O(N) `is_parked[]` scan via a global `Sync.parked_count` atomic:

| Attempt | Variant | Δ flood_1m |
|---|---|---|
| 1 | Basic gate (no alignment, `.acquire` load) | -11.0% |
| 2 | Cacheline-aligned `parked_count` | -2.5% |
| 3 | Aligned + `.monotonic` fast-path load | -8.9% |

**Why none helped:** the cost of the worker-side `fetchAdd`/`fetchSub` on park/unpark transitions (once per park cycle) plus the submitter-side load on every spawn (1M/workload) exceeds the savings from skipping 56 seq_cst loads on the rare "all workers steal-busy" fast path — because `flood_1m` is saturated enough that workers park between short idle gaps frequently. The cacheline alignment helped 8.5pp (false sharing was part of the cost), but removing the `.acquire` fence didn't close the remaining gap — worker-side RMW contention is the true dominant cost.

Full triage in `docs/performance/wake-scan-gate-abandoned/README.md`.

## Host-environment confound

A critical finding: **flood_1m throughput on this host drifted from 566K (morning) to 380K (evening) for source-equivalent main.** Causes:

- Co-tenant `geode` process (owned by user `geode`, cannot kill) chewing ~100% CPU throughout the afternoon/evening.
- 4-day uptime with kernel/cache state accumulation.
- Frequency governor (`schedutil`) ramps cleanly to 3.3 GHz during benchmarks (verified via sampler), so DVFS is NOT the cause.

Paired same-session comparisons are still valid, but **any absolute number from this session's afternoon measurements cannot be compared against numbers from prior sessions' morning measurements.** The "566K → 803K (+42%)" A/B ceiling reported by re-profile Task 3 is under a specific host state that's unreproducible right now.

**Implication:** this session's perf claims (even the paired ones) have reduced statistical power. Future work should re-establish the 566K baseline on a cleaner host before drawing strong conclusions about any lift or regression.

## Why the single-atomic surface appears exhausted

The re-profile identified four hot-path atomics. Post-session status:

| Atomic | Re-profile A/B ceiling | Real-implementation result |
|---|---|---|
| `counters.submitted` fetchAdd | +42% | G3 tried, null |
| `counters.submitted` hot-path reads | (part of above) | Removed in G3, null |
| Descriptor CAS | -14% under load | Deprioritized |
| `is_parked[]` wake scan | +34.8% | Wake-gate tried, net-negative |
| `queued_tasks` seq_cst fetchAdd | not measured | Required for SC handshake; not safely removable |

Of the four, the three we could attack gave null or net-negative. `queued_tasks` is load-bearing for the lost-wakeup handshake at `.seq_cst` — weakening it would require redesigning the park/wake contract.

## Next-step options, ranked

### Option 1: Re-establish baseline on a clean host (HIGHEST EV, LOWEST EFFORT)

Before any more perf work, re-run the re-profile's Task 1 baseline measurement on a quiet host (no co-tenant, recent reboot). If 566K reproduces, the existing A/B ceiling data is trustworthy and future work can target it directly. If it doesn't reproduce and the host has fundamentally changed, the ceiling data is stale and ALL remaining phase plans need fresh measurements before execution.

**Cost:** 10 minutes. **Risk:** zero.

### Option 2: Restructure the park/wake contract (HIGH EV, HIGH EFFORT)

The re-profile showed submitter 100% CPU-bound with zero voluntary blocks. Every submit does:
1. Atomic CAS on descriptor free-list.
2. Write descriptor fields.
3. Push to LIFO slot or local queue or inject queue.
4. `counters.submitted.fetchAdd(.monotonic)` (observability).
5. `counters.queued_tasks.fetchAdd(.seq_cst)` (handshake).
6. Wake-scan (`is_parked[]` loop).

The SC-fetchAdd on queued_tasks (step 5) is required ONLY for the park/wake handshake. If we replaced the park/wake mechanism with one that doesn't need SC total order — e.g., direct futex on a per-worker waiter list, with relaxed atomic enqueue — step 5 could be relaxed to `.monotonic`. On x86_64 this would eliminate an mfence from every submit.

This is a significant redesign: per-Worker parking with condvars becomes per-pool futex-managed waiter lists, the submit hot path changes, and the Phase H ghost-dispatch defense needs to be revalidated against the new wake model.

**Cost:** multiple sessions. **Risk:** high (introduces new race surfaces; Phase G2 taught us timing changes unmask latent races).

### Option 3: Worker-local submit slots (HIGH EV, MEDIUM EFFORT)

Instead of the submitter choosing "LIFO slot of current worker" vs "inject queue", extend the LIFO to a per-Worker incoming queue that ONLY the worker pops from (single-reader) and ONLY non-owner submitters push to (multi-writer). The submitter rotates between worker-local queues via its `wake_hint`. This amortizes submit-side atomic cost across N independent cachelines.

For flood_1m (single submitter pushing 1M tasks), this spreads the writes across 56 cachelines instead of 1-2. Expected benefit: significant reduction in cacheline contention for the submitter's hot-path writes.

**Cost:** moderate redesign. Touches `enqueueTask` + `nextTask` + cancellation + shutdown paths. **Risk:** medium (changes the steal-half semantics; needs stress validation).

### Option 4: Batched submit API (LOW EV for flood_1m, USEFUL GENERALLY)

Expose a `submitBatch(&tasks)` that atomically claims N descriptors, fills them, and pushes them in one SC-fetchAdd on queued_tasks + one wake. Amortizes the SC cost by 1/N per task.

flood_1m is already single-producer doing a tight loop — a submitBatch API would change the benchmark's submit pattern, which may or may not match real-world usage patterns. For production workloads that have natural batching (e.g., processing N items from an input), this is a clean win. For the single-task submit hot path, it doesn't help.

**Cost:** small — add a new API path alongside `submit`. **Risk:** low.

### Option 5: Lock-free inject queue (TARGETS contended_spawn_8x, not flood_1m)

The `lock-free-inject-queue` plan at `docs/superpowers/plans/2026-04-11-lock-free-inject-queue.md` targets multi-submitter scenarios. Current inject queue is `BoundedRing` with a CAS-loop push. Under 8+ concurrent submitters (contended_spawn_8x), this likely bottlenecks. Tokio uses an MPSC queue for its global queue.

This does NOT help flood_1m (single submitter rarely hits the inject queue — most submits fit the LIFO slot or local queue). It would help contended_spawn_8x significantly, which is a secondary benchmark.

**Cost:** medium. **Risk:** low (plan already drafted).

### Option 6: Accept current perf, stop optimizing (DEFENSIBLE)

Argument: the re-profile showed submitter CPU-bound with the non-futex atomics at their minimum useful cost. The hot path is as thin as it can be without restructuring. Attempts to eliminate more atomics either (a) break correctness guarantees or (b) introduce cacheline costs that offset savings.

If the 566K baseline represents the steady-state of this architecture, then further lift requires structural change — a pool using a fundamentally different distribution model (e.g., Tokio's worker-local MPSC queues with direct futex wake). Incremental work on this design has diminishing returns.

**Cost:** zero. **Risk:** zero. **Opportunity cost:** may leave measurable lift on the table if Option 2/3 pays off.

## Concrete recommendation

Start with **Option 1 (re-establish baseline on clean host)**. The decision on which of Options 2-5 to pursue depends on whether the baseline is stable and reproducible. If yes, Option 3 (worker-local submit slots) has the best evidence-adjusted EV for flood_1m specifically. If the baseline is drift-dominated, no further perf work should be done until host conditions are controlled.

Option 5 is independently valuable for `contended_spawn_8x` and can be executed on any host state since its benchmark shape tolerates more noise than flood_1m.

## Audit trail

- `docs/performance/counters-layout-fix/` — Counters layout correctness fix (SHIPPED)
- `docs/performance/wake-scan-gate-abandoned/` — 3-attempt abandon (DOCS ON MAIN)
- `docs/superpowers/plans/2026-04-13-phase-g3-submitted-replacement.md` — G3 plan
- `docs/superpowers/plans/2026-04-13-wake-scan-parked-count-gate.md` — wake-gate plan
- `docs/performance/reprofile-2026-04-13/SUMMARY.md` — session-start re-profile evidence
- Branch `feat/g3-submitted-replacement` — full G3 attempt (unmerged)
- Branch `feat/wake-scan-parked-count-gate` — 3-attempt wake-gate (unmerged)
- Pre-existing worktree `thread-pool-phase-g2` — from prior session, left alone
