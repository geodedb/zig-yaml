# Performance Review of zig/thread-pool Toward Tokio and Go Parity

## Scope and current repo state

The `thread-pool` project is a standalone Zig thread-pool library for the `devnw/zig` ecosystem, offering bounded task descriptors, fixed worker caps, a global-queue baseline, and a work-stealing scheduler behind a single API. citeturn13view0 The stated goal for the current performance initiative is parity with Tokio’s multithreaded runtime on the `tokio_parity/flood_1m` benchmark (1M trivial tasks, single submitter) and improved multi-submitter performance on `contended_spawn_8x`. citeturn9view0turn13view1

The repository is hosted on entity["company","GitLab","code hosting platform"] and the most recent `main`-branch work (as of April 14, 2026) is documentation-heavy, consolidating prior merges (notably Phase G2 re-land and Phase H race fix) and preserving abandoned performance experiments as audit trails. citeturn3view0turn9view0 The session handoff explicitly warns that mainline performance did not change meaningfully “this session,” and that the current host is drifted (absolute numbers should not be compared across sessions without controlling host state). citeturn9view0turn30view2

Two recent, relevant negative-result branches are especially important in understanding today’s “blockers”:

- **Option 3 worker-local incoming queues**: decisive `flood_1m` regression (≈ −48% median), while improving `contended_spawn_8x` (≈ +18% median). citeturn30view0turn9view0
- **Wake-scan parked-count gate**: three attempts to short-circuit the O(N) parked-worker scan regressed `flood_1m` (−11%, −2.5%, −8.9%), with root cause attributed to cacheline contention and atomic RMW traffic. citeturn30view1turn20view0

The practical implication of those results (and earlier profiling history tracked in `docs/PERFORMANCE_TRACKING.md`) is that micro-optimizations around “single atomics” are no longer sufficient to close the remaining Tokio/Go gap; structural scheduler/wake-model adjustments are required. citeturn25view3turn30view2

## Architecture review

### Benchmark that defines “Tokio parity” in this repo

The repository’s Tokio-parity benchmark binary implements two scenarios:

- `flood_1m`: single submitter loop submits 1,000,000 trivial tasks using `.backpressure = .block` (bounded submission), then waits for completion. citeturn13view1
- `contended_spawn_8x`: 8 OS threads submit concurrently (100,000 total tasks), then wait. citeturn13view1

The benchmark config uses:

- `max_threads = 0` → “CPU count” (capped internally at 64). citeturn13view1turn26view0
- `queue_capacity = 4096` and `local_queue_capacity = 256`. citeturn13view1turn26view0
- work-stealing scheduler. citeturn13view1turn25view2

This matters because it entrenches two expensive invariants:

- **bounded descriptors** (descriptor array sized to `queue_capacity`), so flood workloads necessarily cycle descriptor acquire/release and can trigger blocking when “in-flight” saturates. citeturn18view0turn13view1
- **OS-thread parking/unparking pressure**: if submit throughput is not high enough to keep workers busy, they will park frequently and require wakes, driving futex/condvar overhead into the critical path. citeturn18view0turn25view3

### Current scheduler mechanics in `src/pool.zig`

The hot path for `submit()` is:

1. Acquire a descriptor from a bounded freelist (`free_top_tagged` ABA-tagged CAS stack). citeturn18view0
2. Fill descriptor fields; mark state `.queued`. citeturn18view0
3. Enqueue to:
   - worker-local LIFO slot or local queue when submitting from a worker thread, otherwise
   - global inject queue (`BoundedRing` Vyukov-style MPMC). citeturn18view0turn9view0
4. Update counters: `submitted.fetchAdd(.monotonic)` plus `queued_tasks.fetchAdd(.seq_cst)` (for the park/wake handshake), tracking peak queue depth. citeturn18view0turn25view3
5. Wake one parked worker by scanning `is_parked` across the entire worker array (round-robin start), using a `seq_cst` load per worker until a parked worker is found, then acquiring that worker’s park mutex and signaling its condition variable. citeturn18view0turn30view1

When a worker goes idle (can’t find tasks in LIFO, local queue, inject queue, or via stealing), the park path does:

