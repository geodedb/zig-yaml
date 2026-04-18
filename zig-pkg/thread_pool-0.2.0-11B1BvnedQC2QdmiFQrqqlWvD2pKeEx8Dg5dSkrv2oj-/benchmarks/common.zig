const std = @import("std");
const builtin = @import("builtin");
const thread_pool = @import("thread_pool");
const clock = thread_pool.clock;

pub const ScenarioSpec = struct {
    name: []const u8,
    task_count: usize,
    worker_count: usize,
    submitter_count: usize,
    queue_capacity: usize,
    local_queue_capacity: usize,
    inject_batch_size: usize = 16,
    scratch_bytes: usize = 0,
    sleep_ns: u64 = 0,
    idle_gap_ns: u64 = 0,
    nested_children: usize = 0,
    lane: thread_pool.TaskLane = .default,
    register_submitters: bool = false,
};

pub const ResultRow = struct {
    git_sha: []const u8,
    run_timestamp_unix_s: i64,
    zig_version: []const u8,
    os: []const u8,
    arch: []const u8,
    cpu: []const u8,
    scenario_name: []const u8,
    scheduler_variant: []const u8,
    worker_count: usize,
    submitter_count: usize,
    queue_capacity: usize,
    local_queue_capacity: usize,
    task_count: usize,
    throughput_ops_per_sec: f64,
    throughput_stddev_ops_per_sec: f64 = 0,
    submit_latency_p50_ns: u64,
    submit_latency_p95_ns: u64,
    submit_latency_p99_ns: u64,
    completion_latency_p50_ns: u64,
    completion_latency_p95_ns: u64,
    completion_latency_p99_ns: u64,
    cpu_time_ns: u64,
    wall_time_ns: u64,
    alloc_count: u64,
    alloc_bytes: u64,
    live_bytes: u64,
    peak_live_bytes: u64,
    rss_current_bytes: u64,
    rss_peak_bytes: u64,
    rss_delta_after_warmup_bytes: i64,
    steals: u64,
    parks: u64,
    wakeups: u64,
    queue_peak: u64,
};

pub const ResultDocument = struct {
    generated_at_unix_s: i64,
    rows: []ResultRow,
};

pub const Counter = struct {
    value: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
};

pub fn parseOutputArg(allocator: std.mem.Allocator, args: std.process.Args) !?[]const u8 {
    const argv = try args.toSlice(allocator);
    var idx: usize = 0;
    while (idx + 1 < argv.len) : (idx += 1) {
        if (std.mem.eql(u8, argv[idx], "--output")) {
            // Dupe so callers using non-arena allocators are safe.
            return try allocator.dupe(u8, argv[idx + 1]);
        }
    }
    return null;
}

const BenchTaskCtx = struct {
    pool: ?*thread_pool.ThreadPool = null,
    wait_group: ?*thread_pool.WaitGroup = null,
    counter: *Counter,
    submitted_at_ns: *u64,
    completed_at_ns: *u64,
    scratch_bytes: usize,
    sleep_ns: u64,
    nested_children: usize = 0,
};

const SubmitterCtx = struct {
    pool: *thread_pool.ThreadPool,
    tasks: []BenchTaskCtx,
    submit_latencies_ns: []u64,
    wait_group: *thread_pool.WaitGroup,
    lane: thread_pool.TaskLane,
    register: bool,
};

