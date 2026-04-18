// SPDX-License-Identifier: Apache-2.0
//! Tokio rt_multi_threaded parity benchmarks.
//! Scenarios mirror Tokio's published benchmark suite so numbers here are
//! directly comparable to Tokio's output on the same hardware.
//!
//! Reference: https://github.com/tokio-rs/tokio/blob/master/benches/rt_multi_threaded.rs
//!
//! NOTE: We intentionally start with the two scenarios that map to the
//! biggest gaps identified in the audit (pure throughput, multi-producer
//! contention).  The yield-heavy and chained-spawn variants from Tokio's
//! suite require a continuation/callback feature this pool doesn't expose
//! today; they can be added when nested-submit gets a first-class API.
const std = @import("std");
const builtin = @import("builtin");
const thread_pool = @import("thread_pool");
const clock = thread_pool.clock;
const common = @import("common.zig");

const flood_count: usize = 1_000_000;
const contended_count: usize = 100_000;
const contended_submitters: usize = 8;

const NoopCtx = struct {
    marker: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
};

fn noopTask(raw_ctx: *anyopaque, runtime: *thread_pool.TaskContext) void {
    _ = runtime;
    const ctx: *NoopCtx = @ptrCast(@alignCast(raw_ctx));
    _ = ctx.marker.fetchAdd(1, .monotonic);
}

fn writeLine(io: std.Io, line: []const u8) !void {
    try std.Io.File.stdout().writeStreamingAll(io, line);
}

// === Scenario: flood_1m ===
// Single submitter pushes 1M trivial tasks. Measures pure throughput.
fn benchFlood(io: std.Io) !void {
    var pool = try thread_pool.ThreadPool.init(std.heap.smp_allocator, .{
        .max_threads = 0, // CPU count
        .queue_capacity = 4096,
        .local_queue_capacity = 256,
        .scheduler_variant = .work_stealing,
        .max_submitter_queues = 1,
        .submitter_queue_capacity = 1024,
    });
    defer pool.deinit();

    const slot_opt: ?usize = pool.registerSubmitter() catch null;
    defer if (slot_opt) |slot| pool.releaseSubmitter(slot);

    var ctx = NoopCtx{};
    var wg = pool.waitGroup();
    const start = clock.nanoTimestamp();
    for (0..flood_count) |_| {
        _ = try pool.submit(noopTask, @ptrCast(&ctx), .{
            .wait_group = &wg,
            .backpressure = .block,
        });
    }
    wg.wait();
    const end = clock.nanoTimestamp();

    const elapsed_ns: u64 = @intCast(end - start);
    const ops_per_sec = @as(f64, @floatFromInt(flood_count)) / (@as(f64, @floatFromInt(elapsed_ns)) / 1e9);

    var buf: [256]u8 = undefined;
    const line = try std.fmt.bufPrint(buf[0..], "tokio_parity scenario=flood_1m tasks={d} elapsed_ns={d} ops_per_sec={d:.0}\n", .{ flood_count, elapsed_ns, ops_per_sec });
    try writeLine(io, line);
}

// === Scenario: flood_1m_batched ===
// Single submitter pushes 1M trivial tasks through submitBatch with batch
// size 64. Amortizes per-task submitter atomics (counters.submitted,
// queued_tasks seq_cst fetchAdd, parked-worker wake scan) identified by
// the 2026-04-14 ceiling A/B as the flood_1m bottleneck.
const flood_batch_size: usize = 64;

fn benchFloodBatched(io: std.Io) !void {
    var pool = try thread_pool.ThreadPool.init(std.heap.smp_allocator, .{
        .max_threads = 0,
        .queue_capacity = 4096,
        .local_queue_capacity = 256,
        .scheduler_variant = .work_stealing,
        .max_submitter_queues = 1,
        .submitter_queue_capacity = 1024,
    });
    defer pool.deinit();

    const slot_opt: ?usize = pool.registerSubmitter() catch null;
    defer if (slot_opt) |slot| pool.releaseSubmitter(slot);

    var ctx = NoopCtx{};
    var wg = pool.waitGroup();
    var batch: [flood_batch_size]thread_pool.BatchTask = undefined;
    for (&batch) |*b| {
        b.* = .{ .task_fn = noopTask, .ctx = @ptrCast(&ctx) };
    }

    const start = clock.nanoTimestamp();
    var submitted_total: usize = 0;
    while (submitted_total < flood_count) {
        const remaining = flood_count - submitted_total;
        const this_batch = @min(remaining, flood_batch_size);
        const result = try pool.submitBatch(batch[0..this_batch], .{
            .wait_group = &wg,
            .backpressure = .block,
        });
        submitted_total += result.submitted;
    }
    wg.wait();
    const end = clock.nanoTimestamp();

    const elapsed_ns: u64 = @intCast(end - start);
    const ops_per_sec = @as(f64, @floatFromInt(flood_count)) / (@as(f64, @floatFromInt(elapsed_ns)) / 1e9);

    var buf: [256]u8 = undefined;
    const line = try std.fmt.bufPrint(buf[0..], "tokio_parity scenario=flood_1m_batched tasks={d} batch={d} elapsed_ns={d} ops_per_sec={d:.0}\n", .{ flood_count, flood_batch_size, elapsed_ns, ops_per_sec });
    try writeLine(io, line);
}

