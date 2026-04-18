const std = @import("std");
const build_options = @import("build_options");
const sync = @import("sync.zig");
const clock = @import("clock.zig");
const types = @import("types.zig");
const BoundedRing = @import("queue/bounded_ring.zig").BoundedRing;
const WorkDeque = @import("queue/work_deque.zig").WorkDeque;
const RingQueue = @import("queue/ring_queue.zig").RingQueue;
const DescCache = @import("pool/desc_cache.zig").DescCache;
const WorkerScratch = @import("memory/scratch.zig").WorkerScratch;
const Accounting = @import("memory/scratch.zig").Accounting;
const LatencyHistogram = @import("stats/latency.zig").LatencyHistogram;
const process_memory = @import("stats/process_memory.zig");

/// Compile-time flag elides the F-001 per-pool TLS identity check on the
/// hot submit path. UNSAFE when a process hosts more than one ThreadPool
/// (restores the pre-F-001 OOB hazard). Default: false (safe).
const single_pool_mode = build_options.single_pool;

/// COMPTIME-ELISION / P-09: returns the comptime-known `TimestampMode` when
/// `-Dtimestamp-mode` pinned it at build time; returns `null` when the flag
/// is `.any` (runtime-configurable).  Callers branch with `comptime if` so
/// the pinned variant lowers to a compile-time-folded boolean and the hot
/// path drops the submit/start clock reads + histogram observes entirely.
fn pinnedTimestampMode() ?types.TimestampMode {
    return switch (build_options.timestamp_mode) {
        .any => null,
        .full => .full,
        .disabled => .disabled,
    };
}

/// COMPTIME-ELISION / P-09: comptime-known `true` when timestamps are
/// statically enabled, `false` when statically disabled, `null` when the
/// build flag is `.any` (fall back to `self.config.timestamp_mode`).
const ct_timestamps_enabled: ?bool = blk: {
    const pinned = pinnedTimestampMode() orelse break :blk null;
    break :blk pinned == .full;
};

/// COMPTIME-ELISION / P-09: returns the pinned `SchedulerVariant`, or
/// `null` if the flag is `.any`.  Pinned variants let `submit`, `enqueuePush`,
/// `nextTask`, and `statsSnapshot` elide dead-path branches at comptime.
fn pinnedSchedulerVariant() ?types.SchedulerVariant {
    return switch (build_options.scheduler_variant) {
        .any => null,
        .global_queue => .global_queue,
        .work_stealing => .work_stealing,
        .lane_extension => .lane_extension,
    };
}

/// COMPTIME-ELISION / P-09: comptime-known `uses_local` flag.  Returns a
/// concrete `bool` only when the scheduler variant is pinned; returns `null`
/// for the `.any` default so callers fall back to the runtime switch.
const ct_uses_local: ?bool = blk: {
    const pinned = pinnedSchedulerVariant() orelse break :blk null;
    break :blk pinned == .work_stealing or pinned == .lane_extension;
};

/// COMPTIME-ELISION / P-09: helper that returns `true` iff timestamps are
/// active for this pool.  Prefer comptime resolution when possible so the
/// hot path folds the branch; fall back to the runtime `self.config` read
/// when the flag is `.any`.
inline fn timestampsEnabled(self: *const Core) bool {
    if (ct_timestamps_enabled) |ct| return ct;
    return self.config.timestamp_mode == .full;
}

/// COMPTIME-ELISION / P-09: helper that returns `true` iff the scheduler
/// variant uses per-worker local queues.  Comptime-resolves when the
/// variant is pinned; reads `self.config.scheduler_variant` otherwise.
inline fn usesLocalQueues(self: *const Core) bool {
    if (ct_uses_local) |ct| return ct;
    return self.config.scheduler_variant == .work_stealing or
        self.config.scheduler_variant == .lane_extension;
}

/// TLS state scoped per pool. Each entry records the `Core *` that set it,
/// so cross-pool submits don't index pool-A's slot into pool-B's arrays
/// (F-001). The stored pointer is compared for identity only; no deref.
const TlsSlot = struct {
    pool: ?*anyopaque = null,
    index: usize = 0,
};
threadlocal var tls_worker_slot: TlsSlot = .{};
threadlocal var tls_submitter_slot: TlsSlot = .{};

/// Runtime context passed to every task function. Provides the worker
/// index, cancellation state, and access to the per-worker scratch allocator.
pub const TaskContext = struct {
    worker_index: usize,
    cancellation_token: ?*types.CancellationToken,
    scratch: *WorkerScratch,
    lane: types.TaskLane,

    pub fn isCancelled(self: *const TaskContext) bool {
        if (self.cancellation_token) |token| return token.isCancelled();
        return false;
    }

    pub fn allocScratch(self: *TaskContext, comptime T: type, count: usize) ![]T {
        return self.scratch.alloc(T, count);
    }
};

/// Function signature for submitted tasks. `ctx` is the opaque pointer
/// passed to submit; `runtime` provides cancellation and scratch access.
pub const TaskFn = *const fn (ctx: *anyopaque, runtime: *TaskContext) void;

/// A task function paired with its context, for use with `submitBatch`.
pub const BatchTask = struct {
    task_fn: TaskFn,
    ctx: *anyopaque,
};

const PoolState = enum(u8) {
    running,
    shutdown_requested,
    stopping,
    stopped,
};

/// Queue-slot payload: `{generation_tag: u32 high, index: u32 low}` packed
/// into a u64. Consumers check `entryGen(entry) == descriptor.generation`
/// (truncated) before the state CAS in `runTask` / `cancelDescriptor` to
/// reject stale entries — entries that were enqueued against a prior
/// generation of the same descriptor slot. Without this tag, a stale
/// entry emitted by a queue path can succeed at `state.cmpxchg(.queued,
/// .running)` on the new generation's `.queued` state, producing a
/// double-dispatch (confirmed under the Option D drain-vs-steal reorder;
/// also a latent race under the default drain-first order, just with a
/// much narrower window). See
/// `docs/superpowers/specs/2026-04-15-option-c-drain-hint-design.md`
/// "Post-mortem iteration 2" for the diagnosis.
pub const QueueEntry = u64;

inline fn packEntry(index: u32, generation: u64) QueueEntry {
    return (@as(u64, @as(u32, @truncate(generation))) << 32) | @as(u64, index);
}
inline fn entryIndex(entry: QueueEntry) u32 {
    return @as(u32, @truncate(entry));
}
inline fn entryGen(entry: QueueEntry) u32 {
    return @as(u32, @truncate(entry >> 32));
}

/// Tagged-union wrapper over the two per-worker local queue implementations.
/// Selected per-pool via `Config.queue_kind`. All call sites dispatch through
/// the unified methods (tryPushBottom, popBottom, steal, stealOne, len,
/// capacity) so the rest of `Core` is queue-kind agnostic.
const LocalQueue = union(enum) {
    chase_lev: WorkDeque(QueueEntry),
    ring: RingQueue(QueueEntry),

    fn init(allocator: std.mem.Allocator, size: usize, kind: types.QueueKind) !LocalQueue {
        return switch (kind) {
            .chase_lev => .{ .chase_lev = try WorkDeque(QueueEntry).init(allocator, size) },
            .ring => .{ .ring = try RingQueue(QueueEntry).init(allocator, size) },
        };
    }

    fn deinit(self: *LocalQueue) void {
        switch (self.*) {
            .chase_lev => |*q| q.deinit(),
            .ring => |*q| q.deinit(),
        }
    }

    fn tryPushBottom(self: *LocalQueue, value: QueueEntry) bool {
        return switch (self.*) {
            .chase_lev => |*q| q.tryPushBottom(value),
            .ring => |*q| q.tryPush(value),
        };
    }

    fn popBottom(self: *LocalQueue) ?QueueEntry {
        return switch (self.*) {
            .chase_lev => |*q| q.popBottom(),
            .ring => |*q| q.pop(),
        };
    }

    /// Steal up to `out.len` items. For chase_lev returns at most 1; for
    /// ring returns up to (len+1)/2 items via stealHalf.
    fn steal(self: *LocalQueue, out: []QueueEntry) usize {
        return switch (self.*) {
            .chase_lev => |*q| if (q.stealTop()) |v| blk: {
                out[0] = v;
                break :blk @as(usize, 1);
            } else 0,
            .ring => |*q| q.stealHalf(out),
        };
    }

    /// Single-item drain — used by shutdown to cancel pending tasks.
    fn stealOne(self: *LocalQueue) ?QueueEntry {
        return switch (self.*) {
            .chase_lev => |*q| q.stealTop(),
            .ring => |*q| blk: {
                var buf: [1]QueueEntry = undefined;
                if (q.stealHalf(buf[0..]) == 1) break :blk buf[0];
                break :blk null;
            },
        };
    }

    fn len(self: *LocalQueue) usize {
        return switch (self.*) {
            .chase_lev => |*q| q.len(),
            .ring => |*q| q.len(),
        };
    }

    fn capacity(self: *LocalQueue) usize {
        return switch (self.*) {
            .chase_lev => |*q| q.capacity(),
            .ring => |*q| q.capacity(),
        };
    }
};

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
    /// means two workers are racing for this descriptor — panic. Guarded
    /// reads/writes are gated by `claim_sentinel_enabled` (defined below).
    claimed_by: std.atomic.Value(i32) = std.atomic.Value(i32).init(-1),

    comptime {
        // OBSERVABILITY-PIVOT / R-06: dispatch hot group must fit in one
        // cacheline so `runTask`'s stale-filter and state-CAS never reach
        // out to the cold metric fields. The hot group starts at offset 0
        // (`state`) and ends immediately before `submit_ns`.
        //
        // Additionally: `state` is at offset 0, `task_fn` immediately after
        // (u8-atomic + padded alignment), and `generation` is the last hot
        // field. Cold fields (`submit_ns`, `start_ns`, `complete_ns`,
        // `claimed_by`) follow in strict order — see
        // docs/performance/LAYOUT_OFFSETS.md.
        // NOTE: `TaskDescriptor` is a plain `struct`, so Zig may reorder
        // fields for alignment. We therefore lock invariants that hold
        // regardless of layout order, not absolute offsets. See
        // `docs/performance/LAYOUT_OFFSETS.md` for the observed layout
        // under Zig 0.16.0.
        //
        //   a. The dispatch-hot read set (`state`, `task_fn`, `ctx`,
        //      `options`, `generation`) fits within two cachelines. If a
        //      future refactor adds a 6th hot field, it must either fit
        //      in the remaining slack or be explicitly split cold.
        //   b. Total `@sizeOf(TaskDescriptor)` is bounded so the slab
        //      doesn't blow up per-allocation memory on large
        //      `queue_capacity` values.
        const max_hot = @sizeOf(types.SubmitOptions) + 3 * @sizeOf(u64) + 16;
        std.debug.assert(@offsetOf(TaskDescriptor, "submit_ns") <= max_hot);
        std.debug.assert(@sizeOf(TaskDescriptor) <= 128);
    }
};

/// Sentinel value meaning "the lifo_slot is empty". Chosen as the max u64
/// so packed {gen, index} entries (low 32 bits are index) never collide —
/// widened from u32 to carry the generation tag.
const LIFO_SLOT_EMPTY: QueueEntry = 0xFFFF_FFFF_FFFF_FFFF;

/// When `true`, the per-descriptor `claimed_by` sentinel is active: every
/// successful state CAS in `runTask` / `cancelQueuedTasks` also CAS-claims
/// `claimed_by` from `-1` to the worker index, and a failed claim panics
/// (catches double-dequeue races). Tied to `std.debug.runtime_safety` so
/// Debug / ReleaseSafe builds keep the detector; ReleaseFast drops the
/// extra CAS pair from the dispatch hot path now that the Phase H race is
/// fixed (see `docs/performance/phase-h/`).
const claim_sentinel_enabled: bool = std.debug.runtime_safety;

const Worker = struct {
    thread: ?std.Thread = null,
    scratch: WorkerScratch,
    wait_histogram: LatencyHistogram = .{},
    exec_histogram: LatencyHistogram = .{},
    /// OBSERVABILITY-PIVOT / R-03: wake-latency histogram. Observed
    /// by the worker itself at `park_cond.timedWait` return when the
    /// wait returned because of a signal (i.e. `now - parked_at_ns` is
    /// less than the configured `idle_park_after_ns` timeout), so the
    /// histogram captures real wake delay rather than idle-purge ticks.
    wake_histogram: LatencyHistogram = .{},
    busy_ns: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    idle_ns: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    local_queue_peak: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    parks: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    wakeups: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    steals: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    steal_failures: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    started: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    completed: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    last_idle_started_ns: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    scratch_init_failures: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    park_mutex: sync.Mutex = .{},
    park_cond: sync.Condition = .{},
    /// 1 when this worker is parked, 0 otherwise. Fast-path check before
    /// acquiring park_mutex during signal — saves a futex syscall when the
    /// worker isn't actually parked.
    is_parked: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),
    /// Owner-private upper bound on `local_queues[worker_index]` length.
    /// Incremented on every push by the owner; decremented on every
    /// successful pop. Stealers reduce real length below this value —
    /// reconciled to 0 when `popBottom` returns null. Used to drive
    /// 0↔1 transitions of `Core.workers_nonempty` WITHOUT reading the
    /// queue's stealer-written `head` cacheline every pop.
    owned_queue_len: usize = 0,
    /// Tokio-style single-slot LIFO cache. When a task is submitted from this
    /// worker's thread, it goes here first (single atomic store); `nextTask`
    /// pops the slot ahead of the local ring. Cross-worker submits never
    /// touch this slot. Stealers never touch this slot either — only the
    /// owner writes to it. Sentinel value `LIFO_SLOT_EMPTY` (0xFFFF_FFFF)
    /// means "no cached task".
    lifo_slot: std.atomic.Value(QueueEntry) = std.atomic.Value(QueueEntry).init(LIFO_SLOT_EMPTY),
    /// Which lane this worker serves. Set once at spawn and never mutated
    /// in Slice L1 (dynamic rebalancing in L3 may soften this). Workers
    /// with `serves_lane = .blocking` drain the blocking-lane inject queue
    /// and only steal from other `.blocking` workers; default workers drain
    /// the default-lane queue and only steal from `.default` workers. See
    /// docs/superpowers/specs/2026-04-15-lane-extension-scheduler-design.md.
    serves_lane: types.TaskLane = .default,
    /// Slice L4 — timestamp (ns) when the currently-executing task was
    /// dispatched. Zero means idle (no task running). Written unconditionally
    /// in `runTask` when `Config.watchdog_interval_ns > 0`; skipped entirely
    /// when the watchdog is disabled to preserve zero-overhead hot path.
    /// The watchdog thread reads this on every tick to detect stalls.
    current_task_started_ns: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    is_overflow: bool = false,
    overflow_retired: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

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

    comptime {
        // OBSERVABILITY-PIVOT / R-06: `Worker` is a plain `struct`, so Zig
        // may reorder its fields. We therefore lock size-bounded
        // invariants rather than absolute offsets. See
        // `docs/performance/LAYOUT_OFFSETS.md` for the observed layout
        // under Zig 0.16.0.
        //
        //   a. `park_mutex` alignment is at least its natural atomic-
        //      state word size, so no cross-worker tear on mutex ops.
        //      Zig 0.16.0 `std.Thread.Mutex` is futex-based (u32 state),
        //      so `@alignOf == 4`; stronger alignment is not needed.
        //   b. Total `@sizeOf(Worker)` is bounded. The constant is a
        //      ceiling: a future refactor that blows it past the bound
        //      must explicitly update the invariant after documenting
        //      why the growth is acceptable.
        std.debug.assert(@alignOf(sync.Mutex) >= @alignOf(u32));
        // Observed size on Zig 0.16.0 / x86_64: 2048 bytes (was 1912
        // pre-`desc_cache`; Go-gap contended Slice 2-W appended 136
        // bytes at the end of the struct). Ceiling at 4096 (two pages)
        // so accidental cacheline-splitting field additions trip at
        // compile time.
        std.debug.assert(@sizeOf(Worker) <= 4096);
    }
};

