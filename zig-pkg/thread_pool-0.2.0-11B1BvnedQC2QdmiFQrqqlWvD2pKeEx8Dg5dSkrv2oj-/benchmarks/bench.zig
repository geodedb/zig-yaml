const std = @import("std");
const thread_pool = @import("thread_pool");
const common = @import("common.zig");

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const output = try common.parseOutputArg(allocator, init.minimal.args);
    const specs = [_]common.ScenarioSpec{
        .{
            .name = "conn_churn_seq",
            .task_count = 4096,
            .worker_count = 2,
            .submitter_count = 1,
            .queue_capacity = 4096,
            .local_queue_capacity = 64,
            .scratch_bytes = 2048,
        },
        .{
            .name = "producer_contention",
            .task_count = 4096,
            .worker_count = 2,
            .submitter_count = 4,
            .queue_capacity = 4096,
            .local_queue_capacity = 64,
        },
    };
    const variants = [_]thread_pool.SchedulerVariant{ .global_queue, .work_stealing };
    try common.runScenarios(allocator, init.io, &specs, &variants, output);
}
