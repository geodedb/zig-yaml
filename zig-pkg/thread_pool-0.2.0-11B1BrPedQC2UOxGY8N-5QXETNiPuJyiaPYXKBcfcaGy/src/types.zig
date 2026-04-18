const std = @import("std");
const build_options = @import("build_options");
const sync = @import("sync.zig");

/// COMPTIME-ELISION / P-09: build-time-pinned defaults.  When the library
/// is compiled with `-Dtimestamp-mode=<mode>` the corresponding `Config`
/// field defaults to that mode so callers that rely on the defaults do
/// not trip `error.BuildOptionMismatch` at `Core.init`.  `any` preserves
/// the historical `.full` default.
const default_timestamp_mode: TimestampMode = switch (build_options.timestamp_mode) {
    .any => .full,
    .full => .full,
    .disabled => .disabled,
};

/// COMPTIME-ELISION / P-09: build-time-pinned scheduler default.  When
/// `-Dscheduler-variant=<variant>` is passed, callers that rely on the
/// default get the pinned variant; `any` preserves the historical
/// `.global_queue` default.
const default_scheduler_variant: SchedulerVariant = switch (build_options.scheduler_variant) {
    .any => .global_queue,
    .global_queue => .global_queue,
    .work_stealing => .work_stealing,
    .lane_extension => .lane_extension,
};

/// Scheduler topology selector.  Picked at `ThreadPool.init` and never
/// changed afterwards.  All three variants share the public submit/wait
/// API and differ only in how queues and workers are wired internally.
///
/// Pick `global_queue` for simplicity and the lowest RSS baseline,
/// `work_stealing` for low-contention producer workloads, and
/// `lane_extension` when the workload has a mix of CPU and blocking
/// tasks that should run on dedicated worker pools.  See
/// `docs/SCHEDULER_DECISION.md` for the benchmark-driven comparison.
pub const SchedulerVariant = enum {
    /// One bounded FIFO inject queue; fixed worker set drains from it.
    /// Simplest, no local queues, no steals.
    global_queue,
    /// Per-worker LIFO slot + bounded local queue; idle workers refill
    /// from the inject queue and steal from peers.  Tokio-style ring
    /// queue by default (`Config.queue_kind = .ring`).
    work_stealing,
    /// `work_stealing` + dedicated blocking-lane workers and a separate
    /// inject queue for `.lane = .blocking` tasks.  See Slices L1–L4
    /// in `docs/superpowers/specs/2026-04-15-lane-extension-scheduler-design.md`.
    lane_extension,
};

/// Lane routing for a single submission.
///
/// `default` is the standard CPU lane.  `blocking` is rejected when
/// `Config.allow_blocking_lane == false` (returns
/// `error.BlockingLaneDisabled`).  When accepted, a `.blocking` task is
/// routed to the blocking inject queue and drained only by workers
/// whose `serves_lane == .blocking`.  Default workers do not steal
/// blocking work; blocking workers may (always-on) drain default work
/// when idle.  See `Config.cpu_helps_blocking` for the inverse.
pub const TaskLane = enum {
    default,
    blocking,
};

/// Submitter behaviour when a queue is full or the descriptor pool is
/// exhausted.
///
/// # .block deadlock footgun
/// Submitting from inside a task function (`TaskContext.worker_index`
/// is set) with `.backpressure = .block` can deadlock if the pool is
/// saturated — the worker cannot drain the queue because it is itself
/// blocked on the queue.  `.return_error` is the safe default for
/// tasks that may re-submit; `.block` is for external-submitter
/// threads that are provably off the critical path.
pub const BackpressurePolicy = enum {
    /// Return `error.QueueFull` / `error.TaskPoolExhausted` immediately
    /// on the first rejection.  Zero blocking; safe from any context.
    return_error,
    /// Block the submitter on the lane's backpressure condvar until
    /// capacity is available.  Never safe to call from a worker thread
    /// serving the same lane.
    block,
    /// `.block` with a `SubmitOptions.timeout_ns` deadline.  Returns
    /// `error.Timeout` if the deadline passes before capacity frees up.
    block_with_timeout,
};

/// Shutdown semantics selector for `ThreadPool.shutdown`.
///
/// `drain` waits for queued and running tasks to complete.
/// `cancel_pending` sweeps queued tasks into the cancelled state and
/// lets running tasks finish.  Both then join workers and release
/// resources.  See `docs/DESIGN.md § Shutdown Semantics`.
pub const ShutdownMode = enum {
    /// Reject new submissions; let queued and running work finish.
    drain,
    /// Reject new submissions; cancel queued tasks; let running
    /// tasks finish.
    cancel_pending,
};

/// Controls per-task timestamp behavior.  `full` records submit/start/complete
/// timestamps and populates wait/exec histograms — the legacy v0.2.0 mode.
/// `disabled` skips submit/start clock reads and the histogram observes,
/// saving ~40–80ns per task on Linux.  The complete-time clock read is kept
/// because the idle-purge logic in `idle()` depends on
/// `worker.last_idle_started_ns` to decide when to release scratch buffers.
pub const TimestampMode = enum {
    full,
    disabled,
};

/// Task lifecycle state machine:
///
///     free ──> reserved ──> queued ──> running ──> completed
///      ^                                  │            │
///      │                                  └──> cancelled│
///      │                                       │       │
///      └───────────────────────────────────────-┴───────┘
///
/// - `free`:      Descriptor slot available for reuse.
/// - `reserved`:  Slot claimed by acquireDescriptor; being populated.
/// - `queued`:    Task enqueued in inject or local queue.
/// - `running`:   Worker thread is executing the task function.
/// - `completed`: Task finished normally; awaiting wait() or auto-release.
/// - `cancelled`: Task was cancelled before or during execution.
pub const TaskState = enum(u8) {
    free,
    reserved,
    queued,
    running,
    completed,
    cancelled,
};

