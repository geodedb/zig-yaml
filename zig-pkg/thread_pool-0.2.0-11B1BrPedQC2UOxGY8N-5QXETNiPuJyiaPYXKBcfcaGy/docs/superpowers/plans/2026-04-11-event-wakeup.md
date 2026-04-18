# Event-Based Worker Wakeup (PERF-005) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the blind `Thread.sleep` in worker `idle()` with a `Condition`-based park/wake so submitters can wake parked workers immediately, eliminating the 250us latency floor.

**Architecture:** Add a `park_cond`/`park_mutex` pair to `Core`. Workers wait on `park_cond` instead of sleeping. `enqueueTask` signals `park_cond` after a successful push when parked workers exist. Shutdown broadcasts to wake all parked workers. The spin-before-park optimization is preserved — only the sleep is replaced.

**Tech Stack:** Zig 0.15.2, `std.Thread.Condition`, `std.Thread.Mutex`

**Closes:** PERF-005

---

## File Structure

| File | Action | Responsibility |
|------|--------|---------------|
| `src/thread_pool/pool.zig` | **Modify** | Add park_cond/park_mutex to Core; rewrite idle(); add signal in enqueueTask; add broadcast in shutdown |

---

## Task 1: Add park_cond/park_mutex to Core and rewrite idle()

**Files:**

- Modify: `src/thread_pool/pool.zig`

- [ ] **Step 1: Add fields to Core struct**

After `completion_cond` (around line 80), add:

```zig
    park_mutex: std.Thread.Mutex = .{},
    park_cond: std.Thread.Condition = .{},
```

- [ ] **Step 2: Rewrite idle() to use Condition wait**

Replace the current `idle()` function. The spin loop stays. Replace `Thread.sleep` with a timed condition wait:

```zig
    fn idle(self: *Core, worker_index: usize) void {
        var worker = &self.workers[worker_index];
        var spins: usize = 0;
        while (spins < self.config.spin_before_park_iters) : (spins += 1) {
            if (self.queued_tasks.load(.acquire) != 0) return;
            if (self.state.load(.acquire) != .running) return;
            std.atomic.spinLoopHint();
        }

        if (self.state.load(.acquire) != .running) return;

        _ = self.parks.fetchAdd(1, .monotonic);
        worker.parks += 1;

        self.park_mutex.lock();
        _ = self.parked_workers.fetchAdd(1, .monotonic);
        // Re-check after incrementing parked_workers (under lock) to avoid lost wake
        if (self.queued_tasks.load(.acquire) != 0 or self.state.load(.acquire) != .running) {
            _ = self.parked_workers.fetchSub(1, .monotonic);
            self.park_mutex.unlock();
            worker.wakeups += 1;
            return;
        }
        self.park_cond.timedWait(&self.park_mutex, self.config.idle_park_after_ns) catch {};
        _ = self.parked_workers.fetchSub(1, .monotonic);
        self.park_mutex.unlock();
        worker.wakeups += 1;

        if (self.config.worker_scratch_cap_bytes != 0 and self.config.idle_purge_after_ns != 0) {
            const now = nowNs();
            if (now - worker.last_idle_started_ns >= self.config.idle_purge_after_ns) {
                worker.scratch.purge();
            }
        }
    }
```

Key design decisions:

- `parked_workers` is incremented under `park_mutex` BEFORE the wait. This ensures submitters checking `parked_workers > 0` after push will see the parked worker and signal.
- Re-check predicate after incrementing but before wait to avoid lost wake.
- `timedWait` with `idle_park_after_ns` preserves scratch purge timing.

- [ ] **Step 3: Run tests**

Run: `./zig-0.15.2/zig build test --summary all && ./zig-0.15.2/zig build test-integration --summary all && timeout 120 ./zig-0.15.2/zig build test-stress --summary all`

- [ ] **Step 4: Commit**

```bash
git add src/thread_pool/pool.zig
git commit -m "perf: replace Thread.sleep with Condition wait in idle()

Workers now park on park_cond instead of blind sleeping. The timed
wait preserves idle_park_after_ns semantics for scratch purge.
parked_workers is incremented under park_mutex before wait to prevent
lost-wake races.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: Signal parked workers from enqueueTask

**Files:**

- Modify: `src/thread_pool/pool.zig`

- [ ] **Step 1: Add signal after successful push in enqueueTask**

After `incrementQueued()` (around line 347), add:

```zig
        if (self.parked_workers.load(.monotonic) > 0) {
            self.park_mutex.lock();
            self.park_cond.signal();
            self.park_mutex.unlock();
        }
```

Using `signal()` (not `broadcast()`) wakes one worker — sufficient for one new task. The `parked_workers > 0` check avoids the mutex cost when all workers are busy.

- [ ] **Step 2: Add broadcast in shutdown after state transition**

In `shutdown()`, after `self.state.store(.stopping, .release)` (around line 220), add:

```zig
        self.park_mutex.lock();
        self.park_cond.broadcast();
        self.park_mutex.unlock();
```

This wakes ALL parked workers so they can observe `state != .running` and exit.

- [ ] **Step 3: Run all tests**

Run: `./zig-0.15.2/zig build test --summary all && ./zig-0.15.2/zig build test-integration --summary all && timeout 120 ./zig-0.15.2/zig build test-stress --summary all`

- [ ] **Step 4: Run cross-compile and format**

Run: `./zig-0.15.2/zig build cross-check && ./zig-0.15.2/zig fmt --check src/`

- [ ] **Step 5: Commit**

```bash
git add src/thread_pool/pool.zig
git commit -m "perf: close PERF-005 - signal parked workers from enqueueTask

Submitters signal park_cond when parked_workers > 0 after pushing
a task. Shutdown broadcasts to wake all workers for clean exit.
Eliminates the 250us latency floor for task pickup.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: Benchmark and document

- [ ] **Step 1: Run benchmarks**

```bash
./zig-0.15.2/zig build bench 2>/dev/null | python3 -c "import json,sys; [print(f\"{r['scenario_name']:25} {r['scheduler_variant']:15} {r['throughput_ops_per_sec']:>12,.0f} ops/s\") for r in json.load(sys.stdin)['rows']]"
```

- [ ] **Step 2: Update PERF_GAP_ANALYSIS.md**

Mark PERF-005 as Closed with measured latency improvement.

- [ ] **Step 3: Commit**

```bash
git add docs/PERF_GAP_ANALYSIS.md
git commit -m "docs: close PERF-005 in tracking

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```
