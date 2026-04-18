# Spice to Thread-Pool Migration Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace all spice thread pool usage across 39 Zig projects under `~/src/devnw/zig/` with the thread-pool library, consumed as a `build.zig.zon` dependency from gitlab.

**Architecture:** Each project replaces its `.spice` build.zig.zon entry with `.thread_pool` pointing to `git+https://gitlab.com/devnw/zig/thread-pool.git`. Build scripts wire the `thread_pool` module instead of `spice`. Source code migrates from spice's fork-join `pool.call()`/`Future.fork()/join()` API to thread-pool's `pool.submit()`/`submitBatch()`/`WaitGroup` API. Pool initialization uses `ThreadPool.init(allocator, .{})` with default config.

**Tech Stack:** Zig 0.15.2, thread-pool v0.2.0

---

## Project Inventory

| Category | Count | Projects |
|----------|-------|----------|
| **DEEP** | 29 | ai, capture, cli, config, dns, dpi, ds, ebnf, entropy, gql, hsm, i18n, json, ldap, mcp, oauth, oidc, oui, quic, rtree, slog, strings, tls, toml, uri, vulkan, yaml, zcap, zlint |
| **MEDIUM** | 6 | encrypted-fs, graph-storage, hnsw, wal, metrics, raft |
| **SHALLOW** | 3 | audit, grpc-zig, wireguard |
| **STANDALONE** | 1 | concurrency |

- **DEEP:** Has `src/parallel.zig` with spice fork-join patterns (recursive `Future.fork()/join()`)
- **MEDIUM:** Uses spice inline in source files (no dedicated parallel.zig wrapper)
- **SHALLOW:** Lists spice in build.zig.zon but no source code imports it
- **STANDALONE:** Custom thread pool implementation to replace with thread-pool dependency

---

## Common Patterns

These patterns are referenced by all subsequent tasks. Workers MUST read this section before executing any task.

### Pattern A: build.zig.zon Replacement

Replace the `.spice` dependency entry with `.thread_pool`:

**Before:**
```zig
.spice = .{
    .url = "git+https://gitlab.com/devnw/zig/spice.git#79a291ee55789160f9aa4af2ddf526fa38e15dc2",
    .hash = "spice-0.0.0-HnDb5-nKAABohkh8SemVSOtpb7nZestAanVGqrY2fuvC",
},
```

**After:**
```zig
.thread_pool = .{
    .url = "git+https://gitlab.com/devnw/zig/thread-pool.git#7275ae20b51c86278fdb7b4df526715fdf24eeb6",
    .hash = "thread_pool-0.2.0-11B1Bjc9OQCpsTlU23uENRGidyB6DoKgKTODN2-LpFGU",
},
```

To compute the hash:
1. Add the dependency without a `.hash` field
2. Run `zig build` — the error message prints the expected hash
3. Paste the hash value back

**Important:** Some projects pin different spice commits (`79a291ee...` or `bbf106dc...`). Replace ALL variants with the thread-pool entry above.

### Pattern B1: build.zig — Option A (With Parallel Module)

Projects that create a separate `parallel` module (json, quic, dns, cli, config, and most DEEP projects):

**Before:**
```zig
const enable_spice = b.option(bool, "spice", "Enable spice-based parallelism") orelse true;
const spice_mod: ?*std.Build.Module = if (enable_spice) blk: {
    const spice_dep = b.dependency("spice", .{ .target = target, .optimize = optimize });
    break :blk spice_dep.module("spice");
} else null;

// Later, creating the parallel module:
const parallel_mod: ?*std.Build.Module = if (enable_spice) blk: {
    break :blk b.addModule("parallel", .{
        .root_source_file = b.path("src/parallel.zig"),
        .target = target,
        .optimize = optimize,
    });
} else null;
if (parallel_mod) |pm| {
    if (spice_mod) |sm| pm.addImport("spice", sm);
}
```

**After:**
```zig
const enable_tp = b.option(bool, "thread-pool", "Enable thread-pool-based parallelism") orelse true;
const tp_mod: ?*std.Build.Module = if (enable_tp) blk: {
    const tp_dep = b.dependency("thread_pool", .{ .target = target, .optimize = optimize });
    break :blk tp_dep.module("thread_pool");
} else null;

// Later, creating the parallel module:
const parallel_mod: ?*std.Build.Module = if (enable_tp) blk: {
    break :blk b.addModule("parallel", .{
        .root_source_file = b.path("src/parallel.zig"),
        .target = target,
        .optimize = optimize,
    });
} else null;
if (parallel_mod) |pm| {
    if (tp_mod) |tm| pm.addImport("thread_pool", tm);
}
```