pub fn runScenarios(allocator: std.mem.Allocator, io: std.Io, specs: []const ScenarioSpec, variants: []const thread_pool.SchedulerVariant, output_path: ?[]const u8) !void {
    var rows: std.ArrayList(ResultRow) = .empty;
    defer {
        for (rows.items) |row| {
            allocator.free(row.git_sha);
            allocator.free(row.cpu);
        }
        rows.deinit(allocator);
    }

    for (specs) |spec| {
        for (variants) |variant| {
            // Run 7 times; discard the first as a warm-up (cold caches, JIT-like effects).
            // Take the median of the remaining 6 for the reported row, and compute stddev
            // over the same 6 so compare-bench can gate on measured noise.
            const RUN_COUNT: usize = 7;
            const WARMUP_DISCARD: usize = 1;
            const SAMPLE_COUNT: usize = RUN_COUNT - WARMUP_DISCARD; // 6
            var results: [RUN_COUNT]ResultRow = undefined;
            for (&results) |*r| {
                r.* = try runScenario(allocator, io, spec, variant);
            }
            // Free the discarded warm-up run's allocations.
            for (results[0..WARMUP_DISCARD]) |r| {
                allocator.free(r.git_sha);
                allocator.free(r.cpu);
            }
            const samples = results[WARMUP_DISCARD..];
            std.sort.heap(ResultRow, samples, {}, struct {
                fn lessThan(_: void, a: ResultRow, b: ResultRow) bool {
                    return a.throughput_ops_per_sec < b.throughput_ops_per_sec;
                }
            }.lessThan);
            // Compute stddev over the sorted 6 samples before we free the non-median ones.
            const median_throughput = samples[SAMPLE_COUNT / 2].throughput_ops_per_sec;
            var stddev_ops_per_sec: f64 = 0;
            {
                var sum_sq: f64 = 0;
                for (samples) |s| {
                    const d = s.throughput_ops_per_sec - median_throughput;
                    sum_sq += d * d;
                }
                stddev_ops_per_sec = std.math.sqrt(sum_sq / @as(f64, @floatFromInt(SAMPLE_COUNT)));
            }
            // Free allocations from every non-median sample.
            for (samples, 0..) |r, idx| {
                if (idx == SAMPLE_COUNT / 2) continue;
                allocator.free(r.git_sha);
                allocator.free(r.cpu);
            }
            var median_row = samples[SAMPLE_COUNT / 2];
            median_row.throughput_stddev_ops_per_sec = stddev_ops_per_sec;
            try rows.append(allocator, median_row);
        }
    }

    const document = ResultDocument{
        .generated_at_unix_s = @as(i64, @intCast(@divTrunc(clock.nanoTimestamp(), std.time.ns_per_s))),
        .rows = try rows.toOwnedSlice(allocator),
    };
    defer allocator.free(document.rows);

    if (output_path) |path| {
        var file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
        defer file.close(io);
        const json = try std.json.Stringify.valueAlloc(allocator, document, .{ .whitespace = .indent_2 });
        defer allocator.free(json);
        try file.writeStreamingAll(io, json);
        try file.writeStreamingAll(io, "\n");
    } else {
        const json = try std.json.Stringify.valueAlloc(allocator, document, .{ .whitespace = .indent_2 });
        defer allocator.free(json);
        const stdout = std.Io.File.stdout();
        try stdout.writeStreamingAll(io, json);
        try stdout.writeStreamingAll(io, "\n");
    }
}

