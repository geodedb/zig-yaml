const std = @import("std");
const builtin = @import("builtin");
const thread_pool = @import("thread_pool");
const clock = thread_pool.clock;
const common = @import("common.zig");

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const cpu_count = std.Thread.getCpuCount() catch 4;
    const output = try common.parseOutputArg(allocator, init.minimal.args);
    const workers = @max(@min(cpu_count, 16), 4);

    const specs = [_]common.ScenarioSpec{
        .{
            .name = "cpu_work_10us",
            .task_count = 10_000,
            .worker_count = workers,
            .submitter_count = 1,
            .queue_capacity = 2048,
            .local_queue_capacity = 256,
            .sleep_ns = 10_000,
            .scratch_bytes = 4096,
            .register_submitters = true,
        },
        .{
            .name = "cpu_work_100us",
            .task_count = 2_000,
            .worker_count = workers,
            .submitter_count = 1,
            .queue_capacity = 1024,
            .local_queue_capacity = 256,
            .sleep_ns = 100_000,
            .scratch_bytes = 16384,
            .register_submitters = true,
        },
        .{
            .name = "contended_cpu_10us",
            .task_count = 10_000,
            .worker_count = workers,
            .submitter_count = 4,
            .queue_capacity = 2048,
            .local_queue_capacity = 256,
            .sleep_ns = 10_000,
            .scratch_bytes = 4096,
            .register_submitters = true,
        },
        .{
            .name = "nested_fanout_4x",
            .task_count = 2_000,
            .worker_count = workers,
            .submitter_count = 2,
            .queue_capacity = 4096,
            .local_queue_capacity = 256,
            .nested_children = 4,
            .register_submitters = true,
        },
        .{
            .name = "burst_drain_burst",
            .task_count = 4_000,
            .worker_count = workers,
            .submitter_count = 1,
            .queue_capacity = 1024,
            .local_queue_capacity = 256,
            .idle_gap_ns = 10 * std.time.ns_per_ms,
            .sleep_ns = 50_000,
            .register_submitters = true,
        },
    };
    const variants = [_]thread_pool.SchedulerVariant{.work_stealing};

    try common.runScenarios(allocator, init.io, &specs, &variants, output);

    try runMixedWorkload(allocator, workers, output);
    try runLaneIsolation(allocator, workers, output);
}

