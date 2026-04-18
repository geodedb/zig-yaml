# Phase G1: Sharded Wake Targeting Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the O(N) `is_parked[]` scan in `wakeOneParkedWorker` with an O(1) bitmap-driven targeted wake via `@ctz` on `Core.parked_mask: std.atomic.Value(u64)`. A/B-verified ceiling: 488K ops/s (+47% vs 331K baseline).

**Architecture:** Add `Core.parked_mask` maintained by workers in the existing Phase A park handshake (SC fetchOr on park, release fetchAnd on unpark). Rewrite `wakeOneParkedWorker` to load the mask, rotate by an existing counter, `@ctz` to find a parked worker, then take that specific worker's `park_mutex` and signal. `is_parked` per-worker flag retained for mutex-guarded correctness recheck.

**Tech Stack:** Zig 0.15.2, `std.atomic.Value(u64)`, `std.math.rotr`, `@ctz`, existing Phase A park handshake machinery. No new dependencies.

**Reference spec:** `docs/superpowers/specs/2026-04-12-phase-g1-sharded-wake-design.md` — all design decisions locked there. This plan is mechanical execution.

**Performance Targets:**

| Metric | Baseline | Target | Stretch |
|---|---:|---:|---:|
| `bench_tokio_parity/flood_1m` ops/s | 331K | **≥ 450K** | ≥ 485K |
| `bench_tokio_parity/contended_spawn_8x` ops/s | 534K | ≥ 600K | ≥ 650K |
| `test-stress` 5× consecutive | pass | pass | pass |

**Rollback floor:** `flood_1m` median < 400K.

**MANDATORY post-impl A/B gate:** stub `parked_mask` maintenance to no-ops (force fetchOr/fetchAnd to never execute; force load to return 0). flood_1m should regress to baseline (~331K) because wakes become ineffective. If it doesn't regress, the bitmap isn't the source of the lift — ROLLBACK.

---

## File Structure

**Modified files:**

- `src/pool.zig` — add `Core.parked_mask` field (near `sync`); add `workerBit` inline helper (re-introduce — was removed when Phase E rolled back); update `idle()` to maintain `parked_mask` on park + unpark edges; rewrite `wakeOneParkedWorker` as `@ctz`-driven bitmap lookup.
- `tests/unit.zig` — targeted-wake correctness test.
- `tests/stress.zig` — bitmap-wake correctness under wide-pool flood.
- `docs/PERFORMANCE_TRACKING.md` — Phase G1 entry with measurements.
- `benchmarks/results/baseline.json` — rebaseline on success.

**New files:** none.

---

## Task Ordering Rationale

The mechanic has three code touchpoints: `parked_mask` field declaration, worker-side maintenance, submitter-side lookup. Intermediate states must be safe:

1. Add `parked_mask` field + `workerBit` helper (inert: field exists, nobody reads/writes).
2. Worker maintains `parked_mask` in `idle()` (field is written; `wakeOneParkedWorker` still uses old scan; submit behavior unchanged).
3. Rewrite `wakeOneParkedWorker` to use the bitmap (mechanic active).
4. Correctness test.
5. Wide-pool stress test.
6. A/B gate + measurement.
7. Rebaseline.
8. Document.

After task 2, `parked_mask` is maintained but `wakeOneParkedWorker` ignores it — redundant writes but correct. After task 3, the mechanic is active.

---

## Task 1: Add `Core.parked_mask` field + `workerBit` helper

**Files:**

- Modify: `src/pool.zig` (add helper near top; add field in `Core` struct)

### Step 1: Locate the existing helpers near the top of `src/pool.zig`

In `src/pool.zig`, around lines 144-146 you'll find:

```zig
/// Sentinel value meaning "the lifo_slot is empty". Chosen as the max u32
/// so descriptor indices (0..queue_capacity-1) never collide.
const LIFO_SLOT_EMPTY: u32 = 0xFFFF_FFFF;
```

### Step 2: Add `workerBit` helper immediately after `LIFO_SLOT_EMPTY`

Insert:

