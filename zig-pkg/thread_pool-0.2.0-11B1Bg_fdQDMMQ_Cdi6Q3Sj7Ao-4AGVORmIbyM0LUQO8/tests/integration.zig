const std = @import("std");
const thread_pool = @import("thread_pool");
const common = @import("common.zig");

// F-001 regression test: cross-pool TLS index scoping
comptime {
    _ = @import("integration/two_pool_cross_submit.zig");
}

// F-002 regression test: spawn-aware errdefer in Core.init
comptime {
    _ = @import("integration/spawn_failure.zig");
}

// F-005 regression test: idempotent and bounds-checked releaseSubmitter
comptime {
    _ = @import("integration/submitter_lifecycle.zig");
}

fn waitUntilGateStarted(ctx: *common.GateTaskContext) !void {
    const deadline = thread_pool.clock.nanoTimestamp() + (5 * std.time.ns_per_s);
    while (thread_pool.clock.nanoTimestamp() < deadline) {
        if (ctx.started.load(.acquire)) return;
        thread_pool.clock.sleep(100_000);
    }
    return error.Timeout;
}

test "multi-producer contention completes all tasks on work stealing scheduler" {
    var pool = try thread_pool.ThreadPool.init(std.testing.allocator, .{
        .min_threads = 4,
        .max_threads = 4,
        .queue_capacity = 1024,
        .local_queue_capacity = 128,
        .inject_batch_size = 16,
        .scheduler_variant = .work_stealing,
        .worker_scratch_cap_bytes = 4096,
        .idle_park_after_ns = 100_000,
        .idle_purge_after_ns = 500_000,
    });
    defer pool.deinit();

    var wg = pool.waitGroup();
    var counter = common.Counter{};
    const producers = [_]common.ProducerContext{
        .{ .pool = &pool, .counter = &counter, .wait_group = &wg, .task_count = 128 },
        .{ .pool = &pool, .counter = &counter, .wait_group = &wg, .task_count = 128 },
        .{ .pool = &pool, .counter = &counter, .wait_group = &wg, .task_count = 128 },
        .{ .pool = &pool, .counter = &counter, .wait_group = &wg, .task_count = 128 },
    };
    var producer_state = producers;
    var threads: [producer_state.len]std.Thread = undefined;
    for (&threads, &producer_state) |*thread, *producer| {
        thread.* = try std.Thread.spawn(.{}, common.producerMain, .{producer});
    }
    for (threads) |thread| thread.join();
    wg.wait();

    try std.testing.expectEqual(@as(u64, 512), counter.value.load(.acquire));
}

test "batch submission with wait group completes" {
    var pool = try thread_pool.ThreadPool.init(std.testing.allocator, common.defaultConfig(.global_queue));
    defer pool.deinit();

    var wg = pool.waitGroup();
    var counter = common.Counter{};
    var tasks: [32]thread_pool.BatchTask = undefined;
    for (&tasks) |*task| {
        task.* = .{
            .task_fn = common.counterTask,
            .ctx = @ptrCast(&counter),
        };
    }
    const result = try pool.submitBatch(&tasks, .{ .wait_group = &wg });
    try std.testing.expectEqual(@as(usize, 32), result.submitted);
    wg.wait();

    try std.testing.expectEqual(@as(u64, 32), counter.value.load(.acquire));
}

test "blocking tasks do not wedge the pool" {
    var pool = try thread_pool.ThreadPool.init(std.testing.allocator, .{
        .min_threads = 4,
        .max_threads = 4,
        .queue_capacity = 128,
        .local_queue_capacity = 32,
        .scheduler_variant = .work_stealing,
        .allow_blocking_lane = true,
        .blocking_workers = 1,
        .worker_scratch_cap_bytes = 1024,
        .idle_park_after_ns = 100_000,
        .idle_purge_after_ns = 500_000,
    });
    defer pool.deinit();

    var wg = pool.waitGroup();
    var counter = common.Counter{};
    var sleeper = common.SleepTaskContext{ .counter = &counter, .sleep_ns = 200_000 };
    for (0..6) |_| {
        _ = try pool.submit(common.sleepTask, @ptrCast(&sleeper), .{ .wait_group = &wg, .lane = .blocking });
    }
    for (0..32) |_| {
        _ = try pool.submit(common.counterTask, @ptrCast(&counter), .{ .wait_group = &wg });
    }
    wg.wait();

    try std.testing.expectEqual(@as(u64, 38), counter.value.load(.acquire));
}

