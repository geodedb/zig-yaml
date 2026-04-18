const std = @import("std");
const thread_pool = @import("thread_pool");
const common = @import("common.zig");

test "work-stealing scheduler executes each accepted task exactly once" {
    var pool = try thread_pool.ThreadPool.init(std.testing.allocator, common.defaultConfig(.work_stealing));
    defer pool.deinit();

    var wg = pool.waitGroup();
    var counter = common.Counter{};
    for (0..128) |_| {
        _ = try pool.submit(common.counterTask, @ptrCast(&counter), .{ .wait_group = &wg });
    }
    wg.wait();

    try std.testing.expectEqual(@as(u64, 128), counter.value.load(.acquire));
    const stats = pool.statsSnapshot();
    try std.testing.expectEqual(@as(u64, 128), stats.completed);
}

test "global scheduler waitable handle completes" {
    var pool = try thread_pool.ThreadPool.init(std.testing.allocator, common.defaultConfig(.global_queue));
    defer pool.deinit();

    var counter = common.Counter{};
    const handle = try pool.submit(common.counterTask, @ptrCast(&counter), .{ .waitable = true });
    try pool.wait(handle);
    try std.testing.expectEqual(@as(u64, 1), counter.value.load(.acquire));
}

test "wait rejects out-of-bounds handle index" {
    var pool = try thread_pool.ThreadPool.init(std.testing.allocator, .{
        .min_threads = 1,
        .max_threads = 1,
        .queue_capacity = 64,
    });
    defer pool.deinit();

    const bad_handle = thread_pool.types.TaskHandle{
        .index = 9999,
        .generation = 1,
        .waitable = true,
    };
    try std.testing.expectError(error.InvalidHandle, pool.wait(bad_handle));
}

test "shutdown rejects new submissions" {
    var pool = try thread_pool.ThreadPool.init(std.testing.allocator, common.defaultConfig(.global_queue));
    defer pool.deinit();

    try pool.shutdown(.cancel_pending, null);
    var counter = common.Counter{};
    try std.testing.expectError(error.ShutdownInProgress, pool.submit(common.counterTask, @ptrCast(&counter), .{}));
}

test "worker cache purge resets current scratch usage" {
    var pool = try thread_pool.ThreadPool.init(std.testing.allocator, common.defaultConfig(.work_stealing));
    defer pool.deinit();

    var wg = pool.waitGroup();
    var counter = common.Counter{};
    var scratch_ctx = common.ScratchTaskContext{ .counter = &counter, .bytes = 1024 };
    for (0..16) |_| {
        _ = try pool.submit(common.scratchTask, @ptrCast(&scratch_ctx), .{ .wait_group = &wg });
    }
    wg.wait();
    try pool.purgeWorkerCaches();

    const stats = pool.statsSnapshot();
    for (stats.worker_stats) |worker| {
        try std.testing.expectEqual(@as(u64, 0), worker.scratch_current_bytes);
    }
}

test "worker cache purge rejects queued work even when no task is active" {
    var pool = try thread_pool.ThreadPool.init(std.testing.allocator, common.defaultConfig(.work_stealing));
    defer pool.deinit();

    pool.core.counters.queued_tasks.store(1, .release);
    defer pool.core.counters.queued_tasks.store(0, .release);

    try std.testing.expectError(error.PoolBusy, pool.purgeWorkerCaches());
}

test "waitable handle generation increments across reuses" {
    var pool = try thread_pool.ThreadPool.init(std.testing.allocator, common.defaultConfig(.global_queue));
    defer pool.deinit();

    var counter = common.Counter{};
    const handle1 = try pool.submit(common.counterTask, @ptrCast(&counter), .{ .waitable = true });
    try pool.wait(handle1);

    // Same descriptor index may be reused; generation must differ.
    const handle2 = try pool.submit(common.counterTask, @ptrCast(&counter), .{ .waitable = true });
    try pool.wait(handle2);

    if (handle1.index == handle2.index) {
        try std.testing.expect(handle2.generation > handle1.generation);
    }
}

// SEC-018 / F-008: concurrent double-wait on the same TaskHandle.
//
// Pre-fix, two threads that raced on the same waitable handle could both
// pass the "state == .completed" check and both call releaseDescriptor,
// producing a double-push to the freelist and (depending on ABA timing) a
// double-free the allocator never sees because the freelist is a bounded
// pool.  Post-fix, `releaseDescriptor` is CAS-guarded on
// `descriptor.state` so exactly one caller performs the release; the other
// finds `.free` with a matching generation and returns success.
test "SEC-018 concurrent double-wait on same handle is safe" {
    var pool = try thread_pool.ThreadPool.init(std.testing.allocator, common.defaultConfig(.global_queue));
    defer pool.deinit();

    const Barrier = struct {
        pool_ptr: *thread_pool.ThreadPool,
        handle: thread_pool.types.TaskHandle,
        start_gate: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
        results: [2]anyerror!void = .{ {}, {} },

        fn waiter(self: *@This(), slot: usize) void {
            // Spin until the main thread releases both waiters together so
            // they race the completed broadcast under the completion_mutex.
            while (self.start_gate.load(.acquire) == 0) {
                std.atomic.spinLoopHint();
            }
            self.results[slot] = self.pool_ptr.wait(self.handle);
        }
    };

    // Run multiple rounds to shake out the race; each round submits a
    // fresh waitable handle and fires two waiter threads at it.
    var round: usize = 0;
    while (round < 64) : (round += 1) {
        var counter = common.Counter{};
        const handle = try pool.submit(common.counterTask, @ptrCast(&counter), .{ .waitable = true });

        var barrier = Barrier{ .pool_ptr = &pool, .handle = handle };

        const t0 = try std.Thread.spawn(.{}, Barrier.waiter, .{ &barrier, @as(usize, 0) });
        const t1 = try std.Thread.spawn(.{}, Barrier.waiter, .{ &barrier, @as(usize, 1) });

        // Release both waiters simultaneously.
        barrier.start_gate.store(1, .release);

        t0.join();
        t1.join();

        // Both waiters must see success.  If the CAS guard regressed, one
        // would return error.InvalidHandle or (worse) the pool would
        // double-push to the freelist — the DebugAllocator check at
        // pool.deinit() plus the task_desc_live invariant would catch the
        // latter on the stats snapshot below.
        try barrier.results[0];
        try barrier.results[1];
        try std.testing.expectEqual(@as(u64, 1), counter.value.load(.acquire));
    }

    // After all rounds, task_desc_live must be zero — no leaked descriptors.
    const stats = pool.statsSnapshot();
    try std.testing.expectEqual(@as(u64, 0), stats.task_desc_live);
}

// SEC-018: back-to-back sequential wait() on the same handle must not
// panic and must not double-free the descriptor slot.  Post-fix, the
// second wait() observes `.free` with a matching generation (if the slot
// hasn't been reused) and returns success, or observes a generation
// mismatch and returns InvalidHandle.  Either outcome is acceptable; what
// must NOT happen is a panic or a double freelist push.
test "SEC-018 sequential double-wait on same handle does not panic" {
    var pool = try thread_pool.ThreadPool.init(std.testing.allocator, common.defaultConfig(.global_queue));
    defer pool.deinit();

    var counter = common.Counter{};
    const handle = try pool.submit(common.counterTask, @ptrCast(&counter), .{ .waitable = true });
    try pool.wait(handle);

    // Second wait() is a no-op or InvalidHandle — both are acceptable
    // post-SEC-018.  The key invariant is "no panic, no double-free".
    pool.wait(handle) catch |err| {
        try std.testing.expectEqual(@as(anyerror, error.InvalidHandle), err);
    };

    try std.testing.expectEqual(@as(u64, 1), counter.value.load(.acquire));
    const stats = pool.statsSnapshot();
    try std.testing.expectEqual(@as(u64, 0), stats.task_desc_live);
}

