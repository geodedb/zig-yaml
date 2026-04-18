const std = @import("std");
const thread_pool = @import("thread_pool");

const Counter = struct {
    value: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
};

fn counterTask(raw_ctx: *anyopaque, runtime: *thread_pool.TaskContext) void {
    _ = runtime;
    const counter: *Counter = @ptrCast(@alignCast(raw_ctx));
    _ = counter.value.fetchAdd(1, .monotonic);
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var pool = try thread_pool.ThreadPool.init(allocator, .{
        .min_threads = 2,
        .max_threads = 2,
        .queue_capacity = 128,
        .local_queue_capacity = 32,
        .scheduler_variant = .work_stealing,
    });
    defer pool.deinit();

    var wg = pool.waitGroup();
    var counter = Counter{};
    for (0..32) |_| {
        _ = try pool.submit(counterTask, @ptrCast(&counter), .{ .wait_group = &wg });
    }
    wg.wait();

    const stats = pool.statsSnapshot();
    std.debug.print("completed={d} count={d}\n", .{
        stats.completed,
        counter.value.load(.acquire),
    });
}