fn runMixedWorkload(allocator: std.mem.Allocator, workers: usize, output_path: ?[]const u8) !void {
    const task_count: usize = 5_000;
    const slow_pct: usize = 20;

    var pool = try thread_pool.ThreadPool.init(allocator, .{
        .min_threads = workers,
        .max_threads = workers,
        .queue_capacity = 2048,
        .local_queue_capacity = 256,
        .scheduler_variant = .work_stealing,
        .max_submitter_queues = 1,
        .submitter_queue_capacity = 1024,
    });
    defer pool.deinit();

    try common.warmup(&pool, @max(task_count / 8, 32), 4096);

    const TaskCtx = struct {
        counter: *common.Counter,
        completed_at_ns: *u64,
        is_slow: bool,
    };

    var counter = common.Counter{};
    var completed_at = try allocator.alloc(u64, task_count);
    defer allocator.free(completed_at);
    @memset(completed_at, 0);
    var submitted_at = try allocator.alloc(u64, task_count);
    defer allocator.free(submitted_at);

    const task_ctxs = try allocator.alloc(TaskCtx, task_count);
    defer allocator.free(task_ctxs);

    var prng = std.Random.DefaultPrng.init(0xDEAD);
    const rng = prng.random();
    for (task_ctxs, 0..) |*ctx, i| {
        ctx.* = .{
            .counter = &counter,
            .completed_at_ns = &completed_at[i],
            .is_slow = rng.intRangeAtMost(u8, 1, 100) <= slow_pct,
        };
    }

    const mixedTask = struct {
        fn run(raw_ctx: *anyopaque, runtime: *thread_pool.TaskContext) void {
            _ = runtime;
            const ctx: *TaskCtx = @ptrCast(@alignCast(raw_ctx));
            if (ctx.is_slow) {
                clock.sleep(1_000_000);
            }
            _ = ctx.counter.value.fetchAdd(1, .monotonic);
            ctx.completed_at_ns.* = nowNs();
        }
    }.run;

    const mixed_slot_opt: ?usize = pool.registerSubmitter() catch null;
    defer if (mixed_slot_opt) |slot| pool.releaseSubmitter(slot);

    var wg = pool.waitGroup();
    const wall_start = nowNs();
    for (task_ctxs, 0..) |*ctx, i| {
        submitted_at[i] = nowNs();
        _ = try pool.submit(mixedTask, @ptrCast(ctx), .{
            .wait_group = &wg,
            .backpressure = .block,
        });
    }
    wg.wait();
    const wall_end = nowNs();

    var fast_latencies: std.ArrayList(u64) = .empty;
    defer fast_latencies.deinit(allocator);
    var slow_latencies: std.ArrayList(u64) = .empty;
    defer slow_latencies.deinit(allocator);

    for (task_ctxs, 0..) |ctx, i| {
        const latency = completed_at[i] -| submitted_at[i];
        if (ctx.is_slow) {
            try slow_latencies.append(allocator, latency);
        } else {
            try fast_latencies.append(allocator, latency);
        }
    }

    const fast_summary = common.summarizeLatencies(fast_latencies.items);
    const slow_summary = common.summarizeLatencies(slow_latencies.items);

    const throughput = @as(f64, @floatFromInt(task_count)) / (@as(f64, @floatFromInt(wall_end - wall_start)) / std.time.ns_per_s);

    std.debug.print(
        "mixed_fast_slow  throughput={d:.0} ops/s  fast_count={d}  slow_count={d}\n" ++
            "  fast p50={d}us p95={d}us p99={d}us\n" ++
            "  slow p50={d}us p95={d}us p99={d}us\n",
        .{
            throughput,
            fast_latencies.items.len,
            slow_latencies.items.len,
            fast_summary.p50_ns / 1000,
            fast_summary.p95_ns / 1000,
            fast_summary.p99_ns / 1000,
            slow_summary.p50_ns / 1000,
            slow_summary.p95_ns / 1000,
            slow_summary.p99_ns / 1000,
        },
    );

    _ = output_path;
}

