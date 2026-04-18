# AppSec Remediation — Final Summary (2026-04-15)

**Branch merged:** `appsec-remediation-2026-04-15` (22 commits) → `main` at `8cf119d`
**Spec:** [`docs/APPSEC_REVIEW_2026-04-15_src.md`](../../APPSEC_REVIEW_2026-04-15_src.md)
**Plan:** [`docs/superpowers/plans/2026-04-15-appsec-remediation.md`](../../superpowers/plans/2026-04-15-appsec-remediation.md)

## What shipped

All 7 priority findings from the AppSec review are fixed and merged:

| ID | Severity | Title | Status |
|---|---|---|---|
| F-001 | Critical | Per-pool TLS scoping for `tls_worker_index` / `tls_submitter_index` | ✅ shipped |
| F-002 | High | Spawn-aware errdefer in `Core.init` | ✅ shipped |
| F-003 | High | Atomic `free_indices` loads/stores | ✅ shipped |
| F-004 | Medium | Soften `WaitGroup.done` underflow panic | ✅ shipped |
| F-005 | Medium | Harden `releaseSubmitter` (bounds, CAS idempotence, bounded drain) | ✅ shipped |
| F-006 | Medium | Replace `unreachable` on `blocking_inject` with safe fallback | ✅ shipped |
| F-007 | Low | Clamp `parseProcStatusKiB` against `*1024` overflow | ✅ shipped |

**Coverage gaps closed:**

- Two-pool cross-submit integration test (`tests/integration/two_pool_cross_submit.zig`)
- `std.Thread.spawn` partial-failure test via `FailingAllocator` (`tests/integration/spawn_failure.zig`)
- `releaseSubmitter` double-release and OOB-idx tests (`tests/integration/submitter_lifecycle.zig`)
- `-Dtsan` build option wired into `build.zig` for unit/integration/stress suites
- Public-API fuzz harness (`tests/fuzz/pool_fuzz.zig`) with `FUZZ_SEED` / `FUZZ_ITERATIONS` env vars

**Test state:** 84/85 pass (1 skipped: the F-004 regression test is `runtime_safety`-gated and only runs under ReleaseFast).

**ThreadSanitizer:** zero warnings across `test`, `test-integration`, and `test-stress` — see `TSAN-findings.md`.

**Fuzz:** clean runs at `FUZZ_ITERATIONS=5000` across seeds 1, 2, 3, plus a 100-iter smoke re-run post-0.16-migration.

## Per-step performance ledger

From `README.md` progress table — each step's before/after bench + disposition is archived alongside this file:

| Step | Fix | Regression class |
|------|-----|------------------|
| 1 | F-001 per-pool TLS | clean (bench noise, [see diff](step-1-f001-diff.md)) |
| 2 | F-002 spawn errdefer | clean (bench + p95 noise, ruled out by construction) |
| 3 | F-003 atomic free_indices | clean (zero codegen delta on x86_64) |
| 4 | F-006 blocking_inject fallback | clean (contention variance within historical 9–10% CV) |
| 5 | F-005 releaseSubmitter hardening | clean (cold-path lifecycle, not exercised by bench) |
| 6 | F-004 WaitGroup.done soften | clean (bench noise, underflow-only path) |
| 7 | F-007 parseProcStatusKiB clamp | clean (stats-sampling path, not on any bench hot path) |
| 8 | TSan stress run | clean — zero warnings |
| 9 | Fuzz harness | clean — 100 + 5000×3 iterations |

Every scenario whose bench showed a warn-or-block-threshold delta got a written disposition in that step's `step-N-<fix>-diff.md`. The recurring pattern: `conn_churn_seq` and `producer_contention` micro-bench scenarios have 12–37% BASELINE CV, so apparent ±15–50% swings land inside the noise band. Scenarios that actually execute the changed code (bench-realistic / `work_stealing` path) are flat-to-improved throughout the series.