```zig
/// Returns the bitmap bit corresponding to a worker index. Used by the
/// steal-scan and wake-scan bitmaps (`Core.parked_mask` in Phase G1; future
/// phases may add more). Caller must ensure `i < types.MAX_WORKERS = 64`;
/// `Config.validate()` enforces this.
inline fn workerBit(i: usize) u64 {
    std.debug.assert(i < 64);
    return @as(u64, 1) << @intCast(i);
}
```

### Step 3: Locate the `Core` struct

Around line 224-236 of `src/pool.zig`. Fields are ordered: `allocator`, `config`, `accounting`, `state`, `workers`, `local_queues`, `descriptors`, `free_indices`, `free_top_tagged`, `inject_queue`, `sync`, `counters`, `worker_stats_buffer`.

### Step 4: Insert `parked_mask` field between `inject_queue` and `sync`

Before:
```zig
    inject_queue: BoundedRing(u32),
    sync: Sync = .{},
```

After:
```zig
    inject_queue: BoundedRing(u32),
    /// Bitmap of parked workers. Bit `i` set ⇔ worker `i` is parked
    /// (in the kernel-wait portion of idle()). Maintained by workers
    /// during the Phase A park handshake; read by `wakeOneParkedWorker`
    /// to target wakes in O(1) via @ctz instead of scanning N workers.
    /// See docs/superpowers/specs/2026-04-12-phase-g1-sharded-wake-design.md.
    parked_mask: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    sync: Sync = .{},
```

### Step 5: Build + test

```bash
cd /home/benji/src/devnw/zig/thread-pool-phase-f && zig build
```

Expected: SUCCESS.

```bash
cd /home/benji/src/devnw/zig/thread-pool-phase-f && zig build test
```

Expected: all tests pass. No behavior change — field is declared but unread/unwritten; helper function is private and unused at this point.

### Step 6: Commit

```bash
cd /home/benji/src/devnw/zig/thread-pool-phase-f && git add src/pool.zig && git commit -m "feat(pool): add Core.parked_mask + workerBit helper (inert)"
```

---

## Task 2: Maintain `parked_mask` in `idle()` park handshake

**Files:**

- Modify: `src/pool.zig` (`idle()` function around lines 787-830)

### Step 1: Locate `idle()`

Around lines 787-830 of `src/pool.zig`. The current structure (post-F1b rollback):

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

    _ = worker.parks.fetchAdd(1, .release);

    worker.park_mutex.lock();
    // SC total-order handshake ...
    worker.is_parked.store(1, .seq_cst);
    if (self.counters.queued_tasks.load(.seq_cst) != 0 or self.state.load(.acquire) != .running) {
        worker.is_parked.store(0, .release);
        worker.park_mutex.unlock();
        _ = worker.wakeups.fetchAdd(1, .release);
        return;
    }
    worker.park_cond.timedWait(&worker.park_mutex, self.config.idle_park_after_ns) catch {};
    worker.is_parked.store(0, .release);
    worker.park_mutex.unlock();
    _ = worker.wakeups.fetchAdd(1, .release);

    // ... purge logic unchanged ...
}
```

### Step 2: Add `parked_mask` maintenance on both the park-abort and park-wake paths

Modify `idle()` so every `is_parked.store(1, .seq_cst)` is paired with a `parked_mask.fetchOr(workerBit(worker_index), .seq_cst)` and every `is_parked.store(0, .release)` is preceded by a `parked_mask.fetchAnd(~workerBit(worker_index), .release)`. The relevant portion becomes:

```zig
    worker.park_mutex.lock();
    // SC total-order handshake ...
    worker.is_parked.store(1, .seq_cst);
    _ = self.parked_mask.fetchOr(workerBit(worker_index), .seq_cst);
    if (self.counters.queued_tasks.load(.seq_cst) != 0 or self.state.load(.acquire) != .running) {
        _ = self.parked_mask.fetchAnd(~workerBit(worker_index), .release);
        worker.is_parked.store(0, .release);
        worker.park_mutex.unlock();
        _ = worker.wakeups.fetchAdd(1, .release);
        return;
    }
    worker.park_cond.timedWait(&worker.park_mutex, self.config.idle_park_after_ns) catch {};
    _ = self.parked_mask.fetchAnd(~workerBit(worker_index), .release);
    worker.is_parked.store(0, .release);
    worker.park_mutex.unlock();
    _ = worker.wakeups.fetchAdd(1, .release);
