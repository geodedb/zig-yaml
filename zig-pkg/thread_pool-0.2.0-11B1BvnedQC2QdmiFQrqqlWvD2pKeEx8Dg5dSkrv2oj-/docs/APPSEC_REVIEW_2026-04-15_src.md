# AppSec Review — devnw/zig/thread-pool src/

## 1. Scope & Assumptions

**In scope:** `src/root.zig`, `src/pool.zig`, `src/types.zig`, `src/queue/bounded_ring.zig`, `src/queue/work_deque.zig`, `src/queue/ring_queue.zig`, `src/memory/scratch.zig`, `src/stats/latency.zig`, `src/stats/process_memory.zig` (all paths are absolute under `/home/benji/src/devnw/zig/thread-pool/src/`).

**Out of scope:** `tests/`, `benchmarks/`, `third_party/`, `docs/`, `examples/`, the Zig compiler, the Zig standard library.

**Assumptions and calibration:**

- This is a concurrency primitives library linked in-process. The attack surface is API misuse by well-meaning but buggy callers plus any untrusted data that flows through `ctx: *anyopaque` task payloads. There is no network, no auth, no persistence.
- "Critical" is reserved for memory corruption or UB reachable from documented public API calls. "High" for plausible-use data races / panic-as-DoS / resource exhaustion without opt-in.
- OWASP Top 10 2025 and CIS Controls v8.1.2 map loosely: most categories do not apply. A08 (integrity) applies to the queue-entry generation tag and free-list ABA tag. A09 (logging) — one `std.log.warn` on deinit timeout is the only log; it does not leak task payloads.
- Targets Linux primarily; macOS/Windows stats paths (`src/stats/process_memory.zig`) are secondary but were reviewed.
- Zig 0.15.2, no third-party dependencies (supply chain = Zig toolchain only).
- Static read-through only — no execution, no tests run. Where a race could not be empirically verified, it is flagged as such with the evidence required to confirm.

## 2. Executive Summary

The codebase shows a high standard of concurrency engineering: the three queue implementations use well-known algorithms (Vyukov MPMC, Chase-Lev, Tokio/Go-style SPMC) with explicit release/acquire/seq_cst pairings, generation tags on queue entries to defeat descriptor-recycle hazards, an ABA-tagged free-list, and a park-handshake documented to exclude IRIW. Most risk is concentrated in two places: the **cross-pool TLS indexing** assumption in `enqueuePush` and the **init-failure cleanup path** that does not stop already-spawned worker threads.

Severity counts: **Critical 1 / High 2 / Medium 3 / Low 3 / Info 2**.

Highest-risk issues:

1. `threadlocal tls_worker_index` / `tls_submitter_index` are process-global. A thread that is a worker of Pool A (or registered with Pool A) calling `submit()` on Pool B indexes Pool A's slot into Pool B's arrays, which is out-of-bounds in ReleaseFast (UB) and a panic in Debug/ReleaseSafe. Reachable from public API with zero malicious input.
2. `Core.init` spawns workers mid-loop but its `errdefer self.deinitOwned()` never signals shutdown or joins threads. A partial `Thread.spawn` failure leaves worker threads reading memory that `deinitOwned` is simultaneously freeing — UAF on the host process.
3. `acquireDescriptor` performs a non-atomic `free_indices[head]` load outside the CAS. The CAS and ABA counter make the overall algorithm safe from incorrect free-list linkage, but the read itself is a data race under the Zig memory model. On tier-1 targets (x86_64, aarch64) this is benign; on weaker-memory targets the lack of a proper atomic load is a portability concern.

## 3. Findings Table

| ID | Severity | Category | Location | Title |
|----|----------|----------|----------|-------|
| F-001 | Critical | Memory safety / UB | `src/pool.zig:11-12, 913-934` | Process-global `threadlocal` worker/submitter indices enable cross-pool OOB indexing |
| F-002 | High | Memory safety / lifecycle | `src/pool.zig:454-460, 391, 1693-1724` | `Core.init` errdefer frees worker arrays without stopping spawned workers |
| F-003 | High | Data race | `src/pool.zig:1624, 1659` | `acquireDescriptor` / `releaseDescriptor` read/write `free_indices[head]` non-atomically |
| F-004 | Medium | Panic-as-DoS | `src/types.zig:311-315` | `WaitGroup.done()` panics on underflow; caller bug crashes host process |
| F-005 | Medium | Resource lifecycle | `src/pool.zig:555-577` | `registerSubmitter` has no re-entrancy guard and leaks slots on thread exit without release |
| F-006 | Medium | Panic-as-DoS | `src/pool.zig:906, 1341` | `unreachable` on `blocking_inject == null` branches can fire if caller constructs `Config` then mutates it post-validate |
| F-007 | Low | Integer overflow | `src/stats/process_memory.zig:71-74` | `parseProcStatusKiB(...) * 1024` can overflow `u64` on a malicious `/proc/self/status` |
| F-008 | Low | Double-free on misuse | `src/pool.zig:579-598` | Two concurrent `wait()` calls on the same handle can double-release a descriptor |
| F-009 | Low | Allocator-failure path | `src/pool.zig:1425-1427` | Scratch buffer alloc failure is counted but silently swallowed; task sees `error.ScratchUnavailable` on any subsequent `alloc` |
| F-010 | Info | Hygiene | `src/stats/process_memory.zig:84` | `parseInt catch 0` hides parse errors silently — defensible for observability but noted |
| F-011 | Info | Hygiene | `src/queue/bounded_ring.zig:27-28, :22` | Slot `value: T = undefined` holds uninitialized memory for the type lifetime; relies on sequence field as validity gate — correct but fragile if `T` has destructors |

