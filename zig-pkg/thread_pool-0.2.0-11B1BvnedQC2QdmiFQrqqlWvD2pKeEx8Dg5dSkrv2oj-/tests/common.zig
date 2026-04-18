const std = @import("std");
const thread_pool = @import("thread_pool");

pub const Counter = struct {
    value: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
};

/// COMPTIME-ELISION: returns the build-pinned timestamp mode, or `.full`
/// (the ambient default) when the build is unpinned.  Tests that exercise
/// `.disabled`-specific behavior must check this and skip when it returns
/// `.full`; tests that call this function pick up the pinned value so
/// `Core.init` does not reject the runtime config.
pub const default_timestamp_mode: thread_pool.types.TimestampMode = blk: {
    const build_options = @import("thread_pool").build_options;
    break :blk switch (build_options.timestamp_mode) {
        .any => .full,
        .full => .full,
        .disabled => .disabled,
    };
};

/// COMPTIME-ELISION: returns `true` iff the current build pinned the
/// scheduler variant to something other than `variant`.  Tests that
/// explicitly exercise one variant via `defaultConfig(variant)` should
/// call `try skipIfSchedulerVariantIncompatible(variant)` at the top so
/// pinned-variant builds cleanly skip incompatible scenarios rather than
/// fail with `error.BuildOptionMismatch`.
pub fn skipIfSchedulerVariantIncompatible(variant: thread_pool.SchedulerVariant) !void {
    const build_options = @import("thread_pool").build_options;
    const incompatible = switch (build_options.scheduler_variant) {
        .any => false,
        .global_queue => variant != .global_queue,
        .work_stealing => variant != .work_stealing,
        .lane_extension => variant != .lane_extension,
    };
    if (incompatible) return error.SkipZigTest;
}

pub fn defaultConfig(variant: thread_pool.SchedulerVariant) thread_pool.Config {
    return .{
        .min_threads = 2,
        .max_threads = 2,
        .queue_capacity = 512,
        .local_queue_capacity = 64,
        .inject_batch_size = 8,
        .worker_scratch_cap_bytes = 4096,
        .idle_park_after_ns = 100_000,
        .idle_purge_after_ns = 500_000,
        .scheduler_variant = variant,
        .timestamp_mode = default_timestamp_mode,
    };
}

pub fn counterTask(raw_ctx: *anyopaque, runtime: *thread_pool.TaskContext) void {
    _ = runtime;
    const counter: *Counter = @ptrCast(@alignCast(raw_ctx));
    _ = counter.value.fetchAdd(1, .monotonic);
}

pub const ScratchTaskContext = struct {
    counter: *Counter,
    bytes: usize,
};

pub fn scratchTask(raw_ctx: *anyopaque, runtime: *thread_pool.TaskContext) void {
    const ctx: *ScratchTaskContext = @ptrCast(@alignCast(raw_ctx));
    _ = runtime.allocScratch(u8, ctx.bytes) catch {};
    _ = ctx.counter.value.fetchAdd(1, .monotonic);
}

pub const SleepTaskContext = struct {
    counter: *Counter,
    sleep_ns: u64,
};

pub fn sleepTask(raw_ctx: *anyopaque, runtime: *thread_pool.TaskContext) void {
    _ = runtime;
    const ctx: *SleepTaskContext = @ptrCast(@alignCast(raw_ctx));
    thread_pool.clock.sleep(ctx.sleep_ns);
    _ = ctx.counter.value.fetchAdd(1, .monotonic);
}

pub const GateTaskContext = struct {
    counter: *Counter,
    started: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    release: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

pub fn gateTask(raw_ctx: *anyopaque, runtime: *thread_pool.TaskContext) void {
    _ = runtime;
    const ctx: *GateTaskContext = @ptrCast(@alignCast(raw_ctx));
    ctx.started.store(true, .release);
    while (!ctx.release.load(.acquire)) {
        thread_pool.clock.sleep(100_000);
    }
    _ = ctx.counter.value.fetchAdd(1, .monotonic);
}

pub const RecursiveContext = struct {
    pool: *thread_pool.ThreadPool,
    counter: *Counter,
    wait_group: *thread_pool.WaitGroup,
    child_count: usize,
};

pub fn recursiveTask(raw_ctx: *anyopaque, runtime: *thread_pool.TaskContext) void {
    _ = runtime;
    const ctx: *RecursiveContext = @ptrCast(@alignCast(raw_ctx));
    _ = ctx.counter.value.fetchAdd(1, .monotonic);
    for (0..ctx.child_count) |_| {
        _ = ctx.pool.submit(counterTask, @ptrCast(ctx.counter), .{ .wait_group = ctx.wait_group }) catch {};
    }
}

pub const ProducerContext = struct {
    pool: *thread_pool.ThreadPool,
    counter: *Counter,
    wait_group: *thread_pool.WaitGroup,
    task_count: usize,
};

pub fn producerMain(ctx: *ProducerContext) void {
    var i: usize = 0;
    while (i < ctx.task_count) : (i += 1) {
        _ = ctx.pool.submit(counterTask, @ptrCast(ctx.counter), .{ .wait_group = ctx.wait_group }) catch |err| switch (err) {
            error.ShutdownInProgress => return,
            else => return,
        };
    }
}
