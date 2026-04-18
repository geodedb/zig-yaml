# Usage Guide

Complete guide to using `thread-pool` as a dependency in your Zig project.
Covers every public API surface from basic submission through lane isolation,
per-submitter queues, and production observability.

## Adding the Dependency

In your `build.zig.zon`, add the dependency:

```zon
.dependencies = .{
    .thread_pool = .{
        .url = "https://github.com/devnw/thread-pool/archive/<commit>.tar.gz",
        .hash = "<hash>",
    },
},
```

Then in your `build.zig`, import the module:

```zig
const thread_pool_dep = b.dependency("thread_pool", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("thread_pool", thread_pool_dep.module("thread_pool"));
```

## Quick Start

```zig
const std = @import("std");
const tp = @import("thread_pool");

const Counter = struct {
    value: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
};

fn incrementTask(raw_ctx: *anyopaque, runtime: *tp.TaskContext) void {
    _ = runtime;
    const counter: *Counter = @ptrCast(@alignCast(raw_ctx));
    _ = counter.value.fetchAdd(1, .monotonic);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var pool = try tp.ThreadPool.init(gpa.allocator(), .{
        .max_threads = 8,
        .queue_capacity = 4096,
        .scheduler_variant = .work_stealing,
    });
    defer pool.deinit();

    var wg = pool.waitGroup();
    var counter = Counter{};
    for (0..1000) |_| {
        _ = try pool.submit(incrementTask, @ptrCast(&counter), .{
            .wait_group = &wg,
        });
    }
    wg.wait();

    std.debug.print("count = {d}\n", .{counter.value.load(.acquire)});
}
```

## Task Functions

Every task function has the signature:

```zig
fn(ctx: *anyopaque, runtime: *tp.TaskContext) void
```

- `ctx` is an opaque pointer you pass at submission time — cast it back inside
  the task to access your data.
- `runtime` gives the task access to cancellation, scratch memory, the worker
  index, and which lane the task is running on.

Cast your context pointer with `@ptrCast(@alignCast(raw_ctx))`. The pool holds
no ownership over `ctx` — you are responsible for ensuring the pointed-to data
outlives the task.

## Pool Configuration

`ThreadPool.init` takes an allocator and a `Config` struct. Every field has a
sensible default; you only need to set the ones you care about.

### Thread counts

```zig
.max_threads = 0,  // 0 = auto-detect from CPU count (clamped to 64)
.min_threads = 0,  // 0 = same as max_threads after normalization
```

The pool hard-caps at 64 workers because the internal steal-scan bitmap is a
single `u64`.

### Queue sizing

```zig
.queue_capacity = 1024,        // global inject queue (rounded to power-of-two)
.local_queue_capacity = 256,   // per-worker local queue (rounded to power-of-two)
.inject_batch_size = 32,       // max tasks moved inject → local in one batch
.steal_batch_size = 8,         // max tasks stolen per steal attempt (ring queue)
```

`queue_capacity` bounds the total number of in-flight task descriptors. If you
expect bursty submission, size this to your expected burst depth.
`local_queue_capacity` controls how much work a single worker can buffer before
spilling to the global queue.

### Scheduler variant

```zig
.scheduler_variant = .global_queue,   // default — all tasks go through inject queue
.scheduler_variant = .work_stealing,  // workers prefer local work, steal from peers
.scheduler_variant = .lane_extension, // work_stealing + dedicated blocking lane
```

**Recommendation**: use `.work_stealing` for general workloads. Use
`.lane_extension` when you need to isolate blocking or long-running tasks from
CPU-bound work.

### Timing and lifecycle

```zig
.idle_park_after_ns = 250_000,       // 250us — idle workers park after this
.idle_purge_after_ns = 5_000_000,    // 5ms — idle workers release scratch memory
.deinit_timeout_ns = 30_000_000_000, // 30s — max time deinit waits for drain
.timestamp_mode = .full,             // .full records per-task latency; .disabled saves ~40-80ns/task
```

Set `.timestamp_mode = .disabled` in latency-sensitive paths where you don't
need per-task histograms.

### Wake coalescing

```zig
.wake_coalesce_batch = 32,  // signal workers every Nth release, not every release
```

