# Contended / Nested Scenario Gap-Closure Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Narrow the Go throughput gap on the four Zig-behind scenarios in `bench-runtime-compare` — `contended_spawn_8x` (4.18x behind), `contended_cpu_10us` (1.97x behind), `nested_fanout_4x` (6.04x behind), and `mixed_fast_slow` (1.12x behind) — via harness-fairness fixes, comptime-elision builds, targeted profiling, and scenario-specific attacks.

**Architecture:** Four phases. (1) Harness fairness: add `registerSubmitter()` + `max_submitter_queues` config to the 3 scenarios that hammer the inject queue head from multiple threads; add `-Dtimestamp-mode=disabled -Dscheduler-variant=work_stealing` comparison build. (2) Profile each scenario with `perf record` against the current HEAD binary and against the Phase-1 binary; identify per-scenario top-2 hotspots. (3) Scenario-specific attacks gated on Phase-2 findings, each landed behind a paired A/B n=10 gate. (4) Refresh the baseline snapshots, update `CLAUDE.md`, commit.

**Tech Stack:** Zig 0.16.0, `src/pool.zig` Core scheduler, `benchmarks/runtime_compare_zig.zig` harness, `benchmarks/common.zig` shared harness, Linux perf, Go 1.22 + Tokio 1.x pinned under `third_party/`.

**Closed planes — do not re-attack these:** (see memory index)
- `drain-vs-steal` reorder (Options C/D — SIGSEGV then +6% but -3.8% target).
- `parked_workers` shared u64 bitmap (iter 7, −14/−22/−11%).
- Single-worker wake probe (iter 8, −8.74%).
- `is_parked` cacheline isolation (iter 9, neutral).
- `shouldExit` off hot path (iter 10, hang).
- Per-worker `active_tasks` shard (iter 11, −4.26%).
- Socket-aware worker pinning (Slice 3a, −4 to −18%).
- The flood_1m_batched throughput ceiling itself — `notifySubmits` at 27.58% is architectural SC fetchAdd + futex wake cost. Do not revisit. This plan is about contended / nested / mixed-weight scenarios; it is a distinct plane.

