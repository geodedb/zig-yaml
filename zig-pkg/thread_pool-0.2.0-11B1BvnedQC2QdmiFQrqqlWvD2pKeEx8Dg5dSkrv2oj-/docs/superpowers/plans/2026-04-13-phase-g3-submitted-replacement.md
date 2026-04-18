# Phase G3 — `counters.submitted` Hot-Path Replacement

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eliminate hot-path reads of `counters.submitted` (at `src/pool.zig:607` and `:700`) and isolate its write onto its own cacheline, preserving `Stats.submitted` observability while capturing a meaningful fraction of the A/B-measured +42% ceiling (target: at least +20% lift of flood_1m median, i.e. 566K → 680K+).

**Architecture:** Three-part change.
1. **Split cacheline.** `queued_tasks` and `submitted` currently share a cacheline (Counters hot-write group). Move `submitted` to its own cacheline so the submitter's write doesn't stall the worker-side read of the adjacent value.
2. **Replace wake-hint rotation source.** `spawn` at `:607` currently loads `counters.submitted` to compute `hint_idx = submitted % workers.len`. Replace with a per-Core plain u32 `wake_hint` field, incremented on each spawn. Race-tolerant: it's only a load-distribution hint.
3. **Replace steal-start rotation source.** `nextTask` at `:700` (worker-side) currently loads `counters.submitted` to mix with `worker_index`. Replace with a per-Worker plain u32 `steal_hint` counter; each worker reads/writes only its own slot, so no atomic needed.

After this, `counters.submitted.fetchAdd` stays on the submit path for observability but nothing reads it on the hot path. `Stats.submitted` is unchanged for downstream users.

This is **approach (A) — kill reads, keep writes**. Approach (B) — shard the write into per-worker+external counters with aggregation on snapshot — is a follow-up if approach (A) captures less than 60% of the A/B ceiling (i.e. achieves < 720K median). The plan's Task 6 decides whether to proceed to (B).

**Tech Stack:** Zig 0.15+, `ReleaseFast` optimization, `tests/stress.zig` stress suite, `benchmarks/bench_tokio_parity.zig` workload, `perf sched` methodology (available this session — tracefs chmod from re-profile plan still in effect).

---

## Baseline and evidence (fixed inputs)