/// Local-queue implementation for per-worker queues in `work_stealing`
/// and `lane_extension` schedulers.  Ignored by `global_queue` (which
/// has no local queues).
pub const QueueKind = enum {
    /// Chase-Lev work-stealing deque. Correct for single-item steal only.
    chase_lev,
    /// Tokio-style SPMC ring. Supports batch-steal via stealHalf. Default.
    ring,
};

/// Pool-wide configuration.  Constructed by the caller and passed to
/// `ThreadPool.init`.  Normalisation happens inside
/// `Config.normalized()` — callers may pass a partial struct with
/// defaults.  `Config.validate()` enforces the cross-field invariants
/// that `normalized()` cannot simply clamp (for example
/// `lane_extension` requires `blocking_workers > 0`).
///
/// # ABI stability
/// Fields are additive; existing fields keep their defaults across
/// releases.  Adding a new field with a default preserves source
/// compatibility for callers using `.{ ... }` struct literal init.
///
/// # Cross-field coupling
/// Several fields only take effect in combination:
///   - `blocking_workers > 0` requires `allow_blocking_lane = true`
///     (and vice versa).
///   - `watchdog_interval_ns > 0` requires `max_overflow_workers > 0`.
///   - `hot_spinners > 0` requires `wake_every_n_tasks > 0`.
///   - `blocking_queue_capacity`, `blocking_backpressure`, and
///     `cpu_helps_blocking` are gated on `blocking_workers > 0`.
/// `validate()` rejects inconsistent combinations with a typed error.
pub const Config = struct {
    /// Minimum number of worker threads spawned at `init`.  0 means
    /// "same as `max_threads`" (the common case).  Clamped to
    /// `max_threads` if higher.
    min_threads: usize = 0,
    /// Maximum worker threads. Hard capped at 64 because the steal-scan
    /// non-empty-workers bitmap uses a single u64. `validate()` rejects
    /// values > 64 with `error.TooManyWorkers`. 0 means "auto-detect from
    /// CPU count" in `normalized()`; detected values above 64 are clamped.
    max_threads: usize = 0,
    /// Capacity of the pool-wide inject queue (default-lane).  Rounded
    /// up to a power of two by `normalized()` because the underlying
    /// `BoundedRing` uses bitmask modulo.  Must be > 0; must fit in
    /// `u32`.  This is the hard cap on *queued* tasks; descriptors are
    /// separately bounded by `queue_capacity + sum(local_queue_capacity)`.
    queue_capacity: usize = 1024,
    /// Per-worker local-queue capacity.  Used by `work_stealing` and
    /// `lane_extension`.  Rounded up to a power of two by `normalized()`.
    /// Must be > 0.  Larger values reduce inject-queue pressure and
    /// enable deeper batch-steals but increase the worst-case work
    /// sitting behind an oversubscribed core.
    local_queue_capacity: usize = 256,
    /// Max tasks a worker pulls from the inject queue per refill.  0 is
    /// normalised to 1.  Larger values amortise the inject-queue head
    /// CAS across more tasks but risk one worker monopolising a burst.
    inject_batch_size: usize = 32,
    /// `releaseDescriptor` signals blocked submitters on backpressure once
    /// per this many releases, rather than on every release. 0 disables
    /// coalescing (signal every release — the pre-2026-04-12 behavior).
    /// The submitter's `timedWait` on `backpressure_cond` bounds worst-case
    /// missed-signal latency.
    wake_coalesce_batch: u32 = 32,
    /// Number of workers reserved as always-spinning hot workers.
    /// These workers never park; they consume 1 core each at 100% CPU
    /// but catch submits without requiring a futex wake. When > 0, the
    /// submitter skips the wake scan entirely — hot-spinners propagate
    /// wakes themselves every `wake_every_n_tasks` tasks executed.
    ///
    /// Default 0 disables the feature (preserves current behavior).
    /// Must be strictly less than `max_threads` — at least one
    /// non-hot worker is required for the parked-worker fallback.
    /// See docs/superpowers/specs/2026-04-12-phase-f1b-reserved-hot-spinners-design.md.
    hot_spinners: u32 = 0,

    /// Hot-spinner wake propagation threshold. After executing this
    /// many tasks, a hot-spinner issues one `futex_wake` to recruit a
    /// parked worker. Amortizes wake cost across many submits while
    /// bounding worst-case wake latency to ~K × per-task duration.
    /// Ignored when `hot_spinners == 0`. Setting this to 0 while
    /// `hot_spinners > 0` is rejected by `validate()` — would starve
    /// parked workers on long-running tasks.
    wake_every_n_tasks: u32 = 64,
    /// Per-worker scratch arena cap in bytes.  Each worker allocates at
    /// most this many bytes of scratch storage (via `TaskContext.allocScratch`).
    /// The arena is purged on idle (`idle_purge_after_ns`) or explicitly
    /// via `ThreadPool.purgeWorkerCaches`.  Not additive with
    /// `queue_capacity` — this is transient per-task memory, not queue
    /// storage.
    worker_scratch_cap_bytes: usize = 64 * 1024,
    /// OBSERVABILITY-PIVOT / R-10: pool-wide memory budget in bytes.
    /// When `> 0`, scratch-arena allocations that would push
    /// `Stats.live_bytes` above this bound return `error.PoolMemoryBudgetExceeded`
    /// instead of hitting the allocator. `Stats.memory_budget_used_bytes`
    /// mirrors `live_bytes` so operators can watch headroom.
    ///
    /// The budget is *soft* in the sense that it only gates
    /// runtime-growing allocations (worker scratch arenas).
    /// Init-time allocations — workers, queues, descriptors — are
    /// deterministic from the other `Config` fields and are *not*
    /// checked against this budget; operators who want a hard total
    /// bound must size their other fields accordingly.
    ///
    /// Default `0` = unlimited (preserves pre-R-10 behaviour).
    max_pool_memory_bytes: u64 = 0,
    /// How long a worker spins before parking on the wake condvar when
    /// no work is visible.  Lower values reduce wake latency on
    /// bursty workloads; higher values reduce CPU burn.  Tuned in
    /// tandem with `spin_before_park_iters`.
    idle_park_after_ns: u64 = 250_000,
    /// Idle duration after which a worker purges its scratch arena.
    /// Bounds the "cold cache holding onto per-worker memory" anti-
    /// pattern observed in long-running daemons (see geode RSS
    /// regression hypothesis in `docs/GAP_ANALYSIS.md`).
    idle_purge_after_ns: u64 = 5_000_000,
    /// Phase G2 (re-land 2026-04-13): default 0. Once the spin's
    /// `queued_tasks` poll was removed (the dominant cross-core read on
    /// that cacheline), the spin body became pure CPU burn. Setting this
    /// to a non-zero value forces a `spinLoopHint` delay loop with only
    /// a per-iter `state` check — useful for stress tests that need to
    /// reproduce the polless-spin handshake (see tests/stress.zig:516,
    /// :75, :290) but not for normal workloads.
    spin_before_park_iters: usize = 0,
    /// Hard cap on time `ThreadPool.deinit` waits for running tasks to
    /// finish before force-joining workers.  Defaults to 30 seconds —
    /// long enough to absorb a drain pass on realistic workloads,
    /// short enough to catch a hung task in CI.
    deinit_timeout_ns: u64 = 30_000_000_000,
    /// Scheduler topology.  See `SchedulerVariant` for the trade-offs.
    scheduler_variant: SchedulerVariant = default_scheduler_variant,
    /// Local-queue implementation.  Only meaningful for `work_stealing`
    /// and `lane_extension`.  See `QueueKind`.
    queue_kind: QueueKind = .ring,
    /// When true, tasks submitted with `.lane = .blocking` are accepted and
    /// routed to a dedicated blocking-lane inject queue served by the workers
    /// reserved via `blocking_workers`. When false, `.lane = .blocking`
    /// submissions return `error.BlockingLaneDisabled`. Independent of
    /// `scheduler_variant` — the default `global_queue` and `work_stealing`
    /// variants also honor the flag.
    allow_blocking_lane: bool = false,
    /// Number of workers carved out of `max_threads` to serve the blocking
    /// lane. Not additive: if `max_threads = 8` and `blocking_workers = 2`,
    /// the pool spawns 8 threads, 2 of which serve blocking and 6 of which
    /// serve the default lane. Blocking workers drain the blocking-lane
    /// inject queue and never touch default-lane work (Slice L1 — dynamic
    /// rebalancing lands in Slice L3). Default workers only drain the
    /// default-lane queue.
    ///
    /// Must be strictly less than `max_threads` (at least one default worker
    /// required). `blocking_workers > 0` requires `allow_blocking_lane = true`.
    /// Default 0 preserves pre-lane-extension behavior byte-for-byte.
    /// See `docs/superpowers/specs/2026-04-15-lane-extension-scheduler-design.md`.
    blocking_workers: u32 = 0,
    /// Slice L2 — capacity of the blocking-lane inject queue. 0 means "use
    /// `queue_capacity`" (L1 behavior). Rounded to power-of-two in
    /// `normalized()`. Ignored when `blocking_workers == 0` (no blocking queue
    /// is allocated in that case). Letting operators size the lanes
    /// independently is the common reason to reach for L2 — a blocking lane
    /// that holds 8 long sleepers needs far less capacity than the default
    /// lane feeding thousands of CPU tasks.
    blocking_queue_capacity: usize = 0,
    /// Slice L2 — pool-wide override for blocking-lane backpressure policy.
    /// `null` means "inherit the caller's `SubmitOptions.backpressure`"
    /// (L1 behavior). Non-null forces the lane's submitters to use this
    /// policy regardless of what the caller asked for. The common use:
    /// force `.return_error` so an overloaded blocking lane cannot stall
    /// request handlers that happen to submit via `.block`.
    blocking_backpressure: ?BackpressurePolicy = null,
    /// Slice L2 — same pattern for the default lane. Symmetry matters:
    /// some deployments want the opposite invariant (force `.block` on
    /// default, `.return_error` on blocking).
    default_backpressure: ?BackpressurePolicy = null,
    /// Slice L3 — when true, default-lane workers fall back to the
    /// blocking inject queue (and steal from blocking workers' local
    /// queues) when their own lane is idle. Off by default because it
    /// violates the "CPU workers never touch blocking lane" isolation
    /// invariant — a blocking task executed on a CPU worker blocks
    /// that core from CPU work, and subsequent default-lane steals may
    /// pick up blocking work from the CPU worker's local queue. Requires
    /// `blocking_workers > 0` (a blocking lane must exist to help).
    ///
    /// Note: blocking-worker → default fallback is ALWAYS on (no config
    /// knob). Idle blocking workers draining CPU backlog is always a
    /// capacity win and does not violate any isolation invariant —
    /// default work landing in a blocking worker's local queue cannot
    /// be stolen by default workers (same-lane-only steal).
    cpu_helps_blocking: bool = false,
    /// Slice L4 — watchdog thread interval. When > 0, a dedicated thread
    /// wakes every `watchdog_interval_ns` and walks default-lane workers
    /// looking for tasks that have been running longer than
    /// `blocking_promotion_timeout_ns`. Zero disables the watchdog entirely
    /// (no thread spawned, no hot-path overhead). Requires
    /// `max_overflow_workers > 0` when set.
    watchdog_interval_ns: u64 = 0,
    /// Slice L4 — how long a default-lane task may run before the watchdog
    /// flags it as stalled. Ignored when `watchdog_interval_ns == 0`.
    /// Default 10ms matches the Tokio "max_blocking_time" rule of thumb.
    blocking_promotion_timeout_ns: u64 = 10_000_000,
    /// Slice L4 — hard cap on overflow-worker slots reserved at init.
    /// Zero disables overflow spawning (watchdog becomes observability-only).
    /// `max_threads + max_overflow_workers` must stay ≤ 64 (the
    /// workers_nonempty bitmap width).
    max_overflow_workers: u32 = 0,
    /// Per-task timestamp capture mode.  `.full` populates wait/exec
    /// latency histograms (the `Stats.task_wait_ns` / `task_exec_ns`
    /// output); `.disabled` elides those clock reads for a 40–80ns
    /// per-task saving on Linux.  See `TimestampMode` for why the
    /// complete-time read is always kept.
    timestamp_mode: TimestampMode = default_timestamp_mode,
    /// Maximum number of tasks a stealer takes from a single victim per steal
    /// attempt. With `queue_kind = .ring`, true batch-steal via stealHalf is
    /// used and values > 1 are correct. With `queue_kind = .chase_lev`,
    /// only single-item steal is correct and the runtime forces this to 1
    /// via `normalized()`.
    steal_batch_size: usize = 8,
    /// Maximum number of registered-submitter slots.  0 disables the
    /// `registerSubmitter` / `releaseSubmitter` API (callers submit via
    /// the ambient inject queue instead).  Each slot backs an
    /// independent per-submitter ring queue so one hot producer can't
    /// monopolise the inject-queue head CAS.  Capped at 64 by
    /// `normalized()` (bitmap width).
    max_submitter_queues: u32 = 0,
    /// Capacity of each registered-submitter queue.  0 is normalised to
    /// `local_queue_capacity`.  Must be > 0 when
    /// `max_submitter_queues > 0`.  Rounded up to a power of two.
    submitter_queue_capacity: usize = 0,

    pub fn normalized(self: Config) Config {
        var cfg = self;
        const cpu_guess = @max(std.Thread.getCpuCount() catch 1, 1);
        if (cfg.max_threads == 0) {
            cfg.max_threads = @min(cpu_guess, 64);
        }
        if (cfg.min_threads == 0) {
            cfg.min_threads = cfg.max_threads;
        }
        if (cfg.min_threads > cfg.max_threads) {
            cfg.min_threads = cfg.max_threads;
        }
        if (cfg.inject_batch_size == 0) {
            cfg.inject_batch_size = 1;
        }
        if (cfg.local_queue_capacity != 0) {
            cfg.local_queue_capacity = std.math.ceilPowerOfTwo(usize, cfg.local_queue_capacity) catch cfg.local_queue_capacity;
        }
        if (cfg.queue_capacity != 0) {
            cfg.queue_capacity = std.math.ceilPowerOfTwo(usize, cfg.queue_capacity) catch cfg.queue_capacity;
        }
        if (cfg.blocking_queue_capacity != 0) {
            cfg.blocking_queue_capacity = std.math.ceilPowerOfTwo(usize, cfg.blocking_queue_capacity) catch cfg.blocking_queue_capacity;
        }
        cfg.steal_batch_size = std.math.clamp(cfg.steal_batch_size, 1, 32);
        if (cfg.queue_kind == .chase_lev) cfg.steal_batch_size = 1;
        if (cfg.wake_coalesce_batch > 1024) cfg.wake_coalesce_batch = 1024;
        if (cfg.submitter_queue_capacity == 0 and cfg.max_submitter_queues > 0) {
            cfg.submitter_queue_capacity = cfg.local_queue_capacity;
        }
        if (cfg.submitter_queue_capacity != 0) {
            cfg.submitter_queue_capacity = std.math.ceilPowerOfTwo(usize, cfg.submitter_queue_capacity) catch cfg.submitter_queue_capacity;
        }
        if (cfg.max_submitter_queues > 64) cfg.max_submitter_queues = 64;
        return cfg;
    }

    pub fn validate(self: Config) !void {
        if (self.max_threads == 0) return error.InvalidMaxThreads;
        if (self.max_threads > 64) return error.TooManyWorkers;
        if (self.min_threads == 0) return error.InvalidMinThreads;
        if (self.min_threads > self.max_threads) return error.InvalidThreadBounds;
        if (self.queue_capacity == 0 or self.queue_capacity > std.math.maxInt(u32)) return error.InvalidQueueCapacity;
        if (self.local_queue_capacity == 0) {
            return error.InvalidLocalQueueCapacity;
        }
        if (self.scheduler_variant == .lane_extension and self.blocking_workers == 0)
            return error.LaneExtensionRequiresBlockingWorkers;
        if (self.inject_batch_size == 0) return error.InvalidInjectBatchSize;
        if (self.hot_spinners >= self.max_threads) return error.InvalidHotSpinners;
        if (self.hot_spinners > 0 and self.wake_every_n_tasks == 0) return error.InvalidWakeThreshold;
        if (self.blocking_workers >= self.max_threads) return error.InvalidBlockingWorkers;
        if (self.blocking_workers > 0 and !self.allow_blocking_lane)
            return error.BlockingLaneWithoutFlag;
        if (self.allow_blocking_lane and self.blocking_workers == 0)
            return error.AllowBlockingLaneRequiresWorkers;
        if (self.blocking_queue_capacity > std.math.maxInt(u32))
            return error.InvalidBlockingQueueCapacity;
        if (self.blocking_queue_capacity > 0 and self.blocking_workers == 0)
            return error.BlockingQueueCapacityWithoutLane;
        if (self.blocking_backpressure != null and self.blocking_workers == 0)
            return error.BlockingBackpressureWithoutLane;
        if (self.cpu_helps_blocking and self.blocking_workers == 0)
            return error.CpuHelpsBlockingWithoutLane;
        if (self.watchdog_interval_ns > 0 and self.max_overflow_workers == 0)
            return error.WatchdogWithoutOverflowCap;
        if (@as(u64, self.max_threads) + @as(u64, self.max_overflow_workers) > 64)
            return error.OverflowCapExceedsBitmap;
    }
};

