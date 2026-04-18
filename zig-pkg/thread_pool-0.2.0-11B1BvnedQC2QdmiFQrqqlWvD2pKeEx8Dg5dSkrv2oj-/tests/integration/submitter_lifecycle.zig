//! F-005 regression: releaseSubmitter must be idempotent, bounds-check idx,
//! and only clear TLS if the calling thread actually owned the slot.

const std = @import("std");
const thread_pool = @import("thread_pool");

test "F-005: releaseSubmitter is idempotent" {
    const gpa = std.testing.allocator;
    var pool = try thread_pool.ThreadPool.init(gpa, .{
        .max_threads = 2,
        .queue_capacity = 128,
        .max_submitter_queues = 4,
        .submitter_queue_capacity = 64,
    });
    defer pool.deinit();

    const idx = try pool.registerSubmitter();
    pool.releaseSubmitter(idx);
    // Second release must not panic or OOB into a potentially-reused slot.
    pool.releaseSubmitter(idx);
}

test "F-005: releaseSubmitter bounds-checks idx" {
    const gpa = std.testing.allocator;
    var pool = try thread_pool.ThreadPool.init(gpa, .{
        .max_threads = 2,
        .queue_capacity = 128,
    });
    defer pool.deinit();

    // Out-of-range idx must not OOB or panic.
    pool.releaseSubmitter(9999);
    pool.releaseSubmitter(std.math.maxInt(usize));
}
