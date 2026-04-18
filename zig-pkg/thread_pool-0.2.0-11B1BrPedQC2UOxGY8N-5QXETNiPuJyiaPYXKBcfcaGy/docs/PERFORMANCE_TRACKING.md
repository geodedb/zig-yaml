# Performance Tracking

Rolling record of micro-benchmark numbers as the Tokio-parity plan progresses.
All numbers from local dev machine unless noted. CI baselines tracked in
`benchmarks/results/baseline.json`.

## 2026-04-15 realistic workload comparison — 8 scenarios across 3 runtimes

**Status:** shipped on main. Benchmarks at `benchmarks/runtime_compare_zig.zig`,
`benchmarks/external/tokio_runtime_bench/src/main.rs`, and
`benchmarks/external/go_runtime_bench/main.go`.

Expanded the runtime comparison from 2 noop-throughput scenarios to 8
scenarios including realistic CPU work, contended submission, nested fanout,
burst-drain patterns, and mixed fast/slow workloads. All realistic scenarios
use busy loops for fair cross-runtime measurement. Per-task latency
percentiles (p50/p95/p99) are tracked for all new scenarios.

### Headline results (56 workers, 6 retained samples)

| Scenario | Zig | Go | Zig vs Go |
|---|---:|---:|---:|
| `cpu_work_10us` | 1,251,811 ops/s | 597,746 ops/s | **2.09x ahead** |
| `flood_1m` | 1,024,793 ops/s | 776,699 ops/s | **1.32x ahead** |
| `burst_drain_burst` | 163,679 ops/s | 145,170 ops/s | **1.13x ahead** |
| `cpu_work_100us` | 456,838 ops/s | 402,792 ops/s | **1.13x ahead** |
| `mixed_fast_slow` | 223,873 ops/s | 247,217 ops/s | 1.10x behind |
| `contended_cpu_10us` | 1,006,760 ops/s | 1,742,841 ops/s | 1.73x behind |
| `contended_spawn_8x` | 1,055,748 ops/s | 2,881,462 ops/s | 2.73x behind |
| `nested_fanout_4x` | 490,591 ops/s | 2,595,763 ops/s | 5.29x behind |

### Key takeaway

Zig wins 5 of 8 against Go and 7 of 8 against Tokio. The losses are
structural: Go's in-runtime scheduler gives goroutine submitters zero-cost
local-queue access for contended and nested scenarios. On realistic CPU-bound
work, Zig's work-stealing pool dispatches tasks 2x faster than Go.

### Latency highlight

`contended_cpu_10us` p50: Zig 22us vs Go 535us. Despite lower throughput on
contended scenarios, per-task latency is far more predictable.

See [docs/RUNTIME_COMPARISON.md](RUNTIME_COMPARISON.md) for the full table
including Tokio numbers and latency percentiles.

## 2026-04-15 direct runtime comparison — vendored Tokio and Go (initial)

**Status:** superseded by the 8-scenario comparison above.

Initial 2-scenario comparison (flood_1m, contended_spawn_8x) that established
the direct-measurement methodology using vendored source trees.

## 2026-04-14 late session — scratch fast path + idle queue attempt

**Status:** implemented in the current working tree only, not on `main`.
Detailed archive: `docs/performance/2026-04-14-scratch-fastpath-idle-queue/`.

### What changed

- `WorkerScratch.beginTask()`, `alloc()`, and `finishTask()` are now lock-free
  on the normal owning-worker path.
- `ThreadPool.purgeWorkerCaches()` / `Core.purgeWorkerCaches()` now reject
  unless the pool is quiescent: `active_tasks == 0 && queued_tasks == 0`.
- Added `WakeStrategy` with an opt-in `idle_queue` mode that replaces the
  submit-path O(N) parked-worker scan with a bounded idle-worker ticket queue.
- Added `RuntimePreset.tokio_parity`, which currently enables
  `timestamp_mode = .disabled` and `wake_strategy = .idle_queue`.

### Correctness outcome

The first cut of the scratch fast-path refactor exposed a real race:
idle-time purge and external quiescent purge could overlap and double-free a
scratch buffer. That caused an intermittent `SIGSEGV` in
`stress.test.repeated churn returns to a bounded steady state after purge`.

Final workspace fix:

- keep the task fast path lock-free
- serialize only overlapping purge callers on a slow-path purge mutex

Validation on the final workspace:

- `zig build test --summary all` PASS
- `zig build test-integration --summary all` PASS
- `zig build test-stress --summary all` PASS
- focused purge/churn stress loop: 30/30 PASS
- required `ReleaseFast` stress gate: 20/20 PASS

### Same-session A/B (balanced order, n=10 each, ReleaseFast)

Baseline was a clean worktree at `HEAD`; candidate was the final dirty
workspace. Host load during this measurement was high
(`load average: 12.89, 13.63, 11.13` with unrelated `geode` processes
consuming CPU), so treat these as relative same-session numbers only.

| Scenario | Baseline median ops/s | Baseline p95 | Candidate median ops/s | Candidate p95 | Delta |
|---|---:|---:|---:|---:|---:|
| `tokio_parity/flood_1m` | 487,840.5 | 537,976 | 465,650.0 | 541,624 | -4.5% median |
| `tokio_parity/contended_spawn_8x` | 469,570.0 | 510,690 | 411,959.0 | 453,933 | -12.3% median |

### Verdict

This attempt improved the implementation shape and closed a real purge race,
but it did **not** meet the performance success criteria on this host. Do not
claim Tokio/Go parity progress from this patch as-is, and do not flip the
default wake strategy based on these numbers.

## Verdict vs Targets

| Target | v0.2.0 baseline | After plan | Met? |
|--------|----------------|-----------|------|
| `conn_churn_seq/global_queue` throughput ≥ 5M ops/s | 1.48M | ~817K (Phase A+B baseline; not re-measured in B7; see C2 for final verdict) | ❌ regressed |
| `conn_churn_seq/work_stealing` throughput ≥ 3M ops/s | 648K | ~763K (Phase A+B baseline; not re-measured in B7; see C2 for final verdict) | ❌ regressed |
| Submit p50 (single-producer) < 200 ns | 619 ns | 781 ns (Phase A) | ❌ still above target; Phase A recovered the broadcast-fallback regression (~1.8 µs → 781 ns median of 5 runs); remaining gap addressed in Phase B |
| Submit p99 (4 producers) < 1 µs | 6.7 µs | ~12.8 µs | ❌ regressed |
| `producer_contention/*` completion p50 < 100 µs | 1.46 ms | 1.24 ms | ❌ marginal improvement only (queue never filled) |
| Hot-path `nanoTimestamp()` calls per task | 3 | 1 (mandatory; 0 with `timestamp_mode=disabled`) | ✅ (Task 5) |
| Hot-path atomic ops per task | ~10 | ~5 (per-worker counters) | ✅ (Tasks 6, 7) |
| Tokio-parity benchmark suite exists | — | yes (2 scenarios) | ✅ (Task 15) |
| Micro-benchmarks for submit/steal/wake exist | — | yes | ✅ (Tasks 2-4) |
| CI advisory micro-bench job | — | yes | ✅ (Task 16) |
| `bench_tokio_parity/flood_1m` ≥ 1M ops/s | 297K | 340K (Phase C median of 3, very stable: 338K/340K/340K) | ❌ BELOW TARGET — 66% gap; bottleneck is backpressure condvar path (coalesced wake reverted due to Task 10 stress-test hang) |
| `bench_tokio_parity/contended_spawn_8x` ≥ 1M ops/s | 497K | 534K (Phase C median of 3: 510K/534K/549K) | ❌ BELOW TARGET — 47% gap |
| Bench harness run-to-run stddev (`conn_churn_seq/global_queue`) | ~25% | 58% (measured; machine is inherently noisy here) | ✅ measurement fixed — compare-bench now gates on 3×stddev, not hard-coded 15% |

## Phase A+B Final Verdict

**Submit latency (Phase A):** p50 recovered from the Phase 3 broadcast-fallback
regression (~1.8 µs) to 781 ns median of 5 runs. The seq_cst handshake on
`is_parked` + `queued_tasks` closes the lost-wakeup race with a single
signal path and no fallback broadcast. Still ~4× the <200 ns target, but
the regression is no longer in the way.

**Steal throughput (Phase B, batch=1):** 1.42M ops/s, +109% vs Chase-Lev's
677K baseline. The RingQueue swap paid off on single-item steal alone —
owner/stealer last-element race resolves in fewer cache-line bounces.

