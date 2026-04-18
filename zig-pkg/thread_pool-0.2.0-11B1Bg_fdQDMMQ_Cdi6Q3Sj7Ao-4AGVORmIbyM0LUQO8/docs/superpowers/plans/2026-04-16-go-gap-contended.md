# Close the Go-gap on contended scenarios — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Materially narrow or close the Go-runtime throughput gap on `contended_spawn_8x` (Go 3.68x ahead), `contended_cpu_10us` (1.85x), and `nested_fanout_4x` (6.01x), without regressing other scenarios and without re-opening closed attack planes.

**Architecture:** Three attack surfaces that are explicitly *not* in project memory's closed-plane list. (1) Harness adoption of the existing `submitBatch` API inside worker-context fan-out — pure benchmark change, no src/ risk, coalesces the per-task SC `queued_tasks.fetchAdd` that today runs 4× per parent on `nested_fanout_4x`. (2) A per-submitter descriptor cache with batched take from the global freelist — reduces the N-way CAS contention on `free_top_tagged` observed on `contended_*` scenarios with 4–8 registered submitters. (3) A per-worker descriptor cache applying the same mechanism to the worker-submit path used by `nested_fanout_4x`. Each phase is isolated, reversible, and gated by a same-session paired A/B kill criterion.

**Tech stack:** Zig 0.16.0, `std.atomic`, `std.Thread`, `std.testing`. Measurement via `zig build bench-runtime-compare -Doptimize=ReleaseFast` and `bench-realistic`. No new dependencies.

---

## Tension with prior guidance — read before starting

Project memory `project_throughput_plateau_pivot.md` (2026-04-15) directed future work *away* from throughput micro-optimization after five consecutive landing failures on the `notifySubmits`/wake plane. This plan is a **narrow, scoped exception** for three specific scenarios using mechanisms that satisfy the memory's landing bar: "must show a mechanism *not* already tried AND must come with a prediction of why the plateau doesn't apply to it."

Mechanisms in this plan and why the plateau doesn't apply:
- **Harness `submitBatch` (Phase 1):** The prior plateau was on `flood_1m_batched` where `submitBatch` + per-submitter queues *regressed* because batch defers notifySubmits on the external-submitter path. In `nested_fanout_4x` the batcher is a **worker thread**, not an external submitter; the worker path uses LIFO slot + local queue (not the submitter queue). The regression mechanism does not apply.
- **Per-submitter descriptor cache (Phase 2):** Closed-plane list covers the *consumer* side (notifySubmits, park handshake, steal-peek, inject-head CAS) and Worker-struct layout shifts. It does not cover the **descriptor freelist acquire path** — memory `project_per_submitter_queues_landed.md` explicitly names `acquireDescriptor CAS (pool-wide free stack)` as a **remaining per-task bottleneck**, not closed.
- **Per-worker descriptor cache (Phase 3):** Same mechanism as Phase 2 applied to a different call site. Iter-11 memory warns that inserting fields into the Worker struct shifts layout. Phase 3 appends the field at end-of-struct per the explicit iter-11 guidance ("place at end-of-struct or in its own `align(cache_line)` slot").

If Phase 2 **and** Phase 3 both fail their kill criteria, treat that as *confirmation* of the plateau for these scenarios, archive the plan in `docs/performance/2026-04-16-go-gap-contended/CLOSED.md`, and revert to the pivot memory's guidance (latency/fairness/lanes/memory/API/observability axes).

---

## Scope and exclusions

**In scope:** `contended_spawn_8x`, `contended_cpu_10us`, `nested_fanout_4x`.

**Out of scope:** `mixed_fast_slow` (1.02x gap is within session noise — Phase-1 2026-04-16 same-session A/B flipped it to 1.02x *ahead* of Go; the cross-snapshot 1.01x behind in CLAUDE.md is a ~1% swing on 234K ops/sec). No dedicated attack. Will be tracked as a regression sentinel only.

**Excluded by closed-plane list (memory):** `notifySubmits` / park handshake, parked-worker scan, inject-queue CAS, steal-peek, drain-vs-steal reorder, worker-struct layout shifts mid-struct, socket-aware worker pinning, cascading wake, `active_tasks` sharding, `shouldExit` hot-path removal.

**Excluded by environment:** `perf record` profiling (host has `perf_event_paranoid=3`; sysctl change explicitly declined in the 2026-04-16 contended-scenarios plan).

---

## Measurement protocol (enforced by `feedback_measurement_rules.md`)

- Same-session paired A/B only; absolute cross-session numbers are invalid.
- n=10 paired rounds (balanced order: `A B A B ...` or rotated) on `bench-runtime-compare` for every Δ claim. Median + distribution overlap check.
- Stress gate: `20× zig build test-stress -Doptimize=ReleaseFast` — all passing, zero hangs, zero segfaults.
- Default-Config A/B: because Phases 2 and 3 add opt-in fields, also run A/B with the cache disabled to confirm no ambient regression on non-cache paths.
- Host check before every measurement session: uptime > 4h since boot (thermal-stable), load avg 1m < 2.0, no co-tenants with > 10% CPU.
- Record raw per-round throughput to `docs/performance/2026-04-16-go-gap-contended/runs/<phase>-<ab>.json`.

---

## File structure

### To create

- `src/pool/desc_cache.zig` — per-cache data structure with batched take from global freelist and drain-on-release helpers. Pure leaf module (no cyclic imports).
- `tests/desc_cache_test.zig` — unit tests for `DescCache` invariants (batch take returns correct count, drain-on-release returns all held indices, refill retries on CAS contention).
- `docs/performance/2026-04-16-go-gap-contended/README.md` — plan progress tracker.
- `docs/performance/2026-04-16-go-gap-contended/FINAL.md` — end-of-plan summary (Phase 4).
- `docs/performance/2026-04-16-go-gap-contended/runs/*.json` — raw bench outputs.

### To modify

- `src/pool.zig`:
  - Lines 285–364 (`Worker` struct): **append** `desc_cache` fields at end of struct. Bump `@sizeOf(Worker) <= 4096` invariant comment if needed.
  - Lines 854–924 (`registerSubmitter`/`releaseSubmitter`): allocate/drain per-submitter cache.
  - Lines 1253–1275 (`enqueueTask`): no changes (caller path unchanged).
  - Lines 1291–1393 (`enqueuePush`): route `acquireDescriptor` call at line 1296 through cache-first path.
  - Lines 2225–2251 (`acquireDescriptor`): expose `acquireDescriptorBatch(out: []u32) usize`.
  - Lines 2276–2305 (`releaseDescriptor`): unchanged (release stays on global freelist).
  - Pool init (search for `submitter_queues` alloc around line 732): allocate parallel `desc_caches[]` sized to `normalized.max_submitter_queues`.
- `benchmarks/runtime_compare_zig.zig`:
  - Lines 402–413 (`nestedParentTask`): use `pool.submitBatch` for children.
- `benchmarks/common.zig`:
  - Lines 408–420 (`nestedTask`): use `pool.submitBatch` for children.
- `CLAUDE.md`: refresh Current Direct Runtime Snapshot in Phase 4.