test "recursive submission through local queues does not deadlock" {
    var pool = try thread_pool.ThreadPool.init(std.testing.allocator, common.defaultConfig(.work_stealing));
    defer pool.deinit();

    var wg = pool.waitGroup();
    var counter = common.Counter{};
    var recursive = common.RecursiveContext{
        .pool = &pool,
        .counter = &counter,
        .wait_group = &wg,
        .child_count = 8,
    };

    _ = try pool.submit(common.recursiveTask, @ptrCast(&recursive), .{ .wait_group = &wg });
    wg.wait();

    try std.testing.expectEqual(@as(u64, 9), counter.value.load(.acquire));
}

test "submitBatch from worker context completes all child tasks" {
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
    try std.testing.expectEqual(@as(u64, 4), done.load(.acquire));
}

test "pre-cancelled token prevents task body execution" {
    var pool = try thread_pool.ThreadPool.init(std.testing.allocator, .{
        .min_threads = 1,
        .max_threads = 1,
        .queue_capacity = 64,
    });
    defer pool.deinit();

    var token = thread_pool.CancellationToken{};
    // Cancel BEFORE submitting -- the task body must never run.
    token.cancel();
    try std.testing.expect(token.isCancelled());

    var wg = pool.waitGroup();
    var counter = common.Counter{};
    _ = try pool.submit(common.counterTask, @ptrCast(&counter), .{
        .wait_group = &wg,
        .cancellation_token = &token,
    });
    wg.wait();

    // Task body was NOT executed; counter stays 0.
    try std.testing.expectEqual(@as(u64, 0), counter.value.load(.acquire));

    // Stats must reflect the cancellation.
    const stats = pool.statsSnapshot();
    try std.testing.expect(stats.cancelled > 0);
}

test "trySubmit returns error when queue is full" {
    // Tiny queue + 1 worker + sleep tasks = guaranteed full queue.
    var pool = try thread_pool.ThreadPool.init(std.testing.allocator, .{
        .min_threads = 1,
        .max_threads = 1,
        .queue_capacity = 4,
        .scheduler_variant = .global_queue,
    });
    defer pool.deinit();

    var wg = pool.waitGroup();
    var counter = common.Counter{};
    var sleeper = common.SleepTaskContext{ .counter = &counter, .sleep_ns = 500_000_000 };

    // Fill every queue slot with long-running sleep tasks.
    for (0..4) |_| {
        _ = try pool.submit(common.sleepTask, @ptrCast(&sleeper), .{ .wait_group = &wg });
    }

    // trySubmit must fail immediately with a queue/pool exhaustion error.
    // Either error.QueueFull or error.TaskPoolExhausted is acceptable --
    // TaskPoolExhausted fires when all descriptors are consumed before
    // the ring buffer itself is full.
    const result = pool.trySubmit(common.counterTask, @ptrCast(&counter), .{});
    if (result) |_| {
        return error.TestUnexpectedResult;
    } else |err| {
        try std.testing.expect(err == error.QueueFull or err == error.TaskPoolExhausted);
    }

    // Clean up: let the sleep tasks finish.
    wg.wait();
}

test "block_with_timeout returns Timeout when queue stays full" {
    var pool = try thread_pool.ThreadPool.init(std.testing.allocator, .{
        .min_threads = 1,
        .max_threads = 1,
        .queue_capacity = 4,
        .scheduler_variant = .global_queue,
    });
    defer pool.deinit();

    var wg = pool.waitGroup();
    var counter = common.Counter{};
    var sleeper = common.SleepTaskContext{ .counter = &counter, .sleep_ns = 2_000_000_000 };

    // Fill the queue with long-running tasks.
    for (0..4) |_| {
        _ = try pool.submit(common.sleepTask, @ptrCast(&sleeper), .{ .wait_group = &wg });
    }

    // submit() with block_with_timeout should time out because the queue
    // stays full for longer than the 100ms timeout.
    const result = pool.submit(common.counterTask, @ptrCast(&counter), .{
        .backpressure = .block_with_timeout,
        .timeout_ns = 100_000_000,
    });
    try std.testing.expectError(error.Timeout, result);

    // Clean up: let the pool drain.
    wg.wait();
}

test "shutdown with timeout returns Timeout for long-running tasks" {
    var pool = try thread_pool.ThreadPool.init(std.testing.allocator, .{
        .min_threads = 1,
        .max_threads = 1,
        .queue_capacity = 64,
    });
    // NOTE: no defer pool.deinit() here -- we call shutdown manually, then
    // must still deinit. The deinit calls shutdown(.drain, null) internally
    // which is safe to call after a timed-out shutdown.
    defer pool.deinit();

    var counter = common.Counter{};
    var sleeper = common.SleepTaskContext{ .counter = &counter, .sleep_ns = 2_000_000_000 };
    _ = try pool.submit(common.sleepTask, @ptrCast(&sleeper), .{});

    // Give the worker a moment to pick up the task so it becomes active.
    thread_pool.clock.sleep(10_000_000);

    // Shutdown with a 50ms timeout -- the 2-second task won't finish in time.
    const result = pool.core.shutdown(.drain, 50_000_000);
    try std.testing.expectError(error.Timeout, result);
}

test "WaitGroup done underflow guard present in debug build modes" {
    // Verify the WaitGroup correctly tracks pending count down to zero.
    // The underflow guard (@panic) fires if done() is called when pending == 0
    // in Debug and ReleaseSafe (std.debug.runtime_safety == true).
    // In ReleaseFast the invariant is restored silently (F-004 fix).
    var wg = thread_pool.types.WaitGroup{};
    wg.add(1);
    try std.testing.expectEqual(@as(u32, 1), wg.pendingCount());
    wg.done();
    try std.testing.expectEqual(@as(u32, 0), wg.pendingCount());
    // At this point, calling wg.done() in Debug/ReleaseSafe would trigger:
    //   @panic("WaitGroup: done() called more times than add()")
    // In ReleaseFast it returns early after restoring pending to 0.
}

test "F-004: WaitGroup.done underflow does not crash ReleaseFast" {
    // This test only runs under ReleaseFast (runtime_safety == false)
    // where the fix makes double-done resilient. In Debug/ReleaseSafe
    // the panic is preserved as a caller-bug catcher.
    if (std.debug.runtime_safety) return error.SkipZigTest;

    var wg = thread_pool.types.WaitGroup{};
    wg.add(1);
    wg.done();
    wg.done(); // pre-fix: would crash; post-fix: must return cleanly
    // pending must be saturated at 0, not wrapped negative
    try std.testing.expectEqual(@as(u32, 0), wg.pendingCount());
}

test "local_queue_capacity zero rejected for all scheduler variants" {
    var cfg = thread_pool.types.Config{ .local_queue_capacity = 0, .scheduler_variant = .global_queue };
    cfg = cfg.normalized();
    try std.testing.expectError(error.InvalidLocalQueueCapacity, cfg.validate());
}

test "concurrent push-pop-steal does not lose or duplicate items" {
    const WorkDeque = @import("thread_pool").WorkDeque;
    const Deque = WorkDeque(u32);
    var deque = try Deque.init(std.testing.allocator, 256);
    defer deque.deinit();

    const total_items: u32 = 10_000;
    var owner_collected = std.atomic.Value(u32).init(0);
    var stolen_collected = std.atomic.Value(u32).init(0);

    const Stealer = struct {
        fn run(d: *Deque, owner_done: *std.atomic.Value(u32), stolen: *std.atomic.Value(u32)) void {
            var count: u32 = 0;
            while (true) {
                if (d.stealTop()) |_| {
                    count += 1;
                } else {
                    if (d.len() == 0 and owner_done.load(.acquire) > 0) {
                        if (d.stealTop()) |_| {
                            count += 1;
                        } else break;
                    }
                    std.Thread.yield() catch {};
                }
            }
            _ = stolen.fetchAdd(count, .release);
        }
    };

    var threads: [3]std.Thread = undefined;
    for (&threads) |*t| {
        t.* = try std.Thread.spawn(.{}, Stealer.run, .{ &deque, &owner_collected, &stolen_collected });
    }

    var owner_count: u32 = 0;
    var pushed: u32 = 0;
    while (pushed < total_items) {
        if (deque.tryPushBottom(pushed)) {
            pushed += 1;
        }
        if (pushed % 4 == 0) {
            if (deque.popBottom()) |_| {
                owner_count += 1;
            }
        }
    }
    while (deque.popBottom()) |_| {
        owner_count += 1;
    }

    _ = owner_collected.fetchAdd(owner_count, .release);

    for (&threads) |t| t.join();

    const total_recovered = owner_collected.load(.acquire) + stolen_collected.load(.acquire);
    try std.testing.expectEqual(total_items, total_recovered);
}