/// Per-submission behaviour overrides.  Constructed by the caller and
/// passed to `ThreadPool.submit` / `trySubmit`.
///
/// # Backpressure + deadlock footgun
/// `backpressure = .return_error` is the only choice that is safe from
/// inside a task function — `.block` and `.block_with_timeout` can
/// deadlock when the caller is itself a worker that must drain the
/// queue to free capacity.  See `BackpressurePolicy`.
///
/// # Exclusivity
/// `waitable = true` and `wait_group != null` are both allowed on the
/// same submission; the caller may then `wait(handle)` *and* observe
/// the wait-group.  Cancellation is observed via
/// `cancellation_token.isCancelled()` checked inside the task function
/// at safe points.
pub const SubmitOptions = struct {
    /// When true, the submission returns a valid `TaskHandle` that
    /// can be passed to `ThreadPool.wait`.  The descriptor slot is
    /// NOT released until the first successful `wait()` call — do
    /// not leak waitable handles or the pool descriptor pool will
    /// be exhausted.
    waitable: bool = false,
    /// Optional pool-level completion counter.  `WaitGroup.add(1)` is
    /// called on successful submission and `WaitGroup.done()` on
    /// task completion / cancellation.  Caller-owned; must outlive
    /// all submissions that reference it.
    wait_group: ?*WaitGroup = null,
    /// Optional cancellation token polled inside the task function.
    /// Caller-owned.  Setting `token.cancel()` after submission marks
    /// queued tasks as cancelled and allows running tasks to observe
    /// the signal and exit early.
    cancellation_token: ?*CancellationToken = null,
    /// Behaviour when the target queue or descriptor pool is full.
    /// See `BackpressurePolicy`.  Default `.return_error` is the
    /// deadlock-safe choice; `.block` / `.block_with_timeout` are
    /// only safe from non-worker threads.
    backpressure: BackpressurePolicy = .return_error,
    /// Deadline for `.block_with_timeout`.  Ignored otherwise.
    timeout_ns: ?u64 = null,
    /// Lane routing.  See `TaskLane`.  `.blocking` requires
    /// `Config.allow_blocking_lane = true`.
    lane: TaskLane = .default,
};

