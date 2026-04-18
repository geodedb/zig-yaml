# Steal-Scan Bitmap Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the O(N²) sibling-peek steal scan in `src/pool.zig` with an O(1) bitmap-driven scan. Target ≥ 700K ops/s on `bench_tokio_parity/flood_1m` (current baseline: 340K).

**Architecture:** Add `Core.non_empty_workers: std.atomic.Value(u64)` where bit `i` tracks "local_queue[i] non-empty." Three update sites maintain it: owner push (unconditional `fetchOr`), owner pop-to-empty (`fetchAnd` + re-check), successful-steal drain (`fetchAnd` + re-check). Stealer loads the bitmap once, masks its own bit, rotates by a per-worker seed for load balancing, and iterates set bits with `@ctz`. Hard cap of 64 workers enforced in `Config.validate()`.

**Tech Stack:** Zig 0.15.2, `std.atomic.Value(u64)`, `@ctz` / `@popCount`, existing `benchmarks/common.zig` + `bench_tokio_parity` harness, `perf stat` for cache-miss / IPC measurement.

**Reference design spec:** `docs/superpowers/specs/2026-04-12-steal-scan-bitmap-design.md` — all design decisions locked there; this plan is the mechanical execution.

**Performance Targets (success criteria):**

| Metric | Baseline (Phase C) | Target | Stretch |
|---|---:|---:|---:|
| `bench_tokio_parity/flood_1m` ops/s | 340K | ≥ 700K | ≥ 900K |
| `bench_tokio_parity/contended_spawn_8x` ops/s | 534K | ≥ 900K | ≥ 1.1M |
| Cache-miss rate (`perf stat`) | 34.1% | ≤ 8% | ≤ 5% |
| IPC (`perf stat`) | 0.19 | ≥ 1.0 | ≥ 1.5 |
| Submit p50 | 917 ns | ≤ 1000 ns | ≤ 950 ns |
| Submit p99 | 1690 ns | ≤ 1800 ns | ≤ 1700 ns |
| `test-stress` 5× consecutive | pass | pass | pass |

**Rollback floor:** `flood_1m` median < 550K ops/s. If below, the bitmap maintenance cost is eating the scan win; file a follow-up task targeting per-worker cached bit-state (set only on empty→non-empty transition).

---

## File Structure

**Modified files:**

- `src/types.zig` — add `error.TooManyWorkers` in `Config.validate()`, doc the 64-worker cap on `Config.max_threads`.
- `src/pool.zig` — add `worker_bit` helper, `Core.non_empty_workers` field, `Worker.steal_rot_seed` field, three bit-update sites, rewrite stealer scan.
- `tests/unit.zig` — add `TooManyWorkers` validation test + bitmap-invariant racing-threads test.
- `tests/stress.zig` — add 56-worker (or `@min(cpu_count, 64)`) flood stress test.
- `docs/PERFORMANCE_TRACKING.md` — add Phase E section with measurements.
- `benchmarks/results/baseline.json` — rebaseline on success.

**New files:** none.

**Responsibility split:**

- `src/types.zig` stays config-only (no concurrency primitives).
- `src/pool.zig` owns the bitmap field, all bit-update sites, and the scan rewrite. `worker_bit` is a file-local `inline fn` near the top of the file.
- Tests exercise (a) validation, (b) protocol invariant under contention, (c) end-to-end stress on a wide pool, (d) benchmark acceptance.

---

## Phase 1: Config Validation

### Task 1: Add `error.TooManyWorkers` to `Config.validate()`

**Files:**

- Modify: `src/types.zig` (`Config.validate`, around line 126-136)
- Modify: `src/types.zig` (`Config.max_threads` field doc, line 68)
- Test: `tests/unit.zig` (append)

- [ ] **Step 1: Write the failing test**

Append this test to `tests/unit.zig`:

```zig
test "Config validate rejects max_threads > 64" {
    const cfg = thread_pool.Config{ .max_threads = 65, .min_threads = 1 };
    try std.testing.expectError(error.TooManyWorkers, cfg.validate());
}

test "Config validate accepts max_threads = 64" {
    const cfg = thread_pool.Config{ .max_threads = 64, .min_threads = 1 };
    try cfg.validate();
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd /home/benji/src/devnw/zig/thread-pool-lockfree-bp && zig build test-unit -- --test-filter "Config validate rejects max_threads"`
Expected: FAIL with `error.TooManyWorkers` not recognized, or test returns `void` where error expected.

- [ ] **Step 3: Add the validation to `Config.validate()`**

In `src/types.zig`, modify `pub fn validate(self: Config) !void` (around line 126). Add as the first check after `max_threads == 0`:

```zig
pub fn validate(self: Config) !void {
    if (self.max_threads == 0) return error.InvalidMaxThreads;
    if (self.max_threads > 64) return error.TooManyWorkers;
    if (self.min_threads == 0) return error.InvalidMinThreads;
    if (self.min_threads > self.max_threads) return error.InvalidThreadBounds;
    if (self.queue_capacity == 0 or self.queue_capacity > std.math.maxInt(u32)) return error.InvalidQueueCapacity;
    if (self.local_queue_capacity == 0) {
        return error.InvalidLocalQueueCapacity;
    }
    if (self.scheduler_variant == .lane_extension) return error.UnsupportedSchedulerVariant;
    if (self.inject_batch_size == 0) return error.InvalidInjectBatchSize;
}
```