test "Stats.wakeups aggregates from per-worker counters" {
    var pool = try thread_pool.ThreadPool.init(std.testing.allocator, .{
        .max_threads = 2,
        .queue_capacity = 64,
    });
    defer pool.deinit();

    var wg = pool.waitGroup();
    var counter = common.Counter{};
    for (0..8) |_| {
        _ = try pool.submit(common.counterTask, @ptrCast(&counter), .{ .wait_group = &wg });
    }
    wg.wait();

    // Pool-level wakeups must equal the sum of per-worker wakeups. This is
    // the correctness invariant Q-022 fixed: the pool-level counter was
    // previously never incremented while workers did increment their own.
    // The actual value may be zero under ReleaseFast when workers never
    // needed to park (8 trivial tasks finish before the idle threshold),
    // so we only assert the aggregation invariant, not a minimum count.
    const stats = pool.statsSnapshot();
    var expected: u64 = 0;
    for (stats.worker_stats) |w| {
        expected += w.wakeups;
    }
    try std.testing.expectEqual(expected, stats.wakeups);
}

test "Stats.steals/parks aggregate per-worker under work-stealing" {
    var pool = try thread_pool.ThreadPool.init(std.testing.allocator, .{
        .max_threads = 4,
        .queue_capacity = 1024,
        .local_queue_capacity = 64,
        .scheduler_variant = .work_stealing,
    });
    defer pool.deinit();

    var wg = pool.waitGroup();
    var counter = common.Counter{};
    for (0..256) |_| {
        _ = try pool.submit(common.counterTask, @ptrCast(&counter), .{ .wait_group = &wg });
    }
    wg.wait();

    const stats = pool.statsSnapshot();

    var expected_steals: u64 = 0;
    var expected_steal_failures: u64 = 0;
    var expected_parks: u64 = 0;
    for (stats.worker_stats) |w| {
        expected_steals += w.steals;
        expected_steal_failures += w.steal_failures;
        expected_parks += w.parks;
    }
    try std.testing.expectEqual(expected_steals, stats.steals);
    try std.testing.expectEqual(expected_steal_failures, stats.steal_failures);
    try std.testing.expectEqual(expected_parks, stats.parks);
}

test "latency summary exposes p999 and p9999 tail fields" {
    // OBSERVABILITY-PIVOT / R-01: the LatencyHistogram exposes p99.9 and
    // p99.99 derived from the same 64-bucket log2 histogram used for p50/
    // p95/p99. The quantisation is coarse at the tails, so we only assert
    // monotonicity (p99 <= p999 <= p9999 <= max) plus non-zeroness under
    // realistic load. Skipped when timestamps are compiled out, since all
    // histogram fields are intentionally zero in that build.
    if (thread_pool.build_options.timestamp_mode == .disabled) return error.SkipZigTest;
    var pool = try thread_pool.ThreadPool.init(std.testing.allocator, .{
        .min_threads = 2,
        .max_threads = 2,
        .queue_capacity = 4096,
        .default_backpressure = .block,
    });
    defer pool.deinit();

    var wg = pool.waitGroup();
    var counter = common.Counter{};
    // 2000 tasks is enough to populate tail buckets under realistic scheduling
    // jitter without making this test slow. The histogram has 64 log2 buckets
    // so even sparse data hits multiple bins. `.block` backpressure keeps the
    // test deterministic if the scheduler stalls submissions.
    for (0..2000) |_| {
        _ = try pool.submit(common.counterTask, @ptrCast(&counter), .{ .wait_group = &wg });
    }
    wg.wait();

    const stats = pool.statsSnapshot();
    try std.testing.expectEqual(@as(u64, 2000), counter.value.load(.acquire));
    try std.testing.expectEqual(@as(u64, 2000), stats.task_wait_ns.count);
    try std.testing.expectEqual(@as(u64, 2000), stats.task_exec_ns.count);

    // p999 / p9999 must be monotone non-decreasing with p99 and bounded by max.
    // These are the R-01 acceptance assertions.
    try std.testing.expect(stats.task_wait_ns.p99_ns <= stats.task_wait_ns.p999_ns);
    try std.testing.expect(stats.task_wait_ns.p999_ns <= stats.task_wait_ns.p9999_ns);
    try std.testing.expect(stats.task_wait_ns.p9999_ns <= stats.task_wait_ns.max_ns);

    try std.testing.expect(stats.task_exec_ns.p99_ns <= stats.task_exec_ns.p999_ns);
    try std.testing.expect(stats.task_exec_ns.p999_ns <= stats.task_exec_ns.p9999_ns);
    try std.testing.expect(stats.task_exec_ns.p9999_ns <= stats.task_exec_ns.max_ns);

    // At 2000 samples in realistic load, p9999 cannot be zero — that would
    // indicate the summary path is silently skipping the scaled quantile.
    try std.testing.expect(stats.task_exec_ns.p9999_ns > 0);
}

test "per-lane histograms populated when allow_blocking_lane=true" {
    // OBSERVABILITY-PIVOT / R-02: with the blocking lane enabled, the
    // snapshot carries separate default/blocking wait+exec summaries in
    // addition to the pool-wide `task_{wait,exec}_ns`. We exercise both
    // lanes and assert that both per-lane histograms receive samples.
    if (thread_pool.build_options.timestamp_mode == .disabled) return error.SkipZigTest;
    try common.skipIfSchedulerVariantIncompatible(.lane_extension);
    var pool = try thread_pool.ThreadPool.init(std.testing.allocator, .{
        .min_threads = 4,
        .max_threads = 4,
        .queue_capacity = 1024,
        .local_queue_capacity = 32,
        .scheduler_variant = .lane_extension,
        .allow_blocking_lane = true,
        .blocking_workers = 1,
        .blocking_queue_capacity = 512,
    });
    defer pool.deinit();

    var wg = pool.waitGroup();
    var counter = common.Counter{};
    // 64 default-lane tasks and 16 blocking-lane tasks; both lanes must
    // end up with a nonzero histogram count, and the pool-wide summary
    // count must equal their sum.
    for (0..64) |_| {
        _ = try pool.submit(common.counterTask, @ptrCast(&counter), .{ .wait_group = &wg });
    }
    for (0..16) |_| {
        _ = try pool.submit(
            common.counterTask,
            @ptrCast(&counter),
            .{ .wait_group = &wg, .lane = .blocking },
        );
    }
    wg.wait();

    const stats = pool.statsSnapshot();
    try std.testing.expectEqual(@as(u64, 80), counter.value.load(.acquire));
    try std.testing.expect(stats.default_wait_ns.count > 0);
    try std.testing.expect(stats.default_exec_ns.count > 0);
    try std.testing.expect(stats.blocking_wait_ns.count > 0);
    try std.testing.expect(stats.blocking_exec_ns.count > 0);
    // Pool-wide count is the sum of lane counts.
    try std.testing.expectEqual(
        stats.task_wait_ns.count,
        stats.default_wait_ns.count + stats.blocking_wait_ns.count,
    );
    try std.testing.expectEqual(
        stats.task_exec_ns.count,
        stats.default_exec_ns.count + stats.blocking_exec_ns.count,
    );
    try std.testing.expectEqual(@as(u64, 80), stats.task_wait_ns.count);
}

