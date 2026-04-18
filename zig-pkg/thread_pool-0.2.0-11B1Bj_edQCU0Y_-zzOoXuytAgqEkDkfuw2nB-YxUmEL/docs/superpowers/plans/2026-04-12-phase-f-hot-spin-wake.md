# Phase F1: Hot-Spin Wake Elimination Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eliminate the per-submit `futex_wake` in `enqueueTask` by advertising "a worker is actively polling" via a single atomic counter; the submitter skips the kernel wake on the common path. Target: `flood_1m` ≥ 450K ops/s (from 335K baseline; A/B-verified ceiling 506K).

**Architecture:** Add `Core.active_spinners: std.atomic.Value(u32)`. Wrap the existing `idle()` spin phase (`Config.spin_before_park_iters`, default 128) with `fetchAdd(1)` / `fetchSub(1)`. Modify `enqueueTask`'s wake block to return early when `active_spinners.load(.monotonic) > 0` — spinners will self-discover the task via `workerMain`'s outer loop re-entering `nextTask`. Cold path (all workers parked) unchanged.

**Tech Stack:** Zig 0.15.2, `std.atomic.Value(u32)`, existing `Config.spin_before_park_iters` knob, existing `workerMain`/`idle()`/park handshake machinery.

**Reference design spec:** `docs/superpowers/specs/2026-04-12-phase-f-hot-spin-wake-design.md` — all design decisions locked there. This plan is the mechanical execution.

**Performance Targets (success criteria, measured on same 56-core host as A/B):**

| Metric | Baseline | Target | Stretch |
|---|---:|---:|---:|
| `bench_tokio_parity/flood_1m` ops/s | 335K | **≥ 450K** | ≥ 500K |
| `bench_tokio_parity/contended_spawn_8x` ops/s | 534K | ≥ 600K | ≥ 640K |
| `perf stat` cache-miss rate | 34% | ≤ 25% | ≤ 15% |
| `perf stat` IPC | 0.19 | ≥ 0.35 | ≥ 0.5 |
| Submitter CPU in futex_wake chain | ~50% | ≤ 10% | ≤ 5% |
| Submit p50 (single-worker micro) | 917 ns | ≤ 1000 ns | ≤ 950 ns |
| `test-stress` 5× consecutive | pass | pass | pass |

**Rollback floor:** `flood_1m` median < 400K (less than +19% improvement). Triggers immediate revert per the spec.