test "blocking lane rejected when allow_blocking_lane is false" {
    var pool = try thread_pool.ThreadPool.init(std.testing.allocator, .{
        .min_threads = 2,
        .max_threads = 2,
        .queue_capacity = 16,
        .local_queue_capacity = 8,
        .scheduler_variant = .work_stealing,
        .worker_scratch_cap_bytes = 512,
    });
    defer pool.deinit();

    var counter = common.Counter{};
    const result = pool.submit(common.counterTask, @ptrCast(&counter), .{ .lane = .blocking });
    try std.testing.expectError(error.BlockingLaneDisabled, result);
}

test "default-lane submissions unaffected by blocking_workers = 0" {
    var pool = try thread_pool.ThreadPool.init(std.testing.allocator, .{
        .min_threads = 4,
        .max_threads = 4,
        .queue_capacity = 128,
        .local_queue_capacity = 32,
        .scheduler_variant = .work_stealing,
        .worker_scratch_cap_bytes = 1024,
    });
    defer pool.deinit();

    var wg = pool.waitGroup();
    var counter = common.Counter{};
    for (0..64) |_| {
        _ = try pool.submit(common.counterTask, @ptrCast(&counter), .{ .wait_group = &wg });
    }
    wg.wait();
    try std.testing.expectEqual(@as(u64, 64), counter.value.load(.acquire));
}

test "blocking worker isolates CPU pool from stalled blocking task" {
    var pool = try thread_pool.ThreadPool.init(std.testing.allocator, .{
        .min_threads = 4,
        .max_threads = 4,
        .queue_capacity = 128,
        .local_queue_capacity = 32,
        .scheduler_variant = .work_stealing,
        .allow_blocking_lane = true,
        .blocking_workers = 1,
        .worker_scratch_cap_bytes = 1024,
    });
    defer pool.deinit();

    var wg = pool.waitGroup();
    var counter = common.Counter{};

    // One blocking task that sleeps 200ms — would hog a worker if no isolation.
    var sleeper = common.SleepTaskContext{ .counter = &counter, .sleep_ns = 200 * std.time.ns_per_ms };
    _ = try pool.submit(common.sleepTask, @ptrCast(&sleeper), .{ .wait_group = &wg, .lane = .blocking });

    // 100 CPU tasks that should all complete well before the blocking task.
    for (0..100) |_| {
        _ = try pool.submit(common.counterTask, @ptrCast(&counter), .{ .wait_group = &wg });
    }

    wg.wait();
    try std.testing.expectEqual(@as(u64, 101), counter.value.load(.acquire));
}

test "lane_extension variant accepted with blocking_workers > 0" {
    var pool = try thread_pool.ThreadPool.init(std.testing.allocator, .{
        .min_threads = 4,
        .max_threads = 4,
        .queue_capacity = 64,
        .local_queue_capacity = 16,
        .scheduler_variant = .lane_extension,
        .allow_blocking_lane = true,
        .blocking_workers = 1,
        .worker_scratch_cap_bytes = 1024,
    });
    defer pool.deinit();

    var wg = pool.waitGroup();
    var counter = common.Counter{};
    var sleeper = common.SleepTaskContext{ .counter = &counter, .sleep_ns = 100_000 };
    for (0..4) |_| {
        _ = try pool.submit(common.sleepTask, @ptrCast(&sleeper), .{ .wait_group = &wg, .lane = .blocking });
    }
    for (0..16) |_| {
        _ = try pool.submit(common.counterTask, @ptrCast(&counter), .{ .wait_group = &wg });
    }
    wg.wait();
    try std.testing.expectEqual(@as(u64, 20), counter.value.load(.acquire));
}