- [ ] **Step 4: Update the `max_threads` field doc comment**

In `src/types.zig`, replace the existing `max_threads: usize = 0,` declaration (around line 68) with:

```zig
/// Maximum worker threads. Hard capped at 64 because the steal-scan
/// non-empty-workers bitmap uses a single u64. `validate()` rejects
/// values > 64 with `error.TooManyWorkers`. 0 means "auto-detect from
/// CPU count" in `normalized()`; the clamp still applies post-detection
/// via `std.math.clamp` — see `normalized()`.
max_threads: usize = 0,
```

- [ ] **Step 5: Update `normalized()` to clamp auto-detect to 64**

In `src/types.zig`, locate `normalized()` (around line 99). Modify the auto-detect block so CPU counts above 64 get clamped:

```zig
if (cfg.max_threads == 0) {
    cfg.max_threads = @min(cpu_guess, 64);
}
```

Replace only the inner `cfg.max_threads = cpu_guess;` line. The surrounding `if (cfg.max_threads == 0)` stays.

- [ ] **Step 6: Run tests to verify they pass**

Run: `cd /home/benji/src/devnw/zig/thread-pool-lockfree-bp && zig build test-unit -- --test-filter "Config validate"`
Expected: PASS for both new tests.

Also run: `cd /home/benji/src/devnw/zig/thread-pool-lockfree-bp && zig build test`
Expected: full suite passes (no existing test relies on > 64 workers).

- [ ] **Step 7: Commit**

```bash
cd /home/benji/src/devnw/zig/thread-pool-lockfree-bp && git add src/types.zig tests/unit.zig && git commit -m "feat(types): cap max_threads at 64 for steal-scan bitmap"
```

---

## Phase 2: Bitmap Infrastructure

### Task 2: Add `worker_bit` helper, `Core.non_empty_workers` field, and `Worker.steal_rot_seed`

**Files:**

- Modify: `src/pool.zig` (near top-of-file helpers; `Worker` struct; `Core` struct)

This task adds the state but no behavior. Nothing reads or writes the bitmap yet. The purpose is to ship the plumbing in a small, easily-reviewed commit so the subsequent behavior-change commits are minimal.

- [ ] **Step 1: Add `worker_bit` helper**

In `src/pool.zig`, immediately before the `LIFO_SLOT_EMPTY` constant declaration (currently around line 144), add:

```zig
/// Returns the bitmap bit corresponding to a worker index. The steal-scan
/// bitmap (`Core.non_empty_workers`) has one bit per worker; bit `i` is set
/// when `local_queues[i].len() > 0` (modulo the lazy-clear protocol; see
/// the bit-maintenance protocol in docs/superpowers/specs/2026-04-12-steal-scan-bitmap-design.md).
inline fn worker_bit(i: usize) u64 {
    return @as(u64, 1) << @intCast(i);
}
```

- [ ] **Step 2: Add `steal_rot_seed` to `Worker`**

In `src/pool.zig`, locate the `Worker` struct (around line 148). Add a new field immediately after `lifo_slot`:

```zig
    lifo_slot: std.atomic.Value(u32) = std.atomic.Value(u32).init(LIFO_SLOT_EMPTY),
    /// Per-worker counter used to rotate the steal-scan bitmap so that
    /// different stealers bias toward different first candidates instead
    /// of all converging on the lowest-indexed non-empty worker. Read
    /// and written only by the owning worker thread — no atomic needed.
    steal_rot_seed: u32 = 0,
};
```

- [ ] **Step 3: Add `non_empty_workers` to `Core`**

In `src/pool.zig`, locate the `Core` struct (around line 224). Add the field between `free_top_tagged` and `inject_queue`:

```zig
    free_top_tagged: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    /// Bit `i` set ⇔ `local_queues[i]` non-empty (modulo lazy-clear slack).
    /// Read by stealers to identify candidate victims in O(1); written by
    /// owner push/pop and by stealers that drain a victim. See
    /// docs/superpowers/specs/2026-04-12-steal-scan-bitmap-design.md.
    non_empty_workers: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    inject_queue: BoundedRing(u32),
```

- [ ] **Step 4: Build**

Run: `cd /home/benji/src/devnw/zig/thread-pool-lockfree-bp && zig build`
Expected: SUCCESS. No behavior change, no new warnings.

- [ ] **Step 5: Run full test suite (smoke)**

Run: `cd /home/benji/src/devnw/zig/thread-pool-lockfree-bp && zig build test`
Expected: PASS. The field is inert at this point.

- [ ] **Step 6: Commit**

```bash
cd /home/benji/src/devnw/zig/thread-pool-lockfree-bp && git add src/pool.zig && git commit -m "feat(pool): add non_empty_workers bitmap + steal_rot_seed (inert)"
```

---

## Phase 3: Bit Update Sites

### Task 3: Bit-set on owner push in `enqueueTask`

**Files:**

