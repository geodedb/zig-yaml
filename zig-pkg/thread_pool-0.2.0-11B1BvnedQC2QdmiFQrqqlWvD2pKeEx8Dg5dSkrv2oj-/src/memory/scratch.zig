const std = @import("std");
const sync = @import("../sync.zig");

pub const Accounting = struct {
    total_alloc_bytes: *std.atomic.Value(u64),
    total_free_bytes: *std.atomic.Value(u64),
    total_alloc_count: *std.atomic.Value(u64),
    live_bytes: *std.atomic.Value(u64),
    peak_live_bytes: *std.atomic.Value(u64),
    /// OBSERVABILITY-PIVOT / R-10: pool-wide memory budget in bytes.
    /// 0 means "unlimited" (preserves pre-R-10 behaviour).  When > 0,
    /// `reserve(bytes)` must be called before `recordAlloc(bytes)` on
    /// the growth path; `reserve` returns `error.PoolMemoryBudgetExceeded`
    /// if the allocation would push `live_bytes` past the budget.
    max_pool_memory_bytes: u64 = 0,

    pub fn recordAlloc(self: Accounting, bytes: usize) void {
        const amount = @as(u64, @intCast(bytes));
        _ = self.total_alloc_bytes.fetchAdd(amount, .monotonic);
        _ = self.total_alloc_count.fetchAdd(1, .monotonic);
        const live = self.live_bytes.fetchAdd(amount, .monotonic) + amount;
        updatePeak(self.peak_live_bytes, live);
    }

    pub fn recordFree(self: Accounting, bytes: usize) void {
        const amount = @as(u64, @intCast(bytes));
        _ = self.total_free_bytes.fetchAdd(amount, .monotonic);
        _ = self.live_bytes.fetchSub(amount, .monotonic);
    }

    /// OBSERVABILITY-PIVOT / R-10: reservation check. Zero-budget is the
    /// fast path (single branch, no atomic read). When a budget is set,
    /// returns `error.PoolMemoryBudgetExceeded` if the prospective
    /// allocation would push `live_bytes` past `max_pool_memory_bytes`.
    /// Intended for runtime-growing allocations (scratch arenas); init-
    /// time allocations are deterministic and bypass this check.
    pub fn reserve(self: Accounting, bytes: usize) error{PoolMemoryBudgetExceeded}!void {
        if (self.max_pool_memory_bytes == 0) return;
        const amount = @as(u64, @intCast(bytes));
        const current = self.live_bytes.load(.monotonic);
        if (current + amount > self.max_pool_memory_bytes) {
            return error.PoolMemoryBudgetExceeded;
        }
    }

    pub fn updatePeak(counter: *std.atomic.Value(u64), value: u64) void {
        var current = counter.load(.monotonic);
        while (value > current) {
            const previous = counter.cmpxchgWeak(current, value, .monotonic, .monotonic);
            if (previous == null) return;
            current = previous.?;
        }
    }
};

pub const WorkerScratch = struct {
    allocator: std.mem.Allocator,
    accounting: Accounting,
    cap_bytes: usize,
    buffer: ?[]u8 = null,
    fba: ?std.heap.FixedBufferAllocator = null,
    current_bytes: usize = 0,
    peak_bytes: usize = 0,
    /// Slow-path serialization for overlapping purge callers. The normal
    /// owning-worker task path remains lock-free; this only prevents
    /// external quiescent purge and the worker's own idle-time purge from
    /// racing each other and double-freeing the backing buffer.
    purge_mutex: sync.Mutex = .{},
    /// Invariant: the worker task fast path is single-thread-owned. `purge()`
    /// is only legal once the pool is quiescent (`active_tasks == 0 &&
    /// queued_tasks == 0`) or from the owning worker's idle path after it has
    /// left task execution. That lets `beginTask()`, `alloc()`, and
    /// `finishTask()` stay lock-free on the normal path.
    pub fn init(allocator: std.mem.Allocator, accounting: Accounting, cap_bytes: usize) WorkerScratch {
        return .{
            .allocator = allocator,
            .accounting = accounting,
            .cap_bytes = cap_bytes,
        };
    }

    pub fn beginTask(self: *WorkerScratch) !void {
        self.current_bytes = 0;
        if (self.buffer) |buf| {
            self.fba = std.heap.FixedBufferAllocator.init(buf);
        } else {
            self.fba = null;
        }
    }

    pub fn finishTask(self: *WorkerScratch) void {
        if (self.fba) |fba| {
            self.current_bytes = fba.end_index;
            if (self.current_bytes > self.peak_bytes) self.peak_bytes = self.current_bytes;
        } else {
            self.current_bytes = 0;
        }
    }

    pub fn alloc(self: *WorkerScratch, comptime T: type, count: usize) ![]T {
        try self.ensureBuffer();
        if (self.fba == null) return error.ScratchUnavailable;
        var fba = &self.fba.?;
        const slice = try fba.allocator().alloc(T, count);
        self.current_bytes = fba.end_index;
        if (self.current_bytes > self.peak_bytes) self.peak_bytes = self.current_bytes;
        return slice;
    }

    pub fn purge(self: *WorkerScratch) void {
        self.purge_mutex.lock();
        defer self.purge_mutex.unlock();
        if (self.buffer) |buf| {
            self.accounting.recordFree(buf.len);
            self.allocator.free(buf);
        }
        self.buffer = null;
        self.fba = null;
        self.current_bytes = 0;
    }

    pub fn bytesCurrent(self: *WorkerScratch) usize {
        return self.current_bytes;
    }

    pub fn bytesPeak(self: *WorkerScratch) usize {
        return self.peak_bytes;
    }

    fn ensureBuffer(self: *WorkerScratch) !void {
        if (self.cap_bytes == 0 or self.buffer != null) return;
        // OBSERVABILITY-PIVOT / R-10: check the pool-wide memory budget
        // before consuming allocator memory. Zero-budget (the default)
        // takes the single-branch fast path inside `reserve`.
        try self.accounting.reserve(self.cap_bytes);
        const buf = try self.allocator.alloc(u8, self.cap_bytes);
        self.accounting.recordAlloc(buf.len);
        self.buffer = buf;
        self.fba = std.heap.FixedBufferAllocator.init(buf);
    }
};

