# Phase G2 Re-Land: Remove Idle-Spin `queued_tasks` Poll Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Re-apply the original Phase G2 win — remove the `counters.queued_tasks.load(.acquire)` poll inside `Core.idle()`'s spin loop and drop the default `spin_before_park_iters` from `128` to `0`. Original G2 measured +8.9% on `flood_1m` (commit `60ad076`) before being reverted because the poll-removal's timing change unmasked a latent double-dequeue race in `nextTask`. Phase H (state-CAS gate at `runTask`, merged 2026-04-13 in `a75ed98`) closed that race path-agnostically. The re-land target is now unblocked.

**Architecture:** This is a single-site behavior change in `Core.idle()` plus a one-line config default change. The submit path writes `counters.queued_tasks` with `.seq_cst` on every submit; today every worker polls that same cacheline `spin_before_park_iters` times per park cycle. Removing the poll eliminates the dominant cross-core read traffic on the line. Park-handshake correctness is unaffected because the SC `is_parked.store(.seq_cst)` + `queued_tasks.load(.seq_cst)` reload at `pool.zig:881-887` is the actual lost-wakeup guard — the spin-poll was a latency shortcut only. The default `spin_before_park_iters = 0` change is folded in because, with the poll gone, an active spin is pure CPU burn (the original G2's end-of-spin local-work probe was A/B-proved inert per commit `60ad076`).

**Tech Stack:** Zig 0.15.2; `std.atomic.spinLoopHint`; existing Phase A park-handshake machinery; existing Phase H `runTask` state-CAS defense. No new types, no new atomics, no new config fields.

---

## What changed since the original Phase G2 (don't repeat history)

| Aspect | Original G2 (reverted) | Re-land (this plan) |
|---|---|---|
| Spin body | Poll removed; end-of-spin probe added (`lifo_slot`, `local_queue.len()`, `inject_queue.len()`) | Poll removed; **no probe** (A/B in `60ad076` showed probe inert) |
| `spin_before_park_iters` default | Left at 128 in initial commit `c335189`; later set to 0 in cleanup commit `60ad076` | Drops to 0 directly |
| Stress gate | 5× `test-stress` at default optimize | **20×** `test-stress` at `-Doptimize=ReleaseFast`; **100×** as final pre-merge gate (matches Phase H discipline) |
| Race defense | None — exposed latent double-dequeue in `nextTask` (~5% failure rate, missed by 5× sample) | Phase H state-CAS gate at `runTask` is upstream of any path G2 timing could expose |
| Regression tests | Created during plan | **Already on main** (`tests/unit.zig:481` and `tests/stress.zig:516`) — re-land just leans on them |

The two G2 regression tests survived the revert (left in place per the original Task 9 rollback path). The re-land does not add tests; it relies on the existing ones plus the new 20×/100× stress discipline.

---

## Design rationale (embedded — no separate spec)

1. **Why the poll is hot.** At ~331K ops/s, every submit does `queued_tasks.fetchAdd(1, .seq_cst)` on a line read by 56 workers × 128 spin iters per park cycle. Aggregate read rate ~100M loads/s on a line the submitter writes SC. Submitter's SC write bounces across every worker that just read it.
2. **Why removing the poll is safe.** The poll is a latency shortcut, not a correctness mechanism. The mutex-guarded SC handshake at `pool.zig:881-887` (worker stores `is_parked = 1` SC, then re-reads `queued_tasks` SC) is the actual lost-wakeup guard. Both legs of the IRIW exclusion remain SC. Removing acquire-loads in the pre-park spin participates in no handshake — it can only delay observation, never lose it.
3. **Why no end-of-spin probe.** Original G2 `c335189` added `lifo_slot` + `local_queue.len()` + `inject_queue.len()` checks at end-of-spin. A/B in `60ad076` (force `spin_before_park_iters = 0`, re-measure) showed default and spin=0 indistinguishable — the probe was inert dead code, same probability-of-engagement failure mode as Phase F1 (methodology lesson #5). The probe is not re-added.
4. **Why default `spin_before_park_iters = 0`.** With the poll gone, the spin body is just `state` check + `spinLoopHint`. There is no observable benefit — confirmed by `60ad076`'s A/B. Defaulting to 0 makes the spin cost-free for the default workload while preserving the knob for users who explicitly opt in (the existing stress tests at `tests/stress.zig:75,290,528` set non-zero values to exercise the polless-spin handshake).
5. **Why this is now safe to ship (Phase H gate).** Original G2's ~5% stress failure rate came from a wide-overlap double-dequeue race: worker A claimed/ran/released a descriptor, worker B arrived later with the same index from some queue path, dereferenced NULL `task_fn` → SIGSEGV. The Phase H fix (`runTask` `descriptor.state.cmpxchgStrong(.queued, .running, .acq_rel, .acquire)` at `pool.zig:763`) makes ghost duplicates fail the CAS and silently return. The defense is path-agnostic — whichever queue path was emitting duplicates (still tracked as a residual investigation), G2's timing change cannot revive the SIGSEGV.
6. **Why methodology lesson #9 (20×/100× stress) replaces the original 5×.** The original G2 plan's 5× `test-stress` gate passed at `cad50f1` and shipped. Bisect-grade 50–100 run validation later revealed the ~5% race rate. A 5% race appears 0–1× in 5 samples (22% chance of false-clean) but multiple times in 20+ samples. Re-land treats 20× ReleaseFast as the standing post-implementation correctness gate and 100× ReleaseFast as the final pre-merge gate — same discipline that closed Phase H.

---

## Performance Targets

| Metric | Baseline (`a75ed98`) | Target | Stretch |
|---|---:|---:|---:|
| `bench_tokio_parity/flood_1m` ops/s | 337K–340K (Phase H tip) | **≥ 365K** (+8% min) | ≥ 380K |
| `bench_tokio_parity/contended_spawn_8x` ops/s | (record in Task 1) | within −2% of baseline (no regression) | ≥ baseline |
| `test-stress` 20× ReleaseFast | pass | **20/20 pass** | 20/20 |
| `test-stress` 100× ReleaseFast (final gate) | pass | **100/100 pass** | 100/100 |

**Rollback floor:** `flood_1m` median of 5 runs < **355K** (less than +5% over Phase H baseline) → rollback the implementation commit. Keep nothing else changed; the regression tests are already on main.

---

## Mandatory A/B gates (both required)

1. **Pre-plan A/B (Task 2):** stub the `queued_tasks.load(.acquire)` line in the spin to a no-op. Measure flood_1m median of 5. Gate: ≥ **360K** (provides margin over the 337K Phase H baseline). If gate fails, the +9% target is not reproducible on current hardware/main — STOP, escalate before touching production code.
2. **Post-impl mechanism check (Task 7):** with the implementation in place and default `spin_before_park_iters = 0`, temporarily set the default to `128` and re-measure flood_1m. Gate: spin=0 and spin=128 within **±5%** of each other. If spin=128 outperforms spin=0 by more than 5%, the polless-spin loop is doing real work (cache prefetch? branch predictor warmup?) — escalate before merging the default=0 change. If they match, the spin is provably idle and default=0 is the right ship.

---

## File Structure

**Modified files:**

- `src/pool.zig` — `Core.idle()` at lines `856-863`. Remove the `if (self.counters.queued_tasks.load(.acquire) != 0) return;` line inside the spin loop body. Replace the comment block above the spin to document the re-land + Phase H interaction.
- `src/types.zig` — line `105`. Change `spin_before_park_iters: usize = 128,` to `spin_before_park_iters: usize = 0,` and update the doc comment.
- `docs/PERFORMANCE_TRACKING.md` — append a `## Phase G2 Re-Land` section with measured numbers and verdict.
- `benchmarks/results/baseline.json` — rebaseline `flood_1m` on ship (only if Task 9 ship gate passes). If file does not exist, skip.

**No new files.** **No new tests.** The two G2 regression tests already on main (`tests/unit.zig:481`, `tests/stress.zig:516`) cover the behavior; the new stress discipline is execution-time, not new code.

---

## Task Ordering Rationale

Re-land is a single-site change with three measurement checkpoints: pre-plan A/B (validates target), correctness gate (validates Phase H + the new stress discipline catch any race regression), post-impl mechanism A/B (validates the spin default=0 is the right ship). Tasks are sequenced so each intermediate state is independently measurable and recoverable:

1. Worktree + baseline measurement (records Phase H tip ops/s as the comparison floor)
2. Pre-plan A/B: stub the poll, measure, revert (validates ceiling exists on current main)
3. Implementation (one Edit in `src/pool.zig`, one Edit in `src/types.zig`)
4. Build + full unit suite
5. Stress 20× ReleaseFast (correctness gate; the methodology-lesson-#9 floor)
6. Bench measurement (median of 5 flood_1m + median of 3 contended_spawn_8x)
7. Post-impl mechanism A/B (spin=0 default vs spin=128 override)
8. Final stress 100× ReleaseFast (matches Phase H pre-merge discipline)
9. Ship decision: docs + commit, OR rollback to Task 9b

Between every measurement-bearing task: explicit `zig build -Doptimize=ReleaseFast` before invoking the binary. `zig build bench-tokio-parity` alone does not guarantee a rebuild (methodology lesson #8 — Phase G1 Task 3 vs Task 6 same-session discrepancy).

---

## Task 1: Worktree + baseline

**Files:** none modified. Measurement only.

- [ ] **Step 1: Create worktree on `feat/phase-g2-reland`**

```bash
cd /home/benji/src/devnw/zig/thread-pool
git worktree add ../thread-pool-phase-g2-reland -b feat/phase-g2-reland main
cd ../thread-pool-phase-g2-reland
```

Expected: new directory at `../thread-pool-phase-g2-reland`, on `feat/phase-g2-reland` at main tip `a75ed98` or later.

- [ ] **Step 2: Confirm we're on Phase H tip**

```bash
git log -1 --oneline
```

Expected: line begins `a75ed98 fix: merge Phase H` (or a later commit if main has advanced; the plan still applies).

- [ ] **Step 3: Force-rebuild the pre-change binary**

```bash
zig build -Doptimize=ReleaseFast
```

Expected: clean build, no errors.

- [ ] **Step 4: Record baseline `flood_1m` (median of 5)**

```bash
for i in 1 2 3 4 5; do ./zig-out/bin/bench-tokio-parity 2>&1 | grep -E "^flood_1m"; done
```

Record all 5 values to `/tmp/phase-g2-reland-baseline.txt`. Compute median. Expected range: 330K–345K (Phase H tip). Note both the median and the spread (max−min); large spread (> 15K) means the noise floor is wide and downstream gates need to account for it.

- [ ] **Step 5: Record baseline `contended_spawn_8x` (median of 3)**

```bash
for i in 1 2 3; do ./zig-out/bin/bench-tokio-parity 2>&1 | grep -E "^contended_spawn_8x"; done
```

Record values + median to `/tmp/phase-g2-reland-baseline.txt`. This is the floor for the no-regression check at Task 6.

- [ ] **Step 6: No commit**

Task 1 is measurement-only. `git status` should show clean tree. Proceed to Task 2.

---

## Task 2: Pre-plan A/B — stub the poll, measure, revert

**Files:**
- Modify (temporary, reverted at end of task): `src/pool.zig`

Goal: validate the +9% ceiling reproduces on current hardware against the Phase H tip. If it doesn't, the re-land target is not where memory says it is.

- [ ] **Step 1: Re-read the spin block at `src/pool.zig:856-863`**

Read lines 856–863 to confirm current shape matches expectations. Expected:

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

If actual content differs (e.g. the file has shifted lines), STOP and re-locate the spin block. The plan assumes this exact pre-state.

- [ ] **Step 2: Stub the poll line**

Use Edit to comment out the `queued_tasks` load only. Replace:

```zig
        while (spins < self.config.spin_before_park_iters) : (spins += 1) {
            if (self.counters.queued_tasks.load(.acquire) != 0) return;
            if (self.state.load(.acquire) != .running) return;
            std.atomic.spinLoopHint();
        }
```

with:

```zig
        while (spins < self.config.spin_before_park_iters) : (spins += 1) {
            // [G2 RE-LAND PRE-PLAN A/B — reverted at end of Task 2]
            // if (self.counters.queued_tasks.load(.acquire) != 0) return;
            if (self.state.load(.acquire) != .running) return;
            std.atomic.spinLoopHint();
        }
```

The `state` check and `spinLoopHint` remain. This is a temporary experiment.

- [ ] **Step 3: Force-rebuild**

```bash
zig build -Doptimize=ReleaseFast
```

Expected: clean build.

- [ ] **Step 4: Measure `flood_1m` (median of 5)**

```bash
for i in 1 2 3 4 5; do ./zig-out/bin/bench-tokio-parity 2>&1 | grep -E "^flood_1m"; done
```

Append all 5 values + median to `/tmp/phase-g2-reland-baseline.txt`, labeled `STUBBED`.

- [ ] **Step 5: Evaluate the gate**

Gate: stubbed median ≥ **360K** (provides ≥ 7% headroom over the typical 337K Phase H baseline; leaves room for the production version to land ≥ 365K).

- If gate passes: target is real on current main. Proceed to Task 3.
- If gate fails (stubbed median < 360K): STOP. Do not write production code. Possible reasons: (a) Phase H added cost that absorbed the headroom; (b) hardware/environment shifted; (c) noise floor too wide. Document findings in `/tmp/phase-g2-reland-baseline.txt` and escalate to the user.

- [ ] **Step 6: Revert the stub exactly**

Use Edit to restore the original block:

```zig
        while (spins < self.config.spin_before_park_iters) : (spins += 1) {
            if (self.counters.queued_tasks.load(.acquire) != 0) return;
            if (self.state.load(.acquire) != .running) return;
            std.atomic.spinLoopHint();
        }
```

- [ ] **Step 7: Force-rebuild and confirm clean revert**

```bash
zig build -Doptimize=ReleaseFast
git diff src/pool.zig
```

Expected: empty diff. The tree is back to Phase H tip behavior.

- [ ] **Step 8: No commit**

Task 2 is measurement-only. `git status` should be clean. Proceed to Task 3.

---

## Task 3: Implement the re-land change

**Files:**
- Modify: `src/pool.zig:856-863` (the spin block in `Core.idle`)
- Modify: `src/types.zig:105` (default `spin_before_park_iters`)

- [ ] **Step 1: Replace the spin block in `src/pool.zig`**

Use Edit to change the spin block at lines 856–863. From:

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

To:

```zig
    fn idle(self: *Core, worker_index: usize) void {
        var worker = &self.workers[worker_index];
        // Phase G2 (re-land 2026-04-13): no `counters.queued_tasks` poll.
        // The submit path writes that line with .seq_cst on every submit;
        // 56 workers × spin_iters shared loads per park cycle dominated
        // cross-core traffic on the line. Removing the poll lifted
        // flood_1m ~9% in the original G2 (commit c335189 / 60ad076).
        //
        // Handshake correctness is unaffected: the mutex-guarded SC
        // reload at `worker.is_parked.store(1, .seq_cst)` below is the
        // actual lost-wakeup guard (see comment block at the park site).
        // The spin-poll was a latency shortcut, not a correctness mechanism.
        //
        // The original G2 also added an end-of-spin local-work probe
        // (lifo_slot, local_queue.len, inject_queue.len). Post-impl A/B
        // (commit 60ad076) showed the probe was inert — same probability-
        // of-engagement failure as Phase F1's short-spin. Re-land omits
        // the probe and drops `spin_before_park_iters` default to 0
        // (in src/types.zig); a polless spin is pure CPU burn so the
        // default-off knob preserves the spin only for explicit opt-ins
        // (e.g. the existing stress tests at tests/stress.zig:75,290,528).
        //
        // Phase H's `runTask` state-CAS gate (pool.zig:763) defends
        // against the duplicate-emission race that the original G2
        // timing change unmasked — see docs/PERFORMANCE_TRACKING.md
        // § Phase H. Path-agnostic defense; this re-land cannot revive
        // the SIGSEGV that forced the original revert.
        var spins: usize = 0;
        while (spins < self.config.spin_before_park_iters) : (spins += 1) {
            if (self.state.load(.acquire) != .running) return;
            std.atomic.spinLoopHint();
        }
```

The `if (self.state.load(.acquire) != .running) return;` line that immediately follows the loop (originally line 865) is **preserved unchanged**. Do not remove it.

- [ ] **Step 2: Verify the pool.zig edit**

Read the resulting file at the changed range (around lines 856–895) and confirm:

- The `while` loop body contains exactly two statements: the `state` acquire check and `spinLoopHint`.
- No `counters.queued_tasks.load` appears inside the `while` block.
- The post-loop `state` check at the original line 865 is still present.
- The SC park handshake block (the `worker.park_mutex.lock();` block starting around line 869) is untouched.

- [ ] **Step 3: Update `src/types.zig:105`**

Use Edit to change:

```zig
    spin_before_park_iters: usize = 128,
```

to:

```zig
    /// Phase G2 (re-land 2026-04-13): default 0. Once the spin's
    /// `queued_tasks` poll was removed (the dominant cross-core read on
    /// that cacheline), the spin body became pure CPU burn. Setting this
    /// to a non-zero value forces a `spinLoopHint` delay loop with only
    /// a per-iter `state` check — useful for stress tests that need to
    /// reproduce the polless-spin handshake (see tests/stress.zig:516,
    /// :75, :290) but not for normal workloads.
    spin_before_park_iters: usize = 0,
```

- [ ] **Step 4: Build (debug + release)**

```bash
zig build
zig build -Doptimize=ReleaseFast
```

Expected: both clean. If `validate()` in `src/types.zig` enforces a non-zero `spin_before_park_iters`, the debug build will fail — in that case, locate the `validate()` constraint, confirm whether it's intentional (it should not be — the original G2 final form set the default to 0 in `60ad076` without breaking validate), and remove the constraint with a one-line edit. Make a note in the commit message if the validate change was needed.

- [ ] **Step 5: Commit**

```bash
git add src/pool.zig src/types.zig
git commit -m "perf: phase g2 re-land - remove idle-spin queued_tasks poll

The worker idle-spin hammered counters.queued_tasks.load(.acquire) once
per iteration × spin_before_park_iters × worker_count. The submit path
writes that same cacheline with .seq_cst on every submit, so 56 workers
× shared loads per park cycle was the dominant cross-core traffic on
the line. Removing the poll lifts flood_1m ~9% (matches original G2
measurement at c335189 / 60ad076).

Default spin_before_park_iters drops to 0 because, with the poll gone,
the spin body is pure CPU burn (A/B-confirmed in 60ad076 — the original
end-of-spin local-work probe was inert under default config).

Phase H's runTask state-CAS gate defends against the duplicate-emission
race that the original G2 timing change unmasked, so the re-land is
safe under the Phase H discipline (20× test-stress at ReleaseFast as
the standing correctness gate, 100× as final pre-merge)."
```

---

## Task 4: Build + unit-suite gate

**Files:** none. Test-only.

- [ ] **Step 1: Force-rebuild both modes**

```bash
zig build
zig build -Doptimize=ReleaseFast
```

Expected: both clean.

- [ ] **Step 2: Run the full unit suite**

```bash
zig build test 2>&1 | tail -40
```

Expected: all tests pass. Pay particular attention to:

- `tests/unit.zig:481` — `phase g2: worker returns from idle when lifo slot filled during spin window`. This test sets `spin_before_park_iters = 10_000` explicitly and asserts wake latency < 1 ms. With the poll removed and no probe, latency comes from spin completion (~10 µs) + SC handshake observing `queued_tasks > 0` and skipping `park_cond.wait`. Should pass comfortably.
- Any test that does **not** explicitly set `spin_before_park_iters` now runs with default 0 — verify none of those rely on the spin's prior 128-iter behavior. If a test newly fails after this change with a wake-latency or hang signature, that test was implicitly depending on the spin window; either set `spin_before_park_iters = 128` explicitly in that test or fix the test's assumption.

- [ ] **Step 3: If any failure, decide**

- A timing-sensitive test failure that's clearly an artifact of `default = 0` → set the test's config explicitly and re-run. Commit as a separate test-config commit before proceeding.
- A correctness failure (assertion about completion count, queue state, or shutdown) → STOP. Roll back to Task 9b. Phase H plus the 20× discipline are supposed to catch this in Task 5; a failure here means the regression is more severe.

- [ ] **Step 4: No commit unless step 3 needed a test-config edit**

---

## Task 5: Stress 20× ReleaseFast (correctness gate)

**Files:** none. Test-only.

This is the methodology-lesson-#9 floor. Original G2 shipped at 5×; the latent race fired ~5% of the time and slipped through. 20× ReleaseFast gives > 99% probability of catching a 5% race rate.

- [ ] **Step 1: Force-rebuild release**

```bash
zig build -Doptimize=ReleaseFast
```

- [ ] **Step 2: Run 20 consecutive ReleaseFast stress iterations**

```bash
for i in $(seq 1 20); do
  echo "=== stress run $i/20 ==="
  zig build test-stress -Doptimize=ReleaseFast 2>&1 | tail -3 | sed 's/^/  /'
done | tee /tmp/phase-g2-reland-stress20.log
```

Expected: 20/20 PASS. Specifically `tests/stress.zig:516` (`phase g2: aggressive spin flood - no lost wakeups`) must pass every time — that test sets `spin_before_park_iters = 4096` explicitly to drive the polless-spin handshake under load.

- [ ] **Step 3: Inspect the log for any failure or hang**

```bash
grep -E "FAIL|panic|SIGSEGV|deadlock|test failed" /tmp/phase-g2-reland-stress20.log || echo "clean"
```

Expected: `clean`. Any FAIL/panic/SIGSEGV/deadlock pattern means the re-land is unsafe; STOP and go to Task 9b (rollback). This is the gate the original G2 missed.

- [ ] **Step 4: If gate passes, commit log artifact**

```bash
mkdir -p docs/perf-runs
cp /tmp/phase-g2-reland-stress20.log docs/perf-runs/phase-g2-reland-stress20.log
git add docs/perf-runs/phase-g2-reland-stress20.log
git commit -m "test(phase g2 reland): record 20/20 ReleaseFast stress pass"
```

If `docs/perf-runs/` is not a convention in this repo (check with `ls docs/` first; if not present, skip the artifact commit and just keep the log in `/tmp` for the Task 9 ship summary).

---

## Task 6: Bench measurement

**Files:** none. Measurement only.

- [ ] **Step 1: Force-rebuild release**

```bash
zig build -Doptimize=ReleaseFast
```

- [ ] **Step 2: Measure `flood_1m` (median of 5)**

```bash
for i in 1 2 3 4 5; do ./zig-out/bin/bench-tokio-parity 2>&1 | grep -E "^flood_1m"; done
```

Append all 5 values + median to `/tmp/phase-g2-reland-baseline.txt`, labeled `IMPLEMENTED`.

- [ ] **Step 3: Measure `contended_spawn_8x` (median of 3)**

```bash
for i in 1 2 3; do ./zig-out/bin/bench-tokio-parity 2>&1 | grep -E "^contended_spawn_8x"; done
```

Append all 3 values + median to `/tmp/phase-g2-reland-baseline.txt`, labeled `IMPLEMENTED`.

- [ ] **Step 4: Evaluate against targets**

- Primary gate: `flood_1m` median ≥ **365K** (≥ +8% over Task 1 baseline).
- Floor gate: `flood_1m` median ≥ **355K** (≥ +5% over Task 1 baseline). Below this → rollback.
- No-regression gate: `contended_spawn_8x` median within −2% of Task 1 baseline. Below that → rollback.

Record decision (`PASS` / `FLOOR` / `FAIL`) in `/tmp/phase-g2-reland-baseline.txt`.

- [ ] **Step 5: No commit**

---

## Task 7: Post-impl mechanism A/B (default vs spin=128)

**Files:**
- Modify (temporary, reverted at end of task): `src/types.zig:105`

Goal: confirm the choice to default `spin_before_park_iters = 0` is correct. If forcing the spin back to 128 outperforms 0 by > 5%, the spin is doing real work (cache prefetch, branch predictor warmup) that the original G2 A/B missed — escalate before merging the default change.

- [ ] **Step 1: Default (spin=0) measurement is already in `/tmp/phase-g2-reland-baseline.txt` from Task 6**

Note the labeled `IMPLEMENTED` median.

- [ ] **Step 2: Temporarily set `spin_before_park_iters = 128`**

Use Edit on `src/types.zig:105` to change:

```zig
    spin_before_park_iters: usize = 0,
```

to:

```zig
    spin_before_park_iters: usize = 128, // [G2 RE-LAND A/B — reverted at end of Task 7]
```

Keep the doc comment above unchanged.

- [ ] **Step 3: Force-rebuild**

```bash
zig build -Doptimize=ReleaseFast
```

- [ ] **Step 4: Measure spin=128 `flood_1m` (median of 5)**

```bash
for i in 1 2 3 4 5; do ./zig-out/bin/bench-tokio-parity 2>&1 | grep -E "^flood_1m"; done
```

Append all 5 values + median to `/tmp/phase-g2-reland-baseline.txt`, labeled `SPIN_128`.

- [ ] **Step 5: Revert the default change**

Use Edit to restore:

```zig
    spin_before_park_iters: usize = 0,
```

```bash
zig build -Doptimize=ReleaseFast
git diff src/types.zig  # expect empty
```

- [ ] **Step 6: Evaluate the gate**

Compute `delta = (spin_128_median − spin_0_median) / spin_0_median`.

- `|delta| ≤ 5%` → spins are equivalent. Default = 0 is the correct ship. Proceed to Task 8.
- `delta > +5%` (spin=128 noticeably faster) → the polless-spin loop is doing real work. Escalate to user before proceeding; possible follow-up is `spin_before_park_iters` default = some non-zero value (e.g. 32) chosen empirically. Do NOT change the default in this plan.
- `delta < −5%` (spin=128 noticeably slower) → expected — spin=0 wins because polless spin is wasted CPU. Default = 0 is correct, ship harder. Proceed.

- [ ] **Step 7: No commit**

---

## Task 8: Final stress 100× ReleaseFast (pre-merge gate)

**Files:** none. Test-only.

This matches the Phase H discipline: 100× ReleaseFast immediately before merge. Catches the long tail of ~1% race rates that 20× cannot rule out.

- [ ] **Step 1: Force-rebuild release one more time**

```bash
zig build -Doptimize=ReleaseFast
```

- [ ] **Step 2: Run 100 consecutive iterations**

```bash
for i in $(seq 1 100); do
  result=$(zig build test-stress -Doptimize=ReleaseFast 2>&1 | tail -3)
  if echo "$result" | grep -qE "FAIL|panic|SIGSEGV"; then
    echo "FAIL at run $i"
    echo "$result"
    break
  fi
  if (( i % 10 == 0 )); then echo "  $i/100 OK"; fi
done | tee /tmp/phase-g2-reland-stress100.log
```

Expected: `100/100 OK`-style trail in the log. This loop will take ~30–60 minutes depending on per-run duration; check periodically.

- [ ] **Step 3: Verify no failures**

```bash
grep -E "FAIL|panic|SIGSEGV|deadlock" /tmp/phase-g2-reland-stress100.log || echo "100/100 clean"
```

Expected: `100/100 clean`. Any failure → rollback (Task 9b), regardless of how many iterations passed before it. A rare race is still a race.

- [ ] **Step 4: Archive the log**

If `docs/perf-runs/` exists from Task 5:

```bash
cp /tmp/phase-g2-reland-stress100.log docs/perf-runs/phase-g2-reland-stress100.log
git add docs/perf-runs/phase-g2-reland-stress100.log
git commit -m "test(phase g2 reland): record 100/100 ReleaseFast pre-merge stress"
```

Otherwise keep in `/tmp` for the Task 9 ship summary.

---

## Task 9: Ship — docs + commit

**Files:**
- Modify: `docs/PERFORMANCE_TRACKING.md`
- Modify (if it exists): `benchmarks/results/baseline.json`
- Update: `/home/benji/.claude/projects/-home-benji-src-devnw-zig-thread-pool/memory/project_phase_status.md` (auto-memory; mark G2 as shipped)

Execute Task 9 only if **all** of the following hold:
- Task 2 pre-plan A/B passed (stubbed median ≥ 360K)
- Task 5 stress 20× passed (20/20 ReleaseFast)
- Task 6 bench passed (flood_1m ≥ 365K, contended_spawn_8x within −2%)
- Task 7 mechanism A/B passed (|spin_0 − spin_128| ≤ 5%, OR spin_0 wins)
- Task 8 final stress 100× passed (100/100 ReleaseFast)

If any failed, go to Task 9b (rollback) instead.

- [ ] **Step 1: Append a `## Phase G2 Re-Land` section to `docs/PERFORMANCE_TRACKING.md`**

Read the existing file to find the right insertion point (probably after the Phase H section). Then append:

```markdown
## Phase G2 Re-Land: Idle-Spin Poll Removal (shipped 2026-04-13)

**Status:** Shipped. Original Phase G2 (commit `c335189` + cleanup `60ad076`) was reverted because the timing change unmasked a latent double-dequeue race in `nextTask`. Phase H (`a75ed98`) closed that race via state-CAS at `runTask`; the re-land is unblocked.

**Change:** `src/pool.zig:Core.idle()` no longer polls `counters.queued_tasks.load(.acquire)` inside the spin loop. `src/types.zig` default `spin_before_park_iters` drops from `128` to `0` — the polless spin is pure CPU burn at default config; non-zero values remain available as a knob for stress tests that exercise the polless-spin handshake (e.g. `tests/stress.zig:516` at `4096`).

**Hypothesis:** Worker idle-spin polled `counters.queued_tasks.load(.acquire)` `spin_before_park_iters` times per park cycle on a cacheline the submitter writes `.seq_cst` on every submit. 56 workers × 128 iters × shared loads per park cycle dominated cross-core traffic on the line. Removing the poll eliminates the dominant read traffic.

### Measured (median of 5, ReleaseFast, 56-core host)

| Metric | Baseline (`a75ed98` Phase H tip) | G2 Re-Land default (spin=0) | G2 Re-Land spin=128 A/B |
|---|---:|---:|---:|
| `flood_1m` ops/s | {baseline_flood_median} | **{impl_flood_median}** | {spin128_flood_median} |
| `contended_spawn_8x` ops/s | {baseline_contended_median} | {impl_contended_median} | — |
| `test-stress` 20× ReleaseFast | pass | **20/20** | — |
| `test-stress` 100× ReleaseFast | pass | **100/100** | — |

Default `flood_1m` is **{delta_pct}** above Phase H baseline. Default vs spin=128 delta is **{ab_delta_pct}** — within ±5% confirms the polless spin is idle CPU and default=0 is the right ship.

**Correctness:** Phase H's `runTask` state-CAS gate (`pool.zig:763`) is path-agnostic — it makes ghost duplicate emissions silent rather than SIGSEGVs, regardless of which queue path emits them. The G2 timing change cannot revive the original revert reason. Methodology lesson #9 (20× / 100× ReleaseFast stress, replacing the original 5×) was the gate that would have caught the original G2 race; both gates passed for the re-land.

See `docs/superpowers/plans/2026-04-13-phase-g2-reland.md`.
```

Fill in every `{…}` placeholder with the actual measurements from `/tmp/phase-g2-reland-baseline.txt`.

- [ ] **Step 2: Rebaseline `benchmarks/results/baseline.json` (if it exists)**

```bash
ls benchmarks/results/baseline.json 2>/dev/null && echo "exists" || echo "skip"
```

If `exists`: open and update the `flood_1m` entry to the new G2 default median. Otherwise skip.

- [ ] **Step 3: Update auto-memory `project_phase_status.md`**

Edit `/home/benji/.claude/projects/-home-benji-src-devnw-zig-thread-pool/memory/project_phase_status.md` to:

- Add Phase G2 Re-Land to the "Shipped" list with date and commit.
- Remove "Phase G2 (idle-spin `queued_tasks` poll removal): +9% win was real, but…" entry from the "Reverted as negative results" list, OR rewrite it as "Phase G2 (original): reverted, see Phase G2 Re-Land 2026-04-13."
- Update "Next-action priority" to drop step 1 (G2 re-land) and renumber.
- Update the "As of" line and main-tip commit hash.

- [ ] **Step 4: Commit docs**

```bash
git add docs/PERFORMANCE_TRACKING.md benchmarks/results/baseline.json 2>/dev/null || git add docs/PERFORMANCE_TRACKING.md
git commit -m "docs(phase g2 reland): close out — measured +N% on flood_1m, 100/100 stress"
```

(Replace `+N%` with the actual measured delta.)

- [ ] **Step 5: Final summary for reviewer**

Print to stdout (not committed) a 4-line summary suitable for a PR description:

```
Phase G2 Re-Land shipped:
- flood_1m: {baseline} → {impl} ops/s (+{delta}%, A/B spin=128 within ±5% of default)
- contended_spawn_8x: {baseline} → {impl} ops/s (no regression)
- Stress: 20/20 + 100/100 ReleaseFast (Phase H CAS gate defends; methodology lesson #9 satisfied)
- Branch feat/phase-g2-reland ready for merge to main.
```

---

## Task 9b: Rollback path (executed only on gate failure)

**Files:**
- Reset: `src/pool.zig`, `src/types.zig`
- Append negative-result section: `docs/PERFORMANCE_TRACKING.md`

Execute this task only if any Task 4, 5, 6, 7, or 8 gate failed.

- [ ] **Step 1: Identify which commits to drop**

```bash
git log --oneline feat/phase-g2-reland ^main
```

The Task 3 implementation commit is the only behavior-change commit. The optional Task 5 / Task 8 stress-log artifact commits (if present) are documentation; they can stay or be dropped, your call.

- [ ] **Step 2: Drop the implementation commit**

If Task 3 is the only commit on the branch:

```bash
git reset --hard main
```

If there are stress-log artifact commits to keep, use:

```bash
git rebase -i main
```

and mark the `perf: phase g2 re-land` line as `drop`.

- [ ] **Step 3: Confirm clean revert**

```bash
git diff main -- src/pool.zig src/types.zig  # expect empty
zig build -Doptimize=ReleaseFast
zig build test
zig build test-stress -Doptimize=ReleaseFast
```

Expected: all green; tree behaves identically to main.

- [ ] **Step 4: Append negative-result section to `docs/PERFORMANCE_TRACKING.md`**

```markdown
## Phase G2 Re-Land: Idle-Spin Poll Removal (negative result — REVERTED)

**Status:** Reverted. Re-land attempt 2026-04-13.

**Which gate failed:** [Task 4 unit | Task 5 stress 20× | Task 6 bench floor | Task 6 contended regression | Task 7 mechanism A/B | Task 8 stress 100×]

**Measured:** [paste the relevant block from /tmp/phase-g2-reland-baseline.txt and /tmp/phase-g2-reland-stress*.log]

**Root cause (best current theory):** [one paragraph — correctness failure under Phase H CAS suggests a NEW race path G2 timing exposes; bench floor failure means the +9% ceiling closed in the Phase H change; mechanism A/B failure means the spin loop is load-bearing in a way the original G2 missed]

**Next direction:** [either: re-attempt with adjusted approach, or: pivot to G3 (`submitted.fetchAdd` contention, +28% ceiling) since the direct G2 path is closed]

See `docs/superpowers/plans/2026-04-13-phase-g2-reland.md`.
```

- [ ] **Step 5: Commit the rollback docs + update auto-memory**

```bash
git add docs/PERFORMANCE_TRACKING.md
git commit -m "docs(phase g2 reland): negative result — [failed gate name]"
```

Also update `/home/benji/.claude/projects/-home-benji-src-devnw-zig-thread-pool/memory/project_phase_status.md` — append Phase G2 Re-Land to the reverted list with date + failed gate, and bump the next-action priority to G3 or wake-scan.

- [ ] **Step 6: Branch handling**

Leave `feat/phase-g2-reland` in place (with the rollback docs commit if you committed one). The branch represents "documented negative result on the re-land path."

---

## Self-Review Checklist

**1. Spec coverage:** No separate spec. Design rationale embedded above (6 numbered points + "What changed since the original Phase G2" comparison table). Each design decision traces to either A/B data already in `docs/PERFORMANCE_TRACKING.md`, the methodology entries in `feedback_perf_profiling.md` (lessons #5, #8, #9, #10), or the Phase H CAS-gate defense at `pool.zig:763`. Complete.

**2. Placeholder scan:** No "TBD" / "implement later" / "handle edge cases". Every code edit shows the exact before/after. The ship-docs section uses `{…}` placeholders for measured values; those are explicitly flagged in Step 1 of Task 9.

**3. Type consistency:** `spin_before_park_iters` is `usize` in `src/types.zig:105` — preserved. `counters.queued_tasks` is `std.atomic.Value(u64)` accessed via `.load(.acquire)` — referenced consistently. `Core.idle` signature unchanged. `LIFO_SLOT_EMPTY` and `lifo_slot` are *not* referenced in the re-land (the probe is omitted) — original G2's dependency on them is gone, so no stale references.

**4. Test inventory:** The two G2 regression tests (`tests/unit.zig:481` and `tests/stress.zig:516`) are already on main and continue to apply. The plan adds no new tests; the new discipline is execution-time (20× and 100× ReleaseFast), not new code.

**5. Cross-task name consistency:** Branch `feat/phase-g2-reland` (not `feat/phase-g2-queued-tasks-poll`, which is the original-G2 branch left in place for reference). Worktree `../thread-pool-phase-g2-reland`. Baseline scratch file `/tmp/phase-g2-reland-baseline.txt`. Stress logs `/tmp/phase-g2-reland-stress20.log` and `/tmp/phase-g2-reland-stress100.log`. Used consistently across all tasks.

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-04-13-phase-g2-reland.md`. Two execution options:

**1. Subagent-Driven (recommended)** — dispatch a fresh subagent per task with two-stage review between tasks. Use `superpowers:subagent-driven-development`. Particularly suited to this plan because Task 5 (20× stress) and Task 8 (100× stress) are long-running and benefit from isolated subagent context.

**2. Inline Execution** — execute tasks in this session using `superpowers:executing-plans`, batch execution with checkpoints. Suitable if you want to interleave manual decisions at gate evaluations.

Which approach?