### Must not touch

- `scanAndWake` / `notifySubmits` / `park_cond` / `is_parked` (closed plane — iter 7/8/9).
- Worker-struct field *order* except appending at end (iter 11 layout lesson).
- Inject-queue CAS / `BoundedRing.popMany` (closed plane — Options A–G).
- Socket topology / worker pinning (closed plane — Slice 3a).

---

## Phase 0 — Baseline capture

**Files:**
- Create: `docs/performance/2026-04-16-go-gap-contended/baseline.json`
- Create: `docs/performance/2026-04-16-go-gap-contended/README.md`

### Task 0.1: Record baseline runtime-compare snapshot

- [ ] **Step 1: Confirm host quiescence**

Run:
```bash
uptime && cat /proc/loadavg && ps -eo pcpu,pid,cmd --sort=-pcpu | head -10
```
Expected: load1 < 2.0, no non-pool process > 10% CPU. If busy, wait 15 min and re-check.

- [ ] **Step 2: Capture baseline**

Run:
```bash
zig build bench-runtime-compare -Doptimize=ReleaseFast -- \
  --output docs/performance/2026-04-16-go-gap-contended/baseline.json \
  --samples 10 --warmup-discard 2
```
Expected: JSON emitted with 8 scenario rows (8 retained medians from 10 samples).

- [ ] **Step 3: Write progress tracker**

Create `docs/performance/2026-04-16-go-gap-contended/README.md`:

```markdown
# 2026-04-16 Go-gap contended scenarios plan

Plan: [`docs/superpowers/plans/2026-04-16-go-gap-contended.md`](../../superpowers/plans/2026-04-16-go-gap-contended.md)

## Target scenarios and baseline gaps vs Go

| Scenario | Zig baseline (ops/sec) | Go baseline | Gap vs Go |
|----------|-----------------------:|------------:|:---------:|
| contended_spawn_8x  | <fill from baseline.json> | <fill> | <fill>x |
| contended_cpu_10us  | <fill> | <fill> | <fill>x |
| nested_fanout_4x    | <fill> | <fill> | <fill>x |
| mixed_fast_slow     | <fill> | <fill> | <fill>x (sentinel) |

## Phase status

- [ ] Phase 0 — Baseline
- [ ] Phase 1 — `submitBatch` harness adoption
- [ ] Phase 2 — Per-submitter descriptor cache
- [ ] Phase 3 — Per-worker descriptor cache
- [ ] Phase 4 — Final snapshot + docs
```

Fill the table from the JSON. Use `jq` to extract Zig medians; Go medians come from `benchmarks/results/runtime-comparison-latest.json`.

- [ ] **Step 4: Commit baseline**

```bash
git add docs/performance/2026-04-16-go-gap-contended/baseline.json \
        docs/performance/2026-04-16-go-gap-contended/README.md
git commit -m "perf: baseline snapshot for 2026-04-16 Go-gap contended plan"
```

---

## Phase 1 — `submitBatch` harness adoption

**Rationale:** `submitBatch` at `src/pool.zig:800` already exists and coalesces the per-batch notify:

> Line 850 – "pending_notify" is flushed once as a single `notifySubmits(pending_notify, options.lane)` call after all pushes succeed, doing **one** `counters.submitted.fetchAdd(count, .monotonic)` and **one** `queued_tasks.fetchAdd(count, .seq_cst)` per batch (line 1419–1422).

`runtime_compare_zig.zig:runNestedFanout4xSample` today submits children one-by-one (4× per parent × 2000 parents = 8000 individual submits, 8000 SC fetchAdds on `queued_tasks`). Switching to `submitBatch` reduces that to 2000 fetchAdds. No src/ change; pure harness correctness fix of the same shape as the 2026-04-16 Phase-1 `registerSubmitter` audit.

**Prediction:** `nested_fanout_4x` throughput gains 10–25%. `mixed_fast_slow`, `contended_*`, `cpu_work_*`, `burst_drain_burst` unchanged (their harnesses do not fan out).

**Kill criterion:** If `nested_fanout_4x` median does not gain ≥ 8% in paired n=10 A/B, revert and close Phase 1. Non-target scenarios must not regress > 3%.

**Files:**
- Modify: `benchmarks/runtime_compare_zig.zig:402-413` (`nestedParentTask`)
- Modify: `benchmarks/common.zig:408-420` (`nestedTask`)
- Test: existing `test-integration` and `test-stress` suites exercise `submitBatch`.

### Task 1.1: Fail-first test for worker-context submitBatch

- [ ] **Step 1: Write the failing test**

Add to `tests/pool_test.zig` (or the closest existing worker-submit test file — `grep -l 'submit.*worker\|nested' tests/`):

```zig
test "submitBatch from worker context drains via local queue" {
    const allocator = std.testing.allocator;
    var pool = try thread_pool.ThreadPool.init(allocator, .{
        .min_threads = 4,
        .max_threads = 4,
        .queue_capacity = 256,
        .local_queue_capacity = 64,
        .scheduler_variant = .work_stealing,
    });
    defer pool.deinit();

    const CTX = struct {
        pool: *thread_pool.ThreadPool,
        wg: *thread_pool.WaitGroup,
        done: *std.atomic.Value(u64),

        fn parent(raw: *anyopaque, _: *thread_pool.TaskContext) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            var tasks: [4]thread_pool.BatchTask = undefined;
            for (&tasks) |*t| {
                t.* = .{ .task_fn = child, .ctx = @ptrCast(self) };
            }
            _ = self.pool.submitBatch(&tasks, .{ .wait_group = self.wg, .backpressure = .block }) catch return;
        }
        fn child(raw: *anyopaque, _: *thread_pool.TaskContext) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            _ = self.done.fetchAdd(1, .monotonic);
        }
    };

    var done = std.atomic.Value(u64).init(0);
    var wg = pool.waitGroup();
    var ctx = CTX{ .pool = &pool, .wg = &wg, .done = &done };
    _ = try pool.submit(CTX.parent, @ptrCast(&ctx), .{ .wait_group = &wg, .backpressure = .block });
    wg.wait();
    try std.testing.expectEqual(@as(u64, 4), done.load(.monotonic));
}
```

- [ ] **Step 2: Verify it passes (already supported API)**

Run: `zig build test`
Expected: PASS. `submitBatch` from worker context is not new API; it already works. This test locks the behavior we're about to rely on.

- [ ] **Step 3: Commit**

```bash
git add tests/pool_test.zig
git commit -m "test: lock submitBatch-from-worker-context behaviour before harness change"
```

### Task 1.2: Switch `nestedParentTask` in runtime-compare to `submitBatch`

- [ ] **Step 1: Replace loop with submitBatch call**

Edit `benchmarks/runtime_compare_zig.zig:402-413`:

