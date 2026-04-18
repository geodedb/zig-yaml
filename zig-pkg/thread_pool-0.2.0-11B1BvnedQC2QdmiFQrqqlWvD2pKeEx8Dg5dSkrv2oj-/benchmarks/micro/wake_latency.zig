// SPDX-License-Identifier: Apache-2.0
//! Micro-benchmark: park→wake latency.
//! Repeatedly lets the pool quiesce, then submits one task and measures how
//! long until a worker starts executing it.
const std = @import("std");
const thread_pool = @import("thread_pool");
const clock = thread_pool.clock;

const samples = 5_000;
const quiesce_ns: u64 = 300_000; // 300us — long enough that workers definitely park

const Probe = struct {
    submit_ns: i128,
    run_ns: std.atomic.Value(i128) = std.atomic.Value(i128).init(0),
};

fn wakeTask(raw_ctx: *anyopaque, runtime: *thread_pool.TaskContext) void {
    _ = runtime;
    const probe: *Probe = @ptrCast(@alignCast(raw_ctx));
    probe.run_ns.store(@intCast(clock.nanoTimestamp()), .release);
}

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var results = try allocator.alloc(u64, samples);

    var pool = try thread_pool.ThreadPool.init(std.heap.smp_allocator, .{
        .max_threads = 2,
        .queue_capacity = 64,
        .local_queue_capacity = 16,
        .scheduler_variant = .work_stealing,
        .idle_park_after_ns = 50_000,
    });
    defer pool.deinit();

    // Warmup
    for (0..32) |_| {
        var probe = Probe{ .submit_ns = 0 };
        _ = try pool.submit(wakeTask, @ptrCast(&probe), .{});
        while (probe.run_ns.load(.acquire) == 0) std.atomic.spinLoopHint();
    }

    for (0..samples) |i| {
        clock.sleep(quiesce_ns);
        var probe = Probe{ .submit_ns = 0 };
        probe.submit_ns = clock.nanoTimestamp();
        _ = try pool.submit(wakeTask, @ptrCast(&probe), .{});
        while (probe.run_ns.load(.acquire) == 0) std.atomic.spinLoopHint();
        const run_ns = probe.run_ns.load(.acquire);
        results[i] = @intCast(run_ns - probe.submit_ns);
    }

    std.mem.sort(u64, results, {}, std.sort.asc(u64));

    var buf: [256]u8 = undefined;
    const line = try std.fmt.bufPrint(buf[0..], "wake_latency samples={d} p50={d}ns p95={d}ns p99={d}ns max={d}ns\n", .{ samples, results[samples / 2], results[(samples * 95) / 100], results[(samples * 99) / 100], results[samples - 1] });
    try std.Io.File.stdout().writeStreamingAll(init.io, line);
}