- Modify: `src/pool.zig` (`enqueueTask`, around lines 550-570)

- [ ] **Step 1: Locate the `tryPushBottom` branch in `enqueueTask`**

Open `src/pool.zig` around line 550. The relevant block is currently:

```zig
if (self.config.scheduler_variant == .work_stealing and tls_worker_index != null) {
    const wi = tls_worker_index.?;
    const w = &self.workers[wi];
    if (w.lifo_slot.load(.monotonic) == LIFO_SLOT_EMPTY) {
        w.lifo_slot.store(descriptor_index, .release);
        queued = true;
    } else {
        queued = self.local_queues[wi].tryPushBottom(descriptor_index);
        if (queued) {
            const local_len = @as(u32, @intCast(self.local_queues[wi].len()));
            updatePeakU32(&w.local_queue_peak, local_len);
        }
    }
}
```

- [ ] **Step 2: Set the bit when `tryPushBottom` succeeds**

Modify the `else` branch so the successful push path sets the bit via `fetchOr`:

```zig
} else {
    queued = self.local_queues[wi].tryPushBottom(descriptor_index);
    if (queued) {
        _ = self.non_empty_workers.fetchOr(worker_bit(wi), .release);
        const local_len = @as(u32, @intCast(self.local_queues[wi].len()));
        updatePeakU32(&w.local_queue_peak, local_len);
    }
}
```

The `_ =` discards the returned previous value; `fetchOr` is idempotent — setting an already-set bit is free at the semantics level, still one RMW at the hardware level.

**Note:** The LIFO slot path does NOT set the bitmap bit. Stealers never touch the LIFO slot, so it need not advertise work; the owner always drains its own LIFO slot via `nextTask`'s first check.

**Note:** The inject-queue fallback path also does NOT set the bitmap bit. The bitmap tracks local queues only; the inject queue is a separate check in `nextTask` (unchanged). Inject pushes don't advertise work via the bitmap.

- [ ] **Step 3: Build**

Run: `cd /home/benji/src/devnw/zig/thread-pool-lockfree-bp && zig build`
Expected: SUCCESS.

- [ ] **Step 4: Run the full test suite**

Run: `cd /home/benji/src/devnw/zig/thread-pool-lockfree-bp && zig build test`
Expected: PASS. Bit is now set on push but no reader → still inert effectively.

- [ ] **Step 5: Commit**

```bash
cd /home/benji/src/devnw/zig/thread-pool-lockfree-bp && git add src/pool.zig && git commit -m "feat(pool): set non_empty_workers bit on owner push to local ring"
```

### Task 4: Bit-clear-with-recheck on owner pop-to-empty in `nextTask`

**Files:**

- Modify: `src/pool.zig` (`nextTask`, around lines 644-648)

- [ ] **Step 1: Locate the local `popBottom` branch**

In `src/pool.zig`, `nextTask` currently has:

```zig
if (lq.popBottom()) |descriptor_index| {
    self.decrementQueued();
    return descriptor_index;
}
```

- [ ] **Step 2: Add bit-clear-with-recheck on drain**

Modify to:

```zig
if (lq.popBottom()) |descriptor_index| {
    if (lq.len() == 0) {
        _ = self.non_empty_workers.fetchAnd(~worker_bit(worker_index), .release);
        // Re-check: a concurrent push may have raced our clear.
        if (lq.len() != 0) {
            _ = self.non_empty_workers.fetchOr(worker_bit(worker_index), .release);
        }
    }
    self.decrementQueued();
    return descriptor_index;
}
```

The `~worker_bit(worker_index)` mask clears exactly this worker's bit; other bits untouched.

Cost analysis:

- Non-drain pops (common under flood): one extra `lq.len()` call (two acquire loads on owner-local atomics — cheap, in L1).
- Drain pops: one `len()` + one `fetchAnd` + one `len()` + possibly one `fetchOr`. Happens only on the empty transition.

- [ ] **Step 3: Build**

Run: `cd /home/benji/src/devnw/zig/thread-pool-lockfree-bp && zig build`
Expected: SUCCESS.

- [ ] **Step 4: Run full test suite**

Run: `cd /home/benji/src/devnw/zig/thread-pool-lockfree-bp && zig build test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd /home/benji/src/devnw/zig/thread-pool-lockfree-bp && git add src/pool.zig && git commit -m "feat(pool): clear non_empty_workers bit on owner pop-to-empty"
```

### Task 5: Bit-clear-with-recheck on successful steal drain

**Files:**

- Modify: `src/pool.zig` (`nextTask`, around lines 680-700, still inside the work_stealing branch)

This change still uses the OLD O(N²) scan — we'll rewrite the scan itself in Task 6. The goal here is just to add the drain-detection + bit clear inside the existing scan.

- [ ] **Step 1: Locate the existing steal block**

In `src/pool.zig`, the current steal block inside `nextTask` reads (around lines 678-700):

