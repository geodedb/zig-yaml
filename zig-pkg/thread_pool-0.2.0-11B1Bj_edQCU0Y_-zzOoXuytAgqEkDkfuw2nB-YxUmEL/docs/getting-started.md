# Getting Started

## Prerequisites

- Zig `0.16.0`
- Git submodules initialized if you want direct Tokio/Go comparisons:

```bash
git submodule update --init --recursive
```

- Rust and Cargo for the Tokio comparison binary
- A bootstrap Go installation in `PATH` for the first vendored-Go comparison
  run

## Build The Library

```bash
make build
```

Or with Zig directly:

```bash
zig build build
```

## Run The Example

```bash
zig build example
```

The example in [examples/basic.zig](../examples/basic.zig) shows the smallest
useful flow: create a pool, submit tasks with a wait group, wait for
completion, then read a stats snapshot.

## Minimal Usage

```zig
const std = @import("std");
const thread_pool = @import("thread_pool");

fn task(ctx: *anyopaque, runtime: *thread_pool.TaskContext) void {
    _ = ctx;
    _ = runtime;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var pool = try thread_pool.ThreadPool.init(gpa.allocator(), .{
        .min_threads = 2,
        .max_threads = 2,
        .queue_capacity = 128,
        .local_queue_capacity = 32,
        .scheduler_variant = .work_stealing,
    });
    defer pool.deinit();

    var wg = pool.waitGroup();
    _ = try pool.submit(task, undefined, .{ .wait_group = &wg });
    wg.wait();
}
```

## Choose A Scheduler

- `global_queue`: simplest behavior and easiest baseline to reason about
- `work_stealing`: preferred for mixed workloads and current performance work
- `lane_extension`: extends the work-stealing model with a dedicated blocking
  lane

## Next Reads

- [API Reference](api-reference.md)
- [Examples](examples.md)
- [Testing](TESTING.md)
- [Runtime Comparison](RUNTIME_COMPARISON.md)
