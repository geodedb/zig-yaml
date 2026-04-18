# Go-gap round 3 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reclaim the `contended_spawn_8x` / `contended_cpu_10us` throughput ceiling that regressed −10.10% / −5.28% when round 1 Phase 3 appended a 136-byte `DescCache` to the `Worker` struct, without surrendering the `nested_fanout_4x` +81.26% win that same field unlocked.

**Architecture:** Extract the per-worker `DescCache` out of `Worker` into a pool-level parallel slice `Core.worker_desc_caches: []DescCache` that mirrors the existing `Core.desc_caches` layout for per-submitter caches. `Worker` returns to the pre-Phase-3 size of 1912 B so the cacheline pressure that regressed submitter-thread throughput disappears, while cache-hit routing remains a single array-indexed deref (one extra indirection vs the field access — negligible next to the global-freelist CAS it avoids).

**Tech Stack:** Zig 0.16.0, ReleaseFast bench binary, Vyukov MPMC `BoundedRing`, SPSC `DescCache` (32-entry LIFO, single-writer), `bench-runtime-compare` harness for A/B measurement.

**Target scenarios (north star = Go runtime):**

| Scenario              | Go gap at HEAD (`a666ec3`) | Plan target                         |
|-----------------------|:---------------------------|:------------------------------------|
| `contended_spawn_8x`  | 2.67× behind Go            | reclaim ≥ +5 % on this leg alone    |
| `contended_cpu_10us`  | 1.43× behind Go            | reclaim ≥ +3 % on this leg alone    |
| `nested_fanout_4x`    | 2.62× behind Go            | **do-no-harm**: must stay ≥ −3 %    |

**Out-of-scope (closed planes, do not re-attempt):**

- `lifo_slot` rotate semantics on worker-context submit (round 2 Phase 1 closed).
- Batched `submitBatch` fast path via `tryPushBottomN` combined with LIFO rotate (round 2 Phase 2 closed).
- Shared parked-workers bitmap (iter 7).
- Single-worker `notifySubmits` scan (iter 8).
- `notifySubmits` cacheline-isolation (iter 9).
- `shouldExit` off the hotpath (iter 10).
- Per-worker `active_tasks` shard (iter 11).
- Socket-aware worker pinning (Slice 3a).
- Mid-struct reordering of `Worker` fields (iter-11 discipline).
- Growing `Worker` struct further (feedback memory `worker_struct_size_tradeoff`).

---

## File Structure

| Path                                                       | Responsibility                                                            |
|------------------------------------------------------------|---------------------------------------------------------------------------|
| `src/pool.zig`                                             | **Modify**: remove `Worker.desc_cache` field; add `Core.worker_desc_caches: []DescCache`; route `enqueuePush` through the slice; drain on deinit. |
| `tests/unit.zig`                                           | **Modify**: update the four `Worker.desc_cache` tests to inspect `pool.worker_desc_caches[wi]`; update the worker-struct size ceiling assertion. |
| `docs/performance/2026-04-17-go-gap-round3/FINAL.md`       | **Create**: paired-A/B runsheet, kill-gate evaluation, outcome (LAND or REVERT + closed plane). |
| `docs/performance/2026-04-17-go-gap-round3/runs/phase1-ab.md` | **Create**: raw A/B numbers, median-of-10, binary SHA256s. |
| `CLAUDE.md`                                                | **Modify (conditional on land)**: refresh "Current Direct Runtime Snapshot" table with new numbers. |
| `docs/RUNTIME_COMPARISON.md`                               | **Modify (conditional on land)**: refresh current-snapshot table. |
| `benchmarks/results/runtime-comparison-latest.json`        | **Modify (conditional on land)**: new post-land sweep. |

The change is surgical: one field moves from struct to slice. All public API surface stays identical. `DescCache` itself does not change — its invariants (SPSC, 32-entry LIFO, no atomics on push/pop) hold before and after.

---

## Measurement Protocol

Identical to round 2:

- Zig 0.16.0, `-Doptimize=ReleaseFast`, 56 workers, balanced-order same-session paired A/B.
- `bench-runtime-compare` harness, `--samples 11 --warmup-discard 1` → 10 retained samples per leg.
- Median = mean of 5th and 6th sorted samples.
- Binary SHA256 recorded for each leg; legs A and B must hash differently.
- Run interleaved A B A B … for 10 pairs to control for thermal drift.
- A leg = `HEAD` (pre-change, currently `a666ec3`-equivalent).
- B leg = `HEAD + plan Phase 1`.

