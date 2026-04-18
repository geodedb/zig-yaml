const std = @import("std");
const builtin = @import("builtin");
const thread_pool = @import("thread_pool");
const clock = thread_pool.clock;

const flood_task_count: usize = 1_000_000;
const contended_task_count: usize = 100_000;
const contended_submitters: usize = 8;
const children_per_parent: usize = 4;

const SampleResult = struct {
    elapsed_ns: u64,
    latency_p50_us: u64 = 0,
    latency_p95_us: u64 = 0,
    latency_p99_us: u64 = 0,
};

const Sample = struct {
    elapsed_ns: u64,
    ops_per_sec: f64,
    latency_p50_us: u64 = 0,
    latency_p95_us: u64 = 0,
    latency_p99_us: u64 = 0,
};

const ScenarioRow = struct {
    scenario_name: []const u8,
    task_count: usize,
    submitter_count: usize,
    worker_count: usize,
    median_elapsed_ns: u64,
    median_ops_per_sec: f64,
    stddev_ops_per_sec: f64,
    sample_count: usize,
    warmup_discarded: usize,
    samples: []Sample,
    latency_p50_us: u64 = 0,
    latency_p95_us: u64 = 0,
    latency_p99_us: u64 = 0,
};

const RuntimeDocument = struct {
    runtime_name: []const u8,
    runtime_version: []const u8,
    source_commit: []const u8,
    generated_at_unix_s: i64,
    host_os: []const u8,
    host_arch: []const u8,
    rows: []ScenarioRow,
};

const Args = struct {
    output_path: ?[]const u8 = null,
    runtime_version: []const u8 = builtin.zig_version_string,
    source_commit: ?[]const u8 = null,
    samples: usize = 7,
    warmup_discard: usize = 1,
};

const NoopCtx = struct {
    marker: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
};

const ContendedSubmitterCtx = struct {
    pool: *thread_pool.ThreadPool,
    wg: *thread_pool.WaitGroup,
    marker: *NoopCtx,
    count: usize,
};

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const args = try parseArgs(allocator, init.minimal.args);
    if (args.warmup_discard >= args.samples) return error.InvalidArguments;

    const worker_count = @max(std.Thread.getCpuCount() catch 1, 1);
    const source_commit = args.source_commit orelse try gitSha(allocator, init.io);

    var rows: std.ArrayList(ScenarioRow) = .empty;
    defer rows.deinit(allocator);

    try rows.append(allocator, try measureScenario(
        allocator,
        "flood_1m",
        flood_task_count,
        1,
        worker_count,
        args.samples,
        args.warmup_discard,
        runFloodSample,
    ));
    try rows.append(allocator, try measureScenario(
        allocator,
        "contended_spawn_8x",
        contended_task_count,
        contended_submitters,
        worker_count,
        args.samples,
        args.warmup_discard,
        runContendedSample,
    ));
    try rows.append(allocator, try measureScenario(
        allocator,
        "cpu_work_10us",
        10_000,
        1,
        worker_count,
        args.samples,
        args.warmup_discard,
        runCpuWork10usSample,
    ));
    try rows.append(allocator, try measureScenario(
        allocator,
        "cpu_work_100us",
        2_000,
        1,
        worker_count,
        args.samples,
        args.warmup_discard,
        runCpuWork100usSample,
    ));
    try rows.append(allocator, try measureScenario(
        allocator,
        "contended_cpu_10us",
        10_000,
        4,
        worker_count,
        args.samples,
        args.warmup_discard,
        runContendedCpu10usSample,
    ));
    try rows.append(allocator, try measureScenario(
        allocator,
        "nested_fanout_4x",
        10_000,
        1,
        worker_count,
        args.samples,
        args.warmup_discard,
        runNestedFanout4xSample,
    ));
    try rows.append(allocator, try measureScenario(
        allocator,
        "burst_drain_burst",
        4_000,
        1,
        worker_count,
        args.samples,
        args.warmup_discard,
        runBurstDrainBurstSample,
    ));
    try rows.append(allocator, try measureScenario(
        allocator,
        "mixed_fast_slow",
        5_000,
        1,
        worker_count,
        args.samples,
        args.warmup_discard,
        runMixedFastSlowSample,
    ));

    const document = RuntimeDocument{
        .runtime_name = "zig_thread_pool",
        .runtime_version = args.runtime_version,
        .source_commit = source_commit,
        .generated_at_unix_s = @as(i64, @intCast(@divTrunc(clock.nanoTimestamp(), std.time.ns_per_s))),
        .host_os = @tagName(builtin.os.tag),
        .host_arch = @tagName(builtin.cpu.arch),
        .rows = try rows.toOwnedSlice(allocator),
    };

    const json = try std.json.Stringify.valueAlloc(allocator, document, .{ .whitespace = .indent_2 });
    defer allocator.free(json);

    if (args.output_path) |path| {
        var file = try std.Io.Dir.cwd().createFile(init.io, path, .{ .truncate = true });
        defer file.close(init.io);
        try file.writeStreamingAll(init.io, json);
        try file.writeStreamingAll(init.io, "\n");
    } else {
        const stdout = std.Io.File.stdout();
        try stdout.writeStreamingAll(init.io, json);
        try stdout.writeStreamingAll(init.io, "\n");
    }
}