```

Three changes inside `idle()`:
1. `fetchOr` immediately after `is_parked.store(1, .seq_cst)`.
2. `fetchAnd` on the abort path, immediately before `is_parked.store(0, .release)`.
3. `fetchAnd` on the post-wait path, immediately before `is_parked.store(0, .release)`.

Ordering: the SC fetchOr joins the same total order as `is_parked.store(.seq_cst)` — together they are the "parked" publication. The release fetchAnd pairs with the acquire-load in `wakeOneParkedWorker` (Task 3).

### Step 3: Build + test

```bash
cd /home/benji/src/devnw/zig/thread-pool-phase-f && zig build
```

Expected: SUCCESS.

```bash
cd /home/benji/src/devnw/zig/thread-pool-phase-f && zig build test
```

Expected: all tests pass. `parked_mask` is maintained but nothing reads it yet — functionally equivalent to current behavior plus a few extra atomic RMWs on park/unpark edges.

### Step 4: Run stress tests 3×

```bash
cd /home/benji/src/devnw/zig/thread-pool-phase-f && for i in 1 2 3; do echo "=== $i ==="; zig build test-stress --summary all || exit 1; done
```

Expected: 3/3 pass. The park handshake's correctness is unchanged — `parked_mask` maintenance is strictly additive.

### Step 5: Commit

```bash
cd /home/benji/src/devnw/zig/thread-pool-phase-f && git add src/pool.zig && git commit -m "feat(pool): worker maintains parked_mask during park handshake"
```

---

## Task 3: Rewrite `wakeOneParkedWorker` as O(1) bitmap lookup

**Files:**

- Modify: `src/pool.zig` (`wakeOneParkedWorker` around the new helper added in Phase F1b refactor — it's already extracted as a standalone method)

This is the behavior-change commit. After this lands the mechanic is active.

### Step 1: Locate `wakeOneParkedWorker`

In `src/pool.zig`, the function was extracted during an earlier Phase F1b refactor (commit `2f97805`, reverted) — BUT the refactor's `wakeOneParkedWorker` extraction was part of Task 2 of F1b, which was reverted. So `enqueueTask` currently has the wake scan INLINE.

Grep to confirm:

```bash
cd /home/benji/src/devnw/zig/thread-pool-phase-f && grep -n "wakeOneParkedWorker\|Wake one parked worker" src/pool.zig
```

If the function doesn't exist, the wake scan is inline in `enqueueTask` around lines 586-603:

```zig
    // Wake one parked worker. Scan `is_parked` across workers ...
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

### Step 2: Replace the entire inline block with a call + define the helper

In `src/pool.zig`, REPLACE the inline wake block above with a call:

```zig
    self.wakeOneParkedWorker();
```

Then ADD a new private method to `Core`, immediately before `workerMain` (around line 615):

```zig
    /// Wake one parked worker via O(1) bitmap lookup. Replaces the
    /// O(N) scan of workers[*].is_parked. Reads `parked_mask`, rotates
    /// by a per-pool counter (to avoid herding on worker 0), uses @ctz
    /// to find a parked worker, then takes that worker's park_mutex
    /// and signals. The is_parked flag is retained for the mutex-guarded
    /// correctness recheck (cover the race where the worker unparked
    /// between our load and our signal).
    ///
    /// A/B-verified ceiling: stubbing the wake block entirely gave
    /// 488K ops/s on flood_1m vs 331K baseline (+47%).
    /// See docs/superpowers/specs/2026-04-12-phase-g1-sharded-wake-design.md.
    fn wakeOneParkedWorker(self: *Core) void {
        const mask = self.parked_mask.load(.seq_cst);
        if (mask == 0) return;

        // Rotate by an existing counter to spread wakes across workers.
        // G3 will replace this with a submitter-local source; for G1 it
        // preserves current round-robin semantics with one extra load.
        const rot: u6 = @intCast(self.counters.submitted.load(.monotonic) & 63);
        const rotated = std.math.rotr(u64, mask, rot);
        if (rotated == 0) return; // rotation emptied visible bits (max_threads < 64 case)

        const tz: u6 = @intCast(@ctz(rotated));
        const idx = (@as(usize, tz) + @as(usize, rot)) & 63;
        if (idx >= self.workers.len) return; // alias past N; next wake will retry

        const w = &self.workers[idx];
        // Fast-path recheck without mutex: worker may have unparked
        // between our mask load and now.
        if (w.is_parked.load(.seq_cst) != 1) return;

        w.park_mutex.lock();
        if (w.is_parked.load(.monotonic) == 1) {
            w.park_cond.signal();
        }
        w.park_mutex.unlock();
    }
```