**Kill gate (all must hold for PHASE 1 to land):**

| Scenario              | Direction | Threshold |
|-----------------------|-----------|-----------|
| `contended_spawn_8x`  | Δ% B–A    | ≥ **+5 %**  |
| `contended_cpu_10us`  | Δ% B–A    | ≥ **+3 %**  |
| `nested_fanout_4x`    | Δ% B–A    | ≥ −3 %    |
| `flood_1m`            | Δ% B–A    | ≥ −3 %    |
| `cpu_work_10us`       | Δ% B–A    | ≥ −3 %    |
| `cpu_work_100us`      | Δ% B–A    | ≥ −3 %    |
| `burst_drain_burst`   | Δ% B–A    | ≥ −3 %    |
| `mixed_fast_slow`     | Δ% B–A    | ≥ −3 %    |

Both primary targets must individually clear their gate. A win on only one target + near-gate regression on the other **is not enough**: revert instead.

---

## Task 0: Establish baseline at HEAD

**Files:** none modified.

- [ ] **Step 1: Confirm working tree is clean and HEAD is the post-revert commit**

```bash
git status --short
git log -1 --oneline
```

Expected: `git status` empty, HEAD at a commit whose code is byte-identical to `a666ec3` (round 1 FINAL). Verify with:

```bash
git diff a666ec3 HEAD -- src/ tests/ benchmarks/runtime_compare_zig.zig benchmarks/bench_runtime_common.zig
```

Expected: empty diff.

- [ ] **Step 2: Record HEAD SHA and binary hash for the A-leg reference**

```bash
git rev-parse HEAD | tee /tmp/round3-A-sha.txt
zig build bench-runtime-compare -Doptimize=ReleaseFast
sha256sum zig-out/bin/bench-runtime-compare | tee /tmp/round3-A-bin.txt
```

Keep both files for the FINAL runsheet.

- [ ] **Step 3: Pre-commit clean check passes**

```bash
zig build test-all --summary all
```

Expected: all tests green. If anything fails, stop — the plan cannot start on a red tree.

---

## Task 1: Add failing test for externalised per-worker DescCache layout

This task locks the invariant in a test before touching production code, so the refactor cannot accidentally change observable semantics.

**Files:**

- Modify: `tests/unit.zig` (add one test ~before the existing `"pool.deinit drains per-worker desc_caches"` test at `tests/unit.zig:1649`)

- [ ] **Step 1: Add test that verifies the per-worker DescCache lives on `pool.worker_desc_caches[wi]`**

Append this test to `tests/unit.zig`, placing it directly before the existing `test "pool.deinit drains per-worker desc_caches"` block:

```zig
test "per-worker desc_caches live on pool, not inside Worker" {
    // Round 3: the per-worker DescCache was moved out of the `Worker`
    // struct and into a pool-level slice (`Core.worker_desc_caches`),
    // mirroring the submitter layout (`Core.desc_caches`). This test
    // pins the invariant: worker-context submits must fill the slice
    // entry, and `drainWorkerDescCachesForTesting` must empty it.
    const allocator = std.testing.allocator;
    var pool = try thread_pool.ThreadPool.init(allocator, .{
        .worker_count = 4,
        .queue_capacity = 256,
        .local_queue_capacity = 64,
    });
    defer pool.deinit();

    // Submit from a worker thread so the enqueue path takes the
    // per-worker DescCache branch. The task captures its worker index
    // into a shared slot we read after join.
    const Ctx = struct {
        sink: std.atomic.Value(usize) = std.atomic.Value(usize).init(std.math.maxInt(usize)),
        fn task(raw: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            // Submit four child tasks from inside this worker context so the
            // per-worker DescCache gets populated by the batch refill path.
            const inner = struct {
                fn noop(_: *anyopaque) void {}
            };
            var dummy: u8 = 0;
            var i: usize = 0;
            while (i < 4) : (i += 1) {
                _ = thread_pool.current_pool.?.submit(inner.noop, &dummy, .{}) catch {};
            }
            self.sink.store(0, .release);
        }
    };
    var ctx = Ctx{};
    _ = try pool.submit(Ctx.task, &ctx, .{});

    // Drain and verify the cache array is reachable on the pool, not on
    // the Worker struct. This is a compile-time check via the field
    // name — if the field is renamed or moved back into Worker, the
    // test fails to compile.
    while (ctx.sink.load(.acquire) == std.math.maxInt(usize)) {
        std.Thread.sleep(1 * std.time.ns_per_ms);
    }
    pool.drainWorkerDescCachesForTesting();
    try std.testing.expect(@hasField(thread_pool.ThreadPool.Core, "worker_desc_caches"));
}
```