/// Opaque handle to a waitable submission.  Produced by
/// `ThreadPool.submit` only when `SubmitOptions.waitable == true`; all
/// other submissions return `TaskHandle.invalid()`.
///
/// The handle carries `{index, generation}` — the descriptor slot and
/// a per-slot monotonically increasing counter.  `wait()` compares
/// `handle.generation` against the descriptor's current generation to
/// detect stale handles (the slot was reused after a prior waiter
/// released it).
///
/// # Exactly-once wait (SEC-018 / F-008)
/// `wait()` is safe to call concurrently on the same handle.  The
/// underlying release is CAS-guarded; exactly one caller performs
/// the descriptor release, others observe success.  See
/// `docs/security/REV-001.md` + `docs/DESIGN.md § Descriptor reuse`.
pub const TaskHandle = struct {
    /// Descriptor slot index.  `std.math.maxInt(u32)` means "invalid /
    /// non-waitable submission".
    index: u32 = std.math.maxInt(u32),
    /// Per-slot generation counter.  Incremented each time the slot is
    /// re-acquired; `wait()` rejects handles whose generation no longer
    /// matches the descriptor with `error.InvalidHandle`.
    generation: u64 = 0,
    /// Set iff this handle was produced by a `.waitable = true` submit.
    waitable: bool = false,

    /// Return an invalid handle suitable as a sentinel / default init.
    pub fn invalid() TaskHandle {
        return .{};
    }

    /// True iff the handle was produced by a successful waitable
    /// submission.  `wait()` on an invalid handle returns
    /// `error.InvalidHandle`.
    pub fn isValid(self: TaskHandle) bool {
        return self.waitable and self.index != std.math.maxInt(u32);
    }
};

