// SPDX-License-Identifier: MIT
// Copyright (c) 2024 DevNW

//! YAML Parser Performance Benchmarks
//! Run with: zig build bench

const std = @import("std");
const yaml = @import("yaml");

const Allocator = std.mem.Allocator;

/// Monotonic stopwatch. Zig 0.16 removed `std.time.Timer`; read the awake
/// (monotonic) clock through `std.Io` instead.
const Timer = struct {
    start_ns: i96,

    fn start() Timer {
        return .{ .start_ns = now() };
    }

    fn read(self: Timer) u64 {
        return @intCast(@max(now() - self.start_ns, 0));
    }

    fn now() i96 {
        const io = std.Io.Threaded.global_single_threaded.io();
        return std.Io.Clock.awake.now(io).nanoseconds;
    }
};

// ============================================================================
// Benchmark Infrastructure
// ============================================================================

const BenchmarkResult = struct {
    name: []const u8,
    iterations: u64,
    total_ns: u64,
    min_ns: u64,
    max_ns: u64,
    avg_ns: u64,
    ops_per_sec: f64,
    bytes_per_sec: ?f64,
};

fn runBenchmark(
    comptime name: []const u8,
    iterations: u64,
    input_size: ?usize,
    comptime func: fn (Allocator) anyerror!void,
) BenchmarkResult {
    const allocator = std.heap.page_allocator;

    var total_ns: u64 = 0;
    var min_ns: u64 = std.math.maxInt(u64);
    var max_ns: u64 = 0;

    var i: u64 = 0;
    while (i < iterations) : (i += 1) {
        const timer = Timer.start();
        func(allocator) catch {};
        const elapsed = timer.read();
        total_ns += elapsed;
        min_ns = @min(min_ns, elapsed);
        max_ns = @max(max_ns, elapsed);
    }

    const avg_ns = total_ns / iterations;
    const ops_per_sec = @as(f64, @floatFromInt(iterations)) / (@as(f64, @floatFromInt(total_ns)) / 1_000_000_000.0);

    const bytes_per_sec: ?f64 = if (input_size) |size|
        @as(f64, @floatFromInt(size * iterations)) / (@as(f64, @floatFromInt(total_ns)) / 1_000_000_000.0)
    else
        null;

    return .{
        .name = name,
        .iterations = iterations,
        .total_ns = total_ns,
        .min_ns = min_ns,
        .max_ns = max_ns,
        .avg_ns = avg_ns,
        .ops_per_sec = ops_per_sec,
        .bytes_per_sec = bytes_per_sec,
    };
}

fn printResult(result: BenchmarkResult) void {
    std.debug.print("{s:<40} ", .{result.name});
    std.debug.print("avg: {d:>10.2} us  ", .{@as(f64, @floatFromInt(result.avg_ns)) / 1000.0});
    std.debug.print("min: {d:>10.2} us  ", .{@as(f64, @floatFromInt(result.min_ns)) / 1000.0});
    std.debug.print("ops/s: {d:>12.2}", .{result.ops_per_sec});
    if (result.bytes_per_sec) |bps| {
        std.debug.print("  throughput: {d:>10.2} MB/s", .{bps / (1024.0 * 1024.0)});
    }
    std.debug.print("\n", .{});
}

// ============================================================================
// Test Data
// ============================================================================

const small_yaml =
    \\name: test
    \\count: 42
    \\enabled: true
;

const medium_yaml =
    \\database:
    \\  host: localhost
    \\  port: 5432
    \\  username: admin
    \\  password: secret
    \\  options:
    \\    - ssl
    \\    - compression
    \\    - pooling
    \\users:
    \\  - name: alice
    \\    email: alice@example.com
    \\    roles:
    \\      - admin
    \\      - user
    \\  - name: bob
    \\    email: bob@example.com
    \\    roles:
    \\      - user
    \\settings:
    \\  theme: dark
    \\  language: en
    \\  notifications: true
;

const large_yaml =
    \\items:
    \\  - id: 0
    \\    name: item_0
    \\    value: 0
    \\  - id: 1
    \\    name: item_1
    \\    value: 10
    \\  - id: 2
    \\    name: item_2
    \\    value: 20
    \\  - id: 3
    \\    name: item_3
    \\    value: 30
    \\  - id: 4
    \\    name: item_4
    \\    value: 40
    \\  - id: 5
    \\    name: item_5
    \\    value: 50
    \\  - id: 6
    \\    name: item_6
    \\    value: 60
    \\  - id: 7
    \\    name: item_7
    \\    value: 70
    \\  - id: 8
    \\    name: item_8
    \\    value: 80
    \\  - id: 9
    \\    name: item_9
    \\    value: 90
    \\  - id: 10
    \\    name: item_10
    \\    value: 100
    \\  - id: 11
    \\    name: item_11
    \\    value: 110
    \\  - id: 12
    \\    name: item_12
    \\    value: 120
    \\  - id: 13
    \\    name: item_13
    \\    value: 130
    \\  - id: 14
    \\    name: item_14
    \\    value: 140
    \\  - id: 15
    \\    name: item_15
    \\    value: 150
    \\  - id: 16
    \\    name: item_16
    \\    value: 160
    \\  - id: 17
    \\    name: item_17
    \\    value: 170
    \\  - id: 18
    \\    name: item_18
    \\    value: 180
    \\  - id: 19
    \\    name: item_19
    \\    value: 190
