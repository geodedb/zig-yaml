# Re-Profile Post-G2 Re-Land Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Produce fresh wall-clock per-thread evidence and updated A/B-disable ceilings for the three remaining single-atomic targets at main tip `ce0d56b` (post Phase G2 Re-Land, flood_1m = 462K ops/s), then write an evidence-backed ordered recommendation for the next phase.

**Architecture:** This is a **measurement plan, not a code-shipping plan**. All atomic "stubs" are throwaway diffs on scratch branches that get reverted after measurement. The plan output is a written report (`docs/PERFORMANCE_TRACKING.md § 2026-04-13 Re-Profile`) and updated `memory/project_phase_status.md`. No code lands in main from this plan.

**Tech Stack:** Zig 0.14+, `perf sched` (Linux kernel ≥ 5.x), `bench_tokio_parity.zig`, `tests/stress.zig`.

**Methodology rules (non-negotiable):**
1. **Force-rebuild every measurement.** `zig build -Doptimize=ReleaseFast` as a dedicated step, then invoke the compiled binary directly at `zig-out/bin/thread-pool-tokio-parity`. Never trust `zig build bench-tokio-parity` to rebuild (methodology lesson #8).
2. **n=10 minimum for any throughput claim.** n=5 is the in-session sanity check; n=10 medians are the decision signal (methodology lesson, G2 Re-Land Task 6).
3. **20× stress gate for any A/B that stubs an atomic on the submit/wake hot path**, run at ReleaseFast before trusting the A/B number (methodology lesson #9). If an A/B stub deadlocks / crashes, that itself is a useful signal — note it and move on; a ceiling that requires a correctness fix to reach is still a valid ceiling datum.
4. **Each A/B is one commit on a throwaway branch, measured, documented, then the branch is abandoned.** Do not rebase, cherry-pick, or merge any A/B branch.

---

## File Structure

Files produced by this plan (in order of creation):

- `docs/superpowers/plans/2026-04-13-reprofile-post-g2.md` — this plan (already exists after Task 0).
- `docs/performance/reprofile-2026-04-13/baseline.txt` — raw bench output, n=10 at `ce0d56b`.
- `docs/performance/reprofile-2026-04-13/perf-sched-report.md` — wall-clock per-thread breakdown, critical-path thread analysis.
- `docs/performance/reprofile-2026-04-13/ab-submitted-fetchadd.md` — A/B stub design, n=10 numbers, stress result, branch SHA, computed ceiling.
- `docs/performance/reprofile-2026-04-13/ab-descriptor-cas.md` — same shape.
- `docs/performance/reprofile-2026-04-13/ab-wake-scan.md` — same shape.
- `docs/performance/reprofile-2026-04-13/SUMMARY.md` — synthesis + ordered recommendation.
- `docs/PERFORMANCE_TRACKING.md` — add `§ 2026-04-13 Re-Profile` section pointing at the summary.
- `~/.claude/projects/-home-benji-src-devnw-zig-thread-pool/memory/project_phase_status.md` — updated ceilings, next-action priority revised against fresh evidence.

Scratch branches (created, measured, abandoned):

- `profile/ab-submitted-fetchadd-stub`
- `profile/ab-descriptor-cas-stub`
- `profile/ab-wake-scan-stub`

---

## Task 0: Setup

**Files:**
- Create: `docs/performance/reprofile-2026-04-13/` (directory)

- [ ] **Step 1: Verify starting state is main at `ce0d56b`**

```bash
git checkout main
git rev-parse HEAD
# Expected: ce0d56b5... (or newer if main has advanced — abort if so and ask user whether to rebase the plan)
git status
# Expected: clean working tree (no uncommitted changes). Abort if dirty.
```

- [ ] **Step 2: Verify toolchain**

```bash
zig version
# Expected: 0.14.x or newer
which perf
# Expected: /usr/bin/perf or similar — if missing, install linux-perf package before continuing
perf sched --help 2>&1 | head -5
# Expected: usage message including `record`, `latency`, `timehist`. If `sched` subcommand missing, abort.
```

- [ ] **Step 3: Create output directory**

```bash
mkdir -p docs/performance/reprofile-2026-04-13
ls docs/performance/reprofile-2026-04-13
# Expected: empty directory exists
```

- [ ] **Step 4: Commit the empty directory marker**

```bash
echo "# Re-profile artifacts, 2026-04-13" > docs/performance/reprofile-2026-04-13/README.md
git add docs/performance/reprofile-2026-04-13/README.md docs/superpowers/plans/2026-04-13-reprofile-post-g2.md
git commit -m "docs(reprofile): scaffold 2026-04-13 re-profile plan and artifacts dir"
```

---

## Task 1: Baseline flood_1m at `ce0d56b`, n=10

**Files:**
- Create: `docs/performance/reprofile-2026-04-13/baseline.txt`

- [ ] **Step 1: Force-rebuild in ReleaseFast**

```bash
rm -rf zig-out/ .zig-cache/
zig build -Doptimize=ReleaseFast
ls -la zig-out/bin/thread-pool-tokio-parity
# Expected: binary exists, non-zero size, mtime is seconds ago
```

- [ ] **Step 2: Run flood_1m 10×, direct binary invocation**

```bash
{
  echo "# Baseline at $(git rev-parse --short HEAD) ($(date -Iseconds))"
  echo "# n=10, ReleaseFast, direct binary invocation"
  for i in $(seq 1 10); do
    echo "--- run $i ---"
    ./zig-out/bin/thread-pool-tokio-parity flood_1m
  done
} | tee docs/performance/reprofile-2026-04-13/baseline.txt
```

Expected: 10 runs, each printing an `ops/s` line for `flood_1m`. Median ops/s should be in the 430K–490K band (G2 Re-Land reported 462K median at n=5).

- [ ] **Step 3: Compute n=10 median and record**

```bash
grep 'scenario=flood_1m' docs/performance/reprofile-2026-04-13/baseline.txt \
  | grep -Eo 'ops_per_sec=[0-9]+' | grep -Eo '[0-9]+' | sort -n | awk '
      {a[NR]=$1}
      END {
        n=NR;
        if (n%2) print "median:", a[(n+1)/2];
        else print "median:", (a[n/2]+a[n/2+1])/2;
        print "min:", a[1]; print "max:", a[n]; print "n:", n;
      }' \
  | tee -a docs/performance/reprofile-2026-04-13/baseline.txt
```

Expected output appended at end of `baseline.txt`:

```
median: <int in 430000..490000>
min:    <int>
max:    <int>
n: 10
```

**If median < 400K or > 520K**, STOP. Something changed — either main moved, the machine is noisy, or the build config drifted. Report to user; do not proceed.

- [ ] **Step 4: Commit**

```bash
git add docs/performance/reprofile-2026-04-13/baseline.txt
git commit -m "perf(reprofile): baseline flood_1m n=10 at ce0d56b"
```

---

## Task 2: Wall-clock per-thread perf sched at `ce0d56b`

**Files:**
- Create: `docs/performance/reprofile-2026-04-13/perf-sched-report.md`
- Create (transient, do not commit): `perf.data`

- [ ] **Step 1: Record a perf sched trace of a single flood_1m run**

```bash
# perf sched requires root-equivalent privileges (kernel.perf_event_paranoid).
# If the next command fails with "permission denied", rerun under sudo OR
# `sudo sysctl -w kernel.perf_event_paranoid=-1` for the session.
perf sched record -o /tmp/reprofile-perf.data -- \
  ./zig-out/bin/thread-pool-tokio-parity flood_1m 2>&1 \
  | tee docs/performance/reprofile-2026-04-13/perf-sched-stdout.txt
ls -la /tmp/reprofile-perf.data
# Expected: file exists, tens to hundreds of MB
```

- [ ] **Step 2: Extract latency view (who was blocked, and on what)**

```bash
perf sched latency -i /tmp/reprofile-perf.data \
  > docs/performance/reprofile-2026-04-13/perf-sched-latency.txt 2>&1
head -30 docs/performance/reprofile-2026-04-13/perf-sched-latency.txt
# Expected: per-thread table with "Runtime", "Switches", "Wait time (avg/max)"
```

- [ ] **Step 3: Extract timehist (wall-clock timeline per thread)**

```bash
perf sched timehist -i /tmp/reprofile-perf.data \
  > docs/performance/reprofile-2026-04-13/perf-sched-timehist.txt 2>&1
wc -l docs/performance/reprofile-2026-04-13/perf-sched-timehist.txt
# Expected: tens of thousands of scheduling events
```

- [ ] **Step 4: Identify the submitter thread and compute its run/block fractions**

Open `perf-sched-latency.txt`. The submitter thread is the one named `thread-pool-to` (main benchmark thread) OR has the highest total runtime that is NOT a `worker-*` thread. Look for the row with the largest `Runtime ms` outside the worker pool.

Record, in `perf-sched-report.md`:

```markdown
# perf sched report — ce0d56b flood_1m

## Submitter thread (pid/tid: <fill>, name: <fill>)

- Total wall-clock covered by trace: <from `head -1 perf-sched-timehist.txt` vs last line>
- Runtime: <ms from latency table>
- Switches: <count>
- Avg wait: <ms>
- Max wait: <ms>
- **% running (runtime / wall-clock):** <compute>
- **% blocked:** <100 − above>
- **Dominant block cause (from timehist `prev_state` column):** <S = sleeping/futex, D = disk, R = runnable-but-preempted>

## Worker threads (n=56 on this host; confirm via `nproc`)

- Median worker runtime: <ms>
- Median worker % running: <compute>
- Fraction of workers with > 50% block time: <count>

## Critical-path determination

Which thread holds the critical path? Per methodology: the thread whose runtime ≈ wall-clock (i.e. 85–95% running) is the bottleneck. If the submitter is 85%+ running, the submit path is the critical path — steal/wake optimizations have limited headroom.

**Finding:** <one sentence — e.g., "submitter is 91% running, workers median 28% running, so submit path dominates, matching the pre-G2 analysis.">
```

- [ ] **Step 5: Flag any surprises**

In the same report, add a `## Deltas vs pre-G2 (2026-04-12 measurement)` section. The pre-G2 measurement (recorded in `memory/project_phase_status.md`) showed submitter at 89% CPU-bound. If the fresh measurement shows a materially different shape (e.g. submitter drops below 70% running OR workers jump above 50% running), that means G2 Re-Land shifted the critical path and the rest of this plan's A/B priorities may be wrong. **Call this out explicitly.** If there's no material shift, say so.

- [ ] **Step 6: Clean up trace file and commit report**

```bash
rm -f /tmp/reprofile-perf.data
git add docs/performance/reprofile-2026-04-13/perf-sched-report.md \
        docs/performance/reprofile-2026-04-13/perf-sched-latency.txt \
        docs/performance/reprofile-2026-04-13/perf-sched-timehist.txt \
        docs/performance/reprofile-2026-04-13/perf-sched-stdout.txt
git commit -m "perf(reprofile): wall-clock per-thread perf sched at ce0d56b"
```

---

## Task 3: A/B-disable `submitted.fetchAdd` (G3 candidate, pre-G2 ceiling +28%)

**Files:**
- Create (on branch, throwaway): modify `src/pool.zig:597` and `src/pool.zig:700`
- Create: `docs/performance/reprofile-2026-04-13/ab-submitted-fetchadd.md`

**Rationale:** `self.counters.submitted.fetchAdd(1, .monotonic)` at `src/pool.zig:597` runs on every `spawn` call. Its only documented reader is the rotation mixing at `src/pool.zig:700` (`worker_index +% @truncate(submitted.load(.monotonic))`). If we stub the fetchAdd to a no-op and replace the reader with a constant, we measure the ceiling achievable by removing that atomic from the submit path. Any consumer we miss will manifest as a test failure — acceptable, because this is a throwaway branch.

- [ ] **Step 1: Create scratch branch**

```bash
git checkout -b profile/ab-submitted-fetchadd-stub
```

- [ ] **Step 2: Audit all readers of `counters.submitted`**

```bash
# Record every access so we know what we're stubbing.
```

Use Grep: `submitted\.` in `src/pool.zig` (already done during plan research — confirmed readers are lines 501 (snapshot getter), 597 (writer), 607 (wake hint), 700 (steal start mixing)). Confirm nothing outside `src/pool.zig` reads it:

```bash
```

Run Grep over `src/` and `benchmarks/` and `tests/` for `\.submitted` and `counters\.submitted`. If any hit outside `src/pool.zig`, note in the AB report; consumers of the snapshot getter at :501 are tolerable (they'll see the frozen value).

- [ ] **Step 3: Apply the stub**

Modify `src/pool.zig` — replace the fetchAdd at line 597 with a comment, and replace both loads (607, 700) with 0:

```zig
// src/pool.zig line 597 — was:
//     _ = self.counters.submitted.fetchAdd(1, .monotonic);
// replaced with:
        // AB-STUB: submitted.fetchAdd removed to measure ceiling. Do not merge.

// src/pool.zig line 607 — was:
//         const submitted = self.counters.submitted.load(.monotonic);
// replaced with:
        const submitted: u64 = 0; // AB-STUB

// src/pool.zig line 700 — was:
//     const start = (worker_index +% @as(usize, @truncate(self.counters.submitted.load(.monotonic)))) % self.workers.len;
// replaced with:
            const start = worker_index % self.workers.len; // AB-STUB: submitted mixing removed
```

- [ ] **Step 4: Force-rebuild and smoke-verify**

```bash
rm -rf zig-out/ .zig-cache/
zig build -Doptimize=ReleaseFast
zig build test
# Expected: unit tests pass. If they fail, the stub broke a reader we didn't know about —
# document which test and which reader, then skip to Step 7 and record the A/B as
# "ceiling unknown — stub breaks correctness; needs real implementation".
```

- [ ] **Step 5: Stress gate (20× ReleaseFast)**

```bash
{
  pass=0; fail=0
  for i in $(seq 1 20); do
    if zig build test-stress -Doptimize=ReleaseFast > /tmp/stress-$i.log 2>&1; then
      pass=$((pass+1))
      echo "run $i: PASS"
    else
      fail=$((fail+1))
      echo "run $i: FAIL"
    fi
  done
  echo "=== SUMMARY: pass=$pass fail=$fail ==="
} | tee docs/performance/reprofile-2026-04-13/ab-submitted-stress.txt
```

Expected: `pass=20 fail=0`. If any failures, this stub is unsafe — the A/B measurement is still valid as a ceiling datum, but flag it in Step 7.

- [ ] **Step 6: Measure flood_1m n=10**

```bash
{
  echo "# A/B stub: submitted.fetchAdd removed, submitted reader = 0"
  echo "# branch: $(git rev-parse --short HEAD), n=10, ReleaseFast"
  for i in $(seq 1 10); do
    echo "--- run $i ---"
    ./zig-out/bin/thread-pool-tokio-parity flood_1m
  done
} | tee docs/performance/reprofile-2026-04-13/ab-submitted-raw.txt
grep 'scenario=flood_1m' docs/performance/reprofile-2026-04-13/ab-submitted-raw.txt \
  | grep -Eo 'ops_per_sec=[0-9]+' | grep -Eo '[0-9]+' | sort -n | awk '
      {a[NR]=$1}
      END {
        if (NR%2) print "median:", a[(NR+1)/2];
        else print "median:", (a[NR/2]+a[NR/2+1])/2;
        print "n:", NR
      }' | tee -a docs/performance/reprofile-2026-04-13/ab-submitted-raw.txt
```

- [ ] **Step 7: Write the A/B report**

Create `docs/performance/reprofile-2026-04-13/ab-submitted-fetchadd.md`:

```markdown
# A/B: submitted.fetchAdd stub

**Branch:** `profile/ab-submitted-fetchadd-stub` at `<short SHA>` (do not merge).

**Stub:** `src/pool.zig:597,607,700` — removed fetchAdd, replaced reads with 0 / removed mixing.

**Readers audited:**
- line 501: snapshot getter — still returns a stale 0; callers: `<list>`.
- line 607: wake hint — replaced with constant 0; effect: always starts scan at worker 0.
- line 700: steal start mixing — replaced with `worker_index` alone.

**Stress result:** pass=<>, fail=<>. (20× ReleaseFast.)

**Baseline (Task 1):** median = <B> ops/s (n=10).

**Stubbed:** median = <S> ops/s (n=10).

**Lift:** `(S − B) / B * 100` = **<X>%**.

**Pre-G2 ceiling (2026-04-12, 331K baseline):** +28% → 422K.

**Interpretation:**
- If lift is within ±5% of the pre-G2 ceiling, the atomic is still a real target — proceed with G3 plan.
- If lift is materially smaller now (e.g. +10% or less), G2 Re-Land consumed most of the `submitted` contention indirectly (plausible: removing the `queued_tasks` poll may have reduced cacheline eviction pressure that `submitted` piggybacked on). G3 moves down the priority list.
- If lift is materially larger (unlikely, but possible), G3 is now the top target ahead of wake-scan.
```

- [ ] **Step 8: Commit report, abandon stub branch**

```bash
git add docs/performance/reprofile-2026-04-13/ab-submitted-fetchadd.md \
        docs/performance/reprofile-2026-04-13/ab-submitted-raw.txt \
        docs/performance/reprofile-2026-04-13/ab-submitted-stress.txt
git commit -m "perf(reprofile): A/B submitted.fetchAdd stub measurement"
# Commit the report on the stub branch, then go back to main.
# Do NOT merge this branch — its src/pool.zig change is a stub.
# We need the report on main, so cherry-pick only the docs commit.
REPORT_SHA=$(git rev-parse HEAD)
git checkout main
git cherry-pick "$REPORT_SHA"
# Expected: cherry-pick succeeds (only docs files changed in that commit).
```

---

## Task 4: A/B-disable descriptor free-list CAS (pre-G2 ceiling +16%)

**Files:**
- Modify (on branch, throwaway): `src/pool.zig` — replace `acquireDescriptor` free-list CAS loop with a Mutex-guarded bump.
- Create: `docs/performance/reprofile-2026-04-13/ab-descriptor-cas.md`

**Rationale:** `acquireDescriptor` at `src/pool.zig:983` is a CAS-loop on `free_top_tagged`. Stubbing it to a per-call mutex-guarded bump (no reuse) removes the CAS contention at the cost of descriptor exhaustion under sustained load — acceptable for a short `flood_1m` run (1M tasks, pool size typically ≥ that or wrapped via capacity check). If we hit `TaskPoolExhausted`, raise the pool capacity in the benchmark config for the duration of this A/B only.

- [ ] **Step 1: Create scratch branch from main**

```bash
git checkout main
git checkout -b profile/ab-descriptor-cas-stub
```

- [ ] **Step 2: Determine current pool capacity**

```bash
```

Grep `src/pool.zig` for `descriptors` (declaration) and `max_tasks` / `capacity` in `Config`. Record the current flood_1m run's pool capacity.

Read `benchmarks/bench_tokio_parity.zig` — find the `flood_1m` config block. Check whether its `max_tasks` / capacity ≥ 1_048_576 (the flood count). If not, we'll need to bump it for the A/B run.

- [ ] **Step 3: Apply the stub**

Replace `acquireDescriptor` body at `src/pool.zig:983-1007` with a monotonic bump guarded by a single mutex field on `Core`. Sketch:

```zig
// Add to Core struct (scratch only):
ab_bump_mutex: std.Thread.Mutex = .{},
ab_bump_next: u32 = 0,

// Replace acquireDescriptor body:
fn acquireDescriptor(self: *Core) ?u32 {
    self.ab_bump_mutex.lock();
    defer self.ab_bump_mutex.unlock();
    if (self.ab_bump_next >= self.descriptors.len) return null;
    const head = self.ab_bump_next;
    self.ab_bump_next += 1;
    var descriptor = &self.descriptors[head];
    const prev_generation = descriptor.generation;
    descriptor.* = .{};
    descriptor.generation = prev_generation +% 1;
    if (descriptor.generation == 0) descriptor.generation = 1;
    if (claim_sentinel_enabled) descriptor.claimed_by.store(-1, .release);
    descriptor.state.store(.reserved, .release);
    const live = self.counters.task_desc_live.fetchAdd(1, .monotonic) + 1;
    updatePeak(&self.counters.task_desc_peak, live);
    return head;
}
```

Leave `releaseDescriptor` as-is — it touches the free-list, but since `ab_bump_next` never consults the free-list again, releases are just no-ops from the allocator's perspective. (If the current `releaseDescriptor` panics on double-release, scrub its body to a bare `descriptor.state.store(.free, .release); _ = self.counters.task_desc_live.fetchSub(1, .monotonic);` — note in the report if you did.)

**If pool capacity < 1_048_576:** also modify the bench config (in `benchmarks/bench_tokio_parity.zig` flood_1m setup) to set `max_tasks = 2_000_000` for this A/B only. Document in the report.

- [ ] **Step 4: Force-rebuild and smoke-verify**

```bash
rm -rf zig-out/ .zig-cache/
zig build -Doptimize=ReleaseFast
zig build test
# Expected: unit tests pass OR fail only on tests that submit > pool size (descriptor exhaustion).
# Acceptable failure: document which tests.
```

- [ ] **Step 5: Stress gate (20× ReleaseFast)**

Same command as Task 3 Step 5, results → `docs/performance/reprofile-2026-04-13/ab-descriptor-stress.txt`. Stress tests may exhaust the pool — if so, record "stress gate N/A (pool exhaustion by design)" rather than pass/fail, and proceed.

- [ ] **Step 6: Measure flood_1m n=10**

Same as Task 3 Step 6, output → `docs/performance/reprofile-2026-04-13/ab-descriptor-raw.txt`.

If the measurement run errors with `TaskPoolExhausted`, increase pool capacity in bench config and re-run. Note the capacity used.

- [ ] **Step 7: Write the A/B report**

Create `docs/performance/reprofile-2026-04-13/ab-descriptor-cas.md` using the same template as Task 3 Step 7, substituting:
- **Stub:** "acquireDescriptor replaced with Mutex-guarded bump; no reuse. Pool capacity = `<N>`."
- **Pre-G2 ceiling:** +16% → 383K.
- **Interpretation criterion:** within ±5% of pre-G2 ceiling = still a real target.

- [ ] **Step 8: Commit report, cherry-pick back to main**

Same pattern as Task 3 Step 8: commit on stub branch, checkout main, cherry-pick only the docs commit.

---

## Task 5: A/B-disable wake scan (pre-G2 ceiling +47%, highest-ceiling target)

**Files:**
- Modify (on branch, throwaway): `src/pool.zig:600-624` — short-circuit the wake-scan to a no-op.
- Create: `docs/performance/reprofile-2026-04-13/ab-wake-scan.md`

**Rationale:** Replace the `while (off < self.workers.len)` wake-scan block at `src/pool.zig:609-624` with an early `return` after the `incrementQueued()` call. Workers will self-wake by observing `queued_tasks` on spin exit (the submit-before-park handshake at `src/pool.zig:895` guarantees no lost wakeup if workers are already parked and spinning). Under flood_1m, most workers are busy in steal loops, so skipping the scan should lose few real wakes — but **under intermittent-load workloads, workers that are fully parked will never be signaled**, so this stub is only valid for flood_1m measurement and will fail many stress tests. Expect stress failures; they are informational, not blocking.

- [ ] **Step 1: Create scratch branch from main**

```bash
git checkout main
git checkout -b profile/ab-wake-scan-stub
```

- [ ] **Step 2: Apply the stub**

Modify `src/pool.zig` — replace lines 607-624 (the `submitted` hint load through the scan's closing `}`) with:

```zig
// AB-STUB: wake-scan removed. Workers rely on their own spin/park self-wake.
// Only valid for flood_1m measurement — other workloads will lose wakeups.
_ = submitted; // avoid unused-var if it's still in scope; delete if not.
```

(Adjust surrounding variable declarations to avoid unused-local errors. Use `_ = self.workers.len;` etc. if needed.)

- [ ] **Step 3: Force-rebuild and smoke-verify**

```bash
rm -rf zig-out/ .zig-cache/
zig build -Doptimize=ReleaseFast
zig build test 2>&1 | tee /tmp/wake-stub-unit.log
# Expected: SOME unit tests will fail (any test that submits a task while workers are parked).
# This is expected. Record which tests fail.
```

- [ ] **Step 4: Stress gate — 20× ReleaseFast (expected to fail)**

Same command shape as Task 3. Output → `docs/performance/reprofile-2026-04-13/ab-wake-scan-stress.txt`.

Expected: many/all runs fail. Record the failure count. A ceiling measurement is still valid; we just can't ship this stub.

- [ ] **Step 5: Measure flood_1m n=10**

Same as Task 3 Step 6, output → `docs/performance/reprofile-2026-04-13/ab-wake-scan-raw.txt`.

**If flood_1m itself hangs/crashes under this stub**, abort the per-run with a timeout:

```bash
for i in $(seq 1 10); do
  echo "--- run $i ---"
  timeout 60s ./zig-out/bin/thread-pool-tokio-parity flood_1m || echo "run $i: TIMEOUT/CRASH"
done
```

A `TIMEOUT` outcome means the stub has broken flood_1m's correctness (workers are parked permanently) — the ceiling cannot be measured this way. Fall back to a weaker stub in Step 5a.

- [ ] **Step 5a: Fallback stub (only if Step 5 hangs)**

Instead of skipping the scan entirely, replace the `seq_cst` load at `src/pool.zig:613` with `.monotonic` AND break after the first iteration regardless of whether we found a parked worker:

```zig
// AB-STUB (weaker): monotonic load, scan at most 1 worker.
if (self.workers[hint_idx].is_parked.load(.monotonic) == 1) {
    self.workers[hint_idx].park_mutex.lock();
    if (self.workers[hint_idx].is_parked.load(.monotonic) == 1) {
        self.workers[hint_idx].park_cond.signal();
    }
    self.workers[hint_idx].park_mutex.unlock();
}
```

Rebuild, re-run. Note in the report that the ceiling here is a lower bound (weaker stub).

- [ ] **Step 6: Write the A/B report**

Create `docs/performance/reprofile-2026-04-13/ab-wake-scan.md`. Same template. Substitutions:
- **Stub:** which variant (no-wake OR weaker 1-iter monotonic).
- **Stress:** expected failures documented; ceiling treated as upper bound (no-wake variant) or lower bound (weaker variant).
- **Pre-G2 ceiling:** +47% → 488K.
- **Interpretation:** if lift ≥ +30%, wake-scan remains the highest-ceiling target and justifies the complexity of a sharded / orthogonal-gate redesign. If lift is < +15%, G2 Re-Land absorbed much of the cost indirectly (worker self-wake via removed idle-spin poll overlaps) and wake-scan drops in priority.

- [ ] **Step 7: Commit report, cherry-pick to main**

Same pattern as Tasks 3 & 4.

---

## Task 6: Synthesis and ordered recommendation

**Files:**
- Create: `docs/performance/reprofile-2026-04-13/SUMMARY.md`
- Modify: `docs/PERFORMANCE_TRACKING.md` — append `§ 2026-04-13 Re-Profile` section
- Modify: `~/.claude/projects/-home-benji-src-devnw-zig-thread-pool/memory/project_phase_status.md`

- [ ] **Step 1: Verify we're on main with all three A/B reports cherry-picked**

```bash
git checkout main
ls docs/performance/reprofile-2026-04-13/
# Expected files: README.md, baseline.txt, perf-sched-*, ab-submitted-*, ab-descriptor-*, ab-wake-scan-*
git log --oneline -10
# Expected: 5 reprofile commits on main (scaffold, baseline, perf-sched, 3× A/B reports).
```

- [ ] **Step 2: Write the summary**

Create `docs/performance/reprofile-2026-04-13/SUMMARY.md`:

```markdown
# Re-Profile Summary — 2026-04-13 (main tip ce0d56b, post G2 Re-Land)

## Baseline

- flood_1m median: **<B>K ops/s** (n=10, ReleaseFast, direct binary).
- Submitter: <X>% running, <Y>% blocked on <cause>. Worker median: <Z>% running.
- Critical path: <submitter|worker|inconclusive>.

## Fresh single-atomic ceilings (vs <B>K baseline)

| Target | Fresh lift | Pre-G2 lift (vs 331K) | Delta interpretation | Blast radius |
|---|---|---|---|---|
| submitted.fetchAdd (G3) | +<>% | +28% | <still-real | diminished | amplified> | Small |
| Descriptor CAS | +<>% | +16% | <> | Small (per-worker shards) |
| Wake scan | +<>% | +47% | <> | Hard (no bitmap — G1 lesson) |

## Compound check

Sum of fresh lifts: +<>%. Pre-G2 measured compound was +210% for all four atomics. Current three-atomic compound prediction (naive additive): <>%. Reality is likely lower due to interaction effects.

## Ordered next-phase recommendation

1. **<top target>** — rationale: <fresh ceiling> × <blast-radius score> = best expected-value.
2. **<second>** — rationale.
3. **<third>** — rationale.

## Methodology flags

- <any surprise findings — e.g., "wake-scan ceiling dropped from +47% to +12% unexpectedly; G2 Re-Land appears to have shifted the critical path off the wake mechanism.">
- <any stubs that couldn't be measured cleanly — documented as ceiling bounds rather than point estimates.>

## Decision for the user

Based on evidence, the next phase should be **<choice>**. Alternatives and why they were not chosen: <brief>.

If the user disagrees with the ordering, the raw data in `docs/performance/reprofile-2026-04-13/` supports re-prioritization without redoing measurements.
```

Fill in every `<>` placeholder with the actual numbers from Tasks 1, 2, 3, 4, 5. **No `<>` placeholders may remain in the committed file.**

- [ ] **Step 3: Append section to `docs/PERFORMANCE_TRACKING.md`**

Append a new section at the end of the file:

```markdown
## 2026-04-13 Re-Profile (post Phase G2 Re-Land, main tip ce0d56b)

Baseline: <B>K ops/s flood_1m n=10 ReleaseFast.

Fresh A/B-disable ceilings:
- submitted.fetchAdd: +<>% (pre-G2: +28%)
- Descriptor CAS: +<>% (pre-G2: +16%)
- Wake scan: +<>% (pre-G2: +47%)

Full report: `docs/performance/reprofile-2026-04-13/SUMMARY.md`.

Next-phase ordering: 1. <>, 2. <>, 3. <>.
```

- [ ] **Step 4: Update memory — `project_phase_status.md`**

Edit `~/.claude/projects/-home-benji-src-devnw-zig-thread-pool/memory/project_phase_status.md`:

- Update the "Verified critical path for flood_1m" section: replace the pre-G2 ceiling numbers with the fresh ones, and update the date to 2026-04-13.
- Update "Next-action priority": replace with the ordering from SUMMARY.md step 2.
- Add a `**Last reprofile:** 2026-04-13 at `ce0d56b`, baseline <B>K, artifacts in `docs/performance/reprofile-2026-04-13/`.` line.

- [ ] **Step 5: Commit**

```bash
git add docs/performance/reprofile-2026-04-13/SUMMARY.md docs/PERFORMANCE_TRACKING.md
git commit -m "docs(reprofile): 2026-04-13 summary — fresh ceilings and next-phase ordering"
# Memory file is outside the repo — update separately, no commit.
```

- [ ] **Step 6: Report back to user**

Produce a ≤ 200-word summary message containing:
- Baseline number.
- Three fresh ceilings with sign (hold/lost/amplified vs pre-G2).
- Critical-path finding (any shift from submitter-bound?).
- Recommended next phase and why.
- Offer: "Ready to write the <chosen phase> implementation plan?"

Do NOT proceed to implement the chosen phase in this session — the user decides.

---

## Done criteria

- [ ] `docs/performance/reprofile-2026-04-13/SUMMARY.md` exists on main with no `<>` placeholders.
- [ ] `docs/PERFORMANCE_TRACKING.md` has a `§ 2026-04-13 Re-Profile` section.
- [ ] `memory/project_phase_status.md` reflects fresh ceilings and updated next-action priority.
- [ ] Three scratch branches exist but are not merged: `profile/ab-submitted-fetchadd-stub`, `profile/ab-descriptor-cas-stub`, `profile/ab-wake-scan-stub`.
- [ ] Main working tree is clean, main tip is still descended from `ce0d56b` + only docs commits.

## Non-goals (explicitly out of scope)

- Implementing G3, descriptor shards, or wake-scan redesign. This plan only measures.
- Touching architectural work (Chase-Lev, event-wake, lock-free inject). Those require separate plans.
- Fixing the Phase H residual duplicate-emission root cause. Opportunistic; separate plan if benchmarks warrant.
- Merging any of the `profile/ab-*` scratch branches. They are throwaway by design.