fn parseArgs(allocator: std.mem.Allocator, args: std.process.Args) !Args {
    var parsed = Args{};
    const argv = try args.toSlice(allocator);

    var idx: usize = 1;
    while (idx < argv.len) : (idx += 1) {
        const arg = argv[idx];
        if (std.mem.eql(u8, arg, "--output")) {
            idx += 1;
            if (idx >= argv.len) return error.InvalidArguments;
            parsed.output_path = argv[idx];
        } else if (std.mem.eql(u8, arg, "--samples")) {
            idx += 1;
            if (idx >= argv.len) return error.InvalidArguments;
            parsed.samples = try std.fmt.parseInt(usize, argv[idx], 10);
        } else if (std.mem.eql(u8, arg, "--warmup-discard")) {
            idx += 1;
            if (idx >= argv.len) return error.InvalidArguments;
            parsed.warmup_discard = try std.fmt.parseInt(usize, argv[idx], 10);
        } else if (std.mem.eql(u8, arg, "--runtime-version")) {
            idx += 1;
            if (idx >= argv.len) return error.InvalidArguments;
            parsed.runtime_version = argv[idx];
        } else if (std.mem.eql(u8, arg, "--source-commit")) {
            idx += 1;
            if (idx >= argv.len) return error.InvalidArguments;
            parsed.source_commit = argv[idx];
        } else {
            std.debug.print(
                "usage: runtime_compare_zig [--output <path>] [--samples <n>] [--warmup-discard <n>] [--runtime-version <s>] [--source-commit <sha>]\n",
                .{},
            );
            return error.InvalidArguments;
        }
    }

    return parsed;
}

