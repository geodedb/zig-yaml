//! F-001 regression: a thread that is a worker/submitter of pool A must
//! never dereference pool A's TLS index into pool B's arrays.
//!
//! Before the fix: tls_worker_index and tls_submitter_index are process-global.
//! A pool-A worker running on thread N has tls_worker_index = N. When it calls
//! pool_b.submit(), the hot path reads tls_worker_index = N and indexes into
//! pool_b.workers[N] / pool_b.local_queues[N]. If N >= pool_b.workers.len
//! (pool_b is smaller) this is OOB — panic in Debug/ReleaseSafe, UB in
//! ReleaseFast.

const std = @import("std");
const thread_pool = @import("thread_pool");

test "F-001: worker of pool A submitting into pool B does not OOB" {
    const gpa = std.testing.allocator;

    // Pool A: work_stealing so that workers set tls_worker_index. Use 16
    // workers so at least some workers have index >= pool_b's worker count.
    var pool_a = try thread_pool.ThreadPool.init(gpa, .{
        .min_threads = 16,
        .max_threads = 16,
        .queue_capacity = 2048,
        .local_queue_capacity = 256,
        .scheduler_variant = .work_stealing,
        .worker_scratch_cap_bytes = 4096,
    });
    defer pool_a.deinit();

    // Pool B: only 2 workers. Any pool-A worker with index >= 2 would OOB
    // before the fix.
    var pool_b = try thread_pool.ThreadPool.init(gpa, .{
        .min_threads = 2,
        .max_threads = 2,
        .queue_capacity = 512,
        .local_queue_capacity = 64,
        .scheduler_variant = .work_stealing,
        .worker_scratch_cap_bytes = 4096,
    });
    defer pool_b.deinit();

    const hit = try gpa.create(std.atomic.Value(u32));
    defer gpa.destroy(hit);
    hit.* = std.atomic.Value(u32).init(0);

    const wg_b = try gpa.create(thread_pool.WaitGroup);
    defer gpa.destroy(wg_b);
    wg_b.* = pool_b.waitGroup();

    // Each inner task just increments hit.
    const BumpCtx = struct {
        hit: *std.atomic.Value(u32),
        wg: *thread_pool.WaitGroup,
    };

    const bump = struct {
        fn run(raw: *anyopaque, _: *thread_pool.TaskContext) void {
            const c: *BumpCtx = @ptrCast(@alignCast(raw));
            _ = c.hit.fetchAdd(1, .release);
        }
    }.run;

    // N outer tasks, each running on pool_a, each submits one inner task into
    // pool_b. We heap-allocate BumpCtx items so the inner tasks remain valid
    // even after the outer task returns.
    const N: usize = 64;
    const bump_ctxs = try gpa.alloc(BumpCtx, N);
    defer gpa.free(bump_ctxs);

    for (bump_ctxs) |*bc| {
        bc.* = .{ .hit = hit, .wg = wg_b };
    }

    const OuterCtx = struct {
        inner_pool: *thread_pool.ThreadPool,
        bump_ctx: *BumpCtx,
        bump_fn: thread_pool.TaskFn,
    };

    const outer_ctxs = try gpa.alloc(OuterCtx, N);
    defer gpa.free(outer_ctxs);

    const outer_fn = struct {
        fn run(raw: *anyopaque, _: *thread_pool.TaskContext) void {
            const oc: *OuterCtx = @ptrCast(@alignCast(raw));
            // This submit runs on a pool-A worker thread. Before F-001 fix,
            // tls_worker_index (set to pool-A's worker index) would be used
            // to index pool-B's arrays -> OOB if pool-A's index >= pool-B's
            // worker count.
            _ = oc.inner_pool.submit(oc.bump_fn, @ptrCast(oc.bump_ctx), .{
                .wait_group = oc.bump_ctx.wg,
            }) catch {};
        }
    }.run;

    var wg_a = pool_a.waitGroup();

    for (0..N) |i| {
        outer_ctxs[i] = .{
            .inner_pool = &pool_b,
            .bump_ctx = &bump_ctxs[i],
            .bump_fn = bump,
        };
        _ = try pool_a.submit(outer_fn, @ptrCast(&outer_ctxs[i]), .{
            .wait_group = &wg_a,
        });
    }

    // Wait for all outer tasks on pool_a to complete (they submit into pool_b).
    wg_a.wait();

    // Wait for all inner tasks on pool_b to complete.
    wg_b.wait();

    try std.testing.expectEqual(@as(u32, N), hit.load(.acquire));
}

test "F-001: registered submitter of pool A submitting into pool B does not OOB" {
    const gpa = std.testing.allocator;

    // Similar scenario but exercises tls_submitter_index: register a
    // submitter on pool_a (large), then have that submitter submit into
    // pool_b (small). Before fix: tls_submitter_index from pool_a is used
    // to index pool_b.submitter_queues[] -> OOB if pool_b has fewer slots.
    var pool_a = try thread_pool.ThreadPool.init(gpa, .{
        .min_threads = 4,
        .max_threads = 4,
        .queue_capacity = 512,
        .local_queue_capacity = 64,
        .scheduler_variant = .work_stealing,
        .worker_scratch_cap_bytes = 4096,
        .max_submitter_queues = 8,
        .submitter_queue_capacity = 64,
    });
    defer pool_a.deinit();

    var pool_b = try thread_pool.ThreadPool.init(gpa, .{
        .min_threads = 2,
        .max_threads = 2,
        .queue_capacity = 256,
        .local_queue_capacity = 32,
        .scheduler_variant = .work_stealing,
        .worker_scratch_cap_bytes = 4096,
    });
    defer pool_b.deinit();

    var hit = std.atomic.Value(u32).init(0);
    var wg = pool_b.waitGroup();

    const Ctx = struct {
        hit: *std.atomic.Value(u32),
        wg: *thread_pool.WaitGroup,
    };

    const bump = struct {
        fn run(raw: *anyopaque, _: *thread_pool.TaskContext) void {
            const c: *Ctx = @ptrCast(@alignCast(raw));
            _ = c.hit.fetchAdd(1, .release);
        }
    }.run;

    var ctx = Ctx{ .hit = &hit, .wg = &wg };

    // Register a submitter slot on pool_a.
    const slot = try pool_a.registerSubmitter();
    defer pool_a.releaseSubmitter(slot);

    // Now submit into pool_b. Before fix: tls_submitter_index = slot (from
    // pool_a's registration) is blindly used to index pool_b.submitter_queues.
    const N: usize = 16;
    for (0..N) |_| {
        _ = try pool_b.submit(bump, @ptrCast(&ctx), .{ .wait_group = &wg });
    }

    wg.wait();
    try std.testing.expectEqual(@as(u32, N), hit.load(.acquire));
}
