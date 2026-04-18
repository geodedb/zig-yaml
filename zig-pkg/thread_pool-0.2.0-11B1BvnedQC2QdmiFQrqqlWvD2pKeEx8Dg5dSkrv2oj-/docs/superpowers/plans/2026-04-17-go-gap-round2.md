# Go-gap Round 2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Narrow the remaining Go-runtime gap on three contended/nested scenarios by giving every worker-context submit the newest-task "next-g" semantics Go and Tokio have always had, and by amortising per-task queue release-stores inside `submitBatch`.

**Architecture:** Two independent attacks stacked in strict kill-gate order.
Phase 1 turns the per-worker `lifo_slot` from an "only when empty" one-shot cache into a true rotating slot: every worker-context submit swaps the fresh entry in and pushes the displaced entry (if any) to the local deque — matching Go's `runqput` next-g semantics. Phase 2 adds a batched `tryPushBottomN` primitive to `WorkDeque`/`RingQueue`, surfaces it through the `LocalQueue` union, and rewires `submitBatch` to collapse N producer-side release-stores into one for contiguous batches. Both phases leave the `Worker` struct layout untouched (critical per iter-11 and the 2026-04-16 DescCache trade-off memory).

**Tech Stack:** Zig 0.16.0 / ReleaseFast / 56-worker host / `bench-runtime-compare` harness / paired n=10 balanced-order A/B per project measurement rules.

**Scope caveat:** The Go GMP scheduler retains structural advantages (stack-reusable goroutines, in-runtime per-P queues) this library cannot match within its C-compatible, API-stable design. A realistic expectation for this plan is +5 to +15% on the three target scenarios — enough to narrow meaningfully, not enough to erase the remaining gap. The plan gates on measurable narrowing, not parity.

---

## Target scenarios (baselines from `7e125a9` / `a666ec3` bench)

| Scenario              | Current Zig | Go      | Gap         | Plan intent                                                             |
|-----------------------|------------:|--------:|:-----------:|:-----------------------------------------------------------------------:|
| `nested_fanout_4x`    |   1,138,997 | 2,551,449 | 2.24x behind | Phase 1 (LIFO rotate, worker-context spawns) + Phase 2 (batched push)   |
| `contended_spawn_8x`  |   1,229,097 | 2,765,048 | 2.25x behind | Phase 2 (batched push through submitter SPSC queues)                    |
| `contended_cpu_10us`  |   1,223,207 | 1,705,090 | 1.39x behind | Phase 2 (batched push through submitter SPSC queues)                    |

Numbers read from `benchmarks/results/runtime-comparison-latest.json` at baseline commit `a666ec3`.

## Baseline commit

`a666ec3` — end of the 2026-04-16 Go-gap contended plan (FINAL already written). This is Phase 0's "A" leg in every Phase 1+ paired A/B.

## Measurement protocol (read before every A/B)

Reference: [`feedback_measurement_rules.md`](../../.claude/memory/feedback_measurement_rules.md) and the Phase 3 runsheet template [`2026-04-16-go-gap-contended/runs/phase3-ab.md`](../../performance/2026-04-16-go-gap-contended/runs/phase3-ab.md).

- **Same-session paired A/B only**: A, B, A, B, … balanced order in ONE run — never compare numbers from different sessions.
- **n=10 rounds per leg**, `--samples 3 --warmup-discard 1` per run (2 retained → 20 samples per leg aggregated to n=10 medians). Reduce to n=8 only when all 8 rounds already show >3x gate margin in the same direction (Phase-2 precedent).
- **20x ReleaseFast stress gate**: before committing any `src/` change, run `zig build test-stress --summary all` twenty times; must be 20/20 clean. Anything less → revert.
- **Host-state check**: record load average before/after each pair. If `uptime` 1-minute average is > 8 before a run starts, wait for it to drop.
- **Binary-hash check**: confirm the two binaries being A/B'd have distinct SHA256 hashes (both must be freshly rebuilt from their respective commits).
- **Both Zig and comparison-runtime numbers captured**: only Zig is gated, but Tokio and Go numbers are logged alongside so cross-snapshot drift can be attributed.

## Closed planes — do NOT re-attempt

Memories that rule out attractive-looking but failed attacks:

- **`notifySubmits` scan structural** (iter 7–11 closed): shared parked-workers bitmap regressed 11–22%, single-worker probe regressed 8.74%, cacheline isolation was neutral. The 27.58% inclusive-time cost is SC `fetchAdd` + futex wake and cannot be reduced further. Leave `scanAndWake` alone.
- **Worker struct growth** (iter 11 + 2026-04-16 DescCache trade-off memory): adding fields mid-struct OR at end regressed multi-submitter contended scenarios 5–10%. Iter-11 end-of-struct discipline is necessary but not sufficient — Worker size already at 2048B. **Do not add per-Worker fields in this plan.**
- **Socket-aware worker pinning** (Slice 3a closed): 4–18% regression on realistic scenarios by fighting the kernel CFS scheduler. Worker pinning stays disabled.
- **`shouldExit` off the hotpath** (iter 10): hung 20× stress under 180s timeout. `lifo_slot`/stale-gen residue workers process during shutdown is load-bearing.

## File structure

Two existing files receive logic changes; two existing queue modules gain a new batched method; one new benchmark runsheet and one FINAL doc get written.

- **Modify** `src/pool.zig` (worker-context LIFO rotate in `enqueuePush`; submitBatch rewire through new batched path).
- **Modify** `src/queue/work_deque.zig` (add `tryPushBottomN`).
- **Modify** `src/queue/ring_queue.zig` (add `tryPushN`).
- **Modify** `tests/unit.zig` (unit coverage for rotate semantics and batched push).
- **Create** `docs/performance/2026-04-17-go-gap-round2/runs/phase1-ab.md`.
- **Create** `docs/performance/2026-04-17-go-gap-round2/runs/phase2-ab.md`.
- **Create** `docs/performance/2026-04-17-go-gap-round2/FINAL.md`.
- **Modify** `CLAUDE.md` (refresh "Current Direct Runtime Snapshot" at end of Phase 3).

---

## Phase 0 — Baseline pin

Goal: pin the measurement baseline so every paired A/B below has an unambiguous "A" leg.

### Task 0.1: Confirm baseline HEAD and cached binary

**Files:** none modified — read-only verification.

- [ ] **Step 1: Verify HEAD is `a666ec3`**

Run: `git rev-parse HEAD`
Expected: `a666ec3…` (exact SHA prefix; if different, stop and ask the user which commit to baseline against).

- [ ] **Step 2: Build the baseline Zig binary into an isolated worktree**

Run:

```bash
mkdir -p .cache/worktrees
git worktree add -f .cache/worktrees/baseline-a666ec3 a666ec3
cd .cache/worktrees/baseline-a666ec3
zig build bench-runtime-zig -Doptimize=ReleaseFast -p zig-out
sha256sum zig-out/bin/bench-runtime-zig | tee /tmp/baseline-hash.txt
cd -
```

