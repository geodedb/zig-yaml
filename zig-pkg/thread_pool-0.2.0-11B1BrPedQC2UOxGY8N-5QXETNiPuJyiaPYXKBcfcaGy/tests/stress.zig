const std = @import("std");
const thread_pool = @import("thread_pool");
const common = @import("common.zig");

comptime {
    _ = @import("stress/double_dequeue_race.zig");
}

test "stress high-volume small-task increments in bounded waves" {
    var pool = try thread_pool.ThreadPool.init(std.testing.allocator, .{
        .min_threads = 4,
        .max_threads = 4,
        .queue_capacity = 2048,
        .local_queue_capacity = 256,
        .inject_batch_size = 16,
        .scheduler_variant = .work_stealing,
        .worker_scratch_cap_bytes = 4096,
        .idle_park_after_ns = 50_000,
        .idle_purge_after_ns = 250_000,
    });
    defer pool.deinit();

    var counter = common.Counter{};
    var wave: usize = 0;
    while (wave < 5) : (wave += 1) {
        var wg = pool.waitGroup();
        for (0..1_000) |_| {
            _ = try pool.submit(common.counterTask, @ptrCast(&counter), .{ .wait_group = &wg });
        }
        wg.wait();
    }

    try std.testing.expectEqual(@as(u64, 5_000), counter.value.load(.acquire));
}

test "repeated churn returns to a bounded steady state after purge" {
    var pool = try thread_pool.ThreadPool.init(std.testing.allocator, .{
        .min_threads = 2,
        .max_threads = 2,
        .queue_capacity = 512,
        .local_queue_capacity = 64,
        .inject_batch_size = 8,
        .scheduler_variant = .work_stealing,
        .worker_scratch_cap_bytes = 8192,
        .idle_park_after_ns = 50_000,
        .idle_purge_after_ns = 100_000,
    });
    defer pool.deinit();

    var counter = common.Counter{};
    var scratch_ctx = common.ScratchTaskContext{ .counter = &counter, .bytes = 2048 };
    var baseline_live: ?u64 = null;

    for (0..40) |_| {
        var wg = pool.waitGroup();
        for (0..128) |_| {
            _ = try pool.submit(common.scratchTask, @ptrCast(&scratch_ctx), .{ .wait_group = &wg });
        }
        wg.wait();
        try pool.purgeWorkerCaches();
        const stats = pool.statsSnapshot();
        if (baseline_live == null) baseline_live = stats.live_bytes;
        try std.testing.expect(stats.live_bytes <= baseline_live.? + 64 * 1024);
    }
}

test "park handshake: no lost wakeups under submit-while-parking race" {
    var pool = try thread_pool.ThreadPool.init(std.testing.allocator, .{
        .min_threads = 2,
        .max_threads = 2,
        .queue_capacity = 4096,
        .local_queue_capacity = 256,
        .scheduler_variant = .work_stealing,
        .idle_park_after_ns = 50_000,
        .spin_before_park_iters = 4,
    });
    defer pool.deinit();

    var counter = common.Counter{};
    const total: u64 = 200_000;

    const Submitter = struct {
        fn run(p: *thread_pool.ThreadPool, c: *common.Counter, n: u64) void {
            var i: u64 = 0;
            while (i < n) : (i += 1) {
                // Retry on transient QueueFull from rapid submit bursts.
                while (true) {
                    _ = p.submit(common.counterTask, @ptrCast(c), .{}) catch {
                        thread_pool.clock.sleep(1_000);
                        continue;
                    };
                    break;
                }
            }
        }
    };

    const t1 = try std.Thread.spawn(.{}, Submitter.run, .{ &pool, &counter, total / 2 });
    const t2 = try std.Thread.spawn(.{}, Submitter.run, .{ &pool, &counter, total / 2 });
    t1.join();
    t2.join();

    // Wait up to 5s for completion. If any wakeup is lost, the counter stalls.
    const deadline = thread_pool.clock.nanoTimestamp() + 5 * std.time.ns_per_s;
    while (thread_pool.clock.nanoTimestamp() < deadline) {
        if (counter.value.load(.acquire) >= total) break;
        thread_pool.clock.sleep(1_000_000);
    }

    try std.testing.expectEqual(total, counter.value.load(.acquire));
}

