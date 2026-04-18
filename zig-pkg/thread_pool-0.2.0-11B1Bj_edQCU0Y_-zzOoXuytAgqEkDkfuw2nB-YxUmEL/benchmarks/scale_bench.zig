const std = @import("std");
const thread_pool = @import("thread_pool");
const common = @import("common.zig");

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const cpu_count = std.Thread.getCpuCount() catch 4;
    const output = try common.parseOutputArg(allocator, init.minimal.args);
    const specs = [_]common.ScenarioSpec{
        .{
            .name = "conn_churn_parallel",
            .task_count = 512,
            .worker_count = @max(@min(cpu_count, 4), 2),
            .submitter_count = 4,
            .queue_capacity = 1024,
            .local_queue_capacity = 256,
            .scratch_bytes = 4096,
        },
        .{
            .name = "short_long_mix",
            .task_count = 256,
            .worker_count = @max(@min(cpu_count, 4), 2),
            .submitter_count = 2,
            .queue_capacity = 512,
            .local_queue_capacity = 128,
            .sleep_ns = 100_000,
        },
        .{
            .name = "idle_burst_idle",
            .task_count = 256,
            .worker_count = 2,
            .submitter_count = 1,
            .queue_capacity = 512,
            .local_queue_capacity = 64,
            .idle_gap_ns = 5 * std.time.ns_per_ms,
            .scratch_bytes = 1024,
        },
        .{
            .name = "nested_submit",
            .task_count = 128,
            .worker_count = @max(@min(cpu_count, 4), 2),
            .submitter_count = 2,
            .queue_capacity = 512,
            .local_queue_capacity = 128,
            .nested_children = 4,
        },
        .{
            .name = "blocking_lane_sim",
            .task_count = 256,
            .worker_count = @max(@min(cpu_count, 4), 2),
            .submitter_count = 2,
            .queue_capacity = 512,
            .local_queue_capacity = 128,
            .sleep_ns = 100_000,
            .lane = .blocking,
        },
        .{
            .name = "oversubscription",
            .task_count = 512,
            .worker_count = @max(cpu_count, 2) + 2,
            .submitter_count = 4,
            .queue_capacity = 1024,
            .local_queue_capacity = 256,
        },
    };
    const variants = [_]thread_pool.SchedulerVariant{ .global_queue, .work_stealing };
    try common.runScenarios(allocator, init.io, &specs, &variants, output);
}