```zig
fn nestedParentTask(raw_ctx: *anyopaque, runtime: *thread_pool.TaskContext) void {
    _ = runtime;
    const ctx: *NestedParentCtx = @ptrCast(@alignCast(raw_ctx));
    ctx.completed_at_ns.* = nowNs();

    var batch: [16]thread_pool.BatchTask = undefined;
    const n = ctx.child_ctxs.len;
    std.debug.assert(n <= batch.len);
    const now = nowNs();
    for (ctx.child_ctxs, ctx.child_submitted_at, 0..) |*child, *sub, i| {
        sub.* = now;
        batch[i] = .{ .task_fn = realisticTask, .ctx = @ptrCast(child) };
    }
    _ = ctx.pool.submitBatch(batch[0..n], .{
        .wait_group = ctx.wg,
        .backpressure = .block,
    }) catch return;
}
```

Note: `BatchTask` is defined in `src/types.zig` — verify the field names are `task_fn` and `ctx` before saving (grep for `const BatchTask` in src/).

- [ ] **Step 2: Verify compile + unit tests**

Run: `zig build test`
Expected: PASS (all tests, including Task 1.1's new one).

- [ ] **Step 3: Run integration and stress**

Run: `zig build test-integration && zig build test-stress`
Expected: PASS.

- [ ] **Step 4: Paired A/B run — n=10**

```bash
# A = before Task 1.2 (checkout HEAD^ temporarily in a worktree, rebuild, bench)
# B = after (current HEAD)
# Balanced-order: A B A B A B A B A B A B A B A B A B A B
```

Use a scratch script `scripts/phase1-ab.sh` (create if needed) that checks out the A commit, builds `bench-runtime-compare -Doptimize=ReleaseFast`, runs it once, then checks out B and runs it once — 10 rotations.

Record raw per-round throughputs to `docs/performance/2026-04-16-go-gap-contended/runs/phase1-ab.json`.

- [ ] **Step 5: Apply kill criterion**

Compute medians and per-round Δ. If `nested_fanout_4x` median Δ ≥ 8% AND no non-target scenario regresses > 3%: **proceed**. Else: revert Task 1.2 via `git reset --hard HEAD~1`, mark Phase 1 closed in README, skip to Phase 2.

- [ ] **Step 6: Commit**

```bash
git add benchmarks/runtime_compare_zig.zig
git commit -m "perf(bench): use submitBatch in runtime_compare nested_fanout_4x harness"
```

### Task 1.3: Switch `common.zig:nestedTask` to `submitBatch`

- [ ] **Step 1: Replace loop**

Edit `benchmarks/common.zig:408-420`:

```zig
fn nestedTask(raw_ctx: *anyopaque, runtime: *thread_pool.TaskContext) void {
    _ = runtime;
    const ctx: *BenchTaskCtx = @ptrCast(@alignCast(raw_ctx));
    _ = ctx.counter.value.fetchAdd(1, .monotonic);

    var batch: [32]thread_pool.BatchTask = undefined;
    std.debug.assert(ctx.nested_children <= batch.len);
    for (0..ctx.nested_children) |i| {
        batch[i] = .{ .task_fn = benchTask, .ctx = @ptrCast(ctx) };
    }
    _ = ctx.pool.?.submitBatch(batch[0..ctx.nested_children], .{
        .wait_group = ctx.wait_group.?,
        .backpressure = .block,
        .timeout_ns = 5 * std.time.ns_per_s,
    }) catch return;
    ctx.completed_at_ns.* = nowNs();
}
```

- [ ] **Step 2: Verify compile + tests**

Run: `zig build test && zig build test-integration`
Expected: PASS.

- [ ] **Step 3: Paired A/B on bench-realistic**

Run `bench-realistic` A vs B n=10; focus on `nested_fanout_4x` row.

Record to `docs/performance/2026-04-16-go-gap-contended/runs/phase1-realistic-ab.json`.

- [ ] **Step 4: Commit if gains hold**

Kill criterion: `bench-realistic` `nested_fanout_4x` median Δ ≥ 5% (more forgiving because latency is primary for bench-realistic).

```bash
git add benchmarks/common.zig
git commit -m "perf(bench): use submitBatch in bench-realistic nested_fanout harness"
```

### Task 1.4: Phase 1 checkpoint

- [ ] **Step 1: Update README**

Mark Phase 1 complete/partial. Record Δ in table.

- [ ] **Step 2: Commit**

```bash
git add docs/performance/2026-04-16-go-gap-contended/README.md \
        docs/performance/2026-04-16-go-gap-contended/runs/
git commit -m "docs: Phase 1 A/B results for Go-gap contended plan"
```

---

## Phase 2 — Per-submitter descriptor cache

**Rationale:** `acquireDescriptor` at `src/pool.zig:2227-2251` does 1 CAS on `free_top_tagged` per submit. With 4–8 registered submitters, this is the N-way contention point on `contended_spawn_8x` and `contended_cpu_10us`. Project memory `project_per_submitter_queues_landed.md` lists this as a **remaining** per-task bottleneck — not closed.

**Mechanism:** Each registered submitter slot gets a small descriptor cache (`CACHE_N = 32` initially). On submit, the hot path pops from the cache (non-atomic, SPSC owner). On cache empty, one batched CAS takes up to `CACHE_N` descriptors from the global freelist at once — the global CAS rate drops by `CACHE_N×`.

Release path stays on the global freelist (unchanged) — workers release from any thread; per-submitter release caching would require cross-thread sync and loses the win.

**Prediction:** `contended_spawn_8x` +10–20% (dominant CAS contention source gone). `contended_cpu_10us` +6–12%. `nested_fanout_4x` unchanged (worker path doesn't go through submitter queues; Phase 3 handles it). `flood_1m` / `cpu_work_10us` / `cpu_work_100us` unchanged (single producer). `burst_drain_burst` unchanged.

**Kill criterion:** If **neither** `contended_spawn_8x` ≥ 10% **nor** `contended_cpu_10us` ≥ 8% in paired n=10 A/B: revert entire Phase 2 and skip to Phase 3. Also: any non-target regression > 3% = revert.

**Files:**
- Create: `src/pool/desc_cache.zig`
- Create: `tests/desc_cache_test.zig`
- Modify: `src/pool.zig` — see granular edits per task below.

### Task 2.1: `DescCache` module with fail-first test

- [ ] **Step 1: Write the failing test**

Create `tests/desc_cache_test.zig`:

```zig
const std = @import("std");
const DescCache = @import("thread_pool").DescCache; // re-export needed in root.zig

test "DescCache stores and returns indices LIFO" {
    var cache = DescCache.init();
    try std.testing.expectEqual(@as(usize, 0), cache.len());
    try std.testing.expect(cache.tryPop() == null);

    cache.push(7);
    cache.push(9);
    try std.testing.expectEqual(@as(?u32, 9), cache.tryPop());
    try std.testing.expectEqual(@as(?u32, 7), cache.tryPop());
    try std.testing.expect(cache.tryPop() == null);
}

test "DescCache full push returns false" {
    var cache = DescCache.init();
    var i: u32 = 0;
    while (i < DescCache.capacity) : (i += 1) try std.testing.expect(cache.push(i));
    try std.testing.expect(!cache.push(9999));
}

test "DescCache drainAll yields all held indices" {
    var cache = DescCache.init();
    cache.push(1);
    cache.push(2);
    cache.push(3);

    var drained: [4]u32 = undefined;
    const n = cache.drainAll(&drained);
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqualSlices(u32, &[_]u32{ 3, 2, 1 }, drained[0..n]);
    try std.testing.expectEqual(@as(usize, 0), cache.len());
}
```

Add build-step wiring in `build.zig` if needed (follow the pattern of existing `tests/` files — most are auto-discovered).

- [ ] **Step 2: Verify test fails to compile**

Run: `zig build test`
Expected: compile error — `DescCache` is not defined.

- [ ] **Step 3: Create minimal `DescCache` implementation**

Create `src/pool/desc_cache.zig`:

```zig
const std = @import("std");

/// SPSC descriptor cache. The owner (submitter or worker thread) is the
/// single writer and reader. Accessed only from one thread's submit path.
/// Drain-on-release is called under a higher-level exclusion (release
/// CAS), so it also has single-writer semantics at that moment.
///
/// No atomic ops on push/pop/drain: the invariant is that only one thread
/// touches `DescCache` at a time. If this ever changes, every op needs
/// to become atomic and you should reach for a proper SPSC ring instead.
pub const DescCache = struct {
    pub const capacity: usize = 32;

    indices: [capacity]u32 = undefined,
    head: usize = 0,

    pub fn init() DescCache {
        return .{};
    }

    pub fn len(self: *const DescCache) usize {
        return self.head;
    }

    pub fn tryPop(self: *DescCache) ?u32 {
        if (self.head == 0) return null;
        self.head -= 1;
        return self.indices[self.head];
    }

    pub fn push(self: *DescCache, idx: u32) bool {
        if (self.head >= capacity) return false;
        self.indices[self.head] = idx;
        self.head += 1;
        return true;
    }

    pub fn drainAll(self: *DescCache, out: []u32) usize {
        const n = self.head;
        std.debug.assert(out.len >= n);
        var i: usize = 0;
        while (i < n) : (i += 1) out[i] = self.indices[n - 1 - i];
        self.head = 0;
        return n;
    }
};
```

- [ ] **Step 4: Re-export in `src/root.zig`**

Append to `src/root.zig`:

```zig
pub const DescCache = @import("pool/desc_cache.zig").DescCache;
```

- [ ] **Step 5: Run tests**

Run: `zig build test`
Expected: PASS. All three tests green.

- [ ] **Step 6: Commit**

```bash
git add src/pool/desc_cache.zig src/root.zig tests/desc_cache_test.zig
git commit -m "feat(pool): DescCache SPSC descriptor-index cache primitive"
```

### Task 2.2: Batched `acquireDescriptorBatch` helper in `Core`

- [ ] **Step 1: Write failing integration test**

Append to `tests/desc_cache_test.zig`:

```zig
const thread_pool = @import("thread_pool");

test "Core.acquireDescriptorBatch returns up to N indices in one CAS" {
    const allocator = std.testing.allocator;
    var pool = try thread_pool.ThreadPool.init(allocator, .{
        .min_threads = 1,
        .max_threads = 1,
        .queue_capacity = 64,
        .local_queue_capacity = 32,
        .scheduler_variant = .work_stealing,
    });
    defer pool.deinit();

    // Private accessor expected to be added in Step 3. Use an opaque
    // handle so the test compiles once it exists.
    const core = pool.coreForTesting();
    var out: [16]u32 = undefined;
    const n = core.acquireDescriptorBatch(&out);
    try std.testing.expect(n > 0 and n <= out.len);

    // Indices must be distinct.
    var seen = std.AutoHashMap(u32, void).init(allocator);
    defer seen.deinit();
    for (out[0..n]) |idx| try std.testing.expect((try seen.getOrPut(idx)).found_existing == false);

    // Return to freelist.
    for (out[0..n]) |idx| core.releaseDescriptorForTesting(idx);
}
```

- [ ] **Step 2: Run — verify compile error**

Run: `zig build test`
Expected: compile error — `coreForTesting`, `acquireDescriptorBatch`, `releaseDescriptorForTesting` not defined.

- [ ] **Step 3: Implement `acquireDescriptorBatch` in `src/pool.zig`**

Locate `acquireDescriptor` at line 2227. Add alongside it:

```zig
/// Batched take from the top of the freelist. Returns the number of
/// descriptors actually taken (0..out.len). One CAS regardless of
/// batch size, vs N CASes for N single acquires. Caller must arrange
/// to `releaseDescriptor` each returned index exactly once.
///
/// Traverses up to `out.len` freelist links to find the new head, then
/// CAS-publishes the skip. On CAS failure, retries from the current
/// head (standard lock-free retry loop).
fn acquireDescriptorBatch(self: *Core, out: []u32) usize {
    if (out.len == 0) return 0;
    retry: while (true) {
        const tagged = self.free_top_tagged.load(.acquire);
        const head = @as(u32, @truncate(tagged));
        if (head == free_sentinel) return 0;
        const aba = @as(u32, @truncate(tagged >> 32));

        var taken: usize = 0;
        var cur = head;
        out[0] = head;
        taken = 1;
        while (taken < out.len) {
            const next = self.free_indices[cur].load(.monotonic);
            if (next == free_sentinel) break;
            out[taken] = next;
            taken += 1;
            cur = next;
        }
        const new_head_u32 = self.free_indices[cur].load(.monotonic);
        const new_tagged = (@as(u64, aba +% 1) << 32) | @as(u64, new_head_u32);
        if (self.free_top_tagged.cmpxchgWeak(tagged, new_tagged, .acq_rel, .acquire)) |_| {
            continue :retry;
        }
        // Reset each taken descriptor to the state `acquireDescriptor` leaves them in.
        for (out[0..taken]) |idx| {
            const descriptor = &self.descriptors[idx];
            const prev_generation = descriptor.generation;
            descriptor.* = .{};
            descriptor.generation = prev_generation +% 1;
            if (descriptor.generation == 0) descriptor.generation = 1;
            if (claim_sentinel_enabled) descriptor.claimed_by.store(-1, .release);
            descriptor.state.store(.reserved, .release);
        }
        const live = self.counters.task_desc_live.fetchAdd(taken, .monotonic) + taken;
        updatePeak(&self.counters.task_desc_peak, live);
        return taken;
    }
}
```

- [ ] **Step 4: Add test accessors on `ThreadPool`**

Locate the `ThreadPool` wrapper struct (near line 2478 per grep above). Append:

```zig
/// Test-only accessor. Not part of the public contract. Do not call
/// from production code.
pub fn coreForTesting(self: *ThreadPool) *Core {
    return &self.core;
}
```

Add `releaseDescriptorForTesting` as a test-only wrapper around `releaseDescriptor`:

```zig
pub fn releaseDescriptorForTesting(self: *ThreadPool, idx: u32) void {
    self.core.releaseDescriptor(idx);
}
```

(`Core.releaseDescriptor` already exists at 2276.)

Similarly expose `acquireDescriptorBatch`:

```zig
pub fn acquireDescriptorBatchForTesting(self: *ThreadPool, out: []u32) usize {
    return self.core.acquireDescriptorBatch(out);
}
```

Update the test to call `core.acquireDescriptorBatch(&out)` as `pool.acquireDescriptorBatchForTesting(&out)` (Core field is not public; only `ThreadPool` is).

- [ ] **Step 5: Run tests**

Run: `zig build test`
Expected: PASS.

- [ ] **Step 6: Stress gate**

Run: `for i in $(seq 1 20); do zig build test-stress -Doptimize=ReleaseFast || echo "FAIL round $i"; done`
Expected: 20 iterations, zero FAIL.

- [ ] **Step 7: Commit**

```bash
git add src/pool.zig tests/desc_cache_test.zig
git commit -m "feat(pool): acquireDescriptorBatch — amortize freelist CAS contention"
```

### Task 2.3: Allocate per-submitter `desc_caches[]` in pool init

- [ ] **Step 1: Find the submitter_queues allocation site**

Run: `grep -n 'submitter_queues\s*=' src/pool.zig`
Expected: locate the slice allocation near `Core.init` (around where `max_submitter_queues` is consumed).

- [ ] **Step 2: Add parallel allocation**

Near the `submitter_queues` alloc, add:

```zig
self.desc_caches = try allocator.alloc(DescCache, normalized.max_submitter_queues);
for (self.desc_caches) |*c| c.* = DescCache.init();
```

Add the field to `Core`:

```zig
desc_caches: []DescCache = &.{},
```

Add import at top of `pool.zig`:

```zig
const DescCache = @import("pool/desc_cache.zig").DescCache;
```

Free in `Core.deinit`:

```zig
allocator.free(self.desc_caches);
```

- [ ] **Step 3: Run tests**

Run: `zig build test`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add src/pool.zig
git commit -m "feat(pool): allocate per-submitter DescCache array at init"
```

### Task 2.4: Route `enqueuePush` through submitter cache

- [ ] **Step 1: Write failing test for cache consumption**

Append to `tests/desc_cache_test.zig`:

```zig
test "registered submitter consumes from desc_cache before global freelist" {
    const allocator = std.testing.allocator;
    var pool = try thread_pool.ThreadPool.init(allocator, .{
        .min_threads = 2,
        .max_threads = 2,
        .queue_capacity = 256,
        .local_queue_capacity = 32,
        .scheduler_variant = .work_stealing,
        .max_submitter_queues = 1,
        .submitter_queue_capacity = 128,
    });
    defer pool.deinit();

    const slot = try pool.registerSubmitter();
    defer pool.releaseSubmitter(slot);

    var done = std.atomic.Value(u64).init(0);
    const noop = struct {
        fn run(raw: *anyopaque, _: *thread_pool.TaskContext) void {
            const d: *std.atomic.Value(u64) = @ptrCast(@alignCast(raw));
            _ = d.fetchAdd(1, .monotonic);
        }
    }.run;

    var wg = pool.waitGroup();
    // Submit more than DescCache.capacity tasks so the cache must refill.
    const N: usize = thread_pool.DescCache.capacity * 3 + 5;
    var i: usize = 0;
    while (i < N) : (i += 1) {
        _ = try pool.submit(noop, @ptrCast(&done), .{ .wait_group = &wg, .backpressure = .block });
    }
    wg.wait();
    try std.testing.expectEqual(@as(u64, N), done.load(.monotonic));
}
```

- [ ] **Step 2: Verify test still passes (pre-change)**

Run: `zig build test`
Expected: PASS — the test doesn't rely on cache *being* used, just on correctness after N > capacity submits.

- [ ] **Step 3: Implement the cache-first acquire path**

Edit `src/pool.zig:1296`. Replace:

```zig
const descriptor_index = self.acquireDescriptor() orelse return error.TaskPoolExhausted;
```

With:

```zig
const descriptor_index = idx: {
    if (self.tlsSubmitterIndexFor()) |si| {
        const cache = &self.desc_caches[si];
        if (cache.tryPop()) |cached| {
            // Replay the per-acquire metric the global path increments.
            _ = self.counters.task_desc_live.fetchAdd(1, .monotonic);
            break :idx cached;
        }
        var batch: [DescCache.capacity]u32 = undefined;
        const taken = self.acquireDescriptorBatch(&batch);
        if (taken == 0) return error.TaskPoolExhausted;
        // Keep one for this submit, cache the rest.
        var i: usize = 1;
        while (i < taken) : (i += 1) {
            _ = cache.push(batch[i]);
        }
        break :idx batch[0];
    }
    break :idx self.acquireDescriptor() orelse return error.TaskPoolExhausted;
};
```

Subtle invariant: `acquireDescriptorBatch` already bumps `task_desc_live` by `taken`. The inner `tryPop` path must bump by 1 (because the indices in the cache were counted in live at batch time; they are still live, and re-using them for the *same-live-count* invariant means we don't bump again). **Revise:** on `tryPop` cache hit, do NOT bump `task_desc_live` — the index is already counted. On miss + batch refill, the batch already bumped by `taken`, so we push `taken - 1` to cache and keep 1 — no additional bump needed.

Replace the block with the corrected version:

```zig
const descriptor_index = idx: {
    if (self.tlsSubmitterIndexFor()) |si| {
        const cache = &self.desc_caches[si];
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
    break :idx self.acquireDescriptor() orelse return error.TaskPoolExhausted;
};
```

- [ ] **Step 4: Run tests**

Run: `zig build test`
Expected: PASS. All existing tests + new capacity-spanning test.

- [ ] **Step 5: Integration tests**

Run: `zig build test-integration`
Expected: PASS.

- [ ] **Step 6: 20× stress gate**

```bash
for i in $(seq 1 20); do
    zig build test-stress -Doptimize=ReleaseFast || { echo "FAIL round $i"; break; }
done
```
Expected: 20/20 PASS.

- [ ] **Step 7: Commit**

```bash
git add src/pool.zig tests/desc_cache_test.zig
git commit -m "perf(pool): route registered-submitter acquires through DescCache"
```

### Task 2.5: Drain cache on `releaseSubmitter`

- [ ] **Step 1: Write failing leak-check test**

Append to `tests/desc_cache_test.zig`:

```zig
test "releaseSubmitter drains desc_cache back to global freelist" {
    const allocator = std.testing.allocator;
    var pool = try thread_pool.ThreadPool.init(allocator, .{
        .min_threads = 2,
        .max_threads = 2,
        .queue_capacity = 64,
        .local_queue_capacity = 32,
        .scheduler_variant = .work_stealing,
        .max_submitter_queues = 1,
        .submitter_queue_capacity = 64,
    });
    defer pool.deinit();

    const stats_before = pool.statsSnapshot();
    const live_before = stats_before.task_desc_live;

    const slot = try pool.registerSubmitter();
    var done = std.atomic.Value(u64).init(0);
    const noop = struct {
        fn run(raw: *anyopaque, _: *thread_pool.TaskContext) void {
            const d: *std.atomic.Value(u64) = @ptrCast(@alignCast(raw));
            _ = d.fetchAdd(1, .monotonic);
        }
    }.run;

    var wg = pool.waitGroup();
    // Populate cache, then let tasks drain.
    for (0..16) |_| {
        _ = try pool.submit(noop, @ptrCast(&done), .{ .wait_group = &wg, .backpressure = .block });
    }
    wg.wait();

    // At this point some descriptors may sit in cache unreleased (because
    // we over-took on the refill). Release the submitter — this must
    // return those to the global freelist.
    pool.releaseSubmitter(slot);

    const stats_after = pool.statsSnapshot();
    try std.testing.expectEqual(live_before, stats_after.task_desc_live);
}
```

- [ ] **Step 2: Verify test fails**

Run: `zig build test`
Expected: FAIL — cached descriptors leak into `task_desc_live`.

- [ ] **Step 3: Add drain in `releaseSubmitter`**

Edit `src/pool.zig:868-924`. Locate the drain block at line 907 ("Drain: bounded spin-retry on inject_queue.tryPush..."). Before that loop, add:

```zig
// Drain desc_cache back to the global freelist. Must happen BEFORE
// clearing the free_mask bit — the CAS above has made us the sole
// owner of this slot, and any concurrent `registerSubmitter` taking
// our slot observes an empty cache when it reads the new init.
{
    const cache = &self.desc_caches[idx];
    var buf: [DescCache.capacity]u32 = undefined;
    const n = cache.drainAll(&buf);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        self.releaseDescriptor(buf[i]);
    }
}
```

Note: `releaseDescriptor` expects the descriptor to be in `.reserved` or a terminal state. Cached descriptors (never used after `acquireDescriptorBatch` put them in cache) are in `.reserved` state — matches one of the accepted states at line 2292.

- [ ] **Step 4: Run tests**

Run: `zig build test`
Expected: PASS.

- [ ] **Step 5: Stress**

Run: `for i in $(seq 1 20); do zig build test-stress -Doptimize=ReleaseFast || echo "FAIL $i"; done`
Expected: 20/20 PASS.

- [ ] **Step 6: Commit**

```bash
git add src/pool.zig tests/desc_cache_test.zig
git commit -m "fix(pool): drain DescCache back to freelist on releaseSubmitter"
```

### Task 2.6: Phase 2 A/B measurement and kill gate

- [ ] **Step 1: Host quiescence check (repeat Task 0.1 Step 1)**

- [ ] **Step 2: Build both legs**

Use git worktrees to avoid rebuild thrash:

```bash
git worktree add /tmp/pool-phase2-A HEAD~N   # N = commits since Phase-0 baseline
git worktree add /tmp/pool-phase2-B HEAD
cd /tmp/pool-phase2-A && zig build bench-runtime-compare -Doptimize=ReleaseFast
cd /tmp/pool-phase2-B && zig build bench-runtime-compare -Doptimize=ReleaseFast
cd /home/benji/src/devnw/zig/thread-pool
```

- [ ] **Step 3: Paired n=10 balanced-order**

```bash
for round in $(seq 1 10); do
    /tmp/pool-phase2-A/zig-out/bin/bench-runtime-compare --output /tmp/phase2-A-$round.json
    /tmp/pool-phase2-B/zig-out/bin/bench-runtime-compare --output /tmp/phase2-B-$round.json
done
```

Collect into `docs/performance/2026-04-16-go-gap-contended/runs/phase2-ab.json`.

- [ ] **Step 4: Extract per-scenario medians**

Use `jq` to pull ops_per_sec for each scenario across rounds. Compute median and per-round Δ.

Expected table (fill after measurement):

| Scenario | A median | B median | Δ | Gate |
|----------|---------:|---------:|--:|:----:|
| contended_spawn_8x  | | | | ≥ 10% |
| contended_cpu_10us  | | | | ≥ 8%  |
| nested_fanout_4x    | | | | ≥ −3% |
| mixed_fast_slow     | | | | ≥ −3% |
| flood_1m            | | | | ≥ −3% |
| cpu_work_10us       | | | | ≥ −3% |
| cpu_work_100us      | | | | ≥ −3% |
| burst_drain_burst   | | | | ≥ −3% |

- [ ] **Step 5: Apply kill criterion**

If (`contended_spawn_8x` ≥ 10% OR `contended_cpu_10us` ≥ 8%) AND no non-target regresses > 3%: **Phase 2 KEEPS**. Proceed to Phase 3.

Else: `git revert` Task-2.3, 2.4, 2.5 commits. Leave Task 2.1 and 2.2 landed (DescCache module + batched API — low-risk infra that may still be useful for Phase 3). Update README marking Phase 2 closed. Skip Phase 3 if the plateau is confirmed, or proceed if the worker path is believed to be independently attackable.

- [ ] **Step 6: Commit measurement artefacts**

```bash
git add docs/performance/2026-04-16-go-gap-contended/
git commit -m "docs: Phase 2 A/B results for Go-gap contended plan"
```

---

## Phase 3 — Per-worker descriptor cache

**Rationale:** `nested_fanout_4x` spawns children from worker context (see `runtime_compare_zig.zig:402-413` pre-Phase 1). The worker path at `pool.zig:1342-1358` uses LIFO slot + local queue (not the submitter queue), so Phase 2's per-submitter cache does NOT help. Worker-context `acquireDescriptor` still does 1 CAS per child.

**Mechanism:** Append a `DescCache` to `Worker`. On submit-from-worker, pop from the worker-local cache; on miss, batched-refill from global. On worker shutdown (pool deinit), drain to global freelist.

**Prediction:** `nested_fanout_4x` +8–20% **on top of Phase 1 gains**. Other scenarios unchanged — the worker-submit path fires only when a task on a worker submits another task, which in the other scenarios either doesn't happen (flood_1m / cpu_work_*) or doesn't dominate (burst / contended_* where submitters are external).

**Kill criterion:** If `nested_fanout_4x` Phase-1+Phase-3 cumulative gain < 18% vs Phase-0 baseline: revert Phase 3. (The 18% is the headline Phase-1 2026-04-16 gain on the contended-scenarios plan; falling below it means the worker-cache mechanism failed.) Non-target regress > 3% = revert.

**Files:**
- Modify: `src/pool.zig`
  - Worker struct (lines 285–364): append `desc_cache` field at end-of-struct.
  - `enqueuePush` worker-path branch (lines 1342–1361): route acquire through worker cache.
  - Worker shutdown path: drain cache.

### Task 3.1: Append `desc_cache` to `Worker` struct — layout check

- [ ] **Step 1: Write the struct-size test**

Append to an existing test file (e.g. `tests/pool_test.zig`):

```zig
test "Worker struct is within the 4096-byte ceiling post-desc_cache" {
    // The Worker type is private; assert indirectly through its
    // effective size on the workers slice. Allocate one pool and
    // divide the workers slice bytes by workers.len.
    const allocator = std.testing.allocator;
    var pool = try thread_pool.ThreadPool.init(allocator, .{
        .min_threads = 4,
        .max_threads = 4,
        .queue_capacity = 64,
        .local_queue_capacity = 32,
        .scheduler_variant = .work_stealing,
    });
    defer pool.deinit();

    // Delegate actual assertion to a Core-private method that knows
    // the Worker type. Added in Step 2.
    try pool.assertWorkerSizeBoundedForTesting(4096);
}
```

- [ ] **Step 2: Verify compile fail**

Run: `zig build test`
Expected: compile error — `assertWorkerSizeBoundedForTesting` not defined.

- [ ] **Step 3: Implement the test helper**

In `src/pool.zig` near `coreForTesting`:

```zig
pub fn assertWorkerSizeBoundedForTesting(_: *ThreadPool, comptime ceiling: usize) !void {
    if (@sizeOf(Worker) > ceiling) return error.WorkerSizeExceedsCeiling;
}
```

- [ ] **Step 4: Append the field to `Worker`**

Edit `src/pool.zig:340-342`. Keep `is_overflow` and `overflow_retired` in their current position, then add AT END:

```zig
    is_overflow: bool = false,
    overflow_retired: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    // Slice 2-W: per-worker DescCache appended at end of Worker. Per
    // iter-11 layout lesson, we do NOT insert fields mid-struct —
    // adding a field here shifts no existing field offsets.
    desc_cache: DescCache = .{},
};
```

Also update the `@sizeOf(Worker) <= 4096` comment invariant if needed.

- [ ] **Step 5: Run tests**

Run: `zig build test`
Expected: PASS. Size ceiling check must pass with DescCache (256 bytes worst case) added.

- [ ] **Step 6: Commit**

```bash
git add src/pool.zig tests/pool_test.zig
git commit -m "feat(pool): append DescCache to Worker struct (end-of-struct, layout-safe)"
```

### Task 3.2: Route worker-path acquire through `Worker.desc_cache`

- [ ] **Step 1: Write failing test — worker submit uses its cache**

Append to `tests/desc_cache_test.zig`:

```zig
test "worker-spawned task consumes from per-worker DescCache" {
    const allocator = std.testing.allocator;
    var pool = try thread_pool.ThreadPool.init(allocator, .{
        .min_threads = 2,
        .max_threads = 2,
        .queue_capacity = 256,
        .local_queue_capacity = 64,
        .scheduler_variant = .work_stealing,
    });
    defer pool.deinit();

    var done = std.atomic.Value(u64).init(0);
    const Ctx = struct {
        pool: *thread_pool.ThreadPool,
        wg: *thread_pool.WaitGroup,
        done: *std.atomic.Value(u64),
        fn parent(raw: *anyopaque, _: *thread_pool.TaskContext) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            // Submit 64 children (more than capacity) to force a
            // batch refill from the worker cache.
            var i: usize = 0;
            while (i < 64) : (i += 1) {
                _ = self.pool.submit(child, @ptrCast(self), .{
                    .wait_group = self.wg, .backpressure = .block,
                }) catch return;
            }
        }
        fn child(raw: *anyopaque, _: *thread_pool.TaskContext) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            _ = self.done.fetchAdd(1, .monotonic);
        }
    };

    var wg = pool.waitGroup();
    var ctx = Ctx{ .pool = &pool, .wg = &wg, .done = &done };
    _ = try pool.submit(Ctx.parent, @ptrCast(&ctx), .{ .wait_group = &wg, .backpressure = .block });
    wg.wait();
    try std.testing.expectEqual(@as(u64, 64), done.load(.monotonic));
}
```

- [ ] **Step 2: Verify test passes pre-change**

Run: `zig build test`
Expected: PASS (pre-Task-3.2 this works via the global freelist).

- [ ] **Step 3: Route worker acquire through cache**

Edit `src/pool.zig:1296`. Expand the existing `idx:` block (from Task 2.4) to check the worker cache *before* the submitter cache:

```zig
const descriptor_index = idx: {
    const uses_local = usesLocalQueues(self);
    if (uses_local) {
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
    }
    if (self.tlsSubmitterIndexFor()) |si| {
        const cache = &self.desc_caches[si];
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
    break :idx self.acquireDescriptor() orelse return error.TaskPoolExhausted;
};
```

- [ ] **Step 4: Run tests**

Run: `zig build test`
Expected: PASS.

- [ ] **Step 5: Integration**

Run: `zig build test-integration`
Expected: PASS.

- [ ] **Step 6: 20× stress gate**

Run: `for i in $(seq 1 20); do zig build test-stress -Doptimize=ReleaseFast || echo "FAIL $i"; done`
Expected: 20/20 PASS.

- [ ] **Step 7: Commit**

```bash
git add src/pool.zig tests/desc_cache_test.zig
git commit -m "perf(pool): route worker-context acquires through per-worker DescCache"
```

### Task 3.3: Drain per-worker cache on pool deinit

- [ ] **Step 1: Write failing leak test**

Append to `tests/desc_cache_test.zig`:

```zig
test "pool.deinit drains per-worker desc_caches" {
    // Smoke test — pool.deinit is the hard path. We assert that after
    // a burst of worker-submitted work and shutdown, no allocator leak
    // is reported (the test allocator tracks leaks automatically).
    const allocator = std.testing.allocator;
    var pool = try thread_pool.ThreadPool.init(allocator, .{
        .min_threads = 2,
        .max_threads = 2,
        .queue_capacity = 256,
        .local_queue_capacity = 64,
        .scheduler_variant = .work_stealing,
    });

    var done = std.atomic.Value(u64).init(0);
    const Ctx = struct {
        pool: *thread_pool.ThreadPool,
        wg: *thread_pool.WaitGroup,
        done: *std.atomic.Value(u64),
        fn parent(raw: *anyopaque, _: *thread_pool.TaskContext) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            var i: usize = 0;
            while (i < 96) : (i += 1) {
                _ = self.pool.submit(child, @ptrCast(self), .{ .wait_group = self.wg, .backpressure = .block }) catch return;
            }
        }
        fn child(raw: *anyopaque, _: *thread_pool.TaskContext) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            _ = self.done.fetchAdd(1, .monotonic);
        }
    };
    var wg = pool.waitGroup();
    var ctx = Ctx{ .pool = &pool, .wg = &wg, .done = &done };
    _ = try pool.submit(Ctx.parent, @ptrCast(&ctx), .{ .wait_group = &wg, .backpressure = .block });
    wg.wait();

    pool.deinit();
    // Allocator leak check is implicit — test allocator reports on leaks.
}
```

- [ ] **Step 2: Verify test passes or catches the leak**

Run: `zig build test`
Expected: If worker cache still holds descriptors and they are lost on deinit, the descriptors array is freed but no memory leaks because descriptors are a fixed slice. This test will PASS regardless — but conceptually we still want the drain for correctness of `task_desc_live` observability.

Convert the test to check `task_desc_live` via `statsSnapshot` before deinit:

```zig
    const stats = pool.statsSnapshot();
    try std.testing.expectEqual(@as(u64, 0), stats.task_desc_live);
    pool.deinit();