fn measureScenario(
    allocator: std.mem.Allocator,
    scenario_name: []const u8,
    task_count: usize,
    submitter_count: usize,
    worker_count: usize,
    run_count: usize,
    warmup_discard: usize,
    run_once: *const fn (usize) anyerror!SampleResult,
) !ScenarioRow {
    const retained_count = run_count - warmup_discard;
    var all_samples = try allocator.alloc(Sample, run_count);
    defer allocator.free(all_samples);

    for (all_samples) |*sample| {
        const r = try run_once(worker_count);
        const elapsed_s = @as(f64, @floatFromInt(r.elapsed_ns)) / 1e9;
        sample.* = .{
            .elapsed_ns = r.elapsed_ns,
            .ops_per_sec = @as(f64, @floatFromInt(task_count)) / elapsed_s,
            .latency_p50_us = r.latency_p50_us,
            .latency_p95_us = r.latency_p95_us,
            .latency_p99_us = r.latency_p99_us,
        };
    }

    const retained = try allocator.alloc(Sample, retained_count);
    errdefer allocator.free(retained);
    @memcpy(retained, all_samples[warmup_discard..]);

    std.sort.heap(Sample, retained, {}, struct {
        fn lessThan(_: void, lhs: Sample, rhs: Sample) bool {
            return lhs.ops_per_sec < rhs.ops_per_sec;
        }
    }.lessThan);

    const median = retained[retained_count / 2];
    var sum_sq: f64 = 0;
    for (retained) |sample| {
        const delta = sample.ops_per_sec - median.ops_per_sec;
        sum_sq += delta * delta;
    }
    const stddev = std.math.sqrt(sum_sq / @as(f64, @floatFromInt(retained_count)));

    std.debug.print(
        "zig_thread_pool {s} median_ops_per_sec={d:.0} stddev={d:.0} workers={d}",
        .{ scenario_name, median.ops_per_sec, stddev, worker_count },
    );
    if (median.latency_p50_us > 0) {
        std.debug.print(" p50={d}us p95={d}us p99={d}us", .{
            median.latency_p50_us,
            median.latency_p95_us,
            median.latency_p99_us,
        });
    }
    std.debug.print("\n", .{});

    return .{
        .scenario_name = scenario_name,
        .task_count = task_count,
        .submitter_count = submitter_count,
        .worker_count = worker_count,
        .median_elapsed_ns = median.elapsed_ns,
        .median_ops_per_sec = median.ops_per_sec,
        .stddev_ops_per_sec = stddev,
        .sample_count = retained_count,
        .warmup_discarded = warmup_discard,
        .samples = retained,
        .latency_p50_us = median.latency_p50_us,
        .latency_p95_us = median.latency_p95_us,
        .latency_p99_us = median.latency_p99_us,
    };
}

// --- Existing scenarios (no per-task latency) ---

fn runFloodSample(worker_count: usize) !SampleResult {
    var pool = try thread_pool.ThreadPool.init(std.heap.smp_allocator, .{
        .min_threads = worker_count,
        .max_threads = worker_count,
        .queue_capacity = 4096,
        .local_queue_capacity = 256,
        .scheduler_variant = .work_stealing,
    });
    defer pool.deinit();

    var ctx = NoopCtx{};
    var wg = pool.waitGroup();
    const start_ns = clock.nanoTimestamp();
    for (0..flood_task_count) |_| {
        _ = try pool.submit(noopTask, @ptrCast(&ctx), .{
            .wait_group = &wg,
            .backpressure = .block,
        });
    }
    wg.wait();
    return .{ .elapsed_ns = elapsedNsSince(start_ns) };
}

fn runContendedSample(worker_count: usize) !SampleResult {
    var pool = try thread_pool.ThreadPool.init(std.heap.smp_allocator, .{
        .min_threads = worker_count,
        .max_threads = worker_count,
        .queue_capacity = 16384,
        .local_queue_capacity = 256,
        .scheduler_variant = .work_stealing,
        .max_submitter_queues = contended_submitters,
        .submitter_queue_capacity = 4096,
    });
    defer pool.deinit();

    var ctx = NoopCtx{};
    var wg = pool.waitGroup();
    const per_submitter = contended_task_count / contended_submitters;
    var threads: [contended_submitters]std.Thread = undefined;
    var submitters: [contended_submitters]ContendedSubmitterCtx = undefined;

    const start_ns = clock.nanoTimestamp();
    for (0..contended_submitters) |idx| {
        submitters[idx] = .{
            .pool = &pool,
            .wg = &wg,
            .marker = &ctx,
            .count = per_submitter,
        };
        threads[idx] = try std.Thread.spawn(.{}, contendedSubmitterThread, .{&submitters[idx]});
    }
    for (&threads) |*thread| thread.join();
    wg.wait();
    return .{ .elapsed_ns = elapsedNsSince(start_ns) };
}

fn contendedSubmitterThread(ctx: *ContendedSubmitterCtx) void {
    const slot = ctx.pool.registerSubmitter() catch
        @panic("registerSubmitter failed during contended benchmark");
    defer ctx.pool.releaseSubmitter(slot);

    for (0..ctx.count) |_| {
        _ = ctx.pool.submit(noopTask, @ptrCast(ctx.marker), .{
            .wait_group = ctx.wg,
            .backpressure = .block,
        }) catch @panic("submit failed during contended benchmark");
    }
}