**Measurement gates (per user's measurement-rules memory):**
- Same-session paired A/B only. Never compare across reboots.
- n=10 per arm for throughput scenarios; record stddev.
- 20× ReleaseFast stress gate (`for i in {1..20}; do zig build test-stress --summary all || break; done`) before landing.
- Regression bar: no scenario in the `bench-runtime-compare` matrix may drop >2% median ops/sec vs pre-landing baseline.
- Each task that lands code either (a) passes the n=10 + stress gate and commits, or (b) reverts and documents the closed plane in the checkpoint.

---

## File Structure

Pool-side changes are bounded. Most of the plan's code lives in the benchmark harness and a new comparison build profile. The pool surface only changes if Phase-3 attacks find an actionable bottleneck.

- **Modify** `benchmarks/runtime_compare_zig.zig:328–372` — `runContendedSample` is already fully tuned (registers submitters, uses `max_submitter_queues=8`). Used as the reference pattern for Phase 1.
- **Modify** `benchmarks/runtime_compare_zig.zig:423–506` — `runCpuWorkScenario` (powers `contended_cpu_10us`): add `max_submitter_queues=4 / submitter_queue_capacity=4096` config; add `registerSubmitter()` / `releaseSubmitter()` bracket inside the submitter thread.
- **Modify** `benchmarks/runtime_compare_zig.zig:508–580` — `runNestedFanout4xSample`: add `max_submitter_queues=1 / submitter_queue_capacity=4096` config and register the main thread. (Children submit from worker context via local-queue fast path; no change needed there.)
- **Modify** `benchmarks/runtime_compare_zig.zig:650–699` — `runMixedFastSlowSample`: same main-thread register + 1 submitter-queue config as nested_fanout_4x.
- **Modify** `benchmarks/common.zig:293–349` — `submitRange` / `submitterMain`: register each submitter thread so the `bench-realistic` harness matches the runtime-compare harness's tuning. Enables apples-to-apples cross-harness comparison.
- **Create** `docs/performance/contended-scenarios-2026-04-16/` — per-scenario profile markdown written in Phase 2; one file per scenario.
- **Create** `docs/performance/contended-scenarios-2026-04-16/FINAL.md` — final report with before/after medians, what landed, what was tried and closed.
- **Modify** `CLAUDE.md` — "Current Direct Runtime Snapshot" section at the end of Phase 4.
- **Modify** `benchmarks/results/runtime-comparison-latest.json` — refresh (overwrite) at end of Phase 4.

Pool-side files (`src/pool.zig`, `src/types.zig`) are **not expected to change** in Phase 1 or Phase 2. Phase 3 may touch them depending on profile findings; each Phase-3 task defines its own file list.

---

## Task 0: Baseline Capture

**Files:**
- Create: `docs/performance/contended-scenarios-2026-04-16/baseline.json` (copy of existing baseline).

This task establishes the reference point before anything else changes. Every later paired A/B compares against this baseline row-for-row.

- [ ] **Step 1: Snapshot the current runtime-compare result**

```bash
mkdir -p docs/performance/contended-scenarios-2026-04-16
cp benchmarks/results/runtime-comparison-latest.json docs/performance/contended-scenarios-2026-04-16/baseline.json
git log -1 --format='%H' -- benchmarks/results/runtime-comparison-latest.json
```

Expected: `baseline.json` written; `git log` returns `56c109a` or later (the Phase-C baseline-refresh commit).

- [ ] **Step 2: Capture the current Zig-only matrix at this HEAD**

```bash
zig build bench-runtime-zig -Doptimize=ReleaseFast -- \
  --samples 7 --warmup-discard 1 \
  --output docs/performance/contended-scenarios-2026-04-16/zig-only-baseline.json
```

Expected: 8 rows written. Console prints 8 `zig_thread_pool <scenario>` lines. Medians should be within 5% of the `baseline.json` values for the four scenarios of interest.

- [ ] **Step 3: Record the baseline medians we'll gate against**

Create `docs/performance/contended-scenarios-2026-04-16/baseline-medians.md` with a table:

```markdown
# Baseline medians (HEAD $(git rev-parse HEAD))

Captured: $(date -u +%Y-%m-%dT%H:%M:%SZ)

| Scenario | Zig median ops/sec | Go median ops/sec | Gap |
|----------|-------------------:|------------------:|----:|
| contended_spawn_8x   | 916,337   | 3,832,459 | 4.18x behind |
| contended_cpu_10us   | 918,624   | 1,807,198 | 1.97x behind |
| nested_fanout_4x     | 525,906   | 3,175,814 | 6.04x behind |
| mixed_fast_slow      | 223,581   | 249,514   | 1.12x behind |

Source: `baseline.json` (this directory).
```

- [ ] **Step 4: Commit the baseline snapshot**

```bash
git add docs/performance/contended-scenarios-2026-04-16/baseline.json \
         docs/performance/contended-scenarios-2026-04-16/zig-only-baseline.json \
         docs/performance/contended-scenarios-2026-04-16/baseline-medians.md
git commit -m "perf: snapshot baseline for contended-scenarios gap-close"
```

Expected: one new commit; working tree clean.

---

## Task 1: Audit Harness Submitter-Registration Gap

This task is pure recon. It writes the findings into the plan artefact so Phase-1 fixes have concrete line numbers.

**Files:**
- Create: `docs/performance/contended-scenarios-2026-04-16/harness-audit.md`.

- [ ] **Step 1: Grep every `pool.submit` call site in the harness**

```bash
rg -n 'pool\.submit|self\.pool\.submit|ctx\.pool\.submit' benchmarks/
```

Expected output includes (but may not be limited to):
- `benchmarks/runtime_compare_zig.zig` — 8 call sites in the 8 scenarios.
- `benchmarks/common.zig` — 4 call sites (inline + `submitterMain` + `nestedTask`).
- `benchmarks/bench_realistic.zig` — the `runMixedWorkload` and `runLaneIsolation` sites.

- [ ] **Step 2: Grep every `registerSubmitter` call site**

```bash
rg -n 'registerSubmitter|releaseSubmitter' benchmarks/ src/pool.zig
```

Expected: exactly one call site in `benchmarks/runtime_compare_zig.zig:362` (inside `contendedSubmitterThread`). Zero call sites in `common.zig` or `bench_realistic.zig`. Pool-side API is `Core.registerSubmitter` / `Core.releaseSubmitter` with the TLS slot cached via `tls_submitter_slot`.

- [ ] **Step 3: Record the audit**

Write `docs/performance/contended-scenarios-2026-04-16/harness-audit.md`:

```markdown
# Harness submitter-registration audit

## Summary

Only `runContendedSample` in `benchmarks/runtime_compare_zig.zig` registers
submitter threads today. Every other multi-submitter scenario (and every
main-thread-only scenario) hits the inject-queue head directly via
`pool.submit()`, which is serialised through a single MPMC tail CAS.

## Scenarios that do NOT register submitters (and should)

| Scenario | File | Lines | Submitter threads | Current config |
|----------|------|-------|-------------------:|----------------|
| `contended_cpu_10us`   | `runtime_compare_zig.zig` | 423–506 | 4 | `max_submitter_queues=0` |
| `nested_fanout_4x`     | `runtime_compare_zig.zig` | 508–580 | 1 (main) | `max_submitter_queues=0` |
| `mixed_fast_slow`      | `runtime_compare_zig.zig` | 650–699 | 1 (main) | `max_submitter_queues=0` |
| `cpu_work_10us`        | `runtime_compare_zig.zig` | 415     | 1 (main) | `max_submitter_queues=0` |
| `cpu_work_100us`       | `runtime_compare_zig.zig` | 419     | 1 (main) | `max_submitter_queues=0` |
| `burst_drain_burst`    | `runtime_compare_zig.zig` | 582–648 | 1 (main) | `max_submitter_queues=0` |
| `flood_1m`             | `runtime_compare_zig.zig` | 305–326 | 1 (main) | `max_submitter_queues=0` |
| `bench-realistic` all  | `common.zig`              | 351–368 | 1..N | `max_submitter_queues=0` |

## Priority

Phase 1 fixes the three in-scope scenarios only:
- `contended_cpu_10us` (multi-submitter; largest expected delta).
- `nested_fanout_4x` (single main submitter; smaller delta but still a gap).
- `mixed_fast_slow` (single main submitter; smallest expected delta).

The other five are left alone in Phase 1 to preserve apples-to-apples vs
baseline for the non-target scenarios. If Phase 1 + Phase 3 close the gap
meaningfully, a follow-up plan can audit the remaining five.

## Expected gain

Based on the 2026-04-15 `contended_spawn_8x` result when
`registerSubmitter()` was first added (+17.2%, 837K→981K ops/sec), we
expect:
- `contended_cpu_10us`: 8–20% gain (similar pattern, 4 submitters).
- `nested_fanout_4x`: 0–5% gain (main thread submits 2k parents once;
  child submission already routes through worker LIFO slot, so the
  registered submitter only matters for the parent-push phase).
- `mixed_fast_slow`: 0–3% gain (1 submitter; submitter queue just
  deflects the slow-path fall-through to inject_queue).

Absolute gain is conservative; the scenarios with nested/child submissions
from worker context are already on the fast path.
```

- [ ] **Step 4: Commit the audit**

```bash
git add docs/performance/contended-scenarios-2026-04-16/harness-audit.md
git commit -m "docs: record harness submitter-registration audit for contended-scenarios plan"
```

---

## Task 2: Phase 1A — Register Submitters in `contended_cpu_10us`

**Files:**
- Modify: `benchmarks/runtime_compare_zig.zig:423–506` (expand the inline `CpuSubmitterCtx` struct + pool config).

- [ ] **Step 1: Read the existing pattern**

```bash
sed -n '328,372p' benchmarks/runtime_compare_zig.zig
```

Expected: the working pattern from `runContendedSample` — `max_submitter_queues = contended_submitters`, `submitter_queue_capacity = 4096`, and each submitter thread brackets its work with `registerSubmitter()` / `releaseSubmitter()`.

- [ ] **Step 2: Edit `runCpuWorkScenario` pool config**

Change the `thread_pool.ThreadPool.init` call at `benchmarks/runtime_compare_zig.zig:428–434` to add the submitter-queue fields when `submitters > 1`. Because `runCpuWorkScenario` is parameterised over `submitters`, keep it uniform: always set the fields to the `submitters` value; with `submitters == 1` the pool allocates one queue but falls through to inject_queue path when the main thread doesn't register.

Replace:

```zig
    var pool = try thread_pool.ThreadPool.init(std.heap.smp_allocator, .{
        .min_threads = worker_count,
        .max_threads = worker_count,
        .queue_capacity = 4096,
        .local_queue_capacity = 256,
        .scheduler_variant = .work_stealing,
    });
```

With:

```zig
    var pool = try thread_pool.ThreadPool.init(std.heap.smp_allocator, .{
        .min_threads = worker_count,
        .max_threads = worker_count,
        .queue_capacity = 4096,
        .local_queue_capacity = 256,
        .scheduler_variant = .work_stealing,
        .max_submitter_queues = @intCast(@max(submitters, 1)),
        .submitter_queue_capacity = 4096,
    });
```

- [ ] **Step 3: Edit the inline submitter struct's `run` fn to bracket registerSubmitter**

The inline struct at `benchmarks/runtime_compare_zig.zig:464–493` owns the per-thread submit loop. Replace the struct `run` body:

```zig
            threads[s] = try std.Thread.spawn(.{}, struct {
                fn run(c: *CpuSubmitterCtx) void {
                    for (c.tasks, 0..) |*t, j| {
                        c.sub_at[j] = nowNs();
                        _ = c.p.submit(realisticTask, @ptrCast(t), .{
                            .wait_group = c.w,
                            .backpressure = .block,
                        }) catch return;
                    }
                }
            }.run, .{&sub_ctxs[s]});
```

With:

```zig
            threads[s] = try std.Thread.spawn(.{}, struct {
                fn run(c: *CpuSubmitterCtx) void {
                    const slot = c.p.registerSubmitter() catch
                        @panic("registerSubmitter failed during contended_cpu benchmark");
                    defer c.p.releaseSubmitter(slot);
                    for (c.tasks, 0..) |*t, j| {
                        c.sub_at[j] = nowNs();
                        _ = c.p.submit(realisticTask, @ptrCast(t), .{
                            .wait_group = c.w,
                            .backpressure = .block,
                        }) catch return;
                    }
                }
            }.run, .{&sub_ctxs[s]});
```

- [ ] **Step 4: Build**

```bash
zig build bench-runtime-zig -Doptimize=ReleaseFast
```

Expected: clean build. No warnings about unused imports.

- [ ] **Step 5: Paired A/B n=10 — `contended_cpu_10us` only**

This is the per-phase paired A/B. Capture 10 samples each for A (last HEAD pre-edit, via `git stash`) and B (post-edit).

```bash
# B first, in place:
for i in $(seq 1 10); do
  zig build bench-runtime-zig -Doptimize=ReleaseFast -- \
    --samples 1 --warmup-discard 0 \
    --output /tmp/ab-B-$i.json 2>/dev/null | \
    grep 'contended_cpu_10us' || true
done

# Then A (stash the edit):
git stash push -- benchmarks/runtime_compare_zig.zig
zig build bench-runtime-zig -Doptimize=ReleaseFast
for i in $(seq 1 10); do
  zig build bench-runtime-zig -Doptimize=ReleaseFast -- \
    --samples 1 --warmup-discard 0 \
    --output /tmp/ab-A-$i.json 2>/dev/null | \
    grep 'contended_cpu_10us' || true
done

# Restore B:
git stash pop
zig build bench-runtime-zig -Doptimize=ReleaseFast
```

Extract medians with jq:

```bash
for arm in A B; do
  for i in $(seq 1 10); do
    jq -r '.rows[] | select(.scenario_name == "contended_cpu_10us") | .median_ops_per_sec' \
       /tmp/ab-$arm-$i.json
  done | sort -n | awk 'NR==5{print}'
done
```

Expected: B median > A median. Gate: B must be ≥ A × 1.00 on contended_cpu_10us; other scenarios in the runtime-compare matrix may fluctuate ±2% (within noise). If B < A × 1.00 — STOP, do not commit, open a checkpoint doc in `docs/performance/contended-scenarios-2026-04-16/phase1a-failed.md` explaining the surprise.

- [ ] **Step 6: 20× ReleaseFast stress gate**

```bash
for i in $(seq 1 20); do
  zig build test-stress --summary all || { echo "FAIL on iter $i"; break; }
done
```

Expected: 20/20 pass. Zero hangs, zero segfaults, zero asserts.

- [ ] **Step 7: Commit**

```bash
git add benchmarks/runtime_compare_zig.zig
git commit -m "perf(bench): register submitters in contended_cpu_10us harness"
```

---

## Task 3: Phase 1B — Register Main Thread in `nested_fanout_4x`

**Files:**
- Modify: `benchmarks/runtime_compare_zig.zig:513–519` (pool config) and `:559–565` (main submit loop bracket).

The main thread submits 2000 parents; each parent, when run by a worker, submits 4 children via the worker's local-queue fast path (already optimal). The only inject-queue pressure is from the main thread's parent-submission phase.

- [ ] **Step 1: Edit pool config in `runNestedFanout4xSample`**

Replace `benchmarks/runtime_compare_zig.zig:513–519`:

```zig
    var pool = try thread_pool.ThreadPool.init(std.heap.smp_allocator, .{
        .min_threads = worker_count,
        .max_threads = worker_count,
        .queue_capacity = 8192,
        .local_queue_capacity = 256,
        .scheduler_variant = .work_stealing,
    });
```

With:

```zig
    var pool = try thread_pool.ThreadPool.init(std.heap.smp_allocator, .{
        .min_threads = worker_count,
        .max_threads = worker_count,
        .queue_capacity = 8192,
        .local_queue_capacity = 256,
        .scheduler_variant = .work_stealing,
        .max_submitter_queues = 1,
        .submitter_queue_capacity = 4096,
    });
```

- [ ] **Step 2: Bracket the parent-submit loop with registerSubmitter**

Replace the block at `benchmarks/runtime_compare_zig.zig:559–565`:

```zig
    for (parent_ctxs, 0..) |*ctx, i| {
        parent_submitted[i] = nowNs();
        _ = try pool.submit(nestedParentTask, @ptrCast(ctx), .{
            .wait_group = &wg,
            .backpressure = .block,
        });
    }
```

With:

```zig
    const main_slot = try pool.registerSubmitter();
    defer pool.releaseSubmitter(main_slot);
    for (parent_ctxs, 0..) |*ctx, i| {
        parent_submitted[i] = nowNs();
        _ = try pool.submit(nestedParentTask, @ptrCast(ctx), .{
            .wait_group = &wg,
            .backpressure = .block,
        });
    }
```

- [ ] **Step 3: Build**

```bash
zig build bench-runtime-zig -Doptimize=ReleaseFast
```

Expected: clean build.

- [ ] **Step 4: Paired A/B n=10 on nested_fanout_4x**

Use the same n=10 procedure as Task 2 Step 5 but with `nested_fanout_4x` in the `jq` selector. Gate: B ≥ A × 0.99 (expected gain is small because children already use the worker-local fast path; this task is mostly a consistency / future-proofing fix).

- [ ] **Step 5: 20× stress gate**

```bash
for i in $(seq 1 20); do
  zig build test-stress --summary all || { echo "FAIL on iter $i"; break; }
done
```

Expected: 20/20 pass.

- [ ] **Step 6: Commit**

```bash
git add benchmarks/runtime_compare_zig.zig
git commit -m "perf(bench): register main thread in nested_fanout_4x harness"
```

---

## Task 4: Phase 1C — Register Main Thread in `mixed_fast_slow`

**Files:**
- Modify: `benchmarks/runtime_compare_zig.zig:654–661` (pool config) and `:681–687` (submit loop bracket).

- [ ] **Step 1: Edit pool config in `runMixedFastSlowSample`**

Replace `benchmarks/runtime_compare_zig.zig:654–661`:

```zig
    var pool = try thread_pool.ThreadPool.init(std.heap.smp_allocator, .{
        .min_threads = worker_count,
        .max_threads = worker_count,
        .queue_capacity = 4096,
        .local_queue_capacity = 256,
        .scheduler_variant = .work_stealing,
    });
```

With:

```zig
    var pool = try thread_pool.ThreadPool.init(std.heap.smp_allocator, .{
        .min_threads = worker_count,
        .max_threads = worker_count,
        .queue_capacity = 4096,
        .local_queue_capacity = 256,
        .scheduler_variant = .work_stealing,
        .max_submitter_queues = 1,
        .submitter_queue_capacity = 4096,
    });
```

- [ ] **Step 2: Bracket the submit loop**

Replace the block at `benchmarks/runtime_compare_zig.zig:681–687`:

```zig
    for (mixed_ctxs, 0..) |*ctx, i| {
        submitted_at[i] = nowNs();
        _ = try pool.submit(realisticTask, @ptrCast(ctx), .{
            .wait_group = &wg,
            .backpressure = .block,
        });
    }
```

With:

```zig
    const main_slot = try pool.registerSubmitter();
    defer pool.releaseSubmitter(main_slot);
    for (mixed_ctxs, 0..) |*ctx, i| {
        submitted_at[i] = nowNs();
        _ = try pool.submit(realisticTask, @ptrCast(ctx), .{
            .wait_group = &wg,
            .backpressure = .block,
        });
    }
```

- [ ] **Step 3: Build**

```bash
zig build bench-runtime-zig -Doptimize=ReleaseFast
```

Expected: clean build.

- [ ] **Step 4: Paired A/B n=10 on mixed_fast_slow**

Same procedure as Task 2 Step 5. Gate: B ≥ A × 0.99 (expected gain < 3%).

- [ ] **Step 5: 20× stress gate**

```bash
for i in $(seq 1 20); do
  zig build test-stress --summary all || { echo "FAIL on iter $i"; break; }
done
```

Expected: 20/20 pass.

- [ ] **Step 6: Commit**

```bash
git add benchmarks/runtime_compare_zig.zig
git commit -m "perf(bench): register main thread in mixed_fast_slow harness"
```

---

## Task 5: Phase 1D — Mirror Fix to `bench-realistic` Harness

`common.zig::submitRange` drives the `bench-realistic` harness for the same scenarios (`contended_cpu_10us`, `nested_fanout_4x`). Without this fix, `bench-realistic` and `bench-runtime-zig` report different numbers for the same scenario — false-positive regressions during future investigation.

**Files:**
- Modify: `benchmarks/common.zig:176–291` (`runScenario` pool config).
- Modify: `benchmarks/common.zig:293–349` (`submitRange`) and `:351–372` (`submitterMain`).

- [ ] **Step 1: Read the current runScenario pool config**

```bash
sed -n '176,220p' benchmarks/common.zig
```

Expected: the `thread_pool.ThreadPool.init` call for the realistic harness. Confirm it does not currently set `max_submitter_queues` or `submitter_queue_capacity`.

- [ ] **Step 2: Extend `ScenarioSpec` with an optional `submitter_queues` field**

Edit `benchmarks/common.zig:6–19` to add one field:

```zig
pub const ScenarioSpec = struct {
    name: []const u8,
    task_count: usize,
    worker_count: usize,
    submitter_count: usize,
    queue_capacity: usize,
    local_queue_capacity: usize,
    sleep_ns: u64 = 0,
    scratch_bytes: usize = 0,
    idle_gap_ns: u64 = 0,
    nested_children: usize = 0,
    lane: thread_pool.TaskLane = .default,
    register_submitters: bool = false,
};
```

(Keep existing fields; add `register_submitters` at the end with `false` default so existing specs compile unchanged.)

- [ ] **Step 3: Thread `register_submitters` through `runScenario`**

Inside `runScenario` in `common.zig`, the `ThreadPool.init` call adds two fields when `spec.register_submitters` is true:

```zig
    const submitter_queues: u32 = if (spec.register_submitters)
        @intCast(@max(spec.submitter_count, 1))
    else
        0;
    const submitter_capacity: usize = if (spec.register_submitters)
        @max(spec.local_queue_capacity, 1024)
    else
        0;
    var pool = try thread_pool.ThreadPool.init(allocator, .{
        .min_threads = spec.worker_count,
        .max_threads = spec.worker_count,
        .queue_capacity = spec.queue_capacity,
        .local_queue_capacity = spec.local_queue_capacity,
        .scheduler_variant = variant,
        .max_submitter_queues = submitter_queues,
        .submitter_queue_capacity = submitter_capacity,
    });
```

Replace the existing `thread_pool.ThreadPool.init(...)` call in `runScenario` with this block. The two new local bindings must be added immediately before the init call.

- [ ] **Step 4: Bracket `submitterMain` with registerSubmitter**

Edit `benchmarks/common.zig:351–372` (`submitterMain`). Before the outer `for (ctx.tasks, 0..)` loop, add the register / release bracket:

```zig
fn submitterMain(ctx: SubmitterCtx) void {
    const slot = ctx.pool.registerSubmitter() catch {
        @panic("registerSubmitter failed in submitterMain");
    };
    defer ctx.pool.releaseSubmitter(slot);
    for (ctx.tasks, 0..) |*task, idx| {
        // ... existing loop body unchanged
```

Guard the panic: if the caller ran `runScenario` with `register_submitters = false`, then `max_submitter_queues == 0` and `registerSubmitter` returns `error.SubmitterQueuesDisabled`. The `submitterMain` bracket must only call `registerSubmitter` when the pool actually has slots. Add a sentinel to `SubmitterCtx`:

```zig
const SubmitterCtx = struct {
    pool: *thread_pool.ThreadPool,
    tasks: []BenchTaskCtx,
    submit_latencies_ns: []u64,
    wait_group: *thread_pool.WaitGroup,
    lane: thread_pool.TaskLane,
    register: bool,
};
```

Then in `submitterMain`:

```zig
fn submitterMain(ctx: SubmitterCtx) void {
    const slot_opt: ?u32 = if (ctx.register)
        ctx.pool.registerSubmitter() catch null
    else
        null;
    defer if (slot_opt) |slot| ctx.pool.releaseSubmitter(slot);
    for (ctx.tasks, 0..) |*task, idx| {
        // ... unchanged
```

And propagate `register` at the `ctxs[idx] = .{ ... }` construction in `submitRange` (`benchmarks/common.zig:335–342`): add `.register = true,` when `spec.register_submitters` and `submitter_count > 1`, else `false`.

- [ ] **Step 5: Flip the two in-scope realistic scenarios**

Edit `benchmarks/bench_realistic.zig:37–55` (the two `contended_cpu_10us` and `nested_fanout_4x` specs) to add `.register_submitters = true`:

```zig
        .{
            .name = "contended_cpu_10us",
            .task_count = 10_000,
            .worker_count = workers,
            .submitter_count = 4,
            .queue_capacity = 2048,
            .local_queue_capacity = 256,
            .sleep_ns = 10_000,
            .scratch_bytes = 4096,
            .register_submitters = true,
        },
        .{
            .name = "nested_fanout_4x",
            .task_count = 2_000,
            .worker_count = workers,
            .submitter_count = 2,
            .queue_capacity = 4096,
            .local_queue_capacity = 256,
            .nested_children = 4,
            .register_submitters = true,
        },
```

- [ ] **Step 6: Build both harnesses**

```bash
zig build bench-runtime-zig bench-realistic -Doptimize=ReleaseFast
```

Expected: clean build.

- [ ] **Step 7: Verify `bench-realistic` still runs**

```bash
zig build bench-realistic -Doptimize=ReleaseFast 2>&1 | \
  grep -E 'contended_cpu_10us|nested_fanout_4x'
```

Expected: both scenarios emit a throughput + latency line. No `SubmitterQueuesDisabled` panics.

- [ ] **Step 8: 20× stress gate**

```bash
for i in $(seq 1 20); do
  zig build test-stress --summary all || { echo "FAIL on iter $i"; break; }
done
```

Expected: 20/20 pass.

- [ ] **Step 9: Commit**

```bash
git add benchmarks/common.zig benchmarks/bench_realistic.zig
git commit -m "perf(bench): plumb register_submitters through shared harness"
```

---

## Task 6: Phase 1E — Capture Post-Phase-1 Baseline

**Files:**
- Create: `docs/performance/contended-scenarios-2026-04-16/phase1-after.json`.
- Modify: `docs/performance/contended-scenarios-2026-04-16/baseline-medians.md` (append).

- [ ] **Step 1: Run the full runtime-compare matrix**

```bash
zig build bench-runtime-compare -Doptimize=ReleaseFast -- \
  --samples 7 --warmup-discard 1 \
  --output docs/performance/contended-scenarios-2026-04-16/phase1-after.json
```

Expected: 8 rows for zig, 8 for tokio, 8 for go. Tokio / Go numbers should be within 10% of `baseline.json` (thermal drift tolerance); Zig numbers on the three Phase-1 scenarios should be higher.

- [ ] **Step 2: Append the Phase-1 medians to the table**

Append to `docs/performance/contended-scenarios-2026-04-16/baseline-medians.md`:

```markdown
## Post-Phase-1 medians (HEAD $(git rev-parse HEAD))

Captured: $(date -u +%Y-%m-%dT%H:%M:%SZ)

| Scenario | Zig baseline | Zig post-Phase-1 | Delta | Go median | New gap |
|----------|-------------:|-----------------:|------:|----------:|--------:|
| contended_spawn_8x   | 916,337 | (unchanged)  | 0%    | 3,832,459 | (unchanged) |
| contended_cpu_10us   | 918,624 | ___          | ___   | 1,807,198 | ___ |
| nested_fanout_4x     | 525,906 | ___          | ___   | 3,175,814 | ___ |
| mixed_fast_slow      | 223,581 | ___          | ___   | 249,514   | ___ |

Source: `phase1-after.json` (this directory).
```

Fill the blanks from `phase1-after.json` with `jq`.

- [ ] **Step 3: Commit**

```bash
git add docs/performance/contended-scenarios-2026-04-16/phase1-after.json \
         docs/performance/contended-scenarios-2026-04-16/baseline-medians.md
git commit -m "docs: record Phase-1 post-harness-fairness baseline"
```

---

## Task 7: Phase 2A — Build the Comptime-Elision Reference Binary

The `-Dtimestamp-mode=disabled -Dscheduler-variant=work_stealing` pin elides histogram writes and dead-lane branches. If the elision binary significantly outperforms the default binary on the target scenarios, Phase-3 attacks may be unnecessary (users opt into the elision build for latency-critical workloads).

**Files:**
- Create: `docs/performance/contended-scenarios-2026-04-16/elision-binary.md`.
- Create: `docs/performance/contended-scenarios-2026-04-16/elision-results.json`.

- [ ] **Step 1: Build the elision binary**

```bash
zig build bench-runtime-zig -Doptimize=ReleaseFast \
  -Dtimestamp-mode=disabled \
  -Dscheduler-variant=work_stealing
```

Expected: clean build. Confirm the binary is compiled with the options by checking the `build_options` module:

```bash
strings zig-out/bin/thread-pool-runtime-compare-zig 2>/dev/null | \
  grep -E 'timestamp_mode|scheduler_variant' | head -5
```

Expected: at least one reference to the pinned enum values.

- [ ] **Step 2: Run n=7 and diff**

```bash
zig build bench-runtime-zig -Doptimize=ReleaseFast \
  -Dtimestamp-mode=disabled \
  -Dscheduler-variant=work_stealing \
  -- --samples 7 --warmup-discard 1 \
  --output docs/performance/contended-scenarios-2026-04-16/elision-results.json
```

- [ ] **Step 3: Write the findings**

Create `docs/performance/contended-scenarios-2026-04-16/elision-binary.md`:

```markdown
# Elision-binary (timestamp-mode=disabled + scheduler-variant=work_stealing)

Build: `zig build bench-runtime-zig -Doptimize=ReleaseFast
  -Dtimestamp-mode=disabled -Dscheduler-variant=work_stealing`.

## Medians (n=6 retained after 1 warmup discard)

| Scenario | Default ops/sec | Elision ops/sec | Delta |
|----------|----------------:|----------------:|------:|
| contended_spawn_8x   | ___ | ___ | ___ |
| contended_cpu_10us   | ___ | ___ | ___ |
| nested_fanout_4x     | ___ | ___ | ___ |
| mixed_fast_slow      | ___ | ___ | ___ |
| cpu_work_10us        | ___ | ___ | ___ |
| cpu_work_100us       | ___ | ___ | ___ |

Source: `elision-results.json` (this directory) + `phase1-after.json`.

## Interpretation

(Fill with whether comptime elision is a viable user-facing lever on
these scenarios — if the delta is >5%, Phase 4 should update CLAUDE.md
to document the elision-build numbers separately.)
```

Fill the blanks from the JSON files with `jq`. No commit of elision binary itself — it's a flag, not a branch.

- [ ] **Step 4: Commit the findings doc**

```bash
git add docs/performance/contended-scenarios-2026-04-16/elision-binary.md \
         docs/performance/contended-scenarios-2026-04-16/elision-results.json
git commit -m "perf: measure -Dtimestamp-mode=disabled -Dscheduler-variant=work_stealing"
```

---

## Task 8: Phase 2B — Profile `contended_spawn_8x`

This scenario is already fully tuned on the harness side (registers 8 submitters). The 4.18x gap vs Go is structural — our task-per-submit overhead vs Go's per-P local runqueue. Profiling identifies the hottest function under `perf record`.

**Files:**
- Create: `docs/performance/contended-scenarios-2026-04-16/profile-contended_spawn_8x.md`.

- [ ] **Step 1: Build an instrumentable binary**

```bash
zig build bench-runtime-zig -Doptimize=ReleaseFast -fno-strip
```

Note: `-fno-strip` keeps DWARF info for `perf report` symbolisation. If `-fno-strip` is not a valid Zig flag on 0.16.0, use `-Doptimize=ReleaseSafe` as a fallback (slightly slower but keeps symbols).

- [ ] **Step 2: Run the scenario under perf**

```bash
perf record -F 999 -g --call-graph=dwarf -o /tmp/perf-contended-spawn-8x.data \
  zig-out/bin/thread-pool-runtime-compare-zig \
  --samples 1 --warmup-discard 0 \
  2>/dev/null || echo "perf record failed — check kernel.perf_event_paranoid"
```

If the above fails with `perf_event_open: Operation not permitted`, confirm:

```bash
cat /proc/sys/kernel/perf_event_paranoid
```

Expected: `<=2`. If higher, run `sudo sysctl -w kernel.perf_event_paranoid=1` first. Do not commit the `/tmp/perf-*.data` files.

- [ ] **Step 3: Extract the top-20 self-time**

```bash
perf report --stdio --no-children \
  -i /tmp/perf-contended-spawn-8x.data \
  | awk '/^#/{next} NF<4{next} {print}' \
  | head -20 \
  > /tmp/perf-contended-spawn-8x.top20.txt
```

- [ ] **Step 4: Write the finding**

Create `docs/performance/contended-scenarios-2026-04-16/profile-contended_spawn_8x.md`:

```markdown
# Profile: contended_spawn_8x

Captured: $(date -u +%Y-%m-%dT%H:%M:%SZ)
HEAD: $(git rev-parse HEAD)
Binary: ReleaseFast + harness registerSubmitter (Phase 1).

## Top-20 self-time (from `perf report --no-children`)

```
<paste /tmp/perf-contended-spawn-8x.top20.txt content>
```

## Attack candidates

Based on the top self-time entries, list 2–4 candidate attacks ordered
by expected gain. Each candidate must reference a **specific** function
or line in `src/pool.zig`. Use the form:

- **Candidate A: <title>**. Hotspot: <function at file:line>, <self-%>
  self-time. Hypothesis: <specific atomic / cacheline / code-path claim>.
  Attack: <concrete code change proposal>. Expected gain: <range>.
  Closed-plane check: does this intersect any of the closed planes
  above (drain-vs-steal reorder, parked-workers bitmap, etc.)? If yes,
  refuse and mark as `closed-plane-blocked`.

## Next

Phase 3A picks the highest-expected-gain candidate that is NOT
closed-plane-blocked. If all candidates are blocked, this scenario is
deferred to a future plan with the rationale recorded here.
```

Fill the candidates based on the actual `perf report` output. Common suspects (but do not commit to these until the actual profile is read):
- `BoundedRing.tryPush` head/tail contention in the per-submitter queue.
- `counters.submitted.fetchAdd` (.monotonic — cheap, probably not a hotspot).
- `queuedTasksCounter.fetchAdd` (.seq_cst — expensive).
- `scanAndWake` / `notifySubmits` (previously 27.58% on flood_1m_batched).
- `releaseDescriptor` / `acquireDescriptor` bit-mask scan.

- [ ] **Step 5: Commit**

```bash
git add docs/performance/contended-scenarios-2026-04-16/profile-contended_spawn_8x.md
git commit -m "perf: profile contended_spawn_8x and list attack candidates"
```

---

## Task 9: Phase 2C — Profile `contended_cpu_10us`

Repeat Task 8's procedure for `contended_cpu_10us`. Profile the post-Phase-1 binary (submitters registered). Expect a different top-of-list than `contended_spawn_8x` because per-task work is 10µs real CPU, so scheduler overhead should be a smaller fraction.

**Files:**
- Create: `docs/performance/contended-scenarios-2026-04-16/profile-contended_cpu_10us.md`.

- [ ] **Step 1: Run perf on this scenario only**

Modify the harness run (temporarily, with `git stash`) to run ONLY `contended_cpu_10us`. Or: run all 8 and scope the `perf record` to a time window that covers only that scenario by adding `clock.sleep(500 * std.time.ns_per_ms)` before and after. Simpler alternative — run the full matrix under perf and use `perf script` to filter.

```bash
perf record -F 999 -g --call-graph=dwarf \
  -o /tmp/perf-contended-cpu-10us.data \
  zig-out/bin/thread-pool-runtime-compare-zig \
  --samples 1 --warmup-discard 0
```

- [ ] **Step 2: Extract top-20**

```bash
perf report --stdio --no-children \
  -i /tmp/perf-contended-cpu-10us.data \
  | awk '/^#/{next} NF<4{next} {print}' \
  | head -40 > /tmp/perf-contended-cpu-10us.top40.txt
```

(Top-40 because this is the whole-matrix capture; we want enough lines to identify the contended_cpu_10us-specific hotspots via symbol names.)

- [ ] **Step 3: Write `profile-contended_cpu_10us.md`**

Same structure as `profile-contended_spawn_8x.md`. Key distinction: this scenario has 10µs of real CPU work per task. If the top-20 is dominated by `realisticTask` / `busyWork`, the scheduler is already a small fraction and the Phase-1 gain is what the user should expect. In that case, the candidate list should reflect "no further action needed; gap is largely arithmetic".

- [ ] **Step 4: Commit**

```bash
git add docs/performance/contended-scenarios-2026-04-16/profile-contended_cpu_10us.md
git commit -m "perf: profile contended_cpu_10us and list attack candidates"
```

---

## Task 10: Phase 2D — Profile `nested_fanout_4x`

This scenario's 6.04x gap is the largest. Child submissions from worker context hit the LIFO slot / local-queue fast path. Profile will show whether the gap is per-task descriptor overhead (most likely) or cross-worker stealing latency.

**Files:**
- Create: `docs/performance/contended-scenarios-2026-04-16/profile-nested_fanout_4x.md`.

- [ ] **Step 1: Build and profile**

```bash
zig build bench-runtime-zig -Doptimize=ReleaseFast
perf record -F 999 -g --call-graph=dwarf \
  -o /tmp/perf-nested-fanout-4x.data \
  zig-out/bin/thread-pool-runtime-compare-zig \
  --samples 1 --warmup-discard 0
perf report --stdio --no-children \
  -i /tmp/perf-nested-fanout-4x.data \
  > /tmp/perf-nested-fanout-4x.full.txt
```

- [ ] **Step 2: Extract call chains for `nestedParentTask`**

```bash
grep -A 30 'nestedParentTask' /tmp/perf-nested-fanout-4x.full.txt \
  | head -50 > /tmp/perf-nested-fanout-4x.parent.txt
```

The call chain from `nestedParentTask` shows exactly which pool function the child submissions are routed through (`enqueuePush` → LIFO store vs local_queue.tryPushBottom vs inject_queue fallback).

- [ ] **Step 3: Write `profile-nested_fanout_4x.md`**

Same structure as Task 8 Step 4. Key sections:

- Top-20 self-time.
- Call-chain breakdown of `nestedParentTask`: what fraction of child submissions hit (a) LIFO slot, (b) local_queue.tryPushBottom, (c) inject_queue fallback?
- Attack candidates. Likely suspects: LIFO-slot contention with stealer (steal reads LIFO?), descriptor acquisition on hot path, `queuedTasksCounter` seq_cst fetchAdd per child (× 8000 children).

- [ ] **Step 4: Commit**

```bash
git add docs/performance/contended-scenarios-2026-04-16/profile-nested_fanout_4x.md
git commit -m "perf: profile nested_fanout_4x and list attack candidates"
```

---

## Task 11: Phase 2E — Profile `mixed_fast_slow`

Smallest gap (1.12x); expected to be dominated by real work (1ms slow tasks), not scheduler overhead. Profile will confirm.

**Files:**
- Create: `docs/performance/contended-scenarios-2026-04-16/profile-mixed_fast_slow.md`.

- [ ] **Step 1: Profile + extract + write**

Same procedure as Task 10. If the profile shows `busyWork` / sleep dominating >80%, the scenario's gap is arithmetic (Go's goroutines do not steal CPU from each other as aggressively on a workload with long blocking tasks). In that case, the attack list is `[none actionable without a structural change]` and the scenario is deferred to a future plan.