test "worker scratch respects fixed cap and purge" {
    var total_alloc = std.atomic.Value(u64).init(0);
    var total_free = std.atomic.Value(u64).init(0);
    var total_count = std.atomic.Value(u64).init(0);
    var live = std.atomic.Value(u64).init(0);
    var peak = std.atomic.Value(u64).init(0);
    const accounting = Accounting{
        .total_alloc_bytes = &total_alloc,
        .total_free_bytes = &total_free,
        .total_alloc_count = &total_count,
        .live_bytes = &live,
        .peak_live_bytes = &peak,
    };

    var scratch = WorkerScratch.init(std.testing.allocator, accounting, 64);
    try scratch.beginTask();
    _ = try scratch.alloc(u8, 32);
    scratch.finishTask();
    try std.testing.expect(scratch.bytesCurrent() >= 32);
    scratch.purge();
    try std.testing.expectEqual(@as(usize, 0), scratch.bytesCurrent());
}

test "worker scratch defers allocation until first alloc and reuses the buffer" {
    var total_alloc = std.atomic.Value(u64).init(0);
    var total_free = std.atomic.Value(u64).init(0);
    var total_count = std.atomic.Value(u64).init(0);
    var live = std.atomic.Value(u64).init(0);
    var peak = std.atomic.Value(u64).init(0);
    const accounting = Accounting{
        .total_alloc_bytes = &total_alloc,
        .total_free_bytes = &total_free,
        .total_alloc_count = &total_count,
        .live_bytes = &live,
        .peak_live_bytes = &peak,
    };

    var scratch = WorkerScratch.init(std.testing.allocator, accounting, 64);

    try scratch.beginTask();
    scratch.finishTask();
    try std.testing.expectEqual(@as(u64, 0), total_count.load(.acquire));
    try std.testing.expectEqual(@as(u64, 0), live.load(.acquire));

    try scratch.beginTask();
    _ = try scratch.alloc(u8, 16);
    scratch.finishTask();
    try std.testing.expectEqual(@as(u64, 1), total_count.load(.acquire));
    try std.testing.expectEqual(@as(u64, 64), live.load(.acquire));

    try scratch.beginTask();
    _ = try scratch.alloc(u8, 8);
    scratch.finishTask();
    try std.testing.expectEqual(@as(u64, 1), total_count.load(.acquire));

    scratch.purge();
    try std.testing.expectEqual(@as(u64, 64), total_free.load(.acquire));
    try std.testing.expectEqual(@as(u64, 0), live.load(.acquire));
}

test "worker scratch serializes overlapping purge callers" {
    var total_alloc = std.atomic.Value(u64).init(0);
    var total_free = std.atomic.Value(u64).init(0);
    var total_count = std.atomic.Value(u64).init(0);
    var live = std.atomic.Value(u64).init(0);
    var peak = std.atomic.Value(u64).init(0);
    const accounting = Accounting{
        .total_alloc_bytes = &total_alloc,
        .total_free_bytes = &total_free,
        .total_alloc_count = &total_count,
        .live_bytes = &live,
        .peak_live_bytes = &peak,
    };

    var scratch = WorkerScratch.init(std.testing.allocator, accounting, 64);
    try scratch.beginTask();
    _ = try scratch.alloc(u8, 16);
    scratch.finishTask();

    const Purger = struct {
        fn run(shared: *WorkerScratch, start: *std.atomic.Value(u8)) void {
            while (start.load(.acquire) == 0) {
                std.atomic.spinLoopHint();
            }
            shared.purge();
        }
    };

    var start = std.atomic.Value(u8).init(0);
    const t1 = try std.Thread.spawn(.{}, Purger.run, .{ &scratch, &start });
    const t2 = try std.Thread.spawn(.{}, Purger.run, .{ &scratch, &start });
    start.store(1, .release);
    t1.join();
    t2.join();

    try std.testing.expectEqual(@as(u64, 1), total_count.load(.acquire));
    try std.testing.expectEqual(@as(u64, 64), total_free.load(.acquire));
    try std.testing.expectEqual(@as(u64, 0), live.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), scratch.bytesCurrent());
}