fn noopTask(raw_ctx: *anyopaque, runtime: *thread_pool.TaskContext) void {
    _ = runtime;
    const ctx: *NoopCtx = @ptrCast(@alignCast(raw_ctx));
    _ = ctx.marker.fetchAdd(1, .monotonic);
}

// --- Realistic scenarios (with per-task latency) ---

const RealisticTaskCtx = struct {
    completed_at_ns: *u64,
    work_ns: u64,
};

fn realisticTask(raw_ctx: *anyopaque, runtime: *thread_pool.TaskContext) void {
    _ = runtime;
    const ctx: *RealisticTaskCtx = @ptrCast(@alignCast(raw_ctx));
    if (ctx.work_ns > 0) busyWork(ctx.work_ns);
    ctx.completed_at_ns.* = nowNs();
}

const NestedParentCtx = struct {
    pool: *thread_pool.ThreadPool,
    wg: *thread_pool.WaitGroup,
    completed_at_ns: *u64,
    child_ctxs: []RealisticTaskCtx,
    child_submitted_at: []u64,
};

fn nestedParentTask(raw_ctx: *anyopaque, runtime: *thread_pool.TaskContext) void {
    _ = runtime;
    const ctx: *NestedParentCtx = @ptrCast(@alignCast(raw_ctx));
    ctx.completed_at_ns.* = nowNs();

    // One timestamp for the whole batch: submitBatch enqueues all children
    // together, so per-child submit-time spread is < 1 µs. Accepting the
    // minor latency inflation avoids N extra nowNs() calls that would
    // partially negate the batching gain in the tight harness loop.
    var batch: [children_per_parent]thread_pool.BatchTask = undefined;
    std.debug.assert(ctx.child_ctxs.len == batch.len);
    const now = nowNs();
    for (ctx.child_ctxs, ctx.child_submitted_at, 0..) |*child, *sub, i| {
        sub.* = now;
        batch[i] = .{ .task_fn = realisticTask, .ctx = @ptrCast(child) };
    }
    _ = ctx.pool.submitBatch(&batch, .{
        .wait_group = ctx.wg,
        .backpressure = .block,
    }) catch return;
}

fn runCpuWork10usSample(worker_count: usize) !SampleResult {
    return runCpuWorkScenario(worker_count, 10_000, 10_000, 1);
}

fn runCpuWork100usSample(worker_count: usize) !SampleResult {
    return runCpuWorkScenario(worker_count, 2_000, 100_000, 1);
}

fn runContendedCpu10usSample(worker_count: usize) !SampleResult {
    return runCpuWorkScenario(worker_count, 10_000, 10_000, 4);
}