**Implementation simplification vs spec:** The spec specified adding a `WORKER_SPIN_LIMIT` file-local constant. Inspection of the codebase shows this already exists as `Config.spin_before_park_iters` (default 128), used in `idle()` at `src/pool.zig:790`. The plan reuses the existing config knob rather than introducing a redundant constant. The spec also specified re-trying `nextTask()` every 8 spins inside the spin loop — the existing design (check cheap `queued_tasks` counter per spin, return to caller which re-enters `nextTask` via `workerMain`'s outer loop) achieves the same goal with lower per-spin cost. Plan uses the existing structure unchanged.

---

## File Structure

**Modified files:**

- `src/pool.zig` — add `Core.active_spinners` field; wrap `idle()` spin with `fetchAdd`/`fetchSub`; modify `enqueueTask`'s wake block to short-circuit when `active_spinners > 0`.
- `tests/unit.zig` — add `active_spinners` concurrency sanity test.
- `docs/PERFORMANCE_TRACKING.md` — Phase F entry with measured numbers.
- `benchmarks/results/baseline.json` — rebaseline on success.

**New files:** none.

---

## Task Ordering Rationale

The mechanic has two halves: worker-side (advertises spinning via counter) and submitter-side (reads counter to skip wake). Landed together in the wrong order the intermediate state either:
- Counter advertised but never read → small CPU overhead, no benefit.
- Counter read but never written → submitter always sees 0, always takes cold path (current behavior).

Either intermediate state is correct and safe. Plan lands them in this order:

1. Infrastructure (inert field).
2. Worker-side counter maintenance (field used, submitter still wakes).
3. Submitter-side skip-wake (both halves active → mechanic enabled).
4. Tests.
5. Measurement + gates.
6. Documentation.

Between Task 2 and Task 3, the pool has slightly higher overhead (spin phase increments a counter nobody reads). This is an acceptable brief transitional state — stress tests must still pass at Task 2.

---

## Task 1: Add `Core.active_spinners` infrastructure

**Files:**

- Modify: `src/pool.zig` (the `Core` struct, around line 224-237)

- [ ] **Step 1: Locate the `Core` struct field list**

Open `src/pool.zig`. The `Core` struct is around line 224. It has fields `allocator`, `config`, `accounting`, `state`, `workers`, `local_queues`, `descriptors`, `free_indices`, `free_top_tagged`, `inject_queue`, `sync`, `counters`, `worker_stats_buffer`.

- [ ] **Step 2: Add the `active_spinners` field**

Insert immediately after `inject_queue: BoundedRing(u32),`:

```zig
    inject_queue: BoundedRing(u32),
    /// Count of workers currently in the pre-park spin phase. Incremented
    /// on entry to the spin loop in `idle()`, decremented on exit (whether
    /// via queued_tasks observation or full park). `enqueueTask` checks
    /// this atomic on every submit: if > 0, a spinning worker will
    /// self-discover the task via the `workerMain` outer loop re-entering
    /// `nextTask`, so the submitter can skip the kernel `futex_wake`. See
    /// docs/superpowers/specs/2026-04-12-phase-f-hot-spin-wake-design.md.
    active_spinners: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    sync: Sync = .{},
```

(The insertion point is between `inject_queue` and `sync`.)

- [ ] **Step 3: Build**

Run: `cd /home/benji/src/devnw/zig/thread-pool-phase-f && zig build`
Expected: SUCCESS. No behavior change (field added but unused).

- [ ] **Step 4: Run full test suite**

Run: `cd /home/benji/src/devnw/zig/thread-pool-phase-f && zig build test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd /home/benji/src/devnw/zig/thread-pool-phase-f && git add src/pool.zig && git commit -m "feat(pool): add Core.active_spinners counter (inert)"
```

---

## Task 2: Worker maintains `active_spinners` during spin phase

**Files:**

- Modify: `src/pool.zig` (`idle()` function, lines 787-830)

- [ ] **Step 1: Locate the spin loop in `idle()`**

Open `src/pool.zig`. `idle()` currently reads (around lines 787-794):

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
    // ... (park handshake begins here, unchanged)
```

- [ ] **Step 2: Bracket the spin loop with `active_spinners` RMW**

Modify the spin loop to register/deregister the worker as a spinner:

```zig
fn idle(self: *Core, worker_index: usize) void {
    var worker = &self.workers[worker_index];

    // Register as a spinner so submitters can skip the kernel wake while
    // at least one worker is actively polling. The decrement happens on
    // every exit path from the spin loop (found work, shutdown, or
    // exhausted iterations falling through to park).
    _ = self.active_spinners.fetchAdd(1, .acq_rel);

    var spins: usize = 0;
    while (spins < self.config.spin_before_park_iters) : (spins += 1) {
        if (self.counters.queued_tasks.load(.acquire) != 0) {
            _ = self.active_spinners.fetchSub(1, .acq_rel);
            return;
        }
        if (self.state.load(.acquire) != .running) {
            _ = self.active_spinners.fetchSub(1, .acq_rel);
            return;
        }
        std.atomic.spinLoopHint();
    }

    _ = self.active_spinners.fetchSub(1, .acq_rel);

    if (self.state.load(.acquire) != .running) return;
    // ... (park handshake continues unchanged from here)
```

The three `fetchSub` calls cover all exit paths from the spin phase. After the spin loop exhausts its iterations and the worker proceeds to park, the counter must be decremented before the park handshake because a parked worker is NOT a spinner — the submitter needs to observe `active_spinners == 0` and wake it via the cold-path `is_parked` scan.

**Invariant:** at any moment, `active_spinners` equals the number of workers currently executing between `fetchAdd` and `fetchSub` inside `idle()`'s spin loop.

- [ ] **Step 3: Build**

Run: `cd /home/benji/src/devnw/zig/thread-pool-phase-f && zig build`
Expected: SUCCESS.

- [ ] **Step 4: Run full test suite**

Run: `cd /home/benji/src/devnw/zig/thread-pool-phase-f && zig build test`
Expected: PASS. At this point the counter is maintained but not read; behavior is unchanged except for the fetchAdd/fetchSub overhead on the idle-to-spin transition.

- [ ] **Step 5: Run stress tests 3× to confirm no regression**

```bash
cd /home/benji/src/devnw/zig/thread-pool-phase-f && for i in 1 2 3; do echo "=== $i ==="; zig build test-stress --summary all || exit 1; done
```

Expected: 3/3 pass. Each should show `N/N tests passed`.

- [ ] **Step 6: Commit**

```bash
cd /home/benji/src/devnw/zig/thread-pool-phase-f && git add src/pool.zig && git commit -m "feat(pool): worker maintains active_spinners during spin phase"
```

---

## Task 3: Submitter skips `futex_wake` when spinners > 0

**Files:**

- Modify: `src/pool.zig` (`enqueueTask`, around lines 578-603)

This is the behavior-change commit. After this lands, the mechanic is active.

- [ ] **Step 1: Locate the wake block in `enqueueTask`**

In `src/pool.zig`, `enqueueTask` around lines 578-603:

```zig
    _ = self.counters.submitted.fetchAdd(1, .monotonic);
    self.incrementQueued();

    // Wake one parked worker. Scan `is_parked` across workers starting at a
    // round-robin offset so load spreads across the pool. The submit-before-park
    // handshake (see idle()) guarantees: if any worker is about to miss this
    // task because it's heading to park, its `is_parked := 1` store is ordered
    // with its reload of `queued_tasks`. So either we observe `is_parked == 1`
    // and signal it, OR the worker reloads `queued_tasks` and sees our push —
    // no lost wakeup. No broadcast fallback is needed.
    const submitted = self.counters.submitted.load(.monotonic);
    const hint_idx: usize = @intCast(submitted % self.workers.len);
    var off: usize = 0;
    while (off < self.workers.len) : (off += 1) {
        const idx = (hint_idx + off) % self.workers.len;
        const w = &self.workers[idx];
        if (w.is_parked.load(.seq_cst) == 1) {
            w.park_mutex.lock();
            if (w.is_parked.load(.monotonic) == 1) {
                w.park_cond.signal();
            }
            w.park_mutex.unlock();
            break;
        }
    }
```

- [ ] **Step 2: Add early-return when a spinner exists**

Insert a fast-path check immediately after `self.incrementQueued();` and before the wake block's comment:

```zig
    _ = self.counters.submitted.fetchAdd(1, .monotonic);
    self.incrementQueued();

    // Hot path: if any worker is currently spinning in idle(), it will
    // observe our queued_tasks increment within one spin iteration and
    // return to workerMain's outer loop, which re-calls nextTask. No
    // kernel wake is needed. This is the dominant case under flood —
    // verified A/B: stubbing the wake block gives ~506K ops/s on
    // flood_1m vs 335K baseline; matching that ceiling hinges on
    // avoiding the per-submit futex when spinners are available.
    // .monotonic is sufficient: the submitter's queued_tasks increment
    // (above, in incrementQueued) provides the synchronization edge to
    // the spinning worker; active_spinners is a pure hint.
    if (self.active_spinners.load(.monotonic) > 0) {
        // (fall through to the return below; skip the wake scan)
    } else {
        // Cold path: no spinners — all workers parked. Wake one via the
        // existing per-worker signal. Preserves the Phase A handshake.
        const submitted = self.counters.submitted.load(.monotonic);
        const hint_idx: usize = @intCast(submitted % self.workers.len);
        var off: usize = 0;
        while (off < self.workers.len) : (off += 1) {
            const idx = (hint_idx + off) % self.workers.len;
            const w = &self.workers[idx];
            if (w.is_parked.load(.seq_cst) == 1) {
                w.park_mutex.lock();
                if (w.is_parked.load(.monotonic) == 1) {
                    w.park_cond.signal();
                }
                w.park_mutex.unlock();
                break;
            }
        }
    }
```

The original wake block (9 lines of scan + signal) is now wrapped in an `else`. The `if (active_spinners > 0)` branch does nothing — control falls through to the `return` at the end of `enqueueTask`.

**Alternative structure** (cleaner): replace the whole thing with an early-return pattern:

```zig
    _ = self.counters.submitted.fetchAdd(1, .monotonic);
    self.incrementQueued();

    // ... (return from enqueueTask skipping wake block if spinner available)
    if (self.active_spinners.load(.monotonic) == 0) {
        // Cold path: no spinners — wake a parked worker.
        const submitted = self.counters.submitted.load(.monotonic);
        const hint_idx: usize = @intCast(submitted % self.workers.len);
        var off: usize = 0;
        while (off < self.workers.len) : (off += 1) {
            const idx = (hint_idx + off) % self.workers.len;
            const w = &self.workers[idx];
            if (w.is_parked.load(.seq_cst) == 1) {
                w.park_mutex.lock();
                if (w.is_parked.load(.monotonic) == 1) {
                    w.park_cond.signal();
                }
                w.park_mutex.unlock();
                break;
            }
        }
    }
```

**Use the alternative structure** (second code block) — it's shorter and has the same semantics. The top doc-comment block explaining A/B evidence goes above this `if`, preserved.

Final form (combining comment + conditional):

```zig
    _ = self.counters.submitted.fetchAdd(1, .monotonic);
    self.incrementQueued();

    // Hot path: if any worker is currently spinning in idle(), it will
    // observe our queued_tasks increment within one spin iteration and
    // return to workerMain's outer loop, which re-calls nextTask. No
    // kernel wake is needed. A/B-verified: stubbing the wake block
    // yields ~506K ops/s on flood_1m vs 335K baseline.
    //
    // .monotonic is sufficient: the queued_tasks increment above
    // provides the synchronization edge to the spinning worker;
    // active_spinners is a pure hint. Worst cases: (1) stale 0 read
    // causes an extra (unnecessary) wake — harmless. (2) stale >0 read
    // skips a needed wake, but the exiting spinner's park handshake
    // re-reads queued_tasks and aborts the park — no lost wakeup.
    if (self.active_spinners.load(.monotonic) == 0) {
        // Cold path: all workers parked. Wake one via the per-worker
        // signal. Preserves the Phase A park-handshake correctness.
        const submitted = self.counters.submitted.load(.monotonic);
        const hint_idx: usize = @intCast(submitted % self.workers.len);
        var off: usize = 0;
        while (off < self.workers.len) : (off += 1) {
            const idx = (hint_idx + off) % self.workers.len;
            const w = &self.workers[idx];
            if (w.is_parked.load(.seq_cst) == 1) {
                w.park_mutex.lock();
                if (w.is_parked.load(.monotonic) == 1) {
                    w.park_cond.signal();
                }
                w.park_mutex.unlock();
                break;
            }
        }
    }
```

- [ ] **Step 3: Build**

Run: `cd /home/benji/src/devnw/zig/thread-pool-phase-f && zig build`
Expected: SUCCESS.

- [ ] **Step 4: Run full test suite**

Run: `cd /home/benji/src/devnw/zig/thread-pool-phase-f && zig build test`
Expected: PASS.

- [ ] **Step 5: Run stress tests 5× consecutive**

Critical correctness gate — the mechanic is now fully active.

```bash
cd /home/benji/src/devnw/zig/thread-pool-phase-f && for i in 1 2 3 4 5; do echo "=== run $i ==="; zig build test-stress --summary all || exit 1; done
```

Expected: 5/5 pass. Each run reports `N/N tests passed`. Any hang or failure means there's a lost-wakeup bug — STOP and diagnose.

Specifically watch for: the `4-submitter deadline-bounded` test (lines ~345 of tests/stress.zig) exercises small queue + backpressure submission; if workers miss wakes the submitter will hit its 5s per-submit deadline and the test's 10s wall-time assertion will fire.

- [ ] **Step 6: Quick flood_1m smoke**

Run one iteration to confirm the change is in the right direction (not a full measurement — Task 6 does that):

```bash
cd /home/benji/src/devnw/zig/thread-pool-phase-f && zig build bench-tokio-parity -Doptimize=ReleaseFast 2>&1 | grep flood_1m
```

Expected: `flood_1m` in the 400K+ range. If < 380K, the mechanic isn't engaging — investigate before committing. If > 400K, proceed (formal measurement in Task 6).

- [ ] **Step 7: Commit**

```bash
cd /home/benji/src/devnw/zig/thread-pool-phase-f && git add src/pool.zig && git commit -m "perf(pool): submitter skips futex_wake when active_spinners > 0"
```

---

## Task 4: Concurrency sanity test for `active_spinners`

**Files:**

- Modify: `tests/unit.zig` (append)

- [ ] **Step 1: Write the test**

Append to `tests/unit.zig`:

```zig
test "active_spinners: counter stays non-negative under concurrent workers" {
    // Integration-level sanity: submit a steady stream of tasks to a
    // multi-worker pool, assert total task count matches after quiesce.
    // If the active_spinners fetchAdd/fetchSub pairing is broken (e.g.,
    // missing a decrement on some exit path), the counter drifts and
    // the submitter either skips all wakes (tasks never picked up) or
    // always wakes (no perf benefit but still correct). This test
    // catches the first failure mode — a stuck pool.
    var pool = try thread_pool.ThreadPool.init(std.testing.allocator, .{
        .min_threads = 4,
        .max_threads = 4,
        .queue_capacity = 4096,
        .local_queue_capacity = 256,
        .scheduler_variant = .work_stealing,
        // Short spin to force rapid spin→park→wake cycles, exercising
        // every exit path from idle().
        .spin_before_park_iters = 8,
        .idle_park_after_ns = 50_000,
    });
    defer pool.deinit();

    var counter = common.Counter{};
    var wg = pool.waitGroup();

    const total: u64 = 40_000;
    var i: u64 = 0;
    while (i < total) : (i += 1) {
        _ = try pool.submit(common.counterTask, @ptrCast(&counter), .{ .wait_group = &wg });
    }
    wg.wait();
    try std.testing.expectEqual(total, counter.value.load(.acquire));

    // Brief quiesce so workers drain any stragglers and return to idle.
    std.Thread.sleep(5 * std.time.ns_per_ms);

    // Submit one more task; must execute. If active_spinners is stuck >0
    // with all workers parked, the submitter skips the wake and this
    // task starves (test timeout via wg.wait semantics on single task).
    var final_counter = common.Counter{};
    var final_wg = pool.waitGroup();
    _ = try pool.submit(common.counterTask, @ptrCast(&final_counter), .{ .wait_group = &final_wg });
    final_wg.wait();
    try std.testing.expectEqual(@as(u64, 1), final_counter.value.load(.acquire));
}
```

- [ ] **Step 2: Run the test**

```bash
cd /home/benji/src/devnw/zig/thread-pool-phase-f && zig build test -- --test-filter "active_spinners"
```

Expected: PASS in < 2 s.

- [ ] **Step 3: Commit**

```bash
cd /home/benji/src/devnw/zig/thread-pool-phase-f && git add tests/unit.zig && git commit -m "test(unit): active_spinners counter sanity under concurrent workers"
```

---

## Task 5: A/B gate — confirm mechanic is providing the win

**Files:** none modified in this task (measurement + gate only).

- [ ] **Step 1: Build ReleaseFast**

```bash
cd /home/benji/src/devnw/zig/thread-pool-phase-f && zig build -Doptimize=ReleaseFast
```

- [ ] **Step 2: Measure flood_1m with default config**

Run `bench-tokio-parity` 3 times. Record `flood_1m` ops/s for each.

```bash
cd /home/benji/src/devnw/zig/thread-pool-phase-f && zig build bench-tokio-parity -Doptimize=ReleaseFast
```

If zig caches the binary invocation, run the binary directly:

```bash
BIN=$(find /home/benji/src/devnw/zig/thread-pool-phase-f/.zig-cache/o -name "thread-pool-tokio-parity" -executable 2>/dev/null | head -1)
for i in 1 2 3; do echo "=== $i ==="; $BIN; done
```

Record all 3 `flood_1m` values.

- [ ] **Step 3: Measure flood_1m with spin disabled (A/B disable gate)**

Temporarily edit `benchmarks/tokio_parity.zig` (or wherever the bench's pool config lives — find it via `grep -n "spin_before_park_iters\|ThreadPool.init" benchmarks/`) to set `spin_before_park_iters = 0`. Rebuild, run once, record. Then REVERT.

Alternative: if the bench doesn't set this config explicitly, add it temporarily. The change is:

Find a line like `.min_threads = cpu_count,` in the flood_1m pool init inside the bench source. Add alongside:
```zig
.spin_before_park_iters = 0,
```

Build ReleaseFast, run one `flood_1m`, note the number. If `spin_before_park_iters = 0`:
- Workers never spin → `active_spinners` never incremented → submitter always takes cold path.
- Expected: `flood_1m` regresses back to baseline (~335K ops/s).

This is the A/B disable gate: if disabling the spin doesn't drop throughput back to baseline, something else is responsible for the gain and the design is misattributed.

**Revert the edit after measurement** — this is purely a measurement experiment, not a commit. Confirm `git diff` is clean.

- [ ] **Step 4: Evaluate gates**

| Gate | Target | Measured | Pass? |
|---|---:|---:|---:|
| flood_1m median (of 3, default spin) | ≥ 450K | TBD | TBD |
| flood_1m with spin=0 (A/B disable) | ~335K (baseline) | TBD | TBD |
| Primary gate | ≥ 450K | TBD | TBD |

Decision tree:
- **Default ≥ 450K AND spin=0 ~335K:** PASS. Mechanic is the source of the gain. Proceed to Task 6.
- **Default < 400K:** ROLLBACK FLOOR. Stop, report BLOCKED.
- **Default 400-450K:** PARTIAL. Report to controller for decision.
- **Default ≥ 450K BUT spin=0 ≥ 380K:** SUSPICIOUS. The gain is not solely from spin-driven skip-wake. Do not claim success — investigate (something else changed, maybe the earlier commits affected the cold path).

- [ ] **Step 5: Record results** (no commit yet, just capture for Task 7)

Write the 3 default-config flood_1m values, the spin=0 A/B value, and the interpretation. These go into Task 7's Phase F documentation.

---

## Task 6: Measure full benchmark suite and rebaseline

**Files:** `benchmarks/results/baseline.json` (rebaseline).

- [ ] **Step 1: Run `bench-tokio-parity` 5 times (formal measurement)**

Using the direct-binary approach from Task 5 Step 2 to avoid caching. Record:
- `flood_1m` ops/s × 5, median
- `contended_spawn_8x` ops/s × 5, median

Acceptance (stricter than Task 5's gate — full evaluation):
- `flood_1m` median ≥ 450K (target) or ≥ 500K (stretch).
- `contended_spawn_8x` median ≥ 600K.

- [ ] **Step 2: Run `bench-micro-submit`**

```bash
cd /home/benji/src/devnw/zig/thread-pool-phase-f && zig build bench-micro-submit -Doptimize=ReleaseFast
```

Record p50/p95/p99. Acceptance: p50 ≤ 1000 ns, p99 ≤ 1800 ns.

- [ ] **Step 3: Run `perf stat` on the tokio-parity binary**

```bash
BIN=$(find /home/benji/src/devnw/zig/thread-pool-phase-f/.zig-cache/o -name "thread-pool-tokio-parity" -executable 2>/dev/null | head -1)
perf stat -e task-clock,cycles,instructions,cache-misses,cache-references,context-switches $BIN
```

Record cache-miss rate (cache-misses / cache-references × 100) and IPC (instructions / cycles). Acceptance: cache-miss ≤ 25%, IPC ≥ 0.35.

- [ ] **Step 4: Run full `bench` CI suite**

```bash
cd /home/benji/src/devnw/zig/thread-pool-phase-f && zig build bench -Doptimize=ReleaseFast
```

Expected: completes. Note any scenario regressing beyond its stddev gate.

- [ ] **Step 5: Rebaseline (only if all gates pass)**

```bash
cd /home/benji/src/devnw/zig/thread-pool-phase-f && mkdir -p benchmarks/results && zig build bench -Doptimize=ReleaseFast -- --output benchmarks/results/baseline.json
```

Verify diff:

```bash
cd /home/benji/src/devnw/zig/thread-pool-phase-f && git diff benchmarks/results/baseline.json | head -20
```

- [ ] **Step 6: Commit rebaselined file**

```bash
cd /home/benji/src/devnw/zig/thread-pool-phase-f && git add benchmarks/results/baseline.json && git commit -m "bench: rebaseline after Phase F hot-spin wake elimination"
```

---

## Task 7: Document Phase F in `PERFORMANCE_TRACKING.md`

**Files:**

- Modify: `docs/PERFORMANCE_TRACKING.md`

- [ ] **Step 1: Append Phase F section**

Insert AFTER the existing `## Phase E: Steal-Scan Bitmap (negative result — REVERTED)` block and BEFORE `## Bench Stability`. Use this template — fill in the TBD cells with numbers from Tasks 5 and 6:

````markdown
## Phase F1: Hot-Spin Wake Elimination

**Shipped:**

1. **`Core.active_spinners: std.atomic.Value(u32)`** — counter of workers currently in the pre-park spin phase of `idle()`.
2. **Worker spin bracketed with `fetchAdd` / `fetchSub`** on `active_spinners` so submitters can cheaply observe whether a self-discovering worker exists.
3. **Submitter hot-path skip** — `enqueueTask` returns without scanning `is_parked[]` or calling `park_cond.signal()` when `active_spinners > 0`. Cold path (all-parked) preserved.

**Design spec:** `docs/superpowers/specs/2026-04-12-phase-f-hot-spin-wake-design.md`.

**A/B-verified ceiling (pre-implementation):** stubbing the wake block entirely yields 506K ops/s on `flood_1m` vs 335K baseline (+51%). Phase F1 aims to recover most of that ceiling while preserving correctness.

### Phase F1 measurements (git SHA TBD, median of 5 runs ReleaseFast, 56-core host)

| Metric | Phase C/E post-revert | Phase F1 | Delta | Target | Met? |
|---|---:|---:|---:|---:|---:|
| Tokio flood_1m | 335K | TBD | TBD | ≥ 450K | TBD |
| Tokio flood_1m, spin=0 A/B gate | — | TBD | should ≈ 335K | — | TBD |
| Tokio contended_spawn_8x | 534K | TBD | TBD | ≥ 600K | TBD |
| Submit p50 (1 worker, 100k samples) | 917 ns | TBD | TBD | ≤ 1000 ns | TBD |
| Submit p99 | 1690 ns | TBD | TBD | ≤ 1800 ns | TBD |
| `perf stat` cache-miss rate | 34% | TBD | TBD | ≤ 25% | TBD |
| `perf stat` IPC | 0.19 | TBD | TBD | ≥ 0.35 | TBD |
| `conn_churn_seq/global_queue` | 758K | TBD | TBD | within 3×stddev | TBD |
| `conn_churn_seq/work_stealing` | 683K | TBD | TBD | within 3×stddev | TBD |
| `test-stress` 5× consecutive | pass | pass | — | pass | TBD |

### Why this phase worked where D and E didn't

Phases D and E were planned from cumulative-CPU profiles and didn't run A/B-disable checks before committing plans. Both produced ~0% (D) or ~-5% (E) throughput changes despite eliminating real work from real hot paths. Phase F was planned from a wall-clock per-thread profile (`perf sched record`) showing the submitter 89% CPU-bound with 50% in the futex_wake chain, and the spec cited an A/B-verified ceiling (506K with wake stubbed) before any code was written. The measured result (TBD) confirms or denies that the target was real.

### Residual gap to Tokio parity

Tokio's `rt_multi_threaded` runs 5–15M ops/s on flood_1m-equivalent. Phase F1 target is 450K — still 10–30× short. Follow-up phases:

1. **Phase F2: `submitBatch` adoption.** Amortize one wake over N pushes. Orthogonal to F1.
2. **Phase F3: coalesced wake (conditional).** Only if F1+F2 fall short of ~480K. Requires root-causing the Phase C stress-test hang.
3. **Phase G: descriptor-pool / inject-queue contention.** Per Phase D profile: CAS free-list (~2.7%) + inject pop (~7.7%); re-profile after F1 lands to see current proportions.
4. **Phase H: worker-local allocation.**
````

Fill in every `TBD` cell using the numbers captured from Tasks 5 and 6 (flood_1m median, A/B spin=0 value, cache-miss rate, IPC, etc.). Fill in the git SHA of the rebaseline commit from Task 6.

- [ ] **Step 2: Update the top-of-file "Verdict vs Targets" table**

Locate the `bench_tokio_parity/flood_1m ≥ 1M ops/s` row (around line 21) and update the "After plan" cell to include the Phase F number, e.g.:

```
| `bench_tokio_parity/flood_1m` ≥ 1M ops/s | 297K | 340K (C) / 341K (D, reverted) / 322K (E, reverted) / TBD (F1) | ... |
```

Same treatment for `contended_spawn_8x`.

- [ ] **Step 3: Commit**

```bash
cd /home/benji/src/devnw/zig/thread-pool-phase-f && git add docs/PERFORMANCE_TRACKING.md && git commit -m "docs(perf): Phase F1 verdict, rebaseline after hot-spin wake"
```

---

## Self-Review Checklist

Before declaring the plan complete:

- [ ] `Core.active_spinners` field exists and is `std.atomic.Value(u32)`.
- [ ] `idle()` wraps its spin loop with matched fetchAdd(1)/fetchSub(1) on all exit paths (early return on queued_tasks, early return on shutdown, fall-through to park).
- [ ] `enqueueTask` reads `active_spinners` BEFORE the wake scan; skips the scan when > 0.
- [ ] `active_spinners` load on hot path uses `.monotonic`.
- [ ] Existing Phase A park handshake preserved.
- [ ] Unit test for active_spinners passes.
- [ ] `test-stress` 5× consecutive pass.
- [ ] flood_1m median ≥ 450K (target).
- [ ] flood_1m with spin_before_park_iters=0 regresses to ~335K baseline (A/B gate).
- [ ] perf stat cache-miss rate ≤ 25%.
- [ ] Baseline committed.
- [ ] PERFORMANCE_TRACKING.md Phase F filled in with measured numbers.

## Rollback Criteria

- `flood_1m` median < 400K after Task 5 → ROLLBACK. Revert Tasks 1-3; keep Task 4 test as a permanent guard.
- `flood_1m` ≥ 450K BUT spin=0 ≥ 380K → ROLLBACK. Gain not attributable to this mechanic; something else changed and the design is misattributed.
- Any stress test hangs or fails 5× → ROLLBACK. Lost-wakeup bug in the hot-path skip logic.
- submit p50 regresses beyond 20% → ROLLBACK. Coordination overhead exceeds savings.

## Execution Handoff

**Plan complete and saved to `docs/superpowers/plans/2026-04-12-phase-f-hot-spin-wake.md`. Two execution options:**

**1. Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, review between tasks, fast iteration. The critical gates are Task 3 Step 5 (5× stress after mechanic activation) and Task 5 (A/B sanity check — must pass BOTH the target AND the spin=0 regression check).

**2. Inline Execution** — Execute tasks in this session using executing-plans, batch execution with checkpoints.

**Which approach?**
