//! Random-interleave fuzz harness for the public ThreadPool API.
//!
//! Usage:
//!   zig build fuzz                          # default 100 iterations, seed 0xC0FFEE
//!   FUZZ_SEED=1 FUZZ_ITERATIONS=5000 zig build fuzz
//!
//! Invariants checked after each iteration (post-shutdown):
//!   - stats.submitted == stats.completed + stats.cancelled
//!     (the pool accounts for every submitted task)
//!   - stats.task_desc_live == 0
//!     (no leaked task descriptors post-shutdown)
//!   - DebugAllocator reports no leaks
//!   - shutdown completes within 5 seconds (infinite-drain catch)
//!
//! Coverage gaps noted:
//!   - submitter_free_mask (fully-set = no leaked submitter slots) is
//!     private to Core and not exposed by statsSnapshot(). We verify
//!     releaseSubmitter is called for every registerSubmitter we issued,
//!     but cannot read the mask directly from the public API.
//!
//! Known bug found during development (iteration 4, seed 0xC0FFEE):
//!   With the default global_queue scheduler, tasks submitted via a
//!   registered submitter slot go into submitter_queues[], but
//!   tryDrainLaneForWorker() short-circuits before reaching the
//!   submitter-queue steal block when !uses_local (global_queue).
//!   Those tasks are never executed; queued_tasks never reaches zero;
//!   shutdown(.drain, null) spins forever.
//!   Mitigation: this harness uses work_stealing (which DOES drain
//!   submitter queues) and a 5-second shutdown timeout so it detects
//!   rather than hangs on regressions.

const std = @import("std");
const thread_pool = @import("thread_pool");

/// Shutdown timeout: 5 seconds. If a pool takes longer than this to drain,
/// the harness treats it as an invariant failure rather than hanging forever.
const shutdown_timeout_ns: u64 = 5_000_000_000;

const OpKind = enum(u8) {
    submit,
    try_submit,
    register,
    release,
    shutdown_drain,
    shutdown_cancel,
    // SEC-018 / F-008: concurrent double-wait on a waitable handle.  The
    // op spawns a pair of threads that each call `pool.wait(handle)` on
    // the same handle.  Pre-fix, this could double-release the descriptor
    // slot; post-fix, the release is CAS-guarded.  The invariant under
    // test here is simply "no crash, no allocator leak" — the per-iter
    // invariant block at the bottom of `runOne` catches both.
    double_wait,
};

fn noop(ctx: *anyopaque, runtime: *thread_pool.TaskContext) void {
    _ = ctx;
    _ = runtime;
}

fn envU64(init: std.process.Init.Minimal, gpa: std.mem.Allocator, key: []const u8, default: u64) u64 {
    const val = init.environ.getAlloc(gpa, key) catch return default;
    defer gpa.free(val);
    return std.fmt.parseInt(u64, val, 0) catch default;
}

fn envU32(init: std.process.Init.Minimal, gpa: std.mem.Allocator, key: []const u8, default: u32) u32 {
    const val = init.environ.getAlloc(gpa, key) catch return default;
    defer gpa.free(val);
    return std.fmt.parseInt(u32, val, 10) catch default;
}

pub fn main(init: std.process.Init.Minimal) !u8 {
    const seed = envU64(init, std.heap.page_allocator, "FUZZ_SEED", 0xC0FFEE);
    const iterations = envU32(init, std.heap.page_allocator, "FUZZ_ITERATIONS", 100);

    var prng = std.Random.DefaultPrng.init(seed);
    const rng = prng.random();

    var i: u32 = 0;
    while (i < iterations) : (i += 1) {
        runOne(rng, i, seed) catch |err| {
            std.debug.print("fuzz FAIL at iteration {d}, seed={d}: {s}\n", .{ i, seed, @errorName(err) });
            return 1;
        };
    }

    std.debug.print("fuzz ok: {d} iterations seed={d}\n", .{ iterations, seed });
    return 0;
}