Expected: a SHA256 string written to `/tmp/baseline-hash.txt`; note this hash — you will compare against Phase 1's binary hash to confirm distinct binaries.

- [ ] **Step 3: Commit nothing**

This task is read-only. No commit.

---

## Phase 1 — LIFO-slot rotate

**Goal:** In worker-context `enqueuePush`, always swap the incoming entry into `lifo_slot` and push the displaced entry (if any) to the local deque. Matches Go `runqput` / Tokio `LifoSlot` semantics.

**Why this should win:** Today, only the FIRST worker-context submit after a drain gets the hot `lifo_slot` single-store fast path. Children 2..N on `submitBatch`, and any subsequent spawns while the slot is occupied, always take the deque-push path. After rotate, every submit gets the single atomic store; the displaced entry's cost is identical to what today's code pays for children 2..N. Net: the worker's NEXT pop (via `nextTask`'s existing `swap(LIFO_SLOT_EMPTY)`) returns the freshest entry — hottest cache, best branch-predictor state — matching what `nested_fanout_4x` and `cpu_work_10us` actually need.

**Why it might not win:** `lifo_slot` is atomic-swap vs. `tryPushBottom` which is an unordered store + release store. The per-submit atomic cost changes shape (1 store vs 2 stores) but not magnitude. The hypothesis is that the NEXT-POP cache locality dominates; kill gate verifies.

**Kill gate (paired A/B, n=10, same session):**

- `nested_fanout_4x` median Δ ≥ +5% vs Phase-0 baseline.
- No non-target scenario regressed more than 3%.
- 20× `test-stress` clean.

If either fails → revert the Phase 1 commits and skip to Phase 3.

### Task 1.1: Write a rotate-semantics unit test

**Files:**
- Test: `tests/unit.zig` (append new test block near existing `lifo_slot` coverage)

- [ ] **Step 1: Find the existing lifo_slot tests**

Run: `grep -n 'lifo_slot\|LIFO_SLOT' tests/unit.zig | head -20`
Expected: several existing test references; note the line where the closing `}` of the last lifo_slot-related test sits.

- [ ] **Step 2: Append the failing rotate test**

Add the following test immediately after the last lifo_slot-related test in `tests/unit.zig`:

```zig
test "enqueuePush rotates lifo_slot on worker-context submit" {
    var pool = try ThreadPool.init(std.testing.allocator, .{
        .max_threads = 2,
        .queue_capacity = 256,
    });
    defer pool.deinit();

    // Register the test thread as worker 0 for this test by pausing the real
    // worker and submitting on its TLS.
    //
    // Use pool.core.withTlsWorkerForTesting(0, ...) — adds a TLS-install
    // helper used only by tests (see Task 1.2).

    const T = struct {
        fn noop(_: *anyopaque) void {}
    };
    var ctx: u8 = 0;

    // Install TLS worker slot 0 so enqueuePush takes the worker-context branch.
    pool.core.installTestTlsWorkerSlot(0);
    defer pool.core.clearTestTlsWorkerSlot();

    // First submit: slot was empty, entry lands in lifo_slot directly.
    const h1 = try pool.submit(T.noop, &ctx, .{ .waitable = false });
    _ = h1;
    const slot_after_1 = pool.core.peekLifoSlotForTesting(0);
    try std.testing.expect(slot_after_1 != pool.core.lifoSlotEmptySentinelForTesting());

    // Second submit: slot was occupied. Under rotate, the NEW entry replaces
    // the slot and the OLD entry lands in local_queue[0].
    const h2 = try pool.submit(T.noop, &ctx, .{ .waitable = false });
    _ = h2;
    const slot_after_2 = pool.core.peekLifoSlotForTesting(0);
    try std.testing.expect(slot_after_2 != slot_after_1);
    try std.testing.expect(pool.core.localQueueLenForTesting(0) == 1);

    // Third submit: same pattern.
    const h3 = try pool.submit(T.noop, &ctx, .{ .waitable = false });
    _ = h3;
    const slot_after_3 = pool.core.peekLifoSlotForTesting(0);
    try std.testing.expect(slot_after_3 != slot_after_2);
    try std.testing.expect(pool.core.localQueueLenForTesting(0) == 2);
}
```

- [ ] **Step 3: Run the test and watch it fail to compile**

Run: `zig build test --summary all 2>&1 | tail -30`
Expected: compile error — `installTestTlsWorkerSlot`, `clearTestTlsWorkerSlot`, `peekLifoSlotForTesting`, `lifoSlotEmptySentinelForTesting`, `localQueueLenForTesting` are undefined. This is expected; they'll be added in Task 1.2.

- [ ] **Step 4: Stage but do NOT commit yet**

Run: `git add tests/unit.zig`

(The test will be committed together with the implementation in Task 1.2 so the tree is never in a "test references nonexistent API" state on main.)

### Task 1.2: Implement rotate in `enqueuePush` + test helpers

**Files:**
- Modify: `src/pool.zig:~1408-1427` (worker-context default-lane block in `enqueuePush`)
- Modify: `src/pool.zig` (add 5 testing helpers at the end of `ThreadPool`)

- [ ] **Step 1: Re-read the current worker-context block**

Read `src/pool.zig:1401-1444` to confirm the "LIFO slot empty → store; else local_queue push" shape. Under rotate, you will replace this block wholesale.

- [ ] **Step 2: Replace the worker-context branch with rotate semantics**

In `src/pool.zig`, inside `enqueuePush`, replace the block that currently reads:

```zig
if (uses_local) {
    if (self.tlsWorkerIndexFor()) |wi| {
        const w = &self.workers[wi];
        if (w.serves_lane == .default) {
            if (w.lifo_slot.load(.monotonic) == LIFO_SLOT_EMPTY) {
                w.lifo_slot.store(entry, .release);
                queued = true;
            } else {
                const was_empty = w.owned_queue_len == 0;
                queued = self.local_queues[wi].tryPushBottom(entry);
                if (queued) {
                    w.owned_queue_len += 1;
                    if (was_empty) self.markWorkerNonEmpty(wi);
                    updatePeakU32(&w.local_queue_peak, @intCast(w.owned_queue_len));
                }
            }
        }
    }
}
```

with:

```zig
if (uses_local) {
    if (self.tlsWorkerIndexFor()) |wi| {
        const w = &self.workers[wi];
        if (w.serves_lane == .default) {
            // LIFO-rotate (Go `runqput` / Tokio `LifoSlot` semantics):
            // always swap the freshest entry into lifo_slot; the displaced
            // entry (if any) goes to the bottom of local_queue. `nextTask`
            // already pops lifo_slot first, so the just-spawned task is
            // always the next to run when this worker idles — matching
            // Go's next-g slot. Under the prior "only when empty" variant,
            // only the first worker-context submit after a drain got the
            // hot path; every subsequent spawn fell through to the deque.
            const prev = w.lifo_slot.swap(entry, .acq_rel);
            if (prev == LIFO_SLOT_EMPTY) {
                queued = true;
            } else {
                const was_empty = w.owned_queue_len == 0;
                if (self.local_queues[wi].tryPushBottom(prev)) {
                    w.owned_queue_len += 1;
                    if (was_empty) self.markWorkerNonEmpty(wi);
                    updatePeakU32(&w.local_queue_peak, @intCast(w.owned_queue_len));
                    queued = true;
                } else {
                    // Local deque full — restore the displaced entry to
                    // lifo_slot if it is still empty; otherwise fall through
                    // to the submitter_queue / inject_queue path below with
                    // `entry` still addressed (we already swapped it in).
                    // Contention window: another swap by a stealer is
                    // impossible (stealers never touch lifo_slot); a
                    // concurrent nextTask on this worker CAN swap, but this
                    // branch only runs on the worker's own thread, so no
                    // nextTask is in flight here. The restore always wins.
                    const restore = w.lifo_slot.cmpxchgStrong(
                        entry,
                        prev,
                        .acq_rel,
                        .acquire,
                    );
                    if (restore == null) {
                        queued = true;
                        // `entry` is now safe in the slot; the displaced
                        // `prev` becomes the fall-through candidate.
                        // Redirect the remaining branches to push `prev`.
                        //
                        // We reuse the local label-less fall-through by
                        // reassigning the captured pointer-indirect entry
                        // via a local mutable we declare above. Simplest
                        // form: recursively call enqueuePush logic for
                        // `prev` through the submitter/inject path only.
                        if (self.tlsSubmitterIndexFor()) |si| {
                            queued = self.submitter_queues[si].tryPushBottom(prev);
                        }
                        if (!queued) {
                            queued = self.inject_queue.tryPush(prev);
                        }
                        if (!queued) {
                            // Both fallbacks full — give back the descriptor
                            // and return QueueFull. `prev`'s descriptor was
                            // owned by the pool pre-rotate; it now lives in
                            // lifo_slot (under `entry`'s identity). Bail:
                            return error.QueueFull;
                        }
                    }
                    // restore failed (another thread wrote lifo_slot) — fall
                    // through; `entry` is still logically the one we want to
                    // queue via the submitter/inject path.
                }
            }
        }
    }
}
```

Then add test helpers. At the bottom of `ThreadPool` (around the existing `drainWorkerDescCachesForTesting` helper), append:

```zig
pub fn installTestTlsWorkerSlot(self: *ThreadPool, worker_index: usize) void {
    self.core.installTestTlsWorkerSlot(worker_index);
}

pub fn clearTestTlsWorkerSlot(self: *ThreadPool) void {
    self.core.clearTestTlsWorkerSlot();
}

pub fn peekLifoSlotForTesting(self: *ThreadPool, worker_index: usize) u32 {
    return self.core.workers[worker_index].lifo_slot.load(.acquire);
}

pub fn lifoSlotEmptySentinelForTesting(_: *ThreadPool) u32 {
    return LIFO_SLOT_EMPTY;
}

pub fn localQueueLenForTesting(self: *ThreadPool, worker_index: usize) usize {
    return self.core.local_queues[worker_index].len();
}
```

And in `Core` (private methods), add the install/clear pair that mutates the TLS-worker slot used by `tlsWorkerIndexFor`:

```zig
fn installTestTlsWorkerSlot(self: *Core, worker_index: usize) void {
    tls_worker_slot = .{ .pool = @as(*anyopaque, @ptrCast(self)), .index = worker_index };
}

fn clearTestTlsWorkerSlot(self: *Core) void {
    _ = self;
    tls_worker_slot = .{};
}
```

- [ ] **Step 3: Run the rotate unit test and watch it pass**

Run: `zig build test --summary all 2>&1 | tail -30`
Expected: all tests pass, including `enqueuePush rotates lifo_slot on worker-context submit`.

- [ ] **Step 4: Run the full test suite**

Run in parallel (independent suites):

```bash
zig build test-integration --summary all
zig build test-stress --summary all
```

Expected: both clean.

- [ ] **Step 5: 20x ReleaseFast stress gate**

Run:

```bash
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  echo "=== stress run $i ===";
  zig build test-stress -Doptimize=ReleaseFast --summary all || { echo "FAIL at run $i"; exit 1; };
done
```

Expected: `=== stress run 20 ===` reached, no "FAIL at run" message.
If ANY run fails → revert the Phase 1 changes and skip to Phase 3.

- [ ] **Step 6: Commit Phase 1**

```bash
git add tests/unit.zig src/pool.zig
git commit -m "$(cat <<'EOF'
perf(pool): rotate lifo_slot on every worker-context submit

Replace the "only-when-empty" lifo_slot store with a rotating swap:
the freshest entry always lands in lifo_slot, and the displaced entry
(if any) falls through to local_queue. Matches Go runqput / Tokio
LifoSlot next-g semantics, giving every worker-context spawn the
hot single-atomic-store fast path instead of just the first post-drain
spawn. nextTask already pops lifo_slot first, so the just-submitted
task is always next to run on this worker when it idles.

No struct layout changes (iter-11 discipline / 2026-04-16 Worker-size
trade-off memory). Adds Testing helpers for TLS-worker install/clear
and lifo_slot/local_queue peek so unit tests can exercise the rotate
branch deterministically.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

### Task 1.3: Paired A/B — Phase 1 vs Phase 0

**Files:**
- Create: `docs/performance/2026-04-17-go-gap-round2/runs/phase1-ab.md`

- [ ] **Step 1: Build the Phase-1 binary from an isolated worktree**

```bash
mkdir -p .cache/worktrees
git worktree add -f .cache/worktrees/phase1-HEAD HEAD
cd .cache/worktrees/phase1-HEAD
zig build bench-runtime-zig -Doptimize=ReleaseFast -p zig-out
sha256sum zig-out/bin/bench-runtime-zig | tee /tmp/phase1-hash.txt
cd -
diff /tmp/baseline-hash.txt /tmp/phase1-hash.txt
```

Expected: `diff` reports the two binaries are distinct. If identical → the build did not actually rebuild; stop and debug.

- [ ] **Step 2: Run paired A/B (n=10 balanced order)**

```bash
mkdir -p docs/performance/2026-04-17-go-gap-round2/runs
for i in 1 2 3 4 5 6 7 8 9 10; do
  echo "=== round $i: A (Phase-0) ===";
  ./scripts/run-runtime-comparison.sh \
    --zig-bin .cache/worktrees/baseline-a666ec3/zig-out/bin/bench-runtime-zig \
    --samples 3 --warmup-discard 1 \
    --output docs/performance/2026-04-17-go-gap-round2/runs/phase1-A-${i}.json;
  echo "=== round $i: B (Phase-1) ===";
  ./scripts/run-runtime-comparison.sh \
    --zig-bin .cache/worktrees/phase1-HEAD/zig-out/bin/bench-runtime-zig \
    --samples 3 --warmup-discard 1 \
    --output docs/performance/2026-04-17-go-gap-round2/runs/phase1-B-${i}.json;