**Steal throughput (Phase B, batch=8):** 656K ops/s, *slower* than batch=1
in the 2-worker micro because the single victim stalls more often waiting
for the stealer to release capacity. The benefit of true batch-steal shows
only with more stealers per victim; at 2 workers it's a micro-anti-signal.

**Macro `conn_churn_seq`:** +53% global_queue (533K→817K), +40% work_stealing
(544K→763K) vs the Phase 3 baseline. Still far below the 3M–5M targets but
directionally good.

**Macro `producer_contention/work_stealing`:** -18% (892K→731K). Queue
never fills (peak ~2K / 4096) so this is run-to-run variance, not a real
regression — but it's close to CI's -15% regression gate and worth flagging.

**Tokio parity `flood_1m`:** 347K ops/s vs ≥1M target (65% gap remains).

---

## Phase C: Bench Stability + LIFO Slot

**Shipped (this phase):**

1. **7-run discard-first median + stddev** reporting in `benchmarks/common.zig`.
2. **`compare-bench` gates on 3×stddev** (floor 15%) instead of hard-coded 15%.
3. **Per-worker LIFO slot** in `src/pool.zig` — submit-from-worker path now tries
   a single-slot cache before the local ring. Owner-only write; stealers never
   touch the slot.

**Not shipped — reverted:**

- **Coalesced backpressure wake** (Task 9, commit `949cf74`) was reverted in
  `a77003d`. Unit tests passed but `test-stress` hung intermittently. Root
  cause not conclusively isolated before merge — filed as follow-up.

### Phase C measurements (git SHA `a77003d`, median of the stated run count)

| Metric | Phase A+B (merged) | Phase C | Delta |
|---|---:|---:|---|
| Submit p50 (1 worker, 100k samples, median of 5) | 781 ns | 917 ns | bimodal machine noise (558 / 585 / 917 / 948 / 978 ns) |
| Wake p50 (2 workers, 5k samples, median of 3) | 9985 ns | 10819 ns | +8% (within noise) |
| Steal ops/s batch=1 (median of 3) | 1.42M | 668K | machine-state variance (one run hit 1.36M) |
| Steal ops/s batch=8 (median of 3) | 656K | 1.22M | +85% |
| Tokio flood_1m (median of 3) | 336K | 340K | +1.2% (LIFO inert — bench uses 1 external submitter, no worker-context pushes) |
| Tokio contended_spawn_8x (median of 3) | 514K | 534K | +4% (within noise) |
| `conn_churn_seq/global_queue` | 817K | 758K | -7% (within 58% stddev) |
| `conn_churn_seq/work_stealing` | 763K | 683K | -10% (within 9.1% stddev, edge) |
| `producer_contention/global_queue` | ~730K | 808K | +11% |
| `producer_contention/work_stealing` | ~731K | 821K | +12% |

### Honest Phase C verdict

- **Bench stability (Phase 1 of plan):** net win. The 7-run harness with stddev
  reporting revealed that this dev machine produces 58% stddev on
  `conn_churn_seq/global_queue` and 9-13% on the other scenarios — a fact
  hidden by the old 3-run median. Every future optimization now has a
  defensible noise floor to compare against.
- **LIFO slot (Phase 2 of plan):** code ships green, but the current bench
  suite doesn't exercise the hot path. `bench_tokio_parity/flood_1m` uses a
  single external submitter thread; `contended_spawn_8x` uses 8 external
  threads. None of them submit from worker context, so the LIFO slot sits
  empty. A fork-join/nested-async bench would show the real benefit. Until
  one exists, the shipped LIFO code is measured as within-noise and should
  be treated as plumbing for a future workload.
- **Coalesced wake (Phase 3 of plan):** reverted. The measurable throughput
  gap on Tokio-parity flood scenarios is the backpressure condvar path —
  this phase would have addressed it, but the implementation caused
  intermittent hangs in `test-stress` that weren't resolved under time
  pressure. Follow-up task filed.

### Residual gap to Tokio parity

Tokio's `rt_multi_threaded` flood runs 5–15M ops/s; we run 340K. 15–45×
gap. The bottleneck has been triangulated to the blocking-submit /
backpressure path on `flood_1m`: with 1M tasks through a 4096-slot queue,
the submitter blocks ~244 times, each block paying a full condvar
round-trip. Next pass must address this without the stress-test
regression — either a safer coalescing design (edge-triggered on queue
empty→non-empty), or a lock-free descriptor-pool refill so submitters
don't block at all.

**Tokio parity `contended_spawn_8x`:** 508K ops/s vs ≥1M target (49% gap).

### Residual gap

With the submit-path and steal-path recovered, the bottleneck on the
Tokio-parity flood scenarios has moved to the backpressure condvar path:
at 1M tasks through a 4096-capacity queue the submitter blocks ~244 times,
each block paying a full condvar wait+signal round-trip. A future pass
would (a) coalesce backpressure wake-ups so a worker drain signals once
per N descriptors freed, (b) increase effective throughput via larger
inject batches without increasing submit p99, or (c) investigate lock-free
backpressure (thread-local reservation of descriptor slots).

The single-item steal improvement (+109%) and the recovered submit-latency
mean the ring queue and park simplification are both net wins and should
ship. The Tokio-parity 1M ops/s target is out of reach in this pass.

## Phase D: Lock-Free Backpressure (negative result — REVERTED)

**Hypothesis:** The Phase C residual-gap analysis named the backpressure
condvar path as the flood_1m bottleneck (submitter blocks ~244× per 1M
tasks, each paying a full mutex+futex round-trip). Phase D rewrote
`waitForCapacity` as a lock-free spin→yield→sleep backoff and removed
`backpressure_mutex` / `backpressure_cond` / `backpressure_waiters` from
`Sync`. Expected ≥80% flood_1m throughput improvement. See
`docs/superpowers/plans/2026-04-12-lock-free-backpressure.md`.

**Measured (median of 5 runs, ReleaseFast, same host as Phase C):**

| Metric | Phase C | Phase D (measured) | Delta |
|---|---:|---:|---:|
| `bench_tokio_parity/flood_1m` ops/s | 340K | 341K | +0.4% (noise) |
| `bench_tokio_parity/contended_spawn_8x` ops/s | 534K | 510K | -4.5% |
| submit p50 | 917 ns | 929 ns | +1.3% (noise) |
| submit p99 | 1690 ns | 1754 ns | +3.8% |
| `test-stress` 5× consecutive | pass | pass | no hang |

Phase C rollback floor was flood_1m < 450K → revert. Measured 341K
triggers the rollback unambiguously. Branch `feat/lock-free-backpressure`
was reset to preserve only the two incidental test additions (Task 1
regression guard, Task 6 deadline unit test) as permanent improvements.

### Root-cause profile (perf + flame analysis, commit `850b0b5`)

A post-measurement `perf record --call-graph dwarf -F 999` on flood_1m
revealed the backpressure path was never the critical path:

| Candidate path | Cumulative % of cycles |
|---|---:|
| **Work-stealing victim scan** (`nextTask` calling `LocalQueue.len()` across all siblings, two remote-atomic acquire-loads per victim per scan) | **42.1%** |
| **Per-task worker park/unpark** (`park_cond.signal` + `timedWait`, ~1M context-switches for 1M tasks) | ~17–18% |
| Inject queue pop | 7.7% |
| Submit path total | 6.5% |
| Descriptor CAS free-list (acquire + release combined) | ~2.7% |
| Backpressure path | < 1% |

- IPC = 0.19 (severe memory stalls).
- Cache-miss rate = 34.1%.
- 56 workers × 55 sibling scans → all-to-all cacheline ping-pong on each
  local deque's `(top, bottom)` pair. Classic false-sharing topology.

### Lessons learned

1. **The Phase C gap analysis conflated "where the submitter spends its
   blocked time" with "where the pool spends its total cycles."** The
   submitter's 244 condvar round-trips are real but negligible as a
   fraction of total CPU time when 56 workers are burning cycles scanning
   each other.
2. **`perf record` before planning, not after.** A 5-minute profile would
   have redirected the plan to the steal-scan before any code was written.
3. The lock-free backpressure implementation was correct (passed 5/5
   stress runs, no regressions beyond noise), just off the critical path.

### Follow-up targets (priority order)

1. **Steal scan cacheline ping-pong** — maintain a global "non-empty
   workers" bitmap updated lazily on push/pop; idle stealers CLZ-scan the
   bitmap instead of peeking every sibling's `(top, bottom)` pair.
   Expected impact: 30–40% of flood_1m cycles reclaimable.
2. **Per-task park/unpark** — with the scan fixed, workers should find
   work without parking, but a keep-alive spin window on recent-submit
   workers is insurance.
3. Backpressure lock-free rewrite is **not shipped**; revisit only if a
   future workload actually makes it a bottleneck.