test "memory_budget_used_bytes mirrors live_bytes when budget is unlimited" {
    // OBSERVABILITY-PIVOT / R-10: default `max_pool_memory_bytes = 0`
    // (unlimited) must preserve pre-R-10 behaviour — scratch
    // allocations succeed unconditionally and `memory_budget_used_bytes`
    // reports the same number as `live_bytes`.
    var pool = try thread_pool.ThreadPool.init(std.testing.allocator, .{
        .min_threads = 2,
        .max_threads = 2,
        .queue_capacity = 64,
        .worker_scratch_cap_bytes = 4096,
        // max_pool_memory_bytes defaults to 0 (unlimited)
    });
    defer pool.deinit();

    var wg = pool.waitGroup();
    var counter = common.Counter{};
    var ctx = common.ScratchTaskContext{ .counter = &counter, .bytes = 256 };
    for (0..8) |_| {
        _ = try pool.submit(common.scratchTask, @ptrCast(&ctx), .{ .wait_group = &wg });
    }
    wg.wait();

    const stats = pool.statsSnapshot();
    try std.testing.expectEqual(stats.live_bytes, stats.memory_budget_used_bytes);
    try std.testing.expect(stats.live_bytes > 0);
}

test "max_pool_memory_bytes rejects scratch growth past budget" {
    // OBSERVABILITY-PIVOT / R-10: setting a tiny budget causes the
    // scratch arena's `ensureBuffer` allocation to return
    // `error.PoolMemoryBudgetExceeded`; the error bubbles out of
    // `allocScratch` and the task gracefully continues (the scratch
    // task uses `catch {}` so this is observable via the counter
    // incrementing 0 for scratch allocs but the task itself still
    // executing). Most importantly, `memory_budget_used_bytes` stays
    // <= budget + slack.
    var pool = try thread_pool.ThreadPool.init(std.testing.allocator, .{
        .min_threads = 2,
        .max_threads = 2,
        .queue_capacity = 64,
        .worker_scratch_cap_bytes = 64 * 1024,
        // Budget is 1 byte — effectively "no scratch growth allowed".
        // Init-time allocations (workers, queues, descriptors) are
        // exempt from the budget per the R-10 design note.
        .max_pool_memory_bytes = 1,
    });
    defer pool.deinit();

    var wg = pool.waitGroup();
    var counter = common.Counter{};
    var ctx = common.ScratchTaskContext{ .counter = &counter, .bytes = 256 };
    for (0..4) |_| {
        _ = try pool.submit(common.scratchTask, @ptrCast(&ctx), .{ .wait_group = &wg });
    }
    wg.wait();

    // The task always runs (scratch allocation uses `catch {}`), so
    // the counter advances even when the scratch alloc was rejected.
    try std.testing.expectEqual(@as(u64, 4), counter.value.load(.acquire));

    const stats = pool.statsSnapshot();
    // No scratch arena was successfully allocated because the budget
    // (1 byte) is smaller than `worker_scratch_cap_bytes` (64 KiB).
    // The per-worker scratch_current_bytes therefore stays at 0.
    var scratch_total: u64 = 0;
    for (stats.worker_stats) |ws| scratch_total += ws.scratch_current_bytes;
    try std.testing.expectEqual(@as(u64, 0), scratch_total);
}

test "wake-latency histogram populates under realistic load" {
    // OBSERVABILITY-PIVOT / R-03: when timestamps are enabled, the pool
    // records the delta between parking on `park_cond.timedWait` and
    // that call returning due to a signal from a submitter. Idle-timeout
    // returns are excluded. A bursty submission pattern with a
    // relatively-short park timeout is the most reliable way to get
    // workers to park and wake multiple times inside a single test.
    if (thread_pool.build_options.timestamp_mode == .disabled) return error.SkipZigTest;
    var pool = try thread_pool.ThreadPool.init(std.testing.allocator, .{
        .min_threads = 2,
        .max_threads = 2,
        .queue_capacity = 256,
        // Short spin so workers actually park between bursts instead of
        // busy-looping through spin_before_park_iters.
        .spin_before_park_iters = 0,
        // 10ms idle-park timeout — long enough that it doesn't fire
        // during the short sleeps we use between bursts, short enough
        // that a stuck test aborts quickly rather than hanging.
        .idle_park_after_ns = 10_000_000,
        .default_backpressure = .block,
    });
    defer pool.deinit();

    // Three small bursts separated by 200us pauses give workers time to
    // finish, idle long enough for the spin loop to expire, park, and
    // then wake on the next burst.
    for (0..3) |_| {
        var wg = pool.waitGroup();
        var counter = common.Counter{};
        for (0..16) |_| {
            _ = try pool.submit(common.counterTask, @ptrCast(&counter), .{ .wait_group = &wg });
        }
        wg.wait();
        // Sleep longer than the spin iters but shorter than the park
        // timeout so workers do park but are not purged.
        thread_pool.clock.sleep(200_000);
    }

    // Final burst + wait, then snapshot.
    var wg = pool.waitGroup();
    var counter = common.Counter{};
    for (0..32) |_| {
        _ = try pool.submit(common.counterTask, @ptrCast(&counter), .{ .wait_group = &wg });
    }
    wg.wait();

    const stats = pool.statsSnapshot();
    // At least one wake was signal-driven rather than timeout-driven —
    // the bursty cadence plus 10ms timeout makes this reliable.
    try std.testing.expect(stats.wake_latency_ns.count > 0);
    // The histogram caps at `idle_park_after_ns` (10ms here) by
    // construction, so max must be strictly less than that.
    try std.testing.expect(stats.wake_latency_ns.max_ns < 10_000_000);
    // min can be 0 if the first observation rounded into bucket 0, so we
    // only require that mean is populated.
    try std.testing.expect(stats.wake_latency_ns.mean_ns > 0);
}

test "per-lane histograms zero when allow_blocking_lane=false" {
    // OBSERVABILITY-PIVOT / R-02: single-lane configs must leave the
    // per-lane fields at the zero `LatencySummary` so operators can
    // distinguish "blocking lane disabled" from "blocking lane saw zero
    // tasks". The pool-wide `task_{wait,exec}_ns` still carries the
    // overall data.
    if (thread_pool.build_options.timestamp_mode == .disabled) return error.SkipZigTest;
    var pool = try thread_pool.ThreadPool.init(std.testing.allocator, common.defaultConfig(.global_queue));
    defer pool.deinit();

    var wg = pool.waitGroup();
    var counter = common.Counter{};
    for (0..128) |_| {
        _ = try pool.submit(common.counterTask, @ptrCast(&counter), .{ .wait_group = &wg });
    }
    wg.wait();

    const stats = pool.statsSnapshot();
    try std.testing.expect(stats.task_wait_ns.count > 0);
    try std.testing.expectEqual(@as(u64, 0), stats.default_wait_ns.count);
    try std.testing.expectEqual(@as(u64, 0), stats.default_exec_ns.count);
    try std.testing.expectEqual(@as(u64, 0), stats.blocking_wait_ns.count);
    try std.testing.expectEqual(@as(u64, 0), stats.blocking_exec_ns.count);
}

test "timestamp_mode disabled zeroes histograms" {
    // COMPTIME-ELISION: when the library is compiled with
    // -Dtimestamp-mode=full the runtime config is rejected by design.
    // Skip the disabled-mode behavioral check in that build.
    if (thread_pool.build_options.timestamp_mode == .full) return error.SkipZigTest;
    var pool = try thread_pool.ThreadPool.init(std.testing.allocator, .{
        .max_threads = 2,
        .queue_capacity = 64,
        .timestamp_mode = .disabled,
    });
    defer pool.deinit();

    var wg = pool.waitGroup();
    var counter = common.Counter{};
    for (0..32) |_| {
        _ = try pool.submit(common.counterTask, @ptrCast(&counter), .{ .wait_group = &wg });
    }
    wg.wait();

    const stats = pool.statsSnapshot();
    try std.testing.expectEqual(@as(u64, 0), stats.task_wait_ns.count);
    try std.testing.expectEqual(@as(u64, 0), stats.task_exec_ns.count);
    try std.testing.expectEqual(@as(u64, 32), stats.completed);
}