```zig
var stolen: [32]u32 = undefined;
const budget = @min(self.config.steal_batch_size, stolen.len);
const n = self.local_queues[victim_index].steal(stolen[0..budget]);
if (n > 0) {
    const first = stolen[0];
    for (stolen[1..n]) |idx| {
        if (!lq.tryPushBottom(idx)) {
            _ = self.inject_queue.tryPush(idx);
        }
    }
    self.decrementQueued();
    _ = worker.steals.fetchAdd(n, .release);
    const local_len: u32 = @intCast(lq.len());
    updatePeakU32(&worker.local_queue_peak, local_len);
    return first;
}
```

- [ ] **Step 2: Add victim-bit-clear-with-recheck after successful steal**

Modify the `if (n > 0)` block to:

```zig
if (n > 0) {
    const first = stolen[0];
    for (stolen[1..n]) |idx| {
        if (!lq.tryPushBottom(idx)) {
            _ = self.inject_queue.tryPush(idx);
        }
    }
    // If the steal drained the victim, clear its bit so other stealers
    // skip it. Re-check to tolerate a concurrent push from the owner.
    if (self.local_queues[victim_index].len() == 0) {
        _ = self.non_empty_workers.fetchAnd(~worker_bit(victim_index), .release);
        if (self.local_queues[victim_index].len() != 0) {
            _ = self.non_empty_workers.fetchOr(worker_bit(victim_index), .release);
        }
    }
    // The stealer itself pushed to its own local_queue above (for stolen[1..n]).
    // If n >= 2, stealer's bit may need setting. Cheap idempotent fetchOr.
    if (n >= 2) {
        _ = self.non_empty_workers.fetchOr(worker_bit(worker_index), .release);
    }
    self.decrementQueued();
    _ = worker.steals.fetchAdd(n, .release);
    const local_len: u32 = @intCast(lq.len());
    updatePeakU32(&worker.local_queue_peak, local_len);
    return first;
}
```

Two additions:

- **Victim bit clear** if the steal drained the victim.
- **Stealer bit set** when `n >= 2` (the stealer pushed `n-1` descriptors into its own local queue). `n == 1` means no push into local — stealer returns `first` directly, no bit-set needed.

- [ ] **Step 3: Build**

Run: `cd /home/benji/src/devnw/zig/thread-pool-lockfree-bp && zig build`
Expected: SUCCESS.

- [ ] **Step 4: Run full test suite**

Run: `cd /home/benji/src/devnw/zig/thread-pool-lockfree-bp && zig build test`
Expected: PASS. The old scan still works correctly; the bitmap is now maintained on all three protocol sites but still not read by anyone.

- [ ] **Step 5: Run stress tests 3× to confirm no correctness regression**

```bash
cd /home/benji/src/devnw/zig/thread-pool-lockfree-bp && for i in 1 2 3; do echo "=== $i ==="; zig build test-stress || exit 1; done
```

Expected: 3/3 pass. If any fails, STOP and diagnose before proceeding — the bit-update code has a correctness bug.

- [ ] **Step 6: Commit**

```bash
cd /home/benji/src/devnw/zig/thread-pool-lockfree-bp && git add src/pool.zig && git commit -m "feat(pool): maintain non_empty_workers bit on steal drain"
```

---

## Phase 4: Stealer Scan Rewrite

### Task 6: Replace O(N²) sibling-peek scan with bitmap-driven scan

**Files:**

- Modify: `src/pool.zig` (`nextTask`, the entire work_stealing steal loop around lines 665-704)

This is the core performance win. All three bit-update sites are already maintaining the bitmap; this task makes the scan read from it.

- [ ] **Step 1: Locate the current scan loop**

In `src/pool.zig`, the current scan (lines ~665-704) reads:

```zig
// Use worker_index mixed with submitted count for pseudo-random start.
// Avoids global atomic fetchAdd contention that causes thundering-herd
// when all idle workers get sequential starting indices.
const start = (worker_index +% @as(usize, @truncate(self.counters.submitted.load(.monotonic)))) % self.workers.len;
var offset: usize = 0;
while (offset < self.workers.len) : (offset += 1) {
    const victim_index = (start + offset) % self.workers.len;
    if (victim_index == worker_index) continue;
    // Cheap peek before paying the seq_cst CAS cost in steal().
    // len() reads bottom and top with acquire loads; under contention it
    // may return a stale value, but skipping a victim that *appears* empty
    // just means we move to the next one — correctness is unaffected.
    if (self.local_queues[victim_index].len() == 0) continue;
    var stolen: [32]u32 = undefined;
    const budget = @min(self.config.steal_batch_size, stolen.len);
    const n = self.local_queues[victim_index].steal(stolen[0..budget]);
    if (n > 0) {
        // ... (the block we modified in Task 5)
    }
}

_ = worker.steal_failures.fetchAdd(1, .release);
return null;
```

- [ ] **Step 2: Replace the scan with a bitmap-driven version**

Replace the entire block above (from `const start = ...` through `return null;`) with:

```zig
// Bitmap-driven scan: load non_empty_workers once, mask out self,
// rotate by a per-worker seed for load balancing, iterate set bits
// via @ctz. See docs/superpowers/specs/2026-04-12-steal-scan-bitmap-design.md
// for correctness argument.
const self_bit = worker_bit(worker_index);
const raw_bitmap = self.non_empty_workers.load(.acquire) & ~self_bit;
worker.steal_rot_seed +%= 1;
const rot: u6 = @truncate(worker.steal_rot_seed % @as(u32, 64));
var bitmap = std.math.rotr(u64, raw_bitmap, rot);
while (bitmap != 0) {
    const tz: u6 = @intCast(@ctz(bitmap));
    bitmap &= bitmap - 1;
    const victim_index = (@as(usize, tz) + @as(usize, rot)) % 64;
    if (victim_index >= self.workers.len) continue;
    if (victim_index == worker_index) continue; // defensive — already masked
    var stolen: [32]u32 = undefined;
    const budget = @min(self.config.steal_batch_size, stolen.len);
    const n = self.local_queues[victim_index].steal(stolen[0..budget]);
    if (n > 0) {
        const first = stolen[0];
        for (stolen[1..n]) |idx| {
            if (!lq.tryPushBottom(idx)) {
                _ = self.inject_queue.tryPush(idx);
            }
        }
        // Victim bit maintenance (from Task 5).
        if (self.local_queues[victim_index].len() == 0) {
            _ = self.non_empty_workers.fetchAnd(~worker_bit(victim_index), .release);
            if (self.local_queues[victim_index].len() != 0) {
                _ = self.non_empty_workers.fetchOr(worker_bit(victim_index), .release);
            }
        }
        if (n >= 2) {
            _ = self.non_empty_workers.fetchOr(worker_bit(worker_index), .release);
        }
        self.decrementQueued();
        _ = worker.steals.fetchAdd(n, .release);
        const local_len: u32 = @intCast(lq.len());
        updatePeakU32(&worker.local_queue_peak, local_len);
        return first;
    }
}

_ = worker.steal_failures.fetchAdd(1, .release);
return null;
```

**Design notes:**

- `rot` is a `u6` (0..63), so the rotation distance fits in one register.
- `(tz + rot) % 64` reconstructs the original (unrotated) bit index. The `% 64` reflects the 64-bit bitmap width.
- `victim_index >= self.workers.len` guards against the case where `max_threads < 64` and the bitmap has unused high bits (which should be zero via `worker_bit`, but we stay defensive — the rotation can alias an in-range bit to an out-of-range index if `workers.len` is not 64).
- The `continue` on `victim_index == worker_index` is defensive belt-and-suspenders; `raw_bitmap & ~self_bit` already excluded the self bit, but if a stealer's own bit is set post-steal via Task 5 and aliases back to `worker_index` through rotation, we skip safely.

Wait — there's a subtle indexing bug in the above. After masking out self_bit, we rotate the masked bitmap. When we `@ctz` to find a set bit at position `tz`, reconstructing the original index is `(tz + rot) % 64`. But the rotation was `rotr(raw, rot)` which means "bit `k` of `raw` became bit `(k + rot) % 64`" — ergo bit at position `tz` in the rotated word came from bit `(tz + rot) % 64` of `raw`. Correct.

Test-time verification: if `raw_bitmap = 0b0000_0100` (bit 2 set) and `rot = 3`, `rotr(0b0000_0100, 3) = 0b1000_0000_…_0000` (bit 2-3 = -1 = 63 mod 64). `@ctz = 63`. Reconstructed index: `(63 + 3) % 64 = 2`. Correct.

- [ ] **Step 3: Build**

Run: `cd /home/benji/src/devnw/zig/thread-pool-lockfree-bp && zig build`
Expected: SUCCESS. If Zig complains about integer coercion at `@intCast(@ctz(bitmap))`, `@ctz` on a u64 returns a `u7` (since 0..64 inclusive); switch the cast to `@intCast(@as(u7, @ctz(bitmap)))` or keep `tz` as `u7` and compute `victim_index = (@as(usize, tz) + @as(usize, rot)) % 64` — the arithmetic is the same either way.

- [ ] **Step 4: Run full test suite**

Run: `cd /home/benji/src/devnw/zig/thread-pool-lockfree-bp && zig build test`
Expected: PASS — the bitmap is now both written and read. This is the smoke test that the protocol is correct.

- [ ] **Step 5: Run stress tests 5× consecutive**

```bash
cd /home/benji/src/devnw/zig/thread-pool-lockfree-bp && for i in 1 2 3 4 5; do echo "=== $i ==="; zig build test-stress || exit 1; done
```

Expected: 5/5 pass. Any hang or test-loss failure means the bitmap clear-then-push race isn't being recovered by the re-check — STOP and diagnose.

- [ ] **Step 6: Commit**

```bash
cd /home/benji/src/devnw/zig/thread-pool-lockfree-bp && git add src/pool.zig && git commit -m "perf(pool): replace O(N²) sibling-peek with O(1) bitmap steal scan"
```

---

## Phase 5: Targeted Tests

### Task 7: Bitmap-invariant racing-threads unit test

**Files:**

- Modify: `tests/unit.zig` (append)

- [ ] **Step 1: Write the test**

Append this test to `tests/unit.zig`:

```zig
test "non_empty_workers bitmap invariant under racing push/pop" {
    // 8 workers pushing/popping 10k random ops each; after quiesce,
    // for every worker i: bitmap-bit-i-set iff local_queue[i].len() > 0.
    // This stresses the owner push (set), owner pop-to-empty (clear+recheck),
    // and steal drain (clear+recheck) protocol.
    var pool = try thread_pool.ThreadPool.init(std.testing.allocator, .{
        .min_threads = 8,
        .max_threads = 8,
        .queue_capacity = 4096,
        .local_queue_capacity = 256,
        .scheduler_variant = .work_stealing,
    });
    defer pool.deinit();

    var counter = common.Counter{};
    var wg = pool.waitGroup();

    const total: u64 = 80_000;
    var i: u64 = 0;
    while (i < total) : (i += 1) {
        _ = try pool.submit(common.counterTask, @ptrCast(&counter), .{ .wait_group = &wg });
    }
    wg.wait();
    try std.testing.expectEqual(total, counter.value.load(.acquire));

    // Post-quiesce invariant check. Give workers a brief window to drain
    // any late stragglers so the bitmap settles.
    std.Thread.sleep(5 * std.time.ns_per_ms);
    const stats = pool.statsSnapshot();
    try std.testing.expectEqual(@as(u64, 0), stats.queued_tasks);
    try std.testing.expectEqual(@as(u64, 0), stats.active_tasks);

    // All workers should now have empty local queues, so ideally the
    // bitmap is 0. The Tokio-style re-check protocol allows transient
    // spurious set bits (a steal observed empty, cleared, then the owner
    // pushed and raced back). Post-quiesce with no live work, no pushes
    // are happening, so the bitmap must be 0.
    //
    // We don't have public API to inspect Core.non_empty_workers, so we
    // verify correctness indirectly: submit one more task and confirm
    // it executes. If the bitmap were erroneously "all set," stealers
    // would waste time on empty victims; if "all clear" when non-empty,
    // the task wouldn't be found. Either way the follow-up submit would
    // eventually succeed via inject-queue fallback, so this test does
    // NOT catch bitmap drift — it's a smoke test that the protocol
    // doesn't *break* correctness. The real bitmap correctness guarantee
    // comes from the stress tests + the 5× consecutive run gate.
    var final_counter = common.Counter{};
    var final_wg = pool.waitGroup();
    _ = try pool.submit(common.counterTask, @ptrCast(&final_counter), .{ .wait_group = &final_wg });
    final_wg.wait();
    try std.testing.expectEqual(@as(u64, 1), final_counter.value.load(.acquire));
}
```

- [ ] **Step 2: Run the test**