test "blocking_backpressure config forces return_error on full blocking queue" {
    // Slice L2: Config.blocking_backpressure overrides caller's SubmitOptions.backpressure.
    // One blocking worker sleeps, filling the tiny blocking queue; the next
    // blocking submit is asked to .block but must see return_error per config.
    var pool = try thread_pool.ThreadPool.init(std.testing.allocator, .{
        .min_threads = 2,
        .max_threads = 2,
        .queue_capacity = 64,
        .local_queue_capacity = 16,
        .scheduler_variant = .work_stealing,
        .allow_blocking_lane = true,
        .blocking_workers = 1,
        .blocking_queue_capacity = 2,
        .blocking_backpressure = .return_error,
        .worker_scratch_cap_bytes = 512,
    });
    defer pool.deinit();

    var wg = pool.waitGroup();
    var counter = common.Counter{};
    var gate = common.GateTaskContext{ .counter = &counter };
    // Long sleep so the blocking worker stays occupied while we fill the queue.
    var sleeper = common.SleepTaskContext{ .counter = &counter, .sleep_ns = 100 * std.time.ns_per_ms };

    // Deterministically occupy the blocking worker, then fill the queue.
    _ = try pool.submit(common.gateTask, @ptrCast(&gate), .{ .wait_group = &wg, .lane = .blocking });
    try waitUntilGateStarted(&gate);
    _ = try pool.submit(common.sleepTask, @ptrCast(&sleeper), .{
        .wait_group = &wg,
        .lane = .blocking,
        .backpressure = .return_error,
    });
    _ = try pool.submit(common.sleepTask, @ptrCast(&sleeper), .{
        .wait_group = &wg,
        .lane = .blocking,
        .backpressure = .return_error,
    });

    // The caller asks to .block, but blocking_backpressure = .return_error
    // forces QueueFull.
    const result = pool.submit(
        common.sleepTask,
        @ptrCast(&sleeper),
        .{ .wait_group = &wg, .lane = .blocking, .backpressure = .block },
    );
    try std.testing.expectError(error.QueueFull, result);

    gate.release.store(true, .release);
    wg.wait();
}

test "full blocking queue does not block default-lane submitters" {
    // Slice L2 cross-lane isolation: a full blocking queue with .block policy
    // must not serialize default-lane submitters on shared mutex/cond.
    var pool = try thread_pool.ThreadPool.init(std.testing.allocator, .{
        .min_threads = 4,
        .max_threads = 4,
        .queue_capacity = 128,
        .local_queue_capacity = 32,
        .scheduler_variant = .work_stealing,
        .allow_blocking_lane = true,
        .blocking_workers = 1,
        .blocking_queue_capacity = 2,
        .worker_scratch_cap_bytes = 1024,
    });
    defer pool.deinit();

    var wg = pool.waitGroup();
    var counter = common.Counter{};
    var gate = common.GateTaskContext{ .counter = &counter };
    var sleeper = common.SleepTaskContext{ .counter = &counter, .sleep_ns = 50 * std.time.ns_per_ms };

    // Saturate the blocking lane deterministically: 1 gated task in flight +
    // 2 queued.
    _ = try pool.submit(common.gateTask, @ptrCast(&gate), .{ .wait_group = &wg, .lane = .blocking });
    try waitUntilGateStarted(&gate);
    _ = try pool.submit(common.sleepTask, @ptrCast(&sleeper), .{
        .wait_group = &wg,
        .lane = .blocking,
        .backpressure = .return_error,
    });
    _ = try pool.submit(common.sleepTask, @ptrCast(&sleeper), .{
        .wait_group = &wg,
        .lane = .blocking,
        .backpressure = .return_error,
    });

    // Default-lane submissions: must complete quickly regardless of the
    // blocking-lane saturation.
    const start = thread_pool.clock.nanoTimestamp();
    for (0..64) |_| {
        _ = try pool.submit(common.counterTask, @ptrCast(&counter), .{ .wait_group = &wg });
    }
    const elapsed_submit_ns: u64 = @intCast(thread_pool.clock.nanoTimestamp() - start);
    // 64 non-contended submits should take far less than one blocking sleep.
    try std.testing.expect(elapsed_submit_ns < 25 * std.time.ns_per_ms);

    gate.release.store(true, .release);
    wg.wait();
    // 3 blocking + 64 default = 67 tasks.
    try std.testing.expectEqual(@as(u64, 67), counter.value.load(.acquire));
}