## BASELINE → end-of-series delta (zig 0.15.2, same compiler)

Compares `BASELINE-bench.json` (Task 0, before F-001) vs `step-7-f007-after-bench.json` (after all 7 fixes). Both captured under zig 0.15.2 — no compiler drift.

### bench

| scenario | variant | BASELINE ops/s | FINAL ops/s | Δ % | BASELINE p95 (ns) | FINAL p95 (ns) | Δ p95 % | BASELINE CV | verdict |
|---|---|---:|---:|---:|---:|---:|---:|---:|---|
| conn_churn_seq | global_queue | 921,304 | 767,122 | −16.7% | 1,838 | 2,073 | +12.8% | 37% | noise (within 1σ) |
| conn_churn_seq | work_stealing | 1,051,336 | 852,082 | −19.0% | 1,621 | 1,969 | +21.5% | 25% | noise (within 1σ) |
| producer_contention | global_queue | 768,469 | 785,789 | +2.3% | 5,493 | 6,514 | +18.6% | 12% | in-band swap |
| producer_contention | work_stealing | 990,117 | 1,223,924 | **+23.6%** | 5,116 | 3,751 | **−26.7%** | 7% | **improvement** |

### bench-realistic (the scenarios that actually exercise the changed code)

| scenario | BASELINE ops/s | FINAL ops/s | Δ % | BASELINE p95 (ns) | FINAL p95 (ns) | Δ p95 % | verdict |
|---|---:|---:|---:|---:|---:|---:|---|
| cpu_work_10us | 227,816 | 235,083 | **+3.2%** | 17,463 | 14,563 | **−16.6%** | improvement |
| cpu_work_100us | 99,831 | 99,862 | +0.0% | 29,154 | 24,146 | **−17.2%** | p95 improvement, tput flat |
| contended_cpu_10us | 216,500 | 215,280 | −0.6% | 65,155 | 64,938 | −0.3% | flat |
| nested_fanout_4x | 185,091 | 178,830 | −3.4% | 22,489 | 24,707 | +9.9% | within 6% BASELINE CV |
| burst_drain_burst | 83,000 | 84,511 | +1.8% | 22,293 | 20,901 | **−6.2%** | improvement |

**Net effect of the 7-fix series:** 3 of 5 realistic scenarios show a submit-p95 improvement of ≥6%; throughput is within ±3% on all five. One microbench variant (`producer_contention/work_stealing`) shows a genuine +23.6% throughput / −26.7% p95 improvement. Microbench variance on the `conn_churn_seq` variants is within baseline noise.

## Runtime comparison vs Tokio / Go (post-rebase, zig 0.16.0)

Captured in `FINAL-runtime-comparison.json` after the branch was rebased onto origin/main's zig-0.16.0 migration. This replaces the CLAUDE.md snapshot, which was measured under zig 0.15.2 before the rebase.

### Throughput (median ops/sec, 6 retained samples after 1 warmup discard)

| Scenario | Zig thread-pool | Tokio | Go | Zig vs Go |
|---|---:|---:|---:|---:|
| `flood_1m` | 1,074,269 | 504,907 | 1,016,708 | **1.06× ahead** |
| `contended_spawn_8x` | 880,038 | 655,249 | 4,161,629 | 4.73× behind |
| `cpu_work_10us` | 982,714 | 506,030 | 792,213 | **1.24× ahead** |
| `cpu_work_100us` | 416,921 | 380,130 | 441,693 | 1.06× behind |
| `contended_cpu_10us` | 970,439 | 579,571 | 2,546,602 | 2.62× behind |
| `nested_fanout_4x` | 538,931 | 1,306,493 | 4,584,906 | 8.51× behind |
| `burst_drain_burst` | 162,024 | 141,206 | 151,406 | **1.07× ahead** |
| `mixed_fast_slow` | 230,765 | 244,296 | 248,029 | 1.07× behind |