pub fn runScenario(allocator: std.mem.Allocator, io: std.Io, spec: ScenarioSpec, variant: thread_pool.SchedulerVariant) !ResultRow {
    const uses_blocking_lane = spec.lane == .blocking;
    const blocking_workers: u32 = if (uses_blocking_lane)
        @intCast(@max(spec.worker_count / 4, 2))
    else
        0;
    const submitter_queues: u32 = if (spec.register_submitters)
        @intCast(@max(spec.submitter_count, 1))
    else
        0;
    const submitter_capacity: usize = if (spec.register_submitters)
        @max(spec.local_queue_capacity, 1024)
    else
        0;
    var pool = try thread_pool.ThreadPool.init(allocator, .{
        .min_threads = spec.worker_count,
        .max_threads = spec.worker_count,
        .queue_capacity = spec.queue_capacity,
        .local_queue_capacity = spec.local_queue_capacity,
        .inject_batch_size = spec.inject_batch_size,
        .worker_scratch_cap_bytes = @max(spec.scratch_bytes, 4096),
        .idle_park_after_ns = 100_000,
        .idle_purge_after_ns = 500_000,
        .scheduler_variant = variant,
        .allow_blocking_lane = uses_blocking_lane,
        .blocking_workers = blocking_workers,
        .max_submitter_queues = submitter_queues,
        .submitter_queue_capacity = submitter_capacity,
    });
    defer pool.deinit();

    try warmup(&pool, @max(spec.task_count / 8, 32), spec.scratch_bytes);
    const warmup_memory = pool.statsSnapshot().memory;

    var counter = Counter{};
    var submitted_at_ns = try allocator.alloc(u64, spec.task_count);
    defer allocator.free(submitted_at_ns);
    var completed_at_ns = try allocator.alloc(u64, spec.task_count);
    defer allocator.free(completed_at_ns);
    @memset(completed_at_ns, 0);
    var submit_latencies_ns = try allocator.alloc(u64, spec.task_count);
    defer allocator.free(submit_latencies_ns);

    var tasks = try allocator.alloc(BenchTaskCtx, spec.task_count);
    defer allocator.free(tasks);
    for (tasks, 0..) |*task, idx| {
        task.* = .{
            .counter = &counter,
            .submitted_at_ns = &submitted_at_ns[idx],
            .completed_at_ns = &completed_at_ns[idx],
            .scratch_bytes = spec.scratch_bytes,
            .sleep_ns = spec.sleep_ns,
            .nested_children = spec.nested_children,
        };
    }

    const cpu_before = try processCpuTimeNs();
    const wall_start = nowNs();

    if (spec.idle_gap_ns != 0) {
        try submitRange(allocator, &pool, tasks[0 .. spec.task_count / 2], submit_latencies_ns[0 .. spec.task_count / 2], spec.submitter_count, spec.lane, spec.register_submitters);
        clock.sleep(spec.idle_gap_ns);
        try submitRange(allocator, &pool, tasks[spec.task_count / 2 ..], submit_latencies_ns[spec.task_count / 2 ..], spec.submitter_count, spec.lane, spec.register_submitters);
        clock.sleep(spec.idle_gap_ns);
    } else {
        try submitRange(allocator, &pool, tasks, submit_latencies_ns, spec.submitter_count, spec.lane, spec.register_submitters);
    }

    const wall_end = nowNs();
    const cpu_after = try processCpuTimeNs();
    const stats = pool.statsSnapshot();

    const submit_latencies_copy = try allocator.dupe(u64, submit_latencies_ns);
    defer allocator.free(submit_latencies_copy);
    const completion_latencies = try allocator.alloc(u64, spec.task_count);
    defer allocator.free(completion_latencies);
    for (completion_latencies, 0..) |*latency, idx| {
        latency.* = completed_at_ns[idx] - submitted_at_ns[idx];
    }

    const submit_summary = summarizeLatencies(submit_latencies_copy);
    const completion_summary = summarizeLatencies(completion_latencies);

    const throughput = @as(f64, @floatFromInt(spec.task_count)) / (@as(f64, @floatFromInt(wall_end - wall_start)) / std.time.ns_per_s);
    const git_sha = try gitSha(allocator, io);
    const cpu_name = try allocator.dupe(u8, @tagName(builtin.cpu.arch));

    const cpu_time_ns = if (cpu_after > cpu_before) cpu_after - cpu_before else wall_end - wall_start;

    return .{
        .git_sha = git_sha,
        .run_timestamp_unix_s = @as(i64, @intCast(@divTrunc(clock.nanoTimestamp(), std.time.ns_per_s))),
        .zig_version = builtin.zig_version_string,
        .os = @tagName(builtin.os.tag),
        .arch = @tagName(builtin.cpu.arch),
        .cpu = cpu_name,
        .scenario_name = spec.name,
        .scheduler_variant = @tagName(variant),
        .worker_count = spec.worker_count,
        .submitter_count = spec.submitter_count,
        .queue_capacity = spec.queue_capacity,
        .local_queue_capacity = spec.local_queue_capacity,
        .task_count = spec.task_count,
        .throughput_ops_per_sec = throughput,
        .throughput_stddev_ops_per_sec = 0,
        .submit_latency_p50_ns = submit_summary.p50_ns,
        .submit_latency_p95_ns = submit_summary.p95_ns,
        .submit_latency_p99_ns = submit_summary.p99_ns,
        .completion_latency_p50_ns = completion_summary.p50_ns,
        .completion_latency_p95_ns = completion_summary.p95_ns,
        .completion_latency_p99_ns = completion_summary.p99_ns,
        .cpu_time_ns = cpu_time_ns,
        .wall_time_ns = wall_end - wall_start,
        .alloc_count = stats.total_alloc_count,
        .alloc_bytes = stats.total_alloc_bytes,
        .live_bytes = stats.live_bytes,
        .peak_live_bytes = stats.peak_live_bytes,
        .rss_current_bytes = stats.memory.rss_current_bytes,
        .rss_peak_bytes = stats.memory.rss_peak_bytes,
        .rss_delta_after_warmup_bytes = @as(i64, @intCast(stats.memory.rss_current_bytes)) - @as(i64, @intCast(warmup_memory.rss_current_bytes)),
        .steals = stats.steals,
        .parks = stats.parks,
        .wakeups = stats.wakeups,
        .queue_peak = stats.queue_depth_peak,
    };
}