test "blocking_queue_capacity sized independently of queue_capacity" {
    // Slice L2: blocking_queue_capacity is honored; default-queue capacity
    // stays large enough to absorb many default-lane submits.
    var pool = try thread_pool.ThreadPool.init(std.testing.allocator, .{
        .min_threads = 4,
        .max_threads = 4,
        .queue_capacity = 512,
        .local_queue_capacity = 64,
        .scheduler_variant = .work_stealing,
        .allow_blocking_lane = true,
        .blocking_workers = 1,
        .blocking_queue_capacity = 4,
        .worker_scratch_cap_bytes = 1024,
    });
    defer pool.deinit();

    var wg = pool.waitGroup();
    var counter = common.Counter{};
    var gate = common.GateTaskContext{ .counter = &counter };
    var sleeper = common.SleepTaskContext{ .counter = &counter, .sleep_ns = 100 * std.time.ns_per_ms };

    // 1 gated task in flight + 4 queued = 5 accepted. The 6th must fail.
    _ = try pool.submit(common.gateTask, @ptrCast(&gate), .{ .wait_group = &wg, .lane = .blocking });
    try waitUntilGateStarted(&gate);
    for (0..4) |_| {
        _ = try pool.submit(common.sleepTask, @ptrCast(&sleeper), .{
            .wait_group = &wg,
            .lane = .blocking,
            .backpressure = .return_error,
        });
    }
    const overflow = pool.submit(
        common.sleepTask,
        @ptrCast(&sleeper),
        .{ .wait_group = &wg, .lane = .blocking, .backpressure = .return_error },
    );
    try std.testing.expectError(error.QueueFull, overflow);

    // Default lane (capacity 512) still accepts plenty.
    for (0..256) |_| {
        _ = try pool.submit(common.counterTask, @ptrCast(&counter), .{ .wait_group = &wg });
    }
    gate.release.store(true, .release);
    wg.wait();
    // 5 blocking sleepers + 256 default counters = 261.
    try std.testing.expectEqual(@as(u64, 261), counter.value.load(.acquire));
}
test "blocking worker rebalances to default lane when blocking_inject is empty" {
    // Slice L3: the blocking worker always helps the default lane when its own
    // lane is idle. With a single default worker swamped by many default tasks,
    // an idle blocking worker must pick up and execute default work.
    var pool = try thread_pool.ThreadPool.init(std.testing.allocator, .{
        .min_threads = 2,
        .max_threads = 2,
        .queue_capacity = 1024,
        .local_queue_capacity = 64,
        .scheduler_variant = .lane_extension,
        .allow_blocking_lane = true,
        .blocking_workers = 1,
        .worker_scratch_cap_bytes = 1024,
    });
    defer pool.deinit();

    var wg = pool.waitGroup();
    var counter = common.Counter{};
    // Submit only default-lane work. No blocking submissions — the blocking
    // worker has no own-lane work and must rebalance to the default lane to
    // finish the batch.
    for (0..512) |_| {
        _ = try pool.submit(common.counterTask, @ptrCast(&counter), .{ .wait_group = &wg });
    }
    wg.wait();
    try std.testing.expectEqual(@as(u64, 512), counter.value.load(.acquire));
}

test "cpu_helps_blocking opt-in lets default workers drain blocking lane" {
    // Slice L3: with cpu_helps_blocking = true, a default worker will fall back
    // to the blocking lane after finding its own lane empty. Use a single
    // blocking worker with a long-sleeping task blocking it, and submit many
    // fast blocking tasks — without CPU help they'd serialize behind the
    // sleeper; with CPU help, default workers drain them in parallel.
    var pool = try thread_pool.ThreadPool.init(std.testing.allocator, .{
        .min_threads = 3,
        .max_threads = 3,
        .queue_capacity = 1024,
        .blocking_queue_capacity = 256,
        .local_queue_capacity = 64,
        .scheduler_variant = .lane_extension,
        .allow_blocking_lane = true,
        .blocking_workers = 1,
        .cpu_helps_blocking = true,
        .worker_scratch_cap_bytes = 1024,
    });
    defer pool.deinit();

    var wg = pool.waitGroup();
    var counter = common.Counter{};

    // Wedge the blocking worker on a long sleep.
    var sleeper = common.SleepTaskContext{ .counter = &counter, .sleep_ns = 200 * std.time.ns_per_ms };
    _ = try pool.submit(common.sleepTask, @ptrCast(&sleeper), .{ .wait_group = &wg, .lane = .blocking });

    // Flood the blocking lane with fast work. Default workers must help drain.
    for (0..128) |_| {
        _ = try pool.submit(common.counterTask, @ptrCast(&counter), .{ .wait_group = &wg, .lane = .blocking });
    }

    const start = thread_pool.clock.nanoTimestamp();
    wg.wait();
    const elapsed_ns: u64 = @intCast(thread_pool.clock.nanoTimestamp() - start);

    try std.testing.expectEqual(@as(u64, 129), counter.value.load(.acquire));
    // The 128 fast blocking tasks should complete in parallel with the sleeper,
    // not serialized after it. Bound generously: 2x the sleeper (400ms) is
    // still well under the ~25s it would take if every fast task queued
    // behind the sleeper at 200ms each on a single blocking worker.
    try std.testing.expect(elapsed_ns < 400 * std.time.ns_per_ms);
}