/// Synchronization primitives for task completion. Worker parking uses
/// per-Worker park_mutex/park_cond to avoid contention on a shared mutex.
const Sync = struct {
    completion_mutex: sync.Mutex = .{},
    completion_cond: sync.Condition = .{},
    /// Backpressure primitives: blocked submitters (when queue/descriptor
    /// pool is full) sleep on a lane-scoped condvar rather than polling with
    /// a fixed-interval `Thread.sleep`. `releaseDescriptor` signals the
    /// condvars when capacity becomes available. `*_waiters` is an atomic
    /// fast-path counter so the producer path can skip acquiring the mutex
    /// entirely when nobody is blocked.
    ///
    /// Slice L2 splits the backpressure primitives per lane so a full
    /// blocking queue cannot thundering-herd wake default-lane submitters,
    /// and vice versa. When `blocking_workers == 0` the blocking primitives
    /// are initialized but never touched.
    default_backpressure_mutex: sync.Mutex = .{},
    default_backpressure_cond: sync.Condition = .{},
    default_backpressure_waiters: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    blocking_backpressure_mutex: sync.Mutex = .{},
    blocking_backpressure_cond: sync.Condition = .{},
    blocking_backpressure_waiters: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
};

/// Atomic counters tracking pool-wide task and worker events.
/// Fields are grouped by access pattern with cache-line padding
/// between groups to reduce false sharing between submit and worker paths.
const Counters = extern struct {
    const cache_line_size = std.atomic.cache_line;
    const field_size = @sizeOf(std.atomic.Value(u64));

    // === Hot write group (submit path, queued_tasks only) ===
    // `queued_tasks` is read by workers in nextTask; `submitted` was moved to
    // its own cacheline (below) so submitter writes to `submitted` do not
    // stall worker reads of `queued_tasks`.
    queued_tasks: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    _pad0a: [cache_line_size - field_size]u8 = undefined,

    // === Cumulative submit counter (observability-only, off hot read path) ===
    // Written at every spawn(); read only by snapshot() (cold path). Isolated
    // onto its own cacheline to decouple from `queued_tasks` write contention.
    submitted: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    _pad0b: [cache_line_size - field_size]u8 = undefined,

    // === Hot write group (worker path) ===
    active_tasks: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    cancelled: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    _pad1: [cache_line_size - 2 * field_size]u8 = undefined,

    // === Hot write group (blocking-lane submit path) ===
    // Parallel to `queued_tasks`, but only touched by `.lane = .blocking`
    // submits and their matching `runTask`/`cancelDescriptor` decrements.
    // Keeping blocking-lane counter-traffic off the default-lane cacheline
    // is a prerequisite for the park handshake: a default worker's SC load
    // of `queued_tasks` must not see blocking-lane increments, else it
    // would unpark repeatedly on cross-lane submits with nothing to do.
    queued_tasks_blocking: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    _pad1b: [cache_line_size - field_size]u8 = undefined,

    // === Diagnostic/cold counters ===
    wakeups: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    queue_depth_peak: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    task_desc_live: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    task_desc_peak: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    total_alloc_bytes: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    total_free_bytes: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    total_alloc_count: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    live_bytes: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    peak_live_bytes: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    // Slice L4 — watchdog observability. Incremented each time the watchdog
    // thread sees a default-lane worker that has been running one task for
    // longer than `Config.blocking_promotion_timeout_ns`. Cumulative across
    // the pool's lifetime; a single long-stalled task may be counted more
    // than once (once per watchdog tick it remains stalled).
    watchdog_stalls_detected: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    overflow_spawns: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    overflow_retires: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    overflow_active: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    comptime {
        // OBSERVABILITY-PIVOT / R-06: each hot-write counter owns a distinct
        // cacheline. See docs/performance/LAYOUT_OFFSETS.md for the
        // rationale: the park handshake depends on `queued_tasks` and
        // `queued_tasks_blocking` being SC-ordered on *separate* lines, so
        // a blocking-lane increment cannot wake a default-lane worker.
        std.debug.assert(@offsetOf(Counters, "queued_tasks") == 0);
        std.debug.assert(@offsetOf(Counters, "submitted") == cache_line_size);
        std.debug.assert(@offsetOf(Counters, "active_tasks") == 2 * cache_line_size);
        std.debug.assert(@offsetOf(Counters, "queued_tasks_blocking") == 3 * cache_line_size);
        // `cancelled` shares a line with `active_tasks` by design — both are
        // written only on completion/cancellation, never by submitters, so
        // the line stays worker-private.
        std.debug.assert(@offsetOf(Counters, "cancelled") == 2 * cache_line_size + field_size);
    }
};