## 4. Finding Details

### F-001 — Process-global `threadlocal` worker/submitter indices enable cross-pool OOB indexing

- **Severity:** Critical
- **Confidence:** High (static-verified)
- **Location:** `/home/benji/src/devnw/zig/thread-pool/src/pool.zig:11-12`, `:913-934`, `:1085-1086`, `:1113-1114`
- **Evidence:**

  ```zig
  // src/pool.zig:11-12
  threadlocal var tls_worker_index: ?usize = null;
  threadlocal var tls_submitter_index: ?usize = null;
  ```

  ```zig
  // src/pool.zig:913-934
  if (uses_local and tls_worker_index != null) {
      const wi = tls_worker_index.?;
      const w = &self.workers[wi];           // <-- self is pool B, wi is pool A's index
      if (w.serves_lane == .default) { ... }
      ...
      queued = self.local_queues[wi].tryPushBottom(entry);  // OOB if wi >= pool B's len
  }
  if (!queued and tls_submitter_index != null) {
      const si = tls_submitter_index.?;
      queued = self.submitter_queues[si].tryPushBottom(entry);  // OOB if si >= pool B's len
  }
  ```

- **Impact:** If a process hosts two `ThreadPool` instances, a thread that is a worker in Pool A (or registered as a submitter on Pool A) submitting to Pool B will index Pool A's slot into Pool B's `workers` / `local_queues` / `submitter_queues` arrays. If Pool A has more workers than Pool B, this is out-of-bounds. In Debug and ReleaseSafe this is a runtime panic (DoS). In ReleaseFast the bounds check is elided and the read/write is undefined behavior — potential memory corruption, arbitrary write into unrelated heap memory, or type confusion via writing a `QueueEntry` into whatever structure happens to live past the end of the slice.
- **Exploit scenario:** A downstream application creates two independently-configured thread pools (a common pattern: one for CPU work, one for I/O) with different `max_threads`. Pool A has 32 workers, Pool B has 4. Worker 20 of Pool A submits a follow-up task to Pool B. `tls_worker_index == 20`, `self.workers` is Pool B's 4-element slice, `&self.workers[20]` reads 16 slots past the end. In ReleaseFast build, the `is_parked` or `serves_lane` byte it reads is attacker-influenced heap memory, and `local_queues[20].tryPushBottom(entry)` performs an OOB write into whatever lives at that offset. No untrusted input is needed — two honest pools is enough.
- **Root cause:** `threadlocal` is per-thread-per-process, not per-pool-per-thread. The design implicitly assumes a single pool instance.
- **Remediation:** Namespace the TLS state by pool identity. Options in increasing preference:
  1. Store `struct { pool: *Core, index: usize }` in TLS and only read the cached index when `tls.pool == self`.
  2. Use a hashmap `ThreadLocal<Map<*Core, usize>>` — more flexible, more overhead.
  3. Always validate `wi < self.workers.len` and `si < self.submitter_queues.len` before indexing; on mismatch, fall through to the inject queue. Cheapest fix:

  ```zig
  if (uses_local and tls_worker_index != null) {
      const wi = tls_worker_index.?;
      if (wi < self.workers.len) {
          const w = &self.workers[wi];
          // additionally: verify w.thread points at this Core by storing &core in Worker
          ...
      }
  }
  ```

  The bounds check alone closes the OOB but still treats the wrong pool's worker as "our" worker, which wastes the fast path. Option 1 (pool-tagged TLS) is the correct fix.
- **References:** CWE-125 (OOB Read), CWE-787 (OOB Write), CWE-843 (Type Confusion). OWASP 2025 A01 only tangentially — primarily a memory-safety bug, not an access-control one.

---

### F-002 — `Core.init` errdefer frees worker arrays without stopping spawned workers

- **Severity:** High
- **Confidence:** High
- **Location:** `/home/benji/src/devnw/zig/thread-pool/src/pool.zig:391`, `:454-460`, `:1693-1724`
- **Evidence:**

  ```zig
  // src/pool.zig:391
  errdefer self.deinitOwned();
  ...
  // src/pool.zig:454-460
  for (self.workers[0..normalized.max_threads], 0..) |*worker, idx| {
      worker.thread = try std.Thread.spawn(.{}, workerMain, .{ self, idx });
  }
  if (normalized.watchdog_interval_ns > 0) {
      self.watchdog_thread = try std.Thread.spawn(.{}, watchdogMain, .{self});
  }
  ```

  ```zig
  // src/pool.zig:1693 — deinitOwned
  fn deinitOwned(self: *Core) void {
      for (self.workers) |*worker| { worker.scratch.purge(); }
      // ... then frees local_queues, descriptors, workers, etc.
      // No state.store(.stopping), no park_cond.broadcast, no worker.thread.join().
  }
  ```