fn runCpuWorkScenario(worker_count: usize, task_count: usize, work_ns: u64, submitters: usize) !SampleResult {
    var pool = try thread_pool.ThreadPool.init(std.heap.smp_allocator, .{
        .min_threads = worker_count,
        .max_threads = worker_count,
        .queue_capacity = 4096,
        .local_queue_capacity = 256,
        .scheduler_variant = .work_stealing,
        .max_submitter_queues = @intCast(@max(submitters, 1)),
        .submitter_queue_capacity = 4096,
    });
    defer pool.deinit();

    var submitted_at = try std.heap.smp_allocator.alloc(u64, task_count);
    defer std.heap.smp_allocator.free(submitted_at);
    var completed_at = try std.heap.smp_allocator.alloc(u64, task_count);
    defer std.heap.smp_allocator.free(completed_at);
    @memset(completed_at, 0);
    const task_ctxs = try std.heap.smp_allocator.alloc(RealisticTaskCtx, task_count);
    defer std.heap.smp_allocator.free(task_ctxs);
    for (task_ctxs, 0..) |*ctx, i| {
        ctx.* = .{ .completed_at_ns = &completed_at[i], .work_ns = work_ns };
    }

    var wg = pool.waitGroup();
    const start_ns = clock.nanoTimestamp();

    if (submitters <= 1) {
        for (task_ctxs, 0..) |*ctx, i| {
            submitted_at[i] = nowNs();
            _ = try pool.submit(realisticTask, @ptrCast(ctx), .{
                .wait_group = &wg,
                .backpressure = .block,
            });
        }
    } else {
        const per_submitter = task_count / submitters;
        var threads = try std.heap.smp_allocator.alloc(std.Thread, submitters);
        defer std.heap.smp_allocator.free(threads);

        const CpuSubmitterCtx = struct {
            p: *thread_pool.ThreadPool,
            w: *thread_pool.WaitGroup,
            tasks: []RealisticTaskCtx,
            sub_at: []u64,
        };
        var sub_ctxs = try std.heap.smp_allocator.alloc(CpuSubmitterCtx, submitters);
        defer std.heap.smp_allocator.free(sub_ctxs);

        for (0..submitters) |s| {
            const off = s * per_submitter;
            sub_ctxs[s] = .{
                .p = &pool,
                .w = &wg,
                .tasks = task_ctxs[off .. off + per_submitter],
                .sub_at = submitted_at[off .. off + per_submitter],
            };
            threads[s] = try std.Thread.spawn(.{}, struct {
                fn run(c: *CpuSubmitterCtx) void {
                    const slot = c.p.registerSubmitter() catch
                        @panic("registerSubmitter failed during contended_cpu benchmark");
                    defer c.p.releaseSubmitter(slot);
                    for (c.tasks, 0..) |*t, j| {
                        c.sub_at[j] = nowNs();
                        _ = c.p.submit(realisticTask, @ptrCast(t), .{
                            .wait_group = c.w,
                            .backpressure = .block,
                        }) catch return;
                    }
                }
            }.run, .{&sub_ctxs[s]});
        }
        for (threads) |t| t.join();
    }

    wg.wait();
    const elapsed_ns = elapsedNsSince(start_ns);

    const latencies = try std.heap.smp_allocator.alloc(u64, task_count);
    defer std.heap.smp_allocator.free(latencies);
    for (latencies, 0..) |*lat, i| {
        lat.* = completed_at[i] -| submitted_at[i];
    }

    return latencyResult(elapsed_ns, latencies);
}

fn runNestedFanout4xSample(worker_count: usize) !SampleResult {
    const parent_count: usize = 2_000;
    const total_tasks: usize = parent_count + parent_count * children_per_parent;

    var pool = try thread_pool.ThreadPool.init(std.heap.smp_allocator, .{
        .min_threads = worker_count,
        .max_threads = worker_count,
        .queue_capacity = 8192,
        .local_queue_capacity = 256,
        .scheduler_variant = .work_stealing,
        .max_submitter_queues = 1,
        .submitter_queue_capacity = 4096,
    });
    defer pool.deinit();

    var parent_submitted = try std.heap.smp_allocator.alloc(u64, parent_count);
    defer std.heap.smp_allocator.free(parent_submitted);
    var parent_completed = try std.heap.smp_allocator.alloc(u64, parent_count);
    defer std.heap.smp_allocator.free(parent_completed);
    @memset(parent_completed, 0);

    var child_submitted = try std.heap.smp_allocator.alloc(u64, parent_count * children_per_parent);
    defer std.heap.smp_allocator.free(child_submitted);
    @memset(child_submitted, 0);
    var child_completed = try std.heap.smp_allocator.alloc(u64, parent_count * children_per_parent);
    defer std.heap.smp_allocator.free(child_completed);
    @memset(child_completed, 0);

    const child_ctxs = try std.heap.smp_allocator.alloc(RealisticTaskCtx, parent_count * children_per_parent);
    defer std.heap.smp_allocator.free(child_ctxs);
    for (child_ctxs, 0..) |*ctx, i| {
        ctx.* = .{ .completed_at_ns = &child_completed[i], .work_ns = 0 };
    }

    const parent_ctxs = try std.heap.smp_allocator.alloc(NestedParentCtx, parent_count);
    defer std.heap.smp_allocator.free(parent_ctxs);

    var wg = pool.waitGroup();

    for (parent_ctxs, 0..) |*ctx, i| {
        const off = i * children_per_parent;
        ctx.* = .{
            .pool = &pool,
            .wg = &wg,
            .completed_at_ns = &parent_completed[i],
            .child_ctxs = child_ctxs[off .. off + children_per_parent],
            .child_submitted_at = child_submitted[off .. off + children_per_parent],
        };
    }

    const start_ns = clock.nanoTimestamp();

    const slot = try pool.registerSubmitter();
    defer pool.releaseSubmitter(slot);

    for (parent_ctxs, 0..) |*ctx, i| {
        parent_submitted[i] = nowNs();
        _ = try pool.submit(nestedParentTask, @ptrCast(ctx), .{
            .wait_group = &wg,
            .backpressure = .block,
        });
    }

    wg.wait();
    const elapsed_ns = elapsedNsSince(start_ns);

    const latencies = try std.heap.smp_allocator.alloc(u64, total_tasks);
    defer std.heap.smp_allocator.free(latencies);
    for (0..parent_count) |i| {
        latencies[i] = parent_completed[i] -| parent_submitted[i];
    }
    for (0..parent_count * children_per_parent) |i| {
        latencies[parent_count + i] = child_completed[i] -| child_submitted[i];
    }

    return latencyResult(elapsed_ns, latencies);
}

