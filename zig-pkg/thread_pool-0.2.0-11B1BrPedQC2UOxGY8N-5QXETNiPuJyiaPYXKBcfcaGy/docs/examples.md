# Examples

## Basic Counter Example

The full runnable example lives at [examples/basic.zig](../examples/basic.zig).

It demonstrates:

- creating a `GeneralPurposeAllocator`
- creating a `ThreadPool`
- submitting tasks with a wait group
- waiting for completion
- reading a stats snapshot

## Batch Submission

Batch submission is covered in the integration test
[tests/integration.zig](../tests/integration.zig).

Use `submitBatch` when you already have a slice of tasks and want the pool to
amortize the notify-side work:

```zig
var tasks: [32]thread_pool.BatchTask = undefined;
for (&tasks) |*task| {
    task.* = .{
        .task_fn = common.counterTask,
        .ctx = @ptrCast(&counter),
    };
}
const result = try pool.submitBatch(&tasks, .{ .wait_group = &wg });
```

## Blocking Lane

The blocking-lane behavior is covered in
[tests/integration.zig](../tests/integration.zig).

Use it when you need long-running or sleeping tasks to avoid wedging the CPU
pool:

```zig
var pool = try thread_pool.ThreadPool.init(allocator, .{
    .min_threads = 4,
    .max_threads = 4,
    .queue_capacity = 128,
    .local_queue_capacity = 32,
    .scheduler_variant = .work_stealing,
    .allow_blocking_lane = true,
    .blocking_workers = 1,
});
```

Submit blocking work with:

```zig
_ = try pool.submit(task_fn, ctx, .{
    .wait_group = &wg,
    .lane = .blocking,
});
```

## Cancellation

Cancellation is cooperative. The token is checked by the runtime and can also
be checked inside your task if the body does longer-lived work. See the unit
test at [tests/unit.zig](../tests/unit.zig).