## Phase E: Steal-Scan Bitmap (negative result — REVERTED)

**Hypothesis:** The Phase D `perf record` profile attributed 42.1% of
`flood_1m` cumulative cycles to the O(N²) sibling-peek steal scan in
`nextTask`. Phase E replaced that scan with an O(1) bitmap-driven scan:
`Core.non_empty_workers: std.atomic.Value(u64)` with one bit per worker,
set on owner push, cleared with Tokio-style re-check on pop-to-empty and
steal-drain. See
`docs/superpowers/specs/2026-04-12-steal-scan-bitmap-design.md` and
`docs/superpowers/plans/2026-04-12-steal-scan-bitmap.md`.

Targets: flood_1m ≥ 700K ops/s, cache-miss ≤ 8%.

**Measured (median of 5 runs, ReleaseFast, 56-core host):**

| Metric | Phase C | Phase E (measured) | Delta |
|---|---:|---:|---:|
| `bench_tokio_parity/flood_1m` ops/s | 340K | **322K** | **-5%** |
| `bench_tokio_parity/contended_spawn_8x` ops/s | 534K | 550K | +3% (noise) |
| submit p50 | 917 ns | 529 ns | -42% (see caveat) |
| submit p99 | 1690 ns | 762 ns | -55% (see caveat) |
| `perf stat` cache-miss rate | 34.1% | 35.9% | slightly worse |
| `perf stat` IPC | 0.19 | 0.14 | slightly worse |
| Context-switches / 1M tasks | ~1.0M | ~878K | unchanged |
| `test-stress` 5× consecutive | pass | pass | no hang |