test "RingQueue: 1 owner + 4 stealers — no duplicates, no losses" {
    const allocator = std.testing.allocator;
    const N: u32 = 100_000;
    const M_stealers: u32 = 4;

    var q = try thread_pool.RingQueue(u32).init(allocator, 1024);
    defer q.deinit();

    const seen = try allocator.alloc(std.atomic.Value(u8), N);
    defer allocator.free(seen);
    for (seen) |*s| s.* = std.atomic.Value(u8).init(0);

    var pushed = std.atomic.Value(u32).init(0);
    var stolen = std.atomic.Value(u32).init(0);
    var popped = std.atomic.Value(u32).init(0);

    const Owner = struct {
        fn run(
            ptr_q: *thread_pool.RingQueue(u32),
            pushed_ctr: *std.atomic.Value(u32),
            popped_ctr: *std.atomic.Value(u32),
            seen_arr: []std.atomic.Value(u8),
            total: u32,
        ) void {
            var i: u32 = 0;
            while (i < total) {
                if (ptr_q.tryPush(i)) {
                    _ = pushed_ctr.fetchAdd(1, .release);
                    i += 1;
                } else {
                    // Queue full — drain some locally to make room.
                    while (ptr_q.pop()) |v| {
                        const old = seen_arr[v].fetchAdd(1, .release);
                        std.debug.assert(old == 0);
                        _ = popped_ctr.fetchAdd(1, .release);
                    }
                }
            }
            // Final drain.
            while (ptr_q.pop()) |v| {
                const old = seen_arr[v].fetchAdd(1, .release);
                std.debug.assert(old == 0);
                _ = popped_ctr.fetchAdd(1, .release);
            }
        }
    };

    const Stealer = struct {
        fn run(
            ptr_q: *thread_pool.RingQueue(u32),
            stolen_ctr: *std.atomic.Value(u32),
            seen_arr: []std.atomic.Value(u8),
            done: *std.atomic.Value(u8),
        ) void {
            var buf: [32]u32 = undefined;
            while (done.load(.acquire) == 0) {
                const n = ptr_q.stealHalf(buf[0..]);
                for (buf[0..n]) |v| {
                    const old = seen_arr[v].fetchAdd(1, .release);
                    std.debug.assert(old == 0);
                }
                _ = stolen_ctr.fetchAdd(@intCast(n), .release);
            }
            // Final drain pass after owner signals done.
            var buf2: [32]u32 = undefined;
            while (true) {
                const n = ptr_q.stealHalf(buf2[0..]);
                if (n == 0) break;
                for (buf2[0..n]) |v| {
                    const old = seen_arr[v].fetchAdd(1, .release);
                    std.debug.assert(old == 0);
                }
                _ = stolen_ctr.fetchAdd(@intCast(n), .release);
            }
        }
    };

    var done = std.atomic.Value(u8).init(0);
    var threads: [M_stealers]std.Thread = undefined;
    for (&threads) |*t| {
        t.* = try std.Thread.spawn(.{}, Stealer.run, .{ &q, &stolen, seen, &done });
    }
    const owner = try std.Thread.spawn(.{}, Owner.run, .{ &q, &pushed, &popped, seen, N });
    owner.join();
    done.store(1, .release);
    for (&threads) |*t| t.join();

    try std.testing.expectEqual(N, pushed.load(.acquire));
    try std.testing.expectEqual(N, popped.load(.acquire) + stolen.load(.acquire));
    for (seen) |*s| try std.testing.expectEqual(@as(u8, 1), s.load(.acquire));
}