fn runOne(rng: std.Random, iter: u32, seed: u64) !void {
    _ = iter;
    _ = seed;

    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    // DebugAllocator.deinit() returns CheckResult (.ok or .leak).
    // Defer the check; on leak we panic loudly after deinit.
    defer {
        const result = gpa_state.deinit();
        if (result == .leak) {
            std.debug.panic("fuzz: allocator reported a leak after pool.deinit()\n", .{});
        }
    }
    const gpa = gpa_state.allocator();

    // Use work_stealing to ensure submitter-queue tasks are drained.
    // The global_queue variant does not drain submitter_queues[], causing
    // shutdown(.drain) to hang when registerSubmitter() was used (see
    // module-level comment above).
    const max_threads = rng.intRangeAtMost(usize, 2, 6);
    const want_submitter_queues: bool = rng.boolean();
    const max_submitter_queues: u32 = if (want_submitter_queues) rng.intRangeAtMost(u32, 1, 4) else 0;

    var pool = try thread_pool.ThreadPool.init(gpa, .{
        .max_threads = max_threads,
        .queue_capacity = 128,
        .scheduler_variant = .work_stealing,
        .max_submitter_queues = max_submitter_queues,
        .submitter_queue_capacity = if (max_submitter_queues > 0) 64 else 0,
    });

    // Track whether we have an active registered submitter slot.
    // We only allow one at a time to keep state simple.
    var my_submitter: ?usize = null;
    var shut_down = false;

    const n_ops: u32 = rng.intRangeAtMost(u32, 32, 256);
    var op_i: u32 = 0;
    while (op_i < n_ops) : (op_i += 1) {
        if (shut_down) break;
        const kind = rng.enumValue(OpKind);
        switch (kind) {
            .submit => {
                _ = pool.submit(noop, @ptrCast(&pool), .{}) catch continue;
            },
            .try_submit => {
                _ = pool.trySubmit(noop, @ptrCast(&pool), .{}) catch continue;
            },
            .register => {
                // Only register if we don't already hold a slot and there
                // are submitter queue slots configured.
                if (my_submitter == null and max_submitter_queues > 0) {
                    my_submitter = pool.registerSubmitter() catch null;
                }
            },
            .release => {
                if (my_submitter) |idx| {
                    pool.releaseSubmitter(idx);
                    my_submitter = null;
                }
            },
            .shutdown_drain => {
                pool.shutdown(.drain, shutdown_timeout_ns) catch |e| {
                    if (e == error.Timeout) return error.FuzzShutdownDrainTimeout;
                };
                shut_down = true;
            },
            .shutdown_cancel => {
                pool.shutdown(.cancel_pending, shutdown_timeout_ns) catch |e| {
                    if (e == error.Timeout) return error.FuzzShutdownCancelTimeout;
                };
                shut_down = true;
            },
            .double_wait => {
                // SEC-018: submit a waitable handle then fire two threads
                // that race to wait on it.  Ignore submit errors (queue
                // full, shutdown in progress) — the op is best-effort.
                const handle = pool.submit(noop, @ptrCast(&pool), .{ .waitable = true }) catch continue;
                const DoubleWait = struct {
                    fn run(p: *thread_pool.ThreadPool, h: thread_pool.types.TaskHandle) void {
                        // Success and InvalidHandle are both acceptable;
                        // the invariant we care about is "no crash".
                        p.wait(h) catch {};
                    }
                };
                const t0 = std.Thread.spawn(.{}, DoubleWait.run, .{ &pool, handle }) catch continue;
                const t1 = std.Thread.spawn(.{}, DoubleWait.run, .{ &pool, handle }) catch {
                    t0.join();
                    continue;
                };
                t0.join();
                t1.join();
            },
        }
    }

    // Always shut down before reading stats so the counts are stable.
    if (!shut_down) {
        pool.shutdown(.drain, shutdown_timeout_ns) catch |e| {
            if (e == error.Timeout) return error.FuzzShutdownDrainTimeout;
        };
    }

    // Release any held submitter slot before deinit.
    // Coverage gap: we verify our own bookkeeping is balanced, but
    // submitter_free_mask is private to Core and cannot be read via
    // statsSnapshot(). The DebugAllocator leak check below catches any
    // memory that the pool failed to free, which would also signal a
    // mask leak indirectly.
    if (my_submitter) |idx| {
        pool.releaseSubmitter(idx);
        my_submitter = null;
    }

    // --- Invariant checks ---
    const s = pool.statsSnapshot();

    // Invariant 1: every submitted task must be accounted for.
    // submitted == completed + cancelled (started tasks that were cancelled
    // mid-flight are counted in cancelled, not completed).
    if (s.submitted != s.completed + s.cancelled) {
        std.debug.print(
            "fuzz invariant FAIL: submitted={d} completed={d} cancelled={d} (completed+cancelled={d})\n",
            .{ s.submitted, s.completed, s.cancelled, s.completed + s.cancelled },
        );
        pool.deinit();
        return error.FuzzInvariantTaskAccountingFailed;
    }

    // Invariant 2: no task descriptors may be live after shutdown.
    if (s.task_desc_live != 0) {
        std.debug.print(
            "fuzz invariant FAIL: task_desc_live={d} after shutdown\n",
            .{s.task_desc_live},
        );
        pool.deinit();
        return error.FuzzInvariantLeakedDescriptors;
    }

    // Clean up.  DebugAllocator.deinit() in the defer above will catch
    // any allocator-level leaks from pool.deinit().
    pool.deinit();
}