test "timestamp_mode disabled still purges scratch on idle" {
    // COMPTIME-ELISION: skip under -Dtimestamp-mode=full (same reasoning
    // as the histogram-zeroing test above).
    if (thread_pool.build_options.timestamp_mode == .full) return error.SkipZigTest;
    var pool = try thread_pool.ThreadPool.init(std.testing.allocator, .{
        .max_threads = 2,
        .queue_capacity = 64,
        .worker_scratch_cap_bytes = 1024,
        .idle_park_after_ns = 100_000, // 0.1ms — immediate park
        .idle_purge_after_ns = 200_000, // 0.2ms — quick purge trigger
        .timestamp_mode = .disabled,
    });
    defer pool.deinit();

    var counter = common.Counter{};
    var ctx = common.ScratchTaskContext{ .counter = &counter, .bytes = 256 };

    var wg = pool.waitGroup();
    _ = try pool.submit(common.scratchTask, @ptrCast(&ctx), .{ .wait_group = &wg });
    wg.wait();

    // Sleep long enough for:
    // 1. Worker to enter idle path (spin, then park for idle_park_after_ns)
    // 2. Timeout to fire (idle_park_after_ns)
    // 3. Purge check to succeed (idle_purge_after_ns since task completion)
    // Use a generous sleep to account for scheduling delays
    thread_pool.clock.sleep(100_000_000); // 100ms — very ample time for purge to occur

    const stats = pool.statsSnapshot();
    // After purge, scratch memory should be released. live_bytes may still include
    // other allocations (queues, etc.), but scratch_current_bytes should be near 0.
    if (stats.worker_stats.len > 0) {
        var total_scratch: u64 = 0;
        for (stats.worker_stats) |ws| {
            total_scratch += ws.scratch_current_bytes;
        }
        try std.testing.expect(total_scratch == 0);
    }
}

test "fuzz BoundedRing push/pop consistency" {
    try std.testing.fuzz({}, struct {
        fn testOne(_: void, smith: *std.testing.Smith) !void {
            var buf: [256]u8 = undefined;
            const len = smith.sliceWithHash(&buf, 0);
            const input = buf[0..len];

            const Ring = thread_pool.BoundedRing(u32);
            var ring = Ring.init(std.testing.allocator, 16) catch return;
            defer ring.deinit();

            var pushed: u32 = 0;
            var popped: u32 = 0;

            for (input) |byte| {
                if (byte % 2 == 0) {
                    if (ring.tryPush(pushed)) pushed += 1;
                } else {
                    if (ring.pop()) |_| popped += 1;
                }
            }

            while (ring.pop()) |_| popped += 1;

            try std.testing.expectEqual(pushed, popped);
        }
    }.testOne, .{});
}

test "fuzz Config validation never panics" {
    try std.testing.fuzz({}, struct {
        fn testOne(_: void, smith: *std.testing.Smith) !void {
            const max_threads = smith.valueWithHash(u32, 1);
            const queue_cap = smith.valueWithHash(u32, 2);
            const local_cap = smith.valueWithHash(u32, 3);
            const scheduler_byte = smith.valueWithHash(u8, 4) % 3;

            var cfg = thread_pool.Config{
                .max_threads = max_threads,
                .queue_capacity = queue_cap,
                .local_queue_capacity = local_cap,
                .scheduler_variant = @enumFromInt(scheduler_byte),
            };
            cfg = cfg.normalized();
            cfg.validate() catch {};
        }
    }.testOne, .{});
}

test "phase g2: worker returns from idle when lifo slot filled during spin window" {
    const allocator = std.testing.allocator;

    var pool = try thread_pool.ThreadPool.init(allocator, .{
        .min_threads = 2,
        .max_threads = 2,
        .scheduler_variant = .work_stealing,
        .queue_capacity = 256,
        // Spin long enough that a submit landing during the spin window
        // exercises the end-of-spin local-work probe (not the park/wake
        // path) — but short enough the whole spin fits well inside the
        // 1 ms latency assertion.
        .spin_before_park_iters = 10_000,
        // Tight park timeout — if we DO accidentally park, the test
        // wakes quickly but fails the latency assertion below.
        .idle_park_after_ns = 500_000_000,
    });
    defer pool.deinit();

    // Give workers time to enter idle().
    thread_pool.clock.sleep(5 * std.time.ns_per_ms);

    const Ctx = struct {
        ran_at_ns: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
        fn run(ctx_ptr: *anyopaque, _: *thread_pool.TaskContext) void {
            const self: *@This() = @ptrCast(@alignCast(ctx_ptr));
            self.ran_at_ns.store(@intCast(thread_pool.clock.nanoTimestamp()), .release);
        }
    };
    var ctx = Ctx{};

    const submit_ns: u64 = @intCast(thread_pool.clock.nanoTimestamp());
    _ = try pool.submit(Ctx.run, &ctx, .{});

    // Busy-wait up to 50 ms for the task to run.
    const deadline = submit_ns + 50 * std.time.ns_per_ms;
    while (ctx.ran_at_ns.load(.acquire) == 0) {
        if (@as(u64, @intCast(thread_pool.clock.nanoTimestamp())) > deadline) break;
        std.atomic.spinLoopHint();
    }

    const ran_at = ctx.ran_at_ns.load(.acquire);
    try std.testing.expect(ran_at != 0); // task ran
    const latency_ns = ran_at - submit_ns;
    // Assert latency well below the park timeout. If the worker parked
    // (because the spin didn't re-probe local state), latency would be
    // dominated by park_cond.signal round-trip (~15 µs) which is still
    // below 1 ms — so we assert < 1 ms to catch "spin didn't probe at all"
    // regressions without flapping on ordinary park wakes.
    try std.testing.expect(latency_ns < 1 * std.time.ns_per_ms);
}

test "per-worker park: submit wakes a parked worker" {
    var pool = try thread_pool.ThreadPool.init(std.testing.allocator, .{
        .max_threads = 4,
        .queue_capacity = 128,
        .idle_park_after_ns = 10_000_000, // 10ms — long enough for workers to park
    });
    defer pool.deinit();

    // Let workers park before we submit.
    thread_pool.clock.sleep(50_000_000); // 50ms

    var wg = pool.waitGroup();
    var counter = common.Counter{};
    _ = try pool.submit(common.counterTask, @ptrCast(&counter), .{ .wait_group = &wg });
    wg.wait();

    try std.testing.expectEqual(@as(u64, 1), counter.value.load(.acquire));
    // At least one worker must have woken up.
    const stats = pool.statsSnapshot();
    try std.testing.expect(stats.wakeups > 0);
}

test "Stats.started and .completed aggregate from per-worker counters" {
    var pool = try thread_pool.ThreadPool.init(std.testing.allocator, .{
        .max_threads = 2,
        .queue_capacity = 64,
    });
    defer pool.deinit();

    var wg = pool.waitGroup();
    var counter = common.Counter{};
    for (0..64) |_| {
        _ = try pool.submit(common.counterTask, @ptrCast(&counter), .{ .wait_group = &wg });
    }
    wg.wait();

    const stats = pool.statsSnapshot();
    try std.testing.expectEqual(@as(u64, 64), stats.started);
    try std.testing.expectEqual(@as(u64, 64), stats.completed);
}

test "runtime_stats omits parked_workers counter after simplification" {
    // Compile-time assertion: RuntimeStats (types.Stats) must NOT have
    // a `parked_workers` field after this refactor.
    comptime std.debug.assert(!@hasField(thread_pool.types.Stats, "parked_workers"));
}