test "coalesced wake: submitter never stalls forever on backpressure" {
    // Small queue + 4 submitters + 2 workers: submitters must block
    // frequently. With wake_coalesce_batch=32 there are more missed
    // per-release signals, but the timedWait ceiling bounds stalls.
    var pool = try thread_pool.ThreadPool.init(std.testing.allocator, .{
        .min_threads = 2,
        .max_threads = 2,
        .queue_capacity = 256, // small — force backpressure
        .local_queue_capacity = 64,
        .scheduler_variant = .work_stealing,
        .wake_coalesce_batch = 32,
    });
    defer pool.deinit();

    var counter = common.Counter{};
    const total_per_submitter: u64 = 5_000;
    const n_submitters: u32 = 4;
    const total = total_per_submitter * n_submitters;

    const Submitter = struct {
        fn run(p: *thread_pool.ThreadPool, c: *common.Counter, n: u64) void {
            var i: u64 = 0;
            while (i < n) : (i += 1) {
                _ = p.submit(common.counterTask, @ptrCast(c), .{
                    .backpressure = .block_with_timeout,
                    .timeout_ns = 5 * std.time.ns_per_s,
                }) catch break;
            }
        }
    };

    var threads: [n_submitters]std.Thread = undefined;
    for (&threads) |*t| {
        t.* = try std.Thread.spawn(.{}, Submitter.run, .{ &pool, &counter, total_per_submitter });
    }
    for (&threads) |*t| t.join();
    try pool.shutdown(.drain, null);

    try std.testing.expectEqual(total, counter.value.load(.acquire));
}

fn runQueueKindScenario(kind: thread_pool.QueueKind, total: u64) !void {
    var pool = try thread_pool.ThreadPool.init(std.testing.allocator, .{
        .min_threads = 4,
        .max_threads = 4,
        .queue_capacity = 4096,
        .local_queue_capacity = 256,
        .queue_kind = kind,
        .scheduler_variant = .work_stealing,
        .steal_batch_size = if (kind == .ring) 8 else 1,
    });
    defer pool.deinit();

    var counter = common.Counter{};
    var wg = pool.waitGroup();
    var i: u64 = 0;
    while (i < total) : (i += 1) {
        while (true) {
            _ = pool.submit(common.counterTask, @ptrCast(&counter), .{ .wait_group = &wg }) catch {
                thread_pool.clock.sleep(1_000);
                continue;
            };
            break;
        }
    }
    wg.wait();
    try std.testing.expectEqual(total, counter.value.load(.acquire));
}

test "queue_kind matrix: chase_lev executes all submitted tasks" {
    try runQueueKindScenario(.chase_lev, 50_000);
}

test "queue_kind matrix: ring executes all submitted tasks" {
    try runQueueKindScenario(.ring, 50_000);
}

test "LIFO slot: nested-submit storm with 4 workers, no lost tasks" {
    var pool = try thread_pool.ThreadPool.init(std.testing.allocator, .{
        .min_threads = 4,
        .max_threads = 4,
        .queue_capacity = 8192,
        .local_queue_capacity = 256,
        .scheduler_variant = .work_stealing,
        .idle_park_after_ns = 50_000,
        .spin_before_park_iters = 4,
    });
    defer pool.deinit();

    const Nested = struct {
        var inner_counter: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

        fn innerTask(raw_ctx: *anyopaque, runtime: *thread_pool.TaskContext) void {
            _ = raw_ctx;
            _ = runtime;
            _ = inner_counter.fetchAdd(1, .release);
        }
        fn outerTask(raw_ctx: *anyopaque, runtime: *thread_pool.TaskContext) void {
            _ = runtime;
            const p: *thread_pool.ThreadPool = @ptrCast(@alignCast(raw_ctx));
            // Each outer submits 4 inner tasks from worker context — exercises
            // the lifo_slot miss-to-local-ring path (slot holds #1; #2-#4 go to ring).
            var i: u32 = 0;
            while (i < 4) : (i += 1) {
                while (true) {
                    _ = p.submit(innerTask, @ptrCast(p), .{}) catch {
                        thread_pool.clock.sleep(1_000);
                        continue;
                    };
                    break;
                }
            }
        }
    };

    Nested.inner_counter.store(0, .release);

    // NOTE: This test previously used 25k outer × 4 inner = 125k tasks through
    // an 8192-slot descriptor pool, which creates a deadlock window: when ~2k
    // outer tasks are in-flight, their pending inner submits need 4× as many
    // descriptors as are available, so inner submits get TaskPoolExhausted and
    // the outer task can't complete. 1k outer × 4 inner = 5k total descriptors
    // fits comfortably in 8192 and exercises the LIFO hot path without the
    // deadlock. The design lesson: nested-fanout tests must account for the
    // descriptor pool as a finite resource.
    const outer_total: u64 = 1_000;
    var wg = pool.waitGroup();
    var i: u64 = 0;
    while (i < outer_total) : (i += 1) {
        while (true) {
            _ = pool.submit(Nested.outerTask, @ptrCast(&pool), .{ .wait_group = &wg }) catch {
                thread_pool.clock.sleep(1_000);
                continue;
            };
            break;
        }
    }
    wg.wait();
    try pool.shutdown(.drain, null); // inner tasks have no wait-group

    try std.testing.expectEqual(outer_total * 4, Nested.inner_counter.load(.acquire));
}