// === Scenario: contended_spawn_8x ===
// 8 submitter threads each push 100k/8 tasks concurrently.  Targets the
// producer_contention bottleneck identified in the audit.
const ContendedSubmitterCtx = struct {
    pool: *thread_pool.ThreadPool,
    wg: *thread_pool.WaitGroup,
    marker: *NoopCtx,
    count: usize,
};

fn contendedSubmitterThread(ctx: *ContendedSubmitterCtx) void {
    const slot_opt: ?usize = ctx.pool.registerSubmitter() catch null;
    defer if (slot_opt) |slot| ctx.pool.releaseSubmitter(slot);
    for (0..ctx.count) |_| {
        _ = ctx.pool.submit(noopTask, @ptrCast(ctx.marker), .{
            .wait_group = ctx.wg,
            .backpressure = .block,
        }) catch return;
    }
}

fn benchContended(io: std.Io) !void {
    var pool = try thread_pool.ThreadPool.init(std.heap.smp_allocator, .{
        .max_threads = 0,
        .queue_capacity = 4096,
        .local_queue_capacity = 256,
        .scheduler_variant = .work_stealing,
        .max_submitter_queues = contended_submitters,
        .submitter_queue_capacity = 1024,
    });
    defer pool.deinit();

    var ctx = NoopCtx{};
    var wg = pool.waitGroup();
    const per_submitter = contended_count / contended_submitters;

    var threads: [contended_submitters]std.Thread = undefined;
    var submitter_ctxs: [contended_submitters]ContendedSubmitterCtx = undefined;

    const start = clock.nanoTimestamp();
    for (0..contended_submitters) |i| {
        submitter_ctxs[i] = .{
            .pool = &pool,
            .wg = &wg,
            .marker = &ctx,
            .count = per_submitter,
        };
        threads[i] = try std.Thread.spawn(.{}, contendedSubmitterThread, .{&submitter_ctxs[i]});
    }
    for (&threads) |*t| t.join();
    wg.wait();
    const end = clock.nanoTimestamp();

    const elapsed_ns: u64 = @intCast(end - start);
    const total_tasks = per_submitter * contended_submitters;
    const ops_per_sec = @as(f64, @floatFromInt(total_tasks)) / (@as(f64, @floatFromInt(elapsed_ns)) / 1e9);

    var buf: [256]u8 = undefined;
    const line = try std.fmt.bufPrint(buf[0..], "tokio_parity scenario=contended_spawn_8x tasks={d} submitters={d} elapsed_ns={d} ops_per_sec={d:.0}\n", .{ total_tasks, contended_submitters, elapsed_ns, ops_per_sec });
    try writeLine(io, line);
}

// === Scenario: contended_spawn_8x_batched ===
// 8 submitter threads each push 100k/8 tasks via submitBatch with batch
// size 64. Measures whether the batched-submit amortization generalizes
// to the multi-producer case.
const ContendedBatchedSubmitterCtx = struct {
    pool: *thread_pool.ThreadPool,
    wg: *thread_pool.WaitGroup,
    marker: *NoopCtx,
    count: usize,
    pin_cpu_id: ?u32 = null,
};

fn contendedBatchedSubmitterThread(ctx: *ContendedBatchedSubmitterCtx) void {
    if (ctx.pin_cpu_id) |cpu_id| {
        // Best-effort pin: if the host can't honor it (non-Linux / OOR), fall
        // through and measure unpinned — a noisy single data point is better
        // than a silently-failed scenario.
        common.pinCurrentThreadToCpu(cpu_id) catch {};
    }
    const slot_opt: ?usize = ctx.pool.registerSubmitter() catch null;
    defer if (slot_opt) |slot| ctx.pool.releaseSubmitter(slot);
    var batch: [flood_batch_size]thread_pool.BatchTask = undefined;
    for (&batch) |*b| {
        b.* = .{ .task_fn = noopTask, .ctx = @ptrCast(ctx.marker) };
    }
    var submitted_total: usize = 0;
    while (submitted_total < ctx.count) {
        const remaining = ctx.count - submitted_total;
        const this_batch = @min(remaining, flood_batch_size);
        const result = ctx.pool.submitBatch(batch[0..this_batch], .{
            .wait_group = ctx.wg,
            .backpressure = .block,
        }) catch return;
        submitted_total += result.submitted;
    }
}

