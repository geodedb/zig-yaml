const std = @import("std");
const types = @import("../types.zig");

pub const LatencyHistogram = struct {
    const bucket_count = 64;
    const Atomic = std.atomic.Value(u64);

    counts: [bucket_count]Atomic = [_]Atomic{Atomic.init(0)} ** bucket_count,
    count: Atomic = Atomic.init(0),
    min_ns: Atomic = Atomic.init(std.math.maxInt(u64)),
    max_ns: Atomic = Atomic.init(0),
    sum_ns: Atomic = Atomic.init(0),

    /// Record a latency observation.  Called by a single worker thread on its
    /// own histogram, but the fields must be atomic because `merge()` may read
    /// them concurrently from `statsSnapshot()`.
    pub fn observe(self: *LatencyHistogram, value_ns: u64) void {
        const bucket = bucketIndex(value_ns);
        _ = self.counts[bucket].fetchAdd(1, .monotonic);
        _ = self.count.fetchAdd(1, .monotonic);
        _ = self.sum_ns.fetchAdd(value_ns, .monotonic);

        // CAS loop to update min_ns.
        var cur_min = self.min_ns.load(.monotonic);
        while (value_ns < cur_min) {
            cur_min = self.min_ns.cmpxchgWeak(cur_min, value_ns, .monotonic, .monotonic) orelse break;
        }

        // CAS loop to update max_ns.
        var cur_max = self.max_ns.load(.monotonic);
        while (value_ns > cur_max) {
            cur_max = self.max_ns.cmpxchgWeak(cur_max, value_ns, .monotonic, .monotonic) orelse break;
        }
    }

    /// Merge another histogram's values into this one.  `other` is typically a
    /// per-worker histogram that may be concurrently updated by its owner
    /// thread, so all reads from `other` use atomic loads.  `self` is assumed
    /// to be thread-local (e.g. a freshly-initialised accumulator inside
    /// `statsSnapshot()`), but uses atomic ops for field-type consistency.
    pub fn merge(self: *LatencyHistogram, other: *const LatencyHistogram) void {
        var i: usize = 0;
        while (i < bucket_count) : (i += 1) {
            const v = other.counts[i].load(.monotonic);
            _ = self.counts[i].fetchAdd(v, .monotonic);
        }
        const other_count = other.count.load(.monotonic);
        _ = self.count.fetchAdd(other_count, .monotonic);
        _ = self.sum_ns.fetchAdd(other.sum_ns.load(.monotonic), .monotonic);
        if (other_count > 0) {
            const other_min = other.min_ns.load(.monotonic);
            var cur_min = self.min_ns.load(.monotonic);
            while (other_min < cur_min) {
                cur_min = self.min_ns.cmpxchgWeak(cur_min, other_min, .monotonic, .monotonic) orelse break;
            }
            const other_max = other.max_ns.load(.monotonic);
            var cur_max = self.max_ns.load(.monotonic);
            while (other_max > cur_max) {
                cur_max = self.max_ns.cmpxchgWeak(cur_max, other_max, .monotonic, .monotonic) orelse break;
            }
        }
    }

    /// Produce a summary snapshot.  Typically called on a thread-local merged
    /// histogram, so contention is not expected.
    ///
    /// OBSERVABILITY-PIVOT / R-01: p999_ns and p9999_ns surface the log2
    /// bucket boundary that crosses the 99.9/99.99 percentiles.  The
    /// quantisation is load-bearing — these are operator-facing tail
    /// indicators, not precise ns values.
    pub fn summary(self: *const LatencyHistogram) types.LatencySummary {
        const c = self.count.load(.monotonic);
        if (c == 0) return .{};
        return .{
            .count = c,
            .min_ns = self.min_ns.load(.monotonic),
            .mean_ns = self.sum_ns.load(.monotonic) / c,
            .p50_ns = self.quantileScaled(50, 100),
            .p95_ns = self.quantileScaled(95, 100),
            .p99_ns = self.quantileScaled(99, 100),
            .p999_ns = self.quantileScaled(999, 1000),
            .p9999_ns = self.quantileScaled(9999, 10000),
            .max_ns = self.max_ns.load(.monotonic),
        };
    }

    fn bucketIndex(value_ns: u64) usize {
        if (value_ns <= 1) return 0;
        var idx: usize = 0;
        var value = value_ns;
        while (value > 1 and idx < bucket_count - 1) : (idx += 1) {
            value >>= 1;
        }
        return idx;
    }

    fn bucketUpperBound(index: usize) u64 {
        if (index == 0) return 1;
        if (index >= bucket_count - 1) return std.math.maxInt(u64);
        return @as(u64, 1) << @as(u6, @intCast(index));
    }

    fn quantile(self: *const LatencyHistogram, percentile: u8) u64 {
        return self.quantileScaled(percentile, 100);
    }

    /// Generalized rank-in-histogram lookup.  `numerator / denominator`
    /// ∈ [0, 1].  Used by the R-01 p999 / p9999 summary fields.
    fn quantileScaled(self: *const LatencyHistogram, numerator: u64, denominator: u64) u64 {
        const c = self.count.load(.monotonic);
        if (c == 0) return 0;
        const target = @max((c * numerator + (denominator - 1)) / denominator, 1);
        var seen: u64 = 0;
        for (self.counts, 0..) |bucket_atomic, idx| {
            seen += bucket_atomic.load(.monotonic);
            if (seen >= target) return bucketUpperBound(idx);
        }
        return self.max_ns.load(.monotonic);
    }
};

test "latency histogram records quantiles" {
    var histogram = LatencyHistogram{};
    histogram.observe(10);
    histogram.observe(20);
    histogram.observe(30);
    const summary = histogram.summary();
    try std.testing.expectEqual(@as(u64, 3), summary.count);
    try std.testing.expect(summary.p50_ns >= 10);
    try std.testing.expect(summary.max_ns >= 30);
}