```

This now FAILS pre-change because cached descriptors keep `task_desc_live > 0`.

- [ ] **Step 3: Implement worker cache drain**

Locate the worker-shutdown path in `Core.deinit`. Search: `grep -n 'fn deinit' src/pool.zig | head -5`. Before the `workers` slice is freed, add:

```zig
// Drain per-worker DescCaches back to the global freelist. After this,
// task_desc_live reflects only tasks that were actually executed.
for (self.workers) |*w| {
    var buf: [DescCache.capacity]u32 = undefined;
    const n = w.desc_cache.drainAll(&buf);
    var i: usize = 0;
    while (i < n) : (i += 1) self.releaseDescriptor(buf[i]);
}
```

- [ ] **Step 4: Run tests**

Run: `zig build test`
Expected: PASS.

- [ ] **Step 5: Stress**

Run: `for i in $(seq 1 20); do zig build test-stress -Doptimize=ReleaseFast || echo "FAIL $i"; done`
Expected: 20/20 PASS.

- [ ] **Step 6: Commit**

```bash
git add src/pool.zig tests/desc_cache_test.zig
git commit -m "fix(pool): drain per-worker DescCache on pool deinit"
```

### Task 3.4: Phase 3 A/B measurement and kill gate

- [ ] **Step 1: Repeat host quiescence check**

- [ ] **Step 2: Paired A/B — Phase-3 vs Phase-0 baseline**

Use git worktrees: `A = Phase-0 baseline commit`, `B = current HEAD`. n=10 balanced-order.

Record to `docs/performance/2026-04-16-go-gap-contended/runs/phase3-vs-baseline.json`.

- [ ] **Step 3: Also run Phase-3 vs Phase-2 checkpoint**

This isolates Phase 3's delta from Phase 2's. Record to `phase3-vs-phase2.json`.

- [ ] **Step 4: Apply kill criterion**

Phase-3 vs Phase-0 cumulative: `nested_fanout_4x` ≥ 18% → **KEEP**. Non-target regress > 3% = revert.

Phase-3 vs Phase-2 isolated: `nested_fanout_4x` ≥ 10% expected. If < 5%: consider Phase 3 a partial win but honest about scale.

- [ ] **Step 5: Commit results**

```bash
git add docs/performance/2026-04-16-go-gap-contended/runs/
git commit -m "docs: Phase 3 A/B results for Go-gap contended plan"
```

---

## Phase 4 — Final runtime-compare + docs refresh

**Files:**
- Create: `docs/performance/2026-04-16-go-gap-contended/FINAL.md`
- Modify: `CLAUDE.md` (Current Direct Runtime Snapshot section)
- Modify: `benchmarks/results/runtime-comparison-latest.json`
- Modify: `benchmarks/results/baseline.json` (if regression bench gate uses it)

### Task 4.1: Refresh runtime-compare artifacts

- [ ] **Step 1: Host quiescence**

- [ ] **Step 2: Run the standard refresh**

```bash
zig build bench-runtime-compare -Doptimize=ReleaseFast -- \
    --output benchmarks/results/runtime-comparison-latest.json \
    --samples 7 --warmup-discard 1
