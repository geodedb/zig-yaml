const std = @import("std");
const common = @import("common.zig");

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const args = try init.minimal.args.toSlice(allocator);

    var baseline_path: ?[]const u8 = null;
    var current_path: ?[]const u8 = null;
    var idx: usize = 1;
    while (idx + 1 < args.len) : (idx += 1) {
        if (std.mem.eql(u8, args[idx], "--baseline")) baseline_path = args[idx + 1];
        if (std.mem.eql(u8, args[idx], "--current")) current_path = args[idx + 1];
    }
    if (baseline_path == null or current_path == null) {
        std.debug.print("usage: compare-bench --baseline <file> --current <file>\n", .{});
        return error.InvalidArguments;
    }

    const baseline_doc = try readDocument(allocator, init.io, baseline_path.?);
    const current_doc = try readDocument(allocator, init.io, current_path.?);

    var failures: usize = 0;
    for (current_doc.value.rows) |row| {
        const baseline = findMatch(baseline_doc.value.rows, row) orelse continue;
        const throughput_change = pctChange(baseline.throughput_ops_per_sec, row.throughput_ops_per_sec);
        const rss_change = pctChange(@as(f64, @floatFromInt(baseline.rss_current_bytes)), @as(f64, @floatFromInt(row.rss_current_bytes)));
        std.debug.print("{s}/{s} throughput {d:.2}% rss {d:.2}%\n", .{
            row.scenario_name,
            row.scheduler_variant,
            throughput_change,
            rss_change,
        });
        // Gate on throughput regression only. RSS varies too much across
        // environments (local vs CI container) for a tight threshold.
        // Convert absolute stddev (ops/sec) to percentage relative to the baseline
        // throughput. If stddev is 0 (older baseline without the field), treat the
        // noise floor as 0 so the 15% hard floor governs.
        const stddev_pct = if (baseline.throughput_ops_per_sec != 0)
            (baseline.throughput_stddev_ops_per_sec / baseline.throughput_ops_per_sec) * 100.0
        else
            0.0;
        const noise_gate = @max(15.0, 3.0 * stddev_pct);
        std.debug.print("  noise_gate={d:.2}% (stddev_pct={d:.2}%)\n", .{ noise_gate, stddev_pct });
        if (throughput_change < -noise_gate) {
            std.debug.print("  FAIL: regression {d:.2}% exceeds noise gate {d:.2}%\n", .{ -throughput_change, noise_gate });
            failures += 1;
        }
    }

    if (failures != 0) return error.BenchmarkRegression;
}

fn readDocument(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !std.json.Parsed(common.ResultDocument) {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(8 * 1024 * 1024));
    return std.json.parseFromSlice(common.ResultDocument, allocator, bytes, .{ .ignore_unknown_fields = true });
}

fn findMatch(rows: []const common.ResultRow, current: common.ResultRow) ?common.ResultRow {
    for (rows) |row| {
        if (std.mem.eql(u8, row.scenario_name, current.scenario_name) and
            std.mem.eql(u8, row.scheduler_variant, current.scheduler_variant) and
            row.worker_count == current.worker_count and
            row.submitter_count == current.submitter_count)
        {
            return row;
        }
    }
    return null;
}

fn pctChange(before: f64, after: f64) f64 {
    if (before == 0) return 0;
    return ((after - before) / before) * 100.0;
}