const Core = struct {
    allocator: std.mem.Allocator,
    config: types.Config,
    accounting: Accounting = undefined,
    state: std.atomic.Value(PoolState) = std.atomic.Value(PoolState).init(.running),
    workers: []Worker,
    local_queues: []LocalQueue,
    descriptors: []TaskDescriptor,
    /// Singly-linked freelist of descriptor slots. Each slot stores the
    /// index of the next free descriptor (or `0xFFFFFFFF` sentinel).
    ///
    /// The per-slot atomic is `.monotonic` because the `.acq_rel` /
    /// `.acquire` on `free_top_tagged.cmpxchgWeak` establishes the
    /// happens-before relationship that orders the freelist reads and
    /// writes. No additional ordering on the per-slot load/store is
    /// needed. Promoted to `std.atomic.Value(u32)` for F-003: on
    /// weak-memory platforms (riscv, armv7) a plain `[]u32` access
    /// between ABA-tagged CAS operations could tear.
    free_indices: []std.atomic.Value(u32),
    free_top_tagged: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    inject_queue: BoundedRing(QueueEntry),
    /// Blocking-lane inject queue. Present iff `config.blocking_workers > 0`.
    /// Fed by `.lane = .blocking` submits; drained by workers whose
    /// `serves_lane == .blocking`. When `blocking_workers == 0` this stays
    /// null and the default-lane path is byte-for-byte identical to pre-L1
    /// behavior (A/B regression gate).
    blocking_inject: ?BoundedRing(QueueEntry) = null,
    sync: Sync = .{},
    counters: Counters align(std.atomic.cache_line) = .{},
    worker_stats_buffer: []types.WorkerStats,
    /// Bit `i` set iff worker `i`'s local queue is believed non-empty.
    /// Owner-side updates only on 0↔1 transitions. Replaces the
    /// 55-victim `len()` peek loop in nextTask with one u64 load.
    /// Max 64 workers (enforced by Config.validate).
    workers_nonempty: std.atomic.Value(u64) align(std.atomic.cache_line) = std.atomic.Value(u64).init(0),
    submitter_queues: []LocalQueue = &.{},
    submitter_nonempty: std.atomic.Value(u64) align(std.atomic.cache_line) = std.atomic.Value(u64).init(0),
    submitter_free_mask: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    /// Per-submitter SPSC caches of reserved descriptor indices. Parallel
    /// to `submitter_queues` — slot `i` belongs to submitter slot `i`.
    /// Allocated when `max_submitter_queues > 0`; zero-length otherwise.
    /// See Task 2.4 for call-site wiring.
    desc_caches: []DescCache = &.{},
    /// Slice L4 — optional watchdog thread. Spawned when
    /// `config.watchdog_interval_ns > 0`. Walks default-lane workers every
    /// interval looking for stalled tasks (task duration exceeds
    /// `config.blocking_promotion_timeout_ns`). Stalls increment
    /// `counters.watchdog_stalls_detected` and trigger overflow-worker
    /// spawn up to `config.max_overflow_workers`.
    watchdog_thread: ?std.Thread = null,
    /// Signals the watchdog thread to exit. Set by `joinAllWorkers` before
    /// join. Read by `watchdogMain` on each tick.
    watchdog_stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// Number of `Worker` entries whose `.scratch` and other fields were
    /// fully initialized by `Core.init` via `worker.* = .{...}`.  Used by
    /// `deinitOwned` so it does not call `worker.scratch.purge()` on entries
    /// that were never written — raw allocator memory whose `scratch.accounting`
    /// pointers are garbage.  Equals `workers.len` once `Core.init` succeeds;
    /// never mutated after that.
    init_worker_count: usize = 0,
    /// Number of `local_queues` entries that were fully initialized by
    /// `Core.init` via `LocalQueue.init`.  Parallel to `init_worker_count`.
    /// Equals `local_queues.len` once `Core.init` succeeds.
    init_queue_count: usize = 0,
    /// Number of `submitter_queues` entries that were fully initialized.
    /// Equals `submitter_queues.len` once the submitter-init block succeeds.
    init_submitter_count: usize = 0,

    /// QS-002: `Core.init` is decomposed into four narrow helpers plus an
    /// orchestrator.  The F-002 errdefer ladder is preserved verbatim at
    /// the orchestrator level because the cleanup order matters:
    ///
    ///   1. `deinitOwned` (outer errdefer) — tears down all allocations
    ///      bounded by init_worker_count / init_queue_count /
    ///      init_submitter_count.
    ///   2. spawned-workers cleanup (inner errdefer) — stops and joins
    ///      any workers that were already spawned before the failing
    ///      spawn.  Must run BEFORE deinitOwned or the join would touch
    ///      freed Worker storage.
    ///   3. watchdog cleanup (innermost errdefer) — currently a
    ///      defensive placeholder; the watchdog spawn is the last
    ///      fallible step.  Kept so a later maintainer doesn't
    ///      rediscover the need when adding a post-watchdog step.
    ///
    /// Helpers do NOT own errdefers — they take a partially-initialised
    /// `*Core` and either complete their slice of work or return error.
    /// The orchestrator's outer errdefer (`deinitOwned`) catches every
    /// partial-init failure because each helper updates the init_*
    /// counters as it progresses.
    pub fn init(self: *Core, allocator: std.mem.Allocator, config: types.Config) !void {
        var normalized = config.normalized();
        try normalized.validate();

        // COMPTIME-ELISION / P-09: if the caller compiled with a pinned
        // timestamp_mode or scheduler_variant, the runtime Config must
        // match or the elided-branch assumptions will silently break.
        if (comptime pinnedTimestampMode()) |pinned| {
            if (normalized.timestamp_mode != pinned) return error.BuildOptionMismatch;
        }
        if (comptime pinnedSchedulerVariant()) |pinned| {
            if (normalized.scheduler_variant != pinned) return error.BuildOptionMismatch;
        }

        try self.allocateStorage(allocator, normalized);
        errdefer self.deinitOwned();

        self.initDescriptorFreelist(normalized);
        try self.initWorkers(allocator, normalized);

        // F-002: spawn-aware cleanup ladder.  Must run before the outer
        // deinitOwned errdefer would free the Worker backing storage.
        // See the orchestrator doc above.
        var spawned_workers: usize = 0;
        errdefer {
            if (spawned_workers > 0) {
                self.state.store(.stopping, .release);
                for (self.workers[0..spawned_workers]) |*w| {
                    w.park_mutex.lock();
                    w.park_cond.broadcast();
                    w.park_mutex.unlock();
                }
                for (self.workers[0..spawned_workers]) |*w| {
                    if (w.thread) |t| {
                        t.join();
                        w.thread = null;
                    }
                }
            }
        }

        try self.spawnWorkers(normalized, &spawned_workers);

        if (normalized.watchdog_interval_ns > 0) {
            errdefer {
                // Defensive placeholder: if Core.init is ever extended with a
                // fallible step AFTER the watchdog spawn, this errdefer will
                // stop and join the watchdog before deinitOwned runs. As of
                // F-002, the watchdog spawn is the final fallible step in
                // init, so this body is currently unreachable — but the
                // structure is kept so the next maintainer does not have to
                // rediscover the need when adding a post-watchdog step.
                if (self.watchdog_thread) |t| {
                    self.watchdog_stop.store(true, .release);
                    t.join();
                    self.watchdog_thread = null;
                }
            }
            self.watchdog_thread = try std.Thread.spawn(.{}, watchdogMain, .{self});
        }
    }

    /// QS-002 helper (1/4): allocate backing storage for the pool.
    ///
    /// Populates `self.*` with every dynamically-sized slice + queue.
    /// Also wires `self.accounting` and records every allocation with
    /// `recordOwnedAlloc`.  On any failure here the Core is not
    /// recoverable — caller must not install the deinitOwned errdefer
    /// yet (init_worker_count / init_queue_count / init_submitter_count
    /// are still zero, so deinitOwned would be a no-op anyway, but
    /// leaves a cleaner stack trace to fail here before installing it).
    fn allocateStorage(self: *Core, allocator: std.mem.Allocator, normalized: types.Config) !void {
        const total_worker_slots = normalized.max_threads + normalized.max_overflow_workers;
        self.* = .{
            .allocator = allocator,
            .config = normalized,
            .workers = try allocator.alloc(Worker, total_worker_slots),
            .local_queues = try allocator.alloc(LocalQueue, total_worker_slots),
            .descriptors = try allocator.alloc(TaskDescriptor, normalized.queue_capacity),
            .free_indices = try allocator.alloc(std.atomic.Value(u32), normalized.queue_capacity),
            .inject_queue = try BoundedRing(QueueEntry).init(allocator, normalized.queue_capacity),
            .blocking_inject = if (normalized.blocking_workers > 0)
                try BoundedRing(QueueEntry).init(allocator, if (normalized.blocking_queue_capacity > 0)
                    normalized.blocking_queue_capacity
                else
                    normalized.queue_capacity)
            else
                null,
            .worker_stats_buffer = try allocator.alloc(types.WorkerStats, total_worker_slots),
        };

        self.accounting = .{
            .total_alloc_bytes = &self.counters.total_alloc_bytes,
            .total_free_bytes = &self.counters.total_free_bytes,
            .total_alloc_count = &self.counters.total_alloc_count,
            .live_bytes = &self.counters.live_bytes,
            .peak_live_bytes = &self.counters.peak_live_bytes,
            // OBSERVABILITY-PIVOT / R-10: thread the per-pool memory
            // budget through to the Accounting struct so `reserve`
            // can gate scratch allocations.
            .max_pool_memory_bytes = normalized.max_pool_memory_bytes,
        };

        self.recordOwnedAlloc(self.workers.len * @sizeOf(Worker));
        self.recordOwnedAlloc(self.local_queues.len * @sizeOf(LocalQueue));
        self.recordOwnedAlloc(self.descriptors.len * @sizeOf(TaskDescriptor));
        self.recordOwnedAlloc(self.free_indices.len * @sizeOf(std.atomic.Value(u32)));
        self.recordOwnedAlloc(self.worker_stats_buffer.len * @sizeOf(types.WorkerStats));
        self.recordOwnedAlloc(self.inject_queue.capacity() * @sizeOf(u32));
        if (self.blocking_inject) |*bi| {
            self.recordOwnedAlloc(bi.capacity() * @sizeOf(u32));
        }
    }

    /// QS-002 helper (2/4): initialise the descriptor freelist.
    ///
    /// Builds a singly-linked list through `free_indices`; the head
    /// tagged pointer starts at 0 (ABA counter 0, head index 0).
    /// Infallible; purely struct writes.
    fn initDescriptorFreelist(self: *Core, normalized: types.Config) void {
        for (self.descriptors, 0..) |*descriptor, idx| {
            descriptor.* = .{};
            // Build a singly-linked freelist: each slot points to the next.
            // The last slot uses the sentinel 0xFFFFFFFF (empty).
            self.free_indices[idx] = std.atomic.Value(u32).init(
                if (idx + 1 < normalized.queue_capacity)
                    @as(u32, @intCast(idx + 1))
                else
                    0xFFFFFFFF,
            );
        }

        // Tagged pointer: high 32 = ABA counter (starts 0), low 32 = head index.
        self.free_top_tagged = std.atomic.Value(u64).init(@as(u64, 0));
    }

    /// QS-002 helper (3/4): initialise Worker structs + per-worker
    /// local queues + submitter queues.  Mutates
    /// `init_worker_count` / `init_queue_count` / `init_submitter_count`
    /// as each sub-step succeeds so that `deinitOwned` (the caller's
    /// errdefer) can cleanly unwind a partial init.
    ///
    /// Ordering invariant: Worker struct is written FIRST (infallible),
    /// then the LocalQueue is init'd (fallible).  If the LocalQueue
    /// init fails, the Worker has valid scratch that deinitOwned can
    /// purge.  Reversing the order would leave a partially-init'd
    /// scratch field that would crash on `purge()`.
    fn initWorkers(self: *Core, allocator: std.mem.Allocator, normalized: types.Config) !void {
        const total_worker_slots = normalized.max_threads + normalized.max_overflow_workers;

        for (self.workers[0..normalized.max_threads], self.local_queues[0..normalized.max_threads], 0..) |*worker, *lq, idx| {
            // Initialize worker first (no allocation, cannot fail) so that
            // deinitOwned can safely call worker.scratch.purge() even if the
            // LocalQueue.init below fails partway through the loop.  Track
            // init_worker_count so deinitOwned knows the safe upper bound.
            worker.* = .{
                .scratch = WorkerScratch.init(allocator, self.accounting, normalized.worker_scratch_cap_bytes),
                .last_idle_started_ns = std.atomic.Value(u64).init(nowNs()),
                .serves_lane = if (idx < normalized.blocking_workers) .blocking else .default,
            };
            self.init_worker_count += 1;
            lq.* = try LocalQueue.init(allocator, normalized.local_queue_capacity, normalized.queue_kind);
            self.init_queue_count += 1;
            self.recordOwnedAlloc(lq.capacity() * @sizeOf(u32));
        }

        for (normalized.max_threads..total_worker_slots) |oidx| {
            // Same ordering: worker first (infallible), queue second (fallible).
            self.workers[oidx] = .{
                .scratch = WorkerScratch.init(allocator, self.accounting, normalized.worker_scratch_cap_bytes),
                .last_idle_started_ns = std.atomic.Value(u64).init(nowNs()),
                .serves_lane = .default,
                .is_overflow = true,
            };
            self.init_worker_count += 1;
            self.local_queues[oidx] = try LocalQueue.init(allocator, normalized.local_queue_capacity, normalized.queue_kind);
            self.init_queue_count += 1;
            self.recordOwnedAlloc(self.local_queues[oidx].capacity() * @sizeOf(u32));
        }

        if (normalized.max_submitter_queues > 0) {
            self.submitter_queues = try allocator.alloc(LocalQueue, normalized.max_submitter_queues);
            for (self.submitter_queues) |*sq| {
                sq.* = try LocalQueue.init(allocator, normalized.submitter_queue_capacity, normalized.queue_kind);
                self.init_submitter_count += 1;
            }
            self.submitter_free_mask = std.atomic.Value(u64).init((@as(u64, 1) << @intCast(normalized.max_submitter_queues)) - 1);
            self.recordOwnedAlloc(self.submitter_queues.len * @sizeOf(LocalQueue));

            self.desc_caches = try allocator.alloc(DescCache, normalized.max_submitter_queues);
            for (self.desc_caches) |*c| c.* = .{};
            self.recordOwnedAlloc(self.desc_caches.len * @sizeOf(DescCache));
        }
    }

    /// QS-002 helper (4/4): spawn worker threads (F-002 critical path).
    ///
    /// Writes `worker.thread` for each spawned worker and bumps
    /// `spawned_workers_out` so the caller's errdefer ladder knows the
    /// exact prefix of live threads to stop + join on failure.  The
    /// pointer-argument shape is load-bearing: Zig errdefers run in
    /// reverse, so the caller's "stop spawned workers" errdefer is
    /// already registered when `spawnWorkers` is called and must
    /// observe updates as the loop progresses.
    fn spawnWorkers(self: *Core, normalized: types.Config, spawned_workers_out: *usize) !void {
        // Spawn-aware cleanup: if a later spawn fails, tell already-spawned
        // workers to exit and join them before the outer errdefer runs
        // deinitOwned and frees their backing arrays (F-002).
        //
        // No drain is required before signalling exit: Core.init has not
        // yet returned, so no caller can have submitted a task. Workers'
        // shouldExit() predicate requires totalQueuedTasks() == 0, which
        // holds here. If Core.init is ever extended to submit an internal
        // warmup task, this errdefer must be revisited to drain first.
        for (self.workers[0..normalized.max_threads], 0..) |*worker, idx| {
            worker.thread = try std.Thread.spawn(.{}, workerMain, .{ self, idx });
            spawned_workers_out.* += 1;
        }
    }

    pub fn deinit(self: *Core) void {
        self.shutdown(.drain, self.config.deinit_timeout_ns) catch {
            std.log.warn("thread-pool deinit timed out after {d}ms with {d} active tasks and {d} queued", .{
                self.config.deinit_timeout_ns / std.time.ns_per_ms,
                self.counters.active_tasks.load(.acquire),
                self.totalQueuedTasks(),
            });
            self.joinAllWorkers();
        };
        self.deinitOwned();
    }

    pub fn trySubmit(self: *Core, task_fn: TaskFn, ctx: *anyopaque, options: types.SubmitOptions) !types.TaskHandle {
        return self.submitInternal(task_fn, ctx, options, false);
    }

    pub fn submit(self: *Core, task_fn: TaskFn, ctx: *anyopaque, options: types.SubmitOptions) !types.TaskHandle {
        return self.submitInternal(task_fn, ctx, options, true);
    }

    pub const SubmitBatchResult = struct {
        submitted: usize,
    };

    /// Submit up to `tasks.len` work items, amortizing per-batch atomic cost.
    ///
    /// Batches the three submitter-side atomics (`counters.submitted`,
    /// `queued_tasks` seq_cst increment, parked-worker wake scan) across the
    /// whole batch: one `fetchAdd(n)` on each counter and one wake scan that
    /// signals up to `n` parked workers. A 2026-04-14 ceiling A/B showed that
    /// removing these per-task atomics lifts flood_1m throughput by ~30%;
    /// amortizing them with this API captures a large fraction of that.
    ///
    /// Backpressure honors `options.backpressure`: on queue-full or
    /// descriptor-exhaust mid-batch, blocking policies drain the accumulated
    /// notify so workers can make progress, then retry; `.return_error`
    /// returns a partial `SubmitBatchResult.submitted` reflecting the count
    /// of tasks actually queued.
    pub fn submitBatch(self: *Core, tasks: []const BatchTask, options: types.SubmitOptions) !SubmitBatchResult {
        if (tasks.len == 0) return .{ .submitted = 0 };

        const effective = self.effectiveBackpressure(options);
        const deadline = if (effective == .block_with_timeout and options.timeout_ns != null)
            nowNs() + options.timeout_ns.?
        else
            0;

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
                    // Config rejects this lane. Flush pending then propagate
                    // the error regardless of backpressure — no amount of
                    // waiting will unblock a disabled lane.
                    if (pending_notify > 0) self.notifySubmits(pending_notify, options.lane);
                    if (submitted == 0) return err;
                    return .{ .submitted = submitted };
                },
            }
        }
        if (pending_notify > 0) self.notifySubmits(pending_notify, options.lane);
        return .{ .submitted = submitted };
    }

    pub fn registerSubmitter(self: *Core) !usize {
        while (true) {
            const mask = self.submitter_free_mask.load(.acquire);
            if (mask == 0) return error.NoSubmitterSlots;
            const idx: usize = @ctz(mask);
            const bit: u64 = @as(u64, 1) << @intCast(idx);
            if (self.submitter_free_mask.cmpxchgWeak(mask, mask & ~bit, .acq_rel, .monotonic) == null) {
                tls_submitter_slot = .{ .pool = @as(*anyopaque, @ptrCast(self)), .index = idx };
                _ = self.submitter_nonempty.fetchOr(bit, .release);
                return idx;
            }
        }
    }

    pub fn releaseSubmitter(self: *Core, idx: usize) void {
        // F-005: bounds-check — idx must be within the allocated submitter
        // queue slice. An out-of-range idx is silently ignored; the caller
        // cannot do anything useful with a bad index anyway.
        if (idx >= self.submitter_queues.len) return;

        const bit: u64 = @as(u64, 1) << @as(u6, @intCast(idx));

        // F-005: atomic claim of release-responsibility. CAS the bit from
        // 0 (in-use) to 1 (free) in one step so that at most one concurrent
        // releaseSubmitter wins and performs the drain. A naive load-then-
        // act would let two simultaneous release calls both see bit=0 and
        // both drain submitter_queues[idx] concurrently — a data race
        // against the queue's SPMC contract.
        //
        // Residual caller-contract constraint: this CAS does NOT close the
        // pathological release(A) → register(A) → release(A) sequence,
        // because the second release sees bit=0 again (the intervening
        // registerSubmitter cleared it) and proceeds. Closing that case
        // requires per-slot generation tags on the free_mask itself, which
        // is an API-breaking change out of scope for F-005. Callers MUST
        // ensure a given idx is released at most once per registration.

        // Drain desc_cache BEFORE the free_mask CAS publishes the slot as free.
        // DescCache is SPSC — if we drained after the CAS, a concurrent
        // registerSubmitter could claim this slot and start using desc_caches[idx]
        // before our drain completes, racing on `head`. TLS guard ensures only the
        // legitimate owner (the thread that registered) performs the drain; a stray
        // helper thread with no TLS binding must not corrupt the real owner's cache.
        // Cached descriptors are in `.reserved` state (set by acquireDescriptorBatch
        // at refill time) and releaseDescriptor accepts .reserved in its terminal-
        // state CAS loop.
        if (tls_submitter_slot.pool == @as(*anyopaque, @ptrCast(self)) and
            tls_submitter_slot.index == idx)
        {
            const cache = &self.desc_caches[idx];
            var buf: [DescCache.capacity]u32 = undefined;
            const n = cache.drainAll(&buf);
            var i: usize = 0;
            while (i < n) : (i += 1) {
                self.releaseDescriptor(buf[i]);
            }
            tls_submitter_slot = .{};
        }

        while (true) {
            const current = self.submitter_free_mask.load(.acquire);
            if ((current & bit) != 0) return; // already free — idempotent bail
            if (self.submitter_free_mask.cmpxchgWeak(current, current | bit, .acq_rel, .acquire) == null) {
                break; // we won the release
            }
        }

        // Drain: bounded spin-retry on inject_queue.tryPush so no task is
        // silently dropped in the common case. The outer loop terminates
        // because the submitter queue is bounded; the inner spin is bounded
        // to prevent livelock if inject_queue consumers are stalled (e.g.
        // the pool is being torn down while a release races shutdown).
        const max_push_retries: u32 = 1 << 20;
        while (self.submitter_queues[idx].stealOne()) |entry| {
            var retries: u32 = 0;
            while (!self.inject_queue.tryPush(entry)) {
                std.atomic.spinLoopHint();
                retries += 1;
                if (retries >= max_push_retries) break; // pathological: drop to avoid livelock
            }
        }

        _ = self.submitter_nonempty.fetchAnd(~bit, .release);
        // Note: free_mask bit was already set by the CAS above.
    }

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
                    // SEC-018 (F-008): use a CAS to drive the
                    // terminal `.completed|.cancelled → .free` transition
                    // so exactly one concurrent `wait()` caller releases the
                    // descriptor slot. Callers that lose the CAS return
                    // success with no side effect — the task demonstrably
                    // completed, and returning `error.InvalidHandle` there
                    // would be a lie. `releaseDescriptor` itself is also
                    // CAS-guarded as defense-in-depth, so the direct call
                    // here is safe even if the state flipped between the
                    // load above and the store inside.
                    self.releaseDescriptor(handle.index);
                    return;
                },
                .free => {
                    // Generation still matches but state is .free: another
                    // `wait()` on this handle already won the release CAS.
                    // This is the post-SEC-018 success path for the losing
                    // caller of a concurrent double-wait: both callers
                    // observed that the task completed, so both return
                    // success.
                    return;
                },
                else => self.sync.completion_cond.wait(&self.sync.completion_mutex),
            }
        }
    }

    pub fn waitGroup(self: *Core) types.WaitGroup {
        _ = self;
        return .{};
    }

    pub fn shutdown(self: *Core, mode: types.ShutdownMode, timeout_ns: ?u64) !void {
        const old_state = self.state.swap(.shutdown_requested, .acq_rel);
        if (old_state != .running) {
            // Another shutdown is already in progress or completed.
            // Ensure all threads are joined before returning.
            self.joinAllWorkers();
            return;
        }

        if (mode == .cancel_pending) {
            try self.cancelQueuedTasks();
        }

        const deadline = if (timeout_ns) |ns| nowNs() + ns else 0;
        while (true) {
            const queued = self.totalQueuedTasks();
            const active = self.counters.active_tasks.load(.acquire);
            if (queued == 0 and active == 0) break;
            if (deadline != 0 and nowNs() >= deadline) return error.Timeout;

            // Wait on the default-lane backpressure condvar, which
            // releaseDescriptor signals on every completion (both lanes are
            // signaled, so either queue draining progresses the shutdown).
            // Cap at 10ms so we re-check state even if a signal is lost.
            self.waitForCapacity(deadline, .default);
        }

        self.joinAllWorkers();
    }

    fn joinAllWorkers(self: *Core) void {
        // Signal all workers to exit
        self.state.store(.stopping, .release);
        // Stop the watchdog FIRST so it cannot spawn new overflow workers
        // while we are joining. The watchdog only reads worker atomics and
        // spawns threads — stopping it before the worker join pass ensures
        // no new threads appear after we start joining.
        if (self.watchdog_thread) |thread| {
            self.watchdog_stop.store(true, .release);
            thread.join();
            self.watchdog_thread = null;
        }
        // Wake every worker so they observe the state change and exit.
        for (self.workers) |*w| {
            w.park_mutex.lock();
            w.park_cond.broadcast();
            w.park_mutex.unlock();
        }
        // Wake any submitters blocked on backpressure so they observe the
        // state change and return error.ShutdownInProgress instead of
        // sleeping forever. Broadcast both lanes because either may have
        // waiters parked on a full queue.
        self.sync.default_backpressure_mutex.lock();
        self.sync.default_backpressure_cond.broadcast();
        self.sync.default_backpressure_mutex.unlock();
        self.sync.blocking_backpressure_mutex.lock();
        self.sync.blocking_backpressure_cond.broadcast();
        self.sync.blocking_backpressure_mutex.unlock();

        // Join all threads (regular + any active overflow workers)
        for (self.workers) |*worker| {
            if (worker.thread) |thread| {
                thread.join();
                worker.thread = null;
            }
        }
        self.state.store(.stopped, .release);
    }

    /// Wait for descriptor/queue capacity to free up on `lane`, bounded by
    /// `deadline` (absolute nanoseconds; 0 = no deadline). Cap each wait at
    /// 10ms so we re-check state periodically even if a signal is missed.
    ///
    /// Split per-lane (L2): a full blocking queue parks blocking-lane
    /// submitters only, leaving default-lane submitters free to proceed.
    fn waitForCapacity(self: *Core, deadline: u64, lane: types.TaskLane) void {
        const waiters = self.backpressureWaiters(lane);
        const mtx = self.backpressureMutex(lane);
        const cond = self.backpressureCond(lane);

        _ = waiters.fetchAdd(1, .monotonic);
        defer _ = waiters.fetchSub(1, .monotonic);

        mtx.lock();
        defer mtx.unlock();

        const wait_ns: u64 = if (deadline != 0) blk: {
            const now = nowNs();
            break :blk if (now >= deadline) 0 else @min(deadline - now, 10_000_000);
        } else 10_000_000;

        if (wait_ns > 0) {
            cond.timedWait(mtx, wait_ns) catch {};
        }
    }

    inline fn backpressureWaiters(self: *Core, lane: types.TaskLane) *std.atomic.Value(u32) {
        return switch (lane) {
            .default => &self.sync.default_backpressure_waiters,
            .blocking => &self.sync.blocking_backpressure_waiters,
        };
    }

    inline fn backpressureMutex(self: *Core, lane: types.TaskLane) *sync.Mutex {
        return switch (lane) {
            .default => &self.sync.default_backpressure_mutex,
            .blocking => &self.sync.blocking_backpressure_mutex,
        };
    }

    inline fn backpressureCond(self: *Core, lane: types.TaskLane) *sync.Condition {
        return switch (lane) {
            .default => &self.sync.default_backpressure_cond,
            .blocking => &self.sync.blocking_backpressure_cond,
        };
    }

    /// Effective backpressure policy for a submit: `Config.blocking_backpressure`
    /// / `Config.default_backpressure` forces the lane's policy when non-null
    /// (L2), otherwise the caller's `SubmitOptions.backpressure` wins.
    inline fn effectiveBackpressure(self: *const Core, options: types.SubmitOptions) types.BackpressurePolicy {
        return switch (options.lane) {
            .blocking => self.config.blocking_backpressure orelse options.backpressure,
            .default => self.config.default_backpressure orelse options.backpressure,
        };
    }

    pub fn statsSnapshot(self: *Core) types.Stats {
        var aggregate_wakeups: u64 = 0;
        var aggregate_started: u64 = 0;
        var aggregate_completed: u64 = 0;
        var aggregate_steals: u64 = 0;
        var aggregate_steal_failures: u64 = 0;
        var aggregate_parks: u64 = 0;
        for (self.workers, 0..) |*worker, idx| {
            const w_wakeups = worker.wakeups.load(.acquire);
            const w_started = worker.started.load(.acquire);
            const w_completed = worker.completed.load(.acquire);
            const w_steals = worker.steals.load(.acquire);
            const w_steal_failures = worker.steal_failures.load(.acquire);
            const w_parks = worker.parks.load(.acquire);
            aggregate_wakeups += w_wakeups;
            aggregate_started += w_started;
            aggregate_completed += w_completed;
            aggregate_steals += w_steals;
            aggregate_steal_failures += w_steal_failures;
            aggregate_parks += w_parks;
            self.worker_stats_buffer[idx] = .{
                .worker_index = idx,
                .busy_ns = worker.busy_ns.load(.acquire),
                .idle_ns = worker.idle_ns.load(.acquire),
                .local_queue_depth = @as(u32, @intCast(self.local_queues[idx].len())),
                .local_queue_peak = worker.local_queue_peak.load(.acquire),
                .parks = w_parks,
                .wakeups = w_wakeups,
                .steals = w_steals,
                .steal_failures = w_steal_failures,
                .started = w_started,
                .completed = w_completed,
                .scratch_current_bytes = @as(u64, @intCast(worker.scratch.bytesCurrent())),
                .scratch_peak_bytes = @as(u64, @intCast(worker.scratch.bytesPeak())),
            };
        }

        const memory = process_memory.sample() catch types.ProcessMemoryStats{};

        var merged_wait = LatencyHistogram{};
        var merged_exec = LatencyHistogram{};
        // OBSERVABILITY-PIVOT / R-02: per-lane merged histograms populated
        // only when the blocking lane is enabled. Hot-path observe remains
        // a single per-worker `LatencyHistogram.observe` call; the split is
        // purely a snapshot-time aggregation keyed on `Worker.serves_lane`.
        var merged_default_wait = LatencyHistogram{};
        var merged_default_exec = LatencyHistogram{};
        var merged_blocking_wait = LatencyHistogram{};
        var merged_blocking_exec = LatencyHistogram{};
        // OBSERVABILITY-PIVOT / R-03: merged wake-latency histogram.
        var merged_wake = LatencyHistogram{};
        const per_lane_active = self.config.allow_blocking_lane;
        for (self.workers) |*worker| {
            merged_wait.merge(&worker.wait_histogram);
            merged_exec.merge(&worker.exec_histogram);
            merged_wake.merge(&worker.wake_histogram);
            if (per_lane_active) {
                switch (worker.serves_lane) {
                    .default => {
                        merged_default_wait.merge(&worker.wait_histogram);
                        merged_default_exec.merge(&worker.exec_histogram);
                    },
                    .blocking => {
                        merged_blocking_wait.merge(&worker.wait_histogram);
                        merged_blocking_exec.merge(&worker.exec_histogram);
                    },
                }
            }
        }

        // REV-001 — compute best-effort counter-skew flag.  A panicked
        // task leaves `active_tasks` incremented but never reaches the
        // matching decrement or the `completed` bump.  A snapshot caught
        // mid-submit will also show a transient skew, so callers must
        // look for a *persistent* `true` to distinguish real skew from
        // sampling noise.  See `docs/security/REV-001.md`.
        const submitted_snap = self.counters.submitted.load(.acquire);
        const cancelled_snap = self.counters.cancelled.load(.acquire);
        const active_snap = self.counters.active_tasks.load(.acquire);
        const accounted = aggregate_completed + cancelled_snap;
        const skew = if (submitted_snap >= accounted)
            active_snap > submitted_snap - accounted
        else
            // Very large wrap / test harness that reset counters mid-flight
            // — treat as no skew rather than wrapping the subtraction.
            false;

        return .{
            .submitted = submitted_snap,
            .started = aggregate_started,
            .completed = aggregate_completed,
            .cancelled = cancelled_snap,
            .active_tasks = active_snap,
            .queue_depth_current = self.totalQueuedTasks(),
            .queue_depth_peak = self.counters.queue_depth_peak.load(.acquire),
            .steals = aggregate_steals,
            .steal_failures = aggregate_steal_failures,
            .wakeups = aggregate_wakeups,
            .parks = aggregate_parks,
            .task_desc_live = self.counters.task_desc_live.load(.acquire),
            .task_desc_peak = self.counters.task_desc_peak.load(.acquire),
            .total_alloc_bytes = self.counters.total_alloc_bytes.load(.acquire),
            .total_free_bytes = self.counters.total_free_bytes.load(.acquire),
            .total_alloc_count = self.counters.total_alloc_count.load(.acquire),
            .live_bytes = self.counters.live_bytes.load(.acquire),
            .peak_live_bytes = self.counters.peak_live_bytes.load(.acquire),
            .watchdog_stalls_detected = self.counters.watchdog_stalls_detected.load(.acquire),
            .overflow_spawns = self.counters.overflow_spawns.load(.acquire),
            .overflow_retires = self.counters.overflow_retires.load(.acquire),
            .overflow_active = self.counters.overflow_active.load(.acquire),
            .accounting_skew_detected = skew,
            .task_wait_ns = merged_wait.summary(),
            .task_exec_ns = merged_exec.summary(),
            .default_wait_ns = if (per_lane_active) merged_default_wait.summary() else .{},
            .default_exec_ns = if (per_lane_active) merged_default_exec.summary() else .{},
            .blocking_wait_ns = if (per_lane_active) merged_blocking_wait.summary() else .{},
            .blocking_exec_ns = if (per_lane_active) merged_blocking_exec.summary() else .{},
            .wake_latency_ns = merged_wake.summary(),
            // OBSERVABILITY-PIVOT / R-10: mirrors `live_bytes`; see the
            // field doc on `Stats.memory_budget_used_bytes`.
            .memory_budget_used_bytes = self.counters.live_bytes.load(.acquire),
            .memory = memory,
            .worker_stats = self.worker_stats_buffer,
        };
    }

    pub fn purgeWorkerCaches(self: *Core) !void {
        if (self.counters.active_tasks.load(.acquire) != 0) return error.PoolBusy;
        if (self.totalQueuedTasks() != 0) return error.PoolBusy;
        for (self.workers) |*worker| {
            worker.scratch.purge();
        }
    }

    fn submitInternal(self: *Core, task_fn: TaskFn, ctx: *anyopaque, options: types.SubmitOptions, allow_block: bool) !types.TaskHandle {
        const effective = self.effectiveBackpressure(options);
        const deadline = if (allow_block and effective == .block_with_timeout and options.timeout_ns != null)
            nowNs() + options.timeout_ns.?
        else
            0;

        while (true) {
            if (self.state.load(.acquire) != .running) return error.ShutdownInProgress;
            if (self.enqueueTask(task_fn, ctx, options)) |handle| {
                return handle;
            } else |err| switch (err) {
                error.QueueFull, error.TaskPoolExhausted => {
                    if (!allow_block or effective == .return_error) return err;
                    if (deadline != 0 and nowNs() >= deadline) return error.Timeout;
                    self.waitForCapacity(deadline, options.lane);
                },
                else => return err,
            }
        }
    }

    fn enqueueTask(self: *Core, task_fn: TaskFn, ctx: *anyopaque, options: types.SubmitOptions) !types.TaskHandle {
        const handle = try self.enqueuePush(task_fn, ctx, options);

        // Always update counters so the SC park handshake sees queued work.
        const prev_submitted = self.counters.submitted.fetchAdd(1, .monotonic);
        const lane_counter = self.queuedTasksCounter(options.lane);
        const queue_depth = lane_counter.fetchAdd(1, .seq_cst) +% 1;
        updatePeak(&self.counters.queue_depth_peak, queue_depth);

        // Coalesce wake scans: only do the expensive worker scan + futex
        // signal every `wake_coalesce_batch` submits. Between flushes, parked
        // workers that attempt to re-park bail immediately via the SC
        // queued_tasks handshake (they see > 0 and return without sleeping).
        // Using the pool-wide submitted counter avoids TLS state that leaks
        // across pool lifetimes. The first submit (prev_submitted=0) always
        // wakes to ensure at least one worker is active.
        const batch: u64 = self.config.wake_coalesce_batch;
        if (batch <= 1 or prev_submitted % batch == 0) {
            self.scanAndWake(options.lane);
        }

        return handle;
    }

    /// Per-task push path without the submitter-side notify atomics.
    /// Callers are responsible for calling `notifySubmits(n, lane)` with the
    /// number of successful pushes (single `notifySubmits(1, lane)` for plain
    /// `submit`, batched `notifySubmits(count, lane)` for `submitBatch`).
    ///
    /// Lane routing rules (Slice L1):
    /// - `.lane = .blocking` with `!allow_blocking_lane` → `error.BlockingLaneDisabled`
    /// - `.lane = .blocking` with `blocking_workers > 0` → blocking-lane inject queue;
    ///   never routed through LIFO slot or local queues.
    /// - `.lane = .blocking` with `blocking_workers == 0` → falls back to default
    ///   inject queue (user opted in via allow_blocking_lane but reserved no workers).
    /// - `.lane = .default` with TLS submitter being a blocking worker → skips
    ///   LIFO/local path (a blocking worker's caches must not hold default-lane work);
    ///   goes straight to the default inject queue.
    fn enqueuePush(self: *Core, task_fn: TaskFn, ctx: *anyopaque, options: types.SubmitOptions) !types.TaskHandle {
        if (options.lane == .blocking and !self.config.allow_blocking_lane) {
            return error.BlockingLaneDisabled;
        }

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
        errdefer self.releaseDescriptor(descriptor_index);

        if (options.wait_group) |wait_group| {
            wait_group.add(1);
        }

        const descriptor = &self.descriptors[descriptor_index];
        descriptor.task_fn = task_fn;
        descriptor.ctx = ctx;
        descriptor.options = options;
        descriptor.submit_ns = if (timestampsEnabled(self)) nowNs() else 0;
        descriptor.start_ns = 0;
        descriptor.complete_ns = 0;
        descriptor.state.store(.queued, .release);

        const entry = packEntry(descriptor_index, descriptor.generation);
        var queued = false;

        if (options.lane == .blocking) {
            // Blocking-lane submit: go directly to the blocking inject queue.
            // Config.validate enforces allow_blocking_lane → blocking_workers > 0,
            // so blocking_inject is non-null under normal operation.
            if (self.blocking_inject) |*bi| {
                queued = bi.tryPush(entry);
            } else {
                // Defense-in-depth: Config.validate + allow_blocking_lane gate
                // above should make this branch unreachable. Falling back to
                // the default inject queue preserves forward progress if the
                // invariant is ever broken by a future refactor, instead of
                // becoming ReleaseFast UB (F-006).
                //
                // Note: on this fallback path the task executes on a default
                // worker instead of a blocking worker — lane isolation is
                // violated. Acceptable only as a last-resort safety net; the
                // invariant that would make this branch reachable is itself
                // the real bug to fix.
                queued = self.inject_queue.tryPush(entry);
            }
        } else {
            // Default-lane submit: LIFO/local fast path, gated on TLS worker
            // being a default-lane worker. work_stealing and lane_extension
            // both use per-worker queues; global_queue skips them.
            // COMPTIME-ELISION: when -Dscheduler-variant pins the variant at
            // build time, usesLocalQueues folds to a constant and this entire
            // block drops out of the global_queue-pinned binary.
            const uses_local = usesLocalQueues(self);
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
            // Submitter-queue push is gated on `uses_local` because
            // `tryDrainLaneForWorker` only consumes submitter_queues on the
            // work-stealing / lane-extension path (line 1711-ish). With
            // global_queue, workers pop straight from `lane_inject`, so
            // anything landing in `submitter_queues` would sit there forever
            // and deadlock callers waiting on the push with
            // `backpressure = .block`. Keeping the drain and submit sides
            // symmetric makes `registerSubmitter` a no-op under global_queue.
            if (uses_local and !queued) {
                if (self.tlsSubmitterIndexFor()) |si| {
                    queued = self.submitter_queues[si].tryPushBottom(entry);
                }
            }
            if (!queued) {
                queued = self.inject_queue.tryPush(entry);
            }
        }

        if (!queued) {
            if (options.wait_group) |wait_group| wait_group.done();
            return error.QueueFull;
        }

        return if (options.waitable)
            .{
                .index = descriptor_index,
                .generation = descriptor.generation,
                .waitable = true,
            }
        else
            types.TaskHandle.invalid();
    }

    /// Batched submitter-side notify: bumps `counters.submitted` and the
    /// lane's `queued_tasks*` counter by `count` (single seq_cst fetchAdd
    /// for the park handshake), then wakes at most one parked worker that
    /// serves `lane`.
    ///
    /// Must be called after `enqueuePush` has succeeded `count` times for
    /// the same lane since the last notify. A single seq_cst fetchAdd(count)
    /// carries the same SC total-order guarantee as `count` individual
    /// fetchAdds — a parking worker's SC load of the lane counter either
    /// observes the bumped value (and bails out of park) or precedes it,
    /// and the `is_parked` SC pair excludes IRIW regardless of batch size.
    ///
    /// Lane scope: when `blocking_workers == 0` the wake scan covers all
    /// workers (byte-for-byte identical to the pre-lane-extension path —
    /// A/B regression gate). When `blocking_workers > 0` the scan covers
    /// only workers in `lane`'s range, avoiding cross-lane wakeups that
    /// would spin-loop through `nextTask` and re-park immediately.
    ///
    /// Waking exactly one worker per notify — not `count` — matches the
    /// single-submit path and avoids a thundering-herd on the inject queue's
    /// head cacheline. Measured: a wake-up-to-`count` variant regressed
    /// flood_1m_batched throughput ~50% vs this wake-one variant.
    fn notifySubmits(self: *Core, count: u64, lane: types.TaskLane) void {
        if (count == 0) return;
        _ = self.counters.submitted.fetchAdd(count, .monotonic);
        const lane_counter = self.queuedTasksCounter(lane);
        const queue_depth = lane_counter.fetchAdd(count, .seq_cst) +% count;
        updatePeak(&self.counters.queue_depth_peak, queue_depth);
        self.scanAndWake(lane);
    }

    /// Scan workers in `lane` for one parked worker and signal it.
    /// Extracted from notifySubmits so enqueueTask can call it
    /// independently after coalesced counter updates.
    fn scanAndWake(self: *Core, lane: types.TaskLane) void {
        const nb: usize = self.config.blocking_workers;
        const scan_start: usize = if (lane == .blocking) 0 else nb;
        const scan_end: usize = if (lane == .blocking) nb else self.workers.len;
        const scan_len = scan_end - scan_start;
        if (scan_len == 0) return;

        const submitted = self.counters.submitted.load(.monotonic);
        const rel_hint: usize = @intCast(submitted % scan_len);
        var off: usize = 0;
        while (off < scan_len) : (off += 1) {
            const idx = scan_start + ((rel_hint + off) % scan_len);
            const w = &self.workers[idx];
            if (w.is_parked.load(.seq_cst) == 1) {
                w.park_mutex.lock();
                if (w.is_parked.load(.monotonic) == 1) {
                    w.park_cond.signal();
                }
                w.park_mutex.unlock();
                break;
            }
        }
    }

    /// Slice L4 — watchdog main loop. Wakes every `watchdog_interval_ns`,
    /// walks default-lane workers [nb..max_threads), and increments
    /// `counters.watchdog_stalls_detected` for each worker whose current task
    /// has been running longer than `blocking_promotion_timeout_ns`. When
    /// stalls are detected, spawns up to one overflow worker per tick via
    /// `maybeSpawnOverflow`. Exits when `watchdog_stop` is set by
    /// `joinAllWorkers`.
    fn watchdogMain(self: *Core) void {
        const interval_ns = self.config.watchdog_interval_ns;
        const timeout_ns = self.config.blocking_promotion_timeout_ns;
        const nb: usize = self.config.blocking_workers;
        while (!self.watchdog_stop.load(.acquire)) {
            clock.sleep(interval_ns);
            if (self.watchdog_stop.load(.acquire)) break;

            self.reapRetiredOverflow();

            const now = nowNs();
            var stalls_this_tick: u32 = 0;
            var idx: usize = nb;
            while (idx < self.config.max_threads) : (idx += 1) {
                const started = self.workers[idx].current_task_started_ns.load(.acquire);
                if (started == 0) continue;
                if (now <= started) continue;
                if (now - started > timeout_ns) {
                    _ = self.counters.watchdog_stalls_detected.fetchAdd(1, .monotonic);
                    stalls_this_tick += 1;
                }
            }

            if (stalls_this_tick > 0) {
                self.maybeSpawnOverflow();
            }
        }
    }

    fn reapRetiredOverflow(self: *Core) void {
        const max_overflow = self.config.max_overflow_workers;
        if (max_overflow == 0) return;
        const overflow_start = self.config.max_threads;
        const overflow_end = overflow_start + max_overflow;
        var idx: usize = overflow_start;
        while (idx < overflow_end) : (idx += 1) {
            var worker = &self.workers[idx];
            if (worker.overflow_retired.load(.acquire) and worker.thread != null) {
                worker.thread.?.join();
                worker.thread = null;
                worker.overflow_retired.store(false, .release);
                _ = self.counters.overflow_retires.fetchAdd(1, .monotonic);
                _ = self.counters.overflow_active.fetchSub(1, .monotonic);
            }
        }
    }

    fn maybeSpawnOverflow(self: *Core) void {
        const max_overflow = self.config.max_overflow_workers;
        if (max_overflow == 0) return;
        const overflow_start = self.config.max_threads;
        const overflow_end = overflow_start + max_overflow;
        var idx: usize = overflow_start;
        while (idx < overflow_end) : (idx += 1) {
            var worker = &self.workers[idx];
            if (worker.thread == null) {
                worker.thread = std.Thread.spawn(.{}, overflowWorkerMain, .{ self, idx }) catch return;
                _ = self.counters.overflow_spawns.fetchAdd(1, .monotonic);
                _ = self.counters.overflow_active.fetchAdd(1, .monotonic);
                return;
            }
        }
    }

    fn overflowWorkerMain(self: *Core, worker_index: usize) void {
        tls_worker_slot = .{ .pool = @as(*anyopaque, @ptrCast(self)), .index = worker_index };
        defer tls_worker_slot = .{};
        const idle_retire_ns: u64 = self.config.watchdog_interval_ns * 2;
        var idle_since: u64 = 0;

        while (true) {
            if (self.shouldExit()) break;

            const maybe_entry = self.nextTask(worker_index);
            if (maybe_entry == null) {
                const now = nowNs();
                if (idle_since == 0) {
                    idle_since = now;
                } else if (now - idle_since > idle_retire_ns) {
                    break;
                }
                self.idle(worker_index);
                continue;
            }

            idle_since = 0;
            self.runTask(worker_index, maybe_entry.?);
        }

        self.workers[worker_index].overflow_retired.store(true, .release);
    }

    fn workerMain(self: *Core, worker_index: usize) void {
        tls_worker_slot = .{ .pool = @as(*anyopaque, @ptrCast(self)), .index = worker_index };
        defer tls_worker_slot = .{};

        while (true) {
            if (self.shouldExit()) break;

            const maybe_entry = self.nextTask(worker_index);
            if (maybe_entry == null) {
                self.idle(worker_index);
                continue;
            }

            self.runTask(worker_index, maybe_entry.?);
        }
    }

    /// Returns the TLS worker index only when it belongs to this pool and the
    /// index is in-bounds for `self.workers`. Cross-pool submits return null
    /// and fall through to the shared inject queue (F-001).
    ///
    /// Under `-Dsingle-pool`, the pool-identity check is elided as a
    /// comptime no-op: callers guarantee there is only one pool per process,
    /// so any non-null TLS slot must belong to this pool. The null check and
    /// bounds check still run (a non-worker thread has a null slot and must
    /// fall through).
    inline fn tlsWorkerIndexFor(self: *Core) ?usize {
        const slot = tls_worker_slot;
        if (slot.pool == null) return null;
        if (comptime !single_pool_mode) {
            if (slot.pool != @as(*anyopaque, @ptrCast(self))) return null;
        }
        if (slot.index >= self.workers.len) return null;
        return slot.index;
    }

    /// Returns the TLS submitter index only when it belongs to this pool and
    /// the index is in-bounds for `self.submitter_queues`. Cross-pool submits
    /// return null and fall through to the shared inject queue (F-001).
    ///
    /// See `tlsWorkerIndexFor` for the `-Dsingle-pool` elision contract.
    inline fn tlsSubmitterIndexFor(self: *Core) ?usize {
        const slot = tls_submitter_slot;
        if (slot.pool == null) return null;
        if (comptime !single_pool_mode) {
            if (slot.pool != @as(*anyopaque, @ptrCast(self))) return null;
        }
        if (slot.index >= self.submitter_queues.len) return null;
        return slot.index;
    }

    inline fn markWorkerNonEmpty(self: *Core, worker_index: usize) void {
        const bit: u64 = @as(u64, 1) << @intCast(worker_index);
        _ = self.workers_nonempty.fetchOr(bit, .release);
    }

    inline fn markWorkerEmpty(self: *Core, worker_index: usize) void {
        const bit: u64 = @as(u64, 1) << @intCast(worker_index);
        _ = self.workers_nonempty.fetchAnd(~bit, .release);
    }

    fn nextTask(self: *Core, worker_index: usize) ?QueueEntry {
        var worker = &self.workers[worker_index];
        var lq = &self.local_queues[worker_index];

        // Phase H (Task 4b): decrementQueued() is NOT called here. It moved to
        // runTask's CAS-success path so that a ghost duplicate index emitted
        // by any queue path (the upstream race tracked in Task 3 diagnosis)
        // does not cause an unbalanced decrement. Without this move, a
        // single duplicate emission causes queued_tasks to go net-negative
        // by 1; at steady state the race churns millions of duplicates and
        // underflows queued_tasks to a huge u64, which deadlocks shutdown
        // (shouldExit requires queued_tasks == 0).
        //
        // Semantics: queued_tasks now counts "items the scheduler believes
        // are still pending execution" across {submitted, not-yet-claimed}
        // PLUS {popped-by-nextTask, not-yet-claimed-by-runTask-CAS}. Park
        // handshake and shutdown's drain loop both still see 0 iff every
        // submitted item has been claimed (real) or discarded (duplicate).
        //
        // Lane routing (Slice L1): the own-lane inject queue is drained first,
        // with steal victims restricted to same-lane workers via `laneMask`.
        // Slice L3 adds optional cross-lane fallback: an idle blocking worker
        // helps the default lane (always on — purely additive capacity with no
        // isolation concern), and a default worker can help the blocking lane
        // when `cpu_helps_blocking` is opted in.
        // COMPTIME-ELISION: folds to `true` when -Dscheduler-variant pins
        // work_stealing/lane_extension; folds to `false` for global_queue
        // and the LIFO/local-queue drain block is dropped from the binary.
        const uses_local = usesLocalQueues(self);
        if (uses_local) {
            // LIFO slot first: owner-only swap-to-empty. Most-recently-submitted
            // task runs next. This is the hot path for "task spawns task".
            const cached = worker.lifo_slot.swap(LIFO_SLOT_EMPTY, .acquire);
            if (cached != LIFO_SLOT_EMPTY) {
                return cached;
            }

            if (lq.popBottom()) |entry| {
                if (worker.owned_queue_len > 0) worker.owned_queue_len -= 1;
                if (worker.owned_queue_len == 0) self.markWorkerEmpty(worker_index);
                return entry;
            }
            // popBottom returned null: real queue is empty regardless of
            // owned_queue_len (stealers may have drained). Reconcile.
            if (worker.owned_queue_len != 0) {
                worker.owned_queue_len = 0;
                self.markWorkerEmpty(worker_index);
            }
        }

        // Try the worker's own lane first (L1 behavior).
        if (self.tryDrainLaneForWorker(worker, worker_index, lq, worker.serves_lane, uses_local)) |entry| {
            return entry;
        }

        // L3: cross-lane fallback when own lane is empty. Always recomputed
        // per nextTask call — "returns to own lane as soon as new own-lane
        // work arrives" semantic falls out of the always-try-own-lane-first
        // ordering above. No sticky cross-lane affinity.
        if (self.rebalanceLane(worker.serves_lane)) |other_lane| {
            if (self.tryDrainLaneForWorker(worker, worker_index, lq, other_lane, uses_local)) |entry| {
                return entry;
            }
        }

        if (uses_local) {
            _ = worker.steal_failures.fetchAdd(1, .release);
        }
        return null;
    }

    /// Returns the lane a worker should try as a fallback when its own lane
    /// has no work, or null if cross-lane rebalancing is not allowed for
    /// this worker. Blocking workers always help the default lane (isolation
    /// is preserved because default-lane steal never targets blocking
    /// workers). Default workers help the blocking lane only under the
    /// explicit `cpu_helps_blocking` opt-in.
    inline fn rebalanceLane(self: *const Core, worker_lane: types.TaskLane) ?types.TaskLane {
        return switch (worker_lane) {
            .blocking => if (self.config.blocking_workers > 0) types.TaskLane.default else null,
            .default => if (self.config.cpu_helps_blocking) types.TaskLane.blocking else null,
        };
    }

    /// Drain one task for `worker` from `lane`'s queues: pop the lane's
    /// inject queue in a batch (spilling into the worker's local deque),
    /// then steal from `lane`'s workers via the non-empty bitmap. Returns
    /// the task to run, or null if `lane` is empty.
    ///
    /// Invariant: overflow from both pop paths goes back into `lane`'s
    /// inject queue, never the other lane's. This keeps cross-lane steal
    /// decisions lossless — a blocking worker rebalancing to the default
    /// lane never contaminates `blocking_inject` with default tasks.
    inline fn tryDrainLaneForWorker(
        self: *Core,
        worker: *Worker,
        worker_index: usize,
        lq: *LocalQueue,
        lane: types.TaskLane,
        uses_local: bool,
    ) ?QueueEntry {
        // If blocking_inject is absent (invariant broken), treat as no work
        // available for this lane rather than trapping on UB (F-006).
        const lane_inject = self.laneInjectQueue(lane) orelse return null;
        const lane_bits = self.laneMask(lane);

        if (!uses_local) {
            // global_queue: no LIFO/local; straight pop.
            return lane_inject.pop();
        }

        {
            var buf: [32]QueueEntry = undefined;
            const cap = @min(self.config.inject_batch_size, buf.len);
            const n = lane_inject.popMany(buf[0..cap]);
            if (n > 0) {
                const first = buf[0];
                const was_empty = worker.owned_queue_len == 0;
                var pushed_count: usize = 0;
                var i: usize = 1;
                while (i < n) : (i += 1) {
                    if (!lq.tryPushBottom(buf[i])) {
                        while (i < n) : (i += 1) {
                            _ = lane_inject.tryPush(buf[i]);
                        }
                        break;
                    }
                    pushed_count += 1;
                }
                if (pushed_count > 0) {
                    worker.owned_queue_len += pushed_count;
                    if (was_empty) self.markWorkerNonEmpty(worker_index);
                }
                updatePeakU32(&worker.local_queue_peak, @intCast(worker.owned_queue_len));
                return first;
            }
        }

        {
            var sub_mask = self.submitter_nonempty.load(.acquire);
            while (sub_mask != 0) {
                const sub_idx: usize = @ctz(sub_mask);
                sub_mask &= sub_mask - 1;
                var stolen: [32]QueueEntry = undefined;
                const budget = @min(self.config.steal_batch_size, stolen.len);
                const n = self.submitter_queues[sub_idx].steal(stolen[0..budget]);
                if (n > 0) {
                    const first = stolen[0];
                    const was_empty = worker.owned_queue_len == 0;
                    var pushed_count: usize = 0;
                    for (stolen[1..n]) |entry| {
                        if (!lq.tryPushBottom(entry)) {
                            _ = lane_inject.tryPush(entry);
                        } else {
                            pushed_count += 1;
                        }
                    }
                    if (pushed_count > 0) {
                        worker.owned_queue_len += pushed_count;
                        if (was_empty) self.markWorkerNonEmpty(worker_index);
                    }
                    updatePeakU32(&worker.local_queue_peak, @intCast(worker.owned_queue_len));
                    return first;
                }
            }
        }

        // Steal-peek bitmap restricted to `lane`'s workers.
        const self_bit: u64 = @as(u64, 1) << @intCast(worker_index);
        var mask = self.workers_nonempty.load(.acquire) & lane_bits & ~self_bit;
        while (mask != 0) {
            const victim_index: usize = @ctz(mask);
            mask &= mask - 1;
            var stolen: [32]QueueEntry = undefined;
            const budget = @min(self.config.steal_batch_size, stolen.len);
            const n = self.local_queues[victim_index].steal(stolen[0..budget]);
            if (n > 0) {
                const first = stolen[0];
                const was_empty = worker.owned_queue_len == 0;
                var pushed_count: usize = 0;
                for (stolen[1..n]) |entry| {
                    if (!lq.tryPushBottom(entry)) {
                        _ = lane_inject.tryPush(entry);
                    } else {
                        pushed_count += 1;
                    }
                }
                if (pushed_count > 0) {
                    worker.owned_queue_len += pushed_count;
                    if (was_empty) self.markWorkerNonEmpty(worker_index);
                }
                _ = worker.steals.fetchAdd(n, .release);
                updatePeakU32(&worker.local_queue_peak, @intCast(worker.owned_queue_len));
                return first;
            }
        }

        return null;
    }

    /// Returns the inject queue this worker should drain based on its lane.
    /// When `blocking_workers == 0`, all workers are `.default` and this
    /// always returns `&inject_queue` — no change vs pre-L1.
    /// Returns null for `.blocking` if `blocking_inject` is absent — callers
    /// treat null as "no work available on this lane" (F-006).
    inline fn laneInjectQueue(self: *Core, lane: types.TaskLane) ?*BoundedRing(QueueEntry) {
        return switch (lane) {
            .default => &self.inject_queue,
            // Returns null if the blocking lane is disabled — Config.validate
            // should prevent this in production, but we keep the fallback to
            // avoid ReleaseFast UB if the invariant breaks (F-006).
            .blocking => if (self.blocking_inject) |*bi| bi else null,
        };
    }

    /// Execute a single dequeued task on `worker_index`.
    ///
    /// REV-001 — Task panic contract.  Between the `active_tasks.fetchAdd`
    /// at the top of this function and the matching `fetchSub` near the
    /// bottom, `task_fn` is invoked with the caller's context.  Zig panics
    /// are non-catchable by design, so a panicking task aborts the
    /// process — which is the intended behaviour for a production pool.
    /// The narrow "survives-a-panic" case requires a custom process-wide
    /// panic handler and is explicitly out of scope; on that path the
    /// following state would be left skewed:
    ///   - `counters.active_tasks` (incremented, never decremented)
    ///   - `descriptor.claimed_by` (set, never cleared)
    ///   - `descriptor.state` (`.running`, never advanced to `.completed`)
    ///   - `WaitGroup.pending` (never decremented)
    /// `Core.statsSnapshot` surfaces this as `accounting_skew_detected`
    /// for operators whose runtime is still alive post-panic.  See
    /// `docs/security/REV-001.md` for the full contract.
    fn runTask(self: *Core, worker_index: usize, entry: QueueEntry) void {
        const worker = &self.workers[worker_index];
        const descriptor_index = entryIndex(entry);
        const entry_gen = entryGen(entry);
        const descriptor = &self.descriptors[descriptor_index];

        // --- QS-003 gating phase (preserved verbatim) ---
        //
        // Stale-entry filter and the state CAS MUST remain here, before the
        // decomposed helpers run. Gen-tagged queue entries rely on the filter
        // to reject recycled slots; the state CAS is the single point at
        // which exactly one worker wins this dispatch.
        //
        // Stale-entry filter — see `QueueEntry` doc. Reject entries whose
        // generation tag predates the descriptor's current generation, so
        // a recycled slot cannot be double-dispatched through the state CAS.
        if (@as(u32, @truncate(descriptor.generation)) != entry_gen) {
            return;
        }

        // Phase H fix: atomically transition .queued → .running. Any other
        // state means the descriptor was already claimed, already completed,
        // or has been recycled — drop this dispatch. This closes the wide-
        // overlap race where a duplicate descriptor_index emitted by a queue
        // path arrives after the first claimant already ran and released.
        // The CAS failure branch is a silent skip — duplicate emissions are
        // not an error in this layer; the upstream queue-path root cause is
        // tracked as residual Phase H work.
        //
        // Task 4b: on a successful CAS we also decrementQueued. nextTask
        // intentionally does NOT decrement (see the big comment there),
        // because a duplicate emission would otherwise unbalance the
        // counter and deadlock shutdown. Ghost duplicates fail this CAS
        // and silently return without decrementing — so queued_tasks stays
        // equal to "submissions minus successful dispatches plus dropped
        // ghosts' original double-count cancellation", i.e. it reaches 0
        // iff every real submission has been dispatched or cancelled.
        if (descriptor.state.cmpxchgStrong(.queued, .running, .acq_rel, .acquire)) |_| {
            return;
        }
        self.decrementQueued(descriptor.options.lane);

        // --- QS-003 decomposition: start / invoke / finalize ---
        //
        // Helpers are `inline` to keep hot-path layout identical. Claim
        // sentinel ordering is load-bearing: record -> invoke -> finalize,
        // with the sentinel cleared in finalizeTask BEFORE the broadcast or
        // release (see runTask's final block below for the ordering reason).
        const start_ns = self.recordTaskStart(worker, descriptor, worker_index, descriptor_index);
        self.invokeTask(worker, descriptor, worker_index);
        self.finalizeTask(worker, descriptor, descriptor_index, start_ns);
    }

    /// QS-003 hot-path helper: claim sentinel + timestamps + increments.
    ///
    /// Runs immediately after the caller has won the `.queued → .running`
    /// CAS. Records:
    ///   1. claim sentinel (debug-safety double-dequeue detector)
    ///   2. `descriptor.start_ns` (and observability: wait histogram, watchdog)
    ///   3. worker.started++, counters.active_tasks++
    ///   4. idle_ns accumulator, if timestamp_mode == .full
    ///
    /// Returns the monotonic `start_ns` used by `finalizeTask`.
    /// Marked `inline` so ReleaseFast lowers this back into `runTask` with
    /// identical instruction selection to the pre-QS-003 monolith.
    inline fn recordTaskStart(
        self: *Core,
        worker: *Worker,
        descriptor: *TaskDescriptor,
        worker_index: usize,
        descriptor_index: u32,
    ) u64 {
        // Task 2 sentinel: catches tight-overlap sibling where two workers
        // both pass the state CAS (shouldn't happen — CAS is serializing —
        // but the sentinel remains as a defense-in-depth assertion).
        if (claim_sentinel_enabled) {
            const wi_i32: i32 = @intCast(worker_index);
            if (descriptor.claimed_by.cmpxchgStrong(-1, wi_i32, .acq_rel, .acquire)) |other| {
                std.debug.panic(
                    "double-dequeue: descriptor {d} claimed by worker {d}, now worker {d} also tried to claim it",
                    .{ descriptor_index, other, wi_i32 },
                );
            }
        }

        // COMPTIME-ELISION: both flags fold to constants when pinned at
        // build time. The if (timestamps_enabled or watchdog_enabled) check
        // drops entirely when -Dtimestamp-mode=disabled and watchdog is
        // runtime-off.
        const timestamps_enabled = timestampsEnabled(self);
        const watchdog_enabled = self.config.watchdog_interval_ns > 0;
        const start_ns = if (timestamps_enabled or watchdog_enabled) nowNs() else 0;
        descriptor.start_ns = start_ns;

        if (timestamps_enabled) {
            const wait_ns = start_ns - descriptor.submit_ns;
            worker.wait_histogram.observe(wait_ns);
        }

        if (watchdog_enabled) {
            worker.current_task_started_ns.store(start_ns, .release);
        }

        _ = worker.started.fetchAdd(1, .monotonic);
        _ = self.counters.active_tasks.fetchAdd(1, .monotonic);

        if (timestamps_enabled) {
            const idle_started_ns = worker.last_idle_started_ns.load(.acquire);
            if (idle_started_ns != 0 and start_ns >= idle_started_ns) {
                _ = worker.idle_ns.fetchAdd(start_ns - idle_started_ns, .release);
            }
        }

        return start_ns;
    }

    /// QS-003 hot-path helper: user code invocation + scratch bookkeeping.
    ///
    /// Builds the `TaskContext`, checks cancellation, and either runs the
    /// user's `task_fn` bracketed by `scratch.beginTask/finishTask`, or
    /// marks the descriptor cancelled without running user code.
    ///
    /// Contract: `descriptor.task_fn` and `descriptor.ctx` are guaranteed
    /// non-null by the submit path; the `.?` deref is load-bearing here and
    /// must not be changed to an `orelse` fallback.
    inline fn invokeTask(
        self: *Core,
        worker: *Worker,
        descriptor: *TaskDescriptor,
        worker_index: usize,
    ) void {
        var runtime = TaskContext{
            .worker_index = worker_index,
            .cancellation_token = descriptor.options.cancellation_token,
            .scratch = &worker.scratch,
            .lane = descriptor.options.lane,
        };

        const cancelled = if (descriptor.options.cancellation_token) |token| token.isCancelled() else false;
        if (!cancelled) {
            worker.scratch.beginTask() catch {
                _ = worker.scratch_init_failures.fetchAdd(1, .release);
            };
            descriptor.task_fn.?(descriptor.ctx.?, &runtime);
            worker.scratch.finishTask();
        } else {
            descriptor.state.store(.cancelled, .release);
            _ = self.counters.cancelled.fetchAdd(1, .monotonic);
        }
    }

    /// QS-003 hot-path helper: post-task bookkeeping + release/broadcast.
    ///
    /// Ordering (load-bearing):
    ///   1. `complete_ns = nowNs()` — always, so `idle()`'s purge timer is
    ///      correct regardless of `timestamp_mode`.
    ///   2. `last_idle_started_ns.store` — release so idle() readers see it.
    ///   3. `current_task_started_ns.store(0)` when watchdog is enabled.
    ///   4. exec histogram + busy_ns under `timestamp_mode == .full`.
    ///   5. `active_tasks.fetchSub` BEFORE state.store(.completed) — an
    ///      observer waking on `.completed` must see active_tasks already
    ///      decremented, otherwise `shutdown(.drain, …)` can spin.
    ///   6. Claim sentinel cleared BEFORE broadcast/release — otherwise a
    ///      fast-waking observer could re-acquire the descriptor before we
    ///      release the sentinel and trip the double-dequeue panic.
    ///   7. Waitable descriptors broadcast; non-waitable release to freelist.
    inline fn finalizeTask(
        self: *Core,
        worker: *Worker,
        descriptor: *TaskDescriptor,
        descriptor_index: u32,
        start_ns: u64,
    ) void {
        // COMPTIME-ELISION: `timestamps_enabled` folds to a constant when
        // pinned at build time; the exec_histogram observe and busy_ns
        // fetchAdd drop from the binary under -Dtimestamp-mode=disabled.
        const timestamps_enabled = timestampsEnabled(self);
        const watchdog_enabled = self.config.watchdog_interval_ns > 0;

        // Always update last_idle_started_ns so the idle-purge logic in idle() works
        // regardless of timestamp_mode. Read the clock once.
        const complete_ns = nowNs();
        worker.last_idle_started_ns.store(complete_ns, .release);
        if (watchdog_enabled) {
            worker.current_task_started_ns.store(0, .release);
        }

        if (timestamps_enabled) {
            descriptor.complete_ns = complete_ns;
            const exec_ns = complete_ns - start_ns;
            _ = worker.busy_ns.fetchAdd(exec_ns, .release);
            worker.exec_histogram.observe(exec_ns);
        }

        _ = self.counters.active_tasks.fetchSub(1, .monotonic);
        if (descriptor.state.load(.acquire) != .cancelled) {
            descriptor.state.store(.completed, .release);
            _ = worker.completed.fetchAdd(1, .monotonic);
        }

        if (descriptor.options.wait_group) |wait_group| {
            wait_group.done();
        }

        // Clear the claim sentinel before wait_group.done() observers can
        // re-submit / re-acquire this descriptor slot. Paired with the
        // CAS-acquire at the top of runTask.
        if (claim_sentinel_enabled) {
            descriptor.claimed_by.store(-1, .release);
        }

        if (descriptor.options.waitable) {
            self.sync.completion_mutex.lock();
            self.sync.completion_cond.broadcast();
            self.sync.completion_mutex.unlock();
        } else {
            self.releaseDescriptor(descriptor_index);
        }
    }

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

        if (self.state.load(.acquire) != .running) return;

        _ = worker.parks.fetchAdd(1, .release);

        worker.park_mutex.lock();
        // SC total-order handshake:
        //   submitter:  push → queued_tasks.fetchAdd(.seq_cst) → is_parked.load(.seq_cst)
        //   worker:     is_parked.store(.seq_cst) → queued_tasks.load(.seq_cst) → wait
        // Both cross-variable pairs are SC, so either the submitter observes
        // is_parked == 1 (and signals us) OR our queued_tasks load sees the
        // submitter's increment. IRIW is excluded. No lost wakeup.
        //
        // Note: queued_tasks.fetchAdd on the submit path MUST be .seq_cst (not
        // .release). Release stores only create HB with SC loads when the load
        // reads that store's specific value — if the SC load observes an earlier
        // value, no HB edge forms and the IRIW scenario is permitted.
        worker.is_parked.store(1, .seq_cst);
        const lane_counter = self.queuedTasksCounter(worker.serves_lane);
        if (lane_counter.load(.seq_cst) != 0 or self.state.load(.acquire) != .running) {
            worker.is_parked.store(0, .release);
            worker.park_mutex.unlock();
            _ = worker.wakeups.fetchAdd(1, .release);
            return;
        }
        // OBSERVABILITY-PIVOT / R-03: capture `parked_at_ns` before the
        // timedWait so we can measure wake latency on return. We only
        // observe when timestamps are enabled to preserve the
        // zero-overhead path under `-Dtimestamp-mode=disabled`.
        const timestamps_enabled_idle = timestampsEnabled(self);
        const parked_at_ns: u64 = if (timestamps_enabled_idle) nowNs() else 0;
        worker.park_cond.timedWait(&worker.park_mutex, self.config.idle_park_after_ns) catch {};
        worker.is_parked.store(0, .release);
        worker.park_mutex.unlock();
        _ = worker.wakeups.fetchAdd(1, .release);

        if (timestamps_enabled_idle) {
            // Only observe wake latency when timedWait returned before the
            // idle-park timeout fired (i.e. a submitter signaled us). A
            // return triggered by the timeout means "no work arrived" —
            // that latency is bounded by the config, not scheduling, and
            // would skew the tail of the histogram if included.
            const now = nowNs();
            if (now > parked_at_ns) {
                const delta_ns = now - parked_at_ns;
                if (delta_ns < self.config.idle_park_after_ns) {
                    worker.wake_histogram.observe(delta_ns);
                }
            }
        }

        if (self.config.worker_scratch_cap_bytes != 0 and self.config.idle_purge_after_ns != 0) {
            const now = nowNs();
            if (now - worker.last_idle_started_ns.load(.acquire) >= self.config.idle_purge_after_ns) {
                worker.scratch.purge();
            }
        }
    }

    fn shouldExit(self: *Core) bool {
        const state = self.state.load(.acquire);
        if (state == .running) return false;
        return self.totalQueuedTasks() == 0 and self.counters.active_tasks.load(.acquire) == 0;
    }

    fn cancelQueuedTasks(self: *Core) !void {
        // Task 4b: no decrementQueued here — it moved into cancelDescriptor's
        // CAS-success path. Matches the nextTask/runTask split so a ghost
        // duplicate index popped during cancellation drains doesn't
        // double-decrement (which would underflow queued_tasks and
        // deadlock shouldExit).
        while (self.inject_queue.pop()) |entry| {
            self.cancelDescriptor(entry);
        }
        if (self.blocking_inject) |*bi| {
            while (bi.pop()) |entry| {
                self.cancelDescriptor(entry);
            }
        }
        const uses_local = usesLocalQueues(self);
        if (uses_local) {
            // Drain LIFO slots too.
            for (self.workers) |*w| {
                const cached = w.lifo_slot.swap(LIFO_SLOT_EMPTY, .acquire);
                if (cached != LIFO_SLOT_EMPTY) {
                    self.cancelDescriptor(cached);
                }
            }
            for (self.local_queues) |*lq| {
                while (lq.stealOne()) |entry| {
                    self.cancelDescriptor(entry);
                }
            }
        }
    }

    fn cancelDescriptor(self: *Core, entry: QueueEntry) void {
        const descriptor_index = entryIndex(entry);
        const entry_gen = entryGen(entry);
        const descriptor = &self.descriptors[descriptor_index];
        // Stale-entry filter (matches runTask): entry predates current
        // generation → silently drop without decrementing.
        if (@as(u32, @truncate(descriptor.generation)) != entry_gen) {
            return;
        }
        // Gate with the same state CAS pattern runTask uses. A duplicate
        // index emitted by a queue path will find state != .queued (already
        // cancelled, running, completed, or free) and silently return.
        // Only the first valid cancellation decrements queued_tasks.
        if (descriptor.state.cmpxchgStrong(.queued, .cancelled, .acq_rel, .acquire)) |_| {
            return;
        }
        self.decrementQueued(descriptor.options.lane);
        if (claim_sentinel_enabled) {
            descriptor.claimed_by.store(-1, .release);
        }
        _ = self.counters.cancelled.fetchAdd(1, .monotonic);
        if (descriptor.options.wait_group) |wait_group| wait_group.done();
        // Only broadcast for waitable tasks (matches runTask pattern)
        if (descriptor.options.waitable) {
            self.sync.completion_mutex.lock();
            self.sync.completion_cond.broadcast();
            self.sync.completion_mutex.unlock();
        } else {
            self.releaseDescriptor(descriptor_index);
        }
    }

    const free_sentinel: u32 = 0xFFFFFFFF;

    fn acquireDescriptor(self: *Core) ?u32 {
        while (true) {
            const tagged = self.free_top_tagged.load(.acquire);
            const head = @as(u32, @truncate(tagged));
            if (head == free_sentinel) return null;
            const aba = @as(u32, @truncate(tagged >> 32));
            const next = self.free_indices[head].load(.monotonic);
            const new_tagged = @as(u64, aba +% 1) << 32 | @as(u64, next);
            if (self.free_top_tagged.cmpxchgWeak(tagged, new_tagged, .acq_rel, .acquire)) |_| {
                continue;
            }
            var descriptor = &self.descriptors[head];
            const prev_generation = descriptor.generation;
            descriptor.* = .{};
            descriptor.generation = prev_generation +% 1;
            if (descriptor.generation == 0) descriptor.generation = 1;
            if (claim_sentinel_enabled) {
                descriptor.claimed_by.store(-1, .release);
            }
            descriptor.state.store(.reserved, .release);
            const live = self.counters.task_desc_live.fetchAdd(1, .monotonic) + 1;
            updatePeak(&self.counters.task_desc_peak, live);
            return head;
        }
    }

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

            var taken: usize = 1;
            var cur: u32 = head;
            out[0] = head;
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

    /// Release a completed or cancelled descriptor back to the freelist.
    ///
    /// SEC-018: uses a CAS on `descriptor.state` to guarantee exactly-once
    /// release semantics. The previous unconditional `.store(.free)` raced
    /// with concurrent `wait()` callers on the same handle — the first
    /// caller would `releaseDescriptor`, a subsequent caller would observe
    /// the slot already `.free` and return `error.InvalidHandle`, and a
    /// third actor (`acquireDescriptor`) could reuse the slot in between,
    /// causing the second `wait()` to silently succeed on an unrelated
    /// task (ABA-style confusion on the reused index/generation pair).
    ///
    /// Post-fix, only the thread whose CAS from `.completed`/`.cancelled`
    /// to `.free` succeeds performs the freelist push and backpressure
    /// signal. Contending threads observe a failed CAS and return without
    /// side effect; their `wait()` call still returns `void` (success) from
    /// the outer site, because the task demonstrably completed.
    ///
    /// Idempotent callers: `runTask` (non-waitable path) and `wait()` may
    /// both reach this function; exactly one of them succeeds its CAS.
    /// `cancelQueuedTasks` and `shutdown` call this after setting state
    /// themselves — they expect the CAS to succeed. `shutdown`'s path
    /// goes through `.cancelled` so it competes with `wait()` the same
    /// way `runTask`'s `.completed` path does.
    fn releaseDescriptor(self: *Core, descriptor_index: u32) void {
        var descriptor = &self.descriptors[descriptor_index];

        // Attempt the terminal transition. Only exactly one caller wins; the
        // others bail out without touching freelist state.
        //
        // `.reserved` / `.queued` are accepted because enqueuePush holds an
        // errdefer that calls releaseDescriptor when a submit fails partway.
        // In those cases no concurrent actor observes the slot — the CAS
        // will succeed on the first attempt. Post-`.running` (i.e. a task
        // that is currently executing), only the worker that set
        // `.completed`/`.cancelled` calls this function via runTask, so the
        // CAS competes only with concurrent `wait()` callers.
        var observed = descriptor.state.load(.acquire);
        while (true) {
            switch (observed) {
                .reserved, .queued, .completed, .cancelled => {},
                .free, .running => return, // another thread already released, or still running
            }
            if (descriptor.state.cmpxchgWeak(observed, .free, .acq_rel, .acquire)) |actual| {
                observed = actual;
                continue;
            }
            break;
        }

        descriptor.task_fn = null;
        descriptor.ctx = null;
        descriptor.options = .{};
        descriptor.submit_ns = 0;
        descriptor.start_ns = 0;
        descriptor.complete_ns = 0;
        _ = self.counters.task_desc_live.fetchSub(1, .monotonic);

        while (true) {
            const tagged = self.free_top_tagged.load(.acquire);
            const head = @as(u32, @truncate(tagged));
            const aba = @as(u32, @truncate(tagged >> 32));
            self.free_indices[descriptor_index].store(head, .monotonic);
            const new_tagged = @as(u64, aba +% 1) << 32 | @as(u64, descriptor_index);
            if (self.free_top_tagged.cmpxchgWeak(tagged, new_tagged, .acq_rel, .acquire)) |_| {
                continue;
            }
            break;
        }

        // Wake one blocked submitter per lane (if any) now that a descriptor
        // is available. Fast-path: skip the mutex entirely when no submitter
        // is blocked on that lane — the common uncontended case. Descriptors
        // are pool-wide, so either lane's waiter can benefit from a release;
        // waking one per lane avoids missed-signal deadlocks without a
        // broadcast thundering-herd.
        if (self.sync.default_backpressure_waiters.load(.monotonic) > 0) {
            self.sync.default_backpressure_mutex.lock();
            self.sync.default_backpressure_cond.signal();
            self.sync.default_backpressure_mutex.unlock();
        }
        if (self.sync.blocking_backpressure_waiters.load(.monotonic) > 0) {
            self.sync.blocking_backpressure_mutex.lock();
            self.sync.blocking_backpressure_cond.signal();
            self.sync.blocking_backpressure_mutex.unlock();
        }
    }

    fn recordOwnedAlloc(self: *Core, bytes: usize) void {
        self.accounting.recordAlloc(bytes);
    }

    fn recordOwnedFree(self: *Core, bytes: usize) void {
        self.accounting.recordFree(bytes);
    }

    /// Drain per-worker DescCaches back to the global freelist. Called from
    /// deinitOwned (after workers are joined) and exposed via the testing
    /// hook so tests can assert task_desc_live == 0 before pool.deinit().
    /// Each index held in a worker cache was counted into task_desc_live by
    /// acquireDescriptorBatch but never consumed by a task; releasing them
    /// here restores the counter to zero for any post-run leak assertions.
    fn drainWorkerDescCaches(self: *Core) void {
        for (self.workers[0..self.init_worker_count]) |*worker| {
            var buf: [DescCache.capacity]u32 = undefined;
            const n = worker.desc_cache.drainAll(&buf);
            var i: usize = 0;
            while (i < n) : (i += 1) self.releaseDescriptor(buf[i]);
        }
    }

    fn deinitOwned(self: *Core) void {
        // Use init_worker_count / init_queue_count / init_submitter_count to
        // bound the cleanup loops: if Core.init fails partway through the
        // worker/queue init loops, the trailing entries are raw allocator memory
        // whose fields are uninitialized garbage. Iterating beyond the init
        // counts would invoke purge() / deinit() on garbage pointers → crash.
        // After a successful init these counts equal the slice lengths, so the
        // hot (non-error) path is unchanged.
        self.drainWorkerDescCaches();
        for (self.workers[0..self.init_worker_count]) |*worker| {
            worker.scratch.purge();
        }
        for (self.local_queues[0..self.init_queue_count]) |*lq| {
            self.recordOwnedFree(lq.capacity() * @sizeOf(u32));
            lq.deinit();
        }
        if (self.submitter_queues.len > 0) {
            for (self.submitter_queues[0..self.init_submitter_count]) |*sq| {
                sq.deinit();
            }
            self.recordOwnedFree(self.submitter_queues.len * @sizeOf(LocalQueue));
            self.allocator.free(self.submitter_queues);
        }
        if (self.desc_caches.len > 0) {
            self.recordOwnedFree(self.desc_caches.len * @sizeOf(DescCache));
            self.allocator.free(self.desc_caches);
        }
        self.inject_queue.deinit();
        if (self.blocking_inject) |*bi| {
            self.recordOwnedFree(bi.capacity() * @sizeOf(u32));
            bi.deinit();
            self.blocking_inject = null;
        }
        self.recordOwnedFree(self.worker_stats_buffer.len * @sizeOf(types.WorkerStats));
        self.allocator.free(self.worker_stats_buffer);
        self.recordOwnedFree(self.free_indices.len * @sizeOf(std.atomic.Value(u32)));
        self.allocator.free(self.free_indices);
        self.recordOwnedFree(self.descriptors.len * @sizeOf(TaskDescriptor));
        self.allocator.free(self.descriptors);
        self.recordOwnedFree(self.local_queues.len * @sizeOf(LocalQueue));
        self.allocator.free(self.local_queues);
        self.recordOwnedFree(self.workers.len * @sizeOf(Worker));
        self.allocator.free(self.workers);
    }

    fn decrementQueued(self: *Core, lane: types.TaskLane) void {
        const counter = self.queuedTasksCounter(lane);
        _ = counter.fetchSub(1, .release);
    }

    /// Returns a pointer to the `queued_tasks` counter for the given lane.
    /// Lane-specific counters exist to avoid a livelock in the park
    /// handshake: a default worker's SC load of its lane's counter must
    /// not see blocking-lane submits, else it unparks spuriously on
    /// cross-lane work and spin-loops.
    inline fn queuedTasksCounter(self: *Core, lane: types.TaskLane) *std.atomic.Value(u64) {
        return switch (lane) {
            .default => &self.counters.queued_tasks,
            .blocking => &self.counters.queued_tasks_blocking,
        };
    }

    /// Sum of queued tasks across both lanes — for shutdown drain, stats
    /// snapshots, and deinit timeout diagnostics. Not used by the park
    /// handshake (which is per-lane for the reason above).
    inline fn totalQueuedTasks(self: *const Core) u64 {
        return self.counters.queued_tasks.load(.acquire) +
            self.counters.queued_tasks_blocking.load(.acquire);
    }

    /// Bitmask of workers serving `lane`. Bits [0..blocking_workers) are
    /// blocking workers; bits [blocking_workers..max_threads) are default.
    /// When `blocking_workers == 0`, all valid worker bits are in `.default`.
    /// Used to restrict steal-scan and wake-scan to same-lane workers.
    inline fn laneMask(self: *const Core, lane: types.TaskLane) u64 {
        const nb = self.config.blocking_workers;
        if (nb == 0) return switch (lane) {
            .default => ~@as(u64, 0),
            .blocking => 0,
        };
        const blocking_mask: u64 = (@as(u64, 1) << @intCast(nb)) - 1;
        return switch (lane) {
            .blocking => blocking_mask,
            .default => ~blocking_mask,
        };
    }
};