### Step 3: Build

```bash
cd /home/benji/src/devnw/zig/thread-pool-phase-f && zig build
```

Expected: SUCCESS. If Zig complains about integer coercion on `@ctz(rotated)` or `@intCast` to u6, try `const tz: u6 = @intCast(@as(u7, @ctz(rotated)));` (u7 is the natural return of `@ctz(u64)` when non-zero).

### Step 4: Run full test suite

```bash
cd /home/benji/src/devnw/zig/thread-pool-phase-f && zig build test
```

Expected: all tests pass. The mechanic is now live — wakes go through the bitmap.

### Step 5: CRITICAL — Run stress tests 5× consecutive

```bash
cd /home/benji/src/devnw/zig/thread-pool-phase-f && for i in 1 2 3 4 5; do echo "=== run $i ==="; zig build test-stress --summary all || exit 1; done
```

Expected: 5/5 pass. Every run reports `N/N tests passed`. If any hang or fail → BLOCKED, report with details of which test.

### Step 6: Quick flood_1m smoke

```bash
cd /home/benji/src/devnw/zig/thread-pool-phase-f && zig build -Doptimize=ReleaseFast
BIN=$(find /home/benji/src/devnw/zig/thread-pool-phase-f/.zig-cache/o -name "thread-pool-tokio-parity" -executable 2>/dev/null | head -1)
$BIN
```

Expected: `flood_1m` ops/s ≥ 400K. The A/B ceiling was 488K; we're aiming for ≥ 450K (target) and will formally measure in Task 6. If smoke < 380K, the mechanic isn't delivering — investigate before committing.

Record the smoke number in your report.

### Step 7: Commit

```bash
cd /home/benji/src/devnw/zig/thread-pool-phase-f && git add src/pool.zig && git commit -m "perf(pool): O(1) bitmap-driven wake targeting via @ctz"
```

---

## Task 4: Targeted-wake correctness unit test

**Files:**

- Modify: `tests/unit.zig` (append)

### Step 1: Append the test

```zig
test "parked_mask: single-task submit wakes a parked worker" {
    // 2-worker pool. Submit one task, wait for it. Then let workers
    // park (sleep past idle_park_after_ns). Submit a second task —
    // it must execute. If parked_mask isn't maintained correctly,
    // wakeOneParkedWorker will miss the parked worker and the task
    // will hang until timedWait expires.
    var pool = try thread_pool.ThreadPool.init(std.testing.allocator, .{
        .min_threads = 2,
        .max_threads = 2,
        .queue_capacity = 64,
        .local_queue_capacity = 32,
        .scheduler_variant = .work_stealing,
        .spin_before_park_iters = 4,
        .idle_park_after_ns = 50_000,
    });
    defer pool.deinit();

    var counter = common.Counter{};
    var wg = pool.waitGroup();
    _ = try pool.submit(common.counterTask, @ptrCast(&counter), .{ .wait_group = &wg });
    wg.wait();
    try std.testing.expectEqual(@as(u64, 1), counter.value.load(.acquire));

    // Wait past idle_park_after_ns + spin + a safety margin so both
    // workers are firmly parked.
    std.Thread.sleep(5 * std.time.ns_per_ms);

    // Second task MUST execute via the wake mechanism. If parked_mask
    // isn't maintained, wakeOneParkedWorker sees mask == 0 and issues
    // no wake; the worker's timedWait (50us) fires and re-polls. Test
    // would still pass eventually but with ~50us-5ms latency. We assert
    // it completes in under 10ms to fail loudly if the bitmap breaks.
    var solo = common.Counter{};
    var solo_wg = pool.waitGroup();
    const start_ns = std.time.nanoTimestamp();
    _ = try pool.submit(common.counterTask, @ptrCast(&solo), .{ .wait_group = &solo_wg });
    solo_wg.wait();
    const elapsed_ns = std.time.nanoTimestamp() - start_ns;
    try std.testing.expectEqual(@as(u64, 1), solo.value.load(.acquire));
    try std.testing.expect(elapsed_ns < 10 * std.time.ns_per_ms);
}
```