/// Caller-owned cooperative cancellation primitive.  Pass a pointer
/// via `SubmitOptions.cancellation_token`; the task function must
/// poll `isCancelled()` at safe cancellation points (cancellation is
/// not preemptive).  `cancel()` also causes queued-but-not-yet-started
/// tasks to be transitioned to `.cancelled` during drain.
pub const CancellationToken = struct {
    cancelled: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    /// Mark the token as cancelled.  Ordered with `.release` so
    /// readers via `isCancelled()` see every preceding write.
    pub fn cancel(self: *CancellationToken) void {
        self.cancelled.store(true, .release);
    }

    /// Non-blocking check.  Idiomatic use inside a task is to poll at
    /// loop boundaries and `return` early on true.
    pub fn isCancelled(self: *const CancellationToken) bool {
        return self.cancelled.load(.acquire);
    }
};

/// A Go-style `sync.WaitGroup`: an atomic counter the caller adds to
/// ahead of submission and the pool decrements on task completion.
/// Callers block in `wait()` until the counter reaches zero.
///
/// Ownership is caller-side: the `WaitGroup` must outlive every
/// submission that references it via `SubmitOptions.wait_group`.
///
/// # Exactly-once done pairing
/// Each successful submission paired with a wait-group produces
/// exactly one matched `add(1)` / `done()` pair.  The pool invokes
/// `done()` once on task completion or cancellation.  Callers must
/// not call `done()` themselves for submitted tasks — it would
/// produce an underflow.
///
/// # Panic contract (REV-001)
/// If a task panics, `done()` is NOT called and `pending` stays
/// incremented.  Zig panics abort the process; any caller using a
/// custom panic handler to survive must treat the wait-group as
/// leaked.  See `docs/security/REV-001.md`.
pub const WaitGroup = struct {
    pending: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    mutex: sync.Mutex = .{},
    cond: sync.Condition = .{},

    /// Increment the pending count by `delta`.  Must be called before
    /// the corresponding submissions so `done()` cannot race past
    /// zero.
    pub fn add(self: *WaitGroup, delta: u32) void {
        _ = self.pending.fetchAdd(delta, .monotonic);
    }

    /// Decrement the pending count by 1 and broadcast to `wait()` on
    /// the transition 1→0.  The pool calls this exactly once per
    /// successful submission that carried a `wait_group` — callers
    /// normally do not call it themselves.
    ///
    /// # F-004: underflow contract
    /// Calling `done()` more times than `add()` is a caller bug.  In
    /// Debug / ReleaseSafe this panics loudly to catch the bug early.
    /// In ReleaseFast the library saturates `pending` at 0 and
    /// returns — the goal is to keep a long-running daemon alive
    /// even when a caller's accounting is off.
    ///
    /// # Panic contract (REV-001)
    /// If the pool invokes `done()` on behalf of a task and the task
    /// panics before that point, the call does NOT happen.  See the
    /// struct-level doc above and `docs/security/REV-001.md`.
    pub fn done(self: *WaitGroup) void {
        const previous = self.pending.fetchSub(1, .acq_rel);
        if (previous == 0) {
            // F-004: restore invariant so repeated misuse can't push
            // pending arbitrarily negative. Loud panic in Debug/ReleaseSafe
            // catches the caller bug in testing; in ReleaseFast the library
            // keeps running rather than crashing the host process.
            _ = self.pending.fetchAdd(1, .monotonic);
            if (std.debug.runtime_safety) {
                @panic("WaitGroup: done() called more times than add()");
            }
            return;
        }
        if (previous == 1) {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.cond.broadcast();
        }
    }

    /// Block until `pending` reaches zero.  Safe to call from multiple
    /// threads.  Returns immediately if `pending == 0` at call time.
    pub fn wait(self: *WaitGroup) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        while (self.pending.load(.acquire) != 0) {
            self.cond.wait(&self.mutex);
        }
    }

    /// Non-blocking observation of the pending count.
    pub fn pendingCount(self: *const WaitGroup) u32 {
        return self.pending.load(.acquire);
    }
};