test "backpressure backoff: 4 submitters, queue=256, 2 workers, deadline-bounded" {
    // Repro scenario matching the previous coalesced-wake stress test that
    // hung intermittently. Uses default pool config (no wake_coalesce_batch
    // override) so it exercises whatever the current backpressure impl is —
    // today the condvar path, after the lock-free rewrite the spin-backoff
    // path. In both cases it MUST complete in well under the 30s test
    // timeout. The 5s per-submit deadline is the functional bound we verify.
    var pool = try thread_pool.ThreadPool.init(std.testing.allocator, .{
        .min_threads = 2,
        .max_threads = 2,
        .queue_capacity = 256,
        .local_queue_capacity = 64,
        .scheduler_variant = .work_stealing,
    });
    defer pool.deinit();

    var counter = common.Counter{};
    const total_per_submitter: u64 = 5_000;
    const n_submitters: u32 = 4;
    const total = total_per_submitter * n_submitters;

    const Submitter = struct {
        fn run(p: *thread_pool.ThreadPool, c: *common.Counter, n: u64) void {
            var i: u64 = 0;
            while (i < n) : (i += 1) {
                _ = p.submit(common.counterTask, @ptrCast(c), .{
                    .backpressure = .block_with_timeout,
                    .timeout_ns = 5 * std.time.ns_per_s,
                }) catch break;
            }
        }
    };

    const start_ns = thread_pool.clock.nanoTimestamp();
    var threads: [n_submitters]std.Thread = undefined;
    for (&threads) |*t| {
        t.* = try std.Thread.spawn(.{}, Submitter.run, .{ &pool, &counter, total_per_submitter });
    }
    for (&threads) |*t| t.join();
    try pool.shutdown(.drain, null);
    const elapsed_ns = thread_pool.clock.nanoTimestamp() - start_ns;

    // Hang detection first: if we exceeded the wall-time bound, that's the
    // primary signal regardless of counter state.
    try std.testing.expect(elapsed_ns < 10 * std.time.ns_per_s);
    try std.testing.expectEqual(total, counter.value.load(.acquire));
}

test "steal-scan bitmap: wide-pool flood with cpu-count workers" {
    // Exercises the scheduler under high-worker-count pressure:
    // cpu_count (clamped to 64) workers, single submitter, 200k tasks.
    // Primary goal: hang/correctness regression guard.
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
                thread_pool.clock.sleep(1_000);
                continue;
            };
            break;
        }
    }
    wg.wait();
    try std.testing.expectEqual(total, counter.value.load(.acquire));
}

test "hot_spinners: slow tasks force parked worker recruitment via propagation" {
    // hot_spinners=1 with slow tasks (100µs each). After the first
    // wake_every_n_tasks=4 tasks complete, the spinner must wake a
    // parked worker. If propagation is broken, all work stays on the
    // single hot-spinner and the test takes ~N × 100µs instead of
    // running in parallel.
    var pool = try thread_pool.ThreadPool.init(std.testing.allocator, .{
        .min_threads = 4,
        .max_threads = 4,
        .queue_capacity = 2048,
        .local_queue_capacity = 128,
        .scheduler_variant = .work_stealing,
        .hot_spinners = 1,
        .wake_every_n_tasks = 4,
        .idle_park_after_ns = 50_000,
    });
    defer pool.deinit();

    const SlowCtx = struct {
        counter: *common.Counter,
        sleep_ns: u64,
        fn run(raw: *anyopaque, rt: *thread_pool.TaskContext) void {
            _ = rt;
            const ctx: *@This() = @ptrCast(@alignCast(raw));
            thread_pool.clock.sleep(ctx.sleep_ns);
            _ = ctx.counter.value.fetchAdd(1, .monotonic);
        }
    };

    var counter = common.Counter{};
    var slow = SlowCtx{ .counter = &counter, .sleep_ns = 100_000 };
    var wg = pool.waitGroup();
    const total: u64 = 80;
    var i: u64 = 0;
    while (i < total) : (i += 1) {
        _ = try pool.submit(SlowCtx.run, @ptrCast(&slow), .{ .wait_group = &wg });
    }
    const start_ns = thread_pool.clock.nanoTimestamp();
    wg.wait();
    const elapsed_ns = thread_pool.clock.nanoTimestamp() - start_ns;

    try std.testing.expectEqual(total, counter.value.load(.acquire));

    // Serial execution on 1 hot-spinner: 80 * 100µs = 8ms.
    // With propagation recruiting 3 parked workers: ~80/4 * 100µs ≈ 2ms.
    // Allow generous 6ms ceiling to absorb noise; serial behavior would
    // clearly exceed this.
    try std.testing.expect(elapsed_ns < 6 * std.time.ns_per_ms);
}