test "watchdog detects stalled default-lane task" {
    // Slice L4a: with watchdog_interval_ns > 0 and blocking_promotion_timeout_ns
    // shorter than a deliberately-wedged task, the watchdog must observe the
    // stall and increment counters.watchdog_stalls_detected at least once.
    var pool = try thread_pool.ThreadPool.init(std.testing.allocator, .{
        .min_threads = 2,
        .max_threads = 2,
        .queue_capacity = 64,
        .local_queue_capacity = 16,
        .scheduler_variant = .work_stealing,
        .watchdog_interval_ns = 5 * std.time.ns_per_ms,
        .blocking_promotion_timeout_ns = 10 * std.time.ns_per_ms,
        .max_overflow_workers = 1,
        .worker_scratch_cap_bytes = 512,
    });
    defer pool.deinit();

    var wg = pool.waitGroup();
    var counter = common.Counter{};
    // Task runs for 100ms — well above the 10ms stall threshold, giving the
    // watchdog (5ms interval) many opportunities to observe it.
    var sleeper = common.SleepTaskContext{ .counter = &counter, .sleep_ns = 100 * std.time.ns_per_ms };
    _ = try pool.submit(common.sleepTask, @ptrCast(&sleeper), .{ .wait_group = &wg });

    wg.wait();

    const stats = pool.statsSnapshot();
    try std.testing.expect(stats.watchdog_stalls_detected >= 1);
}

test "watchdog disabled produces zero stall counts" {
    // Slice L4a: with watchdog_interval_ns = 0 (default), no watchdog thread
    // is spawned and the stall counter stays at zero regardless of task
    // duration. Guards the no-effect invariant.
    var pool = try thread_pool.ThreadPool.init(std.testing.allocator, .{
        .min_threads = 2,
        .max_threads = 2,
        .queue_capacity = 64,
        .local_queue_capacity = 16,
        .scheduler_variant = .work_stealing,
        .worker_scratch_cap_bytes = 512,
    });
    defer pool.deinit();

    var wg = pool.waitGroup();
    var counter = common.Counter{};
    var sleeper = common.SleepTaskContext{ .counter = &counter, .sleep_ns = 50 * std.time.ns_per_ms };
    _ = try pool.submit(common.sleepTask, @ptrCast(&sleeper), .{ .wait_group = &wg });
    wg.wait();

    const stats = pool.statsSnapshot();
    try std.testing.expectEqual(@as(u64, 0), stats.watchdog_stalls_detected);
}

test "default workers ignore blocking lane without cpu_helps_blocking" {
    // Slice L3: with cpu_helps_blocking = false (default), default workers must
    // NOT touch the blocking lane. Verify that with the blocking worker wedged
    // on a long task, queued blocking tasks wait for the blocking worker to
    // free up rather than being picked up by default workers.
    var pool = try thread_pool.ThreadPool.init(std.testing.allocator, .{
        .min_threads = 3,
        .max_threads = 3,
        .queue_capacity = 1024,
        .blocking_queue_capacity = 64,
        .local_queue_capacity = 64,
        .scheduler_variant = .lane_extension,
        .allow_blocking_lane = true,
        .blocking_workers = 1,
        // cpu_helps_blocking defaults to false
        .worker_scratch_cap_bytes = 1024,
    });
    defer pool.deinit();

    var wg = pool.waitGroup();
    var counter = common.Counter{};

    // Short sleeper (50ms) to wedge the blocking worker briefly.
    var sleeper = common.SleepTaskContext{ .counter = &counter, .sleep_ns = 50 * std.time.ns_per_ms };
    _ = try pool.submit(common.sleepTask, @ptrCast(&sleeper), .{ .wait_group = &wg, .lane = .blocking });

    // A handful of fast blocking tasks queued behind the sleeper.
    for (0..8) |_| {
        _ = try pool.submit(common.counterTask, @ptrCast(&counter), .{ .wait_group = &wg, .lane = .blocking });
    }

    // Default-lane work in parallel, should finish quickly.
    for (0..256) |_| {
        _ = try pool.submit(common.counterTask, @ptrCast(&counter), .{ .wait_group = &wg });
    }

    wg.wait();
    // 1 sleeper + 8 blocking counters + 256 default counters = 265.
    try std.testing.expectEqual(@as(u64, 265), counter.value.load(.acquire));
}