- **Impact:** If `Thread.spawn` fails for worker N (EAGAIN is plausible under thread-count pressure from the host process), `errdefer self.deinitOwned()` runs while workers 0..N-1 are already in `workerMain` — their `shouldExit()` returns false because `state == .running`. `deinitOwned` frees `self.workers`, `self.local_queues`, `self.descriptors`, and internal queues while the live threads dereference them. Result: use-after-free, heap corruption, and likely a segfault in the host process. Also leaks the still-running threads since `Core` is about to be freed by the `ThreadPool.init` outer `errdefer allocator.destroy(core)`.
- **Exploit scenario:** Host process is near `RLIMIT_NPROC`. User calls `ThreadPool.init(.{ .max_threads = 32 })`. `spawn` succeeds for workers 0..20 and fails on 21 with `error.ThreadQuotaExceeded`. `deinitOwned` runs and frees everything. Workers 0..20 are in the middle of `nextTask`'s inject-queue drain — they crash the host or silently corrupt the allocator's freelist.
- **Root cause:** `deinitOwned` is the "cold-teardown" half; it assumes threads have already stopped. On init failure the normal `shutdown()` path is skipped. The spawn loop should either spawn all threads first with an alternative lifecycle, or its errdefer should go through `shutdown` + `joinAllWorkers`.
- **Remediation:** Introduce a per-spawn errdefer that stops what has been started so far. Minimal patch:

  ```zig
  // Replace the spawn loop with:
  var spawned: usize = 0;
  errdefer {
      // Tell already-spawned workers to exit and join them.
      self.state.store(.stopping, .release);
      for (self.workers[0..spawned]) |*w| {
          w.park_mutex.lock();
          w.park_cond.broadcast();
          w.park_mutex.unlock();
      }
      for (self.workers[0..spawned]) |*w| {
          if (w.thread) |t| { t.join(); w.thread = null; }
      }
  }
  for (self.workers[0..normalized.max_threads], 0..) |*worker, idx| {
      worker.thread = try std.Thread.spawn(.{}, workerMain, .{ self, idx });
      spawned += 1;
  }
  ```

  Similar treatment for the watchdog. Alternatively, make `deinitOwned` robust by calling `joinAllWorkers` up front.
- **References:** CWE-416 (Use After Free), CWE-460 (Improper Cleanup on Thrown Exception). CIS Controls v8.1.2 — secure application development process (error-handling paths).

---

### F-003 — `acquireDescriptor` / `releaseDescriptor` read/write `free_indices[head]` non-atomically