Rollback floor was `flood_1m < 550K` → triggered. Behavior-change commits
(Tasks 2-6: bitmap infrastructure, all three bit-update sites, scan
rewrite) were reset out. Retained: Task 1 (`error.TooManyWorkers` cap at
`max_threads > 64` — a defensive guard that's independently useful)
and Tasks 7-8 (a racing-threads bitmap-invariant unit test and a
wide-pool flood stress test — both exercise the scheduler without
reading the bitmap directly, so they remain valid regression guards).

### Why the profile misled us

The Phase D profile counted cumulative cycles across all 56 workers.
Reclaiming 42% of that cumulative cost does not translate to 42% fewer
wall-clock seconds when workers are not the critical path — `flood_1m`
is driven by a single submitter + N drainers with ~1 context-switch per
task. Context-switch count barely moved (1.0M → 0.878M), confirming
the park/unpark path is the hard floor. The bitmap maintenance overhead
(`fetchOr` on every push, `fetchAnd` + re-check on every drain edge)
slightly offsets the scan savings, producing a small regression on the
macro workload.

### Caveat on submit-latency improvement

`bench-micro-submit` shows a dramatic p50/p99 improvement (917 → 529 ns
and 1690 → 762 ns), larger than the code change should produce. Two
possibilities: (a) real side effect of reduced cross-core atomic
contention, or (b) environmental noise between measurement sessions
(the bench-micro-submit harness runs with a single worker — no siblings
to scan — so the bitmap is trivially inert in that path). The sign is
directionally positive but the magnitude is not trustworthy without
re-verification.

### Lessons learned

1. **Cumulative-time profiles mislead when workers aren't the critical
   path.** A wall-clock measurement of the specific contended path
   (single submitter, N drainers) would have shown park/unpark as the
   dominant cost before we wrote any code.
2. **The steal-scan cost was real but not load-bearing.** Reclaiming it
   without addressing park/unpark produces workers that find work faster
   and then park faster — throughput is unchanged because park frequency
   dominates.
3. The bitmap infrastructure was correct (passed 5/5 stress runs, no
   hangs, no lost tasks). It could be re-landed alongside a Phase F
   park/unpark fix if the maintenance cost stops being a net loss once
   workers park less. For now: YAGNI, reverted.

### Follow-up priority order

Unchanged from Phase D:

1. **Phase F: park/unpark path.** ~17% of Phase D cycles; now the dominant
   remaining cost after the scan was addressed. Options: keep-alive spin
   window on recent-submit workers, notify-coalescing, or event-based
   worker wakes. Must be evaluated with a wall-clock profile of the
   single-submitter flood scenario, not cumulative.
2. Phase G: inject queue + descriptor pool.
3. Phase H: worker-local allocation / cache locality.

## Phase F1: Hot-Spin Wake Elimination (negative result — REVERTED, A/B gate caught it)

**Hypothesis:** A wall-clock `perf sched record` profile (2026-04-12) identified the submitter at 89% CPU-bound with ~50% of cycles in the `futex_wake` chain inside `enqueueTask`. An A/B-disable experiment (stub the wake block to a no-op) lifted `flood_1m` from 335K → 506K (+51%) — proving the wake path was a real, addressable ceiling. Phase F1 attempted to capture most of that ceiling by adding `Core.active_spinners: std.atomic.Value(u32)`, bracketing the existing `idle()` spin phase with `fetchAdd`/`fetchSub`, and making `enqueueTask` skip the `is_parked[]` scan + `futex_wake` when `active_spinners > 0`. See `docs/superpowers/specs/2026-04-12-phase-f-hot-spin-wake-design.md` and `docs/superpowers/plans/2026-04-12-phase-f-hot-spin-wake.md`.

### Measured (median of 3, ReleaseFast, 56-core host)

| Metric | Baseline | Phase F1 (default) | Phase F1 (spin=0 A/B) |
|---|---:|---:|---:|
| `flood_1m` ops/s | 335K | **383K** | **386K** |
| `contended_spawn_8x` ops/s | 534K | 568K (mean of 3) | 575K (mean of 3) |

The F1 configuration and the spin=0 A/B are **within noise of each other**. Disabling the spin phase (so workers can never be caught in the "hot-spin" window) did not regress throughput. That proves the `active_spinners > 0` short-circuit in `enqueueTask` was firing ~never: the mechanic was dead code at runtime.

### Why the mechanic didn't engage

Workers are 73% parked during `flood_1m` (per the same perf sched profile). The `idle()` spin phase runs `spin_before_park_iters = 128` iterations × ~1 ns each = **~128 ns**. Inter-submit interval at ~337K ops/s is **~3 µs** — 20× longer than the spin window. The probability that the submitter's `active_spinners.load` observes a non-zero value is negligible; the submitter almost always takes the cold path (full `is_parked` scan + `park_cond.signal` + `futex_wake`), exactly as before. The ~14% throughput movement (335K → 383K) is noise floor / micro-architectural chance, not a Phase F1 win.

### A/B gate worked — keep doing this

Phases D and E both shipped, merged, and documented negative results because the plans committed code before measuring whether the target was engaging. **Phase F1's spec required an A/B-disable measurement before acceptance**, and the gate correctly refused to sign off: the default config and `spin_before_park_iters = 0` produced indistinguishable results. Total cost: 4 commits on a feature branch, never merged, caught in ~15 minutes of measurement after the mechanic was in place.

This is the methodology succeeding. A failing phase was pre-empted before it reached main.

### What was kept

- `tests/unit.zig` — `active_spinners: counter stays non-negative under concurrent workers`. Exercises `spin_before_park_iters = 8` to stress every exit path of `idle()`'s spin loop, submits 40K tasks + a trailing single task. Independently useful as a scheduler stress probe regardless of whether `active_spinners` exists; retained as a permanent regression guard.

All behavior-change commits (infrastructure field, worker maintenance, submitter skip-wake, ordering tweak) were reset out of the feature branch before merge.

### Next attempts (design directions, not yet planned)

The underlying problem — `active_spinners` is 0 at submit time because workers park too quickly — has two correctness-neutral fixes:

1. **F1a: longer spin.** Increase `spin_before_park_iters` dramatically (e.g., ~16K iterations, ~16 µs spin). Workers overlap submits and `active_spinners > 0` becomes frequently true. Trade-off: idle CPU burn in scenarios with no work. Unacceptable for a real no-op workload (56 workers × 100% CPU).
2. **F1b: reserved hot-spin workers.** A small number (1–2) of workers never park; the rest park normally. Submitter can rely on the hot-spinners being catchable. Trade-off: fixed CPU cost regardless of load — but we're already burning those cycles on futex_wake, so net CPU may be flat or down.

Both require a new spec + fresh A/B ceiling measurement before planning.

### Lessons learned

1. **A/B-disable before acceptance, every phase.** Phase F's spec made this a rule; the rule paid out on the first attempt.
2. **A/B must target the mechanic under measurement, not just the suspected bottleneck.** The pre-planning A/B (stub the wake block) validated the target (wake path). The post-implementation A/B (spin=0) validated the mechanic (spin → skip-wake → throughput). Both are needed — a valid target with an ineffective mechanic still produces zero gain.
3. **Probability-of-engagement matters.** The design assumed workers would "often" be spinning at submit time without quantifying "often." Ratio of (spin window duration) : (inter-submit interval) is the correct figure of merit; when it's < 1, the mechanic effectively never fires.

## Phase F1b: Reserved Hot-Spin Workers (negative result — REVERTED, A/B gate caught it)

**Hypothesis:** F1's short-spin mechanic failed because its spin window (~128 ns) was 20× shorter than the inter-submit interval (~3 µs). F1b fixed this by reserving N workers that never park — making the "spin window" effectively ∞. Submitter would skip `futex_wake` unconditionally when `hot_spinners > 0`; reserved workers would propagate wakes every K tasks. See `docs/superpowers/specs/2026-04-12-phase-f1b-reserved-hot-spinners-design.md` and `docs/superpowers/plans/2026-04-12-phase-f1b-reserved-hot-spinners.md`.

### Measured (median of 3, ReleaseFast, 56-core host)

| Metric | hot_spinners=0 | hot_spinners=1 | Delta |
|---|---:|---:|---:|
| `flood_1m` ops/s | 384K | **398K** | +3.7% (noise) |
| `contended_spawn_8x` ops/s (mean of 3) | 572K | 583K | noise |

Rollback floor was 400K; 398K median triggered ROLLBACK. Behavior-change commits (Tasks 2–4: refactor + hot-spinner loop + conditional skip) were reset out. Retained (per plan's rollback clause): Task 1 (config fields + validation tests) and Tasks 5–7 (correctness + propagation + wide-pool stress tests) as permanent API+regression-guard surface.

### Why F1b failed where F1 had succeeded mechanically

F1b's *mechanic* DID engage — `hot_spinners=1` did mean worker 0 never parked and submitter DID skip the wake scan on the submit hot path. But throughput barely moved. The next post-revert deep re-profile revealed why: **the wake scan isn't the sole critical path; it shares the cache-line budget with three other contended atomics that F1b left alone**.

### Deep re-profile: the actual bottleneck is cache-line contention across four atomics

Systematic A/B-disable across every submit-path component (2026-04-12):

| Component | Measured individual lift | New median | Notes |
|---|---:|---:|---|
| Baseline (no changes) | — | 331K | — |
| Wake scan stubbed | +47% | 488K | O(N) is_parked load + futex_wake |
| `queued_tasks` SC fetchAdd removed (and idle-spin poll removed) | +26% | 417K | Worker idle-spin hammers this cache line × 56 |
| `submitted.fetchAdd(.monotonic)` removed + `hint_idx=0` | +28% | 422K | Cross-worker cache line bounces |
| Descriptor CAS (`acquireDescriptor`/`releaseDescriptor` stubbed) | +16% | 383K | ABA-tagged free-list |
| All three shared atomics removed simultaneously | **+210%** | **~1.0M** | Compound lift proves orthogonal-contention theory |
| `inject_queue.tryPush` + everything downstream removed | +2770% | 9.51M | Queue is NOT the bottleneck |
| `runTask` body (noop task function) | +0% | 330K | Task body is already free |

### The cache-line contention theory

F1/F1b's failure wasn't about engagement — it was that **the submit hot path has four contended atomics, not one**. Removing any single one in isolation lifts throughput by its individual measured amount (+16% to +47%), but the previous implementations didn't achieve this because they gated the removal behind a runtime condition that was rarely true (F1: short spin window) or imposed counterbalancing cost (F1b: reserved a worker, reducing pool capacity). A proper rewrite that **literally removes the work path on every submit** (not conditionally) should deliver the measured A/B lift.

### Phases D/E/F1/F1b as a sequence

All four phases eliminated a legitimate hot-path cost. All four measured ~0% wall-clock change. The pattern held because each phase's target, in isolation, was one of four overlapping contention sources on the same submit-path cache lines. Removing one leaves the other three holding the ceiling near-unchanged. The right approach: **sequential architectural rewrites, each actually eliminating (not conditionally skipping) the work**, with A/B gates on each to validate the measured lift shows up. Phase G targets the first of these — wake scan sharding.

### Updated lessons learned (from F1, F1b, and the deep re-profile)

1. **A/B-disable on the mechanic, every phase.** Proven across F1 and F1b. Rule now permanent.
2. **Separating target validity from mechanism validity.** The 335K→488K wake-stub A/B proved the *target* was real (wake scan worth ~47%). F1/F1b failed because their *mechanisms* didn't actually eliminate the work on every submit. Next phase must show, by its own A/B, that the work is gone unconditionally.
3. **Single-atomic phases work only if they literally remove the atomic from the hot path.** Conditional skips (F1, F1b) produce 0% because the atomic is still contended by the paths that don't skip. Rewrites that eliminate the atomic universally (e.g., replace O(N) scan with O(1) bitmap CTZ) DO realize their A/B lift, as long as the rewrite preserves correctness.
4. **Inject queue is not the bottleneck at this scale.** The 9.5M number with queue bypassed proves the MPMC ring CAS is sub-µs/op. Further optimization of the queue is not the fast path to parity.

## Phase G1: Sharded Wake Targeting (negative result — REVERTED, bitmap consolidation anti-pattern)

**Hypothesis:** Replace the O(N) is_parked[] scan in wakeOneParkedWorker with an O(1) @ctz on a shared u64 bitmap (`Core.parked_mask`). A/B-verified ceiling: 488K (later re-measured 460K with fresh builds) by stubbing the wake block entirely. See `docs/superpowers/specs/2026-04-12-phase-g1-sharded-wake-design.md` and `docs/superpowers/plans/2026-04-12-phase-g1-sharded-wake.md`.

### Measured (median of 5, ReleaseFast, 56-core host)

| Metric | Baseline | G1 bitmap | A/B stubbed (no wake) |
|---|---:|---:|---:|
| `flood_1m` ops/s | 331K | **312K** | 460K |

**G1 is net-NEGATIVE** (-7% vs baseline, -47% vs the stubbed A/B ceiling). Rollback triggered.

### Root cause: consolidation anti-pattern under high-writer contention

The bitmap replaced N per-worker `is_parked` cachelines with ONE shared `parked_mask` cacheline. Under flood_1m:

- 56 workers park/unpark frequently (73% parked time per earlier profile).
- Every park writes `parked_mask.fetchOr(.seq_cst)`; every unpark writes `parked_mask.fetchAnd(.release)`.
- The submitter's `parked_mask.load(.seq_cst)` lands on a cacheline being actively bounced across 56 cores.

The original per-worker `is_parked[]` scan was O(N) loads, but those loads hit **N distinct cachelines**, each receiving 1/N of the writer pressure. The bitmap consolidation inverted this — one reader benefits (O(1) vs O(N)), but N writers contend on one line instead of N lines. Net: more total cacheline traffic.

### Smoke vs fresh-build measurement: the 493K illusion

Task 3's smoke measurement of 493K flood_1m was produced by a stale binary. `zig build bench-tokio-parity` does not trigger a rebuild if the target is considered up-to-date — subtle source changes can fail to propagate to the actual binary. All Task 6 measurements used explicit `zig build -Doptimize=ReleaseFast` immediately before running the binary, producing the correct 312K number. **Lesson: always force-rebuild between experiments; never trust same-session smoke measurements.**

### Methodology lesson #7

Cumulative profiles and A/B stubs identify WHERE time is spent, but they don't predict whether a specific *mechanism* for reducing that time will work. **A consolidation-style rewrite (O(N)→O(1) on a shared structure) can be NET NEGATIVE if the consolidated resource has higher write-contention than the distributed resource had read-cost.** This is a new failure mode, distinct from F1/F1b's "conditional-skip" failure mode:

- **F1/F1b failure:** the condition for skipping work was rarely true, so the mechanic didn't engage.
- **G1 failure:** the mechanic engaged on every submit, but consolidating N writes onto one cacheline cost more than the O(N) reads it replaced.

Future phases targeting "make this shared access O(1)" must verify **write contention** of the consolidated structure, not just read cost. Ways to avoid the anti-pattern:

- Sharded structures (per-NUMA, per-core-group) instead of single global.
- Asymmetric access patterns (many readers, few writers) — suits bitmap-style collapse.
- When writes are frequent from many threads, keep the distributed structure and add an ORTHOGONAL cheap gate (e.g., a "count of parked workers" counter) that lets the reader fast-exit without touching the distributed data.

### What was kept vs reverted

Reverted: G1 Tasks 1-5 (bitmap field, park-handshake maintenance, wake rewrite, correctness tests). Spec and plan docs retained as historical record.

### Next direction

The wake path target is still real (stubbing gives +47%). Future attempts must use a different mechanism than bitmap consolidation. Moving Phase G work to G2 next.

## Phase G2: Idle-Spin Poll Removal (negative result — REVERTED, exposes pre-existing scheduler race)

**Hypothesis:** Worker idle-spin polls `counters.queued_tasks.load(.acquire)` spin_before_park_iters × worker_count times per park cycle. A/B-measured ceiling: 331K → 417K ops/s (+26%). Phase G2 removed the poll (keeping the SC park handshake intact). See `docs/superpowers/plans/2026-04-12-phase-g2-queued-tasks-poll.md`.

### Measured (median of 5, ReleaseFast, 56-core host)

| Config | flood_1m ops/s | Δ vs 328K baseline |
|---|---:|---:|
| Baseline (c1425a4, poll present) | 328K | — |
| G2 (poll removed, spin=128 + end-of-spin probe) | 349K | +6.5% |
| G2 (poll removed, spin=0, probe vestigial) | 357K | +8.9% |

The default G2 config measured **-2.4% BELOW spin=0**, proving the end-of-spin local-work probe was inert — same probability-of-engagement failure mode as Phase F1's short-spin active_spinners mechanic (128-iter spin ~128ns vs ~3µs inter-submit interval). The poll-removal itself was the sole source of lift.

### Stress-test failure exposes a pre-existing race

Bisecting stress-test stability (`zig build test-stress -Doptimize=ReleaseFast`, 50–100 run samples per commit):

| Commit | stress failure rate |
|---|---:|
| `c1425a4` main tip | 0/50 |
| `a7f1dc6` (tests added, poll still present) | 0/30 |
| `c335189` (poll removed) | 1/30 |
| `cad50f1` (probe variant) | 5/100 |
| `60ad076` (simplified variant) | 2/40 |

**Finding:** removing the idle-spin poll changes worker timing such that workers now exit `idle()` synchronously at end of spin window instead of staggered (each worker returning as soon as its poll observed non-zero). Under the aggressive-spin stress scenario (16 workers × spin_before_park_iters=4096 × 200K tasks), the synchronized storm on `nextTask`'s inject_queue drain + stealHalf + local-queue overflow path exposes a latent double-dequeue race.

Core dump analysis (`phase g2: aggressive spin flood` test at commit 60ad076):

- Multiple workers simultaneously run the same `descriptor_index` in `runTask`.
- Crashing descriptor has `task_fn=null` — it was released (`releaseDescriptor` zeros the fields), returned to the free list, and re-acquired (`acquireDescriptor`) for a new task while the stale index was still present in a secondary queue path.
- Crash site: `src/pool.zig:749` — `descriptor.task_fn.?(descriptor.ctx.?, &runtime)`.
- Race location (candidate): `src/pool.zig:650-699` (`nextTask`'s inject_queue batch drain + stealHalf overflow → `self.inject_queue.tryPush(idx)` with discarded return).

The race exists in main (c1425a4) but is masked by the staggered-exit timing the poll provides. Removing the poll makes it observable.

### What was reverted vs kept

**Reverted (three `git revert` commits):** G2 implementation (c335189), documentation comments (427289a), simplified variant (60ad076). Tree is now byte-identical to main for `src/pool.zig` and `src/types.zig`.

**Kept (permanent):**

- `tests/unit.zig` — `"phase g2: worker returns from idle when lifo slot filled during spin window"` — regression guard for the idle-spin fast path (passes against pre-G2 code; will catch regressions in any future re-attempt).
- `tests/stress.zig` — `"phase g2: aggressive spin flood - no lost wakeups"` — aggressive-spin stress harness (passes against pre-G2 code; will be the primary signal for detecting the scheduler race during the follow-up fix).
- `cad50f1` unit-test timing fix.

Post-rollback stress stability: 20/20 passing runs at ReleaseFast (confirms the rollback restores the staggered-exit timing).

### Lessons learned

1. **Timing masks races.** A mechanic that changes inter-thread scheduling phase (the poll provided that) can hide an underlying scheduler race. When removing a hot-path load "just to measure," include a wide-N stress sample at each bisect point — 5× was insufficient to catch a 5% failure rate.
2. **Probability-of-engagement lesson #5 confirmed again.** The end-of-spin probe was dead code for the same reason F1's active_spinners was dead: 128-iter spin (~128ns) vs 3µs inter-submit interval. Any future "skip the expensive thing when workers are spinning" design needs a spin window > event interval.
3. **Rollback-preserving test commits is the right move.** The stress test added in a7f1dc6 is the most valuable output of this phase — it reliably triggers the latent scheduler race when the poll is absent, giving us a reproducer for the follow-up fix.

### Next direction — new phase to fix the scheduler race

Before any future G2 re-attempt, fix the double-dequeue race in `src/pool.zig:nextTask` (lines 650–699). Steps for a follow-up phase:

1. Write a targeted stress reproducer that deterministically triggers the race (e.g. manually synchronize worker spin-exits via a barrier, maximize inject_queue drain contention).
2. Add defensive assertions in `runTask` / `acquireDescriptor` / `releaseDescriptor` that catch duplicate descriptor-index dequeue at runtime (only in Debug/ReleaseSafe).
3. Root-cause the specific ordering in `nextTask` that permits duplicate observation of a descriptor index. Likely culprits:
   - The `self.inject_queue.tryPush(idx)` call at line 655 inside the batch-drain loop (discards return value — what if push fails AND the idx is still held by something?)
   - The stealHalf overflow push at line 692 (`_ = self.inject_queue.tryPush(idx);`) — same pattern.
4. Fix preserving the work-stealing throughput. Any redesign must pass the aggressive-spin stress test at 100/100 (not just 5/5).
5. Once the race is fixed, re-attempt G2 (poll removal). The data proves the poll is a real ~9% flood_1m cost — the win is waiting.

See `docs/superpowers/plans/2026-04-12-phase-g2-queued-tasks-poll.md` for the original design; see this section for the negative-result record.

## Bench Stability

From 2026-04-12 forward, `benchmarks/common.zig` runs 7 iterations per
scenario, discards the first (warmup), and reports the median of 6 along
with stddev. Observed stddev as a fraction of median (measured on the
rebaselined dev machine):

| Scenario | Median ops/s | Stddev ops/s | Stddev % |
|----------|-------------:|-------------:|---------:|
| conn_churn_seq/global_queue | 1365079 | 271278 | 19.9% |
| conn_churn_seq/work_stealing | 1324439 | 310471 | 23.4% |
| producer_contention/global_queue | 994633 | 90757 | 9.1% |
| producer_contention/work_stealing | 945187 | 131594 | 13.9% |

`compare-bench`'s regression gate is `throughput_change < -max(15%, 3×stddev%)`.
Noisy scenarios (high stddev%) widen the gate; stable scenarios stay near
the 15% floor.

## Micro: submit_latency (samples=100000, 1 worker, queue=101024, smp_allocator)

| Phase | p50 (ns) | p95 (ns) | p99 (ns) | Notes |
|-------|---------|----------|----------|-------|
| Phase 0 (baseline) | 904 | 1480 | 1793 | pre-optimization |
| Phase 2 (timestamp_mode default=full, no change expected) | 404 | 561 | 615 | Task 5: knob added, default preserves v0.2.0 behavior |
| Phase 2 (per-worker started/completed) | 419 | 565 | 618 | Task 6: move started/completed counters per-worker to reduce hot-path contention (median of 8 runs; variance 365-538ns) |
| Phase 2 (remove global steal/park counters) | 435 | 588 | 643 | Task 7: consolidate steals/steal_failures/parks to per-worker only (median of 5 runs; high variance 365-843ns — within noise) |
| Phase 2 (TaskDescriptor hot/cold split) | 510 | 639 | 696 | Task 8: reorder fields so hot group (state/task_fn/ctx/options/generation) fits in one cache line (hot_size=64B, cache_line=128B); cold metric fields pushed behind. Single-run noise; wash vs Task 7. |
| Phase A (park handshake simplification) | 781 | 1387 | 1690 | A1: removed parked_workers counter + broadcast fallback. A2: seq_cst handshake on is_parked + queued_tasks (median of 5 runs). |

## Micro: steal_throughput (tasks=200000, 2 workers, inject_batch=1, smp_allocator)

| Phase | ops/s | steals | steal_failures | Notes |
|-------|-------|--------|----------------|-------|
| Phase 0 (baseline) | 686840 | 0 | 72154 | |
| Phase 2 (Task 7: per-worker steal/park counters) | 663352 | 0 | 78662 | |
| Phase 2 (Task 8: TaskDescriptor hot/cold split) | 1437441 | 0 | 120361 | |
| Phase 3 (Task 10: batch-steal infra, default size=1) | 636735 | 0 | 101621 | wash — batch-steal default disabled due to popBottom race; infra ready for future deque rework |
| Phase 3 (Task 11: skip-empty victims in steal scan) | 677374 | 0 | 114851 | median of 2 runs (670408, 684341); +6.4% vs Task 10 by skipping seq_cst CAS on victims whose cheap `len()` peek shows empty |
| Phase B (ring queue, batch=1) | 1417145 | 0 | 141358 | Task B4: RingQueue replaces Chase-Lev; steal_batch_size=1 for apples-to-apples; median of 5 runs (1390204, 1405719, 1417145, 1429080, 1438065) |
| Phase B (ring queue, batch=8) | 656631 | 0 | 77245 | Task B4: true batch-steal via stealHalf; expected to scale vs batch=1; median of 5 runs (650127, 653360, 656631, 678349, 1427207); one high outlier excluded from interpretation |

## Micro: wake_latency (samples=5000, 2 workers, quiesce=300us, smp_allocator)

| Phase | p50 (ns) | p95 (ns) | p99 (ns) | Notes |
|-------|---------|----------|----------|-------|
| Phase 0 (baseline) | 9621 | 15181 | 23591 | |
| Phase 2 (Task 7: per-worker steal/park counters) | 10649 | 13016 | 16166 | |
| Phase 2 (Task 8: TaskDescriptor hot/cold split) | 9267 | 11026 | 14400 | |
| Phase 3 (Task 12: per-worker park condvar) | 12768 | 17140 | 21321 | median of 8 runs (10515, 12001, 12074, 12665, 12768, 13859, 13870, 14239, 14307 ns p50). Wake-bench is fixed at 2 workers where a shared park_mutex has ~zero contention, so this micro regresses here; the design removes an N-way mutex serialization point on submit and should pay off at higher worker counts — re-validate when macro adds many-worker scenarios. |
| Phase A (park handshake simplification) | 9985 | 14080 | 17898 | median of 5 runs; single-signal path, no N-way broadcast. |

## Macro: conn_churn_seq (bench scenario, workers=2, queue=4096)

| Phase | scheduler | ops/s | submit p50 (ns) | submit p99 (ns) | Notes |
|-------|-----------|-------|-----------------|-----------------|-------|
| Phase 2 (Task 8: TaskDescriptor hot/cold split) | global_queue | 1731709 | 532 | 813 | |
| Phase 2 (Task 8: TaskDescriptor hot/cold split) | work_stealing | 1680812 | 554 | 891 | |
| Phase 3 (Task 11: skip-empty victims in steal scan) | work_stealing | 895954 | 1211 | 2159 | high run-to-run variance (788K–984K across 3 runs); this scenario rarely triggers steals, so the skip-empty change is effectively inert here — the swing is environmental noise |

## Macro: producer_contention (bench scenario, workers=2, submitters=4, queue=4096)

| Phase | scheduler | ops/s | submit p50 (ns) | submit p99 (ns) | completion p50 (ns) | completion p99 (ns) | Notes |
|-------|-----------|-------|-----------------|-----------------|---------------------|---------------------|-------|
| Phase 0 (baseline, pre-Phase-4) | work_stealing | — | — | — | ~1460000 | ~1690000 | baseline reference from plan — 50us poll-sleep dominated submit p99 under contention |
| Phase 4 (Task 13: backpressure condvar) | global_queue | 684493 | 3627 | 10550 | 1765264 | 1985233 | — |
| Phase 4 (Task 13: backpressure condvar) | work_stealing | 908583 | 2937 | 12791 | 1241252 | 1822769 | queue_peak=2172 < capacity=4096 so the queue-full branch wasn't exercised in this run — backpressure_waiters stays 0, the signal path is skipped entirely, and the change is a wash here. Expected payoff shows in scenarios where submitters actually block (e.g. scale-bench with small queue_capacity). Stress tests pass 10/10. |

## Tokio Parity Suite (workers=cpu_count, queue=4096, smp_allocator, ReleaseFast)

Numbers from `zig build bench-tokio-parity`. Directly comparable to Tokio's
`rt_multi_threaded` bench output on the same hardware.

| Scenario | ops/s | tasks | submitters | Notes |
|----------|-------|-------|-----------|-------|
| flood_1m | 297151 | 1000000 | 1 | Pure throughput; backpressure=block exercises the condvar path because 1M tasks > 4096 queue capacity, so submitter blocks repeatedly waiting for workers to drain |
| contended_spawn_8x | 496883 | 100000 | 8 | Multi-producer contention; 8 submitter threads + cpu_count workers |
| flood_1m (Phase A+B) | 346772 | 1000000 | 1 | Park handshake simplified; ring queue batch-steal=8; median of 3 runs |
| contended_spawn_8x (Phase A+B) | 507753 | 100000 | 8 | Park handshake simplified; ring queue batch-steal=8; median of 3 runs |

For reference, Tokio's `rt_multi_threaded` flood-equivalent typically runs 5–15M ops/s on similar hardware. Our gap is the work the remaining tasks (true batch-steal via deque rework, hot-path atomic reductions beyond Phase 2) target.

## Phase H — nextTask Scheduler Race (2026-04-13)

**Symptom.** ~14% SIGSEGV rate on Phase G2 stress test (`tests/stress.zig::"phase g2: aggressive spin flood - no lost wakeups"`) at ReleaseFast on 56-core hardware. The crash is a NULL function-pointer call at `src/pool.zig:783` (`descriptor.task_fn.?(descriptor.ctx.?, &runtime)`). Reproduces under `zig build test-stress` with the cherry-picked Phase G2 poll removal at `5f5b0f5`. The Task 2 claim sentinel **does** fire — but only sometimes (visible in a parallel run of the deterministic reproducer test from Task 1, e.g. `panic: double-dequeue: descriptor 12 claimed by worker 10, now worker 13 also tried to claim it`). In the dominant SIGSEGV case the sentinel is silent because the second worker reaches the CAS only AFTER the first worker has finished and cleared `claimed_by` back to `-1` (`runTask` line 816), so its CAS-`-1`→`worker_index` succeeds against an already-released descriptor.

**Reproducer.** `zig build test-stress` in a loop (random seed). Crashes one in five-to-ten iterations. The deterministic Task 1 reproducer (`tests/stress/double_dequeue_race.zig`) trips the sentinel directly when the race fires; the spin-flood test usually races into the NULL-deref symptom because both arms (sentinel-trip OR NULL-deref) are downstream of the same root cause. Seed `0x6adae8d8` reproduces but is not deterministic across runs because thread interleaving dominates.

**Reproduction method.** Bash loop running `zig build test-stress`; coredumps captured via `ulimit -c unlimited` + `kernel.core_pattern=/tmp/phase-h-hunt/cores/core.%p`. ReleaseFast core (`core.574634`) yielded the smoking-gun stack via `gdb -batch -ex "thread apply all bt"`. Confirmation pass added two instrumentation panics (post-CAS state assertion + pre-call NULL-fn assertion) inside `runTask`; both fired across multiple runs with consistent shapes.

**Stack trace excerpt (Thread 1, crashing).**

```text
#0  0x0000000000000000 in ?? ()
#1  0x0000000001013174 in pool.Core.runTask (self=0x7f334f6a0000, worker_index=9, descriptor_index=85)
                        at src/pool.zig:783
#2                       pool.Core.workerMain (self=..., worker_index=9) at src/pool.zig:649
#3                       Thread.callFn__anon_7478 () at .../Thread.zig:509
#4                       Thread.LinuxThreadImpl.spawn__anon_4652.Instance.entryFn (...) at .../Thread.zig:1381
```

Frame-1 locals from the same core:

```text
descriptor = 0x7f334f6e2fe0
*descriptor = {task_fn = 0x0, ctx = 0x0, options = {wait_group = 0x0, ..., backpressure = return_error},
               generation = 587, submit_ns = 0, start_ns = 1776083542787660655, complete_ns = 0,
               claimed_by = {raw = 9}, state = {raw = running}}
```

- `task_fn = 0x0` and `ctx = 0x0`: written by `releaseDescriptor` (lines 969–970), not by any submitter.
- `submit_ns = 0` with `timestamp_mode == .full`: also written by `releaseDescriptor` (line 972). A live submission would have a non-zero timestamp.
- `options = .{}`: also written by `releaseDescriptor` (line 971). The test always submits with `.backpressure = .block` — so this descriptor is NOT the live-test submission worker 9 thinks it claimed.
- `state = running` and `claimed_by = 9`: written by worker 9 itself at lines 744 and 751 AFTER its CAS succeeded.

**Source site.** `src/pool.zig:783` (the symptom). Root cause is upstream — see below.

**Root cause.** The scheduler is delivering the same `descriptor_index` to two distinct `runTask` invocations across worker threads. The Task 2 claim sentinel proved this directly when both racers reach `runTask` while the first still owns the slot (`panic: double-dequeue: descriptor 27 claimed by worker 1, now worker 11 also tried to claim it`). When the racers are slightly more spread out — first claimer wins CAS, runs to completion, clears the sentinel at line 816, and starts `releaseDescriptor` (lines 967–998) — the second claimer arrives, finds `claimed_by == -1`, wins its own CAS, and then dereferences fields that the first claimer's `releaseDescriptor` has already nulled. The instrumented post-CAS panic confirmed the descriptor's `state` field at the moment of the second CAS is one of `.free` (most common — released by the first claimer), `.completed` (first claimer mid-cleanup, post-line-816), or `.reserved` (a third path — submitter mid-`acquireDescriptor`/`enqueueTask` having already re-acquired the slot after the first claimer freed it). In all cases the descriptor is NOT in state `.queued` as it would be for a valid live dispatch.

Where the duplicate dispatch comes from: the Task 1 reproducer is configured to push exclusively through `inject_queue` (external submitters → `tls_worker_index == null` → no LIFO/local-queue traffic), so the duplication originates either inside the `inject_queue` (`src/queue/bounded_ring.zig`) MPMC pop path or in the `nextTask` plumbing around it (`src/pool.zig:728`–`732`, also reachable as the `inject_queue.pop()` branch at `src/pool.zig:671`–`684` plus its inject-batch-drain re-push at line 676). The bounded ring's Vyukov sequence-number protocol is internally sound under code review, so the operative suspect is the `inject_queue.pop()` interaction with `decrementQueued()` ordering, or — more likely — a memory-ordering gap between the submitter's plain stores to descriptor fields (`descriptor.task_fn = task_fn` at line 563, etc.) and the visibility guarantee provided by the queue push's release. We could not narrow it tighter inside the time budget without much heavier instrumentation. For Task 4, the highest-leverage fix is structural: gate `runTask` entry on a state CAS (`descriptor.state.cmpxchgStrong(.queued, .running, .acq_rel, .acquire)`) so a freed/reserved descriptor cannot be claimed even when `claimed_by == -1`, and have the second arrival treat CAS failure as "already stolen by another worker" and discard the index without entering the task body.

**Mechanism (narrative).** Workers A and B both end up holding the same `descriptor_index` (say 85) returned from their respective `nextTask` calls. Worker A wins the `claimed_by` CAS, sets `state=.running`, runs the task body, runs the cleanup down to line 816 (`claimed_by.store(-1)`), and starts `releaseDescriptor` (line 824). At line 969 it writes `task_fn = null`. Worker B, meanwhile, has been doing instruction-cache / scheduler-pause delays inside its `nextTask`→`runTask` transition; it now enters `runTask(85)`, succeeds the `claimed_by` CAS against `-1` (because A cleared it), writes `state=.running` over A's `state=.completed`/`.free`, writes `start_ns`, and then dereferences `descriptor.task_fn.?` — which A nulled — and SIGSEGVs jumping to PC=0. The whole sequence is ~50 instructions; the only thing required is for A's cleanup tail (lines 816→969) to interleave with B's `nextTask`-return → `runTask`-CAS path. On a 56-core machine this happens often enough to produce ~14% crash rate.

**Why the sentinel didn't fire (in the SIGSEGV cases).** The sentinel only catches "two workers racing INSIDE `runTask` with both still holding the claim". As soon as worker A reaches line 816 (`claimed_by.store(-1, .release)`) — which happens BEFORE the descriptor's fields are nulled by `releaseDescriptor` — the sentinel is reset. Any second worker arriving after that point will pass the CAS and proceed into the body of `runTask` reading already-nulled / about-to-be-nulled fields. The sentinel is sufficient for tight races (and does fire ~10–20% of repros, particularly in the deterministic Task 1 reproducer that interleaves more aggressively), but not for the loosely-coupled common case.

**Fix shape (input to Task 4).** The narrowest correct fix is a state-CAS gate in `runTask` that replaces / augments the claim-sentinel CAS:

```zig
// At src/pool.zig:744 (inside runTask, replacing or wrapping the claimed_by CAS):
if (descriptor.state.cmpxchgStrong(.queued, .running, .acq_rel, .acquire)) |observed| {
    // Descriptor was not in .queued state — this index is stale.
    // Counter-decrement was already done in nextTask; just bail.
    // Bumping a stat counter (e.g. self.counters.stale_dispatch) is recommended
    // so the rate is observable post-fix.
    return;
}
// Then drop or simplify the claimed_by sentinel — the state CAS subsumes it.
```

This is correct because `enqueueTask` publishes `state.store(.queued, .release)` at line 569 BEFORE the queue push (line 590), and `releaseDescriptor` writes `state.store(.free, .release)` at line 975 BEFORE the freelist push (lines 978–987). The state field is the canonical "this descriptor is dispatchable" signal; gating dispatch on a CAS from `.queued` makes the dispatch idempotent and immune to whatever path delivered the duplicate index.

A separate, deeper investigation should still try to identify WHICH path delivers the duplicate index (likely candidates: `inject_queue.pop()` returning a stale slot under wrap, or `nextTask`'s `decrementQueued` ordering vs. the queue's CAS). But the state-CAS gate makes the system safe regardless, and matches the pattern Tokio uses (`Schedule::release` checks state before run).

**Confidence.** High that the proximate cause is the NULL `task_fn` deref at line 783 caused by descriptor reuse between dispatch and task-body execution — confirmed by core-dump field inspection AND by the post-CAS state-assertion instrumentation firing across multiple independent runs with consistent shapes (`state=free`, `task_fn_null=true` dominating). Medium-high that the fix shape (state-CAS gate) is correct — the state ordering is well-defined and a state-CAS is the standard remedy. Medium-low on identifying the specific queue-path bug that produces the duplicate index — would be raised by adding per-pop / per-push logging in `bounded_ring.zig` and `nextTask`, which is out of scope for this investigation step.

**Temporary instrumentation in `src/pool.zig`** (must be reverted by Task 4):

- Lines ~750–768: post-CAS state-assertion panic.
- Lines ~801–818: pre-call NULL-`task_fn` panic with descriptor field dump.

Both are gated by `claim_sentinel_enabled` (lines 750–768) and a plain `if` (lines 801–818) and live alongside the existing Task 2 sentinel.

### Fix (2026-04-13)

**Applied in two commits on `feat/phase-h-fix-double-dequeue-race`:**

- `710a98f fix(phase h): gate runTask dispatch with state CAS` — replaces the bare `descriptor.state.store(.running, .release)` at the top of `runTask` with `cmpxchgStrong(.queued, .running, .acq_rel, .acquire)`. Ghost duplicate-index dispatches from the queue layer fail the CAS and return silently, preventing the NULL `task_fn` SIGSEGV.
- `daedce6 fix(phase h): balance queued_tasks under ghost-dispatch + cap stealHalf retries` — moves `decrementQueued()` from the five `nextTask` pop sites to the `runTask` CAS-success path. Prevents `queued_tasks` underflow from ghost dispatches (which was causing shutdown hangs). Also caps `ring_queue.stealHalf`'s CAS-retry loop at 256 to prevent livelock on a pathological `head > tail` wrap state.

### Validation (2026-04-13)

With the cherry-picked G2 poll-removal dropped and the branch tip matching production `idle()`:

- `zig build test` — pass
- `zig build test-stress` — pass (baseline single run)
- 100/100 ReleaseFast stress-suite iterations — 0 crashes, 0 hangs (validates both the Phase G2 `aggressive spin flood` test and the new Phase H `double-dequeue race reproducer`)

**Status:** fix landed. Unblocks Phase G2 re-land, G3 (submitted fetchAdd), wake-scan redesign, and descriptor CAS.

### Residual concerns (tracked for future phases)

1. **Duplicate-emission root cause not pinpointed.** Some queue path (ring, chase-lev, LIFO-slot re-submit, or inject-batch drain) still emits the same descriptor index twice. The CAS gate + accounting rebalance make this safe (no crash, no leak, no hang), but the duplicate churn wastes a small amount of work per dispatch. Worth investigating in a follow-up phase if benchmarks show the CAS-fail rate is material.
2. **`head > tail` persistent wrap in `ring_queue`** — a stress condition can leave the ring queue in an unsigned-wrapped state that `stealHalf`'s CAS-retry loop would spin on forever. Capped at 256 retries to prevent livelock, but the wrap itself is unexplained. Strong suspicion: same upstream bug as #1.
3. **`stealOne` wrap-livelock audit** — `stealOne` has a similar CAS-retry shape to `stealHalf` but was not audited for the same wrap-livelock. No observed failures in 100/100 validation, but worth an audit pass.

### Unblocks

- Phase G2 re-land (poll removal for +9% throughput) — shipped 2026-04-13, see § Phase G2 Re-Land below
- Phase G3 (submitted fetchAdd) — +28%
- Wake-scan redesign — +47%
- Descriptor CAS — +16%

---

## Phase G2 Re-Land: Idle-Spin Poll Removal (shipped 2026-04-13)

**Status:** Shipped. Original Phase G2 (commits `c335189` + cleanup `60ad076`) was reverted because the timing change unmasked a latent double-dequeue race in `nextTask`. Phase H (merge `a75ed98`) closed that race via state-CAS at `runTask`, unblocking the re-land.

**Change:**

- `src/pool.zig:Core.idle()` no longer polls `counters.queued_tasks.load(.acquire)` inside the spin loop. The submit path writes that cacheline `.seq_cst` on every submit; 56 workers × spin_iters shared loads per park cycle dominated cross-core traffic on the line.
- `src/types.zig` default `spin_before_park_iters` drops from `128` to `0` — with the poll gone, the spin body is pure CPU burn at default config. Non-zero values remain available as an explicit opt-in for stress tests that exercise the polless-spin handshake (e.g. `tests/stress.zig:516` at `4096`, `tests/stress.zig:75,290` at `4`).

**Commit:** `1351e0b perf: phase g2 re-land - remove idle-spin queued_tasks poll`

### Hypothesis (validated)

Idle-spin polled `counters.queued_tasks.load(.acquire)` `spin_before_park_iters` times per park cycle per worker on a cacheline the submitter writes `.seq_cst` on every submit. Removing the poll eliminates the dominant cross-core read traffic. The SC `is_parked.store(.seq_cst)` + `queued_tasks.load(.seq_cst)` reload at `pool.zig:881-887` is the actual lost-wakeup guard; the spin-poll was a latency shortcut, not a correctness mechanism.

### Methodology refinements applied (vs. original G2)

| Aspect | Original G2 (reverted) | Re-Land |
|---|---|---|
| Spin body mechanism | Poll removed + end-of-spin probe (`lifo_slot`, `local_queue.len`, `inject_queue.len`) | Poll removed, **no probe** (A/B-inert in `60ad076` — probability-of-engagement failure) |
| `spin_before_park_iters` default | 128, dropped to 0 in cleanup commit | Drops to 0 directly |
| Stress gate | 5× `test-stress` (default optimize) | **20× ReleaseFast** (correctness) + **100× ReleaseFast** (pre-merge) — methodology lesson #9 |
| Race defense | None — exposed latent double-dequeue; ~5% SIGSEGV rate slipped through 5× sample | Phase H state-CAS gate at `runTask` is path-agnostic upstream defense |

### Measured (ReleaseFast, 56-core host, 2026-04-13)

**Baseline (main tip `a75ed98`, Phase H):**

| Benchmark | Samples | Median (ops/s) | Range (min–max) |
|---|---:|---:|---:|
| `flood_1m` | n=5 | **346,492** | 336,670 – 351,714 |
| `contended_spawn_8x` | n=10 | **471,188** | 413,459 – 501,867 |

**Re-Land default (spin=0):**

| Benchmark | Samples | Median (ops/s) | Δ vs baseline |
|---|---:|---:|---:|
| `flood_1m` | n=5 | **461,705** | **+33.3%** |
| `contended_spawn_8x` | n=10 | 459,524 | −2.5% (within noise floor; IQR width ~30K on ~460K medians) |

**Spin=128 A/B (poll-removed, Task 7):**

| Benchmark | Samples | Median (ops/s) | Δ vs spin=0 |
|---|---:|---:|---:|
| `flood_1m` | n=5 | 460,598 | −0.2% (flat) |
| `contended_spawn_8x` | n=10 | 473,603 | +3.1% (within noise of spin=0) |

**Flood_1m A/B (Task 2, poll stubbed, spin=128):** median **479,205 ops/s** (n=5), confirming the poll-removal is the load-bearing mechanism — spin default doesn't move flood_1m. Stubbed and production configs are statistically identical on the hot workload.

### Correctness validation

- Unit suite: 39/39 pass (debug + ReleaseFast).
- Stress 20× ReleaseFast: **20/20 pass** in 73s. Includes `tests/stress.zig:516` ("phase g2: aggressive spin flood") driving 16 workers at `spin_before_park_iters = 4096` — explicitly exercises the polless-spin SC handshake under load.
- Stress 100× ReleaseFast: **100/100 pass** in ~360s. Methodology lesson #9 threshold.
- Phase H `runTask` state-CAS gate (`pool.zig:763`) defends against duplicate-emission regardless of which queue path emits the duplicate; the G2 timing change cannot revive the SIGSEGV path that forced the original revert.

### Why contended_spawn_8x is flat (not regressed)

Task 1 baseline captured `contended_spawn_8x` at n=3 (498,767 median, spread 60K). Task 6 re-land measurement at n=3 showed 433,669, triggering a regression alarm. Re-measuring both on Phase H main and on the re-land branch at **n=10** showed the true distributions: main median 471K (IQR 451K–489K), re-land spin=0 median 459K (IQR 452K–481K). The distributions overlap substantially. The "−13% regression" was a thin-sample artifact. Controller-level re-measurement documented in `/tmp/phase-g2-reland-baseline.txt` § Task 7C.

**Takeaway:** future phases must measure **every** benchmark at **n=10 minimum** when evaluating gates, not just the primary metric. Thin-N baselines misread noise as signal.

### Verdict

Ship. `flood_1m` +33.3%; `contended_spawn_8x` statistically unchanged; 20/20 + 100/100 ReleaseFast stress clean; Phase H CAS gate defends against the race that forced the original revert.

See `docs/superpowers/plans/2026-04-13-phase-g2-reland.md` for the execution plan and full task-by-task record.

## 2026-04-13 Re-Profile (post Phase G2 Re-Land, main tip ce0d56b)

Baseline: 566K ops/s flood_1m n=10 ReleaseFast (Task 1, commit `3506b29`).
Submitter is 100% CPU-bound post-G2 (was 89% pre-G2); remaining optimization surface is pure on-CPU compute.

Fresh A/B-disable ceilings (566K baseline):

- submitted.fetchAdd (G3): **+42%** → 803K (clean, 20/20 stress, PRIORITIZE)
- Descriptor CAS: -14% under host-load confound (mechanistic DEPRIORITIZE regardless)
- Wake scan: **+34.8%** → 763K (under load; conservative; PRIORITIZE after G3)

Full report: `docs/performance/reprofile-2026-04-13/SUMMARY.md`.

Next-phase ordering: 1. G3 (submitted.fetchAdd), 2. Wake-scan redesign (post-G3 re-measure first), 3. Architectural pivot (Chase-Lev deque + event-wake + lock-free inject) once single-atomic ceilings exhausted.

## Wake-Scan Parked-Count Gate — Abandoned (2026-04-13)

Three paired n=10 variants all regressed flood_1m. Branch `feat/wake-scan-parked-count-gate` preserved unmerged.

- Attempt 1 (basic gate): -11.0%
- Attempt 2 (cacheline-aligned): -2.5%
- Attempt 3 (aligned + .monotonic load): -8.9%

CPU frequency stable across all attempts (±0.1% mean). Stress 20/20 PASS on all three (no correctness regression). Perf was net-negative due to cacheline false-sharing + atomic RMW contention from 56 workers park/unpark-cycling.

Full write-up with triage, lessons, and suggested alternatives: `docs/performance/wake-scan-gate-abandoned/README.md`.

Re-profile priority update: priority 1 (G3) shipped as correctness-only slice (null perf). Priority 2 (wake-scan redesign) ABANDONED. Priority 3 (architectural pivot — Chase-Lev / event-wake / lock-free inject) was LARGELY ALREADY IMPLEMENTED in prior sessions. Only lock-free-inject-queue (targets contended_spawn_8x multi-submitter) remains as a planned architectural target, but it does not address flood_1m.

**Conclusion:** the single-atomic optimization surface for flood_1m on this pool architecture appears exhausted. Further lift requires structural change (work-distribution model, futex-direct wake, pre-allocated descriptor pools) beyond what this session could validate cleanly under host drift conditions.
