const std = @import("std");

/// SPSC descriptor cache. The owner (submitter or worker thread) is the
/// single writer and reader. Accessed only from one thread's submit path.
/// Drain-on-release is called under a higher-level exclusion (release
/// CAS), so it also has single-writer semantics at that moment.
///
/// No atomic ops on push/pop/drain: the invariant is that only one thread
/// touches `DescCache` at a time. If this ever changes, every op needs
/// to become atomic and you should reach for a proper SPSC ring instead.
pub const DescCache = struct {
    pub const capacity: u32 = 32;

    indices: [capacity]u32 = undefined,
    head: u32 = 0,

    pub fn init() DescCache {
        return .{};
    }

    pub fn len(self: *const DescCache) usize {
        return self.head;
    }

    pub fn tryPop(self: *DescCache) ?u32 {
        if (self.head == 0) return null;
        self.head -= 1;
        return self.indices[self.head];
    }

    pub fn push(self: *DescCache, idx: u32) bool {
        if (self.head >= capacity) return false;
        self.indices[self.head] = idx;
        self.head += 1;
        return true;
    }

    /// Drains the entire cache into `out`, most-recently-pushed first (LIFO).
    /// Panics if `out.len < len()`. Resets the cache to empty.
    pub fn drainAll(self: *DescCache, out: []u32) usize {
        const n = self.head;
        if (out.len < n) std.debug.panic(
            "drainAll: output buffer too small (need {d}, got {d})",
            .{ n, out.len },
        );
        var i: u32 = 0;
        while (i < n) : (i += 1) out[i] = self.indices[n - 1 - i];
        self.head = 0;
        return n;
    }
};
