# Wake-Scan Parked-Count Gate Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a global `parked_count: std.atomic.Value(u32)` gate that lets the submitter skip the O(N) `is_parked[]` wake-scan entirely when no workers are parked. Target: capture a meaningful fraction of the re-profile's +34.8% wake-scan A/B ceiling without the consolidation-anti-pattern traps that killed Phase G1.

**Architecture:** The current wake-scan at `src/pool.zig:615-645` iterates over all `workers.len` workers (56 on target host) on every `spawn`, doing one seq_cst load per worker just to find a parked one to signal. In flood_1m's steady-state, 56/56 workers are busy stealing (re-profile Task 2: worker median 8% running); `is_parked` is 0 for all of them, so the scan finds nothing and returns after burning 56 cacheline loads. Adding a single atomic counter that the park/unpark paths maintain lets the submitter short-circuit the scan with one `.acquire` load.

The correctness of the existing submit-before-park handshake (SC total order on `queued_tasks` and `is_parked`) is **preserved**; `parked_count` is orthogonal — a pure optimization gate. Detailed correctness argument in Task 2.

**Tech Stack:** Zig 0.15.2, `std.atomic.Value`, `@atomicLoad`/`@atomicStore` where appropriate.

**Closes:** next target after re-profile's Phase G3 (re-profile ordered list: 1=G3 done, 2=wake-scan this plan, 3=architectural pivot).

---

## Baseline and evidence

- **Host:** Linux + Zig 0.15.2 + 56-core x86_64.
- **Baseline:** Today under co-tenant load, flood_1m measures 380-390K ops/s on both pre-G3 main (`65f920d`) and prior G3 full branch. Session-earlier 566K baseline is not reproducible today (co-tenant + kernel/cache state); any phase work lands against today's baseline.
- **A/B ceiling (wake-scan removed entirely):** re-profile Task 5 measured +34.8% (566K → 763K under load), stress 20/20 PASS. Under today's lower baseline the absolute ceiling is similarly fractional: expect ~1.3× lift if we capture the full ceiling, or ~1.15× for a partial capture via the gate.
- **Methodology (mandatory):**
  - Force-rebuild from `.zig-cache/` for every measurement.
  - Direct `./zig-out/bin/thread-pool-tokio-parity flood_1m` invocation.
  - n=10 medians; n=5 is thin-sample only.
  - 20× stress gate per change that touches scheduler timing; 100× final pre-merge.
  - Capture `uptime` and CPU frequency state with every measurement (re-profile Task 4 lesson).
  - Use paired same-host-state comparison (pre-gate vs post-gate back-to-back) to control for baseline drift.

## Why this is NOT a G1-style consolidation anti-pattern

G1 (Phase G1 in PERFORMANCE_TRACKING) replaced `is_parked[]` (distributed, per-worker) with a shared u64 bitmap (`parked_mask`). That regressed by -6% because **56 workers writing to one cacheline** cost more than 56 readers each hitting their own cacheline. The fix lesson was: don't consolidate a distributed resource onto a shared cacheline when write contention > read cost.

This plan is different:
- **We keep `is_parked[]` distributed.** The per-worker cacheline traffic pattern is unchanged.
- **We add ONE additional atomic** (`parked_count`) that workers increment on park and decrement on unpark. That's 2 writes per park cycle, not per spawn.
- **The submitter reads `parked_count` ONCE per spawn** with `.acquire` (a plain load, no RMW).
- When `parked_count == 0` (common case), the submitter skips 56 distinct-cacheline reads — net win.
- When `parked_count > 0`, the submitter does one extra `.acquire` load before the 56-iteration scan — small cost amortized over rare parked state.