### Step 2: Run + commit

```bash
cd /home/benji/src/devnw/zig/thread-pool-phase-f && zig build test -- --test-filter "parked_mask"
```

Expected: PASS, elapsed < 10ms.

```bash
cd /home/benji/src/devnw/zig/thread-pool-phase-f && git add tests/unit.zig && git commit -m "test(unit): parked_mask targeted-wake correctness"
```

---

## Task 5: Wide-pool stress test

**Files:**

- Modify: `tests/stress.zig` (append)

### Step 1: Append the test

```zig
test "parked_mask: wide-pool bitmap wake correctness under flood" {
    // cpu_count (clamped to 64) workers with 200k tasks via a single
    // submitter. If the @ctz bitmap wake targets a worker that isn't
    // actually parked (race between mask load and is_parked recheck),
    // or if the rotation aliases produce a systematic miss pattern,
    // tasks will stall in the inject_queue and never complete.
    const cpu_count = @min(std.Thread.getCpuCount() catch 4, 64);
    if (cpu_count < 2) return;

    var pool = try thread_pool.ThreadPool.init(std.testing.allocator, .{
        .min_threads = cpu_count,
        .max_threads = cpu_count,
        .queue_capacity = 4096,
        .local_queue_capacity = 256,
        .scheduler_variant = .work_stealing,
    });
    defer pool.deinit();

    var counter = common.Counter{};
    var wg = pool.waitGroup();
    const total: u64 = 200_000;
    var i: u64 = 0;
    while (i < total) : (i += 1) {
        while (true) {
            _ = pool.submit(common.counterTask, @ptrCast(&counter), .{
                .wait_group = &wg,
            }) catch {
                std.Thread.sleep(1_000);
                continue;
            };
            break;
        }
    }
    wg.wait();
    try std.testing.expectEqual(total, counter.value.load(.acquire));
}
```

### Step 2: Run + 5× stress gate

```bash
cd /home/benji/src/devnw/zig/thread-pool-phase-f && zig build test-stress -- --test-filter "parked_mask"
```

Expected: PASS.

```bash
cd /home/benji/src/devnw/zig/thread-pool-phase-f && for i in 1 2 3 4 5; do echo "=== run $i ==="; zig build test-stress --summary all || exit 1; done
```

Expected: 5/5 pass.

### Step 3: Commit

```bash
cd /home/benji/src/devnw/zig/thread-pool-phase-f && git add tests/stress.zig && git commit -m "test(stress): parked_mask wide-pool bitmap wake correctness"
```

---

## Task 6: A/B-disable gate (MANDATORY)

**Files:** none modified (measurement only; may temporarily edit `src/pool.zig` to stub bitmap maintenance, then revert).

### Step 1: Baseline measurement

```bash
cd /home/benji/src/devnw/zig/thread-pool-phase-f && zig build -Doptimize=ReleaseFast
BIN=$(find /home/benji/src/devnw/zig/thread-pool-phase-f/.zig-cache/o -name "thread-pool-tokio-parity" -executable 2>/dev/null | head -1)
for i in 1 2 3 4 5; do echo "=== G1 run $i ==="; $BIN; done
```

Capture `flood_1m` and `contended_spawn_8x` for each run. Compute median of 5.