/// Shared core for all contended-batched variants.  `pin_cpus` is either
/// null (no pinning — the existing baseline) or an 8-element array with the
/// target cpu id per submitter.
fn benchContendedBatchedCore(
    io: std.Io,
    scenario_label: []const u8,
    pin_cpus: ?[contended_submitters]u32,
) !void {
    var pool = try thread_pool.ThreadPool.init(std.heap.smp_allocator, .{
        .max_threads = 0,
        .queue_capacity = 4096,
        .local_queue_capacity = 256,
        .scheduler_variant = .work_stealing,
        .max_submitter_queues = contended_submitters,
        .submitter_queue_capacity = 1024,
    });
    defer pool.deinit();

    var ctx = NoopCtx{};
    var wg = pool.waitGroup();
    const per_submitter = contended_count / contended_submitters;

    var threads: [contended_submitters]std.Thread = undefined;
    var submitter_ctxs: [contended_submitters]ContendedBatchedSubmitterCtx = undefined;

    const start = clock.nanoTimestamp();
    for (0..contended_submitters) |i| {
        submitter_ctxs[i] = .{
            .pool = &pool,
            .wg = &wg,
            .marker = &ctx,
            .count = per_submitter,
            .pin_cpu_id = if (pin_cpus) |cpus| cpus[i] else null,
        };
        threads[i] = try std.Thread.spawn(.{}, contendedBatchedSubmitterThread, .{&submitter_ctxs[i]});
    }
    for (&threads) |*t| t.join();
    wg.wait();
    const end = clock.nanoTimestamp();

    const elapsed_ns: u64 = @intCast(end - start);
    const total_tasks = per_submitter * contended_submitters;
    const ops_per_sec = @as(f64, @floatFromInt(total_tasks)) / (@as(f64, @floatFromInt(elapsed_ns)) / 1e9);

    var buf: [256]u8 = undefined;
    const line = try std.fmt.bufPrint(buf[0..], "tokio_parity scenario={s} tasks={d} submitters={d} batch={d} elapsed_ns={d} ops_per_sec={d:.0}\n", .{ scenario_label, total_tasks, contended_submitters, flood_batch_size, elapsed_ns, ops_per_sec });
    try writeLine(io, line);
}

fn benchContendedBatched(io: std.Io) !void {
    try benchContendedBatchedCore(io, "contended_spawn_8x_batched", null);
}

// === Pinned variants (Slice 0) ===========================================
//
// Without producer pinning, the kernel scatters the 8 submitter threads
// across the 2 sockets in a way that varies run-to-run, making cross-socket
// coherence effects indistinguishable from measurement noise.  The three
// variants below pin producers to controlled placements so downstream
// slices (sharded inject, socket-local wake-scan) have a measurable signal.

/// socket_cpus[0] = cpus on socket 0, socket_cpus[1] = cpus on socket 1.
/// On a single-socket box or discovery failure, both slices may be empty or
/// degenerate; the scenario-runners skip with a note in that case.
const SocketMap = struct {
    s0: []u32,
    s1: []u32,
    allocator: std.mem.Allocator,

    fn deinit(self: *SocketMap) void {
        self.allocator.free(self.s0);
        self.allocator.free(self.s1);
    }
};

fn discoverSocketMap(allocator: std.mem.Allocator) !SocketMap {
    const s0 = try common.cpusInSocket(allocator, 0);
    errdefer allocator.free(s0);
    const s1 = try common.cpusInSocket(allocator, 1);
    return .{ .s0 = s0, .s1 = s1, .allocator = allocator };
}

fn pickCpu(list: []const u32, idx: usize) u32 {
    // Round-robin over the socket's cpu list.  Never out of bounds: callers
    // check list.len > 0 before calling.
    return list[idx % list.len];
}

fn benchContendedBatchedSymmetric(io: std.Io, map: SocketMap) !void {
    if (map.s0.len == 0 or map.s1.len == 0) {
        try writeLine(io, "tokio_parity scenario=contended_spawn_8x_batched_symmetric SKIPPED (need >=2 sockets)\n");
        return;
    }
    var pins: [contended_submitters]u32 = undefined;
    // 4 on socket 0, 4 on socket 1
    pins[0] = pickCpu(map.s0, 0);
    pins[1] = pickCpu(map.s0, 1);
    pins[2] = pickCpu(map.s0, 2);
    pins[3] = pickCpu(map.s0, 3);
    pins[4] = pickCpu(map.s1, 0);
    pins[5] = pickCpu(map.s1, 1);
    pins[6] = pickCpu(map.s1, 2);
    pins[7] = pickCpu(map.s1, 3);
    try benchContendedBatchedCore(io, "contended_spawn_8x_batched_symmetric", pins);
}

