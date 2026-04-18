const std = @import("std");
const thread_pool = @import("thread_pool");

fn noop(_: *anyopaque, _: *thread_pool.TaskContext) void {}

test "phase h: double-dequeue race reproducer" {
    // Submit-flood harness targeting the nextTask double-dequeue race window
    // (src/pool.zig:632-712). Uses 16 workers with a minimal noop task body
    // to maximise the rate of descriptor churn through the inject_queue
    // drain + stealHalf overflow path.
    //
    // Strategy (Task 1 amended): spin_before_park_iters=0 forces immediate
    // park, mimicking the Phase G2 poll-removed condition where the race
    // actually fires. The original spin=4096 kept the queued_tasks poll in
    // src/pool.zig:790-794 catching all submits before workers parked,
    // which prevented the double-dequeue path from being entered at all
    // (not just masking the symptom). idle_park_after_ns=10us keeps park
    // churn high so workers cycle park->wake->claim repeatedly inside the
    // submit flood, maximising the race window. Default is 250us per
    // src/types.zig:103.
    //
    // Baseline: passes on main (race silently produces a duplicate claim
    // when reached). Becomes diagnostic once the Task 2 descriptor
    // sentinel lands — at that point the duplicate claim panics
    // deterministically within this window.
    var pool = try thread_pool.ThreadPool.init(std.testing.allocator, .{
        .min_threads = 16,
        .max_threads = 16,
        .queue_capacity = 4096,
        .local_queue_capacity = 256,
        .scheduler_variant = .work_stealing,
        .spin_before_park_iters = 0,
        .idle_park_after_ns = 10_000, // 10us — wake fast so park churn is high
    });
    defer pool.deinit();

    // Let workers reach their park/spin steady state before the flood.
    thread_pool.clock.sleep(5 * std.time.ns_per_ms);

    const per_producer: u64 = 500_000;
    var wg = pool.waitGroup();

    const Submitter = struct {
        fn run(p: *thread_pool.ThreadPool, g: *thread_pool.WaitGroup, n: u64) void {
            var dummy: u8 = 0;
            var i: u64 = 0;
            while (i < n) : (i += 1) {
                // enqueueTask auto-adds to the wait_group; do NOT call wg.add()
                // explicitly. Use .block so queue-full never drops tasks and
                // the wait-group count stays consistent.
                _ = p.submit(noop, @ptrCast(&dummy), .{
                    .backpressure = .block,
                    .wait_group = g,
                }) catch |err| switch (err) {
                    error.ShutdownInProgress => return,
                    else => return,
                };
            }
        }
    };

    const t1 = try std.Thread.spawn(.{}, Submitter.run, .{ &pool, &wg, per_producer });
    const t2 = try std.Thread.spawn(.{}, Submitter.run, .{ &pool, &wg, per_producer });
    t1.join();
    t2.join();

    // Polling deadline rather than wg.wait() so a lost wakeup surfaces as a
    // test failure with a clear pendingCount, not a process-level hang.
    // Matches the pattern used by the existing "phase g2: aggressive spin
    // flood" test in this file's sibling tests/stress.zig.
    const deadline_ns: i128 = 30 * std.time.ns_per_s;
    const start = thread_pool.clock.nanoTimestamp();
    while (thread_pool.clock.nanoTimestamp() - start < deadline_ns) {
        if (wg.pendingCount() == 0) break;
        thread_pool.clock.sleep(1 * std.time.ns_per_ms);
    }

    try std.testing.expectEqual(@as(u32, 0), wg.pendingCount());
}
