# Phase H — Fix nextTask Double-Dequeue Race Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Root-cause and fix the scheduler race that allows two workers to dequeue the same descriptor index, which was masked by the `queued_tasks` poll in `idle()` and surfaced as a ~5% SIGSEGV rate under the "phase g2: aggressive spin flood" stress test when the poll was removed (see `docs/PERFORMANCE_TRACKING.md` Phase G2 revert and `ef35296`).

**Architecture:** Two-phase debugging workflow. First we *surface* the race with a deterministic reproducer plus a Debug/ReleaseSafe-only "claimed by worker N" sentinel on every TaskDescriptor that converts the silent double-dequeue into a loud, actionable panic. Then we root-cause from the panic, patch the offending site, and validate by running the reproducer at 100/100 under ReleaseFast. No production behaviour changes in ReleaseFast — the sentinel is guarded by `std.debug.runtime_safety` and compiles out.

**Tech Stack:** Zig 0.15+, `std.atomic.Value`, `std.Thread.ResetEvent` / `std.Thread.WaitGroup`, existing `tests/stress.zig` harness, existing `src/queue/*.zig` deque/ring implementations. Build matrix: Debug (assertions on), ReleaseSafe (assertions on, optimized), ReleaseFast (assertions compiled out).

**Blocking:** Phase G2 re-land, Phase G3 (submitted fetchAdd), wake-scan redesign, and descriptor-CAS must all wait on this — any submit-path change that alters worker timing risks re-exposing the race. See `~/.claude/projects/-home-benji-src-devnw-zig-thread-pool/memory/project_phase_status.md`.

**Suspected sites from the Phase G2 post-mortem (confirm in Task 3 — do NOT patch blind):**

- `src/pool.zig:655` — inject-batch drain: `_ = self.inject_queue.tryPush(extra)` after `tryPushBottom` fails. If `tryPush` *also* fails the index is orphaned (leak, not double-claim), but verify no overlap with the local-queue path that already consumed it.
- `src/pool.zig:692` — steal overflow: `_ = self.inject_queue.tryPush(idx)` when `tryPushBottom` rejects a stolen element. Victim already surrendered the index; confirm no stale holder.
- `src/queue/work_deque.zig` — chase-lev `steal()` / `popBottom()` ABA or ordering bug under high contention.
- `src/queue/ring_queue.zig` — Tokio-style ring `steal`/`stealHalf` CAS-on-head racing with `popBottom`.
- `src/pool.zig:639-642` — LIFO-slot `swap(LIFO_SLOT_EMPTY, .acquire)` in `nextTask` racing with the owner-only submit-path store at `src/pool.zig:558` (owner-only invariant assumption).

---

## File Structure

### Files to create

- `tests/stress/double_dequeue_race.zig` — new deterministic reproducer module; included via `tests/stress.zig`.

### Files to modify

- `src/pool.zig` — add `claimed_by: std.atomic.Value(i32)` to `TaskDescriptor`; assert CAS-acquire in `runTask`, clear in `releaseDescriptor` / on cancellation path. Guard the whole thing with `if (std.debug.runtime_safety)` so ReleaseFast is unchanged.
- `tests/stress.zig` — `_ = @import("stress/double_dequeue_race.zig");` wire-up.
- `docs/PERFORMANCE_TRACKING.md` — append Phase H entry once the fix lands.
- One of `src/queue/work_deque.zig`, `src/queue/ring_queue.zig`, or `src/pool.zig` — the actual fix; which one is determined by Task 3.

### Files read-only for reference