fn benchContendedBatchedAsymmetric(io: std.Io, map: SocketMap) !void {
    if (map.s0.len < contended_submitters) {
        try writeLine(io, "tokio_parity scenario=contended_spawn_8x_batched_asymmetric SKIPPED (socket 0 has too few cpus)\n");
        return;
    }
    var pins: [contended_submitters]u32 = undefined;
    for (0..contended_submitters) |i| pins[i] = pickCpu(map.s0, i);
    try benchContendedBatchedCore(io, "contended_spawn_8x_batched_asymmetric", pins);
}

fn benchContendedBatchedCrosssocket(io: std.Io, map: SocketMap) !void {
    if (map.s1.len < contended_submitters) {
        try writeLine(io, "tokio_parity scenario=contended_spawn_8x_batched_crosssocket SKIPPED (socket 1 has too few cpus)\n");
        return;
    }
    var pins: [contended_submitters]u32 = undefined;
    for (0..contended_submitters) |i| pins[i] = pickCpu(map.s1, i);
    try benchContendedBatchedCore(io, "contended_spawn_8x_batched_crosssocket", pins);
}

// === flood_1m_crosssocket =================================================
// Single submitter pinned to socket 1.  Workers default (both sockets).
// Isolates cross-socket inject cost from the multi-producer contention
// overlay that benchContendedBatched scenarios introduce.
fn benchFloodCrosssocket(io: std.Io, map: SocketMap) !void {
    if (map.s1.len == 0) {
        try writeLine(io, "tokio_parity scenario=flood_1m_crosssocket SKIPPED (no socket 1)\n");
        return;
    }

    // Create the pool FIRST.  Worker threads inherit the current main-thread
    // affinity, so we must not be pinned yet or all 56 workers will collapse
    // onto a single cpu, producing a meaningless "in-L1" throughput.
    var pool = try thread_pool.ThreadPool.init(std.heap.smp_allocator, .{
        .max_threads = 0,
        .queue_capacity = 4096,
        .local_queue_capacity = 256,
        .scheduler_variant = .work_stealing,
        .max_submitter_queues = 1,
        .submitter_queue_capacity = 1024,
    });
    defer pool.deinit();

    const saved = common.getCurrentAffinity() catch {
        try writeLine(io, "tokio_parity scenario=flood_1m_crosssocket SKIPPED (affinity save failed)\n");
        return;
    };
    defer common.setAffinity(&saved) catch {};

    common.pinCurrentThreadToCpu(map.s1[0]) catch {
        try writeLine(io, "tokio_parity scenario=flood_1m_crosssocket SKIPPED (pin failed)\n");
        return;
    };

    const slot_opt: ?usize = pool.registerSubmitter() catch null;
    defer if (slot_opt) |slot| pool.releaseSubmitter(slot);

    var ctx = NoopCtx{};
    var wg = pool.waitGroup();
    const start = clock.nanoTimestamp();
    for (0..flood_count) |_| {
        _ = try pool.submit(noopTask, @ptrCast(&ctx), .{
            .wait_group = &wg,
            .backpressure = .block,
        });
    }
    wg.wait();
    const end = clock.nanoTimestamp();

    const elapsed_ns: u64 = @intCast(end - start);
    const ops_per_sec = @as(f64, @floatFromInt(flood_count)) / (@as(f64, @floatFromInt(elapsed_ns)) / 1e9);

    var buf: [256]u8 = undefined;
    const line = try std.fmt.bufPrint(buf[0..], "tokio_parity scenario=flood_1m_crosssocket tasks={d} elapsed_ns={d} ops_per_sec={d:.0}\n", .{ flood_count, elapsed_ns, ops_per_sec });
    try writeLine(io, line);
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    try benchFlood(io);
    try benchFloodBatched(io);
    try benchContended(io);
    try benchContendedBatched(io);

    // Pinned variants require socket topology.  On non-Linux / single-socket
    // hosts the discoverSocketMap call may error or produce empty slices;
    // each scenario guards itself and prints a SKIPPED line.
    if (builtin.os.tag == .linux) {
        var map = discoverSocketMap(std.heap.smp_allocator) catch null;
        if (map) |*m| {
            defer m.deinit();
            try benchFloodCrosssocket(io, m.*);
            try benchContendedBatchedSymmetric(io, m.*);
            try benchContendedBatchedAsymmetric(io, m.*);
            try benchContendedBatchedCrosssocket(io, m.*);
        } else {
            try writeLine(io, "tokio_parity pinned-variants SKIPPED (socket discovery failed)\n");
        }
    } else {
        try writeLine(io, "tokio_parity pinned-variants SKIPPED (non-Linux)\n");
    }
}