- **Baseline:** 566K ops/s flood_1m median n=10, at main `3506b29` / source `ce0d56b` (Task 1 of re-profile plan, committed in `docs/performance/reprofile-2026-04-13/baseline.txt`).
- **A/B ceiling for this phase:** +42% (566K → 803K), 20/20 stress, 10/10 flood_1m above baseline median (re-profile Task 3, report at `docs/performance/reprofile-2026-04-13/ab-submitted-fetchadd.md`).
- **Consumer audit result:** `Stats.submitted` is populated at `src/pool.zig:501`; no test or benchmark asserts against it; `tests/integration.zig:52` uses an unrelated `SpawnManyResult.submitted` field.
- **Methodology (from `memory/feedback_perf_profiling.md`, mandatory):**
  - Force-rebuild from `.zig-cache/` before every measurement.
  - Direct `./zig-out/bin/thread-pool-tokio-parity flood_1m` invocation, not `zig build bench-tokio-parity`.
  - n=10 medians as decision signal (n=5 is thin-sample).
  - 20× ReleaseFast stress gate per change that touches scheduler timing; 100× as final pre-merge gate.
  - Wall-clock / host-load check before each measurement (re-profile Task 4's -14% was confounded by load avg 15).

---

## File Structure

Files modified by this plan:

- `src/pool.zig` — three structural edits:
  - `Counters` struct (currently lines 219-243): split `submitted` out of the "Hot write group (submit path)" cacheline.
  - `Core` struct (currently ~line 245-258): add `wake_hint: u32` field.
  - `Worker` struct (currently lines 167-198): add `steal_hint: u64` field (u64 to match typical rotation math; non-atomic).
  - `enqueueTask` body (currently ~line 594-624): replace wake-hint load with `wake_hint` read+increment.
  - `nextTask` body (currently ~line 697-700): replace steal-start load with `worker.steal_hint` read+increment.

- `tests/unit.zig` — one new test verifying `Stats.submitted` still returns accurate counts after the changes.
- `tests/stress.zig` — no new tests; existing suite is the correctness gate.
- `docs/PERFORMANCE_TRACKING.md` — append `§ Phase G3` section at close-out (Task 6).

Close-out report: `docs/performance/phase-g3-close/SUMMARY.md` (created Task 6).

No new files in `src/`. No API changes (public `Stats.submitted` behavior preserved).

---

## Task 0: Setup — worktree + feature branch

**Files:**
- Create (outside repo): `/home/benji/src/devnw/zig/thread-pool-phase-g3/` (git worktree)

- [ ] **Step 1: Confirm starting state on main**

Run:
```bash
cd /home/benji/src/devnw/zig/thread-pool
git checkout main
git rev-parse HEAD
git status
```
Expected: HEAD at `9da9462` (re-profile close-out) or newer main commit descended from it; clean working tree (one unrelated untracked `docs/superpowers/plans/2026-04-13-phase-h-fix-double-dequeue-race.md` is tolerable).

If HEAD is not descended from `9da9462`, abort — the baseline numbers won't match.

- [ ] **Step 2: Create worktree for isolated work**

```bash
git worktree add -b feat/g3-submitted-replacement \
  /home/benji/src/devnw/zig/thread-pool-phase-g3 main
cd /home/benji/src/devnw/zig/thread-pool-phase-g3
git rev-parse HEAD
git branch --show-current
```
Expected: HEAD matches main tip; branch is `feat/g3-submitted-replacement`.

- [ ] **Step 3: Baseline smoke — confirm the worktree builds and the current baseline holds**

```bash
rm -rf zig-out/ .zig-cache/
zig build -Doptimize=ReleaseFast
./zig-out/bin/thread-pool-tokio-parity flood_1m
```
Expected: one `scenario=flood_1m tasks=1000000 elapsed_ns=... ops_per_sec=N` line, where N is approximately 500K–600K (matches the 566K n=10 median with single-run variance). If N < 400K or > 700K, note the host load with `uptime` and document; proceed but flag that noise may affect per-task measurements.

No commit in this task.

---

## Task 1: Split `submitted` onto its own cacheline

**Files:**
- Modify: `src/pool.zig` — `Counters` struct, lines 219–243.

- [ ] **Step 1: Read the current `Counters` struct**

```bash
sed -n '216,244p' src/pool.zig
```
Expected: prints the Counters struct with `queued_tasks` and `submitted` adjacent in the "Hot write group (submit path)", separated from the worker-path group by `_pad0`.

- [ ] **Step 2: Apply the cacheline split**

Edit `src/pool.zig`. Replace:

```zig
    // === Hot write group (submit path) ===
    queued_tasks: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    submitted: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    _pad0: [cache_line_size - 2 * field_size]u8 = undefined,
```

with:

```zig
    // === Hot write group (submit path, queued_tasks only) ===
    // `queued_tasks` is read by workers in nextTask; `submitted` was moved to
    // its own cacheline (below) so submitter writes to `submitted` do not
    // stall worker reads of `queued_tasks`.
    queued_tasks: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    _pad0a: [cache_line_size - field_size]u8 = undefined,

    // === Cumulative submit counter (observability-only, off hot read path) ===
    // Written at every spawn(); read only by snapshot() (cold path). Isolated
    // onto its own cacheline to decouple from `queued_tasks` write contention.
    submitted: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    _pad0b: [cache_line_size - field_size]u8 = undefined,
```

(Keep the subsequent groups — `active_tasks`/`cancelled` and diagnostic — unchanged.)

- [ ] **Step 3: Verify build**

```bash
rm -rf zig-out/ .zig-cache/
zig build -Doptimize=ReleaseFast 2>&1 | tail -20
```
Expected: build succeeds. If a padding size arithmetic error occurs, `std.atomic.cache_line` is typically 64 and `field_size` is 8 on x86-64, so `_pad0a = [64-8]u8 = [56]u8`; compute locally if needed.

- [ ] **Step 4: Run full unit test suite**

```bash
zig build test 2>&1 | tail -20
```
Expected: all tests pass. The struct change is ABI-internal; no semantic change.

- [ ] **Step 5: Commit**

```bash
git add src/pool.zig
git commit -m "$(cat <<'EOF'
perf(g3): split counters.submitted onto its own cacheline

Phase G3 sub-change 1/3. Decouples the submitter's `submitted.fetchAdd`
cacheline from the `queued_tasks` cacheline so worker reads of
queued_tasks (in nextTask) do not contend with submitter writes.

Part of docs/superpowers/plans/2026-04-13-phase-g3-submitted-replacement.md
EOF
)"
```

---

## Task 2: Introduce `Core.wake_hint` and replace `:607` load

**Files:**
- Modify: `src/pool.zig` — `Core` struct (add field); `enqueueTask` body (replace load at ~line 607).

**Context:** Current wake-scan at `:607` loads `counters.submitted` to derive `hint_idx = submitted % workers.len`. This is a cross-cacheline read every spawn (even after Task 1's split, it's still a non-local load). Replace with a plain non-atomic `u32` counter on Core. Multiple submitters may race on the increment; racing produces a lost or duplicated hint, which is fine — the hint only determines wake-scan start index, and any starting index preserves correctness (the scan is still a full loop over all workers).

- [ ] **Step 1: Read the current Core struct declaration**

```bash
sed -n '245,260p' src/pool.zig
```
Expected: Core struct with `allocator`, `config`, `accounting`, `state`, `workers`, `local_queues`, `descriptors`, `free_indices`, `free_top_tagged`, `inject_queue`, `sync`, `counters`, `worker_stats_buffer`.

- [ ] **Step 2: Add `wake_hint` field to Core**

Edit `src/pool.zig`. In the Core struct declaration, after `worker_stats_buffer: []types.WorkerStats,`, append:

```zig
    /// Non-atomic u32 rotation counter for wake-scan start index. Written
    /// once per spawn(). Races between submitters are tolerated — any start
    /// index preserves correctness (scan is still full-loop). See Task 2 of
    /// docs/superpowers/plans/2026-04-13-phase-g3-submitted-replacement.md.
    wake_hint: u32 = 0,
```

(Place immediately before the closing `};` of Core; field ordering inside Core doesn't affect hot-path layout since Core is initialized once and all fields are either cold or explicitly-padded atomics.)

- [ ] **Step 3: Read the current wake-scan block**

```bash
sed -n '594,625p' src/pool.zig
```
Expected: the spawn tail block starting with `_ = self.counters.submitted.fetchAdd(1, .monotonic);` and including the 56-iteration wake scan.

- [ ] **Step 4: Replace the wake-hint load**

Edit `src/pool.zig`. Replace (currently at `:607-:608`):

```zig
        const submitted = self.counters.submitted.load(.monotonic);
        const hint_idx: usize = @intCast(submitted % self.workers.len);
```

with:

```zig
        // G3: plain non-atomic rotation counter. Race between submitters is
        // tolerated; the hint only picks a scan start index. A lost increment
        // means two consecutive submits start at the same worker — the scan
        // still covers all workers, so no lost wakeup.
        self.wake_hint +%= 1;
        const hint_idx: usize = @as(usize, self.wake_hint) % self.workers.len;
```

Note: `self` in `enqueueTask` is `*Core` (confirm the param signature at `:554`: `fn enqueueTask(self: *Core, ...)`). If that's not the case (e.g., const self), note that in a comment and fall back to `@as(*Core, @constCast(self))` — but the current signature is `*Core`, so direct `self.wake_hint +%= 1` should work.

- [ ] **Step 5: Verify build + unit tests**

```bash
rm -rf zig-out/ .zig-cache/
zig build -Doptimize=ReleaseFast 2>&1 | tail -20
zig build test 2>&1 | tail -20
```
Expected: clean build; all unit tests pass.

- [ ] **Step 6: Commit**

```bash
git add src/pool.zig
git commit -m "$(cat <<'EOF'
perf(g3): replace spawn wake-hint load with non-atomic rotation counter

Phase G3 sub-change 2/3. Removes a cross-cacheline load of
`counters.submitted` on every spawn() (at pool.zig:607). Replaces with
`Core.wake_hint`, a plain non-atomic u32 incremented inline. Races
between submitters are tolerated: the hint only sets the wake-scan start
index and any start preserves correctness.

Part of docs/superpowers/plans/2026-04-13-phase-g3-submitted-replacement.md
EOF
)"
```

---

## Task 3: Introduce `Worker.steal_hint` and replace `:700` load

**Files:**
- Modify: `src/pool.zig` — `Worker` struct (add field); `nextTask` body (replace load at ~line 700).

**Context:** `nextTask` is called by workers in their steal loop. The current `:700` line reads `counters.submitted` — a cross-thread read of a submitter-hot atomic. Each worker only needs a monotonic rotation for its own steal-start index; a per-worker non-atomic counter is ideal (only the worker itself reads/writes).

- [ ] **Step 1: Read the current Worker struct**

```bash
sed -n '167,198p' src/pool.zig
```
Expected: Worker struct with `thread`, `scratch`, histograms, atomics, `park_mutex`, `park_cond`, `is_parked`, `lifo_slot`.

- [ ] **Step 2: Add `steal_hint` field to Worker**

Edit `src/pool.zig`. In the Worker struct, after the `lifo_slot:` line and before the closing `};`, append:

```zig
    /// Non-atomic u64 rotation counter for this worker's steal-start index.
    /// Only the owner worker reads and writes it (called from nextTask).
    /// Replaces a prior cross-thread load of `counters.submitted`. See
    /// Task 3 of docs/superpowers/plans/2026-04-13-phase-g3-submitted-replacement.md.
    steal_hint: u64 = 0,
```

- [ ] **Step 3: Read the current steal-start line**

```bash
sed -n '695,712p' src/pool.zig
```
Expected: the `nextTask` steal-scan prelude including the `const start = (worker_index +% @as(usize, @truncate(self.counters.submitted.load(.monotonic)))) % self.workers.len;` line.

- [ ] **Step 4: Replace the steal-start mixing load**

First, confirm that `nextTask` has access to the current worker (by index or by pointer). Read around the steal loop context:

```bash
sed -n '640,710p' src/pool.zig
```
Expected to identify: `worker_index` is in scope (passed in or derived). The owner `Worker` is reachable via `&self.workers[worker_index]`.

Edit `src/pool.zig`. Replace (currently at `:697-:700`, the comment and `const start`):

```zig
            // Use worker_index mixed with submitted count for pseudo-random start.
            // Avoids global atomic fetchAdd contention that causes thundering-herd
            // when all idle workers get sequential starting indices.
            const start = (worker_index +% @as(usize, @truncate(self.counters.submitted.load(.monotonic)))) % self.workers.len;
```

with:

```zig
            // G3: per-worker non-atomic rotation. Only this worker writes
            // steal_hint; no cross-thread atomic load. Preserves the original
            // intent (avoid thundering-herd sequential starts) without touching
            // the submitter-hot `counters.submitted` cacheline.
            const owner = &self.workers[worker_index];
            owner.steal_hint +%= 1;
            const start = (worker_index +% @as(usize, @truncate(owner.steal_hint))) % self.workers.len;
```

- [ ] **Step 5: Verify build + unit tests**

```bash
rm -rf zig-out/ .zig-cache/
zig build -Doptimize=ReleaseFast 2>&1 | tail -20
zig build test 2>&1 | tail -20
```
Expected: clean build; all unit tests pass.

- [ ] **Step 6: Commit**

```bash
git add src/pool.zig
git commit -m "$(cat <<'EOF'
perf(g3): replace nextTask steal-start mixing with per-worker hint

Phase G3 sub-change 3/3. Removes the cross-thread load of
`counters.submitted` at pool.zig:700. Replaces with `Worker.steal_hint`,
a per-worker non-atomic u64 counter. Only the owner worker reads and
writes it, so no atomic required. Preserves the pseudo-random-start
intent (avoid worker-0 thundering-herd) without touching the submitter
cacheline.

Part of docs/superpowers/plans/2026-04-13-phase-g3-submitted-replacement.md
EOF
)"
```

---

## Task 4: Regression test — `Stats.submitted` still reports accurate counts

**Files:**
- Modify: `tests/unit.zig` — add one new test function.

**Context:** `counters.submitted.fetchAdd` is still in place at `:597`; `Stats.submitted` at `:501` still reads it. No existing test asserts the value, but that means a later refactor could silently break observability. This task adds an explicit guard.

- [ ] **Step 1: Write the failing test**

Append to `tests/unit.zig` (at the end of the file, before any `}` closing test block):

```zig
test "g3: Stats.submitted reports exact spawn count" {
    var pool = try thread_pool.ThreadPool.init(std.testing.allocator, .{});
    defer pool.deinit();

    const N: usize = 1000;
    var counter = std.atomic.Value(u64).init(0);
    var wg = thread_pool.WaitGroup.init();

    var i: usize = 0;
    while (i < N) : (i += 1) {
        _ = try pool.spawn(common_test.counterTask, @ptrCast(&counter), .{ .wait_group = &wg });
    }
    wg.wait();

    const stats = pool.snapshot();
    try std.testing.expectEqual(@as(u64, N), stats.submitted);
    try std.testing.expectEqual(@as(u64, N), counter.load(.acquire));
}
```

If `thread_pool` and `common_test` aren't the exact module names in unit.zig, check existing imports at the top of unit.zig (`head -30 tests/unit.zig`) and match the naming used in a nearby successful test (e.g., the "hot_spinners = 1 executes all submitted tasks" test at `:831` is a good template).

- [ ] **Step 2: Verify the test would have failed before Task 1-3**

Skip — we're now 3 commits past the baseline. Instead, verify the test passes at the current tip:

```bash
zig build test 2>&1 | tail -20
```
Expected: all tests pass, including the new `g3: Stats.submitted reports exact spawn count` test.

If it fails with a compile error (e.g., `common_test` not imported), inspect the existing imports and adjust the test accordingly.

- [ ] **Step 3: Commit**

```bash
git add tests/unit.zig
git commit -m "$(cat <<'EOF'
test(g3): guard Stats.submitted observability with explicit assertion

Adds a unit test that spawns N=1000 tasks and asserts
`pool.snapshot().submitted == N`. Pins the observability contract so a
future refactor of the hot-path submit counter cannot silently regress
this field.

Part of docs/superpowers/plans/2026-04-13-phase-g3-submitted-replacement.md
EOF
)"
```

---

## Task 5: 20× ReleaseFast stress gate

**Files:**
- Create: `docs/performance/phase-g3-close/stress-20x.txt`

- [ ] **Step 1: Capture host load at start**

```bash
mkdir -p docs/performance/phase-g3-close
{ echo "# load before stress:"; uptime; } | tee docs/performance/phase-g3-close/stress-20x.txt
```

If the 1-minute load average is > 8, STOP and report to user that the host is under load — measurements will be contaminated. Wait for load < 4 before proceeding.

- [ ] **Step 2: Run the 20× stress loop inline (pass 60-min timeout)**

```bash
{
  pass=0; fail=0
  for i in $(seq 1 20); do
    START=$(date +%s)
    if timeout 300 zig build test-stress -Doptimize=ReleaseFast > /tmp/g3-stress-$i.log 2>&1; then
      pass=$((pass+1))
      echo "run $i: PASS ($(($(date +%s) - $START))s)"
    else
      fail=$((fail+1))
      echo "run $i: FAIL ($(($(date +%s) - $START))s)"
      tail -3 /tmp/g3-stress-$i.log || true
    fi
  done
  echo "=== SUMMARY: pass=$pass fail=$fail ==="
  echo "# load after stress:"
  uptime
} | tee -a docs/performance/phase-g3-close/stress-20x.txt
```

Pass `timeout: 3600000` (60 min) to the Bash tool invocation. Each stress iteration should be ~30-120s.

Expected: `pass=20 fail=0`. If any failures occur, the fix introduced a race — do NOT proceed to Task 6 until fixed. Root-cause the failure (check `/tmp/g3-stress-*.log`), file as a blocker, revert Tasks 2/3 separately to bisect which change caused it.

- [ ] **Step 3: Commit the stress log**

```bash
git add docs/performance/phase-g3-close/stress-20x.txt
git commit -m "$(cat <<'EOF'
test(g3): 20× ReleaseFast stress gate — validate changes don't regress correctness
EOF
)"
```

---

## Task 6: Benchmark + close-out report

**Files:**
- Create: `docs/performance/phase-g3-close/baseline-compare.txt`
- Create: `docs/performance/phase-g3-close/SUMMARY.md`
- Modify: `docs/PERFORMANCE_TRACKING.md` — append `§ Phase G3` section.

- [ ] **Step 1: n=10 flood_1m measurement at G3 tip**

```bash
{
  echo "# Phase G3 measurement at $(git rev-parse --short HEAD) ($(date -Iseconds))"
  echo "# branch: $(git branch --show-current)"
  echo "# load at start:"
  uptime
  echo "# baseline (pre-G3): 566K ops/s n=10 (re-profile Task 1, commit 3506b29)"
  echo "# A/B ceiling: 803K ops/s n=10 (re-profile Task 3, commit e07b9f7)"
  for i in $(seq 1 10); do
    echo "--- run $i ---"
    timeout 60 ./zig-out/bin/thread-pool-tokio-parity flood_1m
  done
  echo "# load at end:"
  uptime
} | tee docs/performance/phase-g3-close/baseline-compare.txt

grep 'scenario=flood_1m' docs/performance/phase-g3-close/baseline-compare.txt \
  | grep -Eo 'ops_per_sec=[0-9]+' | grep -Eo '[0-9]+' | sort -n | awk '
      {a[NR]=$1}
      END {
        if (NR==0) { print "no valid runs"; exit }
        if (NR%2) print "median:", a[(NR+1)/2];
        else print "median:", (a[NR/2]+a[NR/2+1])/2;
        print "min:", a[1]; print "max:", a[NR]; print "n:", NR
      }' | tee -a docs/performance/phase-g3-close/baseline-compare.txt
```

Force-rebuild before measuring if you haven't since the last src/pool.zig edit:

```bash
rm -rf zig-out/ .zig-cache/
zig build -Doptimize=ReleaseFast
```

- [ ] **Step 2: Compute capture % and decide on approach (B) follow-up**

Let `G3 = median` from Step 1 output. Let `baseline = 566000`, `ab_ceiling = 803000`.

- Relative lift: `(G3 - baseline) / baseline * 100`
- Capture fraction: `(G3 - baseline) / (ab_ceiling - baseline) * 100`

Thresholds:
- **Capture ≥ 60% (G3 ≥ 708K)**: land G3 as-is; approach (B) optional for later.
- **Capture 30–60% (638K ≤ G3 < 708K)**: land G3; note in close-out that approach (B) could recover the remaining headroom.
- **Capture < 30% (G3 < 638K)**: don't land yet. Investigate: re-run perf sched, compare to Task 2 baseline perf-sched-report. The intended hot-path reads may not have been the actual cost source. Fall back to approach (B) design (shard the write).

- [ ] **Step 3: Write `docs/performance/phase-g3-close/SUMMARY.md`**

Create the file with the following structure. Fill every `<>` with real numbers from Steps 1-2.

```markdown
# Phase G3 Close-Out — `counters.submitted` Hot-Path Replacement

## Result

- **Baseline:** 566K ops/s (pre-G3, re-profile Task 1).
- **A/B ceiling:** 803K ops/s (+42%, re-profile Task 3).
- **G3 result:** <G3>K ops/s median, n=10 (min=<>, max=<>).
- **Lift:** +<X>% relative; +<Y>K ops/s absolute.
- **Capture fraction:** <Z>% of A/B ceiling.
- **Stress:** 20/20 PASS, logged at `docs/performance/phase-g3-close/stress-20x.txt`.
- **Unit:** all PASS including new `g3: Stats.submitted reports exact spawn count` test.

## Sub-changes

1. **Cacheline split (commit `<sha>`):** `counters.submitted` moved off the `queued_tasks` cacheline onto its own.
2. **Wake-hint replacement (commit `<sha>`):** `:607` load replaced with `Core.wake_hint` non-atomic u32.
3. **Steal-start replacement (commit `<sha>`):** `:700` cross-thread load replaced with `Worker.steal_hint` per-worker u64.

## Observability preserved

`Stats.submitted` is still populated by `counters.submitted.fetchAdd` at `:597` and read at `:501`. Unit test at `tests/unit.zig` asserts exact count preservation.

## Host-load context

- Load at measurement start: `<1m/5m/15m>`
- Load at measurement end: `<1m/5m/15m>`
- <Clean | Elevated (note)>

## Recommendation for approach (B)

<Based on capture fraction from Step 2:>

- **If capture ≥ 60%:** land G3; defer approach (B) (shard the submit counter into per-worker + external slots) until a future phase or if `contended_spawn_8x` regression demands it.
- **If capture 30–60%:** land G3 and open a follow-up ticket to implement approach (B). Expected additional lift: the residual headroom between G3 and A/B ceiling.
- **If capture < 30%:** do not land; revert and redesign. The A/B lift source was not where this plan assumed.

This plan's output: <one of the three>.

## Sub-benchmarks to verify no regression on secondary workloads

Also run and record to `docs/performance/phase-g3-close/secondary-benchmarks.txt`:

- `contended_spawn_8x` n=5 — multi-submitter scenario; verify no regression from `wake_hint` races.
- `bench-micro-submit` — submit latency micro.
- `bench-micro-wake` — wake latency micro.

If any secondary benchmark regresses >5% median vs main tip `9da9462`, document in SUMMARY.md and consider rollback or redesign.
```

- [ ] **Step 4: Append to `docs/PERFORMANCE_TRACKING.md`**

Append at the end:

```markdown

## Phase G3 — counters.submitted hot-path replacement (2026-04-13+)

Sub-changes:
1. Cacheline split — `submitted` moved off `queued_tasks` cacheline.
2. `Core.wake_hint` replaces `:607` load of `submitted`.
3. `Worker.steal_hint` replaces `:700` cross-thread load of `submitted`.

Result: flood_1m <G3>K ops/s (baseline 566K, +<X>%), <Z>% of A/B ceiling (803K). Stress 20/20. Observability preserved.

Full report: `docs/performance/phase-g3-close/SUMMARY.md`.
```

Fill `<G3>`, `<X>`, `<Z>` with actual numbers.

- [ ] **Step 5: Commit**

```bash
git add docs/performance/phase-g3-close/ docs/PERFORMANCE_TRACKING.md
git commit -m "$(cat <<'EOF'
docs(g3): close-out — flood_1m +<X>% (<Z>% of A/B ceiling), 20/20 stress

See docs/performance/phase-g3-close/SUMMARY.md for the full report
including lift, capture fraction, stress result, observability check,
and recommendation on approach (B) follow-up.
EOF
)"
```

Fill `<X>` and `<Z>` with the actual percentages.

---

## Task 7: 100× pre-merge stress gate

**Files:**
- Create: `docs/performance/phase-g3-close/stress-100x.txt`

Before merging to main, run the extended stress gate per methodology rule #9.

- [ ] **Step 1: Capture host load; abort if > 8**

```bash
uptime
```

If 1-min avg > 8, wait until it drops before proceeding.

- [ ] **Step 2: 100× stress loop**

```bash
{
  echo "# 100× pre-merge stress gate, branch $(git branch --show-current) at $(git rev-parse --short HEAD)"
  echo "# load at start:"
  uptime
  pass=0; fail=0; first_fail=""
  for i in $(seq 1 100); do
    START=$(date +%s)
    if timeout 300 zig build test-stress -Doptimize=ReleaseFast > /tmp/g3-100-stress-$i.log 2>&1; then
      pass=$((pass+1))
      [ $((i % 10)) -eq 0 ] && echo "run $i: PASS ($(($(date +%s) - $START))s); cumulative pass=$pass fail=$fail"
    else
      fail=$((fail+1))
      if [ -z "$first_fail" ]; then
        first_fail=$i
        echo "run $i: FIRST FAIL ($(($(date +%s) - $START))s)"
        tail -5 /tmp/g3-100-stress-$i.log
      else
        echo "run $i: FAIL ($(($(date +%s) - $START))s)"
      fi
    fi
  done
  echo "=== SUMMARY: pass=$pass fail=$fail (first_fail=$first_fail) ==="
  echo "# load at end:"
  uptime
} | tee docs/performance/phase-g3-close/stress-100x.txt
```

Pass `timeout: 3600000` (60 min). Total wall-clock ~30-120 minutes depending on per-iter cost.

Expected: `pass=100 fail=0`. A single failure among 100 under ReleaseFast indicates a 1% race rate — block merge, root-cause.

- [ ] **Step 3: Commit**

```bash
git add docs/performance/phase-g3-close/stress-100x.txt
git commit -m "$(cat <<'EOF'
test(g3): 100× ReleaseFast stress gate pre-merge validation
EOF
)"
```

If any failures, DO NOT proceed to Task 8.

---

## Task 8: Merge to main

- [ ] **Step 1: Confirm worktree tip is clean and correct**

```bash
git status
git log --oneline main..HEAD
```
Expected: clean working tree; 6–8 commits on the branch covering the three sub-changes, test addition, stress logs, close-out.

- [ ] **Step 2: Offer user merge options**

Stop and ask the user:

> G3 implementation complete on `feat/g3-submitted-replacement`. Results in `docs/performance/phase-g3-close/SUMMARY.md`. Merge options:
> 1. Fast-forward (linear history).
> 2. Merge commit (preserve branch structure).
>
> Which?

Do NOT auto-merge. The user decides (consistent with how phase G2 Re-Land was merged).

- [ ] **Step 3: On user approval, merge from the main worktree**

```bash
cd /home/benji/src/devnw/zig/thread-pool  # primary worktree, on main
git fetch .
# For fast-forward:
git merge --ff-only feat/g3-submitted-replacement
# OR for merge commit:
# git merge --no-ff feat/g3-submitted-replacement -m "perf: merge Phase G3 (counters.submitted hot-path replacement)"
git log --oneline -5
```

- [ ] **Step 4: Clean up worktree**

```bash
git worktree remove /home/benji/src/devnw/zig/thread-pool-phase-g3
git branch -d feat/g3-submitted-replacement  # safe delete (merged)
git worktree list
```

Expected: only the primary worktree remains; branch deletion succeeds cleanly.

- [ ] **Step 5: Update memory**

Edit `~/.claude/projects/-home-benji-src-devnw-zig-thread-pool/memory/project_phase_status.md`:
- Add Phase G3 to the "Shipped" section with the measured lift and merge SHA.
- Remove Phase G3 from "Next-action priority" or mark done.
- Update the "Last reprofile" line's relevance: measurements are now stale at the post-G3 tip; note this if it matters.

No repo commit — memory file is outside the repo.

---

## Done criteria

- [ ] `feat/g3-submitted-replacement` merged to main.
- [ ] `docs/performance/phase-g3-close/SUMMARY.md` reports capture fraction with real numbers.
- [ ] `docs/PERFORMANCE_TRACKING.md` has a `§ Phase G3` section.
- [ ] `memory/project_phase_status.md` reflects G3 as shipped.
- [ ] Stress 20× PASS on the final tip; stress 100× PASS pre-merge.
- [ ] Unit test `g3: Stats.submitted reports exact spawn count` PASSES.
- [ ] `counters.submitted.fetchAdd` still present in `src/pool.zig` (observability preserved).
- [ ] No hot-path load of `counters.submitted` anywhere in `src/pool.zig` (verify with `grep 'counters\.submitted'` showing only `:597` write and `:501` snapshot read).

## Non-goals (explicitly out of scope)

- Approach (B) — per-worker + external sharded submit counter. Deferred to a separate plan iff Task 6 shows capture < 60%.
- Wake-scan redesign (next phase recommended by re-profile plan). Separate plan.
- Descriptor CAS changes (re-profile showed DEPRIORITIZE). Not touched.
- Architectural changes (Chase-Lev deque, event-wake, lock-free inject queue). Separate plans exist at `docs/superpowers/plans/2026-04-11-*.md`.

## Rollback plan

If Task 5 (20× stress) or Task 7 (100× stress) fails:
1. Bisect the three sub-changes (Tasks 1, 2, 3) individually by checking out each commit and running 20× stress on each.
2. The cacheline split (Task 1) is correctness-safe — unlikely to be the culprit; if it is, something in `std.atomic.cache_line` is wrong on this host.
3. `wake_hint` (Task 2) could in principle introduce a starvation pattern (always waking the same worker if `wake_hint` races produce no effective mixing). Unlikely given wake-scan still covers all workers, but possible.
4. `steal_hint` (Task 3) is the most likely culprit if there's a regression — per-worker u64 should be safe but check for accidental UB if the worker field layout changed size/alignment.

If the fault bisects to Task 2 or 3, revert only that sub-change; the cacheline split (Task 1) can stay.