fn submitRange(allocator: std.mem.Allocator, pool: *thread_pool.ThreadPool, tasks: []BenchTaskCtx, submit_latencies_ns: []u64, submitter_count: usize, lane: thread_pool.TaskLane, register: bool) !void {
    var wg = pool.waitGroup();
    if (submitter_count <= 1) {
        const slot_opt: ?usize = if (register) pool.registerSubmitter() catch null else null;
        defer if (slot_opt) |slot| pool.releaseSubmitter(slot);
        var i: usize = 0;
        while (i < tasks.len) : (i += 1) {
            const submit_started = nowNs();
            tasks[i].submitted_at_ns.* = submit_started;
            tasks[i].pool = pool;
            tasks[i].wait_group = &wg;
            if (tasks[i].nested_children == 0) {
                _ = try pool.submit(benchTask, @ptrCast(&tasks[i]), .{
                    .wait_group = &wg,
                    .backpressure = .block,
                    .timeout_ns = 5 * std.time.ns_per_s,
                    .lane = lane,
                });
            } else {
                _ = try pool.submit(nestedTask, @ptrCast(&tasks[i]), .{
                    .wait_group = &wg,
                    .backpressure = .block,
                    .timeout_ns = 5 * std.time.ns_per_s,
                    .lane = lane,
                });
            }
            submit_latencies_ns[i] = nowNs() - submit_started;
        }
        wg.wait();
        return;
    }

    const submitter_len = @min(submitter_count, tasks.len);
    const threads = try allocator.alloc(std.Thread, submitter_len);
    defer allocator.free(threads);
    const ctxs = try allocator.alloc(SubmitterCtx, submitter_len);
    defer allocator.free(ctxs);

    const base = tasks.len / submitter_len;
    const remainder = tasks.len % submitter_len;
    var offset: usize = 0;
    for (ctxs, 0..) |*ctx, idx| {
        const extra: usize = if (idx < remainder) 1 else 0;
        const count = base + extra;
        ctx.* = .{
            .pool = pool,
            .tasks = tasks[offset .. offset + count],
            .submit_latencies_ns = submit_latencies_ns[offset .. offset + count],
            .wait_group = &wg,
            .lane = lane,
            .register = register and submitter_count > 1,
        };
        offset += count;
    }
    for (threads, ctxs) |*thread, ctx| {
        thread.* = try std.Thread.spawn(.{}, submitterMain, .{ctx});
    }
    for (threads) |thread| thread.join();
    wg.wait();
}

fn submitterMain(ctx: SubmitterCtx) void {
    const slot_opt: ?usize = if (ctx.register)
        ctx.pool.registerSubmitter() catch null
    else
        null;
    defer if (slot_opt) |slot| ctx.pool.releaseSubmitter(slot);
    for (ctx.tasks, 0..) |*task, idx| {
        const submit_started = nowNs();
        task.submitted_at_ns.* = submit_started;
        task.pool = ctx.pool;
        task.wait_group = ctx.wait_group;
        if (task.nested_children == 0) {
            _ = ctx.pool.submit(benchTask, @ptrCast(task), .{
                .wait_group = ctx.wait_group,
                .backpressure = .block,
                .timeout_ns = 5 * std.time.ns_per_s,
                .lane = ctx.lane,
            }) catch return;
        } else {
            _ = ctx.pool.submit(nestedTask, @ptrCast(task), .{
                .wait_group = ctx.wait_group,
                .backpressure = .block,
                .timeout_ns = 5 * std.time.ns_per_s,
                .lane = ctx.lane,
            }) catch return;
        }
        ctx.submit_latencies_ns[idx] = nowNs() - submit_started;
    }
}

