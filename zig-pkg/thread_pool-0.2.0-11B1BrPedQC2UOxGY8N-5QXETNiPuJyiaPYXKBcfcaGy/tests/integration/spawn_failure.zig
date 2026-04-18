//! F-002 regression: if std.Thread.spawn fails partway through Core.init,
//! the errdefer must stop and join every worker that was already spawned
//! before freeing shared arrays. Otherwise live workers UAF on freed memory.
//!
//! Strategy: use std.testing.FailingAllocator to inject alloc failures at
//! increasing injection indices. The pool performs several allocations
//! before spawning each worker, so some indices land between worker spawns,
//! exercising the partial-spawn teardown path. The test asserts:
//!   1. No allocator leaks (checked by GeneralPurposeAllocator.deinit).
//!   2. No segfault/UAF from spawned workers running on freed memory.

const std = @import("std");
const thread_pool = @import("thread_pool");

test "F-002: partial init failure does not UAF or leak" {
    // Iterate over a range of failure-injection indices; one or more of these
    // will land between worker spawns and exercise the F-002 path. Step of 1
    // so no candidate index is skipped — spawn-failure landing is
    // timing-sensitive and halving coverage could mask a regression.
    var n: usize = 10;
    while (n < 80) : (n += 1) {
        var backing = std.heap.DebugAllocator(.{}){};
        defer {
            const leak_check = backing.deinit();
            // We cannot call std.testing.expect inside defer reliably after
            // a potential panic, but we want to surface leaks.  The
            // DebugAllocator will already print a report on leak; we do an
            // explicit check so the test frame sees a failure.
            if (leak_check == .leak) {
                std.debug.panic("F-002: allocator leak detected at fail_index={d}\n", .{n});
            }
        }

        var failing = std.testing.FailingAllocator.init(backing.allocator(), .{ .fail_index = n });
        const a = failing.allocator();

        var pool_or_err = thread_pool.ThreadPool.init(a, .{
            .max_threads = 4,
            .queue_capacity = 256,
        });
        if (pool_or_err) |*pool| {
            defer pool.deinit();
        } else |err| switch (err) {
            error.OutOfMemory,
            error.ThreadQuotaExceeded,
            error.SystemResources,
            => {
                // Expected — init failed; the test is that the allocator
                // reports no leaks and the process did not segfault.
            },
            else => return err,
        }
    }
}
