//! YAML Parallel Operations Benchmark

const std = @import("std");
const parallel = @import("parallel");

const WARMUP_RUNS = 3;
const BENCH_RUNS = 5;

const BenchResult = struct {
    seq_ns: u64,
    par_ns: u64,

    fn speedup(self: BenchResult) f64 {
        if (self.par_ns == 0) return 0;
        return @as(f64, @floatFromInt(self.seq_ns)) / @as(f64, @floatFromInt(self.par_ns));
    }

    fn seqMs(self: BenchResult) f64 {
        return @as(f64, @floatFromInt(self.seq_ns)) / 1_000_000.0;
    }

    fn parMs(self: BenchResult) f64 {
        return @as(f64, @floatFromInt(self.par_ns)) / 1_000_000.0;
    }
};

fn double(x: i64) i64 {
    return x * 2;
}

fn add(a: i64, b: i64) i64 {
    return a + b;
}

fn benchParallelMapArray(allocator: std.mem.Allocator, size: usize) !BenchResult {
    const items = try allocator.alloc(i64, size);
    defer allocator.free(items);
    const results_seq = try allocator.alloc(i64, size);
    defer allocator.free(results_seq);
    const results_par = try allocator.alloc(i64, size);
    defer allocator.free(results_par);

    for (items, 0..) |*item, i| item.* = @intCast(i + 1);

    // Sequential
    var seq_total: u64 = 0;
    for (0..BENCH_RUNS) |_| {
        var timer = try std.time.Timer.start();
        for (items, 0..) |item, i| results_seq[i] = double(item);
        seq_total += timer.read();
        std.mem.doNotOptimizeAway(results_seq.ptr);
    }

    // Parallel
    var par_total: u64 = 0;
    for (0..BENCH_RUNS) |_| {
        var timer = try std.time.Timer.start();
        parallel.parallelMapArray(i64, i64, items, results_par, double);
        par_total += timer.read();
        std.mem.doNotOptimizeAway(results_par.ptr);
    }

    return .{ .seq_ns = seq_total / BENCH_RUNS, .par_ns = par_total / BENCH_RUNS };
}

fn benchParallelReduce(allocator: std.mem.Allocator, size: usize) !BenchResult {
    const data = try allocator.alloc(i64, size);
    defer allocator.free(data);

    for (data, 0..) |*d, i| d.* = @intCast(i + 1);

    // Sequential
    var seq_total: u64 = 0;
    for (0..BENCH_RUNS) |_| {
        var timer = try std.time.Timer.start();
        var acc: i64 = 0;
        for (data) |v| acc = add(acc, v);
        seq_total += timer.read();
        std.mem.doNotOptimizeAway(&acc);
    }

    // Parallel
    var par_total: u64 = 0;
    for (0..BENCH_RUNS) |_| {
        var timer = try std.time.Timer.start();
        const result = parallel.parallelReduce(i64, data, 0, add);
        par_total += timer.read();
        std.mem.doNotOptimizeAway(&result);
    }

    return .{ .seq_ns = seq_total / BENCH_RUNS, .par_ns = par_total / BENCH_RUNS };
}

fn printBenchResult(name: []const u8, size: usize, result: BenchResult) void {
    const speedup = result.speedup();
    const indicator: []const u8 = if (speedup >= 1.5) " [FAST]" else if (speedup >= 1.0) " [OK]" else " [SLOW]";
    std.debug.print("{s:<15} {d:>10} {d:>10.3} ms {d:>10.3} ms {d:>8.2}x{s}\n", .{
        name,
        size,
        result.seqMs(),
        result.parMs(),
        speedup,
        indicator,
    });
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n", .{});
    std.debug.print("========================================================================\n", .{});
    std.debug.print("          YAML Library - Spice Parallel Operations Benchmark           \n", .{});
    std.debug.print("========================================================================\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("Warmup: {d} runs, Benchmark: {d} runs (averaged)\n", .{ WARMUP_RUNS, BENCH_RUNS });
    std.debug.print("Legend: [FAST] = >1.5x speedup, [OK] = faster, [SLOW] = slower\n\n", .{});

    std.debug.print("{s:<15} {s:>10} {s:>12} {s:>12} {s:>10}\n", .{ "Operation", "Size", "Sequential", "Parallel", "Speedup" });
    std.debug.print("{s:->15} {s:->10} {s:->12} {s:->12} {s:->10}\n", .{ "", "", "", "", "" });

    const sizes = [_]usize{ 1_000, 10_000, 100_000, 1_000_000, 10_000_000 };

    // Map Array benchmark
    for (sizes) |size| {
        const result = try benchParallelMapArray(allocator, size);
        printBenchResult("Map Array", size, result);
    }
    std.debug.print("\n", .{});

    // Reduce benchmark
    for (sizes) |size| {
        const result = try benchParallelReduce(allocator, size);
        printBenchResult("Reduce (Sum)", size, result);
    }

    std.debug.print("\n", .{});
}