Run: `cd /home/benji/src/devnw/zig/thread-pool-lockfree-bp && zig build test-unit -- --test-filter "non_empty_workers bitmap invariant"`
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
cd /home/benji/src/devnw/zig/thread-pool-lockfree-bp && git add tests/unit.zig && git commit -m "test(unit): bitmap invariant smoke under 8-worker racing push/pop"
```

### Task 8: Wide-pool flood stress test

**Files:**

- Modify: `tests/stress.zig` (append)

- [ ] **Step 1: Append the stress test**

Add to the end of `tests/stress.zig`:

```zig
test "steal-scan bitmap: wide-pool flood with cpu-count workers" {
    // Exercises the bitmap scan under realistic high-worker-count pressure:
    // cpu_count (clamped to 64) workers, single submitter, 200k tasks.
    // With the O(N²) sibling-peek scan this scenario thrashes; with the
    // bitmap it should complete cleanly. Primary goal: hang/correctness
    // regression guard, not a throughput assertion.
    const cpu_count = @min(std.Thread.getCpuCount() catch 4, 64);
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

- [ ] **Step 2: Run the test**

Run: `cd /home/benji/src/devnw/zig/thread-pool-lockfree-bp && zig build test-stress -- --test-filter "steal-scan bitmap: wide-pool flood"`
Expected: PASS, wall time < 5 s on a 56-core machine.

- [ ] **Step 3: Run full stress suite 3× consecutive**

```bash
cd /home/benji/src/devnw/zig/thread-pool-lockfree-bp && for i in 1 2 3; do echo "=== $i ==="; zig build test-stress || exit 1; done
```

Expected: 3/3 pass.

- [ ] **Step 4: Commit**

```bash
cd /home/benji/src/devnw/zig/thread-pool-lockfree-bp && git add tests/stress.zig && git commit -m "test(stress): wide-pool flood bitmap steal-scan"
```

---

## Phase 6: Measure, Rebaseline, Document

### Task 9: Measure benchmarks, verify acceptance gates, rebaseline

**Files:** none modified by this task (measurement + baseline).

- [ ] **Step 1: Build ReleaseFast**

Run: `cd /home/benji/src/devnw/zig/thread-pool-lockfree-bp && zig build -Doptimize=ReleaseFast`
Expected: SUCCESS.

- [ ] **Step 2: Run `bench-tokio-parity` 5 times, record results**

For each iteration `i` in 1..5:

```bash
cd /home/benji/src/devnw/zig/thread-pool-lockfree-bp && zig build bench-tokio-parity -Doptimize=ReleaseFast
```

Capture the `flood_1m` and `contended_spawn_8x` ops/s columns from stdout. Record all 5 values for each scenario.

If `zig build` caches and doesn't actually re-run the binary on subsequent invocations, locate the built artifact (likely under `.zig-cache/o/<hash>/thread-pool-tokio-parity` or `zig-out/bin/bench_tokio_parity`) and invoke it directly. Record the value each run.

- [ ] **Step 3: Compute medians and check gates**

Sort each list of 5 values. The 3rd (middle) is the median. Report and compare against the acceptance table:

| Metric | Baseline | Gate | Measured median | Pass/Fail |
|---|---:|---:|---:|---:|
| flood_1m | 340K | ≥ 700K | TBD | TBD |
| contended_spawn_8x | 534K | ≥ 900K | TBD | TBD |

If flood_1m median is **≥ 700K**: ALL GOOD, proceed to step 4.
If **550K ≤ median < 700K**: PARTIAL — the change is directionally correct but below target. STOP and report PARTIAL before rebaselining; the controller decides whether to ship or investigate further.
If **median < 550K**: ROLLBACK FLOOR TRIGGERED. STOP and report BLOCKED. Do not rebaseline.

- [ ] **Step 4: Run `bench-micro-submit` to check submit latency**

```bash
cd /home/benji/src/devnw/zig/thread-pool-lockfree-bp && zig build bench-micro-submit -Doptimize=ReleaseFast
```

Record the p50/p95/p99 line. Gates: p50 ≤ 1000 ns, p99 ≤ 1800 ns. If either regresses, note it but do not block — discuss in the Phase E doc.

- [ ] **Step 5: Run `perf stat` to verify cache-miss collapse**

```bash
cd /home/benji/src/devnw/zig/thread-pool-lockfree-bp && zig build -Doptimize=ReleaseFast
# Find the bench_tokio_parity binary (most likely path shown below; adjust if needed):
BIN=$(find .zig-cache/o -name "thread-pool-tokio-parity" -executable 2>/dev/null | head -1)
perf stat -e task-clock,cycles,instructions,cache-misses,cache-references,context-switches $BIN
```

Record: cache-miss rate (cache-misses / cache-references × 100), IPC (instructions / cycles), context-switches. Compare to baseline (34.1% cache-miss, 0.19 IPC, ~1M context-switches).

Gates:

- Cache-miss rate ≤ 8%: primary confirmation the ping-pong collapsed.
- IPC ≥ 1.0: confirms stalls gone.
- Context-switches ≤ 400K: confirms park frequency shrank as a side effect.

If cache-miss rate didn't drop below ~15%, the bitmap isn't eliminating the access pattern — re-check that the new scan really isn't peeking sibling `(top, bottom)` anywhere.

- [ ] **Step 6: Run full `bench` CI suite**

```bash
cd /home/benji/src/devnw/zig/thread-pool-lockfree-bp && zig build bench -Doptimize=ReleaseFast
```

Expected: completes without any scenario failing. Note numbers for `conn_churn_seq/*` and `producer_contention/*` — they should hold steady or improve.

- [ ] **Step 7: Rebaseline**

```bash
cd /home/benji/src/devnw/zig/thread-pool-lockfree-bp && mkdir -p benchmarks/results && zig build bench -Doptimize=ReleaseFast -- --output benchmarks/results/baseline.json
```

Verify the file changed:

```bash
cd /home/benji/src/devnw/zig/thread-pool-lockfree-bp && git diff benchmarks/results/baseline.json | head -20
```

- [ ] **Step 8: Commit the new baseline**

```bash
cd /home/benji/src/devnw/zig/thread-pool-lockfree-bp && git add benchmarks/results/baseline.json && git commit -m "bench: rebaseline after steal-scan bitmap"
```

### Task 10: Update `PERFORMANCE_TRACKING.md` with Phase E section

**Files:**

- Modify: `docs/PERFORMANCE_TRACKING.md`

- [ ] **Step 1: Append Phase E section**

Open `docs/PERFORMANCE_TRACKING.md` and insert a new section AFTER the existing `## Phase D: Lock-Free Backpressure (negative result — REVERTED)` block and BEFORE `## Bench Stability`.

Use this template — fill in the TBD cells with the numbers from Task 9:

````markdown
## Phase E: Steal-Scan Bitmap

**Shipped:**

1. **`Core.non_empty_workers: std.atomic.Value(u64)`** — one bit per worker, set on owner local-queue push, cleared on owner pop-to-empty or steal drain with Tokio-style re-check.
2. **O(1) stealer scan** — stealers load the bitmap, mask out self, rotate by a per-worker seed, iterate set bits via `@ctz`. Replaces the former O(N²) sibling `(top, bottom)` peek loop.
3. **Hard cap at 64 workers** — `Config.validate()` returns `error.TooManyWorkers` for `max_threads > 64`. `normalized()` clamps auto-detected CPU counts to 64.

**Design spec:** `docs/superpowers/specs/2026-04-12-steal-scan-bitmap-design.md`.

**Rationale:** Phase D's perf profile attributed 42.1% of `flood_1m` cycles to the sibling-peek scan's cross-core cacheline ping-pong. This phase eliminates that O(N²) cost structurally.

### Phase E measurements (git SHA TBD, median of 5 runs ReleaseFast)

| Metric | Phase C | Phase E | Delta | Target | Met? |
|---|---:|---:|---:|---:|---:|
| Tokio flood_1m | 340K | TBD | TBD | ≥ 700K | TBD |
| Tokio contended_spawn_8x | 534K | TBD | TBD | ≥ 900K | TBD |
| Submit p50 (1 worker, 100k samples) | 917 ns | TBD | TBD | ≤ 1000 ns | TBD |
| Submit p99 | 1690 ns | TBD | TBD | ≤ 1800 ns | TBD |
| `perf stat` cache-miss rate | 34.1% | TBD | TBD | ≤ 8% | TBD |
| `perf stat` IPC | 0.19 | TBD | TBD | ≥ 1.0 | TBD |
| Context-switches / 1M tasks | ~1.0M | TBD | TBD | ≤ 400K | TBD |
| `conn_churn_seq/global_queue` | 758K | TBD | TBD | within 3×stddev | TBD |
| `conn_churn_seq/work_stealing` | 683K | TBD | TBD | within 3×stddev | TBD |
| `test-stress` 5× consecutive | pass | pass | — | pass | TBD |

### Residual gap to Tokio parity

With the steal-scan reclaimed, the next-largest slice is the per-task worker park/unpark path (was 17% of Phase D cycles; may have shrunk as a side effect of workers finding work faster — re-profile). Follow-up plans in priority order:

1. **Phase F: park/unpark reduction.** Keep-alive spin window on recent-submit workers, notify-coalescing, or event-based worker wakes.
2. **Phase G: inject queue & descriptor pool.** Re-profile post-F.
3. **Phase H: worker-local allocation / cache locality.**
````

- [ ] **Step 2: Fill in the TBD cells**

Using the numbers captured in Task 9, replace every `TBD` in the Phase E section with the actual measurement. Add a git SHA for the rebaseline commit (from Task 9 step 8) in the "(git SHA TBD)" placeholder.

- [ ] **Step 3: Update the top-of-file "Verdict vs Targets" table**

Locate the row for `bench_tokio_parity/flood_1m ≥ 1M ops/s` (near line 21) and append the Phase E number to the "After plan" cell. Example format:

```
| `bench_tokio_parity/flood_1m` ≥ 1M ops/s | 297K | 340K (Phase C) / 341K (Phase D, reverted) / TBD (Phase E) | ⚠️/❌/❓ |
```

Same for the `contended_spawn_8x` row.

- [ ] **Step 4: Commit**

```bash
cd /home/benji/src/devnw/zig/thread-pool-lockfree-bp && git add docs/PERFORMANCE_TRACKING.md && git commit -m "docs(perf): Phase E verdict, rebaseline after steal-scan bitmap"
```

---

## Self-Review Checklist

Before declaring the plan complete:

- [ ] `Config.validate()` rejects `max_threads > 64` with `error.TooManyWorkers`.
- [ ] `normalized()` clamps auto-detected CPU count to 64.
- [ ] `Core.non_empty_workers` field exists.
- [ ] `Worker.steal_rot_seed` field exists.
- [ ] `worker_bit(i)` helper exists.
- [ ] Owner push path sets the bit via `fetchOr` on successful `tryPushBottom`.
- [ ] Owner pop-to-empty path clears + re-checks.
- [ ] Successful-steal drain path clears victim bit + re-checks; stealer bit set if n ≥ 2.
- [ ] Stealer scan loads bitmap once, masks self, rotates, iterates with `@ctz`.
- [ ] Bitmap invariant unit test passes.
- [ ] Wide-pool flood stress test passes.
- [ ] `test-stress` passes 5× consecutive.
- [ ] `flood_1m` median ≥ 700K (target) or flagged as PARTIAL (550K–700K).
- [ ] `perf stat` cache-miss rate ≤ 8%.
- [ ] Baseline updated and committed.
- [ ] `PERFORMANCE_TRACKING.md` Phase E filled in with measured numbers, not TBD.

## Rollback Criteria

If after Task 9:

- `flood_1m` median < 550K → ROLLBACK. Revert Tasks 2-6 (keep Task 1 validation + Tasks 7-8 tests as permanent improvements). File a follow-up: the per-worker cached bit-state variant (set only on empty→non-empty transition) may be needed because every-push `fetchOr` is eating gains.
- Any stress test fails or hangs in 5 consecutive runs → ROLLBACK. Bit-update protocol has a correctness bug; re-check Tasks 3-5.
- Submit p50 regresses beyond 20% (917 → > 1100 ns) → ROLLBACK. `fetchOr` on every push is the prime suspect; the per-worker cached variant addresses this.

## Execution Handoff

**Plan complete and saved to `docs/superpowers/plans/2026-04-12-steal-scan-bitmap.md`. Two execution options:**

**1. Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, review between tasks, fast iteration. The critical gate is Task 6 Step 5 (5× stress runs post-scan-rewrite) and Task 9 Step 3 (acceptance gate on flood_1m).

**2. Inline Execution** — Execute tasks in this session using executing-plans, batch execution with checkpoints.

**Which approach?**