- [ ] **Step 2: Commit**

```bash
git add docs/performance/contended-scenarios-2026-04-16/profile-mixed_fast_slow.md
git commit -m "perf: profile mixed_fast_slow and list attack candidates"
```

---

## Task 12: Phase 3 — Attack Triage (branching)

After the four profile docs exist, review them together to decide Phase-3 work.

**Files:**
- Create: `docs/performance/contended-scenarios-2026-04-16/phase3-plan.md`.

- [ ] **Step 1: Read all four profile docs**

```bash
for s in contended_spawn_8x contended_cpu_10us nested_fanout_4x mixed_fast_slow; do
  echo "=== $s ==="
  cat "docs/performance/contended-scenarios-2026-04-16/profile-$s.md"
done > /tmp/profiles-combined.md
```

- [ ] **Step 2: Rank non-blocked candidates across scenarios**

Write `docs/performance/contended-scenarios-2026-04-16/phase3-plan.md`:

```markdown
# Phase 3 attack triage

## Non-blocked candidates (ranked by expected gain × scenario impact)

| Rank | Candidate | Scenarios affected | Hotspot | Expected gain | Risk |
|-----:|-----------|--------------------|---------|--------------|------|
| 1 | ___ | ___ | ___ | ___ | ___ |
| 2 | ___ | ___ | ___ | ___ | ___ |
| 3 | ___ | ___ | ___ | ___ | ___ |

## Blocked candidates

| Candidate | Reason (closed plane) |
|-----------|-----------------------|
| ___ | ___ |

## Phase 3 attack order

Pick rank 1. If rank 1 lands and passes all gates, continue to rank 2.
If rank 1 fails an A/B gate, revert, document in
`docs/performance/contended-scenarios-2026-04-16/phase3-failed-<N>.md`,
then try rank 2.

Maximum 3 attacks before the plan declares the remaining gap
architectural and Phase 4 runs the final snapshot.
```