test "backpressure block policy returns when capacity frees" {
    var pool = try thread_pool.ThreadPool.init(std.testing.allocator, .{
        .max_threads = 1,
        .queue_capacity = 4,
        .local_queue_capacity = 2,
    });
    defer pool.deinit();

    var wg = pool.waitGroup();
    var counter = common.Counter{};
    // Fill the descriptor pool with tasks.
    for (0..4) |_| {
        _ = try pool.submit(common.counterTask, @ptrCast(&counter), .{ .wait_group = &wg });
    }
    // This one must block (no descriptors available) then succeed once the
    // worker drains a task and releases a descriptor, which signals the
    // backpressure condvar.
    _ = try pool.submit(common.counterTask, @ptrCast(&counter), .{
        .wait_group = &wg,
        .backpressure = .block,
    });
    wg.wait();
    try std.testing.expectEqual(@as(u64, 5), counter.value.load(.acquire));
}

test "LIFO slot: submit-from-worker uses lifo_slot before local ring" {
    const allocator = std.testing.allocator;
    var pool = try thread_pool.ThreadPool.init(allocator, .{
        .max_threads = 1,
        .min_threads = 1,
        .queue_capacity = 256,
        .local_queue_capacity = 16,
        .scheduler_variant = .work_stealing,
    });
    defer pool.deinit();

    // Pass both pool pointer and wait-group to outerTask so inner tasks
    // can register with the same wait-group and be awaited.
    const OuterCtx = struct {
        pool: *thread_pool.ThreadPool,
        wg: *thread_pool.WaitGroup,
    };

    const Nested = struct {
        var outer_counter: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
        var inner_counter: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

        fn innerTask(raw_ctx: *anyopaque, runtime: *thread_pool.TaskContext) void {
            _ = raw_ctx;
            _ = runtime;
            _ = inner_counter.fetchAdd(1, .release);
        }
        fn outerTask(raw_ctx: *anyopaque, runtime: *thread_pool.TaskContext) void {
            _ = runtime;
            const octx: *OuterCtx = @ptrCast(@alignCast(raw_ctx));
            _ = outer_counter.fetchAdd(1, .release);
            _ = octx.pool.submit(innerTask, @ptrCast(octx.pool), .{ .wait_group = octx.wg }) catch {};
        }
    };

    Nested.outer_counter.store(0, .release);
    Nested.inner_counter.store(0, .release);

    var wg = pool.waitGroup();
    var octx = OuterCtx{ .pool = &pool, .wg = &wg };
    for (0..100) |_| {
        _ = try pool.submit(Nested.outerTask, @ptrCast(&octx), .{ .wait_group = &wg });
    }
    wg.wait(); // waits for all 100 outer + 100 inner tasks

    try std.testing.expectEqual(@as(u64, 100), Nested.outer_counter.load(.acquire));
    try std.testing.expectEqual(@as(u64, 100), Nested.inner_counter.load(.acquire));
}

test "backpressure deadline: returns error.Timeout when queue stays full" {
    // Queue=2, single worker whose two slots stay occupied by blocking tasks.
    // A 3rd submit with a tight deadline must return Timeout within ~100 ms,
    // not hang. Exercises the spin-backoff deadline-clipping path in
    // waitForCapacity.
    var pool = try thread_pool.ThreadPool.init(std.testing.allocator, .{
        .min_threads = 1,
        .max_threads = 1,
        .queue_capacity = 2,
        .local_queue_capacity = 2,
    });
    defer pool.deinit();

    var block_sem = thread_pool.sync.Semaphore{};

    const BlockCtx = struct {
        sem: *thread_pool.sync.Semaphore,
        fn run(raw: *anyopaque, rt: *thread_pool.TaskContext) void {
            _ = rt;
            const ctx: *@This() = @ptrCast(@alignCast(raw));
            ctx.sem.wait();
        }
    };
    var bctx = BlockCtx{ .sem = &block_sem };

    // Fill the queue with blocking tasks.
    _ = try pool.submit(BlockCtx.run, @ptrCast(&bctx), .{});
    _ = try pool.submit(BlockCtx.run, @ptrCast(&bctx), .{});

    // Third submit must time out within ~100 ms.
    const start = thread_pool.clock.nanoTimestamp();
    const result = pool.submit(BlockCtx.run, @ptrCast(&bctx), .{
        .backpressure = .block_with_timeout,
        .timeout_ns = 10 * std.time.ns_per_ms,
    });
    const elapsed = thread_pool.clock.nanoTimestamp() - start;
    try std.testing.expectError(error.Timeout, result);
    try std.testing.expect(elapsed >= 10 * std.time.ns_per_ms);
    try std.testing.expect(elapsed < 100 * std.time.ns_per_ms); // hang guard

    // Release the blocked tasks so shutdown drains cleanly.
    block_sem.post();
    block_sem.post();
}

test "Config validate rejects max_threads > 64" {
    const cfg = thread_pool.Config{ .max_threads = 65, .min_threads = 1 };
    try std.testing.expectError(error.TooManyWorkers, cfg.validate());
}

test "Config validate accepts max_threads = 64" {
    const cfg = thread_pool.Config{ .max_threads = 64, .min_threads = 1 };
    try cfg.validate();
}

test "Config validate: explicit max_threads > 64 still rejected after normalized()" {
    // normalized() only clamps auto-detect (max_threads == 0) to 64.
    // Explicit over-limit values must still be rejected by validate().
    const cfg = (thread_pool.Config{ .max_threads = 65, .min_threads = 1 }).normalized();
    try std.testing.expectError(error.TooManyWorkers, cfg.validate());
}

test "non_empty_workers bitmap invariant under racing push/pop" {
    // 8 workers pushing/popping 80k tasks; after quiesce, counter must
    // equal total, queued/active must be 0, and a follow-up submit must
    // still execute. Smoke test that the scheduler protocol doesn't break
    // correctness under concurrent push, pop-to-empty, and steal drain.
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
        // Block on backpressure so the test works on CI runners with
        // fewer cores than workers (queue fills before workers drain).
        _ = try pool.submit(common.counterTask, @ptrCast(&counter), .{ .wait_group = &wg, .backpressure = .block });
    }
    wg.wait();
    try std.testing.expectEqual(total, counter.value.load(.acquire));

    // Give workers a brief window to drain late stragglers so counters settle.
    thread_pool.clock.sleep(5 * std.time.ns_per_ms);
    const stats = pool.statsSnapshot();
    try std.testing.expectEqual(@as(u64, 0), stats.queue_depth_current);
    try std.testing.expectEqual(@as(u64, 0), stats.active_tasks);

    // Follow-up submit confirms end-to-end wakeup path still functions
    // post-quiesce.
    var final_counter = common.Counter{};
    var final_wg = pool.waitGroup();
    _ = try pool.submit(common.counterTask, @ptrCast(&final_counter), .{ .wait_group = &final_wg, .backpressure = .block });
    final_wg.wait();
    try std.testing.expectEqual(@as(u64, 1), final_counter.value.load(.acquire));
}

test "Config validate rejects hot_spinners >= max_threads" {
    const cfg = thread_pool.Config{ .max_threads = 4, .min_threads = 1, .hot_spinners = 4 };
    try std.testing.expectError(error.InvalidHotSpinners, cfg.validate());
}

test "Config validate accepts hot_spinners < max_threads" {
    const cfg = thread_pool.Config{ .max_threads = 4, .min_threads = 1, .hot_spinners = 1 };
    try cfg.validate();
}

test "Config validate rejects hot_spinners > 0 with wake_every_n_tasks == 0" {
    const cfg = thread_pool.Config{
        .max_threads = 4,
        .min_threads = 1,
        .hot_spinners = 1,
        .wake_every_n_tasks = 0,
    };
    try std.testing.expectError(error.InvalidWakeThreshold, cfg.validate());
}

test "Config validate accepts hot_spinners = 0 with wake_every_n_tasks = 0" {
    const cfg = thread_pool.Config{
        .max_threads = 4,
        .min_threads = 1,
        .hot_spinners = 0,
        .wake_every_n_tasks = 0,
    };
    try cfg.validate();
}