- [ ] **Step 2: Run the new test and confirm it fails**

```bash
zig build test -- --test-filter "per-worker desc_caches live on pool"
```

Expected: FAIL — either because `thread_pool.ThreadPool.Core` does not publicly expose `worker_desc_caches`, or because the field does not exist yet. Both are acceptable failures — they prove the test is sensitive to the refactor.

> **Note:** if `thread_pool.ThreadPool.Core` is not publicly reachable (it's a private inner struct today), change the `@hasField` line to probe whatever symbol the refactor chooses to expose for the drain hook (e.g., a compile-time check on the type of a new test-only getter). The invariant to pin is that the cache is NOT `@hasField(Worker, "desc_cache")`. Update the test accordingly in Task 2 when the new field name is chosen.

- [ ] **Step 3: Commit the failing test**

```bash
git add tests/unit.zig
git commit -m "$(cat <<'EOF'
test(pool): failing invariant for externalised per-worker DescCache (round 3)

Pins the structural change coming in round 3 Phase 1: the per-worker
DescCache moves out of the `Worker` struct into a pool-level slice
`Core.worker_desc_caches`. Test fails until Task 2 lands the refactor.

Refs: docs/superpowers/plans/2026-04-17-go-gap-round3.md

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Move `desc_cache` from `Worker` to `Core.worker_desc_caches`

This is the core refactor. One field moves from struct to slice; all five call sites update.

**Files:**

- Modify: `src/pool.zig`
  - `Worker` struct definition (`src/pool.zig:286-378`) — remove `desc_cache` field.
  - `Worker` comptime size assertion (`src/pool.zig:355-377`) — update ceiling comment to reflect the restored 1912-byte size.
  - `Core` struct (`src/pool.zig:~518`) — add `worker_desc_caches: []DescCache = &.{}` directly below `desc_caches`.
  - `Core.init` (`src/pool.zig:~754-756`) — allocate `worker_desc_caches` and zero-init after `desc_caches`.
  - `Core.enqueuePush` (`src/pool.zig:1337-1347`) — change `w.desc_cache.tryPop()` / `w.desc_cache.push(...)` to `self.worker_desc_caches[wi].tryPop()` / `self.worker_desc_caches[wi].push(...)`.
  - `Core.drainWorkerDescCaches` (`src/pool.zig:2466-2473`) — iterate `self.worker_desc_caches[0..self.init_worker_count]` instead of iterating `self.workers[]` and touching `.desc_cache`.
  - `Core.deinitOwned` (`src/pool.zig:~2498`) — free `worker_desc_caches` after `desc_caches` with `recordOwnedFree`.

- Modify: `tests/unit.zig`
  - `"Worker struct is within the 4096-byte ceiling post-desc_cache"` at `tests/unit.zig:1593` — update the assertion and comment to reflect the 1912-byte restored size (keep the 4096-byte ceiling for future-proofing; tighten the EXPECTED-EQUAL to 1912 in a second assertion so a silent regrowth is caught).
  - `"worker-spawned task consumes from per-worker DescCache"` at `tests/unit.zig:1607` — change the test's inspection of the cache to read from the pool-level slice instead of `worker.desc_cache`.
  - `"pool.deinit drains per-worker desc_caches"` at `tests/unit.zig:1649` — same update: inspect `pool.worker_desc_caches_for_testing()[wi]` (or equivalent getter) rather than `worker.desc_cache`.

- [ ] **Step 1: Remove the `desc_cache` field from `Worker`**

Edit `src/pool.zig:344-353`. Delete these lines:

```zig
    /// Go-gap contended Slice 2-W: per-worker DescCache.
    ///
    /// Appended AT THE END of `Worker` to preserve existing field offsets
    /// — the iter-11 `active_tasks` shard regressed flood_1m_batched
    /// -4.26% and contended_spawn_8x_batched -9.72% purely because
    /// inserting a field mid-struct shifted other field offsets and
    /// disrupted cache-line layout. Task 3.2 wires this cache into the
    /// worker-side descriptor acquire path; Task 3.3 drains it back to
    /// the freelist on pool deinit.
    desc_cache: DescCache = .{},
```

- [ ] **Step 2: Update the `Worker` size comptime assertion**

In the same struct at `src/pool.zig:355-377`, replace the existing comment about the 2048 B growth with a note that round 3 extracted the cache back out. Tighten the assertion:

```zig
    comptime {
        // OBSERVABILITY-PIVOT / R-06: `Worker` is a plain `struct`, so Zig
        // may reorder its fields. We therefore lock size-bounded
        // invariants rather than absolute offsets. See
        // `docs/performance/LAYOUT_OFFSETS.md`.
        //
        //   a. `park_mutex` alignment is at least its natural atomic-
        //      state word size.
        //   b. `Worker` size is bounded. Round 3 moved the 136-byte
        //      per-worker DescCache out to `Core.worker_desc_caches`;
        //      Worker returned to ~1912 B as observed pre-Phase-3 of
        //      round 1. A 4096-byte ceiling protects against accidental
        //      field growth; a tight equality check catches silent
        //      regrowth.
        std.debug.assert(@alignOf(sync.Mutex) >= @alignOf(u32));
        std.debug.assert(@sizeOf(Worker) <= 4096);
        // Tight invariant: if a future change makes Worker grow, the
        // author must update this constant AND justify it in a new
        // performance ledger — the 5-10% contended-scenario regression
        // measured in round 1 Phase 3 is the cost to beat.
        std.debug.assert(@sizeOf(Worker) == 1912);
    }
```

> **Caveat on the 1912 constant:** if the observed size on the build host differs by a handful of bytes (e.g. because a struct field above was padded differently under Zig 0.16.0 / x86_64), adjust the constant to the actually observed size at this HEAD. The point is tight equality, not the specific magic number. Confirm with a one-off compile and update before proceeding.

- [ ] **Step 3: Add `worker_desc_caches` field to `Core`**

Find the `desc_caches: []DescCache = &.{}` declaration around `src/pool.zig:518`. Immediately below it, add:

```zig
    /// Round 3: per-worker DescCache moved out of `Worker` into this
    /// parallel slice indexed by worker_index. Mirrors the submitter
    /// layout (`desc_caches`) so both sides use the same allocation/
    /// routing pattern. Keeps `Worker` at the pre-Phase-3 size of 1912 B
    /// — the 136-byte in-struct field regressed contended_spawn_8x
    /// −10.10% and contended_cpu_10us −5.28% vs the Phase-2 checkpoint
    /// of round 1, which this refactor exists to reclaim.
    worker_desc_caches: []DescCache = &.{},
```

- [ ] **Step 4: Allocate and zero-init the slice in `Core.init`**

Find the existing per-submitter cache allocation at `src/pool.zig:754-756`:

```zig
            self.desc_caches = try allocator.alloc(DescCache, normalized.max_submitter_queues);
            for (self.desc_caches) |*c| c.* = .{};
            self.recordOwnedAlloc(self.desc_caches.len * @sizeOf(DescCache));
```

Add the worker equivalent immediately below it. Use `normalized.worker_count` (or whatever field holds the post-validation worker count — confirm the field name at read time; in round 1 this was called `worker_count` on the normalized config):

```zig
            self.worker_desc_caches = try allocator.alloc(DescCache, normalized.worker_count);
            for (self.worker_desc_caches) |*c| c.* = .{};
            self.recordOwnedAlloc(self.worker_desc_caches.len * @sizeOf(DescCache));
```

**Important:** this allocation must happen on the same success path as `desc_caches` — same errdefer scope — so a partial init cleans up both or neither. Verify the error-handling path covers the new slice before moving on.

- [ ] **Step 5: Route `enqueuePush` through the pool-level slice**

Find the two worker-context branches in `Core.enqueuePush` at `src/pool.zig:1337-1347`:

```zig
                if (self.tlsWorkerIndexFor()) |wi| {
                    const w = &self.workers[wi];
                    if (w.desc_cache.tryPop()) |cached| break :idx cached;
                    var batch: [DescCache.capacity]u32 = undefined;
                    const taken = self.acquireDescriptorBatch(&batch);
                    if (taken == 0) return error.TaskPoolExhausted;
                    var i: usize = 1;
                    while (i < taken) : (i += 1) {
                        _ = w.desc_cache.push(batch[i]);
                    }
                    break :idx batch[0];
                }
```

Replace with:

```zig
                if (self.tlsWorkerIndexFor()) |wi| {
                    const cache = &self.worker_desc_caches[wi];
                    if (cache.tryPop()) |cached| break :idx cached;
                    var batch: [DescCache.capacity]u32 = undefined;
                    const taken = self.acquireDescriptorBatch(&batch);
                    if (taken == 0) return error.TaskPoolExhausted;
                    var i: usize = 1;
                    while (i < taken) : (i += 1) {
                        _ = cache.push(batch[i]);
                    }
                    break :idx batch[0];
                }
```

The `&self.workers[wi]` access is no longer needed for cache routing; if the variable `w` is used elsewhere in the same block, leave it. Read the surrounding block carefully and only remove dead references.

- [ ] **Step 6: Update `drainWorkerDescCaches` to iterate the slice**

Find `drainWorkerDescCaches` at `src/pool.zig:2466-2473`:

```zig
    fn drainWorkerDescCaches(self: *Core) void {
        for (self.workers[0..self.init_worker_count]) |*worker| {
            var buf: [DescCache.capacity]u32 = undefined;
            const n = worker.desc_cache.drainAll(&buf);
            var i: usize = 0;
            while (i < n) : (i += 1) self.releaseDescriptor(buf[i]);
        }
    }
```

Replace with:

```zig
    fn drainWorkerDescCaches(self: *Core) void {
        for (self.worker_desc_caches[0..self.init_worker_count]) |*cache| {
            var buf: [DescCache.capacity]u32 = undefined;
            const n = cache.drainAll(&buf);
            var i: usize = 0;
            while (i < n) : (i += 1) self.releaseDescriptor(buf[i]);
        }
    }
```

**Bounds-safety check:** the iteration bound `self.init_worker_count` must be ≤ `self.worker_desc_caches.len`. The allocation in Step 4 uses `normalized.worker_count`, and `init_worker_count` is bumped in the same loop that initializes `self.workers`, so after a successful init the two are equal; on a partial-init failure path, `init_worker_count` is the smaller of the two by construction. Safe.

- [ ] **Step 7: Free `worker_desc_caches` in `deinitOwned`**

Find the existing `desc_caches` cleanup at `src/pool.zig:2498-2501`:

```zig
        if (self.desc_caches.len > 0) {
            self.recordOwnedFree(self.desc_caches.len * @sizeOf(DescCache));
            self.allocator.free(self.desc_caches);
        }
```

Add the worker equivalent immediately after it:

```zig
        if (self.worker_desc_caches.len > 0) {
            self.recordOwnedFree(self.worker_desc_caches.len * @sizeOf(DescCache));
            self.allocator.free(self.worker_desc_caches);
        }
```

Order matters: free AFTER `drainWorkerDescCaches` has run. The existing call at `src/pool.zig:2483` already does this correctly — verify it is still before the new free block.

- [ ] **Step 8: Update the four affected tests in `tests/unit.zig`**

For each of the three existing tests that reference `worker.desc_cache` (`"Worker struct is within the 4096-byte ceiling post-desc_cache"`, `"worker-spawned task consumes from per-worker DescCache"`, `"pool.deinit drains per-worker desc_caches"`), replace field access with slice access.

The size-ceiling test at `tests/unit.zig:1593` should now assert the restored 1912 B size, matching the comptime assertion added in Step 2:

```zig
test "Worker struct is within the 4096-byte ceiling post-desc_cache" {
    // Round 3: Worker size was restored to ~1912 B after moving the
    // per-worker DescCache out to Core.worker_desc_caches. Equality
    // check catches silent regrowth; 4096 B is a hard ceiling.
    try std.testing.expectEqual(@as(usize, 1912), @sizeOf(@TypeOf(thread_pool.ThreadPool.__internal_worker_for_testing())));
    try std.testing.expect(@sizeOf(@TypeOf(thread_pool.ThreadPool.__internal_worker_for_testing())) <= 4096);
}
```

> **Note on `__internal_worker_for_testing`:** the existing test reaches `Worker` through whatever internal hook is already exposed — grep for it at `tests/unit.zig:1593` and keep using the same hook. Only the magic number (and comment) changes. If a public `Worker` type is NOT exposed, the existing pattern in the test is the canonical way to size it; do not introduce new test-only public APIs just for this assertion.

For `"worker-spawned task consumes from per-worker DescCache"` at `tests/unit.zig:1607` and `"pool.deinit drains per-worker desc_caches"` at `tests/unit.zig:1649`, grep for `worker.desc_cache` / `workers[i].desc_cache` and replace each occurrence with the slice-indexed access through whatever test-only getter the file already uses (likely `pool.drainWorkerDescCachesForTesting` and a new sibling `workerDescCachesForTesting()` if any direct inspection is needed — prefer the existing drain hook where possible).

Also update the new test from Task 1, Step 1 to use the real field name if needed.

- [ ] **Step 9: Run the full test suite and confirm all green**

```bash
zig build test-all --summary all
```

Expected: all green, including the new `"per-worker desc_caches live on pool, not inside Worker"` test.

- [ ] **Step 10: Commit the refactor**

```bash
git add src/pool.zig tests/unit.zig
git commit -m "$(cat <<'EOF'
perf(pool): extract per-worker DescCache to Core.worker_desc_caches

Round 3 Phase 1. Moves the 136-byte DescCache field out of the Worker
struct (which grew 1912 B -> 2048 B in round 1 Phase 3) into a pool-
level parallel slice indexed by worker_index, mirroring the existing
submitter cache layout (`Core.desc_caches`). Worker returns to 1912 B,
reclaiming the contended_spawn_8x -10.10% / contended_cpu_10us -5.28%
regression measured in round 1 Phase 3's isolated A/B while keeping
the worker-context DescCache fast path that unlocked the
nested_fanout_4x +81.26% win.

Cache-hit routing is a single array-indexed deref vs the prior field
access — negligible next to the global-freelist CAS it avoids.

Drain-on-deinit semantics identical; `drainWorkerDescCaches` now
iterates the slice instead of walking `Worker.desc_cache` fields.
All four affected tests updated; size-ceiling test tightened to equal
1912 B to catch silent regrowth.

Refs: docs/superpowers/plans/2026-04-17-go-gap-round3.md

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Stress gate — 20× ReleaseFast

**Files:** none modified.

- [ ] **Step 1: Run the full 20× stress gate**

```bash
for i in $(seq 1 20); do
  echo "=== run $i ==="
  zig build test-stress -Doptimize=ReleaseFast --summary all || { echo "FAILED run $i"; exit 1; }
done
```

Expected: 20/20 green. If any run fails, revert the Task 2 commit and write a brief postmortem in the FINAL.md (draft in Task 6) describing the failure mode; do not proceed to Task 4.

- [ ] **Step 2: Optional — TSan gate if available on host**

```bash
zig build test -Doptimize=Debug -Dtsan=true --summary all
```

Expected: no TSan warnings. Same abort policy as Step 1.

---

## Task 4: Paired A/B A = HEAD^  B = HEAD

**Files:**

- Create: `docs/performance/2026-04-17-go-gap-round3/runs/phase1-ab.md` (runsheet with raw numbers).

- [ ] **Step 1: Build both legs, record SHA256s**

```bash
git checkout HEAD^ -- src/pool.zig tests/unit.zig
zig build bench-runtime-compare -Doptimize=ReleaseFast
cp zig-out/bin/bench-runtime-compare /tmp/round3-A.bin
sha256sum /tmp/round3-A.bin

git checkout HEAD -- src/pool.zig tests/unit.zig
zig build bench-runtime-compare -Doptimize=ReleaseFast
cp zig-out/bin/bench-runtime-compare /tmp/round3-B.bin
sha256sum /tmp/round3-B.bin
```

Assert the two hashes differ before continuing. If they match, the build system cached something — wipe `zig-out/` and `.zig-cache/` and rebuild.

- [ ] **Step 2: Interleaved A B A B sweep, n=10 per leg**

```bash
mkdir -p docs/performance/2026-04-17-go-gap-round3/runs
for i in $(seq 1 10); do
  /tmp/round3-A.bin --output docs/performance/2026-04-17-go-gap-round3/runs/phase1-A-${i}.json --samples 1 --warmup-discard 0
  /tmp/round3-B.bin --output docs/performance/2026-04-17-go-gap-round3/runs/phase1-B-${i}.json --samples 1 --warmup-discard 0
done
```

- [ ] **Step 3: Aggregate medians**

Write a small aggregation script (or reuse `phase2-aggregate.py` from round 2 — check `.cache/` or recreate from round 2's FINAL.md which references it). Extract median-of-10 per scenario per leg; compute Δ% = (B − A) / A × 100.

Emit a Markdown table into `runs/phase1-ab.md` in the same shape as the round 2 Phase 1 table:

```markdown
| Scenario              | A median   | B median   |    Δ%    | Gate     | Pass |
|-----------------------|-----------:|-----------:|---------:|:--------:|:----:|
| contended_spawn_8x    |        ... |        ... |      ... | ≥ +5 %   | ?    |
| contended_cpu_10us    |        ... |        ... |      ... | ≥ +3 %   | ?    |
| nested_fanout_4x      |        ... |        ... |      ... | ≥ −3 %   | ?    |
| flood_1m              |        ... |        ... |      ... | ≥ −3 %   | ?    |
| cpu_work_10us         |        ... |        ... |      ... | ≥ −3 %   | ?    |
| cpu_work_100us        |        ... |        ... |      ... | ≥ −3 %   | ?    |
| burst_drain_burst     |        ... |        ... |      ... | ≥ −3 %   | ?    |
| mixed_fast_slow       |        ... |        ... |      ... | ≥ −3 %   | ?    |
```

Also record binary SHA256s, sample counts, and the A-leg / B-leg commit SHAs in the runsheet header.

- [ ] **Step 4: Evaluate the kill gate**

Apply the kill-gate table from "Measurement Protocol" above. A single entry failing its individual threshold ⇒ FAIL the gate.

- If **PASS**: proceed to Task 5 (LAND path).
- If **FAIL**: proceed to Task 6 (REVERT path).

Do not negotiate with the gate. Marginal near-misses get reverted and written up as closed planes — that is the discipline round 2 observed, and it is what keeps the plan's measurement protocol honest.

---

## Task 5: LAND path — bench refresh, FINAL.md, push

**Conditional: only run if Task 4 passes.**

**Files:**

- Create: `docs/performance/2026-04-17-go-gap-round3/FINAL.md`
- Modify: `CLAUDE.md` — "Current Direct Runtime Snapshot" tables.
- Modify: `docs/RUNTIME_COMPARISON.md` — "Current Snapshot" tables.
- Modify: `benchmarks/results/runtime-comparison-latest.json` — fresh sweep.

- [ ] **Step 1: Fresh post-land runtime-comparison sweep**

```bash
zig build bench-runtime-compare -Doptimize=ReleaseFast -- \
  --output benchmarks/results/runtime-comparison-latest.json \
  --samples 7 --warmup-discard 1
```

- [ ] **Step 2: Update CLAUDE.md throughput + latency tables**

Open `CLAUDE.md`, find the `### Throughput (ops/sec)` and `### Latency (p50/p95/p99, microseconds)` tables, replace the numbers with the post-land sweep, and bump the "From the 2026-04-17 post-Go-gap-contended-plan run ..." header paragraph to reference round 3.

- [ ] **Step 3: Update docs/RUNTIME_COMPARISON.md current-snapshot tables**

Same substitution, plus bump the "Run date" and "HEAD" lines at the top of the `## Current Snapshot` section.

- [ ] **Step 4: Draft FINAL.md**

Create `docs/performance/2026-04-17-go-gap-round3/FINAL.md` with the same structure as round 1 and round 2 FINAL docs:

- Headline (cross-snapshot gap table vs Go).
- Phase-by-phase isolated paired A/B (pulled from runsheet).
- What landed (commit range, summary).
- What was skipped (and why).
- Trade-off note (vs round 1 Phase 3 state).
- Closed planes confirmed + any new closed planes from this round.
- Next (candidate directions for a future round 4, if any).

- [ ] **Step 5: Stress gate re-run on the same binary**

```bash
for i in $(seq 1 20); do zig build test-stress -Doptimize=ReleaseFast || exit 1; done
```

Expected: 20/20 green. This re-gates against any flaky interaction the bench sweep may have disturbed.

- [ ] **Step 6: Commit docs + bench artefacts**

```bash
git add docs/performance/2026-04-17-go-gap-round3/ \
        benchmarks/results/runtime-comparison-latest.json \
        CLAUDE.md docs/RUNTIME_COMPARISON.md
git commit -m "$(cat <<'EOF'
docs(perf): Go-gap round 3 FINAL + refresh bench artefacts

Round 3 Phase 1 landed: per-worker DescCache extracted to
Core.worker_desc_caches. Paired A/B cleared the kill gate —
contended_spawn_8x and contended_cpu_10us reclaimed, nested_fanout_4x
+81.26% win preserved, no non-target regression beyond the -3% envelope.

Full runsheet in docs/performance/2026-04-17-go-gap-round3/runs/.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
git push origin main
```

---

## Task 6: REVERT path — closed-plane documentation

**Conditional: only run if Task 4 fails.**

**Files:**

- Create: `docs/performance/2026-04-17-go-gap-round3/FINAL.md` (FAILED verdict).
- Revert Task 2's commit from main.

- [ ] **Step 1: Revert the refactor commit**

```bash
git revert --no-edit HEAD   # assumes Task 2's commit is HEAD
```

If subsequent test-only commits landed between Task 2 and this step, resolve them explicitly — do NOT blanket-revert. The goal is to restore `src/pool.zig` and `tests/unit.zig` to byte-identical with the pre-Task-2 state while keeping the plan document and runsheet.

- [ ] **Step 2: Draft FINAL.md noting the closed plane**

Create `docs/performance/2026-04-17-go-gap-round3/FINAL.md` documenting:

- What was attempted (externalise DescCache slice).
- What the paired A/B delivered (raw numbers from Task 4 runsheet).
- Why the gate failed (hypothesis, not reproduced — consistent with round 2's discipline of "revert first, don't diagnose in the failed tree").
- Explicit addition to the "Closed planes" list so future rounds don't re-attempt.

Example candidate mechanisms for the FINAL to list, should FAIL happen (pick whichever matches the observed regression):

1. **Extra indirection dominated the cache-hit path** — the slice-indexed deref is one additional address-computation per cache-hit; under tight contended submit loops this can outweigh the Worker-size win.
2. **Allocator placed `worker_desc_caches` on a cacheline that aliases with another hot Core field** — possible but unlikely given the submitter caches are already allocated the same way without this issue.
3. **Size change shifted another field's cacheline** — if the Worker size assertion in Task 2 Step 2 needed the magic number tweaked, a mid-struct shift may have regressed a different scenario.

- [ ] **Step 3: Commit revert + FINAL**

```bash
git add docs/performance/2026-04-17-go-gap-round3/
git commit -m "$(cat <<'EOF'
docs(perf): Go-gap round 3 FINAL — externalised DescCache FAILED kill gate

Phase 1 reverted: paired A/B missed the target kill gate on
<scenarios>. No code lands from this round. Closes the
externalised-DescCache attack plane; future rounds should not
re-attempt without a materially different hypothesis.

Runsheet + raw JSONs retained for reference in
docs/performance/2026-04-17-go-gap-round3/runs/.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
git push origin main
```

- [ ] **Step 4: Update memory**

Save a new memory pointing at the FINAL doc noting the externalised-DescCache plane as closed, with the mechanism hypothesis and the fact that a comptime opt-out flag (round 2's suggestion #1) becomes the next candidate.

---

## Acceptance Criteria

- Plan lands iff Task 4's kill gate passes on all eight scenarios (two primary ≥ threshold, six secondary ≥ −3%).
- `Worker` struct size is locked to 1912 B (or the tight equality established at HEAD time) by comptime assert + tests.
- `drainWorkerDescCaches` continues to restore `task_desc_live == 0` on deinit — verified by the existing `"pool.deinit drains per-worker desc_caches"` test passing after Task 2's refactor.
- 20× ReleaseFast stress gate: 20/20 green both before paired A/B (Task 3) and after docs commit (Task 5 Step 5).
- Main-tree diff is limited to `src/pool.zig`, `tests/unit.zig`, plan + FINAL docs, and the bench artefact JSON. No collateral changes to unrelated code.
- FINAL.md exists at `docs/performance/2026-04-17-go-gap-round3/FINAL.md` with the verdict, paired-A/B numbers, and closed-plane update, regardless of LAND or REVERT outcome.

---

## Future Rounds (not in scope here)

If round 3 lands successfully, the remaining 2.2–2.7× gap to Go on contended scenarios is architectural (in-runtime per-P queue + goroutine-stack amortisation). Candidates for a round 4 would be, roughly in order of plausibility:

1. **DescCache capacity tuning** — cheap A/B at 16, 24, 48, 64 entries. Likely ±2 % noise territory but worth one sweep.
2. **MPSC DescCache variant (stealable)** — allow workers to steal descriptors from other workers' caches when the global freelist is empty. Risks losing the SPSC simplicity.
3. **Accept the gap as sustainable** — the throughput-plateau pivot memory documents this position; it remains defensible.

If round 3 FAILs and reverts, the fallback is round 2 FINAL's suggestion #1 verbatim: a `Config.worker_desc_cache_enabled` comptime flag that lets user code opt the in-struct DescCache out for multi-submitter workloads. That is a separate plan, not a Phase of this one.