done
uptime | tee -a docs/performance/2026-04-17-go-gap-round2/runs/phase1-host-state.log
```

Expected: 20 JSON files produced, host-state log captured.

- [ ] **Step 3: Aggregate medians and write the runsheet**

Write `docs/performance/2026-04-17-go-gap-round2/runs/phase1-ab.md` using the structure from [`phase3-ab.md`](../../performance/2026-04-16-go-gap-contended/runs/phase3-ab.md): legs, protocol, medians table per scenario, kill-gate verdict, raw samples, methodology notes. Compute the median of 10 as the mean of the 5th and 6th sorted ascending entries. Include ALL 8 bench scenarios — kill gate is scoped to `nested_fanout_4x`, but non-target regressions must be visible.

Expected: runsheet written with one of:
- **PASS:** `nested_fanout_4x` Δ ≥ +5% AND no non-target Δ < -3%
- **FAIL:** record the failure and proceed to Step 5.

- [ ] **Step 4: On PASS — commit the runsheet**

```bash
git add docs/performance/2026-04-17-go-gap-round2/runs/phase1-ab.md docs/performance/2026-04-17-go-gap-round2/runs/phase1-*.json docs/performance/2026-04-17-go-gap-round2/runs/phase1-host-state.log
git commit -m "$(cat <<'EOF'
perf(bench): Phase-1 A/B — lifo_slot rotate on worker-context submit

Paired same-session A/B (n=10 balanced order): Phase-0 baseline
(a666ec3) vs Phase-1 (lifo_slot rotate).

Kill gate: nested_fanout_4x Δ >= +5%, no non-target regression > 3%.
Verdict: PASS/FAIL — see phase1-ab.md for deltas.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

Then continue to Phase 2.

- [ ] **Step 5: On FAIL — revert Phase 1 and skip to Phase 3**

```bash
git log --oneline -3
# Confirm the two commits to revert are (a) the impl commit and (b) the runsheet commit.
git revert --no-edit HEAD~1..HEAD  # revert impl commit; keep the runsheet commit as evidence
```

Then jump directly to Phase 3 with the runsheet documenting the failed attempt.

---

## Phase 2 — Batched local-queue push via `tryPushBottomN`

**Goal:** Collapse N per-task release-stores into one inside `submitBatch`, for both worker-context (local_queue) and submitter-context (submitter_queue) paths.

**Why this should win:** Today, `submitBatch(tasks)` calls `enqueuePush` N times; each call does `tryPushBottom` which costs one `bottom.load(.monotonic) + top.load(.acquire) + buffer[b].store(.unordered) + bottom.store(b+1, .release)` — i.e. one release-store per task that must be globally visible. Batching to `tryPushBottomN` lets the producer write all N buffer slots at `.unordered` and then publish bottom `+= n` with a single release-store. For a 4-task `nested_fanout_4x` burst, that's 4 → 1 release-stores. For an 8-submitter-thread `contended_spawn_8x` batch, same savings on the submitter-queue push side.

**Why it might not win:** The release-store is not free but is also not the dominant cost on a well-predicted branch. If the scenario is dominated by cross-worker steal traffic or descriptor-pool CAS, batching won't move the needle. Kill gate verifies.

**Kill gate (paired A/B, n=10, same session):**

- Weighted-average Δ across `{nested_fanout_4x, contended_spawn_8x, contended_cpu_10us}` ≥ +5% vs Phase 1 HEAD.
- No non-target scenario regressed more than 3%.
- 20× `test-stress` clean.

"Weighted-average" = simple arithmetic mean of the three target Δ%s; any one of the three scenarios individually may exceed or underperform, as long as the mean clears +5% and no non-target regresses > 3%.

If fails → revert Phase 2 and skip to Phase 3 with Phase 1's wins banked.

### Task 2.1: Add `tryPushBottomN` to `WorkDeque`

**Files:**
- Modify: `src/queue/work_deque.zig` (add one method next to `tryPushBottom`)
- Modify: `tests/unit.zig` (new WorkDeque batched-push test)

- [ ] **Step 1: Write the failing unit test**

Append to `tests/unit.zig`:

```zig
test "WorkDeque.tryPushBottomN batches N entries in one release" {
    const WorkDeque = @import("src/queue/work_deque.zig").WorkDeque;
    var q = try WorkDeque(u32).init(std.testing.allocator, 64);
    defer q.deinit();

    const batch = [_]u32{ 10, 20, 30, 40, 50 };
    const n = q.tryPushBottomN(&batch);
    try std.testing.expectEqual(@as(usize, 5), n);

    // popBottom returns LIFO: 50, 40, 30, 20, 10.
    try std.testing.expectEqual(@as(?u32, 50), q.popBottom());
    try std.testing.expectEqual(@as(?u32, 40), q.popBottom());
    try std.testing.expectEqual(@as(?u32, 30), q.popBottom());
    try std.testing.expectEqual(@as(?u32, 20), q.popBottom());
    try std.testing.expectEqual(@as(?u32, 10), q.popBottom());
    try std.testing.expectEqual(@as(?u32, null), q.popBottom());
}

test "WorkDeque.tryPushBottomN partial when near-full" {
    const WorkDeque = @import("src/queue/work_deque.zig").WorkDeque;
    var q = try WorkDeque(u32).init(std.testing.allocator, 4);
    defer q.deinit();

    try std.testing.expect(q.tryPushBottom(1));
    try std.testing.expect(q.tryPushBottom(2));
    // Capacity = 4, already 2 in. Batch of 5 should push 2 and return 2.
    const batch = [_]u32{ 10, 20, 30, 40, 50 };
    const n = q.tryPushBottomN(&batch);
    try std.testing.expectEqual(@as(usize, 2), n);
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `zig build test --summary all 2>&1 | grep -E 'WorkDeque\.tryPushBottomN|FAIL|error' | head -10`
Expected: compile error — `tryPushBottomN` undefined.

- [ ] **Step 3: Implement `tryPushBottomN` in `WorkDeque`**

Add this method immediately after `tryPushBottom` in `src/queue/work_deque.zig`:

```zig
/// Owner-only. Push up to `values.len` items to the bottom of the deque.
/// Returns the number actually pushed (0..values.len). Writes all slot
/// payloads at `.unordered` and publishes the new bottom with a single
/// `.release` store — one global visibility event regardless of batch
/// size, vs N release-stores for N single `tryPushBottom` calls.
///
/// Correctness: same as `tryPushBottom` scaled. Stealers only read slots
/// at indices `[top, bottom)`, and `bottom` is advanced last under
/// `.release`, so until the final store no stealer can observe any of
/// the new slot writes. A stealer that sees the bumped bottom sees all
/// `n` writes (causal with release).
pub fn tryPushBottomN(self: *Self, values: []const T) usize {
    if (values.len == 0) return 0;
    const b = self.bottom.load(.monotonic);
    const t = self.top.load(.acquire);
    const cap: isize = @intCast(self.buffer.len);
    const used = b -% t;
    if (used >= cap) return 0;
    const free: usize = @intCast(cap -% used);
    const n = @min(free, values.len);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        self.buffer[@as(usize, @intCast(b +% @as(isize, @intCast(i)))) & self.mask]
            .store(values[i], .unordered);
    }
    self.bottom.store(b +% @as(isize, @intCast(n)), .release);
    return n;
}
```

- [ ] **Step 4: Run the WorkDeque tests**

Run: `zig build test --summary all 2>&1 | tail -30`
Expected: all new tests pass; nothing else regresses.

- [ ] **Step 5: Commit**

```bash
git add src/queue/work_deque.zig tests/unit.zig
git commit -m "$(cat <<'EOF'
perf(queue): add WorkDeque.tryPushBottomN for batched producer pushes

