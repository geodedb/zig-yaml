// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Parallel YAML operations using thread-pool scheduling.

const std = @import("std");
const tp = @import("thread_pool");

var global_pool: ?tp.ThreadPool = null;
var pool_mutex: std.Thread.Mutex = .{};

pub fn getPool() *tp.ThreadPool {
    pool_mutex.lock();
    defer pool_mutex.unlock();

    if (global_pool == null) {
        global_pool = tp.ThreadPool.init(std.heap.page_allocator, .{}) catch @panic("thread-pool: init failed");
    }
    return &global_pool.?;
}

pub fn deinitPool() void {
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

const MAX_CHUNKS = 64;

/// Process array items in parallel
pub fn parallelMapArray(
    comptime T: type,
    comptime R: type,
    items: []const T,
    results: []R,
    comptime mapFn: fn (T) R,
) void {
    std.debug.assert(items.len == results.len);

    const THRESHOLD = 32;
    if (items.len < THRESHOLD) {
        for (items, 0..) |item, i| results[i] = mapFn(item);
        return;
    }

    const Chunk = struct {
        items: []const T,
        results: []R,

        fn run(ctx_ptr: *anyopaque, _: *tp.TaskContext) void {
            const self: *@This() = @ptrCast(@alignCast(ctx_ptr));
            for (self.items, 0..) |item, i| self.results[i] = mapFn(item);
        }
    };

    const pool = getPool();
    const chunk_size = @max(THRESHOLD, items.len / MAX_CHUNKS);
    var chunks: [MAX_CHUNKS]Chunk = undefined;
    var batch: [MAX_CHUNKS]tp.BatchTask = undefined;
    var n: usize = 0;
    var idx: usize = 0;
    while (idx < items.len and n < MAX_CHUNKS) {
        const end = @min(idx + chunk_size, items.len);
        chunks[n] = .{ .items = items[idx..end], .results = results[idx..end] };
        batch[n] = .{ .task_fn = &Chunk.run, .ctx = @ptrCast(&chunks[n]) };
        n += 1;
        idx = end;
    }

    var wg = pool.waitGroup();
    _ = pool.submitBatch(batch[0..n], .{ .wait_group = &wg }) catch {
        for (items, 0..) |item, i| results[i] = mapFn(item);
        return;
    };
    wg.wait();
}

/// Parallel reduce
pub fn parallelReduce(
    comptime T: type,
    data: []const T,
    initial: T,
    comptime reduceFn: fn (T, T) T,
) T {
    const THRESHOLD = 512;
    if (data.len < THRESHOLD) {
        var acc = initial;
        for (data) |v| acc = reduceFn(acc, v);
        return acc;
    }

    const ReduceChunk = struct {
        data: []const T,
        initial: T,
        result: T,

        fn run(ctx_ptr: *anyopaque, _: *tp.TaskContext) void {
            const self: *@This() = @ptrCast(@alignCast(ctx_ptr));
            var acc = self.initial;
            for (self.data) |v| acc = reduceFn(acc, v);
            self.result = acc;
        }
    };

    const pool = getPool();
    const chunk_size = @max(THRESHOLD, data.len / MAX_CHUNKS);
    var chunks: [MAX_CHUNKS]ReduceChunk = undefined;
    var batch: [MAX_CHUNKS]tp.BatchTask = undefined;
    var n: usize = 0;
    var idx: usize = 0;
    while (idx < data.len and n < MAX_CHUNKS) {
        const end = @min(idx + chunk_size, data.len);
        chunks[n] = .{ .data = data[idx..end], .initial = initial, .result = initial };
        batch[n] = .{ .task_fn = &ReduceChunk.run, .ctx = @ptrCast(&chunks[n]) };
        n += 1;
        idx = end;
    }

    var wg = pool.waitGroup();
    _ = pool.submitBatch(batch[0..n], .{ .wait_group = &wg }) catch {
        var acc = initial;
        for (data) |v| acc = reduceFn(acc, v);
        return acc;
    };
    wg.wait();

    var acc = initial;
    for (chunks[0..n]) |chunk| acc = reduceFn(acc, chunk.result);
    return acc;
}

test "parallel reduce" {
    const data = [_]i32{ 1, 2, 3, 4, 5 };
    const sum = parallelReduce(i32, &data, 0, struct {
        fn add(a: i32, b: i32) i32 {
            return a + b;
        }
    }.add);
    try std.testing.expectEqual(@as(i32, 15), sum);
}