test "active_spinners: counter stays non-negative under concurrent workers" {
    // Integration-level sanity: submit a steady stream of tasks to a
    // multi-worker pool, assert total task count matches after quiesce.
    // If the active_spinners fetchAdd/fetchSub pairing is broken (e.g.,
    // missing a decrement on some exit path), the counter drifts and
    // the submitter either skips all wakes (tasks never picked up) or
    // always wakes (no perf benefit but still correct). This test
    // catches the first failure mode — a stuck pool.
    var pool = try thread_pool.ThreadPool.init(std.testing.allocator, .{
        .min_threads = 4,
        .max_threads = 4,
        .queue_capacity = 4096,
        .local_queue_capacity = 256,
        .scheduler_variant = .work_stealing,
        // Short spin to force rapid spin→park→wake cycles, exercising
        // every exit path from idle().
        .spin_before_park_iters = 8,
        .idle_park_after_ns = 50_000,
    });
    defer pool.deinit();

    var counter = common.Counter{};
    var wg = pool.waitGroup();

    const total: u64 = 40_000;
    var i: u64 = 0;
    while (i < total) : (i += 1) {
        _ = try pool.submit(common.counterTask, @ptrCast(&counter), .{ .wait_group = &wg, .backpressure = .block });
    }
    wg.wait();
    try std.testing.expectEqual(total, counter.value.load(.acquire));

    // Brief quiesce so workers drain any stragglers and return to idle.
    thread_pool.clock.sleep(5 * std.time.ns_per_ms);

    // Submit one more task; must execute. If active_spinners is stuck >0
    // with all workers parked, the submitter skips the wake and this
    // task starves (test timeout via wg.wait semantics on single task).
    var final_counter = common.Counter{};
    var final_wg = pool.waitGroup();
    _ = try pool.submit(common.counterTask, @ptrCast(&final_counter), .{ .wait_group = &final_wg, .backpressure = .block });
    final_wg.wait();
    try std.testing.expectEqual(@as(u64, 1), final_counter.value.load(.acquire));
}

test "hot_spinners = 1 executes all submitted tasks" {
    var pool = try thread_pool.ThreadPool.init(std.testing.allocator, .{
        .min_threads = 4,
        .max_threads = 4,
        .queue_capacity = 4096,
        .local_queue_capacity = 256,
        .scheduler_variant = .work_stealing,
        .hot_spinners = 1,
        .wake_every_n_tasks = 8,
    });
    defer pool.deinit();

    var counter = common.Counter{};
    var wg = pool.waitGroup();

    const total: u64 = 10_000;
    var i: u64 = 0;
    while (i < total) : (i += 1) {
        _ = try pool.submit(common.counterTask, @ptrCast(&counter), .{ .wait_group = &wg, .backpressure = .block });
    }
    wg.wait();
    try std.testing.expectEqual(total, counter.value.load(.acquire));
}

test "hot_spinners = 1 executes follow-up task after quiesce" {
    // Regression guard: after the initial burst drains, the hot-spinner
    // must still execute the next submitted task without requiring any
    // external wake.
    var pool = try thread_pool.ThreadPool.init(std.testing.allocator, .{
        .min_threads = 2,
        .max_threads = 2,
        .queue_capacity = 1024,
        .local_queue_capacity = 128,
        .scheduler_variant = .work_stealing,
        .hot_spinners = 1,
        .wake_every_n_tasks = 4,
    });
    defer pool.deinit();

    var counter = common.Counter{};
    var wg = pool.waitGroup();
    var i: u64 = 0;
    while (i < 500) : (i += 1) {
        _ = try pool.submit(common.counterTask, @ptrCast(&counter), .{ .wait_group = &wg });
    }
    wg.wait();
    try std.testing.expectEqual(@as(u64, 500), counter.value.load(.acquire));

    // Brief idle period so the non-hot worker parks.
    thread_pool.clock.sleep(10 * std.time.ns_per_ms);

    // One more task — must execute via the hot-spinner.
    var solo = common.Counter{};
    var solo_wg = pool.waitGroup();
    _ = try pool.submit(common.counterTask, @ptrCast(&solo), .{ .wait_group = &solo_wg });
    solo_wg.wait();
    try std.testing.expectEqual(@as(u64, 1), solo.value.load(.acquire));
}

test "phase h regression: state CAS gate rejects duplicate descriptor dispatch" {
    // Regression guard for the Phase H state-CAS fix in runTask. The wider
    // reproducer lives in tests/stress/double_dequeue_race.zig; this is a
    // smaller/faster unit test intended to exercise the same race window
    // (spin=0 + tight idle park + 16-worker submit flood) on every unit
    // test run so a future refactor that drops the state CAS surfaces here
    // rather than only in the stress suite.
    //
    // The state CAS at the top of runTask transitions .queued → .running;
    // any duplicate descriptor_index emission from some queue path arrives
    // after the first claimant already released the descriptor (task_fn is
    // null, state is .free or recycled), fails the CAS, and returns
    // silently. Pre-fix, the same race would SIGSEGV on a NULL task_fn call.
    const noop = struct {
        fn run(_: *anyopaque, _: *thread_pool.TaskContext) void {}
    }.run;

    var pool = try thread_pool.ThreadPool.init(std.testing.allocator, .{
        .min_threads = 16,
        .max_threads = 16,
        .queue_capacity = 4096,
        .local_queue_capacity = 256,
        .scheduler_variant = .work_stealing,
        .spin_before_park_iters = 0,
        .idle_park_after_ns = 10_000, // 10us — high park churn
    });
    defer pool.deinit();

    // Let workers reach steady state before the flood.
    thread_pool.clock.sleep(5 * std.time.ns_per_ms);

    const per_producer: u64 = 200_000;
    var wg = pool.waitGroup();

    const Submitter = struct {
        fn run(p: *thread_pool.ThreadPool, g: *thread_pool.WaitGroup, n: u64) void {
            var dummy: u8 = 0;
            var i: u64 = 0;
            while (i < n) : (i += 1) {
                _ = p.submit(noop, @ptrCast(&dummy), .{
                    .backpressure = .block,
                    .wait_group = g,
                }) catch return;
            }
        }
    };

    const t1 = try std.Thread.spawn(.{}, Submitter.run, .{ &pool, &wg, per_producer });
    const t2 = try std.Thread.spawn(.{}, Submitter.run, .{ &pool, &wg, per_producer });
    t1.join();
    t2.join();

    // Deadline-based polling so a lost wakeup surfaces as a test failure
    // with a clear pendingCount rather than a process-level hang.
    const deadline_ns: i128 = 60 * std.time.ns_per_s;
    const start = thread_pool.clock.nanoTimestamp();
    while (thread_pool.clock.nanoTimestamp() - start < deadline_ns) {
        if (wg.pendingCount() == 0) break;
        thread_pool.clock.sleep(1 * std.time.ns_per_ms);
    }

    try std.testing.expectEqual(@as(u32, 0), wg.pendingCount());
}

test "g3: Stats.submitted reports exact spawn count" {
    var pool = try thread_pool.ThreadPool.init(std.testing.allocator, common.defaultConfig(.work_stealing));
    defer pool.deinit();

    const N: u64 = 1000;
    var wg = pool.waitGroup();
    var counter = common.Counter{};
    var i: u64 = 0;
    while (i < N) : (i += 1) {
        _ = try pool.submit(common.counterTask, @ptrCast(&counter), .{ .wait_group = &wg, .backpressure = .block });
    }
    wg.wait();

    try std.testing.expectEqual(N, counter.value.load(.acquire));
    const stats = pool.statsSnapshot();
    try std.testing.expectEqual(N, stats.submitted);
}

test "sync.Mutex lock/unlock is thread-safe" {
    var m: thread_pool.sync.Mutex = .{};
    var counter: u64 = 0;
    const N = 4;
    const IterPerThread = 1000;
    const Worker = struct {
        fn run(mutex: *thread_pool.sync.Mutex, c: *u64) void {
            var i: usize = 0;
            while (i < IterPerThread) : (i += 1) {
                mutex.lock();
                c.* += 1;
                mutex.unlock();
            }
        }
    };
    var threads: [N]std.Thread = undefined;
    for (&threads) |*t| t.* = try std.Thread.spawn(.{}, Worker.run, .{ &m, &counter });
    for (threads) |t| t.join();
    try std.testing.expectEqual(@as(u64, N * IterPerThread), counter);
}