- optional spin loop (`spin_before_park_iters`, default 0). citeturn18view0turn26view0
- lock `park_mutex`, then execute a **seq_cst total-order handshake**: `is_parked.store(.seq_cst)` and `queued_tasks.load(.seq_cst)` to avoid a lost-wakeup scenario, then `timedWait` on `park_cond` for `idle_park_after_ns` (default 250µs). citeturn18view0turn25view3

On the worker side, `runTask` uses an atomic state transition `.queued → .running` (Phase H fix) and decrements `queued_tasks` upon CAS success (to prevent shutdown deadlocks in the presence of “ghost duplicates”). citeturn18view0turn9view0

### Observability and “extras” on the hot path

Two library features materially affect per-task overhead:

- **timestamp mode**: `full` records timestamps and updates latency histograms; `disabled` skips most timestamp reads and histogram updates. citeturn13view2turn18view0
- **per-worker scratch buffer**: each task calls `WorkerScratch.beginTask()` and `finishTask()` around task execution. Today, `beginTask()` takes a mutex lock every task, even when tasks never allocate scratch memory. citeturn27view0turn18view0

The scratch lock is not an academic concern: it inserts a synchronization primitive into the inner loop of worker execution (and into the “noop task” parity benchmarks), which Tokio and Go avoid by relying more heavily on thread-local or per-worker data with minimal locking. citeturn27view0turn21view1turn29search1

## Findings: what is currently blocking throughput

### The “Tokio/Go gap” is mostly structural, not a missing micro-optimization

The handoff and re-profile documents consistently converge on the same topline: even optimistic “single-atomic ceiling” improvements do not get close to the 5–15M ops/s Tokio target; they move the needle into the ~0.8–1.1M range at best, leaving most of the gap intact. citeturn30view2turn9view0

This is reinforced by the project’s own historical phase tracking, where multiple “hot path” ideas either regressed or proved to be off the critical path once profiled (e.g., lock-free backpressure rewrite showed negligible benefit; other phases were reverted after measurement). citeturn25view3turn30view1

The blockers are therefore not “one missing trick,” but a cluster of compounding costs that show up strongly on the `flood_1m` workload shape.

### Primary blocker: wake strategy forces expensive per-submit work under producer-bound load

The current `enqueueTask` wake behavior is expensive in two ways:

- It performs an O(N) scan of `is_parked` across `workers.len` *on every successfully enqueued task*, using `seq_cst` loads. citeturn18view0turn30view1
- When it finds a parked worker, it takes a mutex and signals a condition variable—an operation that can drive futex wake overhead into the dominant cost when workers are parking frequently. citeturn18view0turn25view3

The project already verified that wake-path changes have meaningful ceilings (wake-scan stubs and earlier “remove wake scan” experiments), but attempts to “gate” them with a shared counter regressed because introducing shared atomic RMW traffic during frequent park/unpark cycles cost more than the scan savings. citeturn30view1turn20view0

The key insight is: **the wake bottleneck is not just the scan; it’s the interaction between frequent parking and being forced to do substantial work per submit to recover from that parking.** citeturn25view3turn18view0

### Secondary blocker: aggressive parking + seq_cst handshake keeps the system in a “wake heavy” regime

The `idle()` path parks a worker as soon as `nextTask()` returns null, with default `spin_before_park_iters = 0`. citeturn18view0turn26view0 In producer-bound workloads where the submitter can’t keep the queue saturated (which is exactly what the re-profile describes: submitter 100% running, workers mostly blocked), this makes workers churn between runnable and parked states. citeturn30view2turn18view0

The correctness of the lost-wakeup guard depends on a seq_cst total order between `queued_tasks` and `is_parked`. That enforces stronger ordering than Tokio or Go typically use in their local fast paths, and it constrains how “cheap” a wake optimization can be without reworking this handshake. citeturn18view0turn21view1turn22view1

### Tertiary blocker: per-task scratch locking on the worker fast path

Even for a no-op task, every execution path calls:

- `worker.scratch.beginTask()` (mutex lock + “ensure buffer” logic), then
- `worker.scratch.finishTask()`. citeturn18view0turn27view0

This injects a lock into the worker inner loop, which is not free even when uncontended. It becomes especially hard to justify in the parity benchmarks, where scratch is not used by the workload at all. citeturn13view1turn27view0

### Confirmed dead-ends that should not be repeated

Two confirmed blockers are worth stating plainly because they constrain “what to fix next”:

- **Option 3 (worker-local incoming queues)** cannot be shipped as implemented if `flood_1m` remains a top KPI. It dramatically worsens single-submitter throughput because it forces a submitter to rotate across many cold cachelines; the same design is plausibly beneficial for multi-producer contention. citeturn30view0turn9view0
- **A single global “parked_count” gate** is net-negative under the observed park/unpark dynamics; any wake optimization must avoid a shared RMW hotspot written by every worker. citeturn30view1turn20view0

## How Tokio and Go avoid these costs

### Tokio’s multithreaded runtime does not scan all workers to find someone to wake

Tokio’s documentation for the multithreaded runtime describes essentially the same queue topology (global + per-worker local queues, work-stealing, and a LIFO slot optimization). citeturn21view1turn25view3 The crucial difference is that Tokio explicitly coordinates idle workers so the runtime can quickly choose a worker to notify.

In Tokio’s scheduler implementation, worker wake-up uses an idle coordinator: `notify_parked_local` calls `idle.worker_to_notify(...)` and then directly un-parks the chosen worker via its `unpark` handle—no linear scan of all workers’ parked flags. citeturn23view0turn28search0 This is a fundamentally different wake-selection strategy than the Zig pool’s “scan `is_parked[]` every submit” approach. citeturn18view0turn30view1

Tokio’s parker itself is also a small state machine around an atomic state plus a condvar/driver mechanism, with strong emphasis on not losing notifications. citeturn22view1 The Zig pool has the same “don’t lose wakeups” constraint, but currently pays for it with a global seq_cst counter and cross-thread scan. citeturn18view0turn25view3

### Go’s runtime similarly relies on local run queues and work-stealing, but avoids per-task OS wakeups

Your `RingQueue` is explicitly inspired by Tokio and Go’s run queue logic: single producer pushes/pops from a tail, stealers CAS the head and steal in batches (“steal half”), mirroring patterns in `runtime/proc.go`. citeturn27view1turn29search1

However, Go’s scheduler is not built around waking OS threads per unit of work. Goroutines are scheduled within the runtime on existing OS threads bound to “P” tokens, and the system is designed to keep runnable work available to running threads through local queues, global queue balancing, and work stealing. citeturn29search1turn27view1 The overall effect is the same: **wake selection and work availability are designed so the system does not require a heavy OS-thread park/unpark loop for trivial work.**

## Fixes that unblock measurable gains

This section is deliberately blunt: the observed gap is too large to claim “Tokio/Go parity” from a handful of patches. The fixes below are the changes that remove the biggest structural brakes *so the project can actually pursue* the next order-of-magnitude improvements without repeatedly hitting the same ceiling. They are also chosen to respect the repository’s demonstrated lessons: avoid shared RMW hotspots, measure with paired A/B, and keep correctness gates (Phase H sentinel, stress tests) in place during scheduler work. citeturn9view0turn30view1

### Remove per-task scratch locking from the worker hot path

Right now, the parity benchmark’s noop tasks pay a scratch mutex lock/unlock for every task because `runTask` unconditionally calls `beginTask()`, and `beginTask()` always takes a mutex. citeturn18view0turn27view0

You can remove that lock from the hot path safely by strengthening the `purgeWorkerCaches` precondition so that `purge()` is only called when **both** `active_tasks == 0` and `queued_tasks == 0`, i.e., there is not only no running work but also no pending work that could start immediately after the check. (Today it checks only `active_tasks`.) citeturn18view0turn27view0

Once purge is constrained this way, scratch state is single-thread-owned during normal execution, and the mutex can be removed (or moved behind a slow-path only).

A concrete patch sketch (illustrative; adjust formatting to match repository style):