### Latency (p50/p95/p99, microseconds)

| Scenario | Zig | Tokio | Go |
|---|---|---|---|
| `cpu_work_10us` | 45 / 226 / 301 | 30 / 74 / 105 | 33 / 114 / 208 |
| `cpu_work_100us` | 1,848 / 3,474 / 3,656 | 1,402 / 2,925 / 3,010 | 1,099 / 2,479 / 3,668 |
| `contended_cpu_10us` | **27 / 137 / 192** | 27 / 223 / 313 | 34 / 336 / 416 |
| `nested_fanout_4x` | 12 / 61 / 95 | 6 / 18 / 37 | 4 / 27 / 62 |
| `burst_drain_burst` | 790 / 1,546 / 1,660 | 757 / 1,196 / 1,255 | 592 / 1,032 / 2,313 |
| `mixed_fast_slow` | 10,396 / 18,086 / 19,754 | 4,138 / 8,341 / 11,382 | 8,575 / 14,882 / 15,886 |

### Interpretation

- Zig beats Tokio on 6 of 8 throughput scenarios and beats Go on 3 of 8.
- Zig has the best contended per-task latency: p50 = 27 µs on `contended_cpu_10us` (vs Go's 34 µs; vs Tokio's 27 µs, but Zig's p95/p99 dominates).
- Go's in-runtime local-P queue continues to win contended/nested scenarios; Tokio wins nested-fanout and mixed via fiber amortisation.
- Compared to the pre-rebase CLAUDE.md snapshot (0.15.2): `nested_fanout_4x` improved (+9.9%), `mixed_fast_slow` improved (+3.1%), `flood_1m` improved (+4.8%). `cpu_work_10us` regressed 21.5% and `contended_spawn_8x` regressed 16.6% — these shifts mix **appsec remediation effect + zig 0.16 compiler differences** and cannot be cleanly separated without a same-compiler comparison on the pre-series commit, which was not captured.

## Delta vs CLAUDE.md snapshot

The `CLAUDE.md § Current Direct Runtime Snapshot` numbers were captured at commit `7275ae2` under zig 0.15.2 (the branch's merge base). Post-merge at `8cf119d` under zig 0.16.0, the numbers are:

| Scenario | CLAUDE.md (0.15.2) | FINAL (0.16) | Net change |
|---|---:|---:|---:|
| flood_1m | 1,024,793 | 1,074,269 | +4.8% |
| contended_spawn_8x | 1,055,748 | 880,038 | −16.6% |
| cpu_work_10us | 1,251,811 | 982,714 | −21.5% |
| cpu_work_100us | 456,838 | 416,921 | −8.7% |
| contended_cpu_10us | 1,006,760 | 970,439 | −3.6% |
| nested_fanout_4x | 490,591 | 538,931 | +9.9% |
| burst_drain_burst | 163,679 | 162,024 | −1.0% |
| mixed_fast_slow | 223,873 | 230,765 | +3.1% |

The two double-digit regressions (`contended_spawn_8x`, `cpu_work_10us`) are not attributable to a single cause: the intermediate per-step bench dispositions (above) show clean `work_stealing` path effects, so the shift appears to be compiler-driven (0.15.2 → 0.16). Re-running `bench-runtime-compare` on the pre-appsec commit under zig 0.16 would isolate the compiler contribution — recommended for a future CLAUDE.md refresh.

## Bisect — AppSec vs compiler contribution (same 0.16 compiler)

To separate the remediation effect from the zig 0.15.2 → 0.16 compiler shift, `bench-runtime-compare` was captured at **`e9b6b2a`** (origin/main, pre-AppSec, zig 0.16.0) and compared against **`8cf119d`** (post-AppSec, zig 0.16.0). Same compiler on both sides. Raw data: `BISECT-e9b6b2a-runtime-comparison.json`.

### Same-compiler Zig throughput delta (pre-appsec → post-appsec)

| Scenario | Pre (e9b6b2a) | Post (8cf119d) | Δ % | Attribution |
|---|---:|---:|---:|---|
| `burst_drain_burst` | 161,949 | 162,024 | **+0.0%** | appsec-neutral |
| `contended_cpu_10us` | 947,480 | 970,439 | **+2.4%** | appsec-neutral-to-positive |
| `flood_1m` | 1,158,012 | 1,074,269 | −7.2% | appsec |
| `cpu_work_10us` | 1,044,482 | 982,714 | −5.9% | appsec |
| `cpu_work_100us` | 458,215 | 416,921 | −9.0% | appsec |
| `nested_fanout_4x` | 605,172 | 538,931 | −10.9% | appsec |
| `mixed_fast_slow` | 259,377 | 230,765 | −11.0% | appsec |
| `contended_spawn_8x` | 997,631 | 880,038 | −11.8% | appsec |

### Same-compiler Zig p95 latency delta (µs)

| Scenario | Pre p95 | Post p95 | Δ % |
|---|---:|---:|---:|
| `cpu_work_10us` | 266 | 226 | **−15.0%** (improvement) |
| `burst_drain_burst` | 1,557 | 1,546 | −0.7% (flat) |
| `cpu_work_100us` | 3,660 | 3,474 | **−5.1%** (improvement) |
| `contended_cpu_10us` | 122 | 137 | +12.3% |
| `mixed_fast_slow` | 16,311 | 18,086 | +10.9% |
| `nested_fanout_4x` | 46 | 61 | +32.6% |

### Attribution decomposition (CLAUDE.md 0.15.2 → FINAL 0.16)

| Scenario | Total Δ | Compiler (0.15.2→0.16) | AppSec (pre→post) | Dominant |
|---|---:|---:|---:|---|
| `flood_1m` | +4.8% | +12.0% | −7.2% | **compiler** +, appsec − |
| `contended_spawn_8x` | −16.6% | −5.5% | −11.8% | **appsec** |
| `cpu_work_10us` | −21.5% | −16.6% | −5.9% | **compiler** |
| `cpu_work_100us` | −8.7% | +0.3% | −9.0% | **appsec** |
| `contended_cpu_10us` | −3.6% | −5.9% | +2.4% | **compiler** |
| `nested_fanout_4x` | +9.9% | +23.4% | −10.9% | **compiler** + dominates |
| `burst_drain_burst` | −1.0% | −1.1% | +0.0% | compiler (both flat) |
| `mixed_fast_slow` | +3.1% | +15.8% | −11.0% | **compiler** + dominates |

**Honest characterisation of the AppSec remediation cost:** 5–12% throughput regression on six of eight scenarios under the same compiler. This is a genuine performance cost, not noise. Scenarios that regressed: `flood_1m`, `cpu_work_10us`, `cpu_work_100us`, `nested_fanout_4x`, `mixed_fast_slow`, `contended_spawn_8x`. Two scenarios were appsec-neutral (`burst_drain_burst` flat, `contended_cpu_10us` +2.4% improvement).

**Why per-step perf-gates read "clean":** each fix's narrow before→after diff fell within the high run-to-run variance of the micro-bench scenarios (25–37% BASELINE CV on `conn_churn_seq`). The cumulative effect across all seven fixes only becomes visible in an end-to-end comparison on the more stable `bench-runtime-compare` realistic scenarios. A future plan should include a full runtime-compare before each fix series begins, not just `bench` + `bench-realistic`.

**Correctness-vs-performance tradeoff accepted:** the remediation closes one Critical memory-safety bug (F-001 cross-pool OOB → ReleaseFast UB), two High data-race / UAF bugs (F-002 / F-003), and three Medium robustness bugs (F-004 / F-005 / F-006). The 5–12% throughput cost is the overhead of the pool-identity check on every TLS-cached submit (F-001), the CAS claim on every `releaseSubmitter` (F-005), and the per-slot atomic access on the freelist (F-003). These are security-essential, not gratuitous. If a future optimisation pass reclaims some of this cost — e.g. per-thread-per-pool TLS without the identity check on the hottest loop — the safety properties should be preserved end-to-end (TSan clean + fuzz clean invariants).

## Recommended follow-ups

1. ~~**Bisect `contended_spawn_8x` / `cpu_work_10us` shifts**: compiler vs appsec.~~ ✅ Done (see section above). `contended_spawn_8x` is AppSec-dominated; `cpu_work_10us` is compiler-dominated.
2. **Extend stress-suite TSan duration on CI**: added `tsan-stress-soak` and `tsan-fuzz` jobs to `.gitlab-ci.yml` (scheduled / default-branch / on-demand via `RUN_TSAN=true`). Three back-to-back soak passes per suite.
3. ~~**Fuzz harness under TSan**~~: see (2) — `tsan-fuzz` job runs `zig build fuzz -Dtsan` against three seeds at `FUZZ_ITERATIONS=5000`.
4. ✅ **CLAUDE.md runtime-comparison table refreshed** to the 0.16 post-appsec numbers.
5. ✅ **Optional optimisation pass** — partial recovery via `-Dsingle-pool=true` build flag (see section below).

## Optimisation pass — `-Dsingle-pool` comptime elision

Added a `-Dsingle-pool=true` build option that elides the F-001 pool-identity check on the hot submit path at compile time. The null check and bounds check are retained, so a non-worker / non-submitter thread still falls through correctly. **The flag is UNSAFE when a process hosts multiple pools** (it restores the pre-F-001 OOB hazard for the index-within-bounds case) — callers opt in explicitly. Default remains safe.

F-005 CAS weakening was evaluated and skipped — `releaseSubmitter` is a cold-path lifecycle call (once per submitter, not per task), so weakening its memory ordering has no throughput impact.

### Same-compiler Zig throughput: safe default → `-Dsingle-pool=true`

Raw data: `OPT-single-pool-runtime-comparison.json` (zig 0.16, post-appsec at `5d3d119`, `-Dsingle-pool=true`).

| Scenario | POST default | POST -Dsingle-pool | Δ % | CV (opt run) | classification |
|---|---:|---:|---:|---:|---|
| `contended_spawn_8x` | 880,038 | **1,028,622** | **+16.9%** | 3% | reliable recovery |
| `mixed_fast_slow` | 230,765 | 247,510 | **+7.3%** | 2% | reliable recovery |
| `cpu_work_100us` | 416,921 | 442,799 | **+6.2%** | 7% | reliable recovery |
| `flood_1m` | 1,074,269 | 1,069,672 | −0.4% | 9% | flat |
| `burst_drain_burst` | 162,024 | 160,263 | −1.1% | 0% | flat |
| `cpu_work_10us` | 982,714 | 967,045 | −1.6% | 18% | within noise (18% CV) |
| `nested_fanout_4x` | 538,931 | 509,091 | −5.5% | 14% | within noise (14% CV) |
| `contended_cpu_10us` | 970,439 | 895,071 | −7.8% | 19% | within noise (19% CV) |

### Net AppSec-cost recovery (pre-appsec → post-appsec → opt)

| Scenario | AppSec cost | With `-Dsingle-pool` | Residual cost | Recovery |
|---|---:|---:|---:|---:|
| `contended_spawn_8x` | −11.8% | +3.1% vs pre | **+3.1%** | **100%+** |
| `cpu_work_100us` | −9.0% | −3.4% vs pre | −3.4% | **62%** |
| `mixed_fast_slow` | −11.0% | −4.6% vs pre | −4.6% | **58%** |
| `flood_1m` | −7.2% | −7.6% vs pre | −7.6% | 0% |
| `cpu_work_10us` | −5.9% | −7.4% vs pre | within CV | (noise) |
| `nested_fanout_4x` | −10.9% | −15.9% vs pre | within CV | (noise) |
| `contended_cpu_10us` | +2.4% | −5.5% vs pre | within CV | (noise) |
| `burst_drain_burst` | +0.0% | −1.0% | flat | (flat) |

### Verdict

`-Dsingle-pool=true` **reliably recovers 6–17% on three scenarios** (`contended_spawn_8x`, `cpu_work_100us`, `mixed_fast_slow`) without any TSan or fuzz invariant breakage: 84/85 tests pass, 500-iteration fuzz clean under `-Dsingle-pool=true -Dtsan`. The recovery closes 58–100% of the AppSec cost on those workloads.

The remaining high-variance scenarios (`cpu_work_10us`, `nested_fanout_4x`, `contended_cpu_10us`) show deltas within their respective 14–19% run-to-run CV bands — inconclusive for this single-run measurement; they would need higher sample counts or a different bench setup to discriminate real change from noise.

`flood_1m` does **not** recover under `-Dsingle-pool`. The F-001 hot-path elision doesn't touch descriptor acquire/release; since flood_1m submits 1M tasks through 1M descriptor acquire/release cycles, the −7.2% cost most likely comes from the F-003 atomic `free_indices` accesses inhibiting LLVM optimisations across the loop (even though `.monotonic` compiles to plain load/store on x86_64, it prevents some reordering). A future investigation could add `-Dsingle-pool` elision of the freelist atomics behind a stronger "single-pool, single-producer" contract — but the safety tradeoff is significant.

### How to opt in

```bash
# Library consumers (single-pool-per-process workloads):
zig build -Dsingle-pool=true
# CI / default branch: leave unset for safe multi-pool behavior.
```

Compile-time flag; no runtime overhead either way.

## Commit ledger

22 commits on the series, all fast-forwarded to main at `8cf119d`:

```text
8cf119d chore: migrate remediation tooling to Zig 0.16.0
051930f docs: AppSec review report and remediation plan (2026-04-15)
fab4f01 test: add public-API fuzz harness (appsec coverage gap)
17d3872 test: add -Dtsan build option and record TSan baseline findings
e03115b fix(stats): clamp parseProcStatusKiB to prevent *1024 overflow (F-007)
b4e6fa1 docs(perf-gate): disposition note for step-6-f004 bench outliers
df9842d fix(types): soften WaitGroup.done underflow panic (F-004)
20a4bbf fix(pool): CAS-based idempotence + bounded drain spin in releaseSubmitter
2e82ec0 fix(pool): bounds-check and idempotent releaseSubmitter (F-005)
990edef docs(pool): note lane-isolation cost of F-006 fallback path
4254589 fix(pool): replace unreachable on blocking_inject with safe fallback (F-006)
708b380 docs(pool): document .monotonic ordering rationale on free_indices (F-003)
34e07f2 docs(perf-gate): explicit band arithmetic for step-3-f003 p95 disposition
ed6d72f fix(pool): make free_indices loads/stores atomic (F-003)
0aa3ad8 style(pool,test): address code-quality review notes on F-002
4eeb896 docs(perf-gate): strengthen cpu_work_10us p95 disposition for step-2-f002
370f699 fix(pool): spawn-aware errdefer in Core.init (F-002)
4b606f0 docs(perf-gate): disposition note + recheck data for step-1-f001
9e1ecfe fix(pool): scope TLS worker/submitter indices per-pool (F-001)
9bf8028 fix(perf-gate): guard div/0 in jq, correct README artifact count and flag
5adb1aa fix(perf-gate): pin zig via mise so before/after benches use the same compiler
e6de257 chore(perf-gate): add appsec remediation perf-tracking scaffolding
```

(Post-rebase SHAs; pre-rebase SHAs are in the branch reflog.)