/// A bounded, fixed-capacity thread pool with configurable scheduling.
///
/// Supports two scheduler variants behind the same API: `global_queue`
/// (single shared FIFO) and `work_stealing` (per-worker deques with
/// steal-from-peer). All submissions are non-blocking by default; use
/// `SubmitOptions.backpressure` for blocking behavior when the queue is full.
pub const ThreadPool = struct {
    core: *Core,

    /// Create a new thread pool with the given configuration.
    /// Workers are spawned immediately and begin polling for tasks.
    /// The allocator is retained for the pool's lifetime and used for
    /// internal allocations (descriptors, queues, scratch buffers).
    pub fn init(allocator: std.mem.Allocator, config: types.Config) !ThreadPool {
        const core = try allocator.create(Core);
        errdefer allocator.destroy(core);
        try core.init(allocator, config);
        return .{ .core = core };
    }

    /// Shut down the pool and release all resources.
    /// Drains remaining tasks up to `Config.deinit_timeout_ns` (default 30s),
    /// then force-joins worker threads. After this call the pool is unusable.
    pub fn deinit(self: *ThreadPool) void {
        const allocator = self.core.allocator;
        self.core.deinit();
        allocator.destroy(self.core);
        self.* = undefined;
    }

    /// Submit a task without blocking. Returns `error.QueueFull` or
    /// `error.TaskPoolExhausted` immediately if capacity is exhausted,
    /// regardless of the backpressure policy in `options`.
    pub fn trySubmit(self: *ThreadPool, task_fn: TaskFn, ctx: *anyopaque, options: types.SubmitOptions) !types.TaskHandle {
        return self.core.trySubmit(task_fn, ctx, options);
    }

    /// Submit a task, optionally blocking per `options.backpressure`.
    /// Returns a `TaskHandle` that can be passed to `wait()` if
    /// `options.waitable` is true; otherwise returns an invalid handle.
    pub fn submit(self: *ThreadPool, task_fn: TaskFn, ctx: *anyopaque, options: types.SubmitOptions) !types.TaskHandle {
        return self.core.submit(task_fn, ctx, options);
    }

    /// Submit multiple tasks atomically. Returns the count of tasks
    /// successfully enqueued. If the first task fails, the error propagates;
    /// subsequent failures return a partial `SubmitBatchResult`.
    pub fn submitBatch(self: *ThreadPool, tasks: []const BatchTask, options: types.SubmitOptions) !Core.SubmitBatchResult {
        return self.core.submitBatch(tasks, options);
    }

    pub fn registerSubmitter(self: *ThreadPool) !usize {
        return self.core.registerSubmitter();
    }

    pub fn releaseSubmitter(self: *ThreadPool, idx: usize) void {
        self.core.releaseSubmitter(idx);
    }

    /// Block until a waitable task completes or is cancelled.
    /// The task descriptor is released upon return. Passing an invalid
    /// or non-waitable handle returns `error.InvalidHandle`.
    pub fn wait(self: *ThreadPool, handle: types.TaskHandle) !void {
        return self.core.wait(handle);
    }

    /// Return a new `WaitGroup` for coordinating completion of a batch
    /// of tasks. Pass `&wg` via `SubmitOptions.wait_group`, then call
    /// `wg.wait()` to block until all tasks in the group finish.
    pub fn waitGroup(self: *ThreadPool) types.WaitGroup {
        return self.core.waitGroup();
    }

    /// Initiate graceful or immediate shutdown.
    /// `.drain` waits for all queued and active tasks to complete.
    /// `.cancel_pending` cancels queued tasks, then waits for active ones.
    /// Pass a `timeout_ns` to bound the wait; returns `error.Timeout`
    /// if the deadline elapses with tasks still in flight.
    pub fn shutdown(self: *ThreadPool, mode: types.ShutdownMode, timeout_ns: ?u64) !void {
        return self.core.shutdown(mode, timeout_ns);
    }

    /// Capture a point-in-time snapshot of pool statistics including
    /// submission counts, latency histograms, memory usage, and
    /// per-worker metrics. Worker stats are read without synchronization
    /// and may be approximate while tasks are actively running.
    pub fn statsSnapshot(self: *ThreadPool) types.Stats {
        return self.core.statsSnapshot();
    }

    /// Release scratch memory held by idle workers. Returns
    /// `error.PoolBusy` unless the pool is quiescent
    /// (`active_tasks == 0 && queued_tasks == 0`), since purging during
    /// execution or with queued work remaining would corrupt scratch
    /// allocator ownership.
    pub fn purgeWorkerCaches(self: *ThreadPool) !void {
        return self.core.purgeWorkerCaches();
    }

    // Test-only accessors
    /// Test-only accessor. Not part of the public contract.
    pub fn acquireDescriptorBatchForTesting(self: *ThreadPool, out: []u32) usize {
        return self.core.acquireDescriptorBatch(out);
    }

    /// Test-only accessor. Not part of the public contract.
    pub fn releaseDescriptorForTesting(self: *ThreadPool, idx: u32) void {
        self.core.releaseDescriptor(idx);
    }

    /// Test-only accessor. Drains all per-worker DescCaches back to the
    /// global freelist, mirroring the drain that deinitOwned performs. Use
    /// in tests to assert task_desc_live == 0 before pool.deinit() while
    /// the pool is still live and statsSnapshot() can be called. Not part
    /// of the public contract.
    pub fn drainWorkerDescCachesForTesting(self: *ThreadPool) void {
        self.core.drainWorkerDescCaches();
    }

    /// Test-only accessor. Asserts `@sizeOf(Worker)` does not exceed
    /// `ceiling`. Used by unit tests to catch accidental cacheline-
    /// splitting field additions (iter-11 layout discipline). Returns
    /// `error.WorkerSizeExceedsCeiling` on breach so the failure shows
    /// up in the test output instead of tripping the comptime assert.
    /// Not part of the public contract.
    pub fn assertWorkerSizeBoundedForTesting(_: *ThreadPool, comptime ceiling: usize) !void {
        if (@sizeOf(Worker) > ceiling) return error.WorkerSizeExceedsCeiling;
    }
};

fn nowNs() u64 {
    const ts = clock.nanoTimestamp();
    return if (ts < 0) 0 else @as(u64, @intCast(ts));
}

const updatePeak = Accounting.updatePeak;

fn updatePeakU32(counter: *std.atomic.Value(u32), value: u32) void {
    var current = counter.load(.monotonic);
    while (value > current) {
        const previous = counter.cmpxchgWeak(current, value, .monotonic, .monotonic);
        if (previous == null) return;
        current = previous.?;
    }
}