zig build bench -- --output benchmarks/results/latest.json
zig build scale-bench -- --output benchmarks/results/scale-latest.json
```

- [ ] **Step 3: Commit the updated artifacts**

```bash
git add benchmarks/results/runtime-comparison-latest.json \
        benchmarks/results/latest.json \
        benchmarks/results/scale-latest.json
git commit -m "perf: refresh bench artefacts post-Go-gap-contended plan"
```

### Task 4.2: Write FINAL.md

- [ ] **Step 1: Draft `docs/performance/2026-04-16-go-gap-contended/FINAL.md`**

Template — fill each section from the data:

```markdown
# Go-gap contended plan — FINAL

Plan: [`docs/superpowers/plans/2026-04-16-go-gap-contended.md`](../../superpowers/plans/2026-04-16-go-gap-contended.md)
Range: `<commit before Phase 0>` … `<commit after Phase 4>`
Date: 2026-04-16

## Headline: cross-snapshot gap vs Go

| Scenario | Baseline gap | Final gap | Change |
|----------|:------------:|:---------:|:------:|
| contended_spawn_8x  | 3.86x behind | <x> behind | <narrow/widen> |
| contended_cpu_10us  | 2.27x behind | <x> behind | <narrow/widen> |
| nested_fanout_4x    | 6.19x behind | <x> behind | <narrow/widen> |
| mixed_fast_slow     | 1.01x behind | <x>        | <narrow/widen> |