- **Severity:** High
- **Confidence:** Medium (algorithm is safe on tier-1 targets, but the read is formally a data race under LLVM/Zig's memory model)
- **Location:** `/home/benji/src/devnw/zig/thread-pool/src/pool.zig:1624`, `:1659`
- **Evidence:**

  ```zig
  // src/pool.zig:1618-1628
  fn acquireDescriptor(self: *Core) ?u32 {
      while (true) {
          const tagged = self.free_top_tagged.load(.acquire);
          const head = @as(u32, @truncate(tagged));
          if (head == free_sentinel) return null;
          const aba = @as(u32, @truncate(tagged >> 32));
          const next = self.free_indices[head];                 // <-- non-atomic plain load
          const new_tagged = @as(u64, aba +% 1) << 32 | @as(u64, next);
          if (self.free_top_tagged.cmpxchgWeak(tagged, new_tagged, .acq_rel, .acquire)) |_| {
              continue;
          }
          ...
  ```

  ```zig
  // src/pool.zig:1655-1664
  while (true) {
      const tagged = self.free_top_tagged.load(.acquire);
      const head = @as(u32, @truncate(tagged));
      const aba = @as(u32, @truncate(tagged >> 32));
      self.free_indices[descriptor_index] = head;              // <-- non-atomic plain store
      const new_tagged = @as(u64, aba +% 1) << 32 | @as(u64, descriptor_index);
      if (self.free_top_tagged.cmpxchgWeak(tagged, new_tagged, .acq_rel, .acquire)) |_| {
          continue;
      }
      break;
  }
  ```

  `free_indices` is a plain `[]u32`, not `[]std.atomic.Value(u32)`. Multiple acquirers/releasers racing on the same index happens whenever the ABA counter isn't enough to distinguish — common during heavy submit/release churn.
- **Impact:** Formally, the plain load in `acquireDescriptor` and the plain store in `releaseDescriptor` can run concurrently on the same `free_indices[idx]` slot. On x86_64 and aarch64 aligned 32-bit loads/stores are atomic by hardware contract, so the CAS + ABA tag makes the algorithm sound in practice. On weaker-memory or 32-bit-misaligned platforms the plain load could tear (read half-old, half-new u32) and produce a corrupt `next` value; the CAS would then succeed (because the head/tag match) and install a bogus head. A subsequent `acquireDescriptor` would return an out-of-range index.
- **Exploit scenario:** Not directly reachable by malicious input. Manifests only on non-TSO platforms under heavy contention. Primary concern is portability and future-proofing (riscv, armv7).
- **Root cause:** The code leans on the ABA-tagged CAS as the sole synchronization mechanism but still does a plain load/store on the linked-list "next" pointer, which most lock-free-stack references explicitly model as atomic.
- **Remediation:** Promote `free_indices` to `[]std.atomic.Value(u32)` and use `.monotonic` load/store — `.monotonic` is sufficient because the CAS provides the release/acquire edges:

  ```zig
  free_indices: []std.atomic.Value(u32),
  ...
  const next = self.free_indices[head].load(.monotonic);
  ...
  self.free_indices[descriptor_index].store(head, .monotonic);
  ```

  Zero runtime cost on x86/arm64 (compiles to the same mov), and makes the Zig memory model happy.
- **References:** CWE-362 (Concurrent Execution / Race), CWE-366 (Race Condition Within a Thread). Not in OWASP, but CIS 16 — application testing (thread-sanitizer should flag this).

---

### F-004 — `WaitGroup.done()` panics on underflow; caller bug crashes host process

- **Severity:** Medium
- **Confidence:** High
- **Location:** `/home/benji/src/devnw/zig/thread-pool/src/types.zig:311-315`
- **Evidence:**

  ```zig
  pub fn done(self: *WaitGroup) void {
      const previous = self.pending.fetchSub(1, .acq_rel);
      if (previous == 0) {
          @panic("WaitGroup: done() called more times than add()");
      }
      ...
  ```

- **Impact:** `@panic` in library code aborts the host process. A caller who miscounts `add`/`done` (e.g. double-submit-double-done, or exception-handling path that does `done` twice) takes the whole process down. `WaitGroup.add` accepts a `u32` and unconditionally `fetchAdd(delta, .monotonic)` — no overflow check on the add side, either.
- **Exploit scenario:** Library user builds a worker fan-out that on error does `wait_group.done()` and also relies on `SubmitOptions.wait_group` doing `wg.done()` in `runTask`. Double-done on error → host process crashes. In a multi-tenant service using this pool, one tenant's misconfiguration DoSes the entire server.
- **Root cause:** Defensive crash on caller API misuse. Philosophically defensible (loud failure beats silent corruption) but inconsistent with the library's otherwise error-returning style.
- **Remediation:** Return an error (or saturate to zero with a debug-only panic):

  ```zig
  pub fn done(self: *WaitGroup) void {
      const previous = self.pending.fetchSub(1, .acq_rel);
      if (previous == 0) {
          // Restore invariant; log once in debug.
          _ = self.pending.fetchAdd(1, .monotonic);
          if (std.debug.runtime_safety) {
              std.debug.panic("WaitGroup: done() called more times than add()", .{});
          }
          return;
      }
      ...
  }
  ```

  Pattern matches `claim_sentinel_enabled` elsewhere: panic in Debug/ReleaseSafe, resilient in ReleaseFast.
- **References:** CWE-248 (Uncaught Exception), CWE-754 (Improper Check for Unusual Conditions). OWASP 2025 A10 (mishandling of exceptional conditions).

---

### F-005 — `registerSubmitter` slot leak on thread exit; `releaseSubmitter` has no re-entrancy guard

- **Severity:** Medium
- **Confidence:** High
- **Location:** `/home/benji/src/devnw/zig/thread-pool/src/pool.zig:555-577`
- **Evidence:**

  ```zig
  pub fn registerSubmitter(self: *Core) !usize {
      while (true) {
          const mask = self.submitter_free_mask.load(.acquire);
          if (mask == 0) return error.NoSubmitterSlots;
          const idx: usize = @ctz(mask);
          const bit: u64 = @as(u64, 1) << @intCast(idx);
          if (self.submitter_free_mask.cmpxchgWeak(mask, mask & ~bit, .acq_rel, .monotonic) == null) {
              tls_submitter_index = idx;
              _ = self.submitter_nonempty.fetchOr(bit, .release);
              return idx;
          }
      }
  }

  pub fn releaseSubmitter(self: *Core, idx: usize) void {
      tls_submitter_index = null;
      while (self.submitter_queues[idx].stealOne()) |entry| {
          _ = self.inject_queue.tryPush(entry);
      }
      const bit: u64 = @as(u64, 1) << @intCast(idx);
      _ = self.submitter_nonempty.fetchAnd(~bit, .release);
      _ = self.submitter_free_mask.fetchOr(bit, .release);
  }
  ```

- **Impact:**
  1. **Leak on thread exit**: a thread that `registerSubmitter`s and then exits without `releaseSubmitter` holds the slot forever. Once all 64 slots are held by dead threads, `registerSubmitter` returns `error.NoSubmitterSlots`.
  2. **No idempotence / double-release**: if `releaseSubmitter` is called twice for the same `idx`, the second run's `stealOne` loop walks a queue that another thread may have just re-`registerSubmitter`ed into (because `submitter_free_mask` was cleared by the first release) and is concurrently pushing into. Data race on `submitter_queues[idx]`.
  3. **No argument validation**: `releaseSubmitter(idx)` with `idx >= submitter_queues.len` is an OOB index into the queue slice.
  4. **Dropped tasks on release**: the drain loop `stealOne -> inject_queue.tryPush` silently drops on inject-queue-full. Any in-flight submits made to the submitter queue just before release may be lost.
- **Exploit scenario:** Long-running worker thread in downstream application holds a submitter slot, then `pthread_exit`s from an external cause (signal, FFI call). Over days of operation all 64 slots leak; new threads fail to register; performance path degrades silently (falls back to the shared inject queue) or returns errors the caller didn't expect.
- **Remediation:**
  1. Validate `idx` and that the bit was actually allocated before draining:

  ```zig
  pub fn releaseSubmitter(self: *Core, idx: usize) void {
      if (idx >= self.submitter_queues.len) return;  // or return error
      const bit: u64 = @as(u64, 1) << @intCast(idx);
      // Atomically re-own the slot for drain. If the bit is already free, bail.
      const prev = self.submitter_free_mask.fetchOr(0, .monotonic);
      if ((prev & bit) != 0) return;   // already released
      tls_submitter_index = null;
      while (self.submitter_queues[idx].stealOne()) |entry| {
          while (!self.inject_queue.tryPush(entry)) std.atomic.spinLoopHint();
      }
      _ = self.submitter_nonempty.fetchAnd(~bit, .release);
      _ = self.submitter_free_mask.fetchOr(bit, .release);
  }
  ```

  1. Provide an out-of-band "scrub abandoned submitters" path that runs periodically or on `purgeWorkerCaches`.
  2. Document that `registerSubmitter` must be paired with `releaseSubmitter` via `defer`.
- **References:** CWE-401 (Missing Release of Resource), CWE-404 (Improper Resource Shutdown or Release), CWE-667 (Improper Locking).

---

### F-006 — `unreachable` branches assume `blocking_inject` non-null

- **Severity:** Medium
- **Confidence:** High
- **Location:** `/home/benji/src/devnw/zig/thread-pool/src/pool.zig:900-906`, `:1338-1343`
- **Evidence:**

  ```zig
  // src/pool.zig:900-906
  if (options.lane == .blocking) {
      if (self.blocking_inject) |*bi| {
          queued = bi.tryPush(entry);
      } else unreachable;
  }

  // src/pool.zig:1338-1343
  inline fn laneInjectQueue(self: *Core, lane: types.TaskLane) *BoundedRing(QueueEntry) {
      return switch (lane) {
          .default => &self.inject_queue,
          .blocking => if (self.blocking_inject) |*bi| bi else unreachable,
      };
  }
  ```

- **Impact:** The `unreachable` is gated on an invariant established by `Config.validate`: `allow_blocking_lane` requires `blocking_workers > 0` which allocates `blocking_inject`. The check at `enqueuePush:877` gates `.lane == .blocking` on `allow_blocking_lane`. This looks airtight. However:
  1. `rebalanceLane` at `:1214-1219` returns `.blocking` for `.default` workers when `cpu_helps_blocking` is set. `laneInjectQueue(.blocking)` is then called from `tryDrainLaneForWorker:1238`. `cpu_helps_blocking` requires `blocking_workers > 0` via `validate()`, so `blocking_inject` is non-null. Safe on current code paths.
  2. The invariant holds only because `Config` is treated as immutable after `init`. Nothing in the code enforces that. If a future refactor adds a `reconfigure` API or allows `Config` to be read-mutated post-init, the `unreachable` becomes a reachable trigger — which in ReleaseFast is **undefined behavior** (not a panic).
  3. In ReleaseFast builds, `unreachable` is a UB hint to the optimizer. If wrongly reached, the compiler may delete subsequent control-flow and produce arbitrary execution.
- **Exploit scenario:** Indirect. The invariant chain is validated. This is a latent footgun if anyone adds a lane-reconfiguration API.
- **Root cause:** Using `unreachable` for an invariant that depends on `Config.validate` correctness across the entire lifecycle. Defensive code should return an error or fall back to the default lane.
- **Remediation:** Replace `unreachable` with `return error.BlockingLaneDisabled` on the enqueue path and with `return null` on the drain path. Tiny diff:

  ```zig
  // enqueuePush
  if (options.lane == .blocking) {
      const bi_ptr = if (self.blocking_inject) |*bi| bi else return error.BlockingLaneDisabled;
      queued = bi_ptr.tryPush(entry);
  }
  ```

  For `laneInjectQueue`, refactor callers to handle `?*BoundedRing(QueueEntry)`.
- **References:** CWE-670 (Always-Incorrect Control Flow Implementation), CWE-758 (Reliance on Undefined / Unspecified Behavior).

---

### F-007 — `parseProcStatusKiB * 1024` can overflow u64 on a crafted `/proc/self/status`

- **Severity:** Low
- **Confidence:** Medium
- **Location:** `/home/benji/src/devnw/zig/thread-pool/src/stats/process_memory.zig:71-74`, `:78-88`
- **Evidence:**

  ```zig
  return .{
      .rss_current_bytes = parseProcStatusKiB(contents, "VmRSS:") * 1024,
      .rss_peak_bytes = parseProcStatusKiB(contents, "VmHWM:") * 1024,
      ...
  };

  fn parseProcStatusKiB(contents: []const u8, prefix: []const u8) u64 {
      ...
          while (field_it.next()) |field| {
              return std.fmt.parseInt(u64, field, 10) catch 0;
          }
      ...
  }
  ```

- **Impact:** `parseInt(u64, field, 10)` can return up to `2^64 - 1`. Multiplying by 1024 wraps in Zig's checked-by-default arithmetic — in Debug/ReleaseSafe this is a panic; in ReleaseFast it silently wraps. `/proc/self/status` is normally trustworthy (kernel-written), so the realistic attacker is a containerized pool where `/proc` is a bind-mount of a user-controlled filesystem, or a fuzzed test environment.
- **Exploit scenario:** Tightly constrained. Someone bind-mounts a file containing `VmRSS: 99999999999999999999 kB` into `/proc/self/status`. Call to `statsSnapshot()` → `process_memory.sample()` → panic in Debug build. In ReleaseFast, wraps to some small number — observability-only impact.
- **Root cause:** Trusting parsed input size.
- **Remediation:**

  ```zig
  fn parseProcStatusKiB(contents: []const u8, prefix: []const u8) u64 {
      ...
          while (field_it.next()) |field| {
              const kib = std.fmt.parseInt(u64, field, 10) catch return 0;
              // Cap at max/1024 to avoid overflow when callers multiply.
              return @min(kib, std.math.maxInt(u64) / 1024);
          }
      ...
  }
  ```

- **References:** CWE-190 (Integer Overflow or Wraparound).

---

### F-008 — Two concurrent `wait()` calls on the same handle can double-release

- **Severity:** Low
- **Confidence:** Medium
- **Location:** `/home/benji/src/devnw/zig/thread-pool/src/pool.zig:579-598`
- **Evidence:**

  ```zig
  pub fn wait(self: *Core, handle: types.TaskHandle) !void {
      if (!handle.isValid()) return error.InvalidHandle;
      if (handle.index >= self.descriptors.len) return error.InvalidHandle;

      self.sync.completion_mutex.lock();
      defer self.sync.completion_mutex.unlock();

      while (true) {
          const descriptor = &self.descriptors[handle.index];
          if (descriptor.generation != handle.generation) return error.InvalidHandle;
          switch (descriptor.state.load(.acquire)) {
              .completed, .cancelled => {
                  self.releaseDescriptor(handle.index);
                  return;
              },
              ...
          }
      }
  }
  ```

- **Impact:** `wait()` holds `completion_mutex` for the duration of the wait, so two threads calling `wait(handle)` for the same handle serialize. Thread 1 runs, sees `.completed`, calls `releaseDescriptor` (which resets state to `.free`, bumps freelist, recycles the slot). Thread 2 now holds the mutex, re-reads `descriptor.generation` — if Pool has been quiet, generation is still the same and state is `.free` → returns `InvalidHandle`. Safe.
  But if between the two `wait`s a third thread acquires a fresh descriptor that happens to reuse this index with a new generation, and then completes, Thread 2's generation check fails → safe. The race to the double-release is bounded by the mutex.
  Residual concern: if the user clones the handle and the **first** `wait` races with the `runTask` completion store / signal, and then a **second** `wait` runs strictly after both — no UAF.
  The practical UAF path is: user duplicates the handle, submits a new waitable with the same `wait_group`, races two `wait` calls. Current code is safe because of `completion_mutex`, but the double-release concern is worth documenting as a caller invariant.
- **Exploit scenario:** Caller misuse only. No path reachable from just the public API with a single caller.
- **Remediation:** Document that `TaskHandle` must not be shared across threads for `wait`, OR add a single-shot bit to the handle and CAS it on entry to `wait` to ensure at-most-one release. Minimal API note today; code is defensible.
- **References:** CWE-415 (Double Free) in the worst case; currently mitigated by mutex.

---

### F-009 — Scratch-buffer alloc failure silently reverts to `error.ScratchUnavailable`

- **Severity:** Low
- **Confidence:** High
- **Location:** `/home/benji/src/devnw/zig/thread-pool/src/pool.zig:1424-1429`, `/home/benji/src/devnw/zig/thread-pool/src/memory/scratch.zig:60-86`
- **Evidence:**

  ```zig
  // pool.zig
  if (!cancelled) {
      worker.scratch.beginTask() catch {
          _ = worker.scratch_init_failures.fetchAdd(1, .release);
      };
      descriptor.task_fn.?(descriptor.ctx.?, &runtime);
      worker.scratch.finishTask();
  }
  ```

  `beginTask` only fails if the previously-held `buffer` is non-null (it just resets the FBA). The actual allocation happens lazily in `ensureBuffer` on first `alloc`. If `allocator.alloc(u8, cap_bytes)` in `ensureBuffer` fails, `alloc` returns `error.OutOfMemory` which surfaces into the user's task. The `scratch_init_failures` counter only tracks `beginTask` failures (currently `beginTask` is infallible aside from an invariant violation).
- **Impact:** Low-severity observability mismatch. Tasks receive `error.OutOfMemory` or `error.ScratchUnavailable`, the counter does not increment. The pool continues running correctly; no memory corruption.
- **Root cause:** Mismatched failure-accounting between `beginTask` (no-op on first call) and `ensureBuffer` (the actual allocator call).
- **Remediation:** Either wire `ensureBuffer` failures into `scratch_init_failures`, or rename the counter to reflect what it actually measures.
- **References:** CWE-703 (Improper Check or Handling of Exceptional Conditions). Observability-only, not a security weakness.

---

### F-010 — `parseInt catch 0` silently hides malformed `/proc/self/status`

- **Severity:** Info
- **Location:** `/home/benji/src/devnw/zig/thread-pool/src/stats/process_memory.zig:84`
- **Evidence:**

  ```zig
  return std.fmt.parseInt(u64, field, 10) catch 0;
  ```

- **Impact:** Zero — by design. Observability returns 0 rather than propagating a parse error. Noted only because in conjunction with F-007, a malicious `/proc/self/status` could drive either zero values or overflow-triggered panic.

---

### F-011 — `BoundedRing` slot `value: T = undefined` relies on sequence as validity gate

- **Severity:** Info
- **Location:** `/home/benji/src/devnw/zig/thread-pool/src/queue/bounded_ring.zig:11-31`
- **Evidence:**

  ```zig
  const Slot = struct {
      sequence: std.atomic.Value(usize),
      value: T,
  };
  ...
  slot.* = .{
      .sequence = std.atomic.Value(usize).init(i),
      .value = undefined,
  };
  ```

- **Impact:** Correct by construction for the concrete `T = QueueEntry = u64`. If `T` is ever widened to a non-trivially-destructible type (has an allocator, a resource handle, etc.), `tryPush`'s blind `slot.value = value` overwrites an undefined slot — no leak, because the prior slot was never a valid instance — and `pop`'s `const value = slot.value` copies out. Works for POD types. Would silently break for types with ownership semantics.
- **Remediation:** Add a comptime assert that `T` is a POD:

  ```zig
  comptime std.debug.assert(@typeInfo(T).Int != null or @typeInfo(T).Enum != null or ...);
  ```

  Or: document that `T` must be trivially-copyable.

## 5. Secure Design Notes

Things the code does right; the next reviewer should protect these.

- **Generation-tagged queue entries** (`src/pool.zig:49-71`, `packEntry`/`entryIndex`/`entryGen`). The queue slot carries the descriptor's generation truncated to u32. `runTask:1354` and `cancelDescriptor:1590` both reject stale entries before the state CAS, defeating the "ghost duplicate" race that predates Phase H. This is the primary defense against double-dispatch.
- **State-machine CAS in `runTask`** (`src/pool.zig:1375`). Atomic `.queued` → `.running` transition is the single linearization point for task claim. A failed CAS is a silent drop of a duplicate-emitted entry, which keeps the pool resilient to upstream queue-path races.
- **ABA-tagged free-list** (`src/pool.zig:339`, `:1619-1641`, `:1655-1664`). 32-bit ABA counter plus 32-bit head prevents the classic Treiber-stack ABA. F-003 is the only wart.
- **Split per-lane counters** (`src/pool.zig:277, 298, :1736-1749`). `queued_tasks` and `queued_tasks_blocking` are on separate cachelines; the park handshake checks only the current lane. This is the right structure to keep the SC handshake livelock-free across lanes.
- **Cache-line padded Counters** (`src/pool.zig:269-328`). Hot write groups are isolated with explicit `cache_line` padding and `comptime` invariants asserting the offsets. Cache-ping-pong avoidance is baked in at the type level.
- **Seq_cst park handshake is correctly documented** (`src/pool.zig:1514-1524`). The worker's `is_parked.store(.seq_cst) → queued_tasks.load(.seq_cst)` paired with the submitter's `fetchAdd(.seq_cst) → is_parked.load(.seq_cst)` excludes IRIW, and the comment explicitly cites why `.release` would not suffice. High-quality atomics reasoning.
- **Bounded retries in `stealHalf`** (`src/queue/ring_queue.zig:120-124`). Retry cap of 256 prevents shutdown stalls on a livelocked stealer. Pragmatic defense against unknown upstream bugs.
- **Config validation is thorough** (`src/types.zig:233-264`). All cross-config invariants (`lane_extension` requires `blocking_workers`, `watchdog_interval_ns` requires `max_overflow_workers`, `max_threads + max_overflow_workers ≤ 64` bitmap width, etc.) are enforced with specific error values.
- **Scratch purge serialization** (`src/memory/scratch.zig:88-98`, test at `:177-216`). Idle-purge and external-purge paths are serialized through `purge_mutex`, and the design note correctly argues why the task-execution fast path can stay lock-free.
- **Stale sequence check in `BoundedRing.tryPush` / `pop`** (`src/queue/bounded_ring.zig:49-56`, `:71-79`). Per-slot `sequence` field is the correct Vyukov linearization mechanism; writes to `value` are sandwiched between `sequence` updates with proper release/acquire pairing.
- **Shutdown ordering in `joinAllWorkers`** (`src/pool.zig:635-672`). Watchdog is stopped before workers are joined (otherwise watchdog could spawn new overflow workers mid-teardown), then every worker is signaled via park_cond, then joined, then state is flipped to `.stopped`. Good discipline.

## 6. Coverage Gaps & Questions

- **Empirical data-race verification.** A ThreadSanitizer run (`zig build test-stress -Dtsan`) would confirm or refute F-001 (cross-pool TLS indexing — likely reproducible with a two-pool harness), F-003 (free_indices data race — likely silent on x86 but flagged by TSan), and validate the park-handshake claim experimentally. Not executed in this review.
- **Two-pool stress test.** Not reviewed; unclear whether `tests/stress.zig` or `tests/integration.zig` ever constructs two pools. A positive test that has a worker from Pool A submit into Pool B would immediately surface F-001 under Debug/ReleaseSafe.
- **Fuzz / abuse harness for `registerSubmitter` lifecycle.** Would exercise F-005 leak and double-release paths.
- **Shutdown-during-submit race matrix.** `submitInternal` loads `state` with `.acquire` then tries `enqueueTask`. Between the load and the push, `shutdown()` can flip state to `.shutdown_requested`, then `cancelQueuedTasks` can drain. A task pushed in this window is cancellable by the cancel pass. The current code handles this correctly via the state CAS in `runTask` and `cancelDescriptor`, but a dedicated stress test (spawn N submitters, call `shutdown(.cancel_pending)` once, assert no leaks, no panics, every `wait_group.done` is matched) would be valuable.
- **`Thread.spawn` failure injection.** F-002's UAF is not triggered in CI because `Thread.spawn` never fails there. An allocator-failure-injection test (custom allocator that fails on the Nth call) or `rlimit`-based harness would exercise the broken errdefer.
- **Platform matrix.** `src/stats/process_memory.zig` has Linux / macOS / Windows paths. Static review for bounds and error handling only — cannot verify the macOS `task_info` / Windows `GetProcessMemoryInfo` FFI signatures match the current SDK without running on those platforms.
- **Signal safety.** Zig threads are native pthreads/NTTP on the primary targets. The pool does not install signal handlers. Downstream code that uses `pthread_cancel` or receives async signals in worker threads may corrupt pool invariants; the pool has no defense. This is a documented pattern for thread pools and does not rise to a finding.
- **WaitGroup `add(delta)` overflow.** `add` does `fetchAdd(delta, .monotonic)` with no overflow check. A caller that passes `add(std.math.maxInt(u32))` twice wraps `pending` to a small number — no UAF but could cause `wait()` to return prematurely. Did not raise as a finding because of the narrow abuse path.

## 7. Prioritized Next Actions

1. **Fix F-001 (Critical)** — scope `threadlocal var tls_worker_index` / `tls_submitter_index` per-pool. Minimum: store `.{ pool: *Core, index: usize }` in TLS and check `tls.pool == self` before trusting `index`. Add a two-pool integration test that submits across pools to pin the regression.

2. **Fix F-002 (High)** — replace the bare `errdefer self.deinitOwned()` after the spawn loop with a spawn-aware errdefer that signals `.stopping`, broadcasts every spawned worker's `park_cond`, and joins before `deinitOwned` runs. Add an allocator-failure-injection test around `Core.init` that forces partial spawn.

3. **Fix F-003 (High)** — promote `free_indices: []u32` to `[]std.atomic.Value(u32)` and use `.monotonic` load/store. Zero runtime cost on x86_64 / aarch64; makes the Zig memory model valid for future ports and for ThreadSanitizer runs.

4. **Fix F-006 (Medium)** — replace `unreachable` on `blocking_inject == null` branches with explicit error returns. Eliminates a latent ReleaseFast UB footgun.

5. **Harden F-005 (Medium)** — add bounds check and idempotence guard to `releaseSubmitter`. Add a `defer` usage example in public docs. Consider a pool-level "reap abandoned submitters" helper.

6. **Soften F-004 (Medium)** — gate the `WaitGroup.done()` panic on `std.debug.runtime_safety` so ReleaseFast does not crash the host on a caller arithmetic bug. Preserve the panic in Debug/ReleaseSafe for bug-finding.

7. **Close F-007 (Low)** — clamp the `parseProcStatusKiB` result before multiplying by 1024; prevents an observability-only panic in Debug on a crafted `/proc`.

8. **Run ThreadSanitizer** on the existing stress suite after the above fixes are in. TSan will either confirm or refute the theoretical-but-unverified races in F-003 and F-008, and will also flag anything missed.

9. **Add a fuzz harness for the public API** — random interleavings of `submit` / `trySubmit` / `submitBatch` / `registerSubmitter` / `releaseSubmitter` / `shutdown(.drain)` / `shutdown(.cancel_pending)` / `wait` across multiple threads, with assertions on: no leaked descriptors (`task_desc_live == 0` post-shutdown), no leaked submitter slots (`submitter_free_mask` full), `counters.submitted == counters.completed + counters.cancelled`, and no allocator double-free reported by the testing allocator.