```diff
diff --git a/src/pool.zig b/src/pool.zig
@@
 pub fn purgeWorkerCaches(self: *Core) !void {
-    if (self.counters.active_tasks.load(.acquire) != 0) return error.PoolBusy;
+    if (self.counters.active_tasks.load(.acquire) != 0) return error.PoolBusy;
+    if (self.counters.queued_tasks.load(.acquire) != 0) return error.PoolBusy;
     for (self.workers) |*worker| {
         worker.scratch.purge();
     }
 }

diff --git a/src/memory/scratch.zig b/src/memory/scratch.zig
@@
 pub const WorkerScratch = struct {
@@
-    /// Serializes purge() and beginTask()/alloc() so that the owning worker
-    /// and a remote caller (e.g. Core.purgeWorkerCaches) cannot race on the
-    /// backing buffer. Without this guard, two concurrent purge() calls would
-    /// double-free the allocation.
-    mutex: std.Thread.Mutex = .{},
+    // Invariant: purge() is only called when the pool is quiescent:
+    // active_tasks == 0 and queued_tasks == 0 (see Core.purgeWorkerCaches).
@@
     pub fn beginTask(self: *WorkerScratch) !void {
-        self.mutex.lock();
-        defer self.mutex.unlock();
         try self.ensureBufferLocked();
         if (self.buffer) |buf| {
             self.fba = std.heap.FixedBufferAllocator.init(buf);
             self.current_bytes = 0;
         }
     }
@@
     pub fn alloc(self: *WorkerScratch, comptime T: type, count: usize) ![]T {
-        self.mutex.lock();
-        defer self.mutex.unlock();
         try self.ensureBufferLocked();
         if (self.fba == null) return error.ScratchUnavailable;
@@
     pub fn purge(self: *WorkerScratch) void {
-        self.mutex.lock();
-        defer self.mutex.unlock();
         if (self.buffer) |buf| {
             self.accounting.recordFree(buf.len);
             self.allocator.free(buf);
         }
         self.buffer = null;
         self.fba = null;
         self.current_bytes = 0;
     }
```

This removes a mutex from the per-task inner loop and aligns scratch behavior with how the benchmarks actually use it. citeturn27view0turn13view1

### Replace O(N) wake scanning with an idle-worker queue that avoids a shared RMW hotspot

The wake-scan parked-count gate failed because it added a shared counter written by every worker on every park/unpark transition. citeturn30view1turn20view0 The right replacement pattern is closer to Tokio: track idle workers so the submitter can wake one without scanning the whole pool. citeturn23view0turn28search0

A practical approach that respects the “avoid a shared RMW hotspot” lesson is:

- Maintain an idle set as **multiple shards**, each shard a bounded MPMC ring of worker indices (or a Treiber stack) to reduce contention.
- Workers enqueue themselves into their shard *only when actually transitioning into the parked/waiting state*, and only if not already enqueued.
- Submitters dequeue from shards to get a candidate parked worker to signal, avoiding O(N) scanning and reducing the frequency with which the submit path touches per-worker cachelines.

This is not “free”—it changes the park/unpark transition cost—but it targets the most damaging property of the current design: doing O(N) work on every submit. citeturn18view0turn25view3

A minimal implementation strategy (one shard to start, then shard if needed) looks like this:

- Add to `Worker`:
  - `idle_enqueued: atomic u8` (0/1) to prevent duplicate inserts and bound queue growth even when a worker wakes via timeout.
- Add to `Core`:
  - `idle_queue: BoundedRing(u32)` sized to `max_threads` (or `2*max_threads`) and normalized to a power of two.

Then modify:

- `idle()` to:
  - set `is_parked = 1`
  - enqueue its index into `idle_queue` before the `queued_tasks` check
  - proceed to `timedWait`

- `enqueueTask` to:
  - after successful enqueue + counter increments, try `idle_queue.pop()` and signal that worker if it is still parked, then clear `idle_enqueued`.

This preserves the existing correctness model (Phase G2/Phase H semantics) while removing the linear scan from the submit path. citeturn18view0turn9view0turn30view1