/// Summary statistics for a latency histogram.  Produced by
/// `Stats.task_wait_ns` (queue wait) and `Stats.task_exec_ns`
/// (execution).  Percentiles are computed from a 64-bucket log2
/// histogram; quantisation error is ≤ 2× at each bucket boundary
/// (e.g. p50 may report the bucket's upper edge when the real
/// value is halfway through).
pub const LatencySummary = struct {
    /// Number of observations (events) accumulated.
    count: u64 = 0,
    /// Minimum observed latency in nanoseconds.
    min_ns: u64 = 0,
    /// Arithmetic mean latency in nanoseconds.
    mean_ns: u64 = 0,
    /// 50th-percentile (median) latency in nanoseconds.
    p50_ns: u64 = 0,
    /// 95th-percentile latency in nanoseconds.
    p95_ns: u64 = 0,
    /// 99th-percentile latency in nanoseconds.
    p99_ns: u64 = 0,
    /// 99.9th-percentile latency in nanoseconds (OBSERVABILITY-PIVOT / R-01).
    /// Computed from the same 64-bucket log2 histogram as the other
    /// percentiles; quantisation error grows at the tails and the field
    /// is best interpreted as "which log2 bucket holds the tail" rather
    /// than a precise ns figure.
    p999_ns: u64 = 0,
    /// 99.99th-percentile latency in nanoseconds (OBSERVABILITY-PIVOT / R-01).
    /// Computed from the 64-bucket log2 histogram.  Same caveats as
    /// `p999_ns`: on low sample counts the value degenerates to the
    /// maximum observed bucket.
    p9999_ns: u64 = 0,
    /// Maximum observed latency in nanoseconds.
    max_ns: u64 = 0,
};

/// Per-worker snapshot of runtime counters.  Element of
/// `Stats.worker_stats`.
pub const WorkerStats = struct {
    /// Worker index in `[0, max_threads)`.
    worker_index: usize = 0,
    /// Cumulative nanoseconds spent executing task functions.
    busy_ns: u64 = 0,
    /// Cumulative nanoseconds parked or spinning idle.
    idle_ns: u64 = 0,
    /// Current depth of the per-worker local queue.
    local_queue_depth: u32 = 0,
    /// Peak local-queue depth observed since init.
    local_queue_peak: u32 = 0,
    /// Cumulative park events (futex_wait returns).
    parks: u64 = 0,
    /// Cumulative wake events (futex_wake arrivals + wake_every_n_tasks).
    wakeups: u64 = 0,
    /// Successful steals from peer local queues or the inject queue.
    steals: u64 = 0,
    /// Failed steal attempts (empty victim or CAS race).
    steal_failures: u64 = 0,
    /// Tasks this worker has begun executing (started).
    started: u64 = 0,
    /// Tasks this worker has completed (started and ran to completion).
    completed: u64 = 0,
    /// Current bytes in-use in this worker's scratch arena.
    scratch_current_bytes: u64 = 0,
    /// Peak bytes ever in-use in this worker's scratch arena.
    scratch_peak_bytes: u64 = 0,
};

/// OS-level process memory sample.  Populated per-platform
/// (`/proc/self/status` on Linux, `task_vm_info` on macOS, API on
/// Windows) in `src/stats/process_memory.zig`.  All fields default
/// to 0 on platforms where the metric is unavailable.
pub const ProcessMemoryStats = struct {
    /// Resident Set Size at sample time, in bytes.
    rss_current_bytes: u64 = 0,
    /// Peak RSS observed over the process lifetime, in bytes.
    rss_peak_bytes: u64 = 0,
    /// Private (non-shared) bytes resident at sample time.
    private_current_bytes: u64 = 0,
    /// Peak private bytes over the process lifetime.
    private_peak_bytes: u64 = 0,
};

