# Performance Gap Analysis

Last updated: 2026-04-16

## Summary

Two tracks:

- **Historical PERF-### cohort** (2026-04-11 baseline): micro-opt and false-sharing work, mostly closed. Preserved verbatim below for audit continuity.
- **2026-04-16 adversarial perf review cohort** (`P-##`, `R-##`): pivot-axis findings (tail latency / lanes / memory / observability / methodology) filed against the declared throughput plateau. Raw input: `.cache/audit/perf-reviewed.json`.

Plateau verdict (per `project_throughput_plateau_pivot.md`): throughput plateau on `flood_1m_batched` is architectural — 5 consecutive iter failures on the notifySubmits/state-load plane (iter7 bitmap, iter8 single-probe, iter9 isolation, iter10 shouldExit, iter11 active_tasks shard). **Throughput micro-opts against the plateau are filtered/demoted.** Pivot axes: tail latency, lanes, memory, API, observability, methodology.

### Cohort counts (2026-04-16 adversarial review)

| PerfSeverity | Count | Filed | Tracked in cluster | Filtered / Demoted |
|---|---|---|---|---|
| P0 | 1 | 1 (doc-only P-05) | -- | 0 |
| P1 | 9 | 5 individual + 2 trackers | -- | 0 |
| P2 | 10 | 4 individual | 3 in trackers | 3 (P-06 ARM-defer, P-10, P-12) |
| P3 | 3 | 0 | -- | 3 (P-07/P-08 confirm-only, P-14 dup of PERF-028) |
| **Total** | **23** | **12 issues created** | **5 sub-tasks clustered** | **6 filtered** |

Filtered per plateau-pivot rule: **P-04** (scanAndWake TLS hint, speculative throughput), **P-06** (ARM-only defer), **P-10** (watchdog scan cost, borderline), **P-12** (releaseSubmitter spin, submitter-churn only), **P-07/P-08** (confirm-only), **P-14** (duplicate of existing PERF-028). Six total.

### Top 5 Risks (2026-04-16 cohort, by PerfScore + pivot-axis relevance)

1. **PERF-METHODOLOGY** (P1, PerfScore 100) -- Benchmark methodology hardening tracker. `.full` timestamp_mode + `queue_capacity=4096` + `backpressure=.block` in `flood_1m` means the published runtime-compare table may not be apples-to-apples vs Tokio/Go. Issue #36.
2. ~~**PERF-OBSERVABILITY** (P1, PerfScore 80)~~ — **Closed 2026-04-16** (6 commits: `3356d1d` R-01, `a39092a` R-02, `7c9d2e6` R-03, `5561a46` R-06, `e75f4e0` R-10, `f1e7b67` doc sync). Issue #46.
3. **PERF-P-09** (P1, PerfScore 64) — **Partial 2026-04-16** (`c9a05e8`): `-Dtimestamp-mode` + `-Dscheduler-variant` landed; `-Dqueue-kind` + `-Dlane-extension` deferred. Issue #73 remains open with reduced scope.
4. **PERF-P-11** (P1, PerfScore 48) -- Pool-wide `completion_mutex` + broadcast on waitable tasks. Dormant today but a production-user foot-gun; pairs with R-09 scoped-wait API. Issue #79.
5. **PERF-P-01** (P1, PerfScore 48) -- `RingQueue` head/tail share a cacheline. Default `queue_kind`, so every `LocalQueue` pays unpaid cross-core coherence on every owner push + stealer CAS. Issue #55.

### Baselines (measured 2026-04-11)

| Scenario | Scheduler | Ops/s | RSS |
|---|---|---|---|
| conn_churn_seq (2 workers, 4096 tasks, 1 submitter) | global_queue | 1,500,199 | 260 KB |
| conn_churn_seq (2 workers, 4096 tasks, 1 submitter) | work_stealing | 1,870,000 | 295 KB |
| producer_contention (2 workers, 4096 tasks, 4 submitters) | global_queue | 502,242 | 348 KB |
| producer_contention (2 workers, 4096 tasks, 4 submitters) | work_stealing | 396,748 | 401 KB |

### Scalability Projection

At 64 workers with trivial tasks, throughput will likely plateau due to:

- ~~BoundedRing head/tail false sharing: cache-line bouncing scales with producer count~~ -- Fixed: commit ca1b0a4
- ~~Counters struct false sharing: every atomic write invalidates shared lines across all cores~~ -- Fixed: commit 37fbd6a
- Global counter duplication: ~10 atomics per task on shared counters, many redundant
- ~~completion_mutex broadcast in cancelDescriptor: O(M) contention on cancel paths~~ -- Fixed: commit 3299728
- Single-item steal: O(N) steal scans return only 1 task, starving workers at scale

---

## 2026-04-16 Adversarial Perf Review Cohort

Input: `.cache/audit/perf-reviewed.json` (23 findings; P0=1, P1=9, P2=10, P3=3). All issues on GitLab `devnw/zig/thread-pool`.

### Stack-ranked (pivot-axis findings)