This amortizes futex wake cost across multiple submissions. The default of 32
is well-tuned for high-throughput workloads. Set to 0 to disable coalescing
if you need minimal wake latency for sparse submissions.

## Submitting Tasks

### Single submission

```zig
const handle = try pool.submit(myTask, @ptrCast(&my_data), .{
    .wait_group = &wg,
    .backpressure = .block,
});
```

`submit` may block if backpressure is `.block` or `.block_with_timeout`.

### Non-blocking submission

```zig
const handle = pool.trySubmit(myTask, @ptrCast(&my_data), .{}) catch |err| switch (err) {
    error.QueueFull, error.TaskPoolExhausted => {
        // handle capacity exhaustion
        return;
    },
    else => return err,
};
```

`trySubmit` never blocks — it returns `error.QueueFull` or
`error.TaskPoolExhausted` immediately if the pool is at capacity.

### Batch submission

```zig
var tasks: [64]tp.BatchTask = undefined;
for (&tasks, 0..) |*task, i| {
    task.* = .{
        .task_fn = myTask,
        .ctx = @ptrCast(&my_contexts[i]),
    };
}
const result = try pool.submitBatch(&tasks, .{
    .wait_group = &wg,
    .backpressure = .block,
});
// result.submitted == number actually enqueued
```

`submitBatch` amortizes the per-task atomic operations (counter increments,
wake scans) across the entire batch. On flood workloads this yields ~2x
throughput over individual `submit` calls.

If the pool hits capacity mid-batch with `.return_error`, it returns a partial
`SubmitBatchResult` reflecting how many were enqueued.

## Waiting for Completion

### Wait groups (recommended)

```zig
var wg = pool.waitGroup();
for (0..100) |_| {
    _ = try pool.submit(myTask, ctx, .{ .wait_group = &wg });
}
wg.wait();  // blocks until all 100 tasks complete
```

Pass `&wg` to every submission in the group. The pool increments the group
counter on submit and decrements it on task completion. `wg.wait()` blocks
until the counter reaches zero.

### Waitable handles (single task)

```zig
const handle = try pool.submit(myTask, ctx, .{ .waitable = true });
// ... do other work ...
try pool.wait(handle);  // blocks until this specific task completes
```

Use this when you need to wait on a single task's result. The task descriptor
is released when `wait` returns.

## Backpressure Policies

Control what happens when the pool's queues are full:

```zig
.backpressure = .return_error,       // default — returns error.QueueFull immediately
.backpressure = .block,              // blocks the submitter until capacity opens
.backpressure = .block_with_timeout, // blocks up to timeout_ns, then returns error.Timeout
```

With `.block_with_timeout`:

```zig
_ = try pool.submit(myTask, ctx, .{
    .backpressure = .block_with_timeout,
    .timeout_ns = 5_000_000,  // 5ms
});
```

For request-handling paths, prefer `.return_error` or short timeouts to avoid
blocking your caller indefinitely. Use `.block` for background producers that
can afford to wait.

## Cancellation

Cancellation is cooperative. Create a token, pass it with submissions, and
signal it when you want tasks to stop:

```zig
var cancel = tp.CancellationToken{};

_ = try pool.submit(myTask, ctx, .{
    .wait_group = &wg,
    .cancellation_token = &cancel,
});

// Later, from any thread:
cancel.cancel();
wg.wait();
```

Inside the task, check the runtime context:

```zig
fn myTask(raw_ctx: *anyopaque, runtime: *tp.TaskContext) void {
    const data: *MyData = @ptrCast(@alignCast(raw_ctx));
    for (data.items) |item| {
        if (runtime.isCancelled()) return;
        processItem(item);
    }
}
```

The pool checks the cancellation token before starting a task. If cancelled
before execution begins, the task transitions directly to the cancelled state
without running. Tasks already running must check `isCancelled()` themselves.

## Scratch Allocators

Each worker has a per-worker scratch allocator bounded by
`worker_scratch_cap_bytes` (default 64 KiB). Use it for short-lived
allocations that don't need to outlive the task:

```zig
fn myTask(raw_ctx: *anyopaque, runtime: *tp.TaskContext) void {
    const data: *MyData = @ptrCast(@alignCast(raw_ctx));
    const buffer = runtime.allocScratch(u8, 4096) catch return;
    // buffer is valid for the duration of this task
    processWithBuffer(data, buffer);
    // no need to free — scratch is reused across tasks on the same worker
}
```