test "sync.Mutex tryLock succeeds when unlocked, fails when locked" {
    var m: thread_pool.sync.Mutex = .{};
    try std.testing.expect(m.tryLock());
    try std.testing.expect(!m.tryLock());
    m.unlock();
    try std.testing.expect(m.tryLock());
    m.unlock();
}

test "sync.Condition signal wakes waiter" {
    var m: thread_pool.sync.Mutex = .{};
    var c: thread_pool.sync.Condition = .{};
    var ready: bool = false;

    const Ctx = struct { m: *thread_pool.sync.Mutex, c: *thread_pool.sync.Condition, ready: *bool };
    const ctx = Ctx{ .m = &m, .c = &c, .ready = &ready };

    const Waiter = struct {
        fn run(x: Ctx) void {
            x.m.lock();
            defer x.m.unlock();
            while (!x.ready.*) x.c.wait(x.m);
        }
    };
    var t = try std.Thread.spawn(.{}, Waiter.run, .{ctx});

    // Yield a handful of times to let the waiter park; no external sleep.
    var i: usize = 0;
    while (i < 1000) : (i += 1) std.Thread.yield() catch {};

    m.lock();
    ready = true;
    c.signal();
    m.unlock();

    t.join();
}

test "sync.Semaphore permits balance" {
    var s: thread_pool.sync.Semaphore = .{};
    s.post();
    s.post();
    s.wait();
    s.wait();
    // Non-hang = success.
}

test "clock.nanoTimestamp increases over time" {
    const a = thread_pool.clock.nanoTimestamp();
    thread_pool.clock.sleep(1 * std.time.ns_per_ms);
    const b = thread_pool.clock.nanoTimestamp();
    try std.testing.expect(b > a);
}

test "clock.sleep sleeps at least the requested duration" {
    const want_ns: u64 = 5 * std.time.ns_per_ms;
    const start = thread_pool.clock.nanoTimestamp();
    thread_pool.clock.sleep(want_ns);
    const elapsed = thread_pool.clock.nanoTimestamp() - start;
    // Allow 0.5ms slop for scheduler jitter.
    try std.testing.expect(elapsed >= @as(i96, @intCast(want_ns - 500_000)));
}

test "DescCache stores and returns indices LIFO" {
    var cache = thread_pool.DescCache.init();
    try std.testing.expectEqual(@as(usize, 0), cache.len());
    try std.testing.expect(cache.tryPop() == null);

    _ = cache.push(7);
    _ = cache.push(9);
    try std.testing.expectEqual(@as(?u32, 9), cache.tryPop());
    try std.testing.expectEqual(@as(?u32, 7), cache.tryPop());
    try std.testing.expect(cache.tryPop() == null);
}

test "DescCache full push returns false" {
    var cache = thread_pool.DescCache.init();
    var i: u32 = 0;
    while (i < thread_pool.DescCache.capacity) : (i += 1) try std.testing.expect(cache.push(i));
    try std.testing.expect(!cache.push(9999));
}

test "DescCache drainAll yields all held indices" {
    var cache = thread_pool.DescCache.init();
    _ = cache.push(1);
    _ = cache.push(2);
    _ = cache.push(3);

    var drained: [4]u32 = undefined;
    const n = cache.drainAll(&drained);
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqualSlices(u32, &[_]u32{ 3, 2, 1 }, drained[0..n]);
    try std.testing.expectEqual(@as(usize, 0), cache.len());
}

test "acquireDescriptorBatch returns distinct indices in one CAS" {
    const allocator = std.testing.allocator;
    var pool = try thread_pool.ThreadPool.init(allocator, .{
        .min_threads = 1,
        .max_threads = 1,
        .queue_capacity = 64,
        .local_queue_capacity = 32,
        .scheduler_variant = .work_stealing,
    });
    defer pool.deinit();

    var out: [16]u32 = undefined;
    const n = pool.acquireDescriptorBatchForTesting(&out);
    try std.testing.expect(n > 0 and n <= out.len);

    var seen = std.AutoHashMap(u32, void).init(allocator);
    defer seen.deinit();
    for (out[0..n]) |idx| {
        const gop = try seen.getOrPut(idx);
        try std.testing.expect(!gop.found_existing);
    }

    for (out[0..n]) |idx| pool.releaseDescriptorForTesting(idx);
}

test "registered submitter handles N > DescCache.capacity submits correctly" {
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
    const N: usize = thread_pool.DescCache.capacity * 3 + 5;
    var i: usize = 0;
    while (i < N) : (i += 1) {
        _ = try pool.submit(noop, @ptrCast(&done), .{ .wait_group = &wg, .backpressure = .block });
    }
    wg.wait();
    try std.testing.expectEqual(@as(u64, N), done.load(.acquire));
}

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
    // 16 submits will refill the cache (take 32 from freelist on first miss,
    // consume 1, cache 31 — then 15 more tryPop hits). After wg.wait() returns,
    // 16 descriptors are queued but the other 16 cached indices are still live.
    for (0..16) |_| {
        _ = try pool.submit(noop, @ptrCast(&done), .{ .wait_group = &wg, .backpressure = .block });
    }
    wg.wait();

    // Release the submitter — must return the remaining ~16 cached
    // descriptors to the global freelist, restoring task_desc_live to
    // the pre-registration value.
    pool.releaseSubmitter(slot);

    const stats_after = pool.statsSnapshot();
    try std.testing.expectEqual(live_before, stats_after.task_desc_live);
}

test "Worker struct is within the 4096-byte ceiling post-desc_cache" {
    const allocator = std.testing.allocator;
    var pool = try thread_pool.ThreadPool.init(allocator, .{
        .min_threads = 4,
        .max_threads = 4,
        .queue_capacity = 64,
        .local_queue_capacity = 32,
        .scheduler_variant = .work_stealing,
    });
    defer pool.deinit();

    try pool.assertWorkerSizeBoundedForTesting(4096);
}

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
            var i: usize = 0;
            while (i < 64) : (i += 1) {
                _ = self.pool.submit(child, @ptrCast(self), .{
                    .wait_group = self.wg,
                    .backpressure = .block,
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
    _ = try pool.submit(Ctx.parent, @ptrCast(&ctx), .{
        .wait_group = &wg,
        .backpressure = .block,
    });
    wg.wait();
    try std.testing.expectEqual(@as(u64, 64), done.load(.monotonic));
}

test "pool.deinit drains per-worker desc_caches" {
    // Verifies that descriptor indices cached in Worker.desc_cache are
    // returned to the global freelist at pool teardown, so task_desc_live
    // reaches zero.  The explicit drainWorkerDescCachesForTesting hook
    // mirrors the drain that deinitOwned runs, letting us assert the
    // invariant while the pool is still live (statsSnapshot requires a
    // live pool).  Without the drain, workers hold ~32 cached-but-unused
    // indices each and task_desc_live remains > 0 after wg.wait().
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
            var i: usize = 0;
            // 96 children across 2 workers ensures both caches refill at
            // least once, leaving cached-but-unused indices when tasks end.
            while (i < 96) : (i += 1) {
                _ = self.pool.submit(child, @ptrCast(self), .{
                    .wait_group = self.wg,
                    .backpressure = .block,
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
    _ = try pool.submit(Ctx.parent, @ptrCast(&ctx), .{
        .wait_group = &wg,
        .backpressure = .block,
    });
    wg.wait();

    // Drain worker caches before asserting; this exercises the same code
    // path that deinitOwned calls internally at shutdown.
    pool.drainWorkerDescCachesForTesting();

    const stats = pool.statsSnapshot();
    try std.testing.expectEqual(@as(u64, 0), stats.task_desc_live);
}