fn runLaneIsolation(allocator: std.mem.Allocator, workers: usize, output_path: ?[]const u8) !void {
    const blocking_workers: u32 = @intCast(@max(workers / 4, 2));
    const fast_count: usize = 5_000;
    const slow_count: usize = 200;

    var pool = try thread_pool.ThreadPool.init(allocator, .{
        .min_threads = workers,
        .max_threads = workers,
        .queue_capacity = 4096,
        .local_queue_capacity = 256,
        .scheduler_variant = .work_stealing,
        .allow_blocking_lane = true,
        .blocking_workers = blocking_workers,
        .max_submitter_queues = 1,
        .submitter_queue_capacity = 1024,
    });
    defer pool.deinit();

    try common.warmup(&pool, 256, 0);

    const LaneCtx = struct {
        counter: *common.Counter,
        completed_at_ns: *u64,
    };

    var counter = common.Counter{};
    var fast_completed = try allocator.alloc(u64, fast_count);
    defer allocator.free(fast_completed);
    @memset(fast_completed, 0);
    var fast_submitted = try allocator.alloc(u64, fast_count);
    defer allocator.free(fast_submitted);
    var slow_completed = try allocator.alloc(u64, slow_count);
    defer allocator.free(slow_completed);
    @memset(slow_completed, 0);
    const slow_submitted = try allocator.alloc(u64, slow_count);
    defer allocator.free(slow_submitted);

    const fast_ctxs = try allocator.alloc(LaneCtx, fast_count);
    defer allocator.free(fast_ctxs);
    const slow_ctxs = try allocator.alloc(LaneCtx, slow_count);
    defer allocator.free(slow_ctxs);

    for (fast_ctxs, 0..) |*ctx, i| {
        ctx.* = .{ .counter = &counter, .completed_at_ns = &fast_completed[i] };
    }
    for (slow_ctxs, 0..) |*ctx, i| {
        ctx.* = .{ .counter = &counter, .completed_at_ns = &slow_completed[i] };
    }

    const fastTask = struct {
        fn run(raw_ctx: *anyopaque, runtime: *thread_pool.TaskContext) void {
            _ = runtime;
            const ctx: *LaneCtx = @ptrCast(@alignCast(raw_ctx));
            _ = ctx.counter.value.fetchAdd(1, .monotonic);
            ctx.completed_at_ns.* = nowNs();
        }
    }.run;

    const slowTask = struct {
        fn run(raw_ctx: *anyopaque, runtime: *thread_pool.TaskContext) void {
            _ = runtime;
            const ctx: *LaneCtx = @ptrCast(@alignCast(raw_ctx));
            clock.sleep(5_000_000);
            _ = ctx.counter.value.fetchAdd(1, .monotonic);
            ctx.completed_at_ns.* = nowNs();
        }
    }.run;

    var wg = pool.waitGroup();
    const wall_start = nowNs();

    var slow_thread = try std.Thread.spawn(.{}, struct {
        fn run(p: *thread_pool.ThreadPool, ctxs: []LaneCtx, submitted: []u64, w: *thread_pool.WaitGroup) void {
            for (ctxs, 0..) |*ctx, i| {
                submitted[i] = nowNs();
                _ = p.submit(slowTask, @ptrCast(ctx), .{
                    .wait_group = w,
                    .backpressure = .block,
                    .lane = .blocking,
                }) catch return;
            }
        }
    }.run, .{ &pool, slow_ctxs, slow_submitted, &wg });

    // Default-lane producer (main thread) registers to exercise the per-
    // submitter SPSC queue path. The blocking-lane slow_thread above does
    // not register — submitter_queues are consulted only on the default-
    // lane submit path in pool.zig, so registration there is a no-op.
    const lane_slot_opt: ?usize = pool.registerSubmitter() catch null;
    defer if (lane_slot_opt) |slot| pool.releaseSubmitter(slot);

    for (fast_ctxs, 0..) |*ctx, i| {
        fast_submitted[i] = nowNs();
        _ = try pool.submit(fastTask, @ptrCast(ctx), .{
            .wait_group = &wg,
            .backpressure = .block,
            .lane = .default,
        });
    }

    slow_thread.join();
    wg.wait();
    const wall_end = nowNs();

    const fast_latencies = try allocator.alloc(u64, fast_count);
    defer allocator.free(fast_latencies);
    for (fast_latencies, 0..) |*lat, i| {
        lat.* = fast_completed[i] -| fast_submitted[i];
    }
    const slow_latencies = try allocator.alloc(u64, slow_count);
    defer allocator.free(slow_latencies);
    for (slow_latencies, 0..) |*lat, i| {
        lat.* = slow_completed[i] -| slow_submitted[i];
    }

    const fast_summary = common.summarizeLatencies(fast_latencies);
    const slow_summary = common.summarizeLatencies(slow_latencies);
    const throughput = @as(f64, @floatFromInt(fast_count + slow_count)) / (@as(f64, @floatFromInt(wall_end - wall_start)) / std.time.ns_per_s);

    std.debug.print(
        "lane_isolation  throughput={d:.0} ops/s  blocking_workers={d}\n" ++
            "  default lane p50={d}us p95={d}us p99={d}us  (n={d})\n" ++
            "  blocking lane p50={d}us p95={d}us p99={d}us  (n={d})\n",
        .{
            throughput,
            blocking_workers,
            fast_summary.p50_ns / 1000,
            fast_summary.p95_ns / 1000,
            fast_summary.p99_ns / 1000,
            fast_count,
            slow_summary.p50_ns / 1000,
            slow_summary.p95_ns / 1000,
            slow_summary.p99_ns / 1000,
            slow_count,
        },
    );

    _ = output_path;
}

fn nowNs() u64 {
    const ts = clock.nanoTimestamp();
    return if (ts < 0) 0 else @as(u64, @intCast(ts));
}