Scratch memory is not freed between tasks — it persists on the worker and is
reused. Call `pool.purgeWorkerCaches()` when the pool is quiescent (no active
or queued tasks) to release scratch memory back to the allocator.

## Lane Isolation

Lanes let you separate blocking or long-running work from CPU-bound tasks so
they don't starve each other.

### Setup

```zig
var pool = try tp.ThreadPool.init(allocator, .{
    .max_threads = 8,
    .scheduler_variant = .work_stealing,  // or .lane_extension
    .allow_blocking_lane = true,
    .blocking_workers = 2,  // 2 of 8 workers serve the blocking lane
});
```

With this config, 6 workers serve the default lane and 2 serve the blocking
lane. `blocking_workers` is carved out of `max_threads`, not additive.

### Submitting to lanes

```zig
// CPU-bound work (default lane)
_ = try pool.submit(cpuTask, ctx, .{ .wait_group = &wg });

// Blocking work (blocking lane)
_ = try pool.submit(ioTask, ctx, .{
    .wait_group = &wg,
    .lane = .blocking,
});
```

### Independent queue sizing

Size the blocking lane queue independently when your lanes have different
depth profiles:

```zig
.blocking_queue_capacity = 32,   // blocking lane: small queue for a few long tasks
.queue_capacity = 4096,          // default lane: deep queue for thousands of CPU tasks
```

### Per-lane backpressure overrides

Force a backpressure policy at the pool level, regardless of what callers
request:

```zig
.blocking_backpressure = .return_error,  // never block submitters on a full blocking lane
.default_backpressure = .block,          // default lane always blocks on capacity
```

This is useful when request handlers submit to the blocking lane — forcing
`.return_error` prevents a slow blocking lane from stalling the request path.

### Cross-lane rebalancing

Blocking workers always fall back to the default lane when their own lane is
idle — this is always enabled.

To allow default workers to help drain the blocking lane (opt-in):

```zig
.cpu_helps_blocking = true,
```

This violates the isolation invariant — a blocking task on a CPU worker blocks
that core from CPU work. Only enable it if throughput matters more than
isolation.

## Per-Submitter Queues

When multiple external threads submit concurrently, they contend on the global
inject queue. Per-submitter queues give each submitter thread its own
work-stealing deque, eliminating CAS contention on the hot path.

### Setup

```zig
var pool = try tp.ThreadPool.init(allocator, .{
    .max_threads = 8,
    .scheduler_variant = .work_stealing,
    .max_submitter_queues = 4,       // reserve 4 submitter slots
    .submitter_queue_capacity = 256, // 0 = same as local_queue_capacity
});
```

### Usage from submitter threads

Each submitter thread registers before submitting and releases when done:

```zig
fn submitterThread(pool: *tp.ThreadPool) void {
    const idx = pool.registerSubmitter() catch return;
    defer pool.releaseSubmitter(idx);

    // All submit/submitBatch calls on this thread now go through
    // the dedicated per-submitter queue instead of the global inject queue.
    for (0..10_000) |_| {
        _ = pool.submit(myTask, ctx, .{}) catch break;
    }
}
```

Workers steal from submitter queues just like they steal from peer local
queues. On release, any remaining tasks in the submitter queue are drained
back into the global inject queue.

Submitter registration is thread-local — the queue binding follows the OS
thread, not the call site.

## Watchdog and Overflow Workers

The watchdog detects tasks that run longer than expected on the default lane
and can spawn temporary overflow workers to compensate.

### Setup

```zig
var pool = try tp.ThreadPool.init(allocator, .{
    .max_threads = 8,
    .scheduler_variant = .work_stealing,
    .watchdog_interval_ns = 1_000_000,           // check every 1ms
    .blocking_promotion_timeout_ns = 10_000_000, // flag tasks running > 10ms
    .max_overflow_workers = 4,                    // up to 4 temporary workers
});
```

Constraints:

- `max_threads + max_overflow_workers` must be ≤ 64.
- `watchdog_interval_ns > 0` requires `max_overflow_workers > 0`.