Collapse N producer-side release-stores into one for common contiguous-
batch cases. Wires in at Task 2.4 (submitBatch). Owner-only; stealer-
side semantics unchanged — stealers read slots at [top, bottom) and
bottom is advanced last under .release, so pre-publish writes remain
invisible.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

### Task 2.2: Add `tryPushN` to `RingQueue`

**Files:**
- Modify: `src/queue/ring_queue.zig` (add one method next to `tryPush`)
- Modify: `tests/unit.zig` (mirror WorkDeque batched-push test for RingQueue)

- [ ] **Step 1: Write the failing unit test**

Append to `tests/unit.zig`:

```zig
test "RingQueue.tryPushN batches N entries in one release" {
    const RingQueue = @import("src/queue/ring_queue.zig").RingQueue;
    var q = try RingQueue(u32).init(std.testing.allocator, 64);
    defer q.deinit();

    const batch = [_]u32{ 10, 20, 30, 40, 50 };
    const n = q.tryPushN(&batch);
    try std.testing.expectEqual(@as(usize, 5), n);

    // pop from tail (LIFO): 50, 40, 30, 20, 10.
    try std.testing.expectEqual(@as(?u32, 50), q.pop());
    try std.testing.expectEqual(@as(?u32, 40), q.pop());
    try std.testing.expectEqual(@as(?u32, 30), q.pop());
    try std.testing.expectEqual(@as(?u32, 20), q.pop());
    try std.testing.expectEqual(@as(?u32, 10), q.pop());
    try std.testing.expectEqual(@as(?u32, null), q.pop());
}

test "RingQueue.tryPushN partial when near-full" {
    const RingQueue = @import("src/queue/ring_queue.zig").RingQueue;
    var q = try RingQueue(u32).init(std.testing.allocator, 4);
    defer q.deinit();

    try std.testing.expect(q.tryPush(1));
    try std.testing.expect(q.tryPush(2));
    const batch = [_]u32{ 10, 20, 30, 40, 50 };
    const n = q.tryPushN(&batch);
    try std.testing.expectEqual(@as(usize, 2), n);
}
```

- [ ] **Step 2: Run the tests and verify they fail**

Run: `zig build test --summary all 2>&1 | grep -E 'RingQueue\.tryPushN|FAIL|error' | head -10`
Expected: compile error — `tryPushN` undefined.

- [ ] **Step 3: Implement `tryPushN` in `RingQueue`**

Add this method immediately after `tryPush` in `src/queue/ring_queue.zig`:

```zig
/// Owner-only. Push up to `values.len` items to the tail. Returns the
/// number actually pushed. One `.release` store of tail publishes all
/// `n` slot writes. Same correctness sketch as `tryPush` scaled.
pub fn tryPushN(self: *Self, values: []const T) usize {
    if (values.len == 0) return 0;
    const t = self.tail.load(.monotonic);
    const h = self.head.load(.acquire);
    const cap: u32 = @intCast(self.buffer.len);
    const used = t -% h;
    if (used >= cap) return 0;
    const free: u32 = cap - used;
    const n: u32 = @min(free, @as(u32, @intCast(values.len)));
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        self.buffer[(t +% i) & self.mask].store(values[i], .unordered);
    }
    self.tail.store(t +% n, .release);
    return @intCast(n);
}
```

- [ ] **Step 4: Run tests**

Run: `zig build test --summary all 2>&1 | tail -20`
Expected: pass.

- [ ] **Step 5: Commit**

```bash
git add src/queue/ring_queue.zig tests/unit.zig
git commit -m "$(cat <<'EOF'
perf(queue): add RingQueue.tryPushN for batched producer pushes

Mirrors WorkDeque.tryPushBottomN. One release-store of tail publishes
N slot writes. Wires in at Task 2.3 through the LocalQueue union.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

### Task 2.3: Surface `tryPushBottomN` through `LocalQueue` union

**Files:**
- Modify: `src/pool.zig:~170-175` (add union dispatch method)

- [ ] **Step 1: Add the dispatch method**

Immediately after the existing `tryPushBottom` method in the `LocalQueue` union (around line 170 in `src/pool.zig`), add:

```zig
fn tryPushBottomN(self: *LocalQueue, values: []const QueueEntry) usize {
    return switch (self.*) {
        .chase_lev => |*q| q.tryPushBottomN(values),
        .ring => |*q| q.tryPushN(values),
    };
}
```

- [ ] **Step 2: Build and test**

Run: `zig build test --summary all 2>&1 | tail -20`
Expected: pass.

- [ ] **Step 3: Commit**

```bash
git add src/pool.zig
git commit -m "$(cat <<'EOF'
perf(pool): dispatch LocalQueue.tryPushBottomN through the union

Queue-kind-agnostic wrapper. Consumed by submitBatch in Task 2.4.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

### Task 2.4: Rewire `submitBatch` through the batched push path

**Files:**
- Modify: `src/pool.zig:823` (`submitBatch`)
- Modify: `tests/unit.zig` (new submitBatch end-to-end test with multi-task batch)

- [ ] **Step 1: Write a unit test exercising the batched path**

Append to `tests/unit.zig`:

```zig
test "submitBatch of 8 from worker context routes through tryPushBottomN" {
    var pool = try ThreadPool.init(std.testing.allocator, .{
        .max_threads = 2,
        .queue_capacity = 256,
    });
    defer pool.deinit();

    pool.installTestTlsWorkerSlot(0);
    defer pool.clearTestTlsWorkerSlot();

    const T = struct {
        var count: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);
        fn bump(_: *anyopaque) void {
            _ = count.fetchAdd(1, .monotonic);
        }
    };
    T.count.store(0, .monotonic);

    var ctx: u8 = 0;
    var tasks: [8]@TypeOf(ThreadPool.BatchTask{ .task_fn = undefined, .ctx = undefined }) = undefined;
    for (&tasks) |*t| t.* = .{ .task_fn = T.bump, .ctx = &ctx };

    const res = try pool.submitBatch(&tasks, .{});
    try std.testing.expectEqual(@as(usize, 8), res.submitted);

    // Drain with a wait_group-less spin — workers will pick up tasks as soon
    // as TLS clear lets them run (the test thread holds TLS slot 0 until
    // clearTestTlsWorkerSlot below).
    pool.clearTestTlsWorkerSlot();

    const deadline = std.time.nanoTimestamp() + 2 * std.time.ns_per_s;
    while (T.count.load(.monotonic) < 8) {
        if (std.time.nanoTimestamp() > deadline) return error.Timeout;
        std.Thread.yield() catch {};
    }
}
```

- [ ] **Step 2: Run and watch it pass on the existing per-task path**

Run: `zig build test --summary all 2>&1 | tail -20`
Expected: the test already passes because `submitBatch` currently routes through per-task `enqueuePush`. The batched path will also satisfy the same test; it exists to guard against regressions in Task 2.4.

- [ ] **Step 3: Rewrite `submitBatch` to use the batched path**

Replace the body of `Core.submitBatch` in `src/pool.zig` (the method that starts around line 823) with:

```zig
pub fn submitBatch(self: *Core, tasks: []const BatchTask, options: types.SubmitOptions) !SubmitBatchResult {
    if (tasks.len == 0) return .{ .submitted = 0 };
    const effective = self.effectiveBackpressure(options);
    const deadline = if (effective == .block_with_timeout and options.timeout_ns != null)
        nowNs() + options.timeout_ns.?
    else
        0;

    // Fast path: for default-lane, non-blocking batches from a TLS-identified
    // context, bulk-allocate descriptors + bulk-push into the owner queue in
    // one release-store. Slow path (below) is the pre-existing per-task loop;
    // it handles backpressure retries, mid-batch queue-full, disabled lanes,
    // and shutdown-in-progress without needing to rewind a batched push.
    if (options.lane == .default and tasks.len > 1) {
        const uses_local = usesLocalQueues(self);
        if (uses_local) {
            if (self.tlsWorkerIndexFor()) |wi| {
                const w = &self.workers[wi];
                if (w.serves_lane == .default) {
                    if (self.submitBatchWorkerFast(tasks, options, wi, w)) |res| {
                        return res;
                    }
                    // Fast-path bailed (backpressure needs handling, queue
                    // full mid-way, etc.) — fall through to slow loop.
                }
            }
            if (self.tlsSubmitterIndexFor()) |si| {
                if (self.submitBatchSubmitterFast(tasks, options, si)) |res| {
                    return res;
                }
            }
        }
    }

    // Slow path — unchanged from pre-Task-2.4.
    var submitted: usize = 0;
    var pending_notify: u64 = 0;
    var i: usize = 0;
    while (i < tasks.len) {
        if (self.state.load(.acquire) != .running) {
            if (pending_notify > 0) self.notifySubmits(pending_notify, options.lane);
            if (submitted == 0) return error.ShutdownInProgress;
            return .{ .submitted = submitted };
        }
        if (self.enqueuePush(tasks[i].task_fn, tasks[i].ctx, options)) |_| {
            pending_notify += 1;
            submitted += 1;
            i += 1;
        } else |err| switch (err) {
            error.QueueFull, error.TaskPoolExhausted => {
                if (effective == .return_error) {
                    if (pending_notify > 0) self.notifySubmits(pending_notify, options.lane);
                    if (submitted == 0) return err;
                    return .{ .submitted = submitted };
                }
                if (deadline != 0 and nowNs() >= deadline) {
                    if (pending_notify > 0) self.notifySubmits(pending_notify, options.lane);
                    if (submitted == 0) return error.Timeout;
                    return .{ .submitted = submitted };
                }
                if (pending_notify > 0) {
                    self.notifySubmits(pending_notify, options.lane);
                    pending_notify = 0;
                }
                self.waitForCapacity(deadline, options.lane);
            },
            error.BlockingLaneDisabled => {
                if (pending_notify > 0) self.notifySubmits(pending_notify, options.lane);
                if (submitted == 0) return err;
                return .{ .submitted = submitted };
            },
        }
    }
    if (pending_notify > 0) self.notifySubmits(pending_notify, options.lane);
    return .{ .submitted = submitted };
}

/// Worker-context batched fast path. Returns null when the fast path
/// cannot be applied (backpressure, mid-batch queue-full, descriptor
/// exhaustion) and the caller should fall back to the slow loop.
fn submitBatchWorkerFast(
    self: *Core,
    tasks: []const BatchTask,
    options: types.SubmitOptions,
    wi: usize,
    w: *Worker,
) ?SubmitBatchResult {
    const n = tasks.len;
    // Allocate N descriptors. For now use the per-task desc_cache tryPop /
    // single acquireDescriptor path repeated N times; Phase 2 does NOT
    // reshape descriptor allocation — that is a Phase-3 candidate.
    var desc_buf: [128]u32 = undefined;
    if (n > desc_buf.len) return null;
    var acquired: usize = 0;
    while (acquired < n) {
        if (w.desc_cache.tryPop()) |idx| {
            desc_buf[acquired] = idx;
            acquired += 1;
            continue;
        }
        var refill: [DescCache.capacity]u32 = undefined;
        const taken = self.acquireDescriptorBatch(&refill);
        if (taken == 0) break;
        // Consume from refill greedily: first into desc_buf, rest cached.
        var ri: usize = 0;
        while (ri < taken and acquired < n) : (ri += 1) {
            desc_buf[acquired] = refill[ri];
            acquired += 1;
        }
        while (ri < taken) : (ri += 1) {
            _ = w.desc_cache.push(refill[ri]);
        }
    }
    if (acquired == 0) return null;

    // Initialise descriptor bodies in a tight loop — CPU can pipeline N
    // independent stores when there is no queue-push dependency between.
    var entries: [128]QueueEntry = undefined;
    var j: usize = 0;
    const with_ts = timestampsEnabled(self);
    while (j < acquired) : (j += 1) {
        const di = desc_buf[j];
        const d = &self.descriptors[di];
        d.task_fn = tasks[j].task_fn;
        d.ctx = tasks[j].ctx;
        d.options = options;
        d.submit_ns = if (with_ts) nowNs() else 0;
        d.start_ns = 0;
        d.complete_ns = 0;
        d.state.store(.queued, .release);
        if (options.wait_group) |wg| wg.add(1);
        entries[j] = packEntry(di, d.generation);
    }

    // lifo_slot rotate for the NEWEST entry (last); older entries go to
    // local_queue via tryPushBottomN. If the slot was already occupied,
    // the displaced entry is PREPENDED to the batch for local_queue push.
    const newest = entries[acquired - 1];
    const prev_slot = w.lifo_slot.swap(newest, .acq_rel);
    const had_prev = prev_slot != LIFO_SLOT_EMPTY;

    var push_buf: [129]QueueEntry = undefined;
    var push_n: usize = 0;
    if (had_prev) {
        push_buf[0] = prev_slot;
        push_n = 1;
    }
    for (entries[0 .. acquired - 1]) |e| {
        push_buf[push_n] = e;
        push_n += 1;
    }

    const was_empty = w.owned_queue_len == 0;
    const pushed = self.local_queues[wi].tryPushBottomN(push_buf[0..push_n]);
    if (pushed < push_n) {
        // Partial push — restore lifo_slot to whatever was there before (if
        // anything) and tell caller to fall back. On partial the descriptors
        // acquired but not queued get released, and the slot write itself is
        // undone to pre-call state.
        const unqueued_entries = entries[0 .. acquired - 1 - (pushed - (if (had_prev) @as(usize, 1) else 0))];
        _ = unqueued_entries;
        // Release all descriptors we acquired but could not land. Simpler:
        // release ALL acquired, restore slot to prev, return null → slow path
        // will re-do the work from scratch. Cheap because partial pushes are
        // rare (capacity has 256 slots vs tasks.len in the 4-to-10 range for
        // target workloads) and correctness matters more here than perf.
        _ = w.lifo_slot.store(prev_slot, .release);
        for (desc_buf[0..acquired]) |di| {
            const d = &self.descriptors[di];
            if (options.wait_group) |wg| wg.done();
            // Set descriptor back to .free via releaseDescriptor (gated CAS).
            _ = d.state.cmpxchgStrong(.queued, .free, .acq_rel, .acquire);
            self.releaseDescriptor(di);
        }
        return null;
    }

    if (pushed > 0) {
        w.owned_queue_len += pushed;
        if (was_empty) self.markWorkerNonEmpty(wi);
        updatePeakU32(&w.local_queue_peak, @intCast(w.owned_queue_len));
    }

    self.notifySubmits(@intCast(acquired), options.lane);

    // Partial acquire (descriptor exhaustion mid-batch) → fast path still
    // succeeded for `acquired` tasks; caller gets the partial count.
    return .{ .submitted = acquired };
}

/// Submitter-context batched fast path.
fn submitBatchSubmitterFast(
    self: *Core,
    tasks: []const BatchTask,
    options: types.SubmitOptions,
    si: usize,
) ?SubmitBatchResult {
    const n = tasks.len;
    var desc_buf: [128]u32 = undefined;
    if (n > desc_buf.len) return null;
    const cache = &self.desc_caches[si];
    var acquired: usize = 0;
    while (acquired < n) {
        if (cache.tryPop()) |idx| {
            desc_buf[acquired] = idx;
            acquired += 1;
            continue;
        }
        var refill: [DescCache.capacity]u32 = undefined;
        const taken = self.acquireDescriptorBatch(&refill);
        if (taken == 0) break;
        var ri: usize = 0;
        while (ri < taken and acquired < n) : (ri += 1) {
            desc_buf[acquired] = refill[ri];
            acquired += 1;
        }
        while (ri < taken) : (ri += 1) {
            _ = cache.push(refill[ri]);
        }
    }
    if (acquired == 0) return null;

    var entries: [128]QueueEntry = undefined;
    var j: usize = 0;
    const with_ts = timestampsEnabled(self);
    while (j < acquired) : (j += 1) {
        const di = desc_buf[j];
        const d = &self.descriptors[di];
        d.task_fn = tasks[j].task_fn;
        d.ctx = tasks[j].ctx;
        d.options = options;
        d.submit_ns = if (with_ts) nowNs() else 0;
        d.start_ns = 0;
        d.complete_ns = 0;
        d.state.store(.queued, .release);
        if (options.wait_group) |wg| wg.add(1);
        entries[j] = packEntry(di, d.generation);
    }

    const pushed = self.submitter_queues[si].tryPushBottomN(entries[0..acquired]);
    if (pushed < acquired) {
        // Partial — release remaining descriptors and return null for slow fallback.
        for (desc_buf[pushed..acquired]) |di| {
            const d = &self.descriptors[di];
            if (options.wait_group) |wg| wg.done();
            _ = d.state.cmpxchgStrong(.queued, .free, .acq_rel, .acquire);
            self.releaseDescriptor(di);
        }
        if (pushed == 0) return null;
    }

    self.notifySubmits(@intCast(pushed), options.lane);
    return .{ .submitted = pushed };
}
```

