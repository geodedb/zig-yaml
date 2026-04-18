// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

//! `thread-pool` provides a bounded, reusable thread-pool for devnw/zig codebases.
//! The public surface intentionally stays small while the implementation offers
//! multiple scheduler variants behind the same API.

const std = @import("std");

/// Re-export the `build_options` module so downstream test harnesses can
/// inspect compile-time-pinned flags (`-Dtimestamp-mode`,
/// `-Dscheduler-variant`, `-Dsingle-pool`) and adapt their configs
/// accordingly.  See `tests/common.zig::default_timestamp_mode`.
pub const build_options = @import("build_options");

pub const sync = @import("sync.zig");
pub const clock = @import("clock.zig");
pub const types = @import("types.zig");
pub const ThreadPool = @import("pool.zig").ThreadPool;
pub const TaskContext = @import("pool.zig").TaskContext;
pub const TaskFn = @import("pool.zig").TaskFn;
pub const BatchTask = @import("pool.zig").BatchTask;

pub const version = "0.2.0";

pub const Config = types.Config;
pub const SchedulerVariant = types.SchedulerVariant;
pub const QueueKind = types.QueueKind;
pub const TaskLane = types.TaskLane;
pub const BackpressurePolicy = types.BackpressurePolicy;
pub const SubmitOptions = types.SubmitOptions;
pub const ShutdownMode = types.ShutdownMode;
pub const TaskHandle = types.TaskHandle;
pub const WaitGroup = types.WaitGroup;
pub const CancellationToken = types.CancellationToken;
pub const LatencySummary = types.LatencySummary;
pub const WorkerStats = types.WorkerStats;
pub const ProcessMemoryStats = types.ProcessMemoryStats;
pub const Stats = types.Stats;
pub const WorkDeque = @import("queue/work_deque.zig").WorkDeque;
pub const BoundedRing = @import("queue/bounded_ring.zig").BoundedRing;
pub const RingQueue = @import("queue/ring_queue.zig").RingQueue;
pub const DescCache = @import("pool/desc_cache.zig").DescCache;

test {
    std.testing.refAllDecls(@This());
}