/// Consolidated pool-level snapshot.  Returned by
/// `ThreadPool.statsSnapshot()`.  Counters are read per-field with
/// `.acquire` ordering; the snapshot is NOT atomic as a group, so a
/// snapshot captured mid-submit will show a transient skew between
/// `submitted` and `active_tasks + completed + cancelled` — see
/// `accounting_skew_detected`.
pub const Stats = struct {
    /// Lifetime submissions that returned successfully.
    submitted: u64 = 0,
    /// Lifetime tasks the pool has begun executing.
    started: u64 = 0,
    /// Lifetime tasks that ran to completion.
    completed: u64 = 0,
    /// Lifetime tasks cancelled (via `CancellationToken` or
    /// `shutdown(.cancel_pending)`).
    cancelled: u64 = 0,
    /// Tasks currently in `.running` state.
    active_tasks: u64 = 0,
    /// Approximate sum of queue depths at snapshot time (not atomic).
    queue_depth_current: u64 = 0,
    /// Peak `queue_depth_current` observed since init.
    queue_depth_peak: u64 = 0,
    /// Lifetime successful steals across all workers.
    steals: u64 = 0,
    /// Lifetime failed steal attempts across all workers.
    steal_failures: u64 = 0,
    /// Lifetime wake events across all workers.
    wakeups: u64 = 0,
    /// Lifetime park events across all workers.
    parks: u64 = 0,
    /// Task descriptors currently in use (between acquire and release).
    task_desc_live: u64 = 0,
    /// Peak `task_desc_live` observed since init.
    task_desc_peak: u64 = 0,
    /// Lifetime allocator bytes handed out by the pool.
    total_alloc_bytes: u64 = 0,
    /// Lifetime allocator bytes returned to the allocator.
    total_free_bytes: u64 = 0,
    /// Lifetime allocation events.
    total_alloc_count: u64 = 0,
    /// `total_alloc_bytes - total_free_bytes` at snapshot time.
    live_bytes: u64 = 0,
    /// Peak `live_bytes` observed since init.
    peak_live_bytes: u64 = 0,
    /// Slice L4 — cumulative watchdog-observed stalls. Incremented each tick
    /// the watchdog sees a default-lane worker whose current task has been
    /// running longer than `Config.blocking_promotion_timeout_ns`. Always
    /// zero when `Config.watchdog_interval_ns == 0`.
    watchdog_stalls_detected: u64 = 0,
    /// Slice L4b — cumulative overflow-worker spawns.  Incremented each
    /// time the watchdog promotes a stalled default-lane slot by
    /// spawning a transient overflow worker.  Always zero when
    /// `Config.max_overflow_workers == 0`.
    overflow_spawns: u64 = 0,
    /// Slice L4b — cumulative overflow-worker retires (threads that
    /// finished their spawn burst and exited).  Should equal
    /// `overflow_spawns` after shutdown.
    overflow_retires: u64 = 0,
    /// Slice L4b — overflow workers currently alive.  `overflow_spawns
    /// - overflow_retires` at snapshot time.
    overflow_active: u64 = 0,
    /// REV-001 — best-effort counter-skew detector.  True when the
    /// snapshot observed `active_tasks > submitted - completed - cancelled`,
    /// which can only happen transiently (a snapshot caught mid-submit) or
    /// durably (a task panicked between the `active_tasks` increment in
    /// `runTask` and the matching decrement).  See
    /// `docs/security/REV-001.md` for the contract.  A persistent `true`
    /// across multiple snapshots is the operator's signal that a panicked
    /// task skewed the counters; the pool cannot self-recover from this
    /// condition — Zig panics are non-catchable by design.
    accounting_skew_detected: bool = false,
    /// Queue-wait latency summary (time between submit and start).
    /// Populated when `Config.timestamp_mode == .full`; zero-valued
    /// otherwise.
    task_wait_ns: LatencySummary = .{},
    /// Execution latency summary (time between start and complete).
    /// Populated when `Config.timestamp_mode == .full`.
    task_exec_ns: LatencySummary = .{},
    /// OBSERVABILITY-PIVOT / R-02: per-lane queue-wait latency for the
    /// default lane. Populated only when `Config.allow_blocking_lane ==
    /// true`; otherwise it is the zero-value `LatencySummary` (count=0)
    /// and operators should read `task_wait_ns` as the pool-wide summary.
    /// The split is computed at snapshot time from per-worker histograms
    /// keyed by `Worker.serves_lane`, so the observe hot path stays a
    /// single `LatencyHistogram.observe` call.
    default_wait_ns: LatencySummary = .{},
    /// OBSERVABILITY-PIVOT / R-02: per-lane execution latency for the
    /// default lane. Same activation rule as `default_wait_ns`.
    default_exec_ns: LatencySummary = .{},
    /// OBSERVABILITY-PIVOT / R-02: per-lane queue-wait latency for the
    /// blocking lane. Populated only when `Config.allow_blocking_lane ==
    /// true`. Lets operators see whether blocking-lane tasks are
    /// starving (high p99/p999) without the signal being diluted by
    /// default-lane traffic.
    blocking_wait_ns: LatencySummary = .{},
    /// OBSERVABILITY-PIVOT / R-02: per-lane execution latency for the
    /// blocking lane. Same activation rule as `blocking_wait_ns`.
    blocking_exec_ns: LatencySummary = .{},
    /// OBSERVABILITY-PIVOT / R-03: wake latency — time elapsed between
    /// a worker parking on `park_cond.timedWait` and that call returning
    /// because a submitter signaled it. Timeouts (i.e. idle-purge ticks
    /// where no signal arrived) are excluded so the summary measures
    /// real wake-up delay rather than the configured park timeout.
    /// Populated when `Config.timestamp_mode == .full`; zero-valued
    /// otherwise.
    wake_latency_ns: LatencySummary = .{},
    /// OBSERVABILITY-PIVOT / R-10: bytes currently counted against
    /// `Config.max_pool_memory_bytes`.  Mirrors `live_bytes` — they
    /// refer to the same accounting surface — but is exposed separately
    /// so operators can read "budget used" without having to know the
    /// budget happens to be implemented via the allocator-tracking
    /// counters. Always equals `live_bytes` (even when the budget is 0
    /// / unlimited).
    memory_budget_used_bytes: u64 = 0,
    /// OS-level memory snapshot.  See `ProcessMemoryStats`.
    memory: ProcessMemoryStats = .{},
    /// Per-worker statistics, indexed by worker_index.  Slice points
    /// into pool-owned storage; stable until the next
    /// `statsSnapshot()` call overwrites it.
    worker_stats: []const WorkerStats = &.{},
};