test "overflow worker spawned when default workers stall" {
    var pool = try thread_pool.ThreadPool.init(std.testing.allocator, .{
        .min_threads = 2,
        .max_threads = 2,
        .queue_capacity = 64,
        .local_queue_capacity = 16,
        .scheduler_variant = .work_stealing,
        .watchdog_interval_ns = 5 * std.time.ns_per_ms,
        .blocking_promotion_timeout_ns = 10 * std.time.ns_per_ms,
        .max_overflow_workers = 1,
        .worker_scratch_cap_bytes = 512,
    });
    defer pool.deinit();

    var wg = pool.waitGroup();
    var counter = common.Counter{};

    var gate1 = common.GateTaskContext{ .counter = &counter };
    var gate2 = common.GateTaskContext{ .counter = &counter };
    _ = try pool.submit(common.gateTask, @ptrCast(&gate1), .{ .wait_group = &wg });
    _ = try pool.submit(common.gateTask, @ptrCast(&gate2), .{ .wait_group = &wg });
    try waitUntilGateStarted(&gate1);
    try waitUntilGateStarted(&gate2);

    for (0..16) |_| {
        _ = try pool.submit(common.counterTask, @ptrCast(&counter), .{ .wait_group = &wg });
    }

    thread_pool.clock.sleep(50 * std.time.ns_per_ms);

    const stats = pool.statsSnapshot();
    try std.testing.expect(stats.overflow_spawns >= 1);

    gate1.release.store(true, .release);
    gate2.release.store(true, .release);
    wg.wait();

    try std.testing.expectEqual(@as(u64, 18), counter.value.load(.acquire));
}

test "overflow worker self-retires after idle period" {
    var pool = try thread_pool.ThreadPool.init(std.testing.allocator, .{
        .min_threads = 2,
        .max_threads = 2,
        .queue_capacity = 64,
        .local_queue_capacity = 16,
        .scheduler_variant = .work_stealing,
        .watchdog_interval_ns = 5 * std.time.ns_per_ms,
        .blocking_promotion_timeout_ns = 10 * std.time.ns_per_ms,
        .max_overflow_workers = 1,
        .worker_scratch_cap_bytes = 512,
    });
    defer pool.deinit();

    var wg = pool.waitGroup();
    var counter = common.Counter{};

    var gate1 = common.GateTaskContext{ .counter = &counter };
    var gate2 = common.GateTaskContext{ .counter = &counter };
    _ = try pool.submit(common.gateTask, @ptrCast(&gate1), .{ .wait_group = &wg });
    _ = try pool.submit(common.gateTask, @ptrCast(&gate2), .{ .wait_group = &wg });
    try waitUntilGateStarted(&gate1);
    try waitUntilGateStarted(&gate2);

    for (0..4) |_| {
        _ = try pool.submit(common.counterTask, @ptrCast(&counter), .{ .wait_group = &wg });
    }

    thread_pool.clock.sleep(30 * std.time.ns_per_ms);
    const stats1 = pool.statsSnapshot();
    try std.testing.expect(stats1.overflow_spawns >= 1);

    gate1.release.store(true, .release);
    gate2.release.store(true, .release);
    wg.wait();

    thread_pool.clock.sleep(40 * std.time.ns_per_ms);

    const stats2 = pool.statsSnapshot();
    try std.testing.expect(stats2.overflow_retires >= 1);
    try std.testing.expectEqual(@as(u64, 0), stats2.overflow_active);
}

test "max_overflow_workers = 0 produces no overflow activity" {
    var pool = try thread_pool.ThreadPool.init(std.testing.allocator, .{
        .min_threads = 2,
        .max_threads = 2,
        .queue_capacity = 64,
        .local_queue_capacity = 16,
        .scheduler_variant = .work_stealing,
        .worker_scratch_cap_bytes = 512,
    });
    defer pool.deinit();

    var wg = pool.waitGroup();
    var counter = common.Counter{};
    var sleeper = common.SleepTaskContext{ .counter = &counter, .sleep_ns = 50 * std.time.ns_per_ms };
    _ = try pool.submit(common.sleepTask, @ptrCast(&sleeper), .{ .wait_group = &wg });
    wg.wait();

    const stats = pool.statsSnapshot();
    try std.testing.expectEqual(@as(u64, 0), stats.overflow_spawns);
    try std.testing.expectEqual(@as(u64, 0), stats.overflow_retires);
    try std.testing.expectEqual(@as(u64, 0), stats.overflow_active);
}