;

const flow_yaml = "{a: 1, b: 2, c: 3, d: 4, e: 5, f: 6, g: 7, h: 8, i: 9, j: 10}";

const nested_yaml =
    \\level1:
    \\  level2:
    \\    level3:
    \\      level4:
    \\        level5:
    \\          value: deep
;

// ============================================================================
// Benchmark Functions
// ============================================================================

fn benchParseSmall(allocator: Allocator) !void {
    const docs = try yaml.loadAll(allocator, small_yaml, .{});
    defer {
        for (docs) |*d| d.deinit();
        allocator.free(docs);
    }
}

fn benchParseMedium(allocator: Allocator) !void {
    const docs = try yaml.loadAll(allocator, medium_yaml, .{});
    defer {
        for (docs) |*d| d.deinit();
        allocator.free(docs);
    }
}

fn benchParseLarge(allocator: Allocator) !void {
    const docs = try yaml.loadAll(allocator, large_yaml, .{});
    defer {
        for (docs) |*d| d.deinit();
        allocator.free(docs);
    }
}

fn benchParseFlow(allocator: Allocator) !void {
    const docs = try yaml.loadAll(allocator, flow_yaml, .{});
    defer {
        for (docs) |*d| d.deinit();
        allocator.free(docs);
    }
}

fn benchParseNested(allocator: Allocator) !void {
    const docs = try yaml.loadAll(allocator, nested_yaml, .{});
    defer {
        for (docs) |*d| d.deinit();
        allocator.free(docs);
    }
}

fn benchResolveSmall(allocator: Allocator) !void {
    const docs = try yaml.loadAll(allocator, small_yaml, .{});
    defer {
        for (docs) |*d| d.deinit();
        allocator.free(docs);
    }

    for (docs) |*doc| {
        var value = try yaml.resolveToValue(allocator, doc, .{});
        yaml.freeValue(allocator, &value);
    }
}

fn benchResolveMedium(allocator: Allocator) !void {
    const docs = try yaml.loadAll(allocator, medium_yaml, .{});
    defer {
        for (docs) |*d| d.deinit();
        allocator.free(docs);
    }

    for (docs) |*doc| {
        var value = try yaml.resolveToValue(allocator, doc, .{});
        yaml.freeValue(allocator, &value);
    }
}

fn benchEmitSmall(allocator: Allocator) !void {
    const docs = try yaml.loadAll(allocator, small_yaml, .{});
    defer {
        for (docs) |*d| d.deinit();
        allocator.free(docs);
    }

    var values = try allocator.alloc(yaml.Value, docs.len);
    defer {
        for (values) |*v| yaml.freeValue(allocator, v);
        allocator.free(values);
    }

    for (docs, 0..) |*doc, i| {
        values[i] = try yaml.resolveToValue(allocator, doc, .{});
    }

    const result = try yaml.dumpAll(allocator, values, .{});
    allocator.free(result);
}

fn benchToJson(allocator: Allocator) !void {
    const docs = try yaml.loadAll(allocator, medium_yaml, .{});
    defer {
        for (docs) |*d| d.deinit();
        allocator.free(docs);
    }

    for (docs) |*doc| {
        var value = try yaml.resolveToValue(allocator, doc, .{});
        defer yaml.freeValue(allocator, &value);

        const json = try yaml.toJson(allocator, value, .{});
        allocator.free(json);
    }
}

// ============================================================================
// Main
// ============================================================================

pub fn main() !void {
    std.debug.print("\n", .{});
    std.debug.print("YAML Parser Benchmarks\n", .{});
    std.debug.print("======================\n\n", .{});

    // Warm up
    _ = runBenchmark("warmup", 10, null, benchParseSmall);

    // Parsing benchmarks
    std.debug.print("Parsing:\n", .{});
    std.debug.print("---------\n", .{});
    printResult(runBenchmark("parse small (3 keys)", 10000, small_yaml.len, benchParseSmall));
    printResult(runBenchmark("parse medium (nested)", 5000, medium_yaml.len, benchParseMedium));
    printResult(runBenchmark("parse large (100 items)", 500, large_yaml.len, benchParseLarge));
    printResult(runBenchmark("parse flow style", 10000, flow_yaml.len, benchParseFlow));
    printResult(runBenchmark("parse deeply nested", 10000, nested_yaml.len, benchParseNested));

    std.debug.print("\n", .{});

    // Resolution benchmarks
    std.debug.print("Resolution:\n", .{});
    std.debug.print("------------\n", .{});
    printResult(runBenchmark("resolve small", 10000, null, benchResolveSmall));
    printResult(runBenchmark("resolve medium", 5000, null, benchResolveMedium));

    std.debug.print("\n", .{});

    // Emission benchmarks
    std.debug.print("Emission:\n", .{});
    std.debug.print("----------\n", .{});
    printResult(runBenchmark("emit small", 10000, null, benchEmitSmall));

    std.debug.print("\n", .{});

    // Conversion benchmarks
    std.debug.print("Conversion:\n", .{});
    std.debug.print("------------\n", .{});
    printResult(runBenchmark("to JSON", 5000, null, benchToJson));

    std.debug.print("\n", .{});
}