The project already has strong evidence that wake-path improvements have a large ceiling; this is the kind of structural change that can plausibly capture more of that ceiling than a global counter gate can, because it reduces *read amplification* on the submitter rather than adding a new shared write hotspot. citeturn30view2turn30view1

### Stop paying `seq_cst` on a global counter forever by moving the lost-wakeup guarantee into a per-worker parker

Even if you remove the scan, `queued_tasks.fetchAdd(.seq_cst)` is still on the submit hot path specifically to participate in the SC handshake that prevents the IRIW lost-wakeup scenario. citeturn18view0turn25view3 Tokio avoids building lost-wakeup prevention on a global queue-depth counter; it uses a per-parker atomic state machine that is updated on park/unpark paths. citeturn22view1turn23view0

If Tokio/Go parity is truly the goal (not “best effort within today’s architecture”), the long-term fix is to:

- introduce a per-worker `park_state` (e.g., EMPTY / PARKED / NOTIFIED)
- make `unpark()` a state transition (often a single atomic swap) plus a conditional signal
- remove the need for `queued_tasks` to be seq_cst purely for wake correctness

This is a larger change than the two patches above, but it’s the lever that removes a global ordering primitive from the hottest submit path. Without doing this, you will keep running into ceilings where the submitter is “100% running” and largely performing synchronization and wake maintenance. citeturn30view2turn18view0turn22view1

### Make “parity mode” a first-class configuration

Right now, the parity benchmarks exercise:

- scratch begin/finish every task, citeturn18view0turn27view0
- timestamp mode defaults, citeturn13view2turn18view0
- full scheduler semantics, including tight park/unpark loops. citeturn18view0turn13view1

Tokio/Go “trivial task throughput” numbers are typically achieved in regimes designed to minimize OS-level thread parking and to keep hot workers active with local queues and cheap notification. citeturn23view0turn29search1

To avoid repeatedly debating whether benchmark numbers reflect “optional features,” the project should treat “parity mode” as an explicit config preset:

- `timestamp_mode = disabled`
- scratch fast-path that is effectively lock-free unless scratch is used
- wake strategy set to “idle-set / O(1) notify” rather than scan
- optionally: parameters tuned to minimize parking churn (longer spin, larger inject batch, etc.), but behind explicit config knobs rather than hidden behavior

This makes benchmark comparisons honest: you’re comparing scheduler and wake machinery vs scheduler and wake machinery, not “scheduler + extra cross-thread memory subsystem” vs “scheduler.” citeturn13view0turn13view2turn21view1

## Measurement and risk controls

The measurement discipline documented in the handoff is not optional; it’s necessary to avoid re-learning the same lessons:

- Use paired same-session A/B comparisons and at least `n=10` for `flood_1m`. citeturn9view0turn30view1
- Apply the “20× ReleaseFast stress gate” to any submit-path or wake-path change; keep the Phase H claim sentinel enabled while doing so. citeturn9view0turn18view0
- Treat host drift as real; do not anchor on stale absolute baselines (including the earlier 566K number unless revalidated under clean host state). citeturn9view0turn30view2

For the two concrete patches suggested above, the acceptance criteria should be framed as:

- **Patch: scratch lock removal**
  - No regression in `test-stress` (≥20×).
  - Benchmark deltas should be visible both in `flood_1m` and in any worker-heavy scenario (this change affects worker-side overhead). citeturn27view0turn18view0

- **Patch: idle-worker queue notify**
  - No lost-wakeup hangs under stress (this touches the most sensitive correctness surface).
  - A/B improvement should show most strongly in the parity benchmarks, where submit-side scan overhead is paid at high frequency. citeturn13view1turn18view0

Finally, one hard truth from the existing evidence should guide expectations: even “perfect” versions of these fixes are unlikely to magically reach 5–15M ops/s without deeper structural alignment with Tokio/Go’s idle management and wake semantics. The fixes above are the ones that remove the current architecture’s biggest brakes so that a more Tokio-like idle coordinator and per-worker parker state machine can be implemented without constantly fighting O(N) per-submit work and per-task synchronization overhead. citeturn30view2turn23view0turn18view0