- [ ] **Step 3: Commit**

```bash
git add docs/performance/contended-scenarios-2026-04-16/phase3-plan.md
git commit -m "perf: triage Phase-3 attack candidates"
```

---

## Task 13: Phase 3A — Execute Rank-1 Attack

This task is deliberately **generic** — its content depends on what Phase 2 finds. The steps below are the TDD-style scaffold any Phase-3 attack follows.

**Files:**
- Modify: `src/pool.zig` (or `src/types.zig`, `src/stats/latency.zig`, etc.) — the hotspot identified in the ranked candidate.
- Create: `docs/performance/contended-scenarios-2026-04-16/phase3a-<attack-name>.md`.

- [ ] **Step 1: Write the failing regression test (if the attack is a behaviour change)**

If the attack adds a new configuration flag or changes a public behaviour, add a unit test in `tests/unit.zig` that asserts the new behaviour. Run:

```bash
zig build test --summary all 2>&1 | grep -E 'FAIL|PASS'
```

Expected: the new test fails (because the attack hasn't been implemented). If the attack is purely a micro-optimisation with no behaviour change, skip to Step 2 and note the skip in the phase3a doc.

- [ ] **Step 2: Implement the change**

Edit `src/pool.zig` (or other source file) with the minimum code needed. Do NOT combine two attacks in one task. Do NOT rewrite surrounding code.

- [ ] **Step 3: Verify tests pass**

```bash
zig build test --summary all
zig build test-integration --summary all
```

Expected: both green.

- [ ] **Step 4: Paired A/B n=10 on the target scenarios**

Run the same n=10 procedure from Task 2 Step 5, but against ALL FOUR target scenarios AND `flood_1m` (regression guard):

```bash
for arm in A B; do
  (if [ "$arm" = "A" ]; then git stash push -- src/pool.zig; fi
   zig build bench-runtime-zig -Doptimize=ReleaseFast
   for i in $(seq 1 10); do
     zig build bench-runtime-zig -Doptimize=ReleaseFast -- \
       --samples 1 --warmup-discard 0 \
       --output /tmp/ab-$arm-$i.json 2>/dev/null
   done
   if [ "$arm" = "A" ]; then git stash pop; fi)
done

for scenario in contended_spawn_8x contended_cpu_10us nested_fanout_4x mixed_fast_slow flood_1m; do
  for arm in A B; do
    for i in $(seq 1 10); do
      jq -r ".rows[] | select(.scenario_name == \"$scenario\") | .median_ops_per_sec" \
         /tmp/ab-$arm-$i.json
    done | sort -n | awk -v s="$scenario" -v a="$arm" 'NR==5{print s,a,$0}'
  done
done
```

Gate:
- Target scenario: B ≥ A × (1 + expected_gain × 0.5) — require at least half the expected gain.
- flood_1m: B ≥ A × 0.98 (no >2% regression).
- All other scenarios in the 8-row matrix: B ≥ A × 0.98.

If any gate fails — revert. Do not argue with the gate.

- [ ] **Step 5: 20× stress gate**

```bash
for i in $(seq 1 20); do
  zig build test-stress --summary all || { echo "FAIL on iter $i"; break; }
done
```

Expected: 20/20 pass.

- [ ] **Step 6: Write `phase3a-<attack-name>.md`**

Document: what changed (file:line), A/B medians per scenario, stress result, commit SHA. Same format as the historical iter-N docs under `docs/performance/appsec-fixes-2026-04-15/`.

- [ ] **Step 7: Commit**

```bash
git add src/pool.zig tests/unit.zig  # whichever files actually changed
git add docs/performance/contended-scenarios-2026-04-16/phase3a-<attack-name>.md
git commit -m "perf: <concise description of the attack> — +N% on <scenario>"
```

---

## Task 14: Phase 3B — Execute Rank-2 Attack (if Phase 3A landed)

Same structure as Task 13 but for the rank-2 candidate. If Phase 3A was reverted, Phase 3B starts from pre-Phase-3A state and takes the rank-2 candidate as the new rank-1.

**Termination rule:** If Phase 3A and Phase 3B both fail their A/B gates, declare the remaining gap architectural and skip Phase 3C. Proceed to Phase 4.

- [ ] **Step 1–7:** Identical scaffold to Task 13.

---

## Task 15: Phase 3C — Execute Rank-3 Attack (optional, only if 3A and 3B both succeeded)

Rank-3 is the lowest-expected-gain candidate and gets the strictest bar. If Phase 3A and Phase 3B both landed, this task runs; otherwise it's skipped.

- [ ] **Step 1–7:** Identical scaffold to Task 13. Gate is the same.

---

## Task 16: Phase 4A — Final Snapshot

**Files:**
- Modify: `benchmarks/results/runtime-comparison-latest.json`.
- Modify: `benchmarks/results/baseline.json`.
- Modify: `benchmarks/results/scale-latest.json`.

- [ ] **Step 1: Refresh runtime-compare**

```bash
zig build bench-runtime-compare -Doptimize=ReleaseFast -- \
  --samples 7 --warmup-discard 1 \
  --output benchmarks/results/runtime-comparison-latest.json
```

Expected: 24 rows (8 scenarios × 3 runtimes). Console shows a clean run.

- [ ] **Step 2: Refresh bench baseline**

```bash
zig build bench -- --output benchmarks/results/baseline.json
```

Expected: CI-safe bench suite completes.

- [ ] **Step 3: Refresh scale baseline**

```bash
zig build scale-bench -- --output benchmarks/results/scale-latest.json
```

Expected: scale-bench completes.

- [ ] **Step 4: Commit baselines**

```bash
git add benchmarks/results/runtime-comparison-latest.json \
         benchmarks/results/baseline.json \
         benchmarks/results/scale-latest.json
git commit -m "perf: refresh baselines post-contended-scenarios gap-close"
```

---

## Task 17: Phase 4B — Update CLAUDE.md Snapshot

**Files:**
- Modify: `CLAUDE.md` — the "Current Direct Runtime Snapshot" section.

- [ ] **Step 1: Read the existing section**

```bash
grep -n 'Current Direct Runtime Snapshot' CLAUDE.md
```

Expected: one match; the section is roughly 40 lines long.

- [ ] **Step 2: Extract the new medians**

```bash
jq -r '.runtime_name as $r | .rows[] | "\($r) \(.scenario_name) \(.median_ops_per_sec) \(.latency_p50_us) \(.latency_p95_us) \(.latency_p99_us)"' \
   benchmarks/results/runtime-comparison-latest.json
```

Expected: 24 lines. Use them to update the tables in CLAUDE.md.

- [ ] **Step 3: Rewrite the section**

Replace the existing throughput table, latency table, and interpretation bullets. Keep the host-state caveat paragraph (thermal drift reminder). Add one new bullet under "Interpretation":

> - 2026-04-16 gap-close session (commits <SHA range>) narrowed the four
>   Zig-behind scenarios: <list before → after multipliers>. Phase-1
>   harness-fairness fixes accounted for most of the gain on the three
>   scenarios that were not registering submitters. Phase-3 attacks (if
>   any) are summarised in
>   `docs/performance/contended-scenarios-2026-04-16/FINAL.md`.

- [ ] **Step 4: Commit**

```bash
git add CLAUDE.md
git commit -m "docs(claude): refresh runtime snapshot post-contended-scenarios"
```

---

## Task 18: Phase 4C — Write the FINAL report

**Files:**
- Create: `docs/performance/contended-scenarios-2026-04-16/FINAL.md`.

- [ ] **Step 1: Write the report**

Structure:

```markdown
# Contended-scenarios gap-close — FINAL

Plan: `docs/superpowers/plans/2026-04-16-contended-scenarios-gap.md`
Range: <first commit SHA> … <last commit SHA>
Duration: <start date> → <end date>

## Headline

| Scenario | Baseline gap vs Go | Final gap vs Go | Change |
|----------|:------------------:|:---------------:|:------:|
| contended_spawn_8x   | 4.18x behind | ___ | ___ |
| contended_cpu_10us   | 1.97x behind | ___ | ___ |
| nested_fanout_4x     | 6.04x behind | ___ | ___ |
| mixed_fast_slow      | 1.12x behind | ___ | ___ |

## What landed

- Phase 1A–1D (harness fairness): commits ___.
- Phase 3A: <attack name> / ___ (or "not landed — gap architectural").
- Phase 3B: ___.
- Phase 3C: ___.

## What was tried and reverted

- ___

## Closed planes confirmed (did not re-attempt)

- drain-vs-steal reorder (Options C/D).
- parked_workers shared u64 bitmap.
- Single-worker wake probe.
- is_parked cacheline isolation.
- shouldExit off hot path.
- Per-worker active_tasks shard.
- Socket-aware worker pinning.

## Measurement audit

- Every landing: n=10 paired A/B, 20× ReleaseFast stress, <2% regression
  on every non-target scenario.
- Final snapshot: n=6 retained after 1 warmup discard,
  `benchmarks/results/runtime-comparison-latest.json`.

## Host-state caveat

Measurements were taken on <date> on <hostname>. Thermal drift during
the session is documented in `baseline-medians.md`.

## Next

- Re-audit `bench-realistic` and `bench-tokio-parity` harnesses for the
  same submitter-registration gap (remaining 5 scenarios; deferred from
  this plan).
- Revisit after a Zig toolchain upgrade (.16 → .17).
```

- [ ] **Step 2: Commit**

```bash
git add docs/performance/contended-scenarios-2026-04-16/FINAL.md
git commit -m "docs: final report for contended-scenarios gap-close"
```

---

## Task 19: Phase 4D — Push

- [ ] **Step 1: Review commits**

```bash
git log --oneline main..HEAD
```

Expected: a list of commits from Task 0 through Task 18. Each should be a single-purpose commit.

- [ ] **Step 2: Dry-run push**

```bash
git push --dry-run origin main
```

Expected: a successful dry-run showing the commits that would be pushed.

- [ ] **Step 3: Push**

```bash
git push origin main
```

Confirm with the user before running this. This is a shared-state change; do not skip confirmation.

---

## Self-Review

**Spec coverage:**
- contended_spawn_8x → addressed by Task 8 (profile) + Task 13 (if Phase-3 attack is justified by profile). No harness fix needed (already tuned).
- contended_cpu_10us → Task 2 (Phase 1A harness fix) + Task 9 (profile) + Task 13 (if attack).
- nested_fanout_4x → Task 3 (Phase 1B harness fix) + Task 10 (profile) + Task 13 (if attack).
- mixed_fast_slow → Task 4 (Phase 1C harness fix) + Task 11 (profile) + Task 13 (if attack).

**Placeholder scan:** The plan contains deliberate placeholders ONLY in the profile / triage / FINAL documents, because those contents depend on perf output that doesn't exist yet. Every code change step shows the exact code. Every A/B gate shows the exact gate. Every commit shows the exact message.

**Type / API consistency:**
- `registerSubmitter` / `releaseSubmitter` — consistent across Tasks 2, 3, 4, 5.
- `max_submitter_queues` / `submitter_queue_capacity` — consistent everywhere; always paired.
- `ScenarioSpec.register_submitters` — new field added in Task 5 Step 2, used in Task 5 Step 5. No other task references it.
- `SubmitterCtx.register` — new field added in Task 5 Step 4, used in `submitRange` (same task). No external reference.
- Commit messages follow `perf:` / `perf(bench):` / `docs:` prefixes consistent with repo history.

**Closed-plane check:** Every Phase-3 step (Tasks 13, 14, 15) requires candidates to pass a closed-plane check. The plan enumerates 7 closed planes at the top.

**Measurement rules:** Every A/B is same-session, n=10. Every landing is preceded by 20× ReleaseFast stress. No relative-date references — all absolute (`2026-04-16`).

---

## Execution Handoff

**Plan complete and saved to `docs/superpowers/plans/2026-04-16-contended-scenarios-gap.md`. Two execution options:**

**1. Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, review between tasks, fast iteration.

**2. Inline Execution** — Execute tasks in this session using executing-plans, batch execution with checkpoints.

**Which approach?**
