// SPDX-License-Identifier: Apache-2.0
//! Micro-benchmark: submit-path latency.
//! Spawns a pool with a queue large enough that submits never block, runs
//! workers that sleep forever so task execution doesn't perturb measurement,
//! and records the time for each submit() call.
const std = @import("std");
const thread_pool = @import("thread_pool");
const clock = thread_pool.clock;

const sample_count = 100_000;
const warmup = 10_000;

fn sleepyTask(raw_ctx: *anyopaque, runtime: *thread_pool.TaskContext) void {
    _ = raw_ctx;
    _ = runtime;
    // Workers never actually consume this — we rely on queue depth not runtime.
}

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var samples = try allocator.alloc(u64, sample_count);

    var pool = try thread_pool.ThreadPool.init(std.heap.smp_allocator, .{
        .max_threads = 1,
        .queue_capacity = sample_count + warmup + 1024,
        .local_queue_capacity = 64,
        .scheduler_variant = .global_queue,
        // Disable backpressure entirely — queue is big enough.
        .idle_park_after_ns = 1_000_000,
    });
    defer pool.deinit();

    var marker: u8 = 0;

    // Warmup: submit tasks we don't measure, to page in the freelist and caches.
    for (0..warmup) |_| {
        _ = try pool.submit(sleepyTask, @ptrCast(&marker), .{});
    }

    // Measure.
    for (0..sample_count) |i| {
        const start = clock.nanoTimestamp();
        _ = try pool.submit(sleepyTask, @ptrCast(&marker), .{});
        const end = clock.nanoTimestamp();
        samples[i] = @intCast(end - start);
    }

    std.mem.sort(u64, samples, {}, std.sort.asc(u64));

    const p50 = samples[sample_count / 2];
    const p95 = samples[(sample_count * 95) / 100];
    const p99 = samples[(sample_count * 99) / 100];
    const min = samples[0];
    const max = samples[sample_count - 1];

    var buf: [256]u8 = undefined;
    const line = try std.fmt.bufPrint(
        &buf,
        "submit_latency samples={d} min={d}ns p50={d}ns p95={d}ns p99={d}ns max={d}ns\n",
        .{ sample_count, min, p50, p95, p99, max },
    );
    try std.Io.File.stdout().writeStreamingAll(init.io, line);
}
