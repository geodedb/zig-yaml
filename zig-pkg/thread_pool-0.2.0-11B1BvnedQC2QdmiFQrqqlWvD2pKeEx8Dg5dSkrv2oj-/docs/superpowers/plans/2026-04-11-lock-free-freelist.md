# Lock-Free Descriptor Freelist (PERF-006) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the mutex-protected descriptor freelist with a lock-free Treiber stack using atomic CAS on a tagged top pointer, eliminating the global `free_mutex` that serializes all submit+complete operations.

**Architecture:** The current `free_indices[]` array + `free_top` counter under `free_mutex` becomes an atomic `free_top_tagged` packing `(aba_counter:u32, stack_size:u32)` into a `u64`. Acquire pops with CAS; release pushes with CAS. The ABA counter prevents the classic CAS retry problem. Descriptor field clearing and generation bump happen outside the critical section (only one thread owns the descriptor at a time).

**Tech Stack:** Zig 0.15.2, `std.atomic.Value(u64)`, CAS loops

**Closes:** PERF-006

---

## File Structure

| File | Action | Responsibility |
|------|--------|---------------|
| `src/thread_pool/pool.zig` | **Modify** | Replace free_mutex+free_top with atomic tagged pointer; rewrite acquireDescriptor/releaseDescriptor |

---

## Task 1: Replace free_mutex with atomic Treiber stack

**Files:**

- Modify: `src/thread_pool/pool.zig`

- [ ] **Step 1: Replace Core fields**

Remove `free_top: usize` and `free_mutex: std.Thread.Mutex` from Core struct. Add:

```zig
    free_top_tagged: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
```

The tagged value encodes: `(aba_counter << 32) | stack_size`. Initialize in `Core.init` after populating `free_indices`:

```zig
    self.free_top_tagged = std.atomic.Value(u64).init(@as(u64, normalized.queue_capacity));
```

(ABA starts at 0, stack_size starts at queue_capacity since all descriptors start free.)

- [ ] **Step 2: Rewrite acquireDescriptor as lock-free CAS pop**

```zig
    fn acquireDescriptor(self: *Core) ?u32 {
        while (true) {
            const tagged = self.free_top_tagged.load(.acquire);
            const size = @as(u32, @truncate(tagged));
            if (size == 0) return null;
            const aba = @as(u32, @truncate(tagged >> 32));
            const descriptor_index = self.free_indices[size - 1];
            const new_tagged = @as(u64, aba +% 1) << 32 | @as(u64, size - 1);
            if (self.free_top_tagged.cmpxchgWeak(tagged, new_tagged, .acq_rel, .acquire)) |_| {
                continue; // CAS failed, retry
            }
            // Won the pop — we own descriptor_index exclusively
            var descriptor = &self.descriptors[descriptor_index];
            const prev_generation = descriptor.generation;
            descriptor.* = .{};
            descriptor.generation = prev_generation +% 1;
            if (descriptor.generation == 0) descriptor.generation = 1;
            descriptor.state.store(.reserved, .release);
            const live = self.task_desc_live.fetchAdd(1, .monotonic) + 1;
            updatePeak(&self.task_desc_peak, live);
            return descriptor_index;
        }
    }
```

- [ ] **Step 3: Rewrite releaseDescriptor as lock-free CAS push**

```zig
    fn releaseDescriptor(self: *Core, descriptor_index: u32) void {
        var descriptor = &self.descriptors[descriptor_index];
        descriptor.task_fn = null;
        descriptor.ctx = null;
        descriptor.options = .{};
        descriptor.submit_ns = 0;
        descriptor.start_ns = 0;
        descriptor.complete_ns = 0;
        descriptor.state.store(.free, .release);
        _ = self.task_desc_live.fetchSub(1, .monotonic);

        // Push back to freelist
        while (true) {
            const tagged = self.free_top_tagged.load(.acquire);
            const size = @as(u32, @truncate(tagged));
            const aba = @as(u32, @truncate(tagged >> 32));
            self.free_indices[size] = descriptor_index;
            std.atomic.fence(.release); // Ensure index write visible before CAS
            const new_tagged = @as(u64, aba +% 1) << 32 | @as(u64, size + 1);
            if (self.free_top_tagged.cmpxchgWeak(tagged, new_tagged, .acq_rel, .acquire)) |_| {
                continue; // CAS failed, retry
            }
            return;
        }
    }
```

- [ ] **Step 4: Update Core.init to remove mutex references**

Remove `free_top` and `free_mutex` initialization. The `free_top_tagged` is initialized after the `free_indices` array is populated.

- [ ] **Step 5: Run tests**

Run: `./zig-0.15.2/zig build test --summary all && ./zig-0.15.2/zig build test-integration --summary all && timeout 120 ./zig-0.15.2/zig build test-stress --summary all && ./zig-0.15.2/zig build cross-check`

- [ ] **Step 6: Commit**

```bash
git add src/thread_pool/pool.zig
git commit -m "perf: close PERF-006 - lock-free Treiber stack for descriptor freelist

Replace free_mutex + free_top with atomic CAS on tagged u64
(aba_counter:u32 | stack_size:u32). Acquire and release are
lock-free CAS loops. Eliminates the global mutex that serialized
all submit + complete operations.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: Benchmark and document

- [ ] **Step 1: Run benchmarks and compare**

Focus on `producer_contention` which showed 3x degradation from free_mutex contention.

- [ ] **Step 2: Update PERF_GAP_ANALYSIS.md**

Mark PERF-006 as Closed with evidence.

- [ ] **Step 3: Commit**

```bash
git add docs/PERF_GAP_ANALYSIS.md
git commit -m "docs: close PERF-006 in tracking

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```