The watchdog spawns a dedicated thread that scans default-lane workers at the
configured interval. When it detects a stall, it spawns an overflow worker to
maintain throughput. Overflow workers retire automatically when the backlog
clears. The binary is identical to the non-watchdog path when
`watchdog_interval_ns = 0` (no thread spawned, no hot-path overhead).

Monitor watchdog activity through stats:

```zig
const stats = pool.statsSnapshot();
std.debug.print("stalls={d} spawns={d} active_overflow={d}\n", .{
    stats.watchdog_stalls_detected,
    stats.overflow_spawns,
    stats.overflow_active,
});
```

## Observability

### Stats snapshot

```zig
const stats = pool.statsSnapshot();
```

The snapshot includes:

| Category | Fields |
|---|---|
| **Task lifecycle** | `submitted`, `started`, `completed`, `cancelled`, `active_tasks` |
| **Queue state** | `queue_depth_current`, `queue_depth_peak` |
| **Worker activity** | `steals`, `steal_failures`, `wakeups`, `parks` |
| **Memory** | `total_alloc_bytes`, `live_bytes`, `peak_live_bytes`, process RSS |
| **Descriptors** | `task_desc_live`, `task_desc_peak` |
| **Latency histograms** | `task_wait_ns`, `task_exec_ns` (each with min/mean/p50/p95/p99/max) |
| **Watchdog** | `watchdog_stalls_detected`, `overflow_spawns`, `overflow_retires`, `overflow_active` |
| **Per-worker** | `worker_stats[]` with busy/idle ns, queue depth, parks, steals, scratch bytes |

Latency histograms require `.timestamp_mode = .full` (the default). With
`.disabled`, `task_wait_ns` and `task_exec_ns` will be zeroed.

### Per-worker metrics

```zig
for (stats.worker_stats) |ws| {
    std.debug.print("worker[{d}]: busy={d}ns idle={d}ns steals={d} queue={d}\n", .{
        ws.worker_index,
        ws.busy_ns,
        ws.idle_ns,
        ws.steals,
        ws.local_queue_depth,
    });
}
```

## Shutdown

### Via deinit (recommended)

```zig
defer pool.deinit();
```

`deinit` performs a drain shutdown bounded by `deinit_timeout_ns` (default
30s), then force-joins all worker threads. After this call the pool is
unusable.

### Explicit shutdown

For more control over shutdown behavior:

```zig
// Drain: wait for all queued + active tasks to finish
try pool.shutdown(.drain, null);

// Drain with timeout
pool.shutdown(.drain, 5_000_000_000) catch |err| {
    if (err == error.Timeout) {
        // 5s elapsed with tasks still in flight
    }
};

// Cancel pending: cancel queued tasks, wait for active ones
try pool.shutdown(.cancel_pending, null);
```

## Production Checklist

Recommended configuration for a production deployment:

```zig
var pool = try tp.ThreadPool.init(allocator, .{
    // Let the pool detect CPU count (capped at 64)
    .max_threads = 0,
    .scheduler_variant = .work_stealing,
    .queue_capacity = 8192,
    .local_queue_capacity = 256,

    // Backpressure: don't let callers block forever
    // (set per-submit or override at pool level)
    // .default_backpressure = .return_error,

    // Blocking lane for I/O-bound work
    .allow_blocking_lane = true,
    .blocking_workers = 2,
    .blocking_queue_capacity = 64,
    .blocking_backpressure = .return_error,

    // Disable per-task timestamps if latency histograms aren't needed
    // .timestamp_mode = .disabled,

    // Per-submitter queues if you have known concurrent producers
    // .max_submitter_queues = 4,

    // Watchdog for detecting unexpectedly long tasks
    // .watchdog_interval_ns = 5_000_000,
    // .blocking_promotion_timeout_ns = 50_000_000,
    // .max_overflow_workers = 4,
});
defer pool.deinit();
```

## Further Reading

- [Getting Started](getting-started.md) — minimal setup and first task
- [API Reference](api-reference.md) — complete type and method listing
- [Examples](examples.md) — batch submission, blocking lane, cancellation
- [Architecture](architecture.md) — scheduler internals and queue strategy
- [Runtime Comparison](RUNTIME_COMPARISON.md) — benchmarks vs Tokio and Go