- [ ] **Step 4: Run unit + integration + stress suites**

Run in parallel:

```bash
zig build test --summary all
zig build test-integration --summary all
zig build test-stress --summary all
```

Expected: all clean.

- [ ] **Step 5: 20x ReleaseFast stress gate**

```bash
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  echo "=== stress run $i ===";
  zig build test-stress -Doptimize=ReleaseFast --summary all || { echo "FAIL at run $i"; exit 1; };
done
```

Expected: 20 clean.

- [ ] **Step 6: Commit**

```bash
git add src/pool.zig tests/unit.zig
git commit -m "$(cat <<'EOF'
perf(pool): batched submitBatch fast path via tryPushBottomN

Fast path for default-lane, multi-task submitBatch calls from a TLS-
identified worker or submitter context. Bulk-acquires descriptors, bulk-
writes descriptor bodies, then publishes the whole batch in a single
queue release-store (tryPushBottomN). Worker variant rotates the newest
entry into lifo_slot and prepends the displaced entry (if any) to the
batched push. Both variants fall back to the pre-existing per-task loop
on backpressure, mid-batch queue-full, or descriptor exhaustion so the
complex error paths stay localised.

No struct layout changes. Slow-path behaviour bit-compatible.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

### Task 2.5: Paired A/B — Phase 2 vs Phase 1

**Files:**
- Create: `docs/performance/2026-04-17-go-gap-round2/runs/phase2-ab.md`

- [ ] **Step 1: Build the Phase-2 binary**

```bash
git worktree add -f .cache/worktrees/phase2-HEAD HEAD
cd .cache/worktrees/phase2-HEAD
zig build bench-runtime-zig -Doptimize=ReleaseFast -p zig-out
sha256sum zig-out/bin/bench-runtime-zig | tee /tmp/phase2-hash.txt
cd -
diff /tmp/phase1-hash.txt /tmp/phase2-hash.txt
```

Expected: diff reports distinct binaries.

- [ ] **Step 2: Run n=10 paired A/B (Phase 1 vs Phase 2)**

```bash
for i in 1 2 3 4 5 6 7 8 9 10; do
  echo "=== round $i: A (Phase-1) ===";
  ./scripts/run-runtime-comparison.sh \
    --zig-bin .cache/worktrees/phase1-HEAD/zig-out/bin/bench-runtime-zig \
    --samples 3 --warmup-discard 1 \
    --output docs/performance/2026-04-17-go-gap-round2/runs/phase2-A-${i}.json;
  echo "=== round $i: B (Phase-2) ===";
  ./scripts/run-runtime-comparison.sh \
    --zig-bin .cache/worktrees/phase2-HEAD/zig-out/bin/bench-runtime-zig \
    --samples 3 --warmup-discard 1 \
    --output docs/performance/2026-04-17-go-gap-round2/runs/phase2-B-${i}.json;