test "Config validation rejects impossible bounds" {
    var cfg = Config{ .max_threads = 1, .min_threads = 2 };
    try std.testing.expectError(error.InvalidThreadBounds, cfg.validate());
}

test "Config validation rejects lane_extension without blocking_workers" {
    var cfg = Config{ .max_threads = 2, .min_threads = 1, .scheduler_variant = .lane_extension };
    cfg = cfg.normalized();
    try std.testing.expectError(error.LaneExtensionRequiresBlockingWorkers, cfg.validate());
}

test "Config validation accepts lane_extension with blocking_workers" {
    var cfg = Config{
        .max_threads = 4,
        .min_threads = 4,
        .scheduler_variant = .lane_extension,
        .blocking_workers = 1,
        .allow_blocking_lane = true,
    };
    cfg = cfg.normalized();
    try cfg.validate();
}

test "Config validation rejects blocking_workers >= max_threads" {
    var cfg = Config{
        .max_threads = 4,
        .min_threads = 4,
        .blocking_workers = 4,
        .allow_blocking_lane = true,
    };
    cfg = cfg.normalized();
    try std.testing.expectError(error.InvalidBlockingWorkers, cfg.validate());
}

test "Config validation rejects blocking_workers without allow_blocking_lane" {
    var cfg = Config{
        .max_threads = 4,
        .min_threads = 4,
        .blocking_workers = 1,
        .allow_blocking_lane = false,
    };
    cfg = cfg.normalized();
    try std.testing.expectError(error.BlockingLaneWithoutFlag, cfg.validate());
}

test "Config validation rejects allow_blocking_lane without workers" {
    var cfg = Config{
        .max_threads = 4,
        .min_threads = 4,
        .blocking_workers = 0,
        .allow_blocking_lane = true,
    };
    cfg = cfg.normalized();
    try std.testing.expectError(error.AllowBlockingLaneRequiresWorkers, cfg.validate());
}

test "Config validation rejects blocking_queue_capacity without blocking_workers" {
    var cfg = Config{
        .max_threads = 4,
        .min_threads = 4,
        .blocking_queue_capacity = 128,
    };
    cfg = cfg.normalized();
    try std.testing.expectError(error.BlockingQueueCapacityWithoutLane, cfg.validate());
}

test "Config validation rejects blocking_backpressure without blocking_workers" {
    var cfg = Config{
        .max_threads = 4,
        .min_threads = 4,
        .blocking_backpressure = .return_error,
    };
    cfg = cfg.normalized();
    try std.testing.expectError(error.BlockingBackpressureWithoutLane, cfg.validate());
}

test "Config normalized rounds blocking_queue_capacity to power of two" {
    const cfg = (Config{ .blocking_queue_capacity = 100 }).normalized();
    try std.testing.expectEqual(@as(usize, 128), cfg.blocking_queue_capacity);
}

test "Config validation rejects cpu_helps_blocking without blocking_workers" {
    var cfg = Config{
        .max_threads = 4,
        .min_threads = 4,
        .cpu_helps_blocking = true,
    };
    cfg = cfg.normalized();
    try std.testing.expectError(error.CpuHelpsBlockingWithoutLane, cfg.validate());
}

test "Config validation rejects watchdog without overflow cap" {
    var cfg = Config{
        .max_threads = 4,
        .min_threads = 4,
        .watchdog_interval_ns = 1_000_000,
    };
    cfg = cfg.normalized();
    try std.testing.expectError(error.WatchdogWithoutOverflowCap, cfg.validate());
}

test "Config validation rejects overflow cap that overflows bitmap" {
    var cfg = Config{
        .max_threads = 60,
        .min_threads = 60,
        .max_overflow_workers = 8,
    };
    cfg = cfg.normalized();
    try std.testing.expectError(error.OverflowCapExceedsBitmap, cfg.validate());
}

test "WaitGroup blocks until count reaches zero" {
    var wg = WaitGroup{};
    wg.add(2);
    try std.testing.expectEqual(@as(u32, 2), wg.pendingCount());
    wg.done();
    try std.testing.expectEqual(@as(u32, 1), wg.pendingCount());
    wg.done();
    wg.wait();
    try std.testing.expectEqual(@as(u32, 0), wg.pendingCount());
}

test "F-004: WaitGroup.done underflow does not crash ReleaseFast" {
    // Only runs under ReleaseFast (runtime_safety == false).
    // In Debug/ReleaseSafe the panic is preserved as a caller-bug catcher.
    if (std.debug.runtime_safety) return error.SkipZigTest;

    var wg = WaitGroup{};
    wg.add(1);
    wg.done();
    wg.done(); // pre-fix: would crash; post-fix: must return cleanly
    // pending must be saturated at 0, not wrapped negative
    try std.testing.expectEqual(@as(u32, 0), wg.pendingCount());
}

test "Config normalized rounds local_queue_capacity to power of two" {
    const cfg = (Config{ .local_queue_capacity = 100 }).normalized();
    try std.testing.expectEqual(@as(usize, 128), cfg.local_queue_capacity);

    const cfg2 = (Config{ .local_queue_capacity = 256 }).normalized();
    try std.testing.expectEqual(@as(usize, 256), cfg2.local_queue_capacity);

    const cfg3 = (Config{ .local_queue_capacity = 1 }).normalized();
    try std.testing.expectEqual(@as(usize, 1), cfg3.local_queue_capacity);
}

test "Config normalized rounds queue_capacity to power of two" {
    const cfg = (Config{ .queue_capacity = 1000 }).normalized();
    try std.testing.expectEqual(@as(usize, 1024), cfg.queue_capacity);
}