fn runBurstDrainBurstSample(worker_count: usize) !SampleResult {
    const task_count: usize = 4_000;
    const work_ns: u64 = 50_000;
    const half = task_count / 2;

    var pool = try thread_pool.ThreadPool.init(std.heap.smp_allocator, .{
        .min_threads = worker_count,
        .max_threads = worker_count,
        .queue_capacity = 4096,
        .local_queue_capacity = 256,
        .scheduler_variant = .work_stealing,
    });
    defer pool.deinit();

    var submitted_at = try std.heap.smp_allocator.alloc(u64, task_count);
    defer std.heap.smp_allocator.free(submitted_at);
    var completed_at = try std.heap.smp_allocator.alloc(u64, task_count);
    defer std.heap.smp_allocator.free(completed_at);
    @memset(completed_at, 0);
    const burst_ctxs = try std.heap.smp_allocator.alloc(RealisticTaskCtx, task_count);
    defer std.heap.smp_allocator.free(burst_ctxs);
    for (burst_ctxs, 0..) |*ctx, i| {
        ctx.* = .{ .completed_at_ns = &completed_at[i], .work_ns = work_ns };
    }

    const start_ns = clock.nanoTimestamp();

    // First burst
    {
        var wg = pool.waitGroup();
        for (burst_ctxs[0..half], 0..) |*ctx, i| {
            submitted_at[i] = nowNs();
            _ = try pool.submit(realisticTask, @ptrCast(ctx), .{
                .wait_group = &wg,
                .backpressure = .block,
            });
        }
        wg.wait();
    }

    clock.sleep(10 * std.time.ns_per_ms);

    // Second burst
    {
        var wg = pool.waitGroup();
        for (burst_ctxs[half..], 0..) |*ctx, i| {
            submitted_at[half + i] = nowNs();
            _ = try pool.submit(realisticTask, @ptrCast(ctx), .{
                .wait_group = &wg,
                .backpressure = .block,
            });
        }
        wg.wait();
    }

    clock.sleep(10 * std.time.ns_per_ms);

    const elapsed_ns = elapsedNsSince(start_ns);

    const latencies = try std.heap.smp_allocator.alloc(u64, task_count);
    defer std.heap.smp_allocator.free(latencies);
    for (latencies, 0..) |*lat, i| {
        lat.* = completed_at[i] -| submitted_at[i];
    }

    return latencyResult(elapsed_ns, latencies);
}