### Step 2: A/B-disable measurement (stub bitmap to "always empty")

Temporarily modify `wakeOneParkedWorker` in `src/pool.zig` to ALWAYS return early, simulating the bitmap being empty:

```zig
fn wakeOneParkedWorker(self: *Core) void {
    _ = self;
    return;  // A/B experiment: simulate bitmap always empty — no wake ever issued
    // ... rest of function body unchanged but dead code ...
}
```

Or cleaner — just replace the entire body with `_ = self; return;`.

Rebuild:
```bash
cd /home/benji/src/devnw/zig/thread-pool-phase-f && zig build -Doptimize=ReleaseFast
```

Run 3 times:
```bash
BIN=$(find /home/benji/src/devnw/zig/thread-pool-phase-f/.zig-cache/o -name "thread-pool-tokio-parity" -executable 2>/dev/null | head -1)
for i in 1 2 3; do echo "=== A/B stubbed run $i ==="; $BIN; done
```

Compute median.

### Step 3: REVERT the stub

```bash
cd /home/benji/src/devnw/zig/thread-pool-phase-f && git checkout src/pool.zig
cd /home/benji/src/devnw/zig/thread-pool-phase-f && git diff
```

Verify `git diff` is empty.

### Step 4: Evaluate gates

| Gate | Target | Measured | Pass? |
|---|---:|---:|---:|
| G1 flood_1m median | ≥ 450K | TBD | TBD |
| A/B-stubbed flood_1m median | regresses to ~331K baseline | TBD | TBD |
| Delta | G1 >> A/B-stubbed | TBD | TBD |

Decision tree:

- **G1 median ≥ 450K AND A/B-stubbed ≈ 331K:** CLEAN PASS.
- **G1 < 400K:** ROLLBACK FLOOR. BLOCKED.
- **G1 in [400K, 450K):** PARTIAL. Report for controller decision.
- **G1 ≥ 450K BUT A/B-stubbed also ≥ 400K:** SUSPICIOUS. Something else is lifting throughput; not the bitmap. Investigate.

Record all numbers for Task 8.

---

## Task 7: Formal measurement + rebaseline

**Files:** `benchmarks/results/baseline.json` (only if Task 6 gates pass).

### Step 1: Formal measurement

Using direct binary invocation (still from Task 6 build). Record 5 runs each:

- `flood_1m` ops/s
- `contended_spawn_8x` ops/s

### Step 2: Submit latency micro

```bash
cd /home/benji/src/devnw/zig/thread-pool-phase-f && zig build bench-micro-submit -Doptimize=ReleaseFast
```

Record p50, p95, p99.

### Step 3: Full CI bench

```bash
cd /home/benji/src/devnw/zig/thread-pool-phase-f && zig build bench -Doptimize=ReleaseFast
```

Expected: completes. Note any scenario regressing.

### Step 4: Rebaseline

```bash
cd /home/benji/src/devnw/zig/thread-pool-phase-f && mkdir -p benchmarks/results && zig build bench -Doptimize=ReleaseFast -- --output benchmarks/results/baseline.json
```

### Step 5: Commit baseline

```bash
cd /home/benji/src/devnw/zig/thread-pool-phase-f && git add benchmarks/results/baseline.json && git commit -m "bench: rebaseline after Phase G1 sharded wake"
```

---

## Task 8: Document Phase G1 in `PERFORMANCE_TRACKING.md`

**Files:**

- Modify: `docs/PERFORMANCE_TRACKING.md`

### Step 1: Append Phase G1 section

Insert AFTER the Phase F1b section, before `## Bench Stability`:

````markdown
## Phase G1: Sharded Wake Targeting

**Shipped:**

1. **`Core.parked_mask: std.atomic.Value(u64)`** — bitmap of parked workers.
2. **`workerBit(i)` inline helper** — returns the bit for a worker index.
3. **Park handshake maintains `parked_mask`** — SC fetchOr on park, release fetchAnd on unpark.
4. **`wakeOneParkedWorker` rewritten as O(1)** — load mask, rotate, @ctz, signal that specific worker.