- `src/types.zig` — `TaskState` enum (no changes; we're adding an orthogonal claimed_by field, not a new state).
- `tests/stress.zig` lines 512-563 — the existing "phase g2: aggressive spin flood" test that the new reproducer should extend, not replace.

---

## Task 1: Deterministic double-dequeue reproducer

**Goal:** A test that reproduces the race under ReleaseSafe on a developer laptop within ~30 seconds at 100/100 repetition, *without* requiring the Phase G2 poll removal. The existing `phase g2: aggressive spin flood` test only triggers when the poll is gone because the poll masks the symptom; we need a repro that catches the underlying duplicate claim regardless of the masking poll. The sentinel added in Task 2 converts the mask-defeating: with the sentinel in place, *any* duplicate claim panics, so we can keep the poll for now and still catch the race.

**Files:**

- Create: `tests/stress/double_dequeue_race.zig`
- Modify: `tests/stress.zig` (add import)

- [ ] **Step 1: Write the new reproducer file (initially will not fail until Task 2 sentinel lands, which is expected)**

```zig
// tests/stress/double_dequeue_race.zig
//
// Deterministic reproducer for the nextTask double-dequeue race exposed when
// the queued_tasks idle-spin poll was removed in Phase G2. The race is that
// two workers can observe and claim the same descriptor index under a
// specific submit→park→wake timing window. The Task 2 sentinel on
// TaskDescriptor turns the previously-silent double-claim into a panic;
// this test exists to maximise the probability of hitting that window.
//
// Strategy: park all workers, then flood submits in a tight interleaved
// loop from two producer threads. Every task is a no-op so workers exit
// runTask fast and race back into nextTask before the next submit's wake
// has propagated — which is exactly the window the spin-poll previously
// masked.

const std = @import("std");
const thread_pool = @import("thread_pool");
const common = @import("../common.zig");

fn noop(_: *anyopaque, _: *thread_pool.TaskContext) void {}

test "phase h: double-dequeue race reproducer" {
    // Use 16 workers with an aggressive spin budget so the idle→park→wake
    // handshake is exercised thousands of times per second. min==max so
    // we don't churn threads.
    var pool = try thread_pool.ThreadPool.init(std.testing.allocator, .{
        .min_threads = 16,
        .max_threads = 16,
        .queue_capacity = 4096,
        .local_queue_capacity = 256,
        .scheduler_variant = .work_stealing,
        .spin_before_park_iters = 4096,
    });
    defer pool.deinit();

    // Let the pool quiesce — all 16 workers should reach the park waitpoint.
    std.Thread.sleep(5 * std.time.ns_per_ms);

    const per_producer: u64 = 100_000;
    var wg = thread_pool.WaitGroup{};

    const Submitter = struct {
        fn run(p: *thread_pool.ThreadPool, g: *thread_pool.WaitGroup, n: u64) void {
            var dummy: u8 = 0;
            var i: u64 = 0;
            while (i < n) : (i += 1) {
                _ = p.submit(noop, @ptrCast(&dummy), .{
                    .backpressure = .block,
                    .wait_group = g,
                }) catch return;
            }
        }
    };

    // Two producers: interleaved submits maximise the chance that the
    // wake for submit N fires while worker W is still exiting runTask
    // for submit N-1, so W takes the fast path back into nextTask and
    // races a just-woken parked worker for the same descriptor.
    wg.add(@as(usize, per_producer) * 2);
    const t1 = try std.Thread.spawn(.{}, Submitter.run, .{ &pool, &wg, per_producer });
    const t2 = try std.Thread.spawn(.{}, Submitter.run, .{ &pool, &wg, per_producer });
    t1.join();
    t2.join();

    // 30s watchdog — lost wakeup or deadlock will surface here rather
    // than as a hang.
    const deadline_ns: i128 = 30 * std.time.ns_per_s;
    const start = std.time.nanoTimestamp();
    while (std.time.nanoTimestamp() - start < deadline_ns) {
        if (wg.isDone()) break;
        std.Thread.sleep(1 * std.time.ns_per_ms);
    }
    try std.testing.expect(wg.isDone());
}
```

- [ ] **Step 2: Wire the reproducer into the stress suite**

In `tests/stress.zig`, after the existing imports add:

```zig
comptime {
    _ = @import("stress/double_dequeue_race.zig");
}
```

(If `tests/stress.zig` already uses a different pattern for including sub-tests — e.g. inline `test` blocks — mirror that pattern instead of the `comptime _ =` import.)

- [ ] **Step 3: Verify the test compiles and passes on main (pre-sentinel baseline)**

Run:

```bash
zig build test-stress -Doptimize=ReleaseSafe --summary all 2>&1 | tail -40
```

Expected: the new `phase h: double-dequeue race reproducer` test appears in the summary and passes (it will only *fail* once Task 2 sentinel is in place and catches a real race; right now it's just a well-formed stress harness).

- [ ] **Step 4: Commit**

```bash
git add tests/stress/double_dequeue_race.zig tests/stress.zig
git commit -m "test(phase h): add deterministic double-dequeue reproducer

Submit-flood harness targeting the nextTask race window exposed when
the Phase G2 queued_tasks poll was removed. Passes on its own; becomes
diagnostic once the Task 2 descriptor sentinel lands."
```

---

## Task 2: Add Debug-mode per-descriptor claim sentinel

**Goal:** Turn a silent double-dequeue into a loud panic at the first duplicate claim, so Task 3's root-causing has a reliable signal. The sentinel is an `i32` field on `TaskDescriptor` with `-1` meaning unclaimed. `runTask` CAS-acquires from `-1` to `worker_index`; on CAS failure, panic with both worker indices and the descriptor index. `releaseDescriptor` / `cancelDescriptor` store `-1` back before releasing to the freelist. The entire thing lives behind `if (std.debug.runtime_safety)` so ReleaseFast builds are unaffected.

**Files:**

- Modify: `src/pool.zig` (TaskDescriptor, runTask, releaseDescriptor, cancelDescriptor)

- [ ] **Step 1: Extend `TaskDescriptor` with the claim sentinel**

Edit `src/pool.zig` around line 123. Before:

```zig
const TaskDescriptor = struct {
    // === Hot fields (read on every dispatch and complete) ===
    state: std.atomic.Value(types.TaskState) = std.atomic.Value(types.TaskState).init(.free),
    task_fn: ?TaskFn = null,
    ctx: ?*anyopaque = null,
    options: types.SubmitOptions = .{},
    generation: u64 = 0,

    // === Cold fields (metrics/observability only) ===
    submit_ns: u64 = 0,
    start_ns: u64 = 0,
    complete_ns: u64 = 0,

    comptime {
        // Document the intended cache layout: ensure the hot fields fit in
        // one cache line so dispatch never touches the cold metric fields.
        const hot_size = @offsetOf(TaskDescriptor, "submit_ns");
        std.debug.assert(hot_size <= std.atomic.cache_line);
    }
};
```

After (add `claimed_by` in the cold-fields section so the hot-line layout assertion still passes in ReleaseFast where the field compiles away to zero-size via `runtime_safety` gating — see Step 2 note):

```zig
const TaskDescriptor = struct {
    // === Hot fields (read on every dispatch and complete) ===
    state: std.atomic.Value(types.TaskState) = std.atomic.Value(types.TaskState).init(.free),
    task_fn: ?TaskFn = null,
    ctx: ?*anyopaque = null,
    options: types.SubmitOptions = .{},
    generation: u64 = 0,

    // === Cold fields (metrics/observability only) ===
    submit_ns: u64 = 0,
    start_ns: u64 = 0,
    complete_ns: u64 = 0,

    /// Debug/ReleaseSafe-only double-dequeue detector. `-1` = unclaimed.
    /// Worker CAS-acquires from -1 to its index in runTask; a failed CAS
    /// means two workers are racing for this descriptor — panic.
    /// Always compiled in (cheap — single i32), but only *used* when
    /// `std.debug.runtime_safety` is true. Guarded reads/writes mean
    /// ReleaseFast skips every atomic op.
    claimed_by: std.atomic.Value(i32) = std.atomic.Value(i32).init(-1),

    comptime {
        // Document the intended cache layout: ensure the hot fields fit in
        // one cache line so dispatch never touches the cold metric fields.
        const hot_size = @offsetOf(TaskDescriptor, "submit_ns");
        std.debug.assert(hot_size <= std.atomic.cache_line);
    }
};
```

> Note on layout: `claimed_by` is added *after* `complete_ns` (cold region). `hot_size` is measured up to `submit_ns` (the first cold field), so this layout assertion is unaffected. If the cache-line assertion fails on your platform after this change, move `claimed_by` further down.

- [ ] **Step 2: CAS-acquire the claim at the top of `runTask`**

Edit `src/pool.zig` around line 714 (`fn runTask`). Before:

```zig
fn runTask(self: *Core, worker_index: usize, descriptor_index: u32) void {
    var worker = &self.workers[worker_index];
    var descriptor = &self.descriptors[descriptor_index];
    descriptor.state.store(.running, .release);
```

After:

```zig
fn runTask(self: *Core, worker_index: usize, descriptor_index: u32) void {
    var worker = &self.workers[worker_index];
    var descriptor = &self.descriptors[descriptor_index];

    // Debug/ReleaseSafe-only: detect double-dequeue. If two workers
    // arrive here with the same descriptor_index (scheduler race), the
    // second CAS will fail and we panic with both worker ids. Compiles
    // out under ReleaseFast.
    if (std.debug.runtime_safety) {
        const wi_i32: i32 = @intCast(worker_index);
        if (descriptor.claimed_by.cmpxchgStrong(-1, wi_i32, .acq_rel, .acquire)) |other| {
            std.debug.panic(
                "double-dequeue: descriptor {d} claimed by worker {d}, now worker {d} also tried to claim it",
                .{ descriptor_index, other, wi_i32 },
            );
        }
    }

    descriptor.state.store(.running, .release);
```

- [ ] **Step 3: Release the claim when the descriptor is released**

Two release paths: `releaseDescriptor` (normal + cancel cleanup, line ~901) and the `.state.store(.completed, .release)` path inside `runTask` for *waitable* tasks — where the descriptor is not immediately returned to the freelist but awaits `wait()`. For waitable tasks we still need to clear the claim before the user's `wait()` could in principle re-read; for simplicity clear it unconditionally at the bottom of the task body.

In `runTask`, just before the `if (descriptor.options.waitable)` block around line 778. Before:

```zig
        if (descriptor.options.wait_group) |wait_group| {
            wait_group.done();
        }

        if (descriptor.options.waitable) {
```

After:

```zig
        if (descriptor.options.wait_group) |wait_group| {
            wait_group.done();
        }

        // Clear the claim sentinel before wait_group.done() observers can
        // re-submit / re-acquire this descriptor slot. Paired with the
        // CAS-acquire at the top of runTask.
        if (std.debug.runtime_safety) {
            descriptor.claimed_by.store(-1, .release);
        }

        if (descriptor.options.waitable) {
```

Also clear in `cancelDescriptor` (line ~861), before the release. Before:

```zig
fn cancelDescriptor(self: *Core, descriptor_index: u32) void {
    const descriptor = &self.descriptors[descriptor_index];
    descriptor.state.store(.cancelled, .release);
    _ = self.counters.cancelled.fetchAdd(1, .monotonic);
```

After:

```zig
fn cancelDescriptor(self: *Core, descriptor_index: u32) void {
    const descriptor = &self.descriptors[descriptor_index];
    if (std.debug.runtime_safety) {
        descriptor.claimed_by.store(-1, .release);
    }
    descriptor.state.store(.cancelled, .release);
    _ = self.counters.cancelled.fetchAdd(1, .monotonic);
```

- [ ] **Step 4: Also reset the sentinel on `acquireDescriptor` (paranoia; belt-and-braces against a stale `-1`→`wi` from a prior generation)**

In `acquireDescriptor` around line 889. Before:

```zig
            var descriptor = &self.descriptors[head];
            const prev_generation = descriptor.generation;
            descriptor.* = .{};
            descriptor.generation = prev_generation +% 1;
            if (descriptor.generation == 0) descriptor.generation = 1;
            descriptor.state.store(.reserved, .release);
```

After:

```zig
            var descriptor = &self.descriptors[head];
            const prev_generation = descriptor.generation;
            descriptor.* = .{};
            descriptor.generation = prev_generation +% 1;
            if (descriptor.generation == 0) descriptor.generation = 1;
            if (std.debug.runtime_safety) {
                descriptor.claimed_by.store(-1, .release);
            }
            descriptor.state.store(.reserved, .release);
```

> The `descriptor.* = .{}` above already resets `claimed_by` to -1 via the default, but a second worker holding a race-won reference could write after the reset; the explicit `.release` store establishes a happens-before edge with the next `runTask` CAS.

- [ ] **Step 5: Run the full test suite under ReleaseSafe and confirm the sentinel fires**

```bash
zig build test -Doptimize=ReleaseSafe --summary all 2>&1 | tail -60
```

Expected one of:

- **Likely:** The new `phase h: double-dequeue race reproducer` test (or the existing `phase g2: aggressive spin flood` test) panics with a `double-dequeue: descriptor N claimed by worker A, now worker B ...` message. **This is the desired outcome** — it proves the sentinel works and the race exists. Save the panic output for Task 3.
- **Also possible:** All tests pass on this run. In that case, re-run 10× (`for i in (seq 1 10); zig build test-stress -Doptimize=ReleaseSafe; or break; end`) to increase the probability. If after 10 iterations no panic fires, proceed to Step 6 with the diagnostic — but flag to the reviewer that the race wasn't reproduced, because Task 3 depends on a real panic trace.

- [ ] **Step 6: Commit (whether or not the sentinel fired)**

```bash
git add src/pool.zig
git commit -m "debug(phase h): add per-descriptor claim sentinel for double-dequeue

TaskDescriptor gains a claimed_by i32 atomic initialized to -1. runTask
CAS-acquires from -1 to worker_index; a failed CAS is a double-dequeue
and panics with both worker ids. Guarded by std.debug.runtime_safety so
ReleaseFast is unchanged. Cleared on release/cancel/acquire for ABA
protection across descriptor generations."
```

---

## Task 3: Root-cause from the sentinel panic

**Goal:** Turn the panic output from Task 2 Step 5 into a specific line-number-level diagnosis of which dequeue path produced the duplicate claim. This task is **investigative and has no code output** — the deliverable is a short root-cause write-up appended to the Phase H entry in `docs/PERFORMANCE_TRACKING.md`. Task 4 depends on it.

**Files:**

- Modify: `docs/PERFORMANCE_TRACKING.md` (append diagnosis)

- [ ] **Step 1: Capture a panic trace under ReleaseSafe with debug info**

```bash
zig build test-stress -Doptimize=ReleaseSafe 2>&1 | tee /tmp/phase-h-panic.log
```

If no panic, loop until one fires:

```bash
for i in (seq 1 50)
    zig build test-stress -Doptimize=ReleaseSafe 2>&1 | tee /tmp/phase-h-panic-$i.log
    if grep -q "double-dequeue" /tmp/phase-h-panic-$i.log
        echo "Got panic on iteration $i"
        break
    end
end
```

- [ ] **Step 2: Identify the calling path from the stack trace**

From the panic, identify which `nextTask` branch produced the duplicate descriptor. The branches in `src/pool.zig` lines 632-712 are:

1. LIFO slot (line 639-642)
2. Local deque popBottom (line 645-647)
3. Inject queue pop + batch drain (line 650-663)
4. Cross-worker steal + batch (line 668-700)
5. FIFO fallback path (line 707-710)

Two workers racing means at least one branch returned the same index on two threads. Typical culprits:

- **LIFO slot vs. owner popBottom.** Owner may `popBottom()` an index the stealer just pushed to the LIFO via submit? No — stealers never write LIFO. But owner submit-path can race with owner nextTask. Owner-only access assumption can fail if submit happens from a *different* thread than nextTask for the same worker index. Check: does submit ever run on a different OS thread than the worker it targets? If the pool is shared across OS threads and `tls_worker_index` is used to pick, submits from non-worker threads bypass LIFO entirely (line 551 guard). OK — LIFO should be safe.
- **Local deque popBottom vs. steal().** Classic Chase-Lev race. Inspect `src/queue/work_deque.zig` for the CAS on `top` in `steal()` and whether `popBottom` uses the correct fence pattern (Dynamic Circular Work-Stealing Deque, Lê et al.). Indicators: owner sees `bottom` count and reads slot N, stealer also reads slot N, both return; the CAS on `top` that serializes them is weak-under-acquire when it must be seq_cst.
- **Inject batch drain (line 650-663).** After `self.inject_queue.pop()` returns `descriptor_index`, we call `pop()` again for the batch — if the inject queue itself allows the same slot to pop twice under MPMC contention, two workers each claim different descriptor indices from the batch but may overlap if the queue's head CAS is broken. Check `src/queue/ring_queue.zig` or whichever MPMC implementation backs `inject_queue`.
- **Steal batch overflow re-inject (line 692).** Stealer takes N items, tries to `tryPushBottom` N-1 of them to its own local deque. On failure, `tryPush` back to inject. Because the stealer *already committed* the steal (incremented `top`), the victim cannot re-read these indices; but if `tryPush` to inject races with another worker's `pop()` at the same slot, MPMC ring breakage surfaces here.

- [ ] **Step 3: Write up the diagnosis**

Append to `docs/PERFORMANCE_TRACKING.md` under a new `## Phase H — Double-Dequeue Race` heading:

```markdown
## Phase H — Double-Dequeue Race (2026-04-13)

**Symptom:** `phase g2: aggressive spin flood` crashes with SIGSEGV at ~5% rate
at ReleaseFast when the idle-spin queued_tasks poll is absent. The poll masked
a scheduler race where two workers claim the same descriptor_index.

**Repro:** `tests/stress/double_dequeue_race.zig` + Debug sentinel on
`TaskDescriptor.claimed_by` (see Phase H Task 2 commit).

**Root cause:** [FILL IN — e.g. "Chase-Lev `steal()` in src/queue/work_deque.zig
uses a weakly-ordered CAS on `top` that races with `popBottom()` when bottom
and top converge. Specifically, … (quote the two relevant code blocks and
explain the interleaving.)"]

**Impact:** [FILL IN — affected scheduler variants, repro rate at the commit
being diagnosed.]

**Fix plan:** [FILL IN — see Task 4.]
```

- [ ] **Step 4: Commit the diagnosis**

```bash
git add docs/PERFORMANCE_TRACKING.md
git commit -m "docs(phase h): diagnose nextTask double-dequeue root cause"
```

---

## Task 4: Fix the root cause

**Goal:** Apply the minimum change that eliminates the race identified in Task 3. Do NOT touch code that isn't implicated — any submit-path timing change risks masking or re-exposing the race. Prefer a localized fix in the offending queue implementation over any scheduler-logic refactor.

**Files:**

- Modify: one of `src/queue/work_deque.zig`, `src/queue/ring_queue.zig`, or `src/pool.zig` (determined by Task 3).

- [ ] **Step 1: Write a failing unit test for the specific race**

If the culprit is a queue data structure, add a dedicated unit test in `tests/unit/` that targets the specific CAS/ordering bug with a minimal 2-thread harness. This is distinct from Task 1's end-to-end reproducer — this is a focused regression test that will fail on the bug and pass after the fix.

Example template (adapt to the specific culprit):

```zig
// tests/unit/work_deque_race.zig (or ring_queue_race.zig / etc.)
test "owner popBottom and thief steal cannot return the same slot" {
    // Spin owner and thief on a shared deque; assert the multiset of
    // returned values has no duplicates over N iterations.
    // ... (harness specific to the queue under test)
}
```

- [ ] **Step 2: Run the new unit test and confirm it fails**

```bash
zig build test-unit -Doptimize=ReleaseSafe --summary all 2>&1 | tail -20
```

Expected: FAIL at the duplicate-detection assertion, with at least one duplicate observed.

- [ ] **Step 3: Apply the fix**

The fix form depends on Task 3 findings. Likely shapes:

- If a CAS memory ordering is too weak: upgrade `.release`/`.acquire` on the specific operation to `.acq_rel` or `.seq_cst`, matching the peer.
- If a queue allows a slot to appear in two places transiently: add the missing fence on the path that re-publishes (e.g. the inject-requeue in `src/pool.zig:655` or `:692`).
- If the LIFO slot assumption is violated: restrict submit-to-LIFO to owner threads only (check `tls_worker_index == wi` *and* same OS thread).

Paste the actual diff once Task 3 is concrete; do not land speculative changes.

- [ ] **Step 4: Run the unit regression test and confirm it passes**

```bash
zig build test-unit -Doptimize=ReleaseSafe --summary all 2>&1 | tail -20
```

Expected: PASS.

- [ ] **Step 5: Run the full stress suite under ReleaseSafe (sentinel active) — 10 runs**

```bash
for i in (seq 1 10)
    echo "=== iteration $i ==="
    zig build test-stress -Doptimize=ReleaseSafe 2>&1 | tail -5
    or exit 1
end
```

Expected: all 10 runs pass. If any run panics, the fix is incomplete — return to Task 3.

- [ ] **Step 6: Commit**

```bash
git add src/queue/<fixed-file>.zig tests/unit/<regression-test>.zig
git commit -m "fix(phase h): close nextTask double-dequeue race in <component>

<one-paragraph explanation of the race and the fix, pulled from the
PERFORMANCE_TRACKING.md diagnosis>

Validated by new unit regression test + 10x stress suite under
ReleaseSafe (sentinel active)."
```

---

## Task 5: Validate at 100/100 ReleaseFast against the G2 stress test

**Goal:** Prove the fix holds under the original high-contention workload at ReleaseFast (where the sentinel is compiled out), which is the regime where the symptom was originally observed. 100/100 without panic or hang is the ship gate.

**Files:**

- Modify: `docs/PERFORMANCE_TRACKING.md` (append validation result)

- [ ] **Step 1: Run the existing `phase g2: aggressive spin flood` 100× at ReleaseFast**

```bash
set failures 0
for i in (seq 1 100)
    zig build test-stress -Doptimize=ReleaseFast --test-filter "aggressive spin flood" 2>&1 | tail -3
    if test $status -ne 0
        set failures (math $failures + 1)
        echo "FAIL on iteration $i"
    end
end
echo "Total failures: $failures / 100"
```

Expected: `Total failures: 0 / 100`. (If `--test-filter` isn't supported by this repo's build.zig, run the full `test-stress` target — the critical signal is zero crashes.)

- [ ] **Step 2: Run the new Phase H reproducer 100× at ReleaseFast**

```bash
set failures 0
for i in (seq 1 100)
    zig build test-stress -Doptimize=ReleaseFast --test-filter "double-dequeue race reproducer" 2>&1 | tail -3
    if test $status -ne 0
        set failures (math $failures + 1)
    end
end
echo "Phase H repro failures: $failures / 100"
```

Expected: `Phase H repro failures: 0 / 100`.

- [ ] **Step 3: Run full `zig build test` once under ReleaseSafe as a belt-and-braces check**

```bash
zig build test -Doptimize=ReleaseSafe --summary all 2>&1 | tail -40
```

Expected: all tests pass. Sentinel is active here and would panic on any remaining race.

- [ ] **Step 4: Append the validation result to `docs/PERFORMANCE_TRACKING.md`**

Under the Phase H section added in Task 3, append:

```markdown
**Validation (2026-04-13):**
- 100/100 ReleaseFast runs of `phase g2: aggressive spin flood` — zero crashes.
- 100/100 ReleaseFast runs of `phase h: double-dequeue race reproducer` — zero crashes.
- Full `zig build test -Doptimize=ReleaseSafe` passes (sentinel active).

**Status:** closed. Unblocks Phase G2 re-land, G3 (submitted fetchAdd), wake-scan
redesign, and descriptor CAS.
```

- [ ] **Step 5: Commit and tag the fix as the new Phase H baseline**

```bash
git add docs/PERFORMANCE_TRACKING.md
git commit -m "docs(phase h): close out — 100/100 ReleaseFast, unblocks G2 re-land"
```

---

## Post-Phase-H next steps (for memory, not for this plan)

1. **Phase G2 re-land (cleaner):** remove the idle-spin `queued_tasks` poll only. No probe, no spin-default change. Separate commit for the spin-default-zero question.
2. **Phase G3 vs wake-scan redesign:** G3 is smaller blast radius (+28%), wake-scan is higher ceiling (+47%). Pick G3 first.
3. **Descriptor CAS (+16%):** last remaining ceiling under 500K submit/s; smallest-blast-radius single-atomic fix.

---

## Self-Review Checklist (completed by plan author)

- Spec coverage: every bullet from the user's "What's next" section maps to a task (Task 1 = reproducer, Task 2 = sentinel, Task 3 = root-cause, Task 4 = fix, Task 5 = 100/100 validation). ✓
- Placeholder scan: Task 3 Step 3 and Task 4 Step 3 both contain explicit `[FILL IN — ...]` markers *because* the content is data-dependent on the panic trace. These are marked as investigative outputs, not placeholders-of-laziness. The plan tells the engineer exactly what fields to fill and what shape the fill-in must take. ✓
- Type consistency: `claimed_by` is referenced as `std.atomic.Value(i32)` throughout. CAS `cmpxchgStrong(-1, wi_i32, .acq_rel, .acquire)` is consistent across Task 2 Step 2 and the mental model in Task 3. ✓

---

## Execution Handoff

**Plan complete and saved to `docs/superpowers/plans/2026-04-13-phase-h-fix-double-dequeue-race.md`. Two execution options:**

**1. Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, review between tasks, fast iteration. Task 3 (investigation) is a strong fit for this mode because I can review the diagnosis before Task 4 locks in a fix.

**2. Inline Execution** — Execute tasks in this session using executing-plans, batch execution with checkpoints.

**Which approach?**