fn benchTask(raw_ctx: *anyopaque, runtime: *thread_pool.TaskContext) void {
    const ctx: *BenchTaskCtx = @ptrCast(@alignCast(raw_ctx));
    if (ctx.scratch_bytes != 0) {
        _ = runtime.allocScratch(u8, ctx.scratch_bytes) catch {};
    }
    if (ctx.sleep_ns != 0) {
        clock.sleep(ctx.sleep_ns);
    }
    _ = ctx.counter.value.fetchAdd(1, .monotonic);
    ctx.completed_at_ns.* = nowNs();
}

fn nestedTask(raw_ctx: *anyopaque, runtime: *thread_pool.TaskContext) void {
    _ = runtime;
    const ctx: *BenchTaskCtx = @ptrCast(@alignCast(raw_ctx));
    _ = ctx.counter.value.fetchAdd(1, .monotonic);
    for (0..ctx.nested_children) |_| {
        _ = ctx.pool.?.submit(benchTask, @ptrCast(ctx), .{
            .wait_group = ctx.wait_group.?,
            .backpressure = .block,
            .timeout_ns = 5 * std.time.ns_per_s,
        }) catch return;
    }
    ctx.completed_at_ns.* = nowNs();
}

pub fn warmup(pool: *thread_pool.ThreadPool, task_count: usize, scratch_bytes: usize) !void {
    var counter = Counter{};
    var wg = pool.waitGroup();
    var submitted: u64 = 0;
    var completed: u64 = 0;
    var task = BenchTaskCtx{
        .counter = &counter,
        .submitted_at_ns = &submitted,
        .completed_at_ns = &completed,
        .scratch_bytes = scratch_bytes,
        .sleep_ns = 0,
    };
    for (0..task_count) |_| {
        submitted = nowNs();
        _ = try pool.submit(benchTask, @ptrCast(&task), .{
            .wait_group = &wg,
            .backpressure = .block,
            .timeout_ns = 5 * std.time.ns_per_s,
        });
    }
    wg.wait();
}

pub fn summarizeLatencies(values: []u64) thread_pool.LatencySummary {
    std.sort.heap(u64, values, {}, comptime std.sort.asc(u64));
    return .{
        .count = values.len,
        .min_ns = if (values.len == 0) 0 else values[0],
        .mean_ns = mean(values),
        .p50_ns = percentile(values, 50),
        .p95_ns = percentile(values, 95),
        .p99_ns = percentile(values, 99),
        .max_ns = if (values.len == 0) 0 else values[values.len - 1],
    };
}

fn mean(values: []const u64) u64 {
    if (values.len == 0) return 0;
    var total: u128 = 0;
    for (values) |value| total += value;
    return @as(u64, @intCast(total / values.len));
}