Write contention on `parked_count`: happens only on park/unpark transitions. In flood_1m steady state, workers rarely park (they're busy). Under intermittent load, some workers park/unpark per-task, but that's also the case where the scan currently dominates.

## File Structure

Files modified by this plan:

- `src/pool.zig` — THREE edits:
  - `Sync` struct or new sibling struct: add `parked_count: std.atomic.Value(u32)`.
  - `enqueueTask` wake-scan prelude (~`:612-624`): add the gate — if `parked_count == 0`, skip the scan.
  - `idle()` park path (~`:898-925`): increment before `is_parked.store(1, .seq_cst)`; decrement on all three exit paths (spurious wake, signaled wake, timeout).

- `tests/unit.zig` — append ONE correctness test that validates the gate doesn't introduce lost wakeups under a synthetic park/submit race.

No new files. No public API change.

Close-out artifacts:

- `docs/performance/wake-scan-gate/stress-20x.txt`
- `docs/performance/wake-scan-gate/flood_1m-pre-n10.txt` (main pre-gate)
- `docs/performance/wake-scan-gate/flood_1m-post-n10.txt` (branch post-gate)
- `docs/performance/wake-scan-gate/cpu-freq-log.txt`
- `docs/performance/wake-scan-gate/SUMMARY.md`
- `docs/performance/wake-scan-gate/stress-100x.txt` (pre-merge)
- `docs/PERFORMANCE_TRACKING.md` — append `§ Wake-Scan Parked-Count Gate` section at close-out.

---

## Task 0: Setup — worktree + feature branch

**Files:** none modified (git operations).

- [ ] **Step 1: Confirm main state**

```bash
cd /home/benji/src/devnw/zig/thread-pool
git checkout main
git rev-parse HEAD   # expect 65f920d or newer descendant
git status
```

Working tree should be clean except the unrelated untracked `docs/superpowers/plans/2026-04-13-phase-h-fix-double-dequeue-race.md`.

- [ ] **Step 2: Create worktree**

```bash
git worktree add -b feat/wake-scan-parked-count-gate \
  /home/benji/src/devnw/zig/thread-pool-wake-gate main
cd /home/benji/src/devnw/zig/thread-pool-wake-gate
git branch --show-current
git rev-parse HEAD
```

- [ ] **Step 3: Smoke build**

```bash
rm -rf zig-out/ .zig-cache/
zig build -Doptimize=ReleaseFast
./zig-out/bin/thread-pool-tokio-parity flood_1m
```

Expected: one scenario=flood_1m ops_per_sec line in the current 350-500K band (host-state-dependent). If much lower, flag host load but proceed — per-spec measurement is later.

No commit in this task.

---

## Task 1: Add `parked_count` field

**Files:**
- Modify: `src/pool.zig` — Sync struct (currently at `:200-214`) OR Core struct.

Rationale for placement: `parked_count` is written by workers (on park/unpark) and read by the submitter (on every spawn). It's on the wake synchronization path. Placing it inside `Sync` keeps it with related mutex/condvar fields; placing it on `Core` avoids an extra indirection but risks false-sharing with other hot fields. Since `Sync` is a separate struct already isolated by `sync: Sync = .{}` in Core, placing it there keeps coupling clean.

- [ ] **Step 1: Inspect current Sync struct**

```bash
cd /home/benji/src/devnw/zig/thread-pool-wake-gate
sed -n '200,214p' src/pool.zig
```

Expected output approximately:

```zig
const Sync = struct {
    completion_mutex: std.Thread.Mutex = .{},
    completion_cond: std.Thread.Condition = .{},
    /// Backpressure primitives: ...
    backpressure_mutex: std.Thread.Mutex = .{},
    backpressure_cond: std.Thread.Condition = .{},
    backpressure_waiters: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
};
```

- [ ] **Step 2: Add `parked_count` field**

Edit `src/pool.zig`. In the `Sync` struct, append after `backpressure_waiters`:

```zig
    /// Count of workers currently parked (between `worker.is_parked.store(1, .seq_cst)`
    /// in idle() and either timedWait return or unpark decrement). Read by the
    /// submitter with `.acquire` on every spawn to short-circuit the O(N)
    /// is_parked[] scan when no workers are parked. Written only by workers
    /// on park entry / park exit paths. The count is an ORTHOGONAL OPTIMIZATION
    /// GATE — correctness of the submit-before-park lost-wakeup handshake is
    /// carried by the SC total-order on `queued_tasks` and `is_parked`
    /// (see idle() comment block). A stale `parked_count == 0` read by the
    /// submitter after a worker has SC-stored `is_parked = 1` cannot cause a
    /// lost wakeup because the worker's subsequent SC-load of `queued_tasks`
    /// observes the submitter's SC-fetchAdd and the worker returns without
    /// waiting. See docs/superpowers/plans/2026-04-13-wake-scan-parked-count-gate.md.
    parked_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
```

- [ ] **Step 3: Verify build + tests**

```bash
rm -rf zig-out/ .zig-cache/
zig build -Doptimize=ReleaseFast 2>&1 | tail -10
zig build test 2>&1 | tail -10
```

Expected: clean build, all tests pass. The new field is unused at this point.

- [ ] **Step 4: Commit**

```bash
git add src/pool.zig
git commit -m "$(cat <<'EOF'
perf(wake-gate): add Sync.parked_count atomic (unused)

Phase 1 of docs/superpowers/plans/2026-04-13-wake-scan-parked-count-gate.md.

Introduces the field before any code path reads or writes it. Subsequent
commits add (a) the worker-side increment/decrement and (b) the
submitter-side short-circuit gate.
EOF
)"
```

---

## Task 2: Maintain `parked_count` in `idle()` park/unpark paths

**Files:**
- Modify: `src/pool.zig` — `idle()` function (approximately `:850-930`).

**Correctness requirement:** `parked_count` must be a lower bound on "workers that may be in `park_cond.timedWait`". If it's a lower bound, the submitter's fast-exit on `parked_count == 0` cannot cause a lost wakeup because:

- If the submitter reads `parked_count == 0` AFTER its SC `queued_tasks.fetchAdd`, and some worker W is concurrently parking, then W's SC sequence is: `parked_count.fetchAdd(1, .release)` → `is_parked.store(1, .seq_cst)` → `queued_tasks.load(.seq_cst)` → if nonzero, abort park (decrement count, return).
- The submitter's SC `queued_tasks.fetchAdd(.seq_cst)` MUST synchronize in total order with W's SC `queued_tasks.load(.seq_cst)`. Whichever happens first in SC total order determines the outcome:
  - If submitter's fetchAdd first: W's load sees the increment, W aborts park, no wait, no lost wakeup.
  - If W's load first: W reads 0 (submitter's inc hasn't happened in SC order), W proceeds to wait. But then the submitter's fetchAdd happens AFTER, and by SC total order, W's `is_parked.store(.seq_cst)` also happens BEFORE in SC order. Which means the submitter's NEXT atomic operation — the `parked_count.load(.acquire)` — happens AFTER W's `parked_count.fetchAdd(.release)`. So the submitter reads `parked_count > 0` and enters the scan, finds W's `is_parked == 1`, signals it.

Key invariant: **parked_count is incremented BEFORE `is_parked.store(.seq_cst)` with release ordering.** The release on fetchAdd synchronizes-with the submitter's acquire load of parked_count.

Decrement ordering: can be relaxed. The submitter doesn't need to know "this worker is definitely unparked"; a late `parked_count > 0` just means the scan runs and the scan finds `is_parked == 0` for that worker, which is a no-op.

- [ ] **Step 1: Read the current `idle()` function**

```bash
cd /home/benji/src/devnw/zig/thread-pool-wake-gate
grep -n "^    fn idle" src/pool.zig
# then:
sed -n '850,935p' src/pool.zig
```

Expected to see the park sequence:
- Spin loop
- `worker.parks.fetchAdd(1, .release)`
- `worker.park_mutex.lock()`
- `worker.is_parked.store(1, .seq_cst)` ← MUST happen AFTER parked_count.fetchAdd
- SC `queued_tasks.load(.seq_cst)` check → if nonzero, unpark immediately
- `park_cond.timedWait(...)` or single `park_cond.wait(...)`
- Exit path: `worker.is_parked.store(0, .release)` + `parks`/`wakeups` increments + return

- [ ] **Step 2: Insert increment BEFORE `is_parked.store(1, .seq_cst)`**

Find the line:

```zig
        worker.is_parked.store(1, .seq_cst);
```

Immediately BEFORE that line (i.e., after `worker.park_mutex.lock();` but before any `is_parked` or SC-guarded store), insert:

```zig
        // Increment parked_count BEFORE is_parked.store(.seq_cst). The release
        // here pairs with the submitter's acquire load in enqueueTask; combined
        // with the SC total-order on queued_tasks + is_parked, this guarantees
        // no lost wakeup when the submitter uses parked_count as a short-circuit
        // gate. See plan file for correctness argument.
        _ = self.sync.parked_count.fetchAdd(1, .release);
```

- [ ] **Step 3: Insert decrement on the "queued_tasks seen nonzero — abort park" path**

Find the block that looks approximately like:

```zig
        worker.is_parked.store(1, .seq_cst);
        if (self.counters.queued_tasks.load(.seq_cst) != 0 or self.state.load(.acquire) != .running) {
            worker.is_parked.store(0, .release);
            worker.park_mutex.unlock();
            _ = worker.wakeups.fetchAdd(1, .release);
            return;
        }
```

Modify the abort-park block to decrement parked_count BEFORE returning:

```zig
        worker.is_parked.store(1, .seq_cst);
        if (self.counters.queued_tasks.load(.seq_cst) != 0 or self.state.load(.acquire) != .running) {
            worker.is_parked.store(0, .release);
            _ = self.sync.parked_count.fetchSub(1, .release);  // G3-WAKEGATE: paired with the increment above
            worker.park_mutex.unlock();
            _ = worker.wakeups.fetchAdd(1, .release);
            return;
        }
```

- [ ] **Step 4: Insert decrement on the timedWait-return / normal-wake path**

After the `park_cond.timedWait(...)` call returns (or whatever wait form is used), find the normal-exit sequence that looks approximately like:

```zig
        worker.park_cond.timedWait(&worker.park_mutex, ...) catch {};
        worker.is_parked.store(0, .release);
        worker.park_mutex.unlock();
        _ = worker.wakeups.fetchAdd(1, .release);
```

Modify to decrement parked_count:

```zig
        worker.park_cond.timedWait(&worker.park_mutex, ...) catch {};
        worker.is_parked.store(0, .release);
        _ = self.sync.parked_count.fetchSub(1, .release);  // G3-WAKEGATE: paired with the increment above
        worker.park_mutex.unlock();
        _ = worker.wakeups.fetchAdd(1, .release);
```

(If the function uses `wait` (non-timed) instead of `timedWait`, the same pattern applies.)

If there are OTHER exit paths from idle() after the park block — e.g., a shutdown check or a deferred error — verify each one that follows the `is_parked.store(1, .seq_cst)` does a matching `parked_count.fetchSub`. Use the Grep tool to find every `is_parked.store(0,` line in idle() and audit each.

- [ ] **Step 5: Verify build + unit tests**

```bash
rm -rf zig-out/ .zig-cache/
zig build -Doptimize=ReleaseFast 2>&1 | tail -10
zig build test 2>&1 | tail -10
```

Expected: clean build. Unit tests pass — the gate isn't wired into the submitter yet, so behavior should be unchanged.

- [ ] **Step 6: Sanity-check the balance with a debug assertion (optional, throwaway)**

For diagnostic confidence, temporarily add this assertion at a convenient cold path (e.g., in `deinit()` after all workers have joined):

```zig
std.debug.assert(self.sync.parked_count.load(.acquire) == 0);
```

Run `zig build test` in Debug mode (not ReleaseFast — asserts are stripped in ReleaseFast). If any unit test's pool shutdown observes `parked_count != 0`, there's an unbalanced increment somewhere.

If the assertion passes across all unit tests, REMOVE the debug-only assertion before the commit (it's not a production guard — the counter is allowed to be approximate if sharded later).

- [ ] **Step 7: Commit**

```bash
git add src/pool.zig
git commit -m "$(cat <<'EOF'
perf(wake-gate): maintain parked_count in idle() park/unpark paths

Phase 2 of docs/superpowers/plans/2026-04-13-wake-scan-parked-count-gate.md.

Worker increments parked_count.fetchAdd(1, .release) immediately before
is_parked.store(1, .seq_cst) inside park_mutex. Matching fetchSub on all
exit paths:
  - queued_tasks-seen-nonzero early-return
  - timedWait-return normal path
(Plus any other audited exit from the parked state.)

The release on fetchAdd synchronizes-with the submitter's acquire load
introduced in the next commit. Correctness of the lost-wakeup handshake
is carried by the existing SC total-order on queued_tasks and is_parked;
parked_count is an orthogonal optimization gate, not a correctness
mechanism. See the plan for the detailed argument.

Counter not yet consumed; subsequent commit wires the submitter fast-exit.
EOF
)"
```

---

## Task 3: Submitter fast-exit on `parked_count == 0`

**Files:**
- Modify: `src/pool.zig` — `enqueueTask` wake-scan prelude (approximately `:611-645`).

- [ ] **Step 1: Read the current wake-scan prelude**

```bash
sed -n '611,650p' src/pool.zig
```

Expected (approximately):

```zig
        _ = self.counters.submitted.fetchAdd(1, .monotonic);
        self.incrementQueued();

        // Wake one parked worker. Scan `is_parked` ...
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

- [ ] **Step 2: Insert the fast-exit gate**

Replace the block starting with `const submitted = ...` (through the end of the `while` loop) with:

```zig
        // G3-WAKEGATE: short-circuit when no workers are parked. This is the
        // common case during saturated workloads (flood_1m: 56/56 workers
        // steal-busy, is_parked all 0). The .acquire load pairs with the
        // worker's .release fetchAdd on parked_count in idle(). Correctness
        // of the lost-wakeup handshake is carried by the SC total-order on
        // `queued_tasks` (fetchAdd above was .seq_cst-equivalent via
        // incrementQueued()) and `is_parked` — a stale-read of
        // parked_count == 0 cannot cause a lost wakeup because the
        // concurrently-parking worker will SC-load queued_tasks AFTER
        // storing is_parked and see the submitter's increment, then abort
        // the park. See docs/superpowers/plans/2026-04-13-wake-scan-parked-count-gate.md.
        if (self.sync.parked_count.load(.acquire) != 0) {
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

Note: the original block is indented 8 spaces (function body); the new `if` wraps it and bumps inner indent by 4. Verify visually that the wrap is clean — zig fmt will reformat if needed on commit.

**IMPORTANT:** Confirm that `incrementQueued()` uses `.seq_cst` semantics on `queued_tasks`. Read its definition:

```bash
grep -n "fn incrementQueued" src/pool.zig
# then read the function body:
```

If `incrementQueued` uses `.seq_cst` fetchAdd on `queued_tasks`, the correctness argument holds. If it's `.release` or `.monotonic`, the submit-before-park handshake is ALREADY broken on main (which would be a pre-existing bug, not one we're introducing). Either way, proceed — we're not regressing anything.

- [ ] **Step 3: Verify build + unit tests**

```bash
rm -rf zig-out/ .zig-cache/
zig build -Doptimize=ReleaseFast 2>&1 | tail -10
zig build test 2>&1 | tail -10
```

Expected: clean build, all tests pass.

- [ ] **Step 4: Run the existing integration + stress suite once (short gate)**

```bash
zig build test-integration 2>&1 | tail -10
timeout 120 zig build test-stress -Doptimize=ReleaseFast 2>&1 | tail -10
```

Expected: integration passes; single stress pass. If stress fails in this single run, do NOT commit — debug. If it passes, proceed.

- [ ] **Step 5: Commit**

```bash
git add src/pool.zig
git commit -m "$(cat <<'EOF'
perf(wake-gate): short-circuit enqueueTask wake-scan on parked_count==0

Phase 3 of docs/superpowers/plans/2026-04-13-wake-scan-parked-count-gate.md.

Submitter reads Sync.parked_count with .acquire and skips the O(N)
is_parked[] scan if the count is 0. In flood_1m steady state (all
workers steal-busy), parked_count is 0 nearly every spawn, so the
submitter avoids 56 cross-cacheline seq_cst loads per task.

Correctness of the lost-wakeup handshake is carried by the existing
SC total-order on queued_tasks (.seq_cst fetchAdd in incrementQueued())
and is_parked (.seq_cst store in idle()). The parked_count gate is an
orthogonal optimization; a stale 0 read cannot cause a lost wakeup.

Pre-merge gates: 20x stress (Task 5), n=10 measurement (Task 4),
100x stress (Task 7).
EOF
)"
```

---

## Task 4: Correctness regression test

**Files:**
- Modify: `tests/unit.zig` — append a test that exercises a park/submit race to validate no lost wakeups.

- [ ] **Step 1: Read existing test patterns**

```bash
sed -n '1,20p' tests/unit.zig
grep -n '^test' tests/unit.zig | tail -10
```

Note: the codebase uses `common.Counter`, `common.counterTask`, `common.defaultConfig(.work_stealing)`, `pool.waitGroup()`, `pool.submit(...)`, `pool.statsSnapshot()`. Match these idioms.

- [ ] **Step 2: Append the new test**

Append to the end of `tests/unit.zig`:

```zig
test "wake-gate: no lost wakeup under park/submit interleave" {
    // Force workers to park frequently by using a config that tends toward
    // parking: minimal spin, short idle window. Then submit tasks with
    // small inter-submit pauses so some subset of workers park between
    // tasks. Assert all submitted tasks are eventually executed.
    var cfg = common.defaultConfig(.work_stealing);
    cfg.spin_before_park_iters = 0;            // no spin; workers try to park immediately
    cfg.idle_park_after_ns = 10_000_000;        // 10ms idle window
    var pool = try thread_pool.ThreadPool.init(std.testing.allocator, cfg);
    defer pool.deinit();

    const N: u64 = 500;
    var wg = pool.waitGroup();
    var counter = common.Counter{};
    var i: u64 = 0;
    while (i < N) : (i += 1) {
        _ = try pool.submit(common.counterTask, @ptrCast(&counter), .{ .wait_group = &wg });
        // Small yield between submits — increases the probability that some
        // workers park between submissions, exercising the parked_count
        // increment/decrement paths.
        if (i % 10 == 0) std.Thread.yield() catch {};
    }
    wg.wait();

    try std.testing.expectEqual(N, counter.value.load(.acquire));
    const stats = pool.statsSnapshot();
    try std.testing.expectEqual(N, stats.submitted);
    try std.testing.expectEqual(N, stats.completed);
}
```

- [ ] **Step 3: Verify the test passes**

```bash
zig build test 2>&1 | tail -20
```

Expected: all tests pass, including the new test. If it hangs, `wg.wait()` is stuck — indicates a lost wakeup. STOP and bisect.

- [ ] **Step 4: Commit**

```bash
git add tests/unit.zig
git commit -m "$(cat <<'EOF'
test(wake-gate): park/submit interleave guard

Adds a unit test that forces workers into park frequently (short idle
window, zero spin) and submits N=500 tasks with yield pauses. Asserts
all N tasks are both submitted and completed — guards against lost
wakeups under the parked_count gate.

Part of docs/superpowers/plans/2026-04-13-wake-scan-parked-count-gate.md.
EOF
)"
```

---

## Task 5: 20× ReleaseFast stress gate

**Files:**
- Create: `docs/performance/wake-scan-gate/stress-20x.txt`

- [ ] **Step 1: Pre-flight load check**

```bash
cd /home/benji/src/devnw/zig/thread-pool-wake-gate
mkdir -p docs/performance/wake-scan-gate
{ echo "# load before stress:"; uptime; } | tee docs/performance/wake-scan-gate/stress-20x.txt
```

If 1-min load > 8, STOP and report BLOCKED.

- [ ] **Step 2: 20× stress loop (60-min timeout)**

Pass `timeout: 3600000` to the Bash tool:

```bash
{
  pass=0; fail=0
  for i in $(seq 1 20); do
    START=$(date +%s)
    if timeout 300 zig build test-stress -Doptimize=ReleaseFast > /tmp/wake-stress-$i.log 2>&1; then
      pass=$((pass+1))
      echo "run $i: PASS ($(($(date +%s) - $START))s)"
    else
      fail=$((fail+1))
      echo "run $i: FAIL ($(($(date +%s) - $START))s)"
      tail -5 /tmp/wake-stress-$i.log || true
    fi
  done
  echo "=== SUMMARY: pass=$pass fail=$fail ==="
  echo "# load after stress:"; uptime
} | tee -a docs/performance/wake-scan-gate/stress-20x.txt
```

Expected: `pass=20 fail=0`. Any failure blocks progression; bisect the three sub-change commits.

- [ ] **Step 3: Commit**

```bash
git add docs/performance/wake-scan-gate/stress-20x.txt
git commit -m "$(cat <<'EOF'
test(wake-gate): 20x ReleaseFast stress gate validation

Part of docs/superpowers/plans/2026-04-13-wake-scan-parked-count-gate.md.
EOF
)"
```

If any failure, DO NOT proceed to Task 6.

---

## Task 6: Paired n=10 measurement + close-out

**Files:**
- Create: `docs/performance/wake-scan-gate/flood_1m-pre-n10.txt`
- Create: `docs/performance/wake-scan-gate/flood_1m-post-n10.txt`
- Create: `docs/performance/wake-scan-gate/cpu-freq-log.txt`
- Create: `docs/performance/wake-scan-gate/SUMMARY.md`
- Modify: `docs/PERFORMANCE_TRACKING.md`

- [ ] **Step 1: Pre-flight**

```bash
cd /home/benji/src/devnw/zig/thread-pool-wake-gate
uptime
```

If 1-min load > 4, wait. The paired comparison is MUCH more valuable than Task 5's stress — load matters more here.

- [ ] **Step 2: Set up CPU frequency sampler (background)**

```bash
cat > /tmp/freq-sample.sh << 'EOF'
#!/bin/bash
OUT=$1
while true; do
  max=0
  for c in /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq; do
    f=$(cat "$c" 2>/dev/null || echo 0)
    (( f > max )) && max=$f
  done
  printf "%d %d\n" "$(date +%s%3N)" "$max" >> "$OUT"
  sleep 0.2
done
EOF
chmod +x /tmp/freq-sample.sh
```

- [ ] **Step 3: Measure PRE-gate (main) n=10 with freq logging**

```bash
cd /home/benji/src/devnw/zig/thread-pool  # PRIMARY worktree, on main
git rev-parse HEAD
rm -rf zig-out/ .zig-cache/
zig build -Doptimize=ReleaseFast

/tmp/freq-sample.sh /tmp/pre-gate-freq.log &
SAMPLER_PID=$!
sleep 0.5

{
  echo "# PRE-gate (main) at $(git rev-parse --short HEAD) ($(date -Iseconds))"
  echo "# load at start:"; uptime
  for i in $(seq 1 10); do
    echo "--- run $i ---"
    timeout 60 ./zig-out/bin/thread-pool-tokio-parity flood_1m
  done
  echo "# load at end:"; uptime
} | tee /tmp/pre-gate-raw.txt

kill $SAMPLER_PID 2>/dev/null
wait $SAMPLER_PID 2>/dev/null

grep 'scenario=flood_1m' /tmp/pre-gate-raw.txt \
  | grep -Eo 'ops_per_sec=[0-9]+' | grep -Eo '[0-9]+' | sort -n | awk '
      {a[NR]=$1}
      END { if(NR%2)print"pre median:",a[(NR+1)/2];else print"pre median:",(a[NR/2]+a[NR/2+1])/2; print"pre min:",a[1]; print"pre max:",a[NR]; print"n:",NR }' \
  >> /tmp/pre-gate-raw.txt

cp /tmp/pre-gate-raw.txt /home/benji/src/devnw/zig/thread-pool-wake-gate/docs/performance/wake-scan-gate/flood_1m-pre-n10.txt
```

- [ ] **Step 4: Measure POST-gate (branch) n=10 with freq logging**

```bash
cd /home/benji/src/devnw/zig/thread-pool-wake-gate
git rev-parse HEAD
rm -rf zig-out/ .zig-cache/
zig build -Doptimize=ReleaseFast

/tmp/freq-sample.sh /tmp/post-gate-freq.log &
SAMPLER_PID=$!
sleep 0.5

{
  echo "# POST-gate (branch) at $(git rev-parse --short HEAD) ($(date -Iseconds))"
  echo "# load at start:"; uptime
  for i in $(seq 1 10); do
    echo "--- run $i ---"
    timeout 60 ./zig-out/bin/thread-pool-tokio-parity flood_1m
  done
  echo "# load at end:"; uptime
} | tee /tmp/post-gate-raw.txt

kill $SAMPLER_PID 2>/dev/null
wait $SAMPLER_PID 2>/dev/null

grep 'scenario=flood_1m' /tmp/post-gate-raw.txt \
  | grep -Eo 'ops_per_sec=[0-9]+' | grep -Eo '[0-9]+' | sort -n | awk '
      {a[NR]=$1}
      END { if(NR%2)print"post median:",a[(NR+1)/2];else print"post median:",(a[NR/2]+a[NR/2+1])/2; print"post min:",a[1]; print"post max:",a[NR]; print"n:",NR }' \
  >> /tmp/post-gate-raw.txt

cp /tmp/post-gate-raw.txt docs/performance/wake-scan-gate/flood_1m-post-n10.txt
```

- [ ] **Step 5: Consolidate freq log**

```bash
{
  echo "# CPU frequency samples during paired measurement"
  echo "# PRE-gate:"
  awk 'BEGIN{min=999999999;max=0;sum=0;n=0} {n++; v=$2/1000; sum+=v; if(v<min)min=v; if(v>max)max=v} END{printf "pre: min=%dMHz max=%dMHz mean=%dMHz n=%d\n", min, max, sum/n, n}' /tmp/pre-gate-freq.log
  echo "# POST-gate:"
  awk 'BEGIN{min=999999999;max=0;sum=0;n=0} {n++; v=$2/1000; sum+=v; if(v<min)min=v; if(v>max)max=v} END{printf "post: min=%dMHz max=%dMHz mean=%dMHz n=%d\n", min, max, sum/n, n}' /tmp/post-gate-freq.log
} | tee docs/performance/wake-scan-gate/cpu-freq-log.txt
```

- [ ] **Step 6: Compute deltas and decide**

Let `pre = pre-gate median`, `post = post-gate median`.

- Relative delta = `(post - pre) / pre * 100`
- Absolute delta = `post - pre`

Decision thresholds (host-load-aware):

- **Delta ≥ +5%:** LIFT measurable. Proceed to Task 7 (100× stress) and merge.
- **Delta in [-2%, +5%]:** NULL. The gate didn't help on today's baseline. Check freq deltas — if post-gate freq was materially lower than pre-gate, noise confound. Document and consider re-measure at a cleaner host moment. Do NOT proceed to merge; instead write the SUMMARY and pause.
- **Delta < -2%:** REGRESSION. The gate made things worse (possible causes: parked_count cacheline false-sharing with Sync's other fields; release-barrier cost of fetchAdd inside park_mutex; unbalanced increment/decrement under some path). Do NOT merge; open triage.

- [ ] **Step 7: Write SUMMARY.md**

Create `docs/performance/wake-scan-gate/SUMMARY.md`. Fill all `<>` with real numbers.

```markdown
# Wake-Scan Parked-Count Gate — Close-Out

## Result

| Measurement | Median | Min | Max | n |
|---|---|---|---|---|
| PRE-gate (main `<pre-sha>`) | <pre>K | <>K | <>K | 10 |
| POST-gate (branch `<post-sha>`) | <post>K | <>K | <>K | 10 |

**Delta:** +<X>% relative, +<Y>K ops/s absolute.

**A/B ceiling reference:** +34.8% under load (re-profile Task 5, wake-scan REMOVED entirely). This plan keeps the scan for the non-fast-path case; capture target is partial.

**Capture fraction vs A/B ceiling:** <Z>%.

**Decision:** <SHIP / NULL / REGRESSION per Step 6 thresholds>.

## CPU frequency during measurement

- PRE-gate: min <>MHz / mean <>MHz / max <>MHz
- POST-gate: min <>MHz / mean <>MHz / max <>MHz

If means differ by > 10%, the comparison is noise-contaminated. Document.

## Stress

20/20 PASS at ReleaseFast (see `stress-20x.txt`). Correctness regression test `wake-gate: no lost wakeup under park/submit interleave` passes.

## Sub-changes

1. Add `Sync.parked_count` field (commit `<>`).
2. Worker maintenance in `idle()` (commit `<>`).
3. Submitter fast-exit in `enqueueTask` (commit `<>`).
4. Regression test (commit `<>`).
5. Stress log (commit `<>`).

## Host-load context

Session had co-tenant `geode` process (cannot kill, different user) + 4-day uptime drift. Pre/post measurements were back-to-back on the SAME host state to control for drift.

## Recommendation

<Based on Step 6 threshold decision:>
- SHIP: proceed to Task 7 (100× stress) and merge.
- NULL: pause; investigate or retry at cleaner host moment.
- REGRESSION: do not merge; open triage in `docs/PERFORMANCE_TRACKING.md` with suspected cause.
```

- [ ] **Step 8: Append to `docs/PERFORMANCE_TRACKING.md`**

```markdown

## Wake-Scan Parked-Count Gate (2026-04-13)

Orthogonal global `Sync.parked_count` atomic; submitter `.acquire`-loads it in `enqueueTask` and skips the 56-iteration `is_parked[]` scan when the count is 0 (common case under flood_1m saturation).

Sub-changes (branch `feat/wake-scan-parked-count-gate`):
1. Add `Sync.parked_count` field (commit `<>`).
2. Worker increment/decrement in `idle()` park/unpark paths (commit `<>`).
3. Submitter fast-exit in `enqueueTask` (commit `<>`).
4. Park/submit interleave regression test (commit `<>`).

Result: flood_1m <pre>K → <post>K (+<X>%), <Z>% of A/B ceiling (34.8%). Stress 20/20 PASS.

Full report: `docs/performance/wake-scan-gate/SUMMARY.md`.
```

- [ ] **Step 9: Commit**

```bash
cd /home/benji/src/devnw/zig/thread-pool-wake-gate
git add docs/performance/wake-scan-gate/ docs/PERFORMANCE_TRACKING.md
git commit -m "$(cat <<'EOF'
docs(wake-gate): close-out SUMMARY — paired measurement + capture fraction

See docs/performance/wake-scan-gate/SUMMARY.md for the full report.
EOF
)"
```

---

## Task 7: 100× pre-merge stress gate (conditional on SHIP)

**Run ONLY if Task 6's decision is SHIP.** Otherwise skip.

**Files:**
- Create: `docs/performance/wake-scan-gate/stress-100x.txt`

- [ ] **Step 1: Pre-flight**

```bash
uptime
```

If 1-min > 6, wait.

- [ ] **Step 2: 100× loop**

Pass `timeout: 3600000` to Bash:

```bash
{
  echo "# 100x pre-merge stress, branch $(git branch --show-current) at $(git rev-parse --short HEAD)"
  echo "# load at start:"; uptime
  pass=0; fail=0; first_fail=""
  for i in $(seq 1 100); do
    START=$(date +%s)
    if timeout 300 zig build test-stress -Doptimize=ReleaseFast > /tmp/wake-100-stress-$i.log 2>&1; then
      pass=$((pass+1))
      [ $((i % 10)) -eq 0 ] && echo "run $i: PASS ($(($(date +%s) - $START))s); pass=$pass fail=$fail"
    else
      fail=$((fail+1))
      if [ -z "$first_fail" ]; then
        first_fail=$i
        echo "run $i: FIRST FAIL ($(($(date +%s) - $START))s)"
        tail -5 /tmp/wake-100-stress-$i.log
      fi
    fi
  done
  echo "=== SUMMARY: pass=$pass fail=$fail (first_fail=$first_fail) ==="
  echo "# load at end:"; uptime
} | tee docs/performance/wake-scan-gate/stress-100x.txt
```

Expected: `pass=100 fail=0`.

- [ ] **Step 3: Commit**

```bash
git add docs/performance/wake-scan-gate/stress-100x.txt
git commit -m "test(wake-gate): 100x ReleaseFast pre-merge stress validation"
```

---

## Task 8: Merge to main (conditional on SHIP + 100× PASS)

- [ ] **Step 1: Verify state**

```bash
git status
git log --oneline main..HEAD
```

- [ ] **Step 2: Fast-forward merge**

```bash
cd /home/benji/src/devnw/zig/thread-pool  # primary, on main
git merge --ff-only feat/wake-scan-parked-count-gate
git log --oneline -8
```

- [ ] **Step 3: Remove worktree + branch**

```bash
git worktree remove /home/benji/src/devnw/zig/thread-pool-wake-gate
git branch -d feat/wake-scan-parked-count-gate
git worktree list
```

- [ ] **Step 4: Update memory**

Edit `~/.claude/projects/-home-benji-src-devnw-zig-thread-pool/memory/project_phase_status.md`:
- Add "Wake-Scan Parked-Count Gate" to Shipped section with merge SHA + measured lift.
- Remove from "Next-action priority" or mark done.

---

## Done criteria

- [ ] Branch `feat/wake-scan-parked-count-gate` merged (if SHIP) OR documented null (if NULL) OR triaged (if REGRESSION).
- [ ] `docs/performance/wake-scan-gate/SUMMARY.md` exists on main with real numbers.
- [ ] `docs/PERFORMANCE_TRACKING.md` has a `§ Wake-Scan Parked-Count Gate` section.
- [ ] Stress 20× PASS; 100× PASS on merge tip (SHIP path only).
- [ ] `wake-gate: no lost wakeup under park/submit interleave` test PASSES.
- [ ] `memory/project_phase_status.md` reflects the outcome.

## Non-goals (explicitly out of scope)

- Sharding `parked_count` per-NUMA. Deferred to a follow-up if single-counter contention becomes the next bound.
- Redesigning the park/unpark mechanism (e.g., event-driven waiter list). Separate plan.
- Touching `counters.submitted` further. G3's full attempt showed null; re-profile now recommends wake-scan as priority 2.
- Descriptor CAS. Re-profile DEPRIORITIZED this.
- Architectural pivots (Chase-Lev is done; event-wake is done; lock-free inject is a separate plan if contended_spawn_8x becomes bound).

## Rollback plan

If Task 5 stress fails or Task 6 shows REGRESSION:
1. Bisect the three sub-change commits with `git bisect start` / `bisect good main` / `bisect bad HEAD`.
2. Task 1 (field addition) should be safe alone; Task 2 (worker maintenance) is the most likely source of timing changes; Task 3 (submitter gate) is the optimization itself.
3. If Task 3 regresses, investigate: is `parked_count` cacheline-shared with another hot atomic? Consider padding.
4. If Task 2 regresses, investigate: is the fetchAdd inside `park_mutex` creating new contention? Consider moving it outside the mutex (but preserve the release barrier relative to `is_parked.store`).