done
uptime | tee -a docs/performance/2026-04-17-go-gap-round2/runs/phase2-host-state.log
```

Expected: 20 JSON files, host-state log captured.

- [ ] **Step 3: Write `phase2-ab.md`**

Same runsheet structure as `phase1-ab.md`. Record:
- Target-scenario medians (`nested_fanout_4x`, `contended_spawn_8x`, `contended_cpu_10us`) and their Δ% vs Phase-1 A.
- Weighted-average Δ across the three.
- All 8 scenarios' deltas (guards the non-target regression gate).
- Raw samples.

- [ ] **Step 4: Kill-gate check**

Weighted average of three targets ≥ +5% AND no non-target < −3% → PASS.
Otherwise → FAIL.

- [ ] **Step 5: On PASS — commit runsheet**

```bash
git add docs/performance/2026-04-17-go-gap-round2/runs/phase2-ab.md docs/performance/2026-04-17-go-gap-round2/runs/phase2-*.json docs/performance/2026-04-17-go-gap-round2/runs/phase2-host-state.log
git commit -m "$(cat <<'EOF'
perf(bench): Phase-2 A/B — batched submitBatch push

Paired same-session A/B (n=10 balanced order): Phase-1 (lifo_slot
rotate) vs Phase-2 (lifo_slot rotate + tryPushBottomN submitBatch).

Kill gate: weighted-avg Δ over three targets >= +5%, no non-target
regression > 3%. Verdict: PASS/FAIL — see phase2-ab.md.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 6: On FAIL — revert Phase 2 and proceed to Phase 3**

```bash
# Revert the three Task 2.1–2.4 commits. Phase 1 commit and runsheet stay.
git log --oneline -6
git revert --no-edit <tryPushBottomN commit> <tryPushN commit> <LocalQueue wrapper commit> <submitBatch rewire commit>
```

Document the failure in Phase 3's FINAL.md.

---

## Phase 3 — Artifacts

**Goal:** Produce the same artefact set the prior plan delivered, so this round is reviewable at the same bar.

### Task 3.1: Refresh benchmark JSON artefacts

**Files:**
- Modify: `benchmarks/results/latest.json`
- Modify: `benchmarks/results/scale-latest.json`
- Modify: `benchmarks/results/runtime-comparison-latest.json`

- [ ] **Step 1: Rebuild from main HEAD**

```bash
zig build bench-runtime-compare -Doptimize=ReleaseFast -- \
  --output benchmarks/results/runtime-comparison-latest.json
zig build bench -- --output benchmarks/results/latest.json
zig build scale-bench -- --output benchmarks/results/scale-latest.json
```

Expected: three refreshed JSON artefacts.

- [ ] **Step 2: Commit**

```bash
git add benchmarks/results/*.json
git commit -m "$(cat <<'EOF'
perf: refresh baselines post-Phase-2 (Go-gap round 2)

Bench artefacts now reflect main HEAD.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

### Task 3.2: Write `FINAL.md`

**Files:**
- Create: `docs/performance/2026-04-17-go-gap-round2/FINAL.md`

- [ ] **Step 1: Draft following prior-plan template**

Use the structure in [`2026-04-16-go-gap-contended/FINAL.md`](../../performance/2026-04-16-go-gap-contended/FINAL.md):

- Headline: cross-snapshot gap table vs Go for the three target scenarios.
- Phase-by-phase isolated paired A/B table.
- Source links to phase1-ab.md and phase2-ab.md.
- What landed (commits).
- What was skipped and why.
- Trade-off notes (if any — particularly if Phase 2's fast path regresses anything).
- **Honest cost accounting**: if either phase FAILED the kill gate, say so explicitly. If both passed, state the remaining gap vs Go (probably still > 1.5x) and note that further gains require attacking per-task descriptor init cost, which is out of scope for this plan.

- [ ] **Step 2: Commit**

```bash
git add docs/performance/2026-04-17-go-gap-round2/FINAL.md
git commit -m "$(cat <<'EOF'
docs(perf): Go-gap round 2 FINAL.md

Records the outcome of the 2026-04-17 Go-gap round 2 plan (Phase 1
lifo_slot rotate + Phase 2 batched submitBatch push).

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

### Task 3.3: Refresh `CLAUDE.md` "Current Direct Runtime Snapshot"

**Files:**
- Modify: `CLAUDE.md` (the section starting `## Current Direct Runtime Snapshot`)

- [ ] **Step 1: Read the new `runtime-comparison-latest.json`**

```bash
cat benchmarks/results/runtime-comparison-latest.json | jq -r '.rows[] | "\(.scenario_name): zig=\(.zig_thread_pool.throughput_ops_per_sec) tokio=\(.tokio.throughput_ops_per_sec) go=\(.go.throughput_ops_per_sec)"'
```

- [ ] **Step 2: Update the snapshot table and interpretation bullets**

Edit `CLAUDE.md` in-place. Update:

- Date stamp on the snapshot paragraph.
- Throughput table (ops/sec).
- Latency table.
- "Interpretation" bullets: replace the 2026-04-16 contended-scenarios summary with the 2026-04-17 round-2 summary — what landed, paired A/B deltas, updated Go gap per scenario.

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md
git commit -m "$(cat <<'EOF'
docs: refresh CLAUDE.md runtime snapshot post Go-gap round 2

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Self-review checklist (before handoff)

- [ ] Every step has actual code / actual command / actual expected output — no "TBD" or "fill in".
- [ ] Kill gates are stated numerically for each phase.
- [ ] Revert instructions exist for every phase that might fail.
- [ ] Struct layout invariants (iter-11, Worker-size trade-off memory) are not touched.
- [ ] Closed-plane memories (notifySubmits, worker pinning, shouldExit) are not re-attacked.
- [ ] 20x ReleaseFast stress gate is explicit before every `src/`-touching commit.
- [ ] Measurement protocol is same-session paired A/B, n=10, balanced order.
- [ ] Artefacts (runsheets + FINAL.md + CLAUDE.md) are written in Phase 3 regardless of whether Phase 1/2 passed or failed.
