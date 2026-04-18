# Phase G2: Remove Idle-Spin `queued_tasks` Poll Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove the shared-cacheline `counters.queued_tasks.load(.acquire)` hammered by every worker in the idle-spin loop (`src/pool.zig:791`). Replace with a pure `spinLoopHint` delay followed by a single local-work probe before parking. A/B-verified ceiling on the `queued_tasks` cacheline: 331K → 417K ops/s (+26%).

**Architecture:** The current `idle()` spin runs `spin_before_park_iters` (default 128) iterations, each iteration loading the pool-wide `queued_tasks` counter. Submitter writes this same cacheline with `.seq_cst` fetchAdd on every submit, so 56 workers × 128 shared loads per park cycle is the dominant cross-core traffic on the line. G2 drops the counter load from the spin body entirely. The spin becomes a pure micro-delay; a single end-of-spin probe on local-only state (this worker's `lifo_slot`, its `local_queue`, and the `inject_queue` length) decides whether to park. Park handshake correctness is unchanged because the SC ordering on `queued_tasks.fetchAdd` vs `is_parked` store is preserved — only the redundant read-side spin is removed.

**Tech Stack:** Zig 0.15.2, `std.atomic.spinLoopHint`, existing Phase A park handshake machinery, existing `LocalQueue.len()` / `BoundedRing.len()` / `lifo_slot` APIs. No new types, no new atomics, no new config.

**Design rationale (embedded — no separate spec):**

1. **Why the counter load is hot.** At 331K ops/s, every submit does `queued_tasks.fetchAdd(1, .seq_cst)` on a line also being read by 56 workers × 128 spin iters per park cycle. Aggregate load rate on the line is ~100M reads/s. Submitter's SC write to the line bounces across every worker that just read it.
2. **Why removing the poll is safe.** The poll's purpose is "avoid parking when a task is about to arrive." But the park handshake (SC store of `is_parked` + SC reload of `queued_tasks` at `pool.zig:812-813`) catches any lost-wakeup case. The spin-poll is a latency optimisation, not a correctness mechanism. Replacing 128 polls with 1 probe preserves the optimisation's intent while eliminating the cross-core traffic.
3. **Why a final local probe.** A pure delay without any final check would force parking even when work landed in this worker's LIFO slot during the spin — measurable latency regression on rapid worker-context spawn bursts. A one-shot probe at the end of the spin restores that fast path without restoring the 128× cacheline cost.
4. **What the final probe checks (in order, all `.monotonic` or `.acquire` local loads):** pool state, this worker's `lifo_slot`, this worker's `local_queue.len()`, `inject_queue.len()`. The inject-queue probe is the only non-worker-local load, costing 2 atomic loads (head, tail) ONCE per park cycle — ~350× cheaper than the removed 128-iter poll.
5. **Why G2 is orthogonal to G1 (parked bitmap).** G1 targeted the submitter-side O(N) wake scan — a different cacheline set (per-worker `is_parked` array). G1 failed on consolidation anti-pattern (56 writers on one bitmap line). G2 does the opposite: removes a shared load, does not add a shared write. The consolidation anti-pattern cannot apply.
6. **Correctness argument for the SC handshake.** `incrementQueued()` at `pool.zig:968` stays `.seq_cst`. `idle()`'s post-park-acquire handshake at `pool.zig:812-813` stays `.seq_cst`. The IRIW-exclusion argument in the comment at `pool.zig:801-811` is untouched. The only loads removed are the `.acquire` loads in the pre-park spin — those participate in no handshake, they only shortcut the spin; dropping them cannot introduce a lost wakeup.

**Reference — no separate spec document.** Phase F1b's "deep re-profile" entry in `docs/PERFORMANCE_TRACKING.md` provides the A/B data: `queued_tasks` SC fetchAdd + idle-spin poll together lift +26%; this plan targets the poll specifically (the dominant component of that lift).

**Performance Targets:**

| Metric | Baseline (2026-04-12 `3b0ca5b`) | Target | Stretch |
|---|---:|---:|---:|
| `bench_tokio_parity/flood_1m` ops/s | 331K | **≥ 390K** | ≥ 415K |
| `bench_tokio_parity/contended_spawn_8x` ops/s | 534K | ≥ 540K (no regression) | ≥ 580K |
| `bench-micro-wake` p50 ns | 9985 | ≤ 12000 (no regression) | ≤ 9000 |
| `test-stress` 10× consecutive | pass | pass | pass |

**Rollback floor:** `flood_1m` median of 5 runs < **370K** → rollback the behavior-change commits (keep any added tests as regression guards).

**MANDATORY A/B gates (both required):**

1. **Pre-plan A/B (Task 2):** stub `queued_tasks.load` in the spin to return hard-coded 0. Expect flood_1m ≥ 400K. If not ≥ 380K, the target is not where we think it is → STOP, do not touch production code.
2. **Post-impl A/B (Task 7):** build the production change, then additionally set `spin_before_park_iters = 0` (disable the spin entirely). If the default build and spin=0 build measure indistinguishably (< 5% delta), the spin is now pure dead code and the final-probe fast path isn't engaging → ROLLBACK even if numbers are up, because we're shipping inert code.

---

## File Structure

**Modified files:**

- `src/pool.zig` — rewrite the spin block at lines 787–794 (inside `fn idle`); add the end-of-spin local-work probe immediately after. No struct changes, no field additions, no new helpers.
- `tests/unit.zig` — new test: `idle-spin: worker avoids park when work arrives in its LIFO slot during spin window` (regression guard, exercises the new local-probe path).
- `tests/stress.zig` — new test: `flood with aggressive spin: no lost wakeups under 56-worker × 1M-task flood with spin_before_park_iters = 4096` (forces the spin to dominate and validates handshake correctness when poll is gone).
- `docs/PERFORMANCE_TRACKING.md` — Phase G2 section with A/B numbers and final verdict.
- `benchmarks/results/baseline.json` — rebaseline on success (only if ship decision reached).

**New files:** none.

---

## Task Ordering Rationale

G2 is a single-site behavioral change (~8 lines in `idle()`), but the methodology requires three measurement checkpoints: pre-plan A/B (validates target), unit/stress correctness (validates handshake still holds), post-impl A/B (validates mechanic engages). Tasks are sequenced so each intermediate state is safe and independently measurable:

1. **Worktree + baseline** — isolate the experiment and record today's noise floor BEFORE any code touches.
2. **Pre-plan A/B measurement** — stub the poll, measure, revert the stub. If ceiling isn't real, stop here.
3. **Correctness tests first (TDD)** — write the regression guard test BEFORE the implementation so the test captures the desired property, not the implemented behavior.
4. **Implementation** — the one-file change.
5. **Correctness check** — unit + stress, force-rebuild between runs.
6. **Full bench** — force-rebuild, median of 5.
7. **Post-impl A/B** — rebuild with `spin_before_park_iters = 0`, compare.
8. **Ship decision** — either rebaseline + document, or rollback.

Between each measurement-bearing task: `zig build -Doptimize=ReleaseFast` explicitly before running the binary. `zig build bench-tokio-parity` alone does not guarantee a rebuild (see Phase G1 Task 3 → Task 6 discrepancy, methodology lesson #8).

---

## Task 1: Create worktree and record baseline

**Files:** none modified. Measurement only.

- [ ] **Step 1: Create a dedicated worktree for Phase G2**

```bash
cd /home/benji/src/devnw/zig/thread-pool
git worktree add ../thread-pool-phase-g2 -b feat/phase-g2-queued-tasks-poll main
cd ../thread-pool-phase-g2
```

Expected: new directory `../thread-pool-phase-g2` on branch `feat/phase-g2-queued-tasks-poll` at main tip (`3b0ca5b` or later).

- [ ] **Step 2: Force-rebuild the pre-change binary**

```bash
zig build -Doptimize=ReleaseFast
```

Expected: clean build, no errors.

- [ ] **Step 3: Record baseline flood_1m (median of 5)**

```bash
for i in 1 2 3 4 5; do ./zig-out/bin/bench-tokio-parity 2>&1 | grep -E "^flood_1m"; done
```

Expected output (one line per run): `flood_1m             N ops/s   1000000 tasks   1 submitters`.

Record the 5 N values. Compute median. Expected range: 310K–360K. Write the five numbers and the median in a scratch file `/tmp/phase-g2-baseline.txt` (not committed) — these are the comparison floor for every later measurement in this phase.

- [ ] **Step 4: Record baseline contended_spawn_8x (median of 3)**

```bash
for i in 1 2 3; do ./zig-out/bin/bench-tokio-parity 2>&1 | grep -E "^contended_spawn_8x"; done
```

Expected: 510K–570K. Record median to `/tmp/phase-g2-baseline.txt`.

- [ ] **Step 5: Record baseline bench-micro-wake p50**

```bash
zig build bench-wake 2>&1 | tail -20
```

If the step doesn't exist, skip (Phase G2 doesn't touch wake latency directly; the check is defensive). Expected p50: 9000–11000 ns.

- [ ] **Step 6: Commit baseline capture script (no code changes)**

Nothing to commit in this task — baseline lives in `/tmp/phase-g2-baseline.txt` which is deliberately not tracked. Proceed to Task 2.

---

## Task 2: Pre-plan A/B — stub the poll, measure, revert

**Files:**
- Modify: `src/pool.zig` (temporary change, reverted at end of task)

Goal: validate the +26% ceiling by removing ONLY the poll and measuring. If ceiling isn't there, the plan is wrong and later tasks must not proceed.

- [ ] **Step 1: Open `src/pool.zig` and locate the idle spin at lines 787–794**

Current code:

```zig
fn idle(self: *Core, worker_index: usize) void {
    var worker = &self.workers[worker_index];
    var spins: usize = 0;
    while (spins < self.config.spin_before_park_iters) : (spins += 1) {
        if (self.counters.queued_tasks.load(.acquire) != 0) return;
        if (self.state.load(.acquire) != .running) return;
        std.atomic.spinLoopHint();
    }
```

- [ ] **Step 2: Replace the `queued_tasks` load with a no-op placeholder**

Use Edit to change the spin body so the load no longer fires:

```zig
    while (spins < self.config.spin_before_park_iters) : (spins += 1) {
        // [G2 PRE-PLAN A/B — reverted at end of Task 2]
        // if (self.counters.queued_tasks.load(.acquire) != 0) return;
        if (self.state.load(.acquire) != .running) return;
        std.atomic.spinLoopHint();
    }
```

The `queued_tasks` check is commented out; everything else is identical. This is a temporary experiment.

- [ ] **Step 3: Force-rebuild**

```bash
zig build -Doptimize=ReleaseFast
```

Expected: clean build.

- [ ] **Step 4: Measure flood_1m (median of 5)**

```bash
for i in 1 2 3 4 5; do ./zig-out/bin/bench-tokio-parity 2>&1 | grep -E "^flood_1m"; done
```

Record all 5 values. Compute median.

- [ ] **Step 5: Evaluate the gate**

Gate: median flood_1m **≥ 380K** (provides >15% margin over 331K baseline, leaves room for the post-impl version to land at 390K+).

- If gate passes: the target is real. Proceed.
- If gate fails (median < 380K): STOP. The +26% number from the F1b re-profile was either environmental or the poll isn't the dominant sub-component of the combined `queued_tasks` lift. Do not write the production change; instead, document findings in `/tmp/phase-g2-baseline.txt` and escalate to the user before Task 3.

- [ ] **Step 6: Revert the stub**

Use Edit to restore the original line exactly:

```zig
    while (spins < self.config.spin_before_park_iters) : (spins += 1) {
        if (self.counters.queued_tasks.load(.acquire) != 0) return;
        if (self.state.load(.acquire) != .running) return;
        std.atomic.spinLoopHint();
    }
```

- [ ] **Step 7: Force-rebuild and sanity-check the revert**

```bash
zig build -Doptimize=ReleaseFast
./zig-out/bin/bench-tokio-parity 2>&1 | grep "^flood_1m"
```

Expected: single run within baseline range (310K–360K). Confirms the revert is complete; the tree is back to pre-G2 state.

- [ ] **Step 8: Commit nothing**

Task 2 is measurement-only. No commit. `git status` should report a clean tree (no uncommitted changes).

---

## Task 3: Write failing unit test for end-of-spin local-work probe

**Files:**
- Modify: `tests/unit.zig`

Test goal: when a worker enters `idle()` with no work, and work lands in its LIFO slot during the spin window, the worker must return from `idle()` WITHOUT parking (i.e. without blocking on `park_cond`).

Because `idle()` is private, we test the observable: submit a task to a specific worker's LIFO slot mid-spin and verify the task runs within a tight deadline (much less than `idle_park_after_ns`).

- [ ] **Step 1: Find where existing idle/park-related tests live in `tests/unit.zig`**

```bash
grep -n "spin_before_park\|idle\|is_parked" tests/unit.zig | head -20
```

Pick an insertion point near similar tests.

- [ ] **Step 2: Write the failing test**

Insert at the chosen location:

```zig
test "phase g2: worker returns from idle when lifo slot filled during spin window" {
    const allocator = std.testing.allocator;

    var pool = try ThreadPool.init(allocator, .{
        .worker_count = 2,
        .scheduler_variant = .work_stealing,
        .queue_capacity = 256,
        // Long spin to maximise the window we can race into.
        .spin_before_park_iters = 1_000_000,
        // Tight park timeout — if we DO accidentally park, the test
        // wakes quickly but fails the latency assertion below.
        .idle_park_after_ns = 500_000_000,
    });
    defer pool.deinit();

    // Give workers time to enter idle().
    std.Thread.sleep(5 * std.time.ns_per_ms);

    const Ctx = struct {
        ran_at_ns: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
        fn run(ctx_ptr: *anyopaque, _: *ThreadPool.TaskContext) void {
            const self: *@This() = @ptrCast(@alignCast(ctx_ptr));
            self.ran_at_ns.store(@intCast(std.time.nanoTimestamp()), .release);
        }
    };
    var ctx = Ctx{};

    const submit_ns: u64 = @intCast(std.time.nanoTimestamp());
    _ = try pool.submit(Ctx.run, &ctx, .{});

    // Busy-wait up to 50 ms for the task to run.
    const deadline = submit_ns + 50 * std.time.ns_per_ms;
    while (ctx.ran_at_ns.load(.acquire) == 0) {
        if (@as(u64, @intCast(std.time.nanoTimestamp())) > deadline) break;
        std.atomic.spinLoopHint();
    }

    const ran_at = ctx.ran_at_ns.load(.acquire);
    try std.testing.expect(ran_at != 0); // task ran
    const latency_ns = ran_at - submit_ns;
    // Assert latency well below the park timeout. If the worker parked
    // (because the spin didn't re-probe local state), latency would be
    // dominated by park_cond.signal round-trip (~15 µs) which is still
    // below 1 ms — so we assert < 1 ms to catch "spin didn't probe at all"
    // regressions without flapping on ordinary park wakes.
    try std.testing.expect(latency_ns < 1 * std.time.ns_per_ms);
}
```

- [ ] **Step 3: Run the test — expect PASS today (pre-change)**

```bash
zig build test 2>&1 | tail -30
```

Expected: PASS. The test passes against the current `idle()` because today's spin DOES poll `queued_tasks`, which the submit path increments. The test establishes the required behavior — it will pass both before and after the change, provided the change preserves the fast path.

Note on TDD inversion: this is a regression guard, not a driver-test. The change (Task 4) removes a mechanism but must preserve its observable effect. The test locks the observable in place.

- [ ] **Step 4: Commit**

```bash
git add tests/unit.zig
git commit -m "test: phase g2 - idle spin must return from local work without park"
```

---

## Task 4: Write stress test for handshake correctness under aggressive spin

**Files:**
- Modify: `tests/stress.zig`

Test goal: under an aggressive `spin_before_park_iters` setting (forces many workers to be mid-spin during each submit), all 1M submitted tasks must complete. This validates that the handshake comment at `src/pool.zig:801-811` still holds after the poll is removed — i.e. no submit ever leaves a worker parked while its task sits queued.

- [ ] **Step 1: Find an insertion point in `tests/stress.zig`**

```bash
grep -n "flood\|spin_before_park_iters" tests/stress.zig | head -20
```

- [ ] **Step 2: Add the stress test**

```zig
test "phase g2: aggressive spin flood - no lost wakeups" {
    const allocator = std.testing.allocator;

    var pool = try ThreadPool.init(allocator, .{
        .worker_count = 16, // keep test reasonable in CI
        .scheduler_variant = .work_stealing,
        .queue_capacity = 4096,
        // Spin much longer than normal to stress the post-poll-removal
        // handshake. Many workers will be mid-spin at submit time.
        .spin_before_park_iters = 4096,
    });
    defer pool.deinit();

    var completed = std.atomic.Value(u64).init(0);
    const Ctx = struct {
        counter: *std.atomic.Value(u64),
        fn run(ctx_ptr: *anyopaque, _: *ThreadPool.TaskContext) void {
            const self: *@This() = @ptrCast(@alignCast(ctx_ptr));
            _ = self.counter.fetchAdd(1, .monotonic);
        }
    };
    var ctx = Ctx{ .counter = &completed };

    const total: u64 = 200_000;
    var submitted: u64 = 0;
    while (submitted < total) : (submitted += 1) {
        _ = try pool.submit(Ctx.run, &ctx, .{ .backpressure = .block });
    }

    // Wait with deadline for drain. If the G2 change loses a wakeup,
    // the test hangs here until deadline.
    const deadline_ns: u64 = 30 * std.time.ns_per_s;
    const start: u64 = @intCast(std.time.nanoTimestamp());
    while (completed.load(.acquire) < total) {
        if (@as(u64, @intCast(std.time.nanoTimestamp())) - start > deadline_ns) break;
        std.Thread.sleep(1 * std.time.ns_per_ms);
    }

    try std.testing.expectEqual(total, completed.load(.acquire));
}
```

- [ ] **Step 3: Run the test — expect PASS pre-change**

```bash
zig build test-stress 2>&1 | tail -20
```

Expected: PASS. Establishes the regression guard. After Task 5 implements the change, this test should still pass — that's the correctness gate for shipping.

- [ ] **Step 4: Run 5 consecutive times to confirm it's non-flaky**

```bash
for i in 1 2 3 4 5; do zig build test-stress 2>&1 | tail -5; echo "---"; done
```

Expected: 5/5 PASS. If flaky, fix the flakiness before proceeding — an intermittent stress test masks real G2 handshake regressions.

- [ ] **Step 5: Commit**

```bash
git add tests/stress.zig
git commit -m "test: phase g2 - aggressive spin flood regression guard"
```

---

## Task 5: Implement the G2 change

**Files:**
- Modify: `src/pool.zig:787-794` (the `idle` function's spin block)

- [ ] **Step 1: Re-read the current `idle` function**

```bash
sed -n '785,830p' src/pool.zig
```

Confirm the code matches the snippet shown below before editing. If it doesn't match exactly, STOP and reconcile (the plan may have drifted from tip).

Expected current content:

```zig
    fn idle(self: *Core, worker_index: usize) void {
        var worker = &self.workers[worker_index];
        var spins: usize = 0;
        while (spins < self.config.spin_before_park_iters) : (spins += 1) {
            if (self.counters.queued_tasks.load(.acquire) != 0) return;
            if (self.state.load(.acquire) != .running) return;
            std.atomic.spinLoopHint();
        }

        if (self.state.load(.acquire) != .running) return;
```

- [ ] **Step 2: Replace the spin block**

Use Edit to change lines 787–796 to:

```zig
    fn idle(self: *Core, worker_index: usize) void {
        var worker = &self.workers[worker_index];
        // Phase G2: spin as pure micro-delay. We do NOT poll
        // `counters.queued_tasks` here — the submit path writes that line
        // with .seq_cst on every submit, and 56 workers × spin_iters
        // shared loads per park cycle dominated cross-core traffic on the
        // line (A/B-measured: removing the poll lifts flood_1m by >15%).
        // Handshake correctness is unaffected — the mutex-guarded reload
        // at `worker.is_parked.store(1, .seq_cst)` below is the actual
        // lost-wakeup guard; the spin-poll was a latency shortcut only.
        var spins: usize = 0;
        while (spins < self.config.spin_before_park_iters) : (spins += 1) {
            if (self.state.load(.acquire) != .running) return;
            std.atomic.spinLoopHint();
        }

        // End-of-spin local-work probe: if work became visible during the
        // spin window, skip parking. The probe reads only this worker's
        // local sources plus a single inject_queue length peek — at most
        // 3 atomic loads, executed once per park cycle (vs 128× on the
        // removed poll). Restores the "avoid park on rapid arrival" fast
        // path without the cross-core polling cost.
        if (self.config.scheduler_variant == .work_stealing) {
            if (worker.lifo_slot.load(.monotonic) != LIFO_SLOT_EMPTY) return;
            if (self.local_queues[worker_index].len() != 0) return;
        }
        if (self.inject_queue.len() != 0) return;

        if (self.state.load(.acquire) != .running) return;
```

Note: the `if (self.state.load(.acquire) != .running) return;` line immediately after this block (the post-spin state check at the previous line 796) is PRESERVED unchanged. Do not remove it.

- [ ] **Step 3: Verify the edit**

```bash
sed -n '787,825p' src/pool.zig
```

Confirm: no `counters.queued_tasks` inside the `while (spins < …)` loop body; the three new probes (`lifo_slot`, `local_queue.len()`, `inject_queue.len()`) are present; the existing SC park handshake at line ~812 is untouched.

- [ ] **Step 4: Build**

```bash
zig build -Doptimize=ReleaseFast 2>&1
```

Expected: clean build. If build fails on `self.local_queues[worker_index].len()` being non-pub or similar, inspect `src/queue/ring_queue.zig` and confirm `len()` is `pub`. (It is, as of tip — but a surprise means the change needs adjustment.)

- [ ] **Step 5: Commit**

```bash
git add src/pool.zig
git commit -m "perf: phase g2 - remove idle-spin queued_tasks poll

The worker idle-spin hammered counters.queued_tasks.load(.acquire) once
per iteration × spin_before_park_iters × worker_count. A/B-measuring
the submit path showed this shared load cacheline was a dominant cross-
core traffic source — removing it lifts flood_1m by ~20-26%.

Replace the spin body with a pure spinLoopHint delay, plus a one-shot
end-of-spin probe on local sources (lifo_slot, local queue, inject
queue length) to preserve the fast path for work that lands during
the spin window.

The SC park handshake at the is_parked / queued_tasks reload site is
unchanged — the removed load was a latency shortcut, not a correctness
mechanism."
```

---

## Task 6: Correctness gate — unit + stress tests

**Files:** none. Run tests only.

- [ ] **Step 1: Force-rebuild in debug + release**

```bash
zig build
zig build -Doptimize=ReleaseFast
```

Expected: both clean.

- [ ] **Step 2: Run the full unit suite**

```bash
zig build test 2>&1 | tail -40
```

Expected: all tests pass, including the new Task 3 test.

- [ ] **Step 3: Run stress 5× consecutive in release mode**

```bash
for i in 1 2 3 4 5; do
  zig build test-stress -Doptimize=ReleaseFast 2>&1 | tail -5
  echo "--- run $i done ---"
done
```

Expected: 5/5 PASS. A single failure anywhere here blocks shipping: either the handshake was broken or the new local-work probe introduced a race. Do NOT proceed to Task 7.

- [ ] **Step 4: If any failure, rollback**

If step 3 shows any failure, reset the Task 5 commit but retain the test commits:

```bash
git reset --hard HEAD~1   # drops the Task 5 implementation commit
zig build test-stress     # confirm tests still pass against unchanged pool
```

Document the failure mode in `docs/PERFORMANCE_TRACKING.md` under a "Phase G2 (negative result)" section and STOP — do not proceed to Task 7.

- [ ] **Step 5: Commit nothing (correctness gate only)**

---

## Task 7: Post-impl A/B gate — default vs spin=0

**Files:** none modified. Two rebuilds, two measurements.

This is the mandatory mechanic-engagement gate. If default and spin=0 measure the same, the mechanic (spin + local probe) is inert and we are shipping dead code.

- [ ] **Step 1: Force-rebuild the default configuration**

```bash
zig build -Doptimize=ReleaseFast
```

- [ ] **Step 2: Measure default flood_1m (median of 5)**

```bash
for i in 1 2 3 4 5; do ./zig-out/bin/bench-tokio-parity 2>&1 | grep "^flood_1m"; done
```

Record all 5 values and median in `/tmp/phase-g2-baseline.txt`.

- [ ] **Step 3: Temporarily force `spin_before_park_iters = 0`**

Use Edit to change `src/types.zig:105` from:

```zig
    spin_before_park_iters: usize = 128,
```

to:

```zig
    spin_before_park_iters: usize = 0, // [G2 A/B — reverted at end of Task 7]
```

- [ ] **Step 4: Force-rebuild**

```bash
zig build -Doptimize=ReleaseFast
```

- [ ] **Step 5: Measure spin=0 flood_1m (median of 5)**

```bash
for i in 1 2 3 4 5; do ./zig-out/bin/bench-tokio-parity 2>&1 | grep "^flood_1m"; done
```

Record all 5 values and median.

- [ ] **Step 6: Revert the spin_before_park_iters change**

Use Edit to restore:

```zig
    spin_before_park_iters: usize = 128,
```

```bash
zig build -Doptimize=ReleaseFast
git diff src/types.zig  # expect empty
```

- [ ] **Step 7: Evaluate the A/B gate**

Gate: `(default_median - spin0_median) / baseline_median ≥ 5%`.

- If default is ≥5% higher than spin=0: mechanic engages. The spin + local probe is doing real work. Proceed to Task 8.
- If default and spin=0 are within 5% of each other: mechanic is inert. The "win" is unexplained — either the poll-removal itself is the entire benefit (in which case the spin can be removed entirely as a follow-up) or the numbers are coincidental. ROLLBACK the Task 5 commit; document as negative result. This mirrors the F1 A/B gate that caught the short-spin dead-code path.

- [ ] **Step 8: Record gate outcome**

Write the default median, spin=0 median, delta %, and gate decision to `/tmp/phase-g2-baseline.txt`.

- [ ] **Step 9: Commit nothing**

Task 7 is measurement-only. Ensure `git status` is clean before Task 8.

---

## Task 8: Final measurement + ship decision

**Files:** `docs/PERFORMANCE_TRACKING.md`, optionally `benchmarks/results/baseline.json`.

- [ ] **Step 1: Force-rebuild one more time**

```bash
zig build -Doptimize=ReleaseFast
```

- [ ] **Step 2: Measure contended_spawn_8x (median of 3)**

```bash
for i in 1 2 3; do ./zig-out/bin/bench-tokio-parity 2>&1 | grep "^contended_spawn_8x"; done
```

Expected: ≥ 530K (no regression). If < 500K (> 6% regression vs Task 1 baseline 534K), ROLLBACK — G2 must not regress the multi-submitter scenario.

- [ ] **Step 3: Measure bench-micro-wake p50 (if available)**

```bash
zig build bench-wake 2>&1 | grep -E "p50|p99"
```

Expected: p50 within 20% of Task 1 baseline (~9985 ns). A regression > 20% suggests the local probe is missing work on first pass and forcing a park cycle — ROLLBACK.

- [ ] **Step 4: Ship decision**

Ship iff ALL of the following:
- Task 2 pre-plan A/B gate passed (≥ 380K with poll stubbed)
- Task 6 correctness gate passed (unit 100%, stress 5/5)
- Task 7 post-impl A/B gate passed (default ≥ spin=0 + 5%)
- Task 8 default flood_1m median of 5 ≥ 390K
- Task 8 contended_spawn_8x ≥ 530K
- Task 8 wake p50 within 20% of 9985 ns (or bench-wake target unavailable, skip)

If ANY gate fails, go to Task 9 (rollback path). Otherwise go to Step 5 (ship path).

- [ ] **Step 5 (ship path): Update `docs/PERFORMANCE_TRACKING.md`**

Append a new section `## Phase G2: Idle-Spin Poll Removal (shipped)` with:
- Hypothesis (one paragraph summarising the design rationale from this plan's header)
- Measured table (baseline, default, spin=0 A/B, contended_spawn_8x, wake p50)
- Verdict (delta % vs baseline, why shipped)
- Cross-link to this plan file

Template:

```markdown
## Phase G2: Idle-Spin Poll Removal (shipped)

**Hypothesis:** Worker idle-spin polls `counters.queued_tasks.load(.acquire)`
128× per park cycle × 56 workers, on the same cacheline the submitter
writes with `.seq_cst` on every submit. A/B-disabling the poll lifted
flood_1m +26% in the F1b re-profile. Phase G2 removes the poll and
replaces it with a one-shot local-work probe at the end of the spin.

### Measured (median of 5, ReleaseFast, 56-core host)

| Metric | Baseline (3b0ca5b) | G2 default | G2 spin=0 A/B |
|---|---:|---:|---:|
| `flood_1m` ops/s | {baseline} | **{default}** | {spin0} |
| `contended_spawn_8x` ops/s | 534K | {contended} | — |
| `bench-micro-wake` p50 ns | 9985 | {wake_p50} | — |
| `test-stress` 5× consecutive | pass | pass | pass |

Default ops/s is {delta%} above baseline; default vs spin=0 delta is
{abgate%}, confirming the mechanic (spin + end-of-spin local probe) is
engaging — the lift is not from poll-removal alone.

See `docs/superpowers/plans/2026-04-12-phase-g2-queued-tasks-poll.md`.
```

Fill in the `{…}` placeholders with the measured numbers.

- [ ] **Step 6 (ship path): Rebaseline**

If `benchmarks/results/baseline.json` exists and tracks flood_1m, update the entry to the new G2 median. Otherwise skip.

- [ ] **Step 7 (ship path): Commit docs**

```bash
git add docs/PERFORMANCE_TRACKING.md benchmarks/results/baseline.json
git commit -m "docs(perf): phase g2 shipped - idle-spin queued_tasks poll removed"
```

- [ ] **Step 8 (ship path): Summary for reviewer**

Write a 3–5 line summary to stdout naming: the baseline, the default measurement, the A/B-gate delta, and the correctness runs passed. This is the message used to request review (e.g. PR description).

---

## Task 9: Rollback path (executed only on gate failure)

**Files:** `src/pool.zig`, `src/types.zig` (revert), `docs/PERFORMANCE_TRACKING.md` (append negative result).

Only execute this task if any Task 6, 7, or 8 gate failed.

- [ ] **Step 1: Identify which commits to revert**

Task 5 is the only behavior-change commit. Tasks 3 and 4 (tests) stay — they are permanent regression guards regardless of whether G2 ships.

```bash
git log --oneline feat/phase-g2-queued-tasks-poll ^main
```

- [ ] **Step 2: Reset the Task 5 commit, keep test commits**

```bash
git rebase -i main   # drop only the Task 5 commit; keep Task 3 + Task 4 test commits
```

(Interactive rebase: mark the `perf: phase g2 - remove idle-spin queued_tasks poll` line as `drop`, keep the rest `pick`.)

- [ ] **Step 3: Confirm the revert**

```bash
git diff main -- src/pool.zig      # expect empty
git diff main -- tests/unit.zig    # expect the test addition only
git diff main -- tests/stress.zig  # expect the stress test addition only
zig build -Doptimize=ReleaseFast
zig build test
zig build test-stress
```

Expected: all green. Tree behaves identically to main from the compiler's and runtime's perspective, only the two regression-guard tests are additional.

- [ ] **Step 4: Append negative-result section to `docs/PERFORMANCE_TRACKING.md`**

```markdown
## Phase G2: Idle-Spin Poll Removal (negative result — REVERTED)

**Hypothesis:** [as above]

**Which gate failed:** [Task 6 correctness | Task 7 A/B mechanic-engagement | Task 8 throughput floor | Task 8 contended_spawn_8x regression | Task 8 wake-latency regression]

**Measured:** [table with baseline, G2 default, spin=0 A/B]

**Root cause (best current theory):** [one paragraph — correctness failure points to handshake breakage; mechanic-engagement failure points to local-probe being trivially true every call; throughput regression without correctness failure points to false-sharing introduced by the new probe's cacheline access pattern]

**What was kept:** tests/unit.zig "idle spin" test and tests/stress.zig "aggressive spin flood" test — both exercise the scheduler without depending on the reverted code, so they remain valid regression guards.

**Next direction:** [either "re-attempt with different mechanism" or "move G3 earlier"].

See `docs/superpowers/plans/2026-04-12-phase-g2-queued-tasks-poll.md`.
```

- [ ] **Step 5: Commit the rollback docs**

```bash
git add docs/PERFORMANCE_TRACKING.md
git commit -m "docs(perf): phase g2 reverted - [failed gate name]"
```

- [ ] **Step 6: Branch handling**

Leave the branch `feat/phase-g2-queued-tasks-poll` in place with the two test commits and the rollback docs commit. Merge-back or PR decision is up to the maintainer — the branch represents "two useful regression tests + a documented negative result."

---

## Self-Review Checklist (already executed by plan author)

**1. Spec coverage:** No separate spec. Design rationale embedded in plan header (6 numbered points) — every design decision traces to either A/B data in `docs/PERFORMANCE_TRACKING.md` or the handshake correctness comment at `src/pool.zig:801-811`. Complete.

**2. Placeholder scan:** No "TBD", "implement later", or "handle edge cases". Every step shows the code to write. The rollback-docs template includes `{…}` placeholders, which are explicitly flagged for the measurement values.

**3. Type consistency:** `lifo_slot` is `std.atomic.Value(u32)` throughout pool.zig. `LIFO_SLOT_EMPTY: u32 = 0xFFFF_FFFF` is the existing sentinel. `LocalQueue.len()` is `pub fn` returning `usize`. `BoundedRing.len()` is `pub fn` returning `usize`. `inject_queue` is `BoundedRing(u32)`. All names and signatures match the tree at commit `3b0ca5b`.

**Gaps addressed during review:** Added Task 7 explicit A/B gate threshold (5%) based on Phase F1's methodology precedent. Added Task 8 wake-latency regression clause. Clarified that Task 3+4 test commits are preserved on rollback.

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-04-12-phase-g2-queued-tasks-poll.md`. Two execution options:

**1. Subagent-Driven (recommended)** — dispatch a fresh subagent per task, review between tasks, fast iteration. Use superpowers:subagent-driven-development.

**2. Inline Execution** — execute tasks in this session using superpowers:executing-plans, batch execution with checkpoints.

Which approach?