test "hot_spinners: wide-pool flood with cpu-count workers, hot_spinners=1" {
    // High-worker-count stress: cpu_count (clamped to 64) workers,
    // 1 reserved hot-spinner, 200k tasks, single submitter.
    // Regression guard for correctness under realistic flood load.
    const cpu_count = @min(std.Thread.getCpuCount() catch 4, 64);
    if (cpu_count < 2) return; // need at least 2 workers for hot_spinners=1 to leave a non-hot worker

    var pool = try thread_pool.ThreadPool.init(std.testing.allocator, .{
        .min_threads = cpu_count,
        .max_threads = cpu_count,
        .queue_capacity = 4096,
        .local_queue_capacity = 256,
        .scheduler_variant = .work_stealing,
        .hot_spinners = 1,
        .wake_every_n_tasks = 64,
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
                thread_pool.clock.sleep(1_000);
                continue;
            };
            break;
        }
    }
    wg.wait();
    try std.testing.expectEqual(total, counter.value.load(.acquire));
}

test "phase g2: aggressive spin flood - no lost wakeups" {
    // Stress the submit→park handshake with an aggressive spin count.
    // With spin_before_park_iters=4096, many of the 16 workers will be
    // mid-spin at the moment each submit fires the wake. This validates
    // that the handshake still guarantees no lost wakeups after the
    // poll removal in Phase G2.
    var pool = try thread_pool.ThreadPool.init(std.testing.allocator, .{
        .min_threads = 16,
        .max_threads = 16,
        .queue_capacity = 4096,
        .local_queue_capacity = 256,
        .scheduler_variant = .work_stealing,
        .spin_before_park_iters = 4096,
    });
    defer pool.deinit();

    var counter = common.Counter{};
    const total: u64 = 200_000;

    const Submitter = struct {
        fn run(p: *thread_pool.ThreadPool, c: *common.Counter, n: u64) void {
            var i: u64 = 0;
            while (i < n) : (i += 1) {
                // Use blocking submit so queue-full never drops tasks.
                _ = p.submit(common.counterTask, @ptrCast(c), .{
                    .backpressure = .block,
                }) catch |err| switch (err) {
                    error.ShutdownInProgress => return,
                    else => return,
                };
            }
        }
    };

    // Two submitter threads — interleaved submits increase the chance that
    // workers are mid-spin when a wake arrives.
    const t1 = try std.Thread.spawn(.{}, Submitter.run, .{ &pool, &counter, total / 2 });
    const t2 = try std.Thread.spawn(.{}, Submitter.run, .{ &pool, &counter, total / 2 });
    t1.join();
    t2.join();

    // Wait up to 30s for all tasks to complete. A lost wakeup would cause
    // the counter to stall below total.
    const deadline_ns: i128 = 30 * std.time.ns_per_s;
    const start = thread_pool.clock.nanoTimestamp();
    while (thread_pool.clock.nanoTimestamp() - start < deadline_ns) {
        if (counter.value.load(.acquire) >= total) break;
        thread_pool.clock.sleep(1 * std.time.ns_per_ms);
    }

    try std.testing.expectEqual(total, counter.value.load(.acquire));
}
