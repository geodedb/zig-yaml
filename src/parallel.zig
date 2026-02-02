// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Parallel YAML operations using spice heartbeat scheduling.

const std = @import("std");
const build_options = @import("build_options");
const spice = if (build_options.enable_spice) @import("spice") else struct {
    pub const ThreadPool = void;
    pub const Task = void;
    pub fn Future(comptime I: type, comptime O: type) type {
        _ = I;
        _ = O;
        return void;
    }
};

var global_pool: if (build_options.enable_spice) ?spice.ThreadPool else void = if (build_options.enable_spice) null else {};
var pool_mutex: std.Thread.Mutex = .{};

pub fn getPool() if (build_options.enable_spice) *spice.ThreadPool else void {
    if (!build_options.enable_spice) return;

    pool_mutex.lock();
    defer pool_mutex.unlock();

    if (global_pool == null) {
        global_pool = spice.ThreadPool.init(std.heap.page_allocator);
        global_pool.?.start(.{});
    }
    return &global_pool.?;
}

pub fn deinitPool() void {
    if (!build_options.enable_spice) return;

    pool_mutex.lock();
    defer pool_mutex.unlock();

    if (global_pool) |*pool| {
        pool.deinit();
        global_pool = null;
    }
}

// ============================================================================
// Parallel Array/Sequence Processing
// ============================================================================

pub fn ArrayContext(comptime T: type, comptime R: type) type {
    return struct {
        items: []const T,
        results: []R,
    };
}

/// Process array items in parallel
pub fn parallelMapArray(
    comptime T: type,
    comptime R: type,
    items: []const T,
    results: []R,
    comptime mapFn: fn (T) R,
) void {
    std.debug.assert(items.len == results.len);

    if (!build_options.enable_spice or items.len < 32) {
        for (items, 0..) |item, i| results[i] = mapFn(item);
        return;
    }

    const pool = getPool();
    const Ctx = ArrayContext(T, R);
    _ = pool.call(void, ParallelMapArrayTask(T, R, mapFn).task, Ctx{ .items = items, .results = results });
}

fn ParallelMapArrayTask(comptime T: type, comptime R: type, comptime mapFn: fn (T) R) type {
    const Ctx = ArrayContext(T, R);
    return struct {
        pub fn task(t: *spice.Task, ctx: Ctx) void {
            const items = ctx.items;
            const results = ctx.results;

            if (items.len < 16) {
                for (items, 0..) |item, i| results[i] = mapFn(item);
                return;
            }

            const mid = items.len / 2;
            const left_ctx = Ctx{ .items = items[0..mid], .results = results[0..mid] };
            const right_ctx = Ctx{ .items = items[mid..], .results = results[mid..] };

            var fut = spice.Future(Ctx, void).init();
            fut.fork(t, task, right_ctx);

            t.call(void, task, left_ctx);
            if (fut.join(t) == null) {
                t.call(void, task, right_ctx);
            }
        }
    };
}

/// Parallel reduce
pub fn parallelReduce(
    comptime T: type,
    data: []const T,
    initial: T,
    comptime reduceFn: fn (T, T) T,
) T {
    if (!build_options.enable_spice or data.len < 512) {
        var acc = initial;
        for (data) |v| acc = reduceFn(acc, v);
        return acc;
    }

    const pool = getPool();
    const Ctx = ReduceContext(T);
    return pool.call(T, ParallelReduceTask(T, reduceFn).task, Ctx{ .data = data, .initial = initial });
}

fn ReduceContext(comptime T: type) type {
    return struct { data: []const T, initial: T };
}

fn ParallelReduceTask(comptime T: type, comptime reduceFn: fn (T, T) T) type {
    const Ctx = ReduceContext(T);
    return struct {
        pub fn task(t: *spice.Task, ctx: Ctx) T {
            const data = ctx.data;
            const initial = ctx.initial;

            if (data.len < 256) {
                var acc = initial;
                for (data) |v| acc = reduceFn(acc, v);
                return acc;
            }

            const mid = data.len / 2;
            const left_ctx = Ctx{ .data = data[0..mid], .initial = initial };
            const right_ctx = Ctx{ .data = data[mid..], .initial = initial };

            var fut = spice.Future(Ctx, T).init();
            fut.fork(t, task, right_ctx);

            const left_result = t.call(T, task, left_ctx);
            const right_result = if (fut.join(t)) |val| val else t.call(T, task, right_ctx);

            return reduceFn(left_result, right_result);
        }
    };
}

test "parallel reduce" {
    if (!build_options.enable_spice) return error.SkipZigTest;

    const data = [_]i32{ 1, 2, 3, 4, 5 };
    const sum = parallelReduce(i32, &data, 0, struct {
        fn add(a: i32, b: i32) i32 {
            return a + b;
        }
    }.add);
    try std.testing.expectEqual(@as(i32, 15), sum);
}