## Phase-by-phase isolated paired A/B (same-session)

| Phase | Scenario | A median | B median | Δ | Gate | Kept? |
|-------|----------|---------:|---------:|--:|:----:|:-----:|
| 1 | nested_fanout_4x | | | | ≥8% | |
| 2 | contended_spawn_8x | | | | ≥10% OR | |
| 2 | contended_cpu_10us | | | | ≥8% | |
| 3 | nested_fanout_4x (cumulative) | | | | ≥18% | |

## What landed

<table of phase → commit → description>

## What was skipped (and why)

<If phases were killed, document why. If not, say so.>

## Closed planes confirmed (did not re-attempt)

<Reference `project_iter9_closed_and_notify_ceiling.md` et al.>

## Next

<If gaps remain material, point to the pivot memory. If plan succeeded,
list any follow-ups that emerged.>
```

- [ ] **Step 2: Update CLAUDE.md "Current Direct Runtime Snapshot"**

Edit the two tables + interpretation bullets. Add a new interpretation bullet referencing this plan's FINAL.md.

- [ ] **Step 3: Commit docs**

```bash
git add docs/performance/2026-04-16-go-gap-contended/FINAL.md CLAUDE.md
git commit -m "docs: 2026-04-16 Go-gap contended plan — FINAL summary"
```

### Task 4.3: Memory update

- [ ] **Step 1: Update auto-memory**

Write a new memory file `~/.claude/projects/-home-benji-src-devnw-zig-thread-pool/memory/project_2026_04_16_go_gap_contended.md` summarizing:
- Which phases landed
- Same-session paired A/B numbers
- Any new closed planes (e.g. "batched freelist-take via DescCache closed on `flood_1m_batched`" if the mechanism didn't help there)
- Any new landed planes (DescCache itself; per-worker cache)

Add a one-line index entry to `MEMORY.md`.

This is a conversational task — no git commit needed for auto-memory.

---

## Self-review checklist

- [x] Every src/ modification has an explicit file:line citation.
- [x] Every task has complete code blocks (no "TBD", no "similar to above").
- [x] All tests are written before implementation (TDD structure intact).
- [x] Kill criteria are numeric, not hand-wavy.
- [x] Prior closed planes are explicitly excluded from scope.
- [x] Measurement protocol enforces the feedback_measurement_rules.md memory.
- [x] Each phase is independently revertible with clean commit boundaries.
- [x] `mixed_fast_slow` scope decision is justified (noise-floor).
- [x] Host-state caveat carried forward from 2026-04-16 contended plan.

## Execution handoff

Plan complete and saved to `docs/superpowers/plans/2026-04-16-go-gap-contended.md`. Two execution options:

**1. Subagent-Driven (recommended)** — dispatch a fresh subagent per task, review between tasks, fast iteration.

**2. Inline Execution** — execute tasks in this session using executing-plans, batch execution with checkpoints.

Which approach?