**Design spec:** `docs/superpowers/specs/2026-04-12-phase-g1-sharded-wake-design.md`.

**A/B-verified ceiling (pre-implementation):** stubbing the wake block entirely gave 488K ops/s (+47% vs 331K).

### Phase G1 measurements (git SHA TBD, median of 5 runs ReleaseFast, 56-core host)

| Metric | Baseline | Phase G1 | A/B-stubbed | Delta vs baseline | Target | Met? |
|---|---:|---:|---:|---:|---:|---:|
| `flood_1m` ops/s | 331K | TBD | TBD | TBD | ≥ 450K | TBD |
| `contended_spawn_8x` ops/s | 534K | TBD | — | TBD | ≥ 600K | TBD |
| Submit p50 (100k samples) | 917 ns | TBD | — | TBD | ≤ 1000 ns | TBD |
| Submit p99 | 1690 ns | TBD | — | TBD | ≤ 1800 ns | TBD |
| `test-stress` 5× consecutive | pass | pass | — | — | pass | TBD |

### Why G1 delivered where F1/F1b didn't

F1/F1b conditionally skipped the wake scan based on runtime state (F1: any worker spinning; F1b: hot_spinners configured). The conditions were rarely satisfied or had counterbalancing cost. **G1 unconditionally replaces the O(N) scan with an O(1) lookup on every submit.** The work is genuinely eliminated — not conditionally skipped — so the A/B-measured individual lift (+47%) translates to real throughput.

### Residual gap to Tokio parity

Tokio runs 5-15M. G1 target is 450K-488K — still 10-30× short. Follow-up phases:

1. **G2: Remove `queued_tasks` from idle-spin.** A/B-measured +26%.
2. **G3: Submitter-local counter.** A/B-measured +28%.
3. **Phase H: Descriptor CAS rework.** A/B-measured +16%.

Expected after G1+G2+G3 combined: ~1.0M ops/s per the decomposition experiment.
````

Replace TBDs with measured numbers from Tasks 6-7.

### Step 2: Update top-of-file verdict table

Locate the `flood_1m ≥ 1M ops/s` row (~line 21) and append G1 to the "After plan" cell.

### Step 3: Commit

```bash
cd /home/benji/src/devnw/zig/thread-pool-phase-f && git add docs/PERFORMANCE_TRACKING.md && git commit -m "docs(perf): Phase G1 verdict, rebaseline after sharded wake"
```

---

## Self-Review Checklist

- [ ] `Core.parked_mask` field exists with doc comment.
- [ ] `workerBit` inline helper exists with debug.assert.
- [ ] `idle()` maintains `parked_mask` on all three edges (park-store, abort, wake).
- [ ] `wakeOneParkedWorker` uses `parked_mask.load(.seq_cst)` + `@ctz` + rotation.
- [ ] `is_parked` retained for mutex-guarded correctness recheck.
- [ ] Targeted-wake unit test passes (single-task after quiesce in < 10ms).
- [ ] Wide-pool stress test passes.
- [ ] `test-stress` 5× consecutive passes.
- [ ] **A/B gate: stubbing bitmap to "always empty" regresses throughput to ≈ baseline.**
- [ ] **flood_1m median ≥ 450K (target).**
- [ ] Baseline committed (only if gates pass).
- [ ] PERFORMANCE_TRACKING.md Phase G1 filled in.

## Rollback Criteria

- `flood_1m` median < 400K → ROLLBACK Tasks 2-3 (keep Task 1 field + Tasks 4-5 tests).
- Any stress test hangs or fails 5× → ROLLBACK (lost-wakeup bug in park handshake).
- A/B-stubbed doesn't regress to ≈ baseline → mechanic isn't the source; investigate.
- Submit p50 regresses beyond 20% → ROLLBACK (bitmap overhead exceeds savings).

## Execution Handoff

**Plan complete. Two execution options:**

1. **Subagent-Driven (recommended)** — fresh subagent per task + two-stage review. Critical gates: Task 3 Step 5 (5× stress after mechanic activation), Task 6 (A/B gate).
2. **Inline Execution** — executing-plans skill, batch checkpoints.

**Which approach?**