Key changes:
1. Build option renamed from `"spice"` to `"thread-pool"`
2. Dependency name: `"thread_pool"` (matches build.zig.zon key)
3. Module name: `"thread_pool"` (matches the library's addModule name)
4. Import name for parallel module: `"thread_pool"` instead of `"spice"`

### Pattern B2: build.zig — Option B (Direct Import)

Projects that wire spice directly into their main module (metrics, raft, encrypted-fs):

**Before:**
```zig
const spice_dep = b.dependency("spice", .{ .target = target, .optimize = optimize });
const spice_module = spice_dep.module("spice");

const module = b.addModule("mylib", .{
    .root_source_file = b.path("src/root.zig"),
    .target = target,
    .optimize = optimize,
    .imports = &.{
        .{ .name = "spice", .module = spice_module },
    },
});
```

**After:**
```zig
const tp_dep = b.dependency("thread_pool", .{ .target = target, .optimize = optimize });
const tp_module = tp_dep.module("thread_pool");

const module = b.addModule("mylib", .{
    .root_source_file = b.path("src/root.zig"),
    .target = target,
    .optimize = optimize,
    .imports = &.{
        .{ .name = "thread_pool", .module = tp_module },
    },
});
```

Also update any test modules that import spice directly:
```zig
// Before:
.imports = &.{ .{ .name = "spice", .module = spice_module } },
// After:
.imports = &.{ .{ .name = "thread_pool", .module = tp_module } },
```

### Pattern C: parallel.zig Rewrite Template

This is the core migration. The spice fork-join pattern becomes a flat submit/WaitGroup pattern.

**Before (spice parallel.zig — universal structure):**
```zig
const spice = @import("spice");
const std = @import("std");

// Global pool management
var global_pool: ?spice.ThreadPool = null;
var pool_mutex: std.Thread.Mutex = .{};

pub fn getPool() *spice.ThreadPool {
    pool_mutex.lock();
    defer pool_mutex.unlock();
    if (global_pool == null) {
        global_pool = spice.ThreadPool.init(std.heap.page_allocator);
        global_pool.?.start(.{});
    }
    return &global_pool.?;
}

pub fn deinitPool() void {
    pool_mutex.lock();
    defer pool_mutex.unlock();
    if (global_pool) |*pool| {
        pool.deinit();
        global_pool = null;
    }
}

// Example operation with fork-join
const OpContext = struct {
    items: []const Item,
    results: []Result,
};

fn parallelOpTask(task: *spice.Task, ctx: OpContext) void {
    if (ctx.items.len < 64) {
        for (ctx.items, 0..) |item, i| {
            ctx.results[i] = processItem(item);
        }
        return;
    }
    const mid = ctx.items.len / 2;
    var fut = spice.Future(OpContext, void).init();
    fut.fork(task, parallelOpTask, .{
        .items = ctx.items[mid..],
        .results = ctx.results[mid..],
    });
    task.call(void, parallelOpTask, .{
        .items = ctx.items[0..mid],
        .results = ctx.results[0..mid],
    });
    _ = fut.join(task);
}

pub fn parallelOp(items: []const Item, results: []Result) void {
    std.debug.assert(items.len == results.len);
    if (items.len < 64) {
        for (items, 0..) |item, i| {
            results[i] = processItem(item);
        }
        return;
    }
    const pool = getPool();
    _ = pool.call(void, parallelOpTask, OpContext{
        .items = items,
        .results = results,
    });
}
```

**After (thread-pool parallel.zig — universal structure):**
```zig
const tp = @import("thread_pool");
const std = @import("std");

// -- Global pool management --

var global_pool: ?tp.ThreadPool = null;
var pool_mutex: std.Thread.Mutex = .{};

pub fn getPool() *tp.ThreadPool {
    pool_mutex.lock();
    defer pool_mutex.unlock();
    if (global_pool == null) {
        global_pool = tp.ThreadPool.init(std.heap.page_allocator, .{}) catch
            @panic("thread-pool: init failed");
    }
    return &global_pool.?;
}

pub fn deinitPool() void {
    pool_mutex.lock();
    defer pool_mutex.unlock();
    if (global_pool) |*pool| {
        pool.deinit();
        global_pool = null;
    }
}

// -- Example operation with submit/WaitGroup --

const MAX_CHUNKS = 64;

const OpChunk = struct {
    items: []const Item,
    results: []Result,
};

fn opChunkTask(ctx_ptr: *anyopaque, _: *tp.TaskContext) void {
    const chunk: *OpChunk = @ptrCast(@alignCast(ctx_ptr));
    for (chunk.items, 0..) |item, i| {
        chunk.results[i] = processItem(item);
    }
}

pub fn parallelOp(items: []const Item, results: []Result) void {
    std.debug.assert(items.len == results.len);

    const THRESHOLD = 64;
    if (items.len < THRESHOLD) {
        for (items, 0..) |item, i| {
            results[i] = processItem(item);
        }
        return;
    }

    const pool = getPool();
    const chunk_size = @max(THRESHOLD, items.len / MAX_CHUNKS);

    var chunks: [MAX_CHUNKS]OpChunk = undefined;
    var batch: [MAX_CHUNKS]tp.BatchTask = undefined;
    var n: usize = 0;

    var i: usize = 0;
    while (i < items.len and n < MAX_CHUNKS) {
        const end = @min(i + chunk_size, items.len);
        chunks[n] = .{ .items = items[i..end], .results = results[i..end] };
        batch[n] = .{ .task_fn = &opChunkTask, .ctx = @ptrCast(&chunks[n]) };
        n += 1;
        i = end;
    }

    var wg = pool.waitGroup();
    _ = pool.submitBatch(batch[0..n], .{ .wait_group = &wg }) catch {
        for (items, 0..) |item, j| {
            results[j] = processItem(item);
        }
        return;
    };
    wg.wait();
}
```

**Key migration rules:**
1. `@import("spice")` becomes `@import("thread_pool")`
2. `spice.ThreadPool.init(allocator)` + `.start(.{})` becomes `tp.ThreadPool.init(allocator, .{}) catch @panic(...)`
3. Recursive fork-join becomes flat chunking with `submitBatch` + `WaitGroup`
4. Each parallel operation gets: a `ChunkContext` struct, a chunk task function, and the public wrapper
5. Task function signature: `fn(ctx_ptr: *anyopaque, _: *tp.TaskContext) void`
6. Stack-allocated chunk arrays are safe because `wg.wait()` blocks until completion
7. The `catch` fallback on `submitBatch` processes sequentially (handles queue-full edge case)
8. `MAX_CHUNKS = 64` matches thread-pool's max worker count (u64 bitmap)

**For operations that aggregate results (e.g., sum, count):**
```zig
const CountChunk = struct {
    items: []const Item,
    partial: *usize,
};

fn countChunkTask(ctx_ptr: *anyopaque, _: *tp.TaskContext) void {
    const chunk: *CountChunk = @ptrCast(@alignCast(ctx_ptr));
    var count: usize = 0;
    for (chunk.items) |item| {
        if (item.matches()) count += 1;
    }
    chunk.partial.* = count;
}

pub fn parallelCount(items: []const Item) usize {
    // ... threshold check, pool setup, chunking ...
    var partials: [MAX_CHUNKS]usize = [_]usize{0} ** MAX_CHUNKS;
    // ... chunks[n] = .{ .items = ..., .partial = &partials[n] } ...
    // ... submitBatch + wg.wait() ...
    var total: usize = 0;
    for (partials[0..n]) |p| total += p;
    return total;
}
```

**For operations with extra parameters (e.g., crypto key, options):**
```zig
const EncryptChunk = struct {
    inputs: []const Packet,
    outputs: [][]u8,
    results: []EncryptResult,
    key: CryptoKey,
};

fn encryptChunkTask(ctx_ptr: *anyopaque, _: *tp.TaskContext) void {
    const chunk: *EncryptChunk = @ptrCast(@alignCast(ctx_ptr));
    for (chunk.inputs, 0..) |pkt, i| {
        chunk.results[i] = encrypt(pkt, chunk.outputs[i], chunk.key);
    }
}
```

### Pattern D: Inline Spice Migration (MEDIUM projects)

For projects that use spice directly (not through parallel.zig):

**Before:**
```zig
const spice = @import("spice");

pub fn doWork(pool: *spice.ThreadPool, data: []const u8) Result {
    return pool.call(Result, struct {
        fn run(task: *spice.Task, ctx: WorkCtx) Result {
            var fut = spice.Future(WorkCtx, PartialResult).init();
            fut.fork(task, computePartial, ctx.right_half());
            const left = task.call(PartialResult, computePartial, ctx.left_half());
            const right = fut.join(task) orelse computePartial(task, ctx.right_half());
            return merge(left, right);
        }
    }.run, WorkCtx.from(data));
}
```

**After:**
```zig
const tp = @import("thread_pool");

pub fn doWork(pool: *tp.ThreadPool, data: []const u8) !Result {
    const chunk_size = @max(64, data.len / 64);
    var partials: [64]PartialResult = undefined;
    var chunks: [64]ChunkCtx = undefined;
    var batch: [64]tp.BatchTask = undefined;
    var n: usize = 0;

    var i: usize = 0;
    while (i < data.len and n < 64) {
        const end = @min(i + chunk_size, data.len);
        partials[n] = .{};
        chunks[n] = .{ .data = data[i..end], .result = &partials[n] };
        batch[n] = .{ .task_fn = &chunkFn, .ctx = @ptrCast(&chunks[n]) };
        n += 1;
        i = end;
    }

    var wg = pool.waitGroup();
    _ = try pool.submitBatch(batch[0..n], .{ .wait_group = &wg });
    wg.wait();

    var result = Result{};
    for (partials[0..n]) |p| result = merge(result, p);
    return result;
}
```

### Pattern E: Re-export Migration (metrics, raft)

**Before (root.zig):**
```zig
pub const spice = @import("spice");
```

**After (root.zig):**
```zig
pub const thread_pool = @import("thread_pool");
```

Downstream consumers that used `metrics.spice` must change to `metrics.thread_pool`.

---

## Phase 0: Preparation

### Task 1: Tag Thread-Pool Release and Verify Fetch

**Files:**
- None (thread-pool repo actions only)

- [ ] **Step 1: Verify the current commit is pushed to gitlab**

```bash
cd ~/src/devnw/zig/thread-pool
git push origin main
```

- [ ] **Step 2: Tag v0.2.0 release**

```bash
cd ~/src/devnw/zig/thread-pool
git tag -a v0.2.0 -m "v0.2.0: work-stealing pool with lanes, batched submit, wake coalescing"
git push origin v0.2.0
```

- [ ] **Step 3: Verify the dependency can be fetched**

Create a temporary test project:

```bash
mkdir /tmp/tp-fetch-test && cd /tmp/tp-fetch-test
cat > build.zig.zon << 'ZONE'
.{
    .name = .tp_fetch_test,
    .version = "0.0.1",
    .fingerprint = 0x0,
    .minimum_zig_version = "0.15.2",
    .dependencies = .{
        .thread_pool = .{
            .url = "git+https://gitlab.com/devnw/zig/thread-pool.git#7275ae20b51c86278fdb7b4df526715fdf24eeb6",
        },
    },
    .paths = .{ "build.zig", "build.zig.zon" },
}
ZONE
cat > build.zig << 'BUILD'
const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const tp_dep = b.dependency("thread_pool", .{ .target = target, .optimize = optimize });
    _ = tp_dep.module("thread_pool");
}
BUILD
zig build 2>&1
```

Expected: either success or an error containing the correct hash string. If hash error, record the hash value — it will be `thread_pool-0.2.0-11B1Bjc9OQCpsTlU23uENRGidyB6DoKgKTODN2-LpFGU` used by all subsequent tasks.

- [ ] **Step 4: Record the hash**

Save the hash value for use in all project migrations. Format: `thread_pool-0.2.0-<hash_suffix>`.

- [ ] **Step 5: Clean up**

```bash
rm -rf /tmp/tp-fetch-test
```

---

## Phase 1: Worked Examples (Full Code)

### Task 2: Migrate json (Simple DEEP)

**Files:**
- Modify: `~/src/devnw/zig/json/build.zig.zon`
- Modify: `~/src/devnw/zig/json/build.zig`
- Rewrite: `~/src/devnw/zig/json/src/parallel.zig`

- [ ] **Step 1: Update build.zig.zon**

In `~/src/devnw/zig/json/build.zig.zon`, replace the `.spice` dependency:

```zig
// Remove:
.spice = .{
    .url = "git+https://gitlab.com/devnw/zig/spice.git#79a291ee55789160f9aa4af2ddf526fa38e15dc2",
    .hash = "spice-0.0.0-HnDb5-nKAABohkh8SemVSOtpb7nZestAanVGqrY2fuvC",
},

// Add:
.thread_pool = .{
    .url = "git+https://gitlab.com/devnw/zig/thread-pool.git#7275ae20b51c86278fdb7b4df526715fdf24eeb6",
    .hash = "thread_pool-0.2.0-11B1Bjc9OQCpsTlU23uENRGidyB6DoKgKTODN2-LpFGU",
},
```

Use the hash recorded in Task 1 Step 4. If not yet known, omit `.hash`, run `zig build`, and paste the reported hash.

- [ ] **Step 2: Update build.zig**

Apply Pattern B1. In `~/src/devnw/zig/json/build.zig`:

1. Find the spice option/dependency block and replace per Pattern B1
2. Find where the parallel module imports spice and change to thread_pool
3. Search for any other `"spice"` string references and update

- [ ] **Step 3: Rewrite parallel.zig**

Read the current `~/src/devnw/zig/json/src/parallel.zig` to identify all parallel operations and their domain types. Then rewrite using Pattern C.

For each function in the file that follows the spice fork-join pattern:
1. Create a `*Chunk` struct holding the slice inputs/outputs for that operation
2. Create a chunk task function with signature `fn(ctx_ptr: *anyopaque, _: *tp.TaskContext) void`
3. Rewrite the public function to use flat chunking + submitBatch + WaitGroup

Preserve:
- All public function signatures (names, parameters, return types)
- All threshold values
- All result/context struct definitions that are part of the public API
- Sequential fallback paths

Replace:
- `@import("spice")` with `@import("thread_pool")`
- Global pool init from `spice.ThreadPool.init(alloc)` + `.start(.{})` to `tp.ThreadPool.init(alloc, .{}) catch @panic(...)`
- Fork-join task functions with chunk task functions
- `pool.call(void, taskFn, ctx)` with `submitBatch` + `wg.wait()`

- [ ] **Step 4: Verify build compiles**

```bash
cd ~/src/devnw/zig/json && zig build 2>&1
```

Expected: clean compilation. If hash mismatch, update build.zig.zon with the reported hash and retry.

- [ ] **Step 5: Run tests**

```bash
cd ~/src/devnw/zig/json && zig build test --summary all
```

Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
cd ~/src/devnw/zig/json
git add build.zig.zon build.zig src/parallel.zig
git commit -m "refactor: migrate from spice to thread-pool

Replace spice fork-join thread pool with thread-pool library.
Dependency now pulled from gitlab via build.zig.zon.
Parallel operations use submitBatch + WaitGroup instead of Future.fork/join."
```

---

### Task 3: Migrate quic (Complex DEEP)

**Files:**
- Modify: `~/src/devnw/zig/quic/build.zig.zon`
- Modify: `~/src/devnw/zig/quic/build.zig`
- Rewrite: `~/src/devnw/zig/quic/src/parallel.zig`

The quic parallel.zig is ~941 lines with 4+ parallel operations (AEAD encrypt, AEAD decrypt, header protection, loss detection). Each operation has its own context/result types.

- [ ] **Step 1: Update build.zig.zon**

Replace `.spice` with `.thread_pool` per Pattern A.

- [ ] **Step 2: Update build.zig**

Apply Pattern B1. The quic build.zig has a more complex module graph — the parallel module imports `quic_crypto` and is distributed to `quic_packet_legacy_mod`, `quic_packet_mod`, `quic_recovery_mod`, `quic_endpoint_mod`. All of these `addImport("parallel", pm)` calls remain unchanged. Only the spice→thread_pool wiring within the parallel module changes.

Find and update:
1. The `enable_spice` option → `enable_tp` / `"thread-pool"`
2. The `b.dependency("spice", ...)` → `b.dependency("thread_pool", ...)`
3. The `spice_dep.module("spice")` → `tp_dep.module("thread_pool")`
4. The `pm.addImport("spice", sm)` → `pm.addImport("thread_pool", tm)`

- [ ] **Step 3: Read current parallel.zig and identify operations**

```bash
cd ~/src/devnw/zig/quic
head -50 src/parallel.zig
grep "^pub fn" src/parallel.zig
```

Identify every public function, its domain types (context struct, result struct), and threshold values.

- [ ] **Step 4: Rewrite parallel.zig**

Apply Pattern C to each operation. The quic parallel.zig has operations like:

- `parallelAeadEncrypt` — encrypts packets in parallel, results in `[]AeadEncryptResult`
- `parallelAeadDecrypt` — decrypts packets, results in `[]AeadDecryptResult`
- `parallelHeaderProtect` — generates header protection masks
- `parallelLossDetect` — scans packets for losses, returns aggregated `LossDetectResult`

For each operation:
1. Define a `*Chunk` struct (e.g., `AeadEncryptChunk`) holding slice inputs/outputs + shared params (crypto key, etc.)
2. Define a chunk task function
3. Rewrite the public function with flat chunking + submitBatch + wg.wait()

For `parallelLossDetect` (aggregating operation), use the aggregation variant from Pattern C:
- Each chunk writes a partial result to a `partials[n]` array
- After `wg.wait()`, merge partial results into the final `LossDetectResult`

- [ ] **Step 5: Verify build compiles**

```bash
cd ~/src/devnw/zig/quic && zig build 2>&1
```

- [ ] **Step 6: Run tests**

```bash
cd ~/src/devnw/zig/quic && zig build test --summary all
```

- [ ] **Step 7: Commit**

```bash
cd ~/src/devnw/zig/quic
git add build.zig.zon build.zig src/parallel.zig
git commit -m "refactor: migrate from spice to thread-pool

Replace spice fork-join with thread-pool submitBatch/WaitGroup.
All 4 parallel crypto operations preserved with flat chunking."
```

---

### Task 4: Migrate metrics (MEDIUM + REEXPORT)

**Files:**
- Modify: `~/src/devnw/zig/metrics/build.zig.zon`
- Modify: `~/src/devnw/zig/metrics/build.zig`
- Modify: `~/src/devnw/zig/metrics/src/root.zig`
- Modify: `~/src/devnw/zig/metrics/src/registry.zig`
- Modify: `~/src/devnw/zig/metrics/tests/integration.zig`

The metrics project uses spice directly (no parallel.zig) and re-exports it from root.zig.

- [ ] **Step 1: Update build.zig.zon**

Replace `.spice` with `.thread_pool` per Pattern A.

- [ ] **Step 2: Update build.zig**

Apply Pattern B2. The metrics build.zig unconditionally imports spice and wires it to:
- The main `metrics` module
- Unit test modules
- Integration test modules
- Benchmark executables

Replace all instances of `"spice"` with `"thread_pool"` in import declarations.

- [ ] **Step 3: Update root.zig re-export**

Apply Pattern E:

```zig
// Before:
pub const spice = @import("spice");
// After:
pub const thread_pool = @import("thread_pool");
```

- [ ] **Step 4: Rewrite registry.zig spice usage**

Read `~/src/devnw/zig/metrics/src/registry.zig` and identify the `parallelSnapshot` function and any other spice usage.

The metrics registry uses nested `spice.Future` for parallel snapshot capture:

```zig
pub fn parallelSnapshot(self: *Registry, pool: *spice.ThreadPool) error{OutOfMemory}!Snapshot {
    return pool.call(Snapshot, struct {
        pub fn run(t: *spice.Task, args: ...) Snapshot {
            var gauge_fut = spice.Future(...).init();
            gauge_fut.fork(t, ...);
            // ... more forks ...
            _ = gauge_fut.join(t);
            // ...
        }
    }.run, ...);
}
```

Replace with thread-pool pattern. Change the function signature to accept `*tp.ThreadPool`:

```zig
pub fn parallelSnapshot(self: *Registry, pool: *tp.ThreadPool) error{OutOfMemory}!Snapshot {
    // Identify the independent snapshot operations (gauges, histograms, timers, etc.)
    // Submit each as a task via submitBatch + WaitGroup
    // Merge partial snapshots after wg.wait()
}
```

- [ ] **Step 5: Update tests**

In `~/src/devnw/zig/metrics/tests/integration.zig`, replace:
- `@import("spice")` with `@import("thread_pool")`
- `spice.ThreadPool.init(allocator)` + `.start(.{})` with `tp.ThreadPool.init(allocator, .{}) catch ...`
- `spice.ThreadPool` type references with `tp.ThreadPool`

- [ ] **Step 6: Verify and test**

```bash
cd ~/src/devnw/zig/metrics && zig build test --summary all
```

- [ ] **Step 7: Commit**

```bash
cd ~/src/devnw/zig/metrics
git add build.zig.zon build.zig src/root.zig src/registry.zig tests/integration.zig
git commit -m "refactor: migrate from spice to thread-pool

Replace spice with thread-pool for parallel metric snapshots.
Re-export changed from spice to thread_pool in public API."
```

---

## Phase 2: DEEP Projects (Remaining 26)

All projects below follow the same migration pattern as Task 2 (json). For each:
1. Apply Pattern A to build.zig.zon
2. Apply Pattern B1 to build.zig
3. Apply Pattern C to src/parallel.zig
4. Run `zig build test --summary all`
5. Commit

Each task lists the project path and any project-specific notes.

### Task 5: Migrate strings

**Path:** `~/src/devnw/zig/strings`
**Files:** build.zig.zon, build.zig, src/parallel.zig
**Notes:** Simple string operations (likely parallel search/transform). Follow Task 2 pattern exactly.

- [ ] Update build.zig.zon (Pattern A)
- [ ] Update build.zig (Pattern B1)
- [ ] Rewrite src/parallel.zig (Pattern C) — read file, identify ops, apply template
- [ ] Run: `cd ~/src/devnw/zig/strings && zig build test --summary all`
- [ ] Commit: `git commit -m "refactor: migrate from spice to thread-pool"`

### Task 6: Migrate uri

**Path:** `~/src/devnw/zig/uri`
**Files:** build.zig.zon, build.zig, src/parallel.zig
**Notes:** Parallel URI parsing. Follow Task 2 pattern.

- [ ] Update build.zig.zon (Pattern A)
- [ ] Update build.zig (Pattern B1)
- [ ] Rewrite src/parallel.zig (Pattern C)
- [ ] Run: `cd ~/src/devnw/zig/uri && zig build test --summary all`
- [ ] Commit

### Task 7: Migrate toml

**Path:** `~/src/devnw/zig/toml`
**Files:** build.zig.zon, build.zig, src/parallel.zig
**Notes:** Parallel TOML parsing. Follow Task 2 pattern.

- [ ] Update build.zig.zon (Pattern A)
- [ ] Update build.zig (Pattern B1)
- [ ] Rewrite src/parallel.zig (Pattern C)
- [ ] Run: `cd ~/src/devnw/zig/toml && zig build test --summary all`
- [ ] Commit

### Task 8: Migrate yaml

**Path:** `~/src/devnw/zig/yaml`
**Files:** build.zig.zon, build.zig, src/parallel.zig
**Notes:** Parallel YAML parsing. Follow Task 2 pattern.

- [ ] Update build.zig.zon (Pattern A)
- [ ] Update build.zig (Pattern B1)
- [ ] Rewrite src/parallel.zig (Pattern C)
- [ ] Run: `cd ~/src/devnw/zig/yaml && zig build test --summary all`
- [ ] Commit

### Task 9: Migrate ebnf

**Path:** `~/src/devnw/zig/ebnf`
**Files:** build.zig.zon, build.zig, src/parallel.zig
**Notes:** Parallel EBNF grammar parsing. Follow Task 2 pattern.

- [ ] Update build.zig.zon (Pattern A)
- [ ] Update build.zig (Pattern B1)
- [ ] Rewrite src/parallel.zig (Pattern C)
- [ ] Run: `cd ~/src/devnw/zig/ebnf && zig build test --summary all`
- [ ] Commit

### Task 10: Migrate entropy

**Path:** `~/src/devnw/zig/entropy`
**Files:** build.zig.zon, build.zig, src/parallel.zig
**Notes:** Parallel entropy/bootstrap analysis. May have aggregation ops — use aggregation variant from Pattern C.

- [ ] Update build.zig.zon (Pattern A)
- [ ] Update build.zig (Pattern B1)
- [ ] Rewrite src/parallel.zig (Pattern C)
- [ ] Run: `cd ~/src/devnw/zig/entropy && zig build test --summary all`
- [ ] Commit

### Task 11: Migrate tls

**Path:** `~/src/devnw/zig/tls`
**Files:** build.zig.zon, build.zig, src/parallel.zig
**Notes:** Parallel TLS operations (likely certificate validation, crypto). Follow Task 2 pattern.

- [ ] Update build.zig.zon (Pattern A)
- [ ] Update build.zig (Pattern B1)
- [ ] Rewrite src/parallel.zig (Pattern C)
- [ ] Run: `cd ~/src/devnw/zig/tls && zig build test --summary all`
- [ ] Commit

### Task 12: Migrate slog

**Path:** `~/src/devnw/zig/slog`
**Files:** build.zig.zon, build.zig, src/parallel.zig
**Notes:** Parallel structured logging. Also check `src/handlers/async_handler.zig` for direct spice usage — if present, apply Pattern D.

- [ ] Update build.zig.zon (Pattern A)
- [ ] Update build.zig (Pattern B1)
- [ ] Rewrite src/parallel.zig (Pattern C)
- [ ] Check and update src/handlers/async_handler.zig if it imports spice
- [ ] Run: `cd ~/src/devnw/zig/slog && zig build test --summary all`
- [ ] Commit

### Task 13: Migrate config

**Path:** `~/src/devnw/zig/config`
**Files:** build.zig.zon, build.zig, src/parallel.zig
**Notes:** Parallel config file loading/validation. Follow Task 2 pattern.

- [ ] Update build.zig.zon (Pattern A)
- [ ] Update build.zig (Pattern B1)
- [ ] Rewrite src/parallel.zig (Pattern C)
- [ ] Run: `cd ~/src/devnw/zig/config && zig build test --summary all`
- [ ] Commit

### Task 14: Migrate cli

**Path:** `~/src/devnw/zig/cli`
**Files:** build.zig.zon, build.zig, src/parallel.zig
**Notes:** Parallel CLI argument processing. Depends on config — ensure config (Task 13) is migrated first if cli imports config's parallel functionality. Otherwise independent.

- [ ] Update build.zig.zon (Pattern A)
- [ ] Update build.zig (Pattern B1)
- [ ] Rewrite src/parallel.zig (Pattern C)
- [ ] Run: `cd ~/src/devnw/zig/cli && zig build test --summary all`
- [ ] Commit

### Task 15: Migrate dns

**Path:** `~/src/devnw/zig/dns`
**Files:** build.zig.zon, build.zig, src/parallel.zig
**Notes:** ~932 lines with 4+ operations: zone parsing (threshold=64), DNSSEC validation (threshold=2), batch query (threshold=4), cache prefetch (threshold=8). Follow Task 3 (quic) pattern for multi-operation files. Depends on cli — ensure Task 14 done first.

- [ ] Update build.zig.zon (Pattern A)
- [ ] Update build.zig (Pattern B1)
- [ ] Read src/parallel.zig and identify all operations
- [ ] Rewrite src/parallel.zig (Pattern C, one chunk type per operation)
- [ ] Run: `cd ~/src/devnw/zig/dns && zig build test --summary all`
- [ ] Commit

### Task 16: Migrate mcp

**Path:** `~/src/devnw/zig/mcp`
**Files:** build.zig.zon, build.zig, src/parallel.zig
**Notes:** Parallel MCP message processing and pipelining. Also check `src/pipelining.zig` for direct spice usage.

- [ ] Update build.zig.zon (Pattern A)
- [ ] Update build.zig (Pattern B1)
- [ ] Rewrite src/parallel.zig (Pattern C)
- [ ] Check src/pipelining.zig for spice imports and update if needed
- [ ] Run: `cd ~/src/devnw/zig/mcp && zig build test --summary all`
- [ ] Commit

### Task 17: Migrate ai

**Path:** `~/src/devnw/zig/ai`
**Files:** build.zig.zon, build.zig, src/parallel.zig
**Notes:** ~651 lines. Operations: batch transform (threshold=8), metric compute (threshold=16), population eval (threshold=8), preprocessing (threshold=16). Also check `src/serving/`, `src/backend/`, `src/distributed/`, `src/cluster/`, `src/data/`, `src/hub/` for direct `std.Thread` usage — these may use thread spawning for servers/background tasks, which should be migrated if they represent parallelism.

- [ ] Update build.zig.zon (Pattern A)
- [ ] Update build.zig (Pattern B1)
- [ ] Rewrite src/parallel.zig (Pattern C)
- [ ] Grep for `std.Thread.spawn` in src/ — migrate any task-parallel usage to thread-pool submit
- [ ] Run: `cd ~/src/devnw/zig/ai && zig build test --summary all`
- [ ] Commit

### Task 18: Migrate vulkan

**Path:** `~/src/devnw/zig/vulkan`
**Files:** build.zig.zon, build.zig, src/parallel.zig
**Notes:** Parallel Vulkan pipeline operations. Follow Task 2 pattern.

- [ ] Update build.zig.zon (Pattern A)
- [ ] Update build.zig (Pattern B1)
- [ ] Rewrite src/parallel.zig (Pattern C)
- [ ] Run: `cd ~/src/devnw/zig/vulkan && zig build test --summary all`
- [ ] Commit

### Task 19: Migrate capture

**Path:** `~/src/devnw/zig/capture`
**Files:** build.zig.zon, build.zig, src/parallel.zig
**Notes:** Parallel packet capture/filtering. Follow Task 2 pattern.

- [ ] Update build.zig.zon (Pattern A)
- [ ] Update build.zig (Pattern B1)
- [ ] Rewrite src/parallel.zig (Pattern C)
- [ ] Run: `cd ~/src/devnw/zig/capture && zig build test --summary all`
- [ ] Commit

### Task 20: Migrate dpi

**Path:** `~/src/devnw/zig/dpi`
**Files:** build.zig.zon, build.zig, src/parallel.zig
**Notes:** Parallel deep packet inspection. Follow Task 2 pattern.

- [ ] Update build.zig.zon (Pattern A)
- [ ] Update build.zig (Pattern B1)
- [ ] Rewrite src/parallel.zig (Pattern C)
- [ ] Run: `cd ~/src/devnw/zig/dpi && zig build test --summary all`
- [ ] Commit

### Task 21: Migrate ds

**Path:** `~/src/devnw/zig/ds`
**Files:** build.zig.zon, build.zig, src/parallel.zig
**Notes:** Parallel data structure operations. Follow Task 2 pattern.

- [ ] Update build.zig.zon (Pattern A)
- [ ] Update build.zig (Pattern B1)
- [ ] Rewrite src/parallel.zig (Pattern C)
- [ ] Run: `cd ~/src/devnw/zig/ds && zig build test --summary all`
- [ ] Commit

### Task 22: Migrate gql

**Path:** `~/src/devnw/zig/gql`
**Files:** build.zig.zon, build.zig, src/parallel.zig
**Notes:** Parallel GraphQL operations. Follow Task 2 pattern.

- [ ] Update build.zig.zon (Pattern A)
- [ ] Update build.zig (Pattern B1)
- [ ] Rewrite src/parallel.zig (Pattern C)
- [ ] Run: `cd ~/src/devnw/zig/gql && zig build test --summary all`
- [ ] Commit

### Task 23: Migrate hsm

**Path:** `~/src/devnw/zig/hsm`
**Files:** build.zig.zon, build.zig, src/parallel.zig
**Notes:** Parallel HSM (hardware security module) operations. Follow Task 2 pattern.

- [ ] Update build.zig.zon (Pattern A)
- [ ] Update build.zig (Pattern B1)
- [ ] Rewrite src/parallel.zig (Pattern C)
- [ ] Run: `cd ~/src/devnw/zig/hsm && zig build test --summary all`
- [ ] Commit

### Task 24: Migrate i18n

**Path:** `~/src/devnw/zig/i18n`
**Files:** build.zig.zon, build.zig, src/parallel.zig
**Notes:** Parallel i18n resource processing. Follow Task 2 pattern.

- [ ] Update build.zig.zon (Pattern A)
- [ ] Update build.zig (Pattern B1)
- [ ] Rewrite src/parallel.zig (Pattern C)
- [ ] Run: `cd ~/src/devnw/zig/i18n && zig build test --summary all`
- [ ] Commit

### Task 25: Migrate ldap

**Path:** `~/src/devnw/zig/ldap`
**Files:** build.zig.zon, build.zig, src/parallel.zig
**Notes:** Parallel LDAP operations. Follow Task 2 pattern.

- [ ] Update build.zig.zon (Pattern A)
- [ ] Update build.zig (Pattern B1)
- [ ] Rewrite src/parallel.zig (Pattern C)
- [ ] Run: `cd ~/src/devnw/zig/ldap && zig build test --summary all`
- [ ] Commit

### Task 26: Migrate oauth

**Path:** `~/src/devnw/zig/oauth`
**Files:** build.zig.zon, build.zig, src/parallel.zig
**Notes:** Parallel OAuth flows. Follow Task 2 pattern.

- [ ] Update build.zig.zon (Pattern A)
- [ ] Update build.zig (Pattern B1)
- [ ] Rewrite src/parallel.zig (Pattern C)
- [ ] Run: `cd ~/src/devnw/zig/oauth && zig build test --summary all`
- [ ] Commit

### Task 27: Migrate oidc

**Path:** `~/src/devnw/zig/oidc`
**Files:** build.zig.zon, build.zig, src/parallel.zig
**Notes:** Parallel OIDC operations. Follow Task 2 pattern.

- [ ] Update build.zig.zon (Pattern A)
- [ ] Update build.zig (Pattern B1)
- [ ] Rewrite src/parallel.zig (Pattern C)
- [ ] Run: `cd ~/src/devnw/zig/oidc && zig build test --summary all`
- [ ] Commit

### Task 28: Migrate oui

**Path:** `~/src/devnw/zig/oui`
**Files:** build.zig.zon, build.zig, src/parallel.zig
**Notes:** Parallel OUI (MAC vendor) lookups. Follow Task 2 pattern.

- [ ] Update build.zig.zon (Pattern A)
- [ ] Update build.zig (Pattern B1)
- [ ] Rewrite src/parallel.zig (Pattern C)
- [ ] Run: `cd ~/src/devnw/zig/oui && zig build test --summary all`
- [ ] Commit

### Task 29: Migrate rtree

**Path:** `~/src/devnw/zig/rtree`
**Files:** build.zig.zon, build.zig, src/parallel.zig
**Notes:** Parallel R-tree spatial index operations. Follow Task 2 pattern.

- [ ] Update build.zig.zon (Pattern A)
- [ ] Update build.zig (Pattern B1)
- [ ] Rewrite src/parallel.zig (Pattern C)
- [ ] Run: `cd ~/src/devnw/zig/rtree && zig build test --summary all`
- [ ] Commit

### Task 30: Migrate zlint

**Path:** `~/src/devnw/zig/zlint`
**Files:** build.zig.zon, build.zig, src/parallel.zig
**Notes:** Parallel linting. Follow Task 2 pattern.

- [ ] Update build.zig.zon (Pattern A)
- [ ] Update build.zig (Pattern B1)
- [ ] Rewrite src/parallel.zig (Pattern C)
- [ ] Run: `cd ~/src/devnw/zig/zlint && zig build test --summary all`
- [ ] Commit

### Task 31: Migrate zcap

**Path:** `~/src/devnw/zig/zcap`
**Files:** build.zig.zon, build.zig, src/parallel.zig, src/cli.zig
**Notes:** Has parallel.zig AND direct spice usage in src/cli.zig. Apply Pattern C to parallel.zig and Pattern D to cli.zig.

- [ ] Update build.zig.zon (Pattern A)
- [ ] Update build.zig (Pattern B1)
- [ ] Rewrite src/parallel.zig (Pattern C)
- [ ] Update src/cli.zig — replace spice imports/usage (Pattern D)
- [ ] Run: `cd ~/src/devnw/zig/zcap && zig build test --summary all`
- [ ] Commit

---

## Phase 3: MEDIUM Projects (Remaining 5)

These projects use spice inline (no parallel.zig). Each requires reading the specific source files and applying Pattern D.

### Task 32: Migrate raft (MEDIUM + REEXPORT)

**Path:** `~/src/devnw/zig/raft`
**Files:** build.zig.zon, build.zig, src/root.zig, src/node.zig
**Notes:** Uses fork-join for parallel AppendEntries construction. Re-exports spice from root.zig.

- [ ] Update build.zig.zon (Pattern A)
- [ ] Update build.zig (Pattern B2 — direct import, no parallel module)
- [ ] Update src/root.zig re-export (Pattern E)
- [ ] Read src/node.zig — find spice fork-join usage in AppendEntries construction
- [ ] Rewrite to use submitBatch + WaitGroup (Pattern D)
- [ ] Run: `cd ~/src/devnw/zig/raft && zig build test --summary all`
- [ ] Commit

### Task 33: Migrate encrypted-fs

**Path:** `~/src/devnw/zig/encrypted-fs`
**Files:** build.zig.zon, build.zig, src/app.zig, src/commands.zig
**Notes:** Uses fork-join for parallel encryption/decryption. Pattern B2 (direct import).

- [ ] Update build.zig.zon (Pattern A)
- [ ] Update build.zig (Pattern B2)
- [ ] Read src/app.zig and src/commands.zig — find spice usage
- [ ] Rewrite parallel encryption/decryption to submitBatch + WaitGroup (Pattern D)
- [ ] Run: `cd ~/src/devnw/zig/encrypted-fs && zig build test --summary all`
- [ ] Commit

### Task 34: Migrate graph-storage

**Path:** `~/src/devnw/zig/graph-storage`
**Files:** build.zig.zon, build.zig, src/buffer_pool.zig, src/engine.zig
**Notes:** Uses fork-join for parallel I/O and distance computations.

- [ ] Update build.zig.zon (Pattern A)
- [ ] Update build.zig (Pattern B1 or B2 — check which wiring pattern is used)
- [ ] Read src/buffer_pool.zig and src/engine.zig — find spice usage
- [ ] Rewrite parallel I/O and distance ops to submitBatch + WaitGroup (Pattern D)
- [ ] Run: `cd ~/src/devnw/zig/graph-storage && zig build test --summary all`
- [ ] Commit

### Task 35: Migrate hnsw

**Path:** `~/src/devnw/zig/hnsw`
**Files:** build.zig.zon, build.zig, src/hnsw.zig
**Notes:** Uses fork-join for parallel distance batch computations in HNSW index.

- [ ] Update build.zig.zon (Pattern A)
- [ ] Update build.zig (check wiring pattern)
- [ ] Read src/hnsw.zig — find spice usage for distance computations
- [ ] Rewrite to submitBatch + WaitGroup (Pattern D)
- [ ] Run: `cd ~/src/devnw/zig/hnsw && zig build test --summary all`
- [ ] Commit

### Task 36: Migrate wal

**Path:** `~/src/devnw/zig/wal`
**Files:** build.zig.zon, build.zig, src/wal.zig
**Notes:** Uses fork-join for recursive serialization.

- [ ] Update build.zig.zon (Pattern A)
- [ ] Update build.zig (check wiring pattern)
- [ ] Read src/wal.zig — find spice usage for serialization
- [ ] Rewrite recursive serialization to flat submitBatch + WaitGroup (Pattern D)
- [ ] Run: `cd ~/src/devnw/zig/wal && zig build test --summary all`
- [ ] Commit

---

## Phase 4: SHALLOW Projects

These projects list spice in build.zig.zon but don't import it in source code. Just remove the dependency.

### Task 37: Migrate audit

**Path:** `~/src/devnw/zig/audit`
**Files:** build.zig.zon, build.zig

- [ ] **Verify no source usage:** `grep -r '@import("spice")' ~/src/devnw/zig/audit/src/`
- [ ] If no source imports: remove `.spice` from build.zig.zon entirely (don't replace with thread_pool)
- [ ] If source imports exist: treat as DEEP/MEDIUM and apply appropriate pattern
- [ ] Remove any spice references from build.zig
- [ ] Run: `cd ~/src/devnw/zig/audit && zig build test --summary all`
- [ ] Commit: `git commit -m "chore: remove unused spice dependency"`

### Task 38: Migrate grpc-zig

**Path:** `~/src/devnw/zig/grpc-zig`
**Files:** build.zig.zon, build.zig

- [ ] **Verify no source usage:** `grep -r '@import("spice")' ~/src/devnw/zig/grpc-zig/src/`
- [ ] If no source imports: remove `.spice` from build.zig.zon entirely
- [ ] Remove any spice references from build.zig
- [ ] Run: `cd ~/src/devnw/zig/grpc-zig && zig build test --summary all`
- [ ] Commit: `git commit -m "chore: remove unused spice dependency"`

### Task 39: Migrate wireguard

**Path:** `~/src/devnw/zig/wireguard`
**Files:** build.zig.zon, build.zig

- [ ] **Verify no source usage:** `grep -r '@import("spice")' ~/src/devnw/zig/wireguard/src/`
- [ ] If no source imports: remove `.spice` from build.zig.zon entirely
- [ ] Remove any spice references from build.zig
- [ ] Run: `cd ~/src/devnw/zig/wireguard && zig build test --summary all`
- [ ] Commit: `git commit -m "chore: remove unused spice dependency"`

---

## Phase 5: Standalone Pool

### Task 40: Migrate concurrency

**Path:** `~/src/devnw/zig/concurrency`
**Files:** build.zig.zon, build.zig, src/thread_pool.zig, src/bounded_queue.zig, tests/, examples/

The concurrency project implements its own thread pool from scratch. Replace it with thread-pool as a dependency.

- [ ] **Step 1: Read current public API**

```bash
grep "^pub" ~/src/devnw/zig/concurrency/src/thread_pool.zig
```

Identify: ThreadPool, ThreadPoolConfig, WorkItem, Stats structs and their methods.

- [ ] **Step 2: Update build.zig.zon**

Add thread-pool dependency:

```zig
.dependencies = .{
    .thread_pool = .{
        .url = "git+https://gitlab.com/devnw/zig/thread-pool.git#7275ae20b51c86278fdb7b4df526715fdf24eeb6",
        .hash = "thread_pool-0.2.0-11B1Bjc9OQCpsTlU23uENRGidyB6DoKgKTODN2-LpFGU",
    },
},
```

- [ ] **Step 3: Update build.zig**

Add thread_pool module import for the library and tests.

- [ ] **Step 4: Rewrite thread_pool.zig as thin wrapper**

Replace the custom implementation with a wrapper around the thread-pool library. Map the concurrency project's public API to thread-pool's API:

```zig
const tp = @import("thread_pool");
const std = @import("std");

pub const ThreadPoolConfig = struct {
    num_threads: usize = 0,

    fn toTpConfig(self: ThreadPoolConfig) tp.Config {
        return .{
            .max_threads = if (self.num_threads == 0)
                0  // auto-detect
            else
                self.num_threads,
        };
    }
};

pub const ThreadPool = struct {
    inner: tp.ThreadPool,

    pub fn init(allocator: std.mem.Allocator, config: ThreadPoolConfig) !ThreadPool {
        return .{
            .inner = try tp.ThreadPool.init(allocator, config.toTpConfig()),
        };
    }

    pub fn deinit(self: *ThreadPool) void {
        self.inner.deinit();
    }

    pub fn submit(self: *ThreadPool, task_fn: tp.TaskFn, ctx: *anyopaque) !void {
        _ = try self.inner.submit(task_fn, ctx, .{});
    }

    pub fn submitBatch(self: *ThreadPool, tasks: []const tp.BatchTask) !usize {
        const result = try self.inner.submitBatch(tasks, .{});
        return result.submitted;
    }
};
```

Adapt the wrapper to match the concurrency project's existing public API as closely as possible. Callers should need minimal changes.

- [ ] **Step 5: Delete bounded_queue.zig**

The custom queue implementation is no longer needed — thread-pool provides its own.

- [ ] **Step 6: Update tests and examples**

Update `tests/integration.zig` and `examples/basic.zig` to use the new wrapper API. If the wrapper preserves the original API, changes should be minimal.

- [ ] **Step 7: Verify and test**

```bash
cd ~/src/devnw/zig/concurrency && zig build test --summary all
```

- [ ] **Step 8: Commit**

```bash
cd ~/src/devnw/zig/concurrency
git add -A
git commit -m "refactor: replace custom pool with thread-pool library dependency

Custom ThreadPool and BoundedQueue replaced by thin wrapper over
thread-pool library pulled from gitlab. Public API preserved."
```

---

## Phase 6: Cleanup

### Task 41: Retire spice

**Path:** `~/src/devnw/zig/spice`

- [ ] **Step 1: Verify no remaining consumers**

```bash
for d in ~/src/devnw/zig/*/; do
    if grep -q "spice" "$d/build.zig.zon" 2>/dev/null; then
        echo "STILL USES SPICE: $(basename $d)"
    fi
done
```

Expected: only `spice` itself (self-reference if any) and no other projects.

- [ ] **Step 2: Verify all projects build**

```bash
for d in ~/src/devnw/zig/*/; do
    if [ -f "$d/build.zig" ] && [ "$(basename $d)" != "spice" ]; then
        echo "=== $(basename $d) ==="
        (cd "$d" && zig build test --summary all 2>&1 | tail -3)
    fi
done
```

- [ ] **Step 3: Archive spice**

Option A — Archive the gitlab repo (mark as archived, read-only):
```bash
cd ~/src/devnw/zig/spice
echo "# ARCHIVED — Replaced by [thread-pool](https://gitlab.com/devnw/zig/thread-pool)" > DEPRECATED.md
git add DEPRECATED.md
git commit -m "chore: archive — replaced by thread-pool library"
git push origin main
```

Option B — If the user prefers to delete entirely, confirm before proceeding.

- [ ] **Step 4: Update thread-pool docs**

Add a migration note to the thread-pool README or docs referencing this migration for any external spice consumers.

---

## Dependency Order Notes

Most projects import spice independently via their own build.zig.zon, so they can be migrated in parallel. The following ordering constraints exist:

1. **metrics** (Task 4) before any project that uses `metrics.spice` re-export
2. **raft** (Task 32) before any project that uses `raft.spice` re-export
3. **config** (Task 13) before **cli** (Task 14) — cli depends on config
4. **cli** (Task 14) before **dns** (Task 15) — dns depends on cli
5. **json** (Task 2) before **slog** (Task 12) and **mcp** (Task 16) — they depend on json
6. **tls** (Task 11) before **quic** (Task 3) and **ai** (Task 17) — they depend on tls

All other projects can be migrated in any order.

## Parallelization Strategy

For agentic execution with subagent-driven-development:
- **Wave 1** (no dependencies): Tasks 5-10 (strings, uri, toml, yaml, ebnf, entropy) — all independent
- **Wave 2** (foundation): Tasks 11, 2, 4 (tls, json, metrics) — independent of each other
- **Wave 3** (depends on Wave 2): Tasks 12, 3, 13, 16, 32 (slog, quic, config, mcp, raft)
- **Wave 4** (depends on Wave 3): Tasks 14, 15, 17 (cli, dns, ai)
- **Wave 5** (remaining DEEP): Tasks 18-31 — all independent
- **Wave 6** (MEDIUM): Tasks 33-36 — all independent
- **Wave 7** (SHALLOW + special): Tasks 37-40 — all independent
- **Wave 8** (cleanup): Task 41