fn runMixedFastSlowSample(worker_count: usize) !SampleResult {
    const task_count: usize = 5_000;
    const slow_ns: u64 = 1_000_000;

    var pool = try thread_pool.ThreadPool.init(std.heap.smp_allocator, .{
        .min_threads = worker_count,
        .max_threads = worker_count,
        .queue_capacity = 4096,
        .local_queue_capacity = 256,
        .scheduler_variant = .work_stealing,
        .max_submitter_queues = 1,
        .submitter_queue_capacity = 4096,
    });
    defer pool.deinit();

    var submitted_at = try std.heap.smp_allocator.alloc(u64, task_count);
    defer std.heap.smp_allocator.free(submitted_at);
    var completed_at = try std.heap.smp_allocator.alloc(u64, task_count);
    defer std.heap.smp_allocator.free(completed_at);
    @memset(completed_at, 0);
    const mixed_ctxs = try std.heap.smp_allocator.alloc(RealisticTaskCtx, task_count);
    defer std.heap.smp_allocator.free(mixed_ctxs);
    for (mixed_ctxs, 0..) |*ctx, i| {
        const is_slow = (i % 5) == 0;
        ctx.* = .{
            .completed_at_ns = &completed_at[i],
            .work_ns = if (is_slow) slow_ns else 0,
        };
    }

    var wg = pool.waitGroup();
    const start_ns = clock.nanoTimestamp();

    const slot = try pool.registerSubmitter();
    defer pool.releaseSubmitter(slot);

    for (mixed_ctxs, 0..) |*ctx, i| {
        submitted_at[i] = nowNs();
        _ = try pool.submit(realisticTask, @ptrCast(ctx), .{
            .wait_group = &wg,
            .backpressure = .block,
        });
    }

    wg.wait();
    const elapsed_ns = elapsedNsSince(start_ns);

    const latencies = try std.heap.smp_allocator.alloc(u64, task_count);
    defer std.heap.smp_allocator.free(latencies);
    for (latencies, 0..) |*lat, i| {
        lat.* = completed_at[i] -| submitted_at[i];
    }

    return latencyResult(elapsed_ns, latencies);
}

// --- Helpers ---

fn busyWork(ns: u64) void {
    const start = nowNs();
    while (true) {
        const now = nowNs();
        if (now -| start >= ns) break;
    }
}

fn latencyResult(elapsed_ns: u64, latencies: []u64) SampleResult {
    std.sort.heap(u64, latencies, {}, comptime std.sort.asc(u64));
    const n = latencies.len;
    if (n == 0) return .{ .elapsed_ns = elapsed_ns };
    return .{
        .elapsed_ns = elapsed_ns,
        .latency_p50_us = latencies[n * 50 / 100] / 1000,
        .latency_p95_us = latencies[@min(n * 95 / 100, n - 1)] / 1000,
        .latency_p99_us = latencies[@min(n * 99 / 100, n - 1)] / 1000,
    };
}

fn elapsedNsSince(start_ns: i128) u64 {
    const end_ns: i128 = clock.nanoTimestamp();
    const delta = end_ns - start_ns;
    return if (delta <= 0) 0 else @as(u64, @intCast(delta));
}

fn nowNs() u64 {
    const ts: i128 = clock.nanoTimestamp();
    return if (ts < 0) 0 else @as(u64, @intCast(ts));
}

fn gitSha(allocator: std.mem.Allocator, io: std.Io) ![]const u8 {
    const result = std.process.run(allocator, io, .{
        .argv = &.{ "git", "rev-parse", "HEAD" },
        .stdout_limit = .limited(128),
        .stderr_limit = .limited(512),
    }) catch return allocator.dupe(u8, "unknown");
    defer allocator.free(result.stderr);
    const exited = switch (result.term) {
        .exited => |code| code,
        else => 1,
    };
    if (exited != 0) {
        allocator.free(result.stdout);
        return allocator.dupe(u8, "unknown");
    }
    defer allocator.free(result.stdout);
    return allocator.dupe(u8, std.mem.trim(u8, result.stdout, " \r\n\t"));
}