fn percentile(values: []const u64, pct: u8) u64 {
    if (values.len == 0) return 0;
    const idx = @min((values.len - 1) * pct / 100, values.len - 1);
    return values[idx];
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

fn processCpuTimeNs() !u64 {
    if (builtin.os.tag == .linux) {
        const posix = std.posix;
        const fd = try posix.openat(posix.AT.FDCWD, "/proc/self/stat", .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
        defer _ = std.os.linux.close(fd);
        var buffer: [4096]u8 = undefined;
        var total: usize = 0;
        while (total < buffer.len) {
            const n = try posix.read(fd, buffer[total..]);
            if (n == 0) break;
            total += n;
        }
        const contents = buffer[0..total];
        var it = std.mem.tokenizeScalar(u8, contents, ' ');
        var field_index: usize = 1;
        var utime_ticks: u64 = 0;
        var stime_ticks: u64 = 0;
        while (it.next()) |field| : (field_index += 1) {
            if (field_index == 14) utime_ticks = std.fmt.parseInt(u64, field, 10) catch 0;
            if (field_index == 15) {
                stime_ticks = std.fmt.parseInt(u64, field, 10) catch 0;
                break;
            }
        }
        return (utime_ticks + stime_ticks) * (std.time.ns_per_s / 100);
    }
    return nowNs();
}

fn nowNs() u64 {
    const ts = clock.nanoTimestamp();
    return if (ts < 0) 0 else @as(u64, @intCast(ts));
}

/// A task that does the absolute minimum — used by micro-benchmarks to
/// measure pool overhead without task-body noise.  Writes a single u8 to a
/// volatile marker to prevent the optimizer from eliding the call.
pub fn noopTask(raw_ctx: *anyopaque, runtime: *thread_pool.TaskContext) void {
    _ = runtime;
    const marker: *volatile u8 = @ptrCast(raw_ctx);
    marker.* +%= 1;
}

// --- Affinity helpers for producer-pinning benches (Slice 0) ---
//
// Cross-socket L3 coherence cost dominates batched-submit scenarios on
// multi-socket hosts.  Without explicit producer pinning, std.Thread.spawn
// lets the kernel scatter producers across sockets, so two runs of the same
// bench at the same SHA differ by topology noise alone.  These helpers are
// Linux-only; on other OSes they return error.Unsupported so callers can
// gracefully skip pinning.

pub fn pinCurrentThreadToCpu(cpu_id: u32) !void {
    if (builtin.os.tag != .linux) return error.Unsupported;
    var set: std.os.linux.cpu_set_t = std.mem.zeroes(std.os.linux.cpu_set_t);
    const bits_per_word = @sizeOf(usize) * 8;
    const word_idx: usize = cpu_id / bits_per_word;
    if (word_idx >= set.len) return error.CpuIdOutOfRange;
    const bit_idx: u6 = @intCast(cpu_id % bits_per_word);
    set[word_idx] |= @as(usize, 1) << bit_idx;
    try std.os.linux.sched_setaffinity(0, &set);
}

pub fn cpuSocketId(cpu_id: u32) !u32 {
    if (builtin.os.tag != .linux) return error.Unsupported;
    var path_buf: [128]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "/sys/devices/system/cpu/cpu{d}/topology/physical_package_id", .{cpu_id}) catch return error.SocketIdUnavailable;
    const posix = std.posix;
    const fd = posix.openat(posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0) catch return error.SocketIdUnavailable;
    defer _ = std.os.linux.close(fd);
    var read_buf: [32]u8 = undefined;
    var total: usize = 0;
    while (total < read_buf.len) {
        const n = posix.read(fd, read_buf[total..]) catch return error.SocketIdUnavailable;
        if (n == 0) break;
        total += n;
    }
    const trimmed = std.mem.trim(u8, read_buf[0..total], " \r\n\t");
    return std.fmt.parseInt(u32, trimmed, 10) catch error.SocketIdUnavailable;
}

/// Enumerate the CPUs belonging to a given socket.  Caller owns and frees.
/// Returns an empty slice if no CPUs match (e.g. socket id not present).
pub fn cpusInSocket(allocator: std.mem.Allocator, socket_id: u32) ![]u32 {
    if (builtin.os.tag != .linux) return error.Unsupported;
    var list: std.ArrayList(u32) = .empty;
    errdefer list.deinit(allocator);
    var miss_streak: u32 = 0;
    var cpu: u32 = 0;
    while (cpu < 4096 and miss_streak < 16) : (cpu += 1) {
        const sid = cpuSocketId(cpu) catch {
            miss_streak += 1;
            continue;
        };
        miss_streak = 0;
        if (sid == socket_id) try list.append(allocator, cpu);
    }
    return list.toOwnedSlice(allocator);
}

/// Discover how many distinct sockets (physical packages) exist.
pub fn socketCount() !u32 {
    if (builtin.os.tag != .linux) return error.Unsupported;
    var seen: u64 = 0;
    var miss_streak: u32 = 0;
    var cpu: u32 = 0;
    while (cpu < 4096 and miss_streak < 16) : (cpu += 1) {
        const sid = cpuSocketId(cpu) catch {
            miss_streak += 1;
            continue;
        };
        miss_streak = 0;
        if (sid >= 64) continue;
        seen |= @as(u64, 1) << @intCast(sid);
    }
    return @popCount(seen);
}

pub fn getCurrentAffinity() !std.os.linux.cpu_set_t {
    if (builtin.os.tag != .linux) return error.Unsupported;
    var set: std.os.linux.cpu_set_t = std.mem.zeroes(std.os.linux.cpu_set_t);
    const rc = std.os.linux.sched_getaffinity(0, @sizeOf(std.os.linux.cpu_set_t), &set);
    if (rc != 0) return error.Unexpected;
    return set;
}

pub fn setAffinity(set: *const std.os.linux.cpu_set_t) !void {
    if (builtin.os.tag != .linux) return error.Unsupported;
    try std.os.linux.sched_setaffinity(0, set);
}