| Rank | Sev | PerfScore | ID | Finding | Component | Evidence | Measurement | Issue | Fix Summary | Owner | SLA | Status |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 1 | P1 | 100 | P-15/R-05/R-08/R-12/R-14 | Benchmark methodology hardening (tracker) | bench, scripts, docs | `runtime_compare_zig.zig:306-313,428-434`; `types.zig:187` | Re-run parity preset; stddev; new scenarios | [#36](https://gitlab.com/devnw/zig/thread-pool/-/work_items/36) | Parity preset; env gating; n=15 warmup=3; new scenarios | @benjiv | Within sprint | Open |
| 2 | P1 | 80 | R-01/R-02/R-03/R-06/R-10 | Observability pivot (tracker) | stats, pool, docs | `stats/latency.zig:66-78`; `pool.zig:204-255` | per-lane p99, wake-latency p99, mem budget, offset dump | [#46](https://gitlab.com/devnw/zig/thread-pool/-/work_items/46) | p999/p9999; per-lane hist; wake-latency hist; memory budget; layout doc | @benjiv | Within sprint / Next quarter | **Closed 2026-04-16** (5 commits: 3356d1d R-01, a39092a R-02, 7c9d2e6 R-03, 5561a46 R-06, e75f4e0 R-10) |
| 3 | P1 | 64 | P-09 | Comptime elision flags | build, types, pool | `types.zig:82,115-116,187`; `pool.zig:995,1589,1606,1640` | Build-matrix A/B | [#73](https://gitlab.com/devnw/zig/thread-pool/-/work_items/73) | `-Dtimestamp-mode` + `-Dscheduler-variant` landed; `-Dqueue-kind` + `-Dlane-extension` deferred | @benjiv | Within sprint | **Partially Closed 2026-04-16** |
| 4 | P1 | 48 | P-01 | RingQueue head/tail false sharing (default queue_kind) | queue | `ring_queue.zig:30-31` | n=20 paired on `nested_fanout_4x`, `contended_cpu_10us` | [#55](https://gitlab.com/devnw/zig/thread-pool/-/work_items/55) | Mirror `BoundedRing` `_pad_head` layout | @benjiv | Within sprint | Open |
| 5 | P1 | 48 | P-03 | Worker struct layout audit | pool | `pool.zig:204-255` | Comptime offset dump + paired A/B | [#64](https://gitlab.com/devnw/zig/thread-pool/-/work_items/64) | Full `@offsetOf` pass before any layout shift | @benjiv | Within sprint | Open |
| 6 | P1 | 48 | P-11 | Waitable completion pool-wide mutex + broadcast | pool | `pool.zig:1653-1670` | 100K waitable bench; waiter-count 4 | [#79](https://gitlab.com/devnw/zig/thread-pool/-/work_items/79) | Per-descriptor condvar lazy-alloc | @benjiv | Within sprint | Open |
| 7 | P1 | 48 | R-13 | Validate `watchdog_interval_ns` extremes | types, pool | `pool.zig:1176-1202` | Unit tests + oscillation bench | [#84](https://gitlab.com/devnw/zig/thread-pool/-/work_items/84) | Reject sub-100us interval; warn >1s | @benjiv | Within sprint | Open |
| 8 | P2 | 36 | R-09 | `waitForCompletion(handle, timeout)` API | pool, types | `pool.zig:1653-1670` | 1M single-task-wait microbench | [#90](https://gitlab.com/devnw/zig/thread-pool/-/work_items/90) | Scoped-wait API; deprecate `options.waitable` | @benjiv | Next quarter | Open |
| 9 | P2 | 32 | R-11 | Counters comptime offset asserts | pool | `pool.zig` Counters | Compile-only | [#91](https://gitlab.com/devnw/zig/thread-pool/-/work_items/91) | Lock in hot/cold cacheline invariants | @benjiv | Next quarter | Open |
| 10 | P2 | 24 | P-02 | BoundedRing trailing tail pad | queue | `bounded_ring.zig:19-21`; `pool.zig:365,371` | Dual-lane submit p99 | [#88](https://gitlab.com/devnw/zig/thread-pool/-/work_items/88) | Trailing `_pad_tail` + Core asserts | @benjiv | Next quarter | Open |
| 11 | P2 | 24 | R-04 | Watchdog overflow hysteresis / proportional control | pool | `pool.zig:1199-1201` | Oscillating-stall scenario | [#89](https://gitlab.com/devnw/zig/thread-pool/-/work_items/89) | Proportional spawn + 2-tick hysteresis | @benjiv | Next quarter | Open |
| 12 | Info | -- | P-05 | Document seq_cst `queued_tasks` IRIW invariant | docs, pool | `pool.zig:985,1137,1711-1721` | N/A (doc-only) | [#26](https://gitlab.com/devnw/zig/thread-pool/-/work_items/26) | Prose in DESIGN.md + Litmus note | @benjiv | As capacity | Open |

### Filtered / demoted (plateau-pivot rule or dup)

| ID | Sev | Reason |
|---|---|---|
| P-04 | P1→P3 | scanAndWake TLS hint — speculative throughput, orthogonal to 5-iter failure plane; do not invest further |
| P-06 | P2 | ARM-only; bench host is x86; defer until ARM port |
| P-07 | P3 | `acquireDescriptor` branch — confirm-only, likely LLVM-folded |
| P-08 | P3 | `claim_sentinel_enabled` — confirm-only, comptime-false in ReleaseFast |
| P-10 | P2 | Watchdog scan cost — throughput-plateau-adjacent, R-13 + R-04 cover the real risks |
| P-12 | P2 | `releaseSubmitter` spin — submitter-churn only, not steady-state; defer |
| P-13 | P2 | `submitter_nonempty` doc — inline docstring note sufficient, no issue needed |
| P-14 | P3 | `bucketIndex` `@clz` — duplicate of historical PERF-028 |
| R-07 | P2 | Adaptive `scan_len` — plateau wake ceiling (iter 8 closed similar angle); do not re-attack |

### Findings by area (2026-04-16 cohort)

**area::methodology**: PERF-METHODOLOGY (#36).
**area::observability**: PERF-OBSERVABILITY (#46), PERF-R-11 (#91).
**area::concurrency**: PERF-P-05 (#26), PERF-P-09 (#73), PERF-P-11 (#79), PERF-R-13 (#84), PERF-P-01 (#55), PERF-P-03 (#64), PERF-P-02 (#88), PERF-R-04 (#89), PERF-R-09 (#90).
**area::latency**: PERF-P-11 (#79), PERF-R-09 (#90).

### Roadmap (2026-04-16 cohort)

**Quick wins (< 1 day each)**

- PERF-P-01 #55 — RingQueue `_pad_head` (mirror BoundedRing).
- PERF-R-11 #91 — Counters comptime offset asserts.
- PERF-R-13 #84 — `Config.validate` watchdog bounds.
- PERF-P-05 #26 — IRIW invariant doc.

**Medium (1-5 days each)**

- PERF-P-03 #64 — Worker layout audit + conditional re-pack.
- PERF-P-11 #79 — Per-descriptor condvar for waitable.
- PERF-P-02 #88 — BoundedRing trailing pad.
- PERF-R-04 #89 — Watchdog hysteresis + proportional control.
- PERF-METHODOLOGY #36 — Parity preset + env gating + re-run.

**Strategic (> 5 days)**

- PERF-OBSERVABILITY #46 — p999/p9999 + per-lane histograms + wake-latency hist + memory budget API + layout doc.
- PERF-P-09 #73 — Comptime elision build matrix.
- PERF-R-09 #90 — Scoped `waitForCompletion` API + deprecation path.

### Scoring (2026-04-16 cohort)

| ID | Impact | Likelihood | PerfScore | Confidence |
|---|---|---|---|---|
| P-15 (in #36) | 5 | 5 | 100 | confirmed |
| R-08 (in #36) | 4 | 5 | 80 | confirmed |
| R-02 (in #46) | 4 | 5 | 80 | confirmed |
| R-01 (in #46) | 4 | 5 | 80 | confirmed |
| R-05 (in #36) | 4 | 4 | 64 | confirmed |
| P-09 #73 | 4 | 4 | 64 | suspected |
| R-10 (in #46) | 3 | 5 | 60 | confirmed |
| R-06 (in #46) | 3 | 5 | 60 | confirmed |
| P-01 #55 | 3 | 4 | 48 | suspected |
| P-03 #64 | 3 | 4 | 48 | suspected |
| P-11 #79 | 4 | 3 | 48 | suspected |
| R-13 #84 | 3 | 4 | 48 | confirmed |
| R-03 (in #46) | 3 | 4 | 48 | confirmed |
| R-09 #90 | 3 | 3 | 36 | suspected |
| R-11 #91 | 2 | 4 | 32 | confirmed |
| P-02 #88 | 2 | 3 | 24 | suspected |
| R-04 #89 | 2 | 3 | 24 | suspected |
| P-05 #26 | 0 | 0 | info | confirmed |

---

## Historical Cohort (2026-04-11 baseline)

PERF-### numbering. Preserved for audit continuity. Most items closed / resolved via prior sprints. See "Stack-Ranked Findings" below.

## Stack-Ranked Findings

Sorted by PerfScore descending. PerfScore = Impact(1-5) x Likelihood(1-5) x 4.

| Rank | Sev | PerfScore | ID | Finding | Component | Evidence | Measurement | Fix Summary | Owner | SLA | Status |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 1 | P0 | 100 | PERF-001 | WorkDeque mutex-guarded, not lock-free Chase-Lev | `queue/work_deque.zig` | All 3 ops shared single mutex; single-writer deque design violated | 477K vs 1.5M ops/s (3.1x regression) | Replaced with atomic Chase-Lev deque (top/bottom atomics, steal CAS) | @benjiv | Immediate | Closed -- replaced with lock-free Chase-Lev deque. work_stealing throughput improved 3.9x (477K -> 1.87M ops/s). |
| 2 | P0 | 100 | PERF-002 | Unconditional completion_mutex + broadcast on every task | `pool.zig:537-540,607-609` | runTask guards with `if (waitable)` at :537, but cancelDescriptor at :607-609 still does unconditional lock+broadcast | Est. 1.5M futex syscalls/s on cancel path; waitable path still guarded | Guard cancelDescriptor with `if (descriptor.options.waitable)` before lock+broadcast | @benjiv | Immediate | Closed -- cancelDescriptor now guarded with `if (descriptor.options.waitable)` check; commit 3299728. |
| 3 | P1 | 80 | PERF-022 | BoundedRing head/tail false sharing | `queue/bounded_ring.zig:19-20` | head and tail atomics are adjacent struct fields, share same cache line | Standard Vyukov anti-pattern; expected 15-30% throughput improvement from padding | Add `align(64)` or 56-byte padding between head and tail | @benjiv | Within sprint | Closed -- 56-byte padding between head and tail; commit ca1b0a4. |
| 4 | P0 | 80 | PERF-005 | No actual wake signal -- workers use blind Thread.sleep | `pool.zig:560-571` | Workers park via park_cond.timedWait; submit signals with park_cond.signal at pool.zig:398-400 | Sub-microsecond wake latency (was 250us floor) | park_cond.timedWait + submit signal implemented | @benjiv | Immediate | Resolved -- Workers park via park_cond.timedWait, signaled on submit at pool.zig:398-400. |
| 5 | P1 | 80 | PERF-006 | free_mutex global serialization for descriptor acquire/release | `pool.zig:615-660` | Lock-free Treiber stack with CAS and ABA counter | N/A -- lock-free | Replaced with lock-free Treiber stack CAS freelist | @benjiv | Within sprint | Resolved -- Lock-free Treiber stack CAS freelist at pool.zig:615-660. No mutex. |
| 6 | P1 | 80 | PERF-007 | inject_queue.mutex global serialization | `queue/bounded_ring.zig` | Lock-free Vyukov MPMC BoundedRing with atomic head/tail + per-slot sequence | N/A -- lock-free | Replaced with lock-free Vyukov MPMC BoundedRing | @benjiv | Within sprint | Resolved -- Lock-free Vyukov MPMC BoundedRing. No mutex. |
| 7 | P1 | 64 | PERF-012 | ~15 Core atomics contiguous without cache-line padding | `pool.zig:82-100` | submit/complete/idle counters packed in same cache lines | False sharing at >4 workers; all atomic writes invalidate shared line | Add `align(64)` padding between hot/cold groups or use separate structs | @benjiv | Within sprint | Won't Do -- Requires Core struct reorganization into sub-structs which changes all access patterns. False sharing is real but fix complexity exceeds benefit at current worker counts (<16). Defer until lock-free freelist (PERF-006) removes larger bottleneck. |
| 8 | P0 | 60 | PERF-003 | Scratch mutex is pure overhead -- per-worker, single-writer | `memory/scratch.zig` | No mutex in scratch.zig. Per-worker, single-writer. beginTask/finishTask access only from owning thread. | N/A -- no mutex | Mutex removed entirely | @benjiv | Immediate | Resolved -- No mutex in scratch.zig. Per-worker, single-writer access only. |
| 9 | P1 | 60 | PERF-023 | Counters struct false sharing | `pool.zig:83-103` | 19 atomic u64 fields packed in 152 bytes across ~2.4 cache lines. Hot read/write fields (queued_tasks, active_tasks, submitted, completed) share lines with cold fields (steal_failures, peak counters). | Confirm with `perf c2c`; expected HITM on Counters struct address range | Group hot fields (queued_tasks, active_tasks, submitted, completed) with padding; move cold fields to separate struct | @benjiv | Within sprint | Closed -- cache-line padding added between hot and cold counter groups; commit 37fbd6a. |
| 10 | P1 | 60 | PERF-009 | BoundedRing/WorkDeque use modulo instead of bitmask | `bounded_ring.zig; work_deque.zig` | Power-of-2 buffer with bitmask indexing replaces modulo | 20-40 cycles saved per queue op | Power-of-2 + bitmask implemented | @benjiv | Within sprint | Closed -- power-of-2 buffer with bitmask indexing replaces modulo. |
| 11 | P1 | 60 | PERF-010 | 3 nowNs() calls per task (~75ns total) | `pool.zig` | submit_ns, start_ns, complete_ns each call nanoTimestamp() | ~75ns overhead per task; 11% CPU core at 1.5M ops/s | Already optimal; 3rd call necessary for wait-latency | @benjiv | Within sprint | Won't Do -- Already optimal: 2 calls in runTask (start_ns, complete_ns); 3rd in submit path necessary for wait-latency calculation. No reduction possible without losing metrics. |
| 12 | P1 | 48 | PERF-013 | Redundant WorkDeque.len() call in nextTask drain loop | `pool.zig` | Redundant len() calls removed from drain loop; tryPushBottom return value used instead | N/A | Use local count or capacity() for guard | @benjiv | Within sprint | Closed -- redundant len() calls removed from drain loop; tryPushBottom return value used instead. |
| 13 | P1 | 48 | PERF-008 | decrementQueued CAS loop vs fetchSub | `pool.zig:696-698` | Uses `fetchSub(1, .release)` directly. No CAS loop. | N/A -- single atomic op | fetchSub(1, .release) implemented directly | @benjiv | Within sprint | Resolved -- Uses fetchSub(1, .release) directly at pool.zig:696-698. |
| 14 | P2 | 48 | PERF-016 | Steal scan O(N) with global round-robin -- thundering-herd | `pool.zig:455-458` | Replaced global atomic fetchAdd with per-worker pseudo-random start (worker_index +% submitted count) | N/A | Eliminates contention on shared counter | @benjiv | Next quarter | Closed -- per-worker pseudo-random start at pool.zig:455-458. |
| 15 | P2 | 48 | PERF-017 | submitBatch is N individual submits, not true batch | `pool.zig:213-221` | Loop calls submit() individually; N lock pairs per batch | 32x lock overhead for batch=32 | N/A | @benjiv | Next quarter | Won't Do -- PERF-006 lock-free freelist makes per-task cost negligible. |
| 16 | P2 | 40 | PERF-027 | Hot-path atomic overhead -- ~10 atomic operations per task | `pool.zig:394-401,464-472,527-531` | Global counters (steals :465, steal_failures :471, parks :557) duplicate per-worker counters (:466, :472, :558). Global wakeups counter (:316) is loaded in statsSnapshot but never incremented -- always 0. | ~10 atomics per task; 5-6 are redundant global increments | Remove global steals/steal_failures/parks/wakeups counters; derive from sum of per-worker values in statsSnapshot | @benjiv | Next quarter | Open |
| 17 | P1 | 36 | PERF-011 | LatencyHistogram non-atomic fields read cross-thread in statsSnapshot | `stats/latency.zig:7-11; pool.zig:300-303` | sum_ns is now u64 (not u128), reducing tearing risk. But all histogram fields (counts, count, min_ns, max_ns, sum_ns) are plain u64, not atomic. statsSnapshot merges histograms cross-thread at pool.zig:300-303 without synchronization. | Data race on cross-thread histogram reads during active workloads | Use atomic fields for histogram counters, or copy histogram under per-worker lock before merge | @benjiv | Within sprint | Closed -- all histogram fields converted to std.atomic.Value with proper load/store ordering; commit de49d69. |
| 18 | P2 | 36 | PERF-024 | submitBatch per-task signaling | `pool.zig:213-221,397-400` | submitBatch calls submit() in a loop; each submit does park_mutex.lock/signal/unlock if parked_workers > 0 | N park_mutex lock/signal/unlock for batch of N tasks | Signal once at end of batch; or add internal submitInternal variant without signal, signal after loop | @benjiv | Next quarter | Open |
| 19 | P2 | 36 | PERF-026 | Single-item steal in work_stealing | `pool.zig:463-466; queue/work_deque.zig:63-82` | stealTop() returns exactly 1 item per successful steal. Most runtimes batch-steal half the victim's deque. | Under-utilization of steal opportunity; O(N) scan for 1 task | Implement batch steal (steal half of victim's deque) | @benjiv | Next quarter | Open |
| 20 | P1 | 36 | PERF-014 | Benchmark uses 128 tasks -- below noise floor | `benchmarks/bench.zig:14` | task_count increased to 4096; queue_capacity raised proportionally | Runtime now ~3-6ms, well above noise floor | Task count increased | @benjiv | Within sprint | Closed -- task_count increased to 4096. |
| 21 | P1 | 36 | PERF-015 | Benchmark single-shot measurement, no statistical repetition | `benchmarks/common.zig` | Median-of-3 runs implemented in runScenarios | Reduced noise | Added iterations with median reporting | @benjiv | Within sprint | Closed -- median-of-3 runs implemented. |
| 22 | P2 | 32 | PERF-020 | statsSnapshot reads non-atomic Worker fields cross-thread | `pool.zig:280-293` | Converted all Worker stat fields to std.atomic.Value with proper load/store/fetchAdd ordering | N/A | Atomic fields implemented | @benjiv | Next quarter | Closed -- all Worker stat fields converted to std.atomic.Value. |
| 23 | P2 | 32 | PERF-021 | Worker struct ~1.2KB with histograms; no hot/cold split | `pool.zig` | Split local_queues into separate dense array for cache-friendly steal scan | N/A | Hot/cold split implemented | @benjiv | Next quarter | Closed -- local_queues split into separate dense array. |
| 24 | P2 | 24 | PERF-025 | submitInternal backpressure flat 50us sleep | `pool.zig:339-358` | `Thread.sleep(50_000)` on QueueFull/TaskPoolExhausted with no exponential backoff | Thundering-herd retry when multiple submitters hit backpressure simultaneously | Implement exponential backoff (50us, 100us, 200us, ... capped at 1ms) with jitter | @benjiv | Next quarter | Open |
| 25 | P2 | 24 | PERF-030 | WorkDeque top/bottom false sharing | `queue/work_deque.zig:15-16` | top and bottom atomics are adjacent struct fields, share same cache line. Less severe than BoundedRing because bottom is single-owner. | Confirm with `perf c2c` under 4+ worker steal contention | Add padding between top and bottom fields | @benjiv | Next quarter | Open |
| 26 | P3 | 24 | PERF-031 | No benchmark scenarios with 4+ workers in CI-safe suite | `benchmarks/bench.zig:15-28` | Both scenarios use worker_count=2. False sharing issues (PERF-022, PERF-023, PERF-030) only manifest with 4+ workers. | False sharing regressions undetectable in CI | Add scenario with 4 or 8 workers for contention-sensitive regression detection | @benjiv | Backlog | Open |
| 27 | P0 | 40 | PERF-004 | Spurious wakeups counter incremented on every submit | `pool.zig:565,571` | Counter removed from submit path. Only per-worker wakeups.fetchAdd(1) in idle() at pool.zig:565 and :571. Global counters.wakeups is loaded in statsSnapshot but never incremented. | N/A -- no wasted atomic on submit | Counter gated behind actual idle wake | @benjiv | Immediate | Resolved -- Counter removed from submit path. Only counted in idle(). |
| 28 | P2 | 20 | PERF-018 | CI installs Zig from scratch every job (~12 jobs x 50MB) | `.gitlab-ci.yml:28-31` | install-zig.sh runs per-job; no `cache:` directive in .gitlab-ci.yml | 30-60s extra per job; ~6-12 min total pipeline waste | Add `cache:` key on ZIG_VERSION or use pre-built image | @benjiv | Next quarter | Open |
| 29 | P3 | 20 | PERF-028 | LatencyHistogram.bucketIndex uses while loop instead of @clz intrinsic | `stats/latency.zig:47-55` | `while (value > 1)` loop iterates up to 63 times; 13 iterations for typical 10us latency. @clz is single instruction on all targets. | ~10-15 cycles per observe() vs 1 cycle with @clz | Replace with `@as(usize, @intCast(63 - @clz(value)))` or equivalent bit-scan | @benjiv | Backlog | Open |
| 30 | P3 | 8 | PERF-029 | Shutdown drain polls with 100us sleep instead of condvar | `pool.zig:258-264` | `while (true)` loop with `Thread.sleep(100_000)` polling queued/active until zero | 100us polling latency on shutdown; wastes CPU during drain | Signal shutdown completion via condvar when last task completes | @benjiv | Backlog | Open |
| 31 | P2 | 16 | PERF-019 | alloc_count always 0 in benchmark output | `benchmarks/common.zig` | Added total_alloc_count atomic to Accounting/Core/Stats | N/A | alloc_count wired up | @benjiv | Next quarter | Closed -- total_alloc_count wired up. |

---

## Findings by Area

### Area: App (Scheduler / Queue / Worker)

| ID | PerfScore | Finding | Status |
|---|---|---|---|
| PERF-001 | 100 | WorkDeque mutex instead of lock-free Chase-Lev | Closed |
| PERF-002 | 100 | Unconditional completion_mutex + broadcast | Closed |
| PERF-022 | 80 | BoundedRing head/tail false sharing | Closed |
| PERF-005 | 80 | Blind Thread.sleep idle (no signal-based wake) | Resolved |
| PERF-006 | 80 | free_mutex global serialization | Resolved |
| PERF-007 | 80 | inject_queue.mutex global serialization | Resolved |
| PERF-012 | 64 | False sharing on Core atomics | Won't Do |
| PERF-003 | 60 | Scratch mutex on single-writer path | Resolved |
| PERF-023 | 60 | Counters struct false sharing | Closed |
| PERF-009 | 60 | Modulo instead of bitmask | Closed |
| PERF-010 | 60 | 3 nowNs() calls per task | Won't Do |
| PERF-013 | 48 | Redundant mutex in drain loop | Closed |
| PERF-008 | 48 | CAS loop instead of fetchSub | Resolved |
| PERF-016 | 48 | O(N) steal scan with thundering herd | Closed |
| PERF-017 | 48 | submitBatch not truly batched | Won't Do |
| PERF-027 | 40 | Hot-path atomic overhead (redundant global counters) | Open |
| PERF-004 | 40 | Spurious wakeups counter | Resolved |
| PERF-011 | 36 | Non-atomic histogram fields, cross-thread reads | Closed |
| PERF-024 | 36 | submitBatch per-task signaling | Open |
| PERF-026 | 36 | Single-item steal in work_stealing | Open |
| PERF-020 | 32 | Non-atomic worker field reads in statsSnapshot | Closed |
| PERF-021 | 32 | Worker struct cache layout | Closed |
| PERF-025 | 24 | submitInternal backpressure flat 50us sleep | Open |
| PERF-030 | 24 | WorkDeque top/bottom false sharing | Open |
| PERF-028 | 20 | bucketIndex while loop instead of @clz | Open |
| PERF-018 | 20 | Zig installed per-job without caching | Open |
| PERF-019 | 16 | alloc_count always 0 | Closed |
| PERF-029 | 8 | Shutdown drain polls with 100us sleep | Open |

### Area: Infra / CI

| ID | PerfScore | Finding | Status |
|---|---|---|---|
| PERF-018 | 20 | Zig installed per-job without caching | Open |

### Area: Benchmark Reliability

| ID | PerfScore | Finding | Status |
|---|---|---|---|
| PERF-014 | 36 | 128 tasks below noise floor | Closed |
| PERF-015 | 36 | Single-shot measurement, no repetition | Closed |
| PERF-019 | 16 | alloc_count always 0 | Closed |
| PERF-031 | 24 | No 4+ worker scenarios in CI-safe bench suite | Open |

---

## Scoring Methodology

```text
PerfScore = Impact(1-5) x Likelihood(1-5) x 4

Impact:
  5 = SLO saver / 10x improvement potential
  4 = 2-5x improvement or significant cost reduction
  3 = Noticeable user-facing improvement
  2 = Small improvement
  1 = Hardening, future-proofing

Likelihood:
  5 = Always hit / hot path
  4 = Common code path
  3 = Moderate frequency
  2 = Rare code path
  1 = Edge case / theoretical
```

### Scoring Detail

| ID | Impact | Likelihood | PerfScore | Confidence | Rationale |
|---|---|---|---|---|---|
| PERF-001 | 5 (3.1x regression) | 5 (every work-steal task) | 100 | confirmed | Measured: 477K vs 1.5M ops/s |
| PERF-002 | 5 (20-40% throughput) | 5 (every task completion) | 100 | confirmed | runTask guarded; cancelDescriptor still unconditional at pool.zig:607-609 |
| PERF-022 | 4 (15-30% throughput) | 5 (every push/pop on MPMC ring) | 80 | suspected | Adjacent atomics at bounded_ring.zig:19-20; classic Vyukov false sharing |
| PERF-005 | 4 (250us latency floor) | 5 (every idle->wake) | 80 | confirmed | park_cond.timedWait + signal on submit implemented |
| PERF-006 | 4 (scalability wall) | 5 (2x per task lifecycle) | 80 | confirmed | Lock-free Treiber stack CAS freelist verified at pool.zig:615-660 |
| PERF-007 | 4 (26x latency spike) | 5 (every submit to global) | 80 | confirmed | Lock-free Vyukov MPMC ring verified at bounded_ring.zig |
| PERF-012 | 4 (false sharing) | 4 (>4 workers) | 64 | suspected | Layout inspection; confirm with perf c2c |
| PERF-003 | 3 (60-150ms/s waste) | 5 (every task, 2x) | 60 | confirmed | No mutex in scratch.zig; per-worker single-writer |
| PERF-023 | 3 (false sharing) | 5 (every task, multiple counters) | 60 | suspected | 19 atomic u64 fields in 152 bytes at pool.zig:83-103 |
| PERF-009 | 3 (50-100ns/op) | 5 (every push/pop/steal) | 60 | confirmed | Bitmask indexing with mask field; power-of-2 enforced |
| PERF-010 | 3 (75ns/task, 11% CPU) | 5 (every task) | 60 | confirmed | 3 calls, all necessary for metrics |
| PERF-013 | 3 (32 extra mutex ops) | 4 (work-steal drain) | 48 | confirmed | Removed; tryPushBottom return value used |
| PERF-008 | 2 (2-5ns/task) | 5 (every dequeue) | 48 | confirmed | fetchSub(1, .release) at pool.zig:697; verified direct |
| PERF-016 | 3 (steal storms) | 4 (16+ workers) | 48 | confirmed | Per-worker pseudo-random start at pool.zig:455-458 |
| PERF-017 | 3 (32x lock overhead) | 4 (batch submit path) | 48 | confirmed | Deferred; lock-free freelist makes per-task cost negligible |
| PERF-027 | 2 (redundant atomics) | 5 (every task) | 40 | confirmed | Global steals/steal_failures/parks duplicate per-worker; global wakeups never incremented (always 0) |
| PERF-004 | 2 (wasted atomic) | 5 (every submit) | 40 | confirmed | Removed from submit path; only in idle() at pool.zig:565,571 |
| PERF-011 | 3 (data race / garbage stats) | 3 (active workload + snapshot) | 36 | confirmed | sum_ns now u64; all histogram fields still non-atomic; merge at pool.zig:300-303 is unsynchronized |
| PERF-024 | 3 (N lock/signal per batch) | 3 (batch submit path) | 36 | confirmed | submitBatch at pool.zig:213-221 calls submit() individually; each triggers signal at :397-400 |
| PERF-026 | 3 (under-utilized steal) | 3 (steal path) | 36 | suspected | stealTop() returns 1 item; batch-steal would amortize O(N) scan |
| PERF-014 | 3 (unreliable gate) | 3 (CI runs) | 36 | confirmed | Fixed: 4096 tasks |
| PERF-015 | 3 (no confidence) | 3 (CI runs) | 36 | confirmed | Fixed: median-of-3 |
| PERF-020 | 2 (stale stats) | 4 (any stats call during work) | 32 | confirmed | Fixed: atomic fields |
| PERF-021 | 2 (cache pressure) | 4 (steal scan) | 32 | confirmed | Fixed: hot/cold split |
| PERF-025 | 2 (thundering herd retry) | 3 (backpressure path) | 24 | confirmed | Flat 50us sleep at pool.zig:353; no backoff, no jitter |
| PERF-030 | 2 (false sharing) | 3 (steal contention) | 24 | suspected | Adjacent atomics at work_deque.zig:15-16; less severe than BoundedRing (single-owner bottom) |
| PERF-031 | 2 (undetectable regressions) | 3 (CI runs) | 24 | confirmed | bench.zig uses worker_count=2 only; false sharing invisible |
| PERF-028 | 1 (loop vs intrinsic) | 5 (every observe()) | 20 | confirmed | while loop at latency.zig:47-55; 13 iterations for 10us |
| PERF-018 | 2 (pipeline time) | 2 (CI only) | 20 | confirmed | install-zig.sh per job, no cache directive |
| PERF-019 | 2 (blind to allocs) | 2 (CI only) | 16 | confirmed | Fixed: total_alloc_count wired up |
| PERF-029 | 1 (polling waste) | 2 (shutdown only) | 8 | confirmed | Thread.sleep(100_000) polling loop at pool.zig:258-264 |

---

## Roadmap

### Quick Wins (< 1 day each)

| ID | Fix | Expected Gain | Risk |
|---|---|---|---|
| PERF-002 | ~~Guard cancelDescriptor with waitable check~~ | ~~Done -- commit 3299728~~ | -- |
| PERF-027 | Remove global counters.steals/steal_failures/parks/wakeups; sum per-worker values in statsSnapshot | ~4 fewer atomics per task | Low -- stats semantics preserved |
| PERF-028 | Replace bucketIndex while loop with `63 - @clz(value)` | ~12 cycles saved per observe() | None -- single instruction |
| PERF-029 | Replace shutdown drain poll with condvar signal on last task completion | Eliminate polling; instant shutdown | Low -- condvar semantics straightforward |
| PERF-018 | Add `cache:` directive in .gitlab-ci.yml keyed on ZIG_VERSION | Save 30-60s per job | None |

### Medium Effort (1-5 days each)

| ID | Fix | Expected Gain | Risk |
|---|---|---|---|
| PERF-022 | ~~Add padding between BoundedRing head and tail~~ | ~~Done -- commit ca1b0a4~~ | -- |
| PERF-023 | ~~Group hot Counters fields with cache-line padding~~ | ~~Done -- commit 37fbd6a~~ | -- |
| PERF-030 | Add padding between WorkDeque top and bottom | Reduced false sharing under steal contention | Low -- padding only |
| PERF-024 | Add submitBatchInternal that enqueues N tasks, signals once | N-fold reduction in park_mutex lock/unlock | Low -- additive code path |
| PERF-025 | Exponential backoff with jitter (50us, 100us, 200us, ... capped 1ms) | Eliminate thundering-herd retry | Low -- backpressure path only |
| PERF-011 | ~~Convert histogram fields to std.atomic.Value~~ | ~~Done -- commit de49d69~~ | -- |
| PERF-031 | Add bench scenario with 4-8 workers | Detect false sharing regressions in CI | None |

### Strategic (> 5 days)

| ID | Fix | Expected Gain | Risk |
|---|---|---|---|
| PERF-026 | Batch-steal half of victim's deque (steal_half()) | Amortize O(N) steal scan; better load distribution | Medium -- correctness of bulk transfer |

---

## Top-3 ROI Fixes (highest PerfScore / lowest effort)

1. ~~**PERF-022** (PerfScore 80):~~ Closed -- cache-line padding added between head and tail; commit ca1b0a4.

2. ~~**PERF-002** (PerfScore 100):~~ Closed -- cancelDescriptor guarded with waitable check; commit 3299728.

3. **PERF-027** (PerfScore 40, effort < 2 hours): Remove global `counters.steals`, `counters.steal_failures`, `counters.parks`, and `counters.wakeups` atomic counters. Sum per-worker values in `statsSnapshot()` instead. Saves ~4 atomic fetchAdd operations per task on the hot path. Low risk -- per-worker counters already exist and are authoritative.

---

## Validation Plan

### How to verify each fix

| ID | Command | Expected Delta |
|---|---|---|
| PERF-002 | `zig build bench -- --output /tmp/after.json && zig build compare -- --baseline benchmarks/results/baseline.json --current /tmp/after.json` | Cancel path shows no futex syscalls for non-waitable tasks |
| PERF-022 | Same bench command with 4+ workers; `perf c2c record -- zig build bench && perf c2c report` | HITM events on BoundedRing head/tail eliminated; 15-30% throughput improvement |
| PERF-023 | `perf c2c record -- zig build bench && perf c2c report` at 4+ workers | Reduced HITM events on Counters struct address range |
| PERF-024 | Batch submit scenario with batch_size=32 | 32x fewer park_mutex lock/unlock cycles |
| PERF-025 | producer_contention scenario with 8 submitters at queue saturation | Reduced retry thundering-herd; smoother backpressure |
| PERF-026 | work_stealing scenario at 8+ workers with imbalanced task distribution | Higher steal throughput; fewer steal_failures |
| PERF-027 | `perf stat -e instructions zig build bench` before/after | ~4 fewer atomic instructions per task |
| PERF-028 | Microbenchmark of bucketIndex; bench throughput | ~10 cycles saved per observe() |
| PERF-029 | Shutdown latency measurement | Instant vs 100us polling |
| PERF-030 | `perf c2c` at 4+ workers under steal contention | Reduced HITM events on WorkDeque |
| PERF-031 | CI bench with 4-8 workers | False sharing regressions detectable |
| PERF-011 | ThreadSanitizer or manual race test during active workload + statsSnapshot | No data race on histogram fields |
| PERF-018 | CI pipeline timing before/after | 30-60s saved per job |

---

## Confidence Assessment

| Tag | IDs |
|---|---|
| `confidence::confirmed` | PERF-001, PERF-002, PERF-003, PERF-004, PERF-005, PERF-006, PERF-007, PERF-008, PERF-009, PERF-010, PERF-011, PERF-013, PERF-014, PERF-015, PERF-017, PERF-018, PERF-019, PERF-020, PERF-024, PERF-025, PERF-027, PERF-028, PERF-029, PERF-031 |
| `confidence::suspected` | PERF-012, PERF-022, PERF-023, PERF-026, PERF-030 |

### What would confirm suspected items

- **PERF-012**: Run `perf c2c` and confirm HITM (cross-core cache-line invalidation) events on addresses within the Core struct atomic region (offset 0x50-0xE0).
- **PERF-022**: Run `perf c2c` under 4+ producers pushing to inject queue. Confirm HITM on BoundedRing head/tail addresses (adjacent in struct at bounded_ring.zig:19-20). Alternatively, add padding and measure throughput delta.
- **PERF-023**: Run `perf c2c` at 4+ workers. Confirm HITM on Counters struct fields at pool.zig:83-103. Especially queued_tasks/active_tasks vs submitted/completed.
- **PERF-026**: Run work_stealing benchmark with highly imbalanced task distribution (1 producer, 8 workers). Measure steal_failures/steals ratio. If > 10:1, single-item steal is the bottleneck.
- **PERF-030**: Run `perf c2c` at 4+ workers under active stealing. Confirm HITM on WorkDeque top/bottom addresses. Less likely than PERF-022 since bottom is single-writer.

---

## Rollout Risk Register

| ID | Risk Level | Concern | Safeguard |
|---|---|---|---|
| PERF-002 | Low | Non-waitable cancelled tasks could skip broadcast (correct: no one waits) | Existing wait() tests cover waitable path; cancel tests verify state transitions |
| PERF-022 | Low | Increased struct size from padding (~56 bytes per BoundedRing) | Trivial memory cost; single instance per pool |
| PERF-023 | Low | Increased Counters struct size from padding | Trivial; single instance per pool |
| PERF-024 | Low | Batch signal could delay worker wake by batch duration | Batch sizes are small (typically < 32); total delay negligible |
| PERF-025 | Low | Exponential backoff could increase latency on transient full | Cap at 1ms; reset on success |
| PERF-026 | Medium | Batch steal correctness (partial deque transfer) | Extensive stress tests; compare results before/after |
| PERF-027 | Low | Stats accuracy if worker array mutated during snapshot | Workers array is fixed at init; per-worker counters are monotonic |
| PERF-030 | Low | Increased WorkDeque struct size from padding | Trivial; one per worker |
| PERF-011 | Medium | Atomic histogram ops add per-observe overhead | Benchmark observe() path before/after; use relaxed ordering where safe |

---

## Cross-References

- Design decisions: `docs/DESIGN.md` (tracks deque design choice)
- Functional gap analysis: `docs/GAP_ANALYSIS.md`
- Performance targets: `docs/PERFORMANCE_TARGETS.md`
- Scheduler decision: `docs/SCHEDULER_DECISION.md`
- Latest runtime-compare snapshot: `docs/performance/appsec-fixes-2026-04-15/FINAL-runtime-comparison.json`
- 2026-04-16 adversarial review input: `.cache/audit/perf-reviewed.json`
- Plateau-verdict memory: `project_throughput_plateau_pivot.md` (architectural flood_1m_batched plateau)
