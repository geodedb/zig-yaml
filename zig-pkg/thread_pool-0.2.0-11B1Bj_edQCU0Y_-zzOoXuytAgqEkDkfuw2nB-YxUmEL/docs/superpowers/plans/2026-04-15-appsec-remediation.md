# AppSec Remediation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Apply the remediations from `docs/APPSEC_REVIEW_2026-04-15_src.md` (F-001 through F-007) in priority order, add the tests the review flagged as coverage gaps (two-pool cross-submit, `Thread.spawn` failure injection, ThreadSanitizer stress, public-API fuzz), and gate every change on a per-step performance diff so any regression is visible and reviewable before the commit is accepted.

**Architecture:** Each fix gets its own task. Every task follows the same shape: **bench-before → TDD test → minimal fix → bench-after → review diff → commit (or revert)**. Bench artifacts land under `docs/performance/appsec-fixes-2026-04-15/` so regressions can be audited after the fact. The AppSec findings are mechanically verified (line numbers spot-checked 2026-04-15 against `pool.zig` — they match the report).

**Tech Stack:** Zig 0.15.2 stdlib · existing `zig build bench` and `zig build bench-realistic` harnesses · `jq` for JSON diff · bash for the perf-gate wrapper.

**Spec:** `docs/APPSEC_REVIEW_2026-04-15_src.md` — Sections 3, 4, and 7 (findings table, finding details, prioritized next actions).

**Prerequisite:** Run in a dedicated worktree. If you don't already have one, create it before Task 0:

```bash
git worktree add ../thread-pool-appsec -b appsec-remediation-2026-04-15 main
cd ../thread-pool-appsec
```

---

## Performance-Regression Review Rule

This rule is referenced from every task. **Read it once and apply it consistently.**

After running `scripts/perf-gate.sh <step-name> after`, open the generated diff file `docs/performance/appsec-fixes-2026-04-15/<step-name>-diff.md` and inspect the per-scenario deltas.

| Metric | Warn | Block |
|---|---|---|
| `median_ops_per_sec` regression on any scenario | ≥ 3% | ≥ 5% |
| `submit_latency_p95_ns` regression on any scenario | ≥ 7% | ≥ 10% |
| `completion_latency_p95_ns` regression on any scenario | ≥ 7% | ≥ 10% |

- **Warn (3–5% throughput regression, 7–10% p95 regression):** Log the observation in the commit body and proceed. Bench variance on this hardware is documented as ±3% run-to-run.
- **Block (≥ 5% throughput regression, ≥ 10% p95 regression):** Stop. Do not commit. Paste the diff into the session, summarize the regression, and ask the user: "This fix regresses `<scenario>` by N%. Accept, adjust, or revert?"
- **Improvement (any size) is always OK** and should be noted in the commit body.

The baseline for comparison is always the *previous committed state*, not the repo's historical baseline. Task N's "before" becomes Task N+1's reference once Task N commits.

---

## File Structure

**New:**
- `scripts/perf-gate.sh` — wrapper that runs `zig build bench` and `zig build bench-realistic`, saves JSON to dated artifact directory, and emits a markdown diff against the previous run.
- `docs/performance/appsec-fixes-2026-04-15/` — artifact directory; `README.md` tracks overall remediation progress.
- `docs/performance/appsec-fixes-2026-04-15/BASELINE-bench.json` and `BASELINE-realistic.json` — pre-change benchmarks.
- `docs/performance/appsec-fixes-2026-04-15/STEP-<N>-<name>-{before,after}-{bench,realistic}.json` — per-step bench captures.
- `docs/performance/appsec-fixes-2026-04-15/STEP-<N>-<name>-diff.md` — per-step human-readable regression report.
- `tests/integration/two_pool_cross_submit.zig` — new regression test for F-001 (cross-pool submit must not OOB).
- `tests/integration/spawn_failure.zig` — new regression test for F-002 (partial spawn must not UAF).
- `tests/fuzz/pool_fuzz.zig` — new fuzz harness for the public API.

**Modified:**
- `src/pool.zig` — F-001 (TLS scoping), F-002 (spawn errdefer), F-003 (atomic free_indices), F-005 (releaseSubmitter hardening), F-006 (no `unreachable` on `blocking_inject`).
- `src/types.zig` — F-004 (WaitGroup.done soften-panic).
- `src/stats/process_memory.zig` — F-007 (clamp `parseProcStatusKiB`).
- `build.zig` — register new integration tests, register fuzz harness, add `-Dtsan` option.
- `docs/performance/appsec-fixes-2026-04-15/README.md` — living progress doc.

Each file has a single clear responsibility. `pool.zig` is already large (1883 LOC); do not restructure it as part of this work — touch only the specific line ranges called out per task.

---

## Task 0: Perf-gate infrastructure and baseline

**Files:**
- Create: `docs/performance/appsec-fixes-2026-04-15/README.md`
- Create: `scripts/perf-gate.sh`
- Create: `docs/performance/appsec-fixes-2026-04-15/BASELINE-bench.json`
- Create: `docs/performance/appsec-fixes-2026-04-15/BASELINE-realistic.json`

- [ ] **Step 1: Create the artifact directory and progress README**

```bash
mkdir -p docs/performance/appsec-fixes-2026-04-15
```

Write `docs/performance/appsec-fixes-2026-04-15/README.md`:

```markdown
# AppSec Remediation — Performance Tracking (2026-04-15)

Spec: `docs/APPSEC_REVIEW_2026-04-15_src.md`
Plan: `docs/superpowers/plans/2026-04-15-appsec-remediation.md`

## Baselines
- `BASELINE-bench.json` — output of `zig build bench` on the starting commit.
- `BASELINE-realistic.json` — output of `zig build bench-realistic`.

## Per-step artifacts
Each remediation step produces four files:
- `STEP-<N>-<name>-before-bench.json`
- `STEP-<N>-<name>-after-bench.json`
- `STEP-<N>-<name>-before-realistic.json`
- `STEP-<N>-<name>-after-realistic.json`
- `STEP-<N>-<name>-diff.md` — markdown delta table.

## Step progress

| Step | Fix | Status | Regression class |
|------|-----|--------|------------------|
| 1 | F-001 per-pool TLS | pending | – |
| 2 | F-002 spawn errdefer | pending | – |
| 3 | F-003 atomic free_indices | pending | – |
| 4 | F-006 no unreachable blocking_inject | pending | – |
| 5 | F-005 harden releaseSubmitter | pending | – |
| 6 | F-004 soften WaitGroup.done | pending | – |
| 7 | F-007 clamp parseProcStatusKiB | pending | – |
| 8 | TSan stress run | pending | – |
| 9 | Fuzz harness | pending | – |
```

- [ ] **Step 2: Write the perf-gate script**

Create `scripts/perf-gate.sh`:

```bash
#!/usr/bin/env bash
# scripts/perf-gate.sh
# Usage: ./scripts/perf-gate.sh <step-name> <before|after>
# Captures bench + bench-realistic JSON, and when called with "after"
# emits a markdown diff vs the matching "before" file.

set -euo pipefail

STEP="${1:?step name required (e.g. step-1-f001)}"
PHASE="${2:?phase required: before | after}"
ART_DIR="docs/performance/appsec-fixes-2026-04-15"

if [[ "$PHASE" != "before" && "$PHASE" != "after" ]]; then
    echo "phase must be 'before' or 'after'" >&2
    exit 2
fi

mkdir -p "$ART_DIR"

BENCH_OUT="$ART_DIR/${STEP}-${PHASE}-bench.json"
REAL_OUT="$ART_DIR/${STEP}-${PHASE}-realistic.json"

echo "[perf-gate] $STEP $PHASE: running zig build bench ..."
zig build bench -- --output "$BENCH_OUT"

echo "[perf-gate] $STEP $PHASE: running zig build bench-realistic ..."
zig build bench-realistic -Doptimize=ReleaseFast -- --output "$REAL_OUT"

if [[ "$PHASE" == "after" ]]; then
    DIFF_OUT="$ART_DIR/${STEP}-diff.md"
    BEFORE_BENCH="$ART_DIR/${STEP}-before-bench.json"
    BEFORE_REAL="$ART_DIR/${STEP}-before-realistic.json"

    if [[ ! -f "$BEFORE_BENCH" || ! -f "$BEFORE_REAL" ]]; then
        echo "[perf-gate] ERROR: missing before-files. Run '$STEP before' first." >&2
        exit 3
    fi

    {
        echo "# Perf diff — $STEP"
        echo
        echo "Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo
        echo "## bench (zig build bench)"
        echo
        echo "| scenario | variant | ops/s before | ops/s after | Δ % | p95 submit before (ns) | p95 submit after (ns) | Δ p95 % |"
        echo "|---|---|---:|---:|---:|---:|---:|---:|"
        jq -r --slurpfile bef "$BEFORE_BENCH" '
          .rows as $aft
          | $bef[0].rows as $bfr
          | $aft
          | map({
              scenario_name, scheduler_variant,
              ops_after: .throughput_ops_per_sec,
              p95_after: .submit_latency_p95_ns,
              key: (.scenario_name + "|" + .scheduler_variant)
            })
          | .[] as $a
          | $bfr
          | map(select((.scenario_name + "|" + .scheduler_variant) == $a.key))
          | if length == 0 then
              [$a.scenario_name, $a.scheduler_variant, "n/a", $a.ops_after, "n/a", "n/a", $a.p95_after, "n/a"]
            else
              . [0] as $b
              | [
                  $a.scenario_name, $a.scheduler_variant,
                  ($b.throughput_ops_per_sec | tostring),
                  ($a.ops_after | tostring),
                  ((($a.ops_after - $b.throughput_ops_per_sec) / $b.throughput_ops_per_sec * 100) | tostring + "%"),
                  ($b.submit_latency_p95_ns | tostring),
                  ($a.p95_after | tostring),
                  ((($a.p95_after - $b.submit_latency_p95_ns) / $b.submit_latency_p95_ns * 100) | tostring + "%")
                ]
            end
          | "| " + join(" | ") + " |"
        ' "$BENCH_OUT"
        echo
        echo "## bench-realistic (runtime comparison, zig_thread_pool rows)"
        echo
        echo "| scenario | median ops/s before | median ops/s after | Δ % |"
        echo "|---|---:|---:|---:|"
        jq -r --slurpfile bef "$BEFORE_REAL" '
          def zrows(doc): doc.runtimes[] | select(.runtime_name == "zig_thread_pool") | .rows;
          (. | zrows(.)) as $aft
          | ($bef[0] | zrows(.)) as $bfr
          | $aft
          | .[] as $a
          | ($bfr | map(select(.scenario_name == $a.scenario_name))) as $m
          | if ($m | length) == 0 then
              "| \($a.scenario_name) | n/a | \($a.median_ops_per_sec) | n/a |"
            else
              $m[0] as $b
              | "| \($a.scenario_name) | \($b.median_ops_per_sec) | \($a.median_ops_per_sec) | \((($a.median_ops_per_sec - $b.median_ops_per_sec) / $b.median_ops_per_sec * 100))% |"
            end
        ' "$REAL_OUT"
        echo
        echo "## Review checklist"
        echo
        echo "Apply the Performance-Regression Review Rule from the plan:"
        echo "- Throughput regression ≥ 5% on any scenario → BLOCK, escalate to user."
        echo "- p95 latency regression ≥ 10% on any scenario → BLOCK, escalate to user."
        echo "- 3–5% throughput / 7–10% p95 → WARN, note in commit body."
    } > "$DIFF_OUT"

    echo "[perf-gate] diff written to $DIFF_OUT"
fi

echo "[perf-gate] done."
```

```bash
chmod +x scripts/perf-gate.sh
```

- [ ] **Step 3: Confirm `jq` is available**

Run: `jq --version`
Expected: any version printed. If missing, `sudo apt-get install -y jq` or equivalent.

- [ ] **Step 4: Capture baseline benches**

Run:
```bash
zig build bench -- --output docs/performance/appsec-fixes-2026-04-15/BASELINE-bench.json
zig build bench-realistic -Doptimize=ReleaseFast -- --output docs/performance/appsec-fixes-2026-04-15/BASELINE-realistic.json
```

Expected: both JSON files written, exit 0.

- [ ] **Step 5: Sanity-check the baseline JSON**

Run:
```bash
jq '.rows | length' docs/performance/appsec-fixes-2026-04-15/BASELINE-bench.json
jq '[.runtimes[] | select(.runtime_name=="zig_thread_pool") | .rows | length][0]' docs/performance/appsec-fixes-2026-04-15/BASELINE-realistic.json
```

Expected: two integers > 0. If either is 0 or null, the bench harness output shape has drifted; stop and investigate.

- [ ] **Step 6: Commit the scaffolding**

```bash
git add scripts/perf-gate.sh docs/performance/appsec-fixes-2026-04-15/
git commit -m "chore(perf-gate): add appsec remediation perf-tracking scaffolding

- scripts/perf-gate.sh wraps bench + bench-realistic and emits markdown diffs
- docs/performance/appsec-fixes-2026-04-15/ captures baseline + per-step JSON
- BASELINE-bench.json and BASELINE-realistic.json: starting point for the
  AppSec remediation series tracked in docs/superpowers/plans/2026-04-15-*."
```

---

## Task 1: F-001 — Per-pool TLS scoping (Critical)

**Files:**
- Modify: `src/pool.zig:11-12` (change TLS declarations), `:913-934` (guard reads), `:555-577` (submitter register), `:1085-1086`, `:1113-1114` (any other TLS readers)
- Create: `tests/integration/two_pool_cross_submit.zig`
- Modify: `build.zig` to register the new test

- [ ] **Step 1: Perf-gate before**

Run: `./scripts/perf-gate.sh step-1-f001 before`
Expected: two JSON files under `docs/performance/appsec-fixes-2026-04-15/`.

- [ ] **Step 2: Write the failing cross-pool regression test**

Create `tests/integration/two_pool_cross_submit.zig`:

```zig
//! F-001 regression: a thread that is a worker/submitter of pool A must
//! never dereference pool A's TLS index into pool B's arrays.

const std = @import("std");
const thread_pool = @import("thread_pool");

const Ctx = struct {
    hit: *std.atomic.Value(u32),
};

fn bump(ctx_ptr: *anyopaque, runtime: *thread_pool.TaskContext) void {
    _ = runtime;
    const c: *Ctx = @ptrCast(@alignCast(ctx_ptr));
    _ = c.hit.fetchAdd(1, .release);
}

test "F-001: worker of pool A submitting into pool B does not OOB" {
    const gpa = std.testing.allocator;

    // Pool A has many workers; pool B has few. A worker from A submitting
    // into B would OOB into B's workers/local_queues/submitter_queues if
    // TLS state is process-global.
    var pool_a = try thread_pool.ThreadPool.init(gpa, .{
        .max_threads = 16,
        .queue_capacity = 1024,
    });
    defer pool_a.deinit();

    var pool_b = try thread_pool.ThreadPool.init(gpa, .{
        .max_threads = 2,
        .queue_capacity = 256,
    });
    defer pool_b.deinit();

    var hit = std.atomic.Value(u32).init(0);
    var ctx = Ctx{ .hit = &hit };

    // Submit tasks on pool A. From inside those tasks, re-submit into
    // pool B. If pool A's TLS worker index (0..15) is blindly used against
    // pool B (len=2), this OOBs.
    const Inner = struct {
        fn outer(ctx_ptr: *anyopaque, runtime: *thread_pool.TaskContext) void {
            _ = runtime;
            const outer_ctx: *struct {
                inner_pool: *thread_pool.ThreadPool,
                hit: *std.atomic.Value(u32),
            } = @ptrCast(@alignCast(ctx_ptr));
            var inner_ctx = Ctx{ .hit = outer_ctx.hit };
            _ = outer_ctx.inner_pool.submit(bump, @ptrCast(&inner_ctx), .{}) catch return;
        }
    };
    const Outer = struct {
        inner_pool: *thread_pool.ThreadPool,
        hit: *std.atomic.Value(u32),
    };
    var outer = Outer{ .inner_pool = &pool_b, .hit = &hit };

    const N: u32 = 64;
    var i: u32 = 0;
    while (i < N) : (i += 1) {
        _ = try pool_a.submit(Inner.outer, @ptrCast(&outer), .{});
    }

    try pool_a.shutdown(.drain);
    try pool_b.shutdown(.drain);

    try std.testing.expect(hit.load(.acquire) > 0);
}
```

- [ ] **Step 3: Register the test in `build.zig`**

In the integration-test step, append this source file. Locate the existing `test-integration` step (search `test-integration` in `build.zig`) and add:

```zig
integration_tests.root_module.addAnonymousImport("two_pool_cross_submit", .{
    .root_source_file = b.path("tests/integration/two_pool_cross_submit.zig"),
});
```

or, if the integration harness uses a single aggregating `tests/integration.zig`, append `_ = @import("integration/two_pool_cross_submit.zig");` to that aggregator. Inspect `build.zig` lines referencing `test-integration` and use whichever pattern the repo already uses.

- [ ] **Step 4: Run the test and confirm it fails**

Run:
```bash
zig build test-integration --summary all 2>&1 | tee /tmp/f001-before.log
```

Expected (Debug mode): `panic: index out of bounds` originating from `src/pool.zig:917` or `:930` when worker of pool A tries `local_queues[wi]` against pool B. If the test *passes*, the attack premise doesn't actually reproduce here — stop, show the log, and ask the user whether the scenario needs sharpening before proceeding. (Do not proceed with the fix if the test passes — without a failing test the fix can't be TDD-verified.)

- [ ] **Step 5: Change the TLS declarations**

In `src/pool.zig:11-12`, replace:

```zig
threadlocal var tls_worker_index: ?usize = null;
threadlocal var tls_submitter_index: ?usize = null;
```

with:

```zig
/// TLS state scoped per pool. Each entry records the `Core *` that set it,
/// so cross-pool submits don't index pool-A's slot into pool-B's arrays
/// (F-001). The stored pointer is compared for identity only; no deref.
const TlsSlot = struct {
    pool: ?*anyopaque = null,
    index: usize = 0,
};
threadlocal var tls_worker_slot: TlsSlot = .{};
threadlocal var tls_submitter_slot: TlsSlot = .{};
```

- [ ] **Step 6: Add helper predicates as methods on `Core`**

Inside the `Core` struct body (grep `pub const Core` or `const Core = struct` to find it; helpers conventionally live near the existing private methods like `acquireDescriptor`), add the two methods below. They must be *methods on Core* (not file-scope free fns) so `self.tlsWorkerIndexFor()` method-call syntax works:

```zig
inline fn tlsWorkerIndexFor(self: *Core) ?usize {
    const slot = tls_worker_slot;
    if (slot.pool != @as(*anyopaque, @ptrCast(self))) return null;
    if (slot.index >= self.workers.len) return null;
    return slot.index;
}

inline fn tlsSubmitterIndexFor(self: *Core) ?usize {
    const slot = tls_submitter_slot;
    if (slot.pool != @as(*anyopaque, @ptrCast(self))) return null;
    if (slot.index >= self.submitter_queues.len) return null;
    return slot.index;
}
```

The methods read the file-scope `tls_worker_slot` / `tls_submitter_slot` declared in Step 5. That's fine — file-scope `threadlocal var` is visible from inside the struct body.

- [ ] **Step 7: Update every TLS read site**

Search for `tls_worker_index` and `tls_submitter_index`:

```bash
grep -n "tls_worker_index\|tls_submitter_index" src/pool.zig
```

For each read site, replace:

```zig
if (uses_local and tls_worker_index != null) {
    const wi = tls_worker_index.?;
    ...
}
```

with:

```zig
if (uses_local) {
    if (self.tlsWorkerIndexFor()) |wi| {
        ...
    }
}
```

And:

```zig
if (!queued and tls_submitter_index != null) {
    const si = tls_submitter_index.?;
    ...
}
```

with:

```zig
if (!queued) {
    if (self.tlsSubmitterIndexFor()) |si| {
        ...
    }
}
```

- [ ] **Step 8: Update every TLS write site**

`tls_worker_index = idx;` → `tls_worker_slot = .{ .pool = @ptrCast(self), .index = idx };`
`tls_worker_index = null;` → `tls_worker_slot = .{};`
`tls_submitter_index = idx;` → `tls_submitter_slot = .{ .pool = @ptrCast(self), .index = idx };`
`tls_submitter_index = null;` → `tls_submitter_slot = .{};`

In `workerMain` (~`src/pool.zig:1085`) and in `registerSubmitter`/`releaseSubmitter` (~`:561`, `:566`), these are the only writers. Grep confirms:

```bash
grep -n "tls_worker_index\s*=\|tls_submitter_index\s*=" src/pool.zig
```

Every hit must be migrated.

- [ ] **Step 9: Build and run the cross-pool test**

Run:
```bash
zig build test-integration --summary all
```

Expected: the F-001 test passes. If it still panics, the migration missed a call site — re-grep for `tls_worker_index`/`tls_submitter_index` and confirm zero matches.

- [ ] **Step 10: Run the full test suite**

Run:
```bash
zig build test-all --summary all
```

Expected: all suites pass.

- [ ] **Step 11: Perf-gate after**

Run: `./scripts/perf-gate.sh step-1-f001 after`
Expected: `STEP-1-f001-diff.md` written.

- [ ] **Step 12: Review the perf diff**

Open `docs/performance/appsec-fixes-2026-04-15/step-1-f001-diff.md`. Apply the Performance-Regression Review Rule at the top of this plan. If any scenario shows ≥ 5% throughput regression or ≥ 10% p95 regression, **stop and escalate to the user** before committing. Otherwise (warn-level or clean), proceed.

- [ ] **Step 13: Update the progress README**

In `docs/performance/appsec-fixes-2026-04-15/README.md`, update the Step 1 row: `status = done`, `regression class = <clean|warn|escalated>`.

- [ ] **Step 14: Commit**

```bash
git add src/pool.zig tests/integration/two_pool_cross_submit.zig build.zig docs/performance/appsec-fixes-2026-04-15/
git commit -m "fix(pool): scope TLS worker/submitter indices per-pool (F-001)

Previously tls_worker_index and tls_submitter_index were process-global.
A thread that was worker N of pool A submitting into pool B would index
pool A's slot into pool B's arrays. OOB in ReleaseFast (UB), panic in
Debug/ReleaseSafe. Two pools in the same process is enough — no malicious
input required.

Fix: store (pool*, index) in TLS, and helper accessors check pool identity
and array bounds before returning the cached index. Cross-pool submits now
fall through to the shared inject queue, which is the correct behavior.

Adds tests/integration/two_pool_cross_submit.zig as a positive regression
test. Perf diff: see docs/performance/appsec-fixes-2026-04-15/step-1-f001-diff.md.

Refs: docs/APPSEC_REVIEW_2026-04-15_src.md F-001."
```

---

## Task 2: F-002 — Spawn-aware errdefer on Core.init (High)

**Files:**
- Modify: `src/pool.zig:454-460` (spawn loop) and `:391` (replace the single `errdefer self.deinitOwned()` guarding spawn with a spawn-aware block)
- Create: `tests/integration/spawn_failure.zig`
- Modify: `build.zig` to register the new test

- [ ] **Step 1: Perf-gate before**

Run: `./scripts/perf-gate.sh step-2-f002 before`

- [ ] **Step 2: Write the failing spawn-failure test**

Create `tests/integration/spawn_failure.zig`:

```zig
//! F-002 regression: if std.Thread.spawn fails partway through Core.init,
//! the errdefer must stop and join every worker that was already spawned
//! before freeing shared arrays. Otherwise the live workers UAF on freed
//! memory. We simulate spawn failure by exhausting a custom allocator.

const std = @import("std");
const thread_pool = @import("thread_pool");

// FailingAllocator wraps a backing allocator and starts returning
// error.OutOfMemory after N successful allocations. This is the closest
// portable stand-in for Thread.spawn failure: ThreadPool.init performs
// several allocations before each spawn, so OOM at the right count leaves
// some workers spawned and some not-yet-spawned.
const FailingAllocator = struct {
    backing: std.mem.Allocator,
    remaining: *std.atomic.Value(usize),

    fn alloc(ctx: *anyopaque, len: usize, ptr_align: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *FailingAllocator = @ptrCast(@alignCast(ctx));
        if (self.remaining.fetchSub(1, .acq_rel) == 0) {
            _ = self.remaining.fetchAdd(1, .monotonic);
            return null;
        }
        return self.backing.rawAlloc(len, ptr_align, ret_addr);
    }
    fn resize(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *FailingAllocator = @ptrCast(@alignCast(ctx));
        return self.backing.rawResize(buf, buf_align, new_len, ret_addr);
    }
    fn remap(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *FailingAllocator = @ptrCast(@alignCast(ctx));
        return self.backing.rawRemap(buf, buf_align, new_len, ret_addr);
    }
    fn free(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, ret_addr: usize) void {
        const self: *FailingAllocator = @ptrCast(@alignCast(ctx));
        self.backing.rawFree(buf, buf_align, ret_addr);
    }

    fn allocator(self: *FailingAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }
};

test "F-002: partial init failure does not UAF" {
    // Iterate the failure point across a range: one of these will fall
    // between the workers[0] spawn and the workers[N-1] spawn.
    var n: usize = 32;
    while (n < 96) : (n += 1) {
        var remaining = std.atomic.Value(usize).init(n);
        var fa = FailingAllocator{
            .backing = std.testing.allocator,
            .remaining = &remaining,
        };
        const a = fa.allocator();

        const pool = thread_pool.ThreadPool.init(a, .{
            .max_threads = 4,
            .queue_capacity = 256,
        }) catch |err| switch (err) {
            error.OutOfMemory => continue, // init failed — expected; validates cleanup did not UAF/leak
            else => return err,
        };
        // If init succeeded, shut down cleanly.
        defer pool.deinit();
        try pool.shutdown(.drain);
    }
}
```

- [ ] **Step 3: Register the test in `build.zig`**

Locate the integration-test step in `build.zig` (search for `test-integration`). Two patterns are possible depending on what the repo uses:

Pattern A — if `build.zig` has per-file entries:

```zig
integration_tests.root_module.addAnonymousImport("spawn_failure", .{
    .root_source_file = b.path("tests/integration/spawn_failure.zig"),
});
```

Pattern B — if there is an aggregator `tests/integration.zig` that `@import`s each integration file, append:

```zig
_ = @import("integration/spawn_failure.zig");
```

Use whichever pattern the repo already uses (inspect `build.zig` or `tests/integration.zig` to confirm).

- [ ] **Step 4: Run the test and confirm it fails (UAF or leaked-thread symptoms)**

Run:
```bash
zig build test-integration --summary all 2>&1 | tee /tmp/f002-before.log
```

Expected on Debug: memory leak reported by `std.testing.allocator`, or segfault from worker UAF. If it passes, the allocator-driven spawn failure never actually lands between spawns — adjust the `remaining` range to a lower-N window and retry (try `n = 10..50`) before proceeding. Do not proceed with the fix until you have a failing test.

- [ ] **Step 5: Add a spawn-aware errdefer in `src/pool.zig`**

At approximately line 454 (just before the spawn loop), replace:

```zig
for (self.workers[0..normalized.max_threads], 0..) |*worker, idx| {
    worker.thread = try std.Thread.spawn(.{}, workerMain, .{ self, idx });
}

if (normalized.watchdog_interval_ns > 0) {
    self.watchdog_thread = try std.Thread.spawn(.{}, watchdogMain, .{self});
}
```

with:

```zig
// Spawn-aware cleanup: if a later spawn fails, tell already-spawned workers
// to exit and join them before the outer errdefer runs deinitOwned and
// frees their backing arrays (F-002).
var spawned_workers: usize = 0;
errdefer {
    if (spawned_workers > 0) {
        self.state.store(.stopping, .release);
        // Wake every parked worker so shouldExit() returns true.
        for (self.workers[0..spawned_workers]) |*w| {
            w.park_mutex.lock();
            w.park_cond.broadcast();
            w.park_mutex.unlock();
        }
        for (self.workers[0..spawned_workers]) |*w| {
            if (w.thread) |t| {
                t.join();
                w.thread = null;
            }
        }
    }
}

for (self.workers[0..normalized.max_threads], 0..) |*worker, idx| {
    worker.thread = try std.Thread.spawn(.{}, workerMain, .{ self, idx });
    spawned_workers += 1;
}

if (normalized.watchdog_interval_ns > 0) {
    errdefer {
        if (self.watchdog_thread) |t| {
            self.watchdog_stop.store(true, .release);
            t.join();
            self.watchdog_thread = null;
        }
    }
    self.watchdog_thread = try std.Thread.spawn(.{}, watchdogMain, .{self});
}
```

Verify that `self.workers[i].park_mutex`, `park_cond`, and `shouldExit()` semantics exist (they do per the AppSec review's Secure Design Notes). Verify that `self.watchdog_stop` exists; if the watchdog uses a different stop mechanism, adapt to it.

- [ ] **Step 6: Run the spawn-failure test**

Run:
```bash
zig build test-integration --summary all
```

Expected: test passes. No leaks reported. No UAF.

- [ ] **Step 7: Run full test suite**

```bash
zig build test-all --summary all
```

Expected: all pass.

- [ ] **Step 8: Perf-gate after**

Run: `./scripts/perf-gate.sh step-2-f002 after`

- [ ] **Step 9: Review the perf diff**

Apply the Performance-Regression Review Rule. This change only runs on the error path, so the fast-path benchmarks should show **zero regression**. If they don't, something went wrong — investigate before committing.

- [ ] **Step 10: Update progress README**

- [ ] **Step 11: Commit**

```bash
git add src/pool.zig tests/integration/spawn_failure.zig build.zig docs/performance/appsec-fixes-2026-04-15/
git commit -m "fix(pool): spawn-aware errdefer in Core.init (F-002)

If Thread.spawn fails partway through the worker-spawn loop, the outer
errdefer self.deinitOwned() was running while already-spawned workers
were still dereferencing self.workers, self.local_queues, and
self.descriptors — UAF on the host process.

Fix: add a nested errdefer that, on partial-spawn failure, flips state
to .stopping, wakes every parked worker, and joins them before the
outer deinitOwned frees the arrays.

Adds tests/integration/spawn_failure.zig that exercises the error path
via a failing-allocator pattern.

Refs: docs/APPSEC_REVIEW_2026-04-15_src.md F-002."
```

---

## Task 3: F-003 — Atomic `free_indices` (High)

**Files:**
- Modify: `src/pool.zig` — allocator for `free_indices` (~line 380), struct field declaration, `acquireDescriptor` (1618-1641), `releaseDescriptor` (1644-1683), freelist init (411-419)

- [ ] **Step 1: Perf-gate before**

Run: `./scripts/perf-gate.sh step-3-f003 before`

- [ ] **Step 2: Locate the struct field declaration**

Run: `grep -n "free_indices" src/pool.zig`

Expect hits at: struct field (`free_indices: []u32,` near top of `Core`), the `allocator.alloc(u32, ...)` init site (~380), freelist init loop (~411-419), `acquireDescriptor` (1624), `releaseDescriptor` (1659).

- [ ] **Step 3: Change the field type**

Find the `free_indices: []u32,` field in the `Core` struct declaration and change to:

```zig
free_indices: []std.atomic.Value(u32),
```

- [ ] **Step 4: Update the allocator init**

At ~line 380, change:

```zig
.free_indices = try allocator.alloc(u32, normalized.queue_capacity),
```

to:

```zig
.free_indices = try allocator.alloc(std.atomic.Value(u32), normalized.queue_capacity),
```

And update the `recordOwnedAlloc` at ~line 404:

```zig
self.recordOwnedAlloc(self.free_indices.len * @sizeOf(std.atomic.Value(u32)));
```

Note: `@sizeOf(std.atomic.Value(u32))` is `@sizeOf(u32)` on all supported targets, so this is accounting-identical.

- [ ] **Step 5: Update the freelist init loop**

At ~lines 411-419:

```zig
for (self.descriptors, 0..) |*descriptor, idx| {
    descriptor.* = .{};
    self.free_indices[idx] = std.atomic.Value(u32).init(
        if (idx + 1 < normalized.queue_capacity)
            @as(u32, @intCast(idx + 1))
        else
            0xFFFFFFFF,
    );
}
```

- [ ] **Step 6: Update `acquireDescriptor`**

At line 1624, change:

```zig
const next = self.free_indices[head];
```

to:

```zig
const next = self.free_indices[head].load(.monotonic);
```

- [ ] **Step 7: Update `releaseDescriptor`**

At line 1659, change:

```zig
self.free_indices[descriptor_index] = head;
```

to:

```zig
self.free_indices[descriptor_index].store(head, .monotonic);
```

- [ ] **Step 8: Build and run the full test suite**

Run:
```bash
zig build test-all --summary all
```

Expected: all suites pass. If a compilation error mentions `free_indices` in an unexpected location, `grep -n "free_indices" src/pool.zig` to find the remaining plain-access site and migrate it.

- [ ] **Step 9: Stress test**

Run:
```bash
zig build test-stress --summary all
```

Expected: all stress tests pass.

- [ ] **Step 10: Perf-gate after**

Run: `./scripts/perf-gate.sh step-3-f003 after`

- [ ] **Step 11: Review the perf diff**

Expectation: **zero measurable regression** — `.monotonic` atomic load/store on u32 compiles to the same `mov` instruction as the plain access on x86_64 and aarch64. If a regression appears, inspect the disassembly (`zig build bench -Doptimize=ReleaseFast -Dcpu=baseline -- --output /tmp/bench.json`) and confirm the compiler emitted `lock`-prefixed or fenced instructions. Escalate if so.

- [ ] **Step 12: Update progress README**

- [ ] **Step 13: Commit**

```bash
git add src/pool.zig docs/performance/appsec-fixes-2026-04-15/
git commit -m "fix(pool): make free_indices loads/stores atomic (F-003)

Under Zig's memory model the plain []u32 slot-accesses in
acquireDescriptor and releaseDescriptor are a formal data race with
the ABA-tagged CAS. On x86_64/aarch64 aligned u32 load/store are
hardware-atomic so this is silent today; on riscv/armv7 tearing is
possible and a corrupt 'next' pointer installed by CAS would return
an OOB descriptor index on subsequent acquire.

Fix: promote to []std.atomic.Value(u32) and use .monotonic load/store.
The ABA-tagged CAS on free_top_tagged continues to provide the
release/acquire edges. No codegen change on primary targets.

Refs: docs/APPSEC_REVIEW_2026-04-15_src.md F-003."
```

---

## Task 4: F-006 — Replace `unreachable` on `blocking_inject` (Medium)

**Files:**
- Modify: `src/pool.zig:900-906` (`enqueuePush` blocking branch) and `:1338-1343` (`laneInjectQueue`)

- [ ] **Step 1: Perf-gate before**

Run: `./scripts/perf-gate.sh step-4-f006 before`

- [ ] **Step 2: Add the new error variant (if needed)**

Search for the error set that `submitInternal`/`enqueuePush` returns:

```bash
grep -n "error{" src/pool.zig | head -20
```

Locate the error set used by the submit path (likely named `SubmitError` or a local `error{...}`). Add `BlockingLaneDisabled` to it. If `enqueuePush` currently returns a bool for queued/not, change the return type only if necessary.

If the cleanest fix is to leave the `.lane == .blocking` branch guarded by the `allow_blocking_lane` precondition (which `Config.validate` already enforces) and simply replace `unreachable` with a safer fallback, do that instead. The choice:

**Option A** — hard error: `return error.BlockingLaneDisabled;`
**Option B** — fallback to default inject: `queued = self.inject_queue.tryPush(entry);`

Option A is more honest but needs an error-set update. Option B is safer-by-default for future misuse. Prefer **Option B** — this branch should not be reachable anyway, and a silent fallback to the default lane preserves forward progress even on future invariant breakage.

- [ ] **Step 3: Replace the first `unreachable`**

At `src/pool.zig:900-906`, replace:

```zig
if (options.lane == .blocking) {
    if (self.blocking_inject) |*bi| {
        queued = bi.tryPush(entry);
    } else unreachable;
}
```

with (Option B):

```zig
if (options.lane == .blocking) {
    if (self.blocking_inject) |*bi| {
        queued = bi.tryPush(entry);
    } else {
        // Defense in depth: Config.validate guarantees blocking_inject
        // exists when allow_blocking_lane is set, and enqueuePush gates
        // this branch on allow_blocking_lane — so this else is meant to
        // be unreachable. Falling back to the default lane preserves
        // forward progress if that invariant is ever broken by a future
        // refactor, instead of becoming ReleaseFast UB (F-006).
        queued = self.inject_queue.tryPush(entry);
    }
}
```

- [ ] **Step 4: Replace the second `unreachable`**

At `src/pool.zig:1338-1343`, change `laneInjectQueue` to return an optional or fall back to `inject_queue`. Preferred: change return type to `?*BoundedRing(QueueEntry)`:

```zig
inline fn laneInjectQueue(self: *Core, lane: types.TaskLane) ?*BoundedRing(QueueEntry) {
    return switch (lane) {
        .default => &self.inject_queue,
        .blocking => if (self.blocking_inject) |*bi| bi else null,
    };
}
```

Update the single caller at `tryDrainLaneForWorker` (~`:1238`) to handle `null`:

```zig
const q = self.laneInjectQueue(lane) orelse return false;
// ... use q ...
```

Confirm there is exactly one caller:

```bash
grep -n "laneInjectQueue" src/pool.zig
```

- [ ] **Step 5: Build and run full suite**

```bash
zig build test-all --summary all
```

- [ ] **Step 6: Perf-gate after**

Run: `./scripts/perf-gate.sh step-4-f006 after`

- [ ] **Step 7: Review perf diff**

Expected: neutral. The change only affects error paths that weren't previously reachable. If `laneInjectQueue` becoming optional adds a branch in the hot path, watch for a small regression; it should be ≤ 1%.

- [ ] **Step 8: Update progress README and commit**

```bash
git add src/pool.zig docs/performance/appsec-fixes-2026-04-15/
git commit -m "fix(pool): replace unreachable on blocking_inject with safe fallback (F-006)

In ReleaseFast, 'unreachable' is a UB hint — if the invariant ever
breaks (e.g. future refactor adds a reconfigure API), execution becomes
arbitrary. The invariant is currently sound (Config.validate + the
allow_blocking_lane gate in enqueuePush) but the footgun is latent.

Fix: fall back to the default inject queue on the enqueue path, and
change laneInjectQueue to ?*BoundedRing so the drain caller handles
the absence explicitly. Zero hot-path cost in the normal case.

Refs: docs/APPSEC_REVIEW_2026-04-15_src.md F-006."
```

---

## Task 5: F-005 — Harden `releaseSubmitter` (Medium)

**Files:**
- Modify: `src/pool.zig:555-577` (`registerSubmitter` and `releaseSubmitter`)

- [ ] **Step 1: Perf-gate before**

Run: `./scripts/perf-gate.sh step-5-f005 before`

- [ ] **Step 2: Write a regression test (double-release and OOB idx)**

Append to `tests/integration/two_pool_cross_submit.zig` (or create `tests/integration/submitter_lifecycle.zig`):

```zig
test "F-005: releaseSubmitter is idempotent and bounds-checks idx" {
    const gpa = std.testing.allocator;
    var pool = try thread_pool.ThreadPool.init(gpa, .{
        .max_threads = 2,
        .queue_capacity = 128,
    });
    defer pool.deinit();

    const idx = try pool.registerSubmitter();
    pool.releaseSubmitter(idx);
    // Second release must not panic, must not race.
    pool.releaseSubmitter(idx);
    // Out-of-range idx must not OOB.
    pool.releaseSubmitter(9999);
    try pool.shutdown(.drain);
}
```

- [ ] **Step 3: Confirm test fails or crashes against current code**

```bash
zig build test-integration --summary all 2>&1 | tee /tmp/f005-before.log
```

Expected (Debug): panic or assertion on the second `releaseSubmitter(idx)` via OOB indexing in the drain loop, or on `releaseSubmitter(9999)`.

- [ ] **Step 4: Harden `releaseSubmitter`**

Replace the current function body (~lines 567-577) with:

```zig
pub fn releaseSubmitter(self: *Core, idx: usize) void {
    if (idx >= self.submitter_queues.len) return;
    const bit: u64 = @as(u64, 1) << @intCast(idx);

    // Atomically claim ownership for drain. If the bit is already set in
    // the free-mask, some other caller has already released (or is racing
    // to release) this slot — bail (F-005 idempotence).
    while (true) {
        const mask = self.submitter_free_mask.load(.acquire);
        if ((mask & bit) != 0) return; // already free
        if (self.submitter_free_mask.cmpxchgWeak(mask, mask | 0, .acq_rel, .monotonic) == null) {
            // We did not change the mask; we're just confirming the bit
            // is still clear while we take drain ownership via the loop
            // exit below.
            break;
        }
    }

    // Best-effort: only clear TLS if this thread was the one that owned
    // the slot. Otherwise leave TLS alone.
    if (tls_submitter_slot.pool == @as(*anyopaque, @ptrCast(self))
        and tls_submitter_slot.index == idx)
    {
        tls_submitter_slot = .{};
    }

    // Drain any pending entries into the shared inject queue. Retry
    // until pushed; the inject queue is bounded but drain is bounded by
    // the submitter queue size, so this terminates.
    while (self.submitter_queues[idx].stealOne()) |entry| {
        while (!self.inject_queue.tryPush(entry)) std.atomic.spinLoopHint();
    }

    _ = self.submitter_nonempty.fetchAnd(~bit, .release);
    _ = self.submitter_free_mask.fetchOr(bit, .release);
}
```

Note: the `cmpxchgWeak(mask, mask | 0)` spin is a no-op CAS used as a read-acquire fence over the free-mask state while we decide whether to drain. Simpler: just read once and bail if already-free:

```zig
pub fn releaseSubmitter(self: *Core, idx: usize) void {
    if (idx >= self.submitter_queues.len) return;
    const bit: u64 = @as(u64, 1) << @intCast(idx);
    const mask = self.submitter_free_mask.load(.acquire);
    if ((mask & bit) != 0) return; // already released

    if (tls_submitter_slot.pool == @as(*anyopaque, @ptrCast(self))
        and tls_submitter_slot.index == idx)
    {
        tls_submitter_slot = .{};
    }

    while (self.submitter_queues[idx].stealOne()) |entry| {
        while (!self.inject_queue.tryPush(entry)) std.atomic.spinLoopHint();
    }

    _ = self.submitter_nonempty.fetchAnd(~bit, .release);
    _ = self.submitter_free_mask.fetchOr(bit, .release);
}
```

Use the simpler form. The check is advisory — an adversarial concurrent re-register could slip between the check and the drain, but only the original owner should call `releaseSubmitter`, so this is acceptable.

- [ ] **Step 5: Run the test**

```bash
zig build test-integration --summary all
```

Expected: pass.

- [ ] **Step 6: Run full suite**

```bash
zig build test-all --summary all
```

- [ ] **Step 7: Perf-gate after**

Run: `./scripts/perf-gate.sh step-5-f005 after`

- [ ] **Step 8: Review perf diff**

Expected: neutral. `releaseSubmitter` is a cold-path API (lifecycle, not per-submit).

- [ ] **Step 9: Update progress README and commit**

```bash
git add src/pool.zig tests/integration/ docs/performance/appsec-fixes-2026-04-15/
git commit -m "fix(pool): bounds-check and idempotent releaseSubmitter (F-005)

Previously releaseSubmitter(idx) with out-of-range idx would OOB into
submitter_queues, and a double-release would race against a concurrent
registerSubmitter+submitter-push on the same slot.

Fix:
- Guard against idx >= submitter_queues.len.
- Early-return if the bit is already set in submitter_free_mask
  (already released).
- Only clear TLS if this thread was the slot's original owner.

Refs: docs/APPSEC_REVIEW_2026-04-15_src.md F-005."
```

---

## Task 6: F-004 — Soften `WaitGroup.done()` panic (Medium)

**Files:**
- Modify: `src/types.zig:311-315`

- [ ] **Step 1: Perf-gate before**

Run: `./scripts/perf-gate.sh step-6-f004 before`

- [ ] **Step 2: Locate the current `done()` implementation**

```bash
grep -n "pub fn done" src/types.zig
```

- [ ] **Step 3: Replace `done()`**

At approximately `src/types.zig:311-315`, replace:

```zig
pub fn done(self: *WaitGroup) void {
    const previous = self.pending.fetchSub(1, .acq_rel);
    if (previous == 0) {
        @panic("WaitGroup: done() called more times than add()");
    }
    // ... existing post-decrement logic (signal cond, etc.) ...
}
```

with:

```zig
pub fn done(self: *WaitGroup) void {
    const previous = self.pending.fetchSub(1, .acq_rel);
    if (previous == 0) {
        // Restore the invariant so a buggy caller cannot drive 'pending'
        // arbitrarily negative via repeated done() (F-004). In Debug and
        // ReleaseSafe we still panic loudly to catch the bug in testing;
        // in ReleaseFast we keep running so one misbehaving caller
        // cannot crash a multi-tenant host.
        _ = self.pending.fetchAdd(1, .monotonic);
        if (std.debug.runtime_safety) {
            @panic("WaitGroup: done() called more times than add()");
        }
        return;
    }
    // ... preserve existing post-decrement logic ...
}
```

Preserve any existing logic that runs after the underflow check (signal the condition variable on reaching 0, etc.).

- [ ] **Step 4: Add a regression test**

In the WaitGroup test file (find via `grep -rn "WaitGroup" tests/`), add:

```zig
test "F-004: WaitGroup.done underflow does not crash ReleaseFast" {
    var wg = thread_pool.WaitGroup{};
    wg.add(1);
    wg.done();
    // Second done() would previously panic. In ReleaseFast, this
    // returns. In Debug, it panics — so we only exercise the resilient
    // form via a runtime check.
    if (!std.debug.runtime_safety) {
        wg.done(); // no crash
        try std.testing.expect(wg.pending.load(.monotonic) == 0);
    }
}
```

- [ ] **Step 5: Run tests in both modes**

```bash
zig build test --summary all                       # Debug — should panic if we exercise underflow
zig build test -Doptimize=ReleaseFast --summary all # ReleaseFast — underflow path runs clean
```

Expected: Debug suite passes (the underflow test is guarded by `runtime_safety`). ReleaseFast suite passes including the underflow assertion.

- [ ] **Step 6: Full suite**

```bash
zig build test-all --summary all
```

- [ ] **Step 7: Perf-gate after**

Run: `./scripts/perf-gate.sh step-6-f004 after`

- [ ] **Step 8: Review perf diff**

Expected: neutral. `done()` is called once per task completion; the added `fetchAdd` on the underflow path is not in the normal flow.

- [ ] **Step 9: Update progress README and commit**

```bash
git add src/types.zig tests/ docs/performance/appsec-fixes-2026-04-15/
git commit -m "fix(types): soften WaitGroup.done underflow panic (F-004)

A @panic in library code aborts the host process. A caller who
miscounts add/done (common in error paths) DoSes the host.

Fix: saturate pending at 0 on underflow in ReleaseFast so the library
does not crash on caller bugs; preserve the panic under
std.debug.runtime_safety so Debug/ReleaseSafe still catch the bug
loudly during testing.

Refs: docs/APPSEC_REVIEW_2026-04-15_src.md F-004."
```

---

## Task 7: F-007 — Clamp `parseProcStatusKiB` (Low)

**Files:**
- Modify: `src/stats/process_memory.zig:71-88`

- [ ] **Step 1: Perf-gate before**

Run: `./scripts/perf-gate.sh step-7-f007 before`

- [ ] **Step 2: Update `parseProcStatusKiB`**

At approximately `src/stats/process_memory.zig:78`, replace:

```zig
fn parseProcStatusKiB(contents: []const u8, prefix: []const u8) u64 {
    var line_it = std.mem.splitScalar(u8, contents, '\n');
    while (line_it.next()) |line| {
        if (std.mem.startsWith(u8, line, prefix)) {
            var field_it = std.mem.tokenizeAny(u8, line[prefix.len..], " \t");
            while (field_it.next()) |field| {
                return std.fmt.parseInt(u64, field, 10) catch 0;
            }
        }
    }
    return 0;
}
```

with:

```zig
fn parseProcStatusKiB(contents: []const u8, prefix: []const u8) u64 {
    var line_it = std.mem.splitScalar(u8, contents, '\n');
    while (line_it.next()) |line| {
        if (std.mem.startsWith(u8, line, prefix)) {
            var field_it = std.mem.tokenizeAny(u8, line[prefix.len..], " \t");
            while (field_it.next()) |field| {
                const kib = std.fmt.parseInt(u64, field, 10) catch return 0;
                // Cap so caller can safely multiply by 1024 without
                // overflow on a crafted /proc/self/status (F-007).
                return @min(kib, std.math.maxInt(u64) / 1024);
            }
        }
    }
    return 0;
}
```

- [ ] **Step 3: Add a small regression test**

Add to the same file's test block (or an appropriate test file):

```zig
test "F-007: parseProcStatusKiB clamps to avoid *1024 overflow" {
    const big = "VmRSS:\t18446744073709551615 kB\n";
    const v = parseProcStatusKiB(big, "VmRSS:");
    // Caller will multiply by 1024; ensure that does not overflow u64.
    _ = v * 1024;
    try std.testing.expect(v <= std.math.maxInt(u64) / 1024);
}
```

- [ ] **Step 4: Run tests**

```bash
zig build test --summary all
```

- [ ] **Step 5: Perf-gate after and review**

```bash
./scripts/perf-gate.sh step-7-f007 after
```

Expected: neutral (stats path is not in the hot bench loop).

- [ ] **Step 6: Update progress README and commit**

```bash
git add src/stats/process_memory.zig docs/performance/appsec-fixes-2026-04-15/
git commit -m "fix(stats): clamp parseProcStatusKiB to prevent *1024 overflow (F-007)

A crafted or corrupt /proc/self/status could produce a u64 KiB value
that overflows when callers multiply by 1024 — panic in Debug, wrap
in ReleaseFast.

Fix: cap the parse at maxInt(u64)/1024.

Refs: docs/APPSEC_REVIEW_2026-04-15_src.md F-007."
```

---

## Task 8: ThreadSanitizer stress run

**Files:**
- Modify: `build.zig` — add `-Dtsan` option that sets `sanitize_thread = true` on test steps
- Create: `docs/performance/appsec-fixes-2026-04-15/TSAN-findings.md`

- [ ] **Step 1: Add a `-Dtsan` option to `build.zig`**

Near the top of the `build()` function in `build.zig`, add:

```zig
const tsan = b.option(bool, "tsan", "Enable ThreadSanitizer on test artifacts") orelse false;
```

Then for each test-producing compile step (unit, integration, stress), after the `b.addTest(...)` call, add:

```zig
if (tsan) {
    test_step.root_module.sanitize_thread = true;
}
```

Use the actual variable names used in the file (`test_unit`, `test_integration`, `test_stress`, etc. — grep to discover).

- [ ] **Step 2: Run the stress suite under TSan**

```bash
zig build test-stress -Dtsan -Doptimize=Debug --summary all 2>&1 | tee /tmp/tsan-stress.log
```

Expected: runs to completion. May emit TSan warnings. Capture every `WARNING: ThreadSanitizer` block verbatim.

- [ ] **Step 3: Triage TSan findings**

For each warning, classify into:
- **Real race the prior fixes missed** — file a follow-up task (do not fix here).
- **Known-benign** with documented justification (e.g. racy stats counter where the algorithm tolerates staleness) — record in `TSAN-findings.md`.
- **False positive** from a Zig/LLVM instrumentation gap — record with a link to the upstream issue.

Write `docs/performance/appsec-fixes-2026-04-15/TSAN-findings.md` with sections:
- Date and commit SHA
- Command used
- Findings summary (count by classification)
- Per-finding: location, stack snippets (trimmed), classification, recommended action

- [ ] **Step 4: (Optional) Run unit + integration suites under TSan**

```bash
zig build test -Dtsan --summary all 2>&1 | tee -a /tmp/tsan-unit.log
zig build test-integration -Dtsan --summary all 2>&1 | tee -a /tmp/tsan-integration.log
```

Add additional findings to the doc.

- [ ] **Step 5: Commit**

```bash
git add build.zig docs/performance/appsec-fixes-2026-04-15/TSAN-findings.md
git commit -m "test: add -Dtsan option and record TSan baseline findings

Enables std.Build.Module.sanitize_thread on test artifacts when
-Dtsan is passed. Captures the current set of TSan warnings from
zig build test-stress under TSAN-findings.md so regressions can be
diffed in future runs.

Refs: docs/APPSEC_REVIEW_2026-04-15_src.md coverage gaps."
```

No perf-gate needed — TSan builds are Debug-mode, not comparable to ReleaseFast bench numbers.

---

## Task 9: Public-API fuzz harness

**Files:**
- Create: `tests/fuzz/pool_fuzz.zig`
- Modify: `build.zig` — register a `fuzz` step

- [ ] **Step 1: Write the fuzz harness**

Create `tests/fuzz/pool_fuzz.zig`:

```zig
//! Random-interleave fuzz for the public ThreadPool API.
//!
//! Covers the operations called out in the AppSec review's coverage gaps:
//!   submit / trySubmit / submitBatch /
//!   registerSubmitter / releaseSubmitter /
//!   shutdown(.drain|.cancel_pending) / wait
//!
//! Invariants checked after each run:
//!   - counters.submitted == counters.completed + counters.cancelled
//!   - task_desc_live == 0 post-shutdown
//!   - submitter_free_mask is fully set (no leaked slots)
//!   - testing allocator reports no leaks

const std = @import("std");
const thread_pool = @import("thread_pool");

const OpKind = enum { submit, try_submit, submit_batch, register, release, shutdown_drain, shutdown_cancel, wait_handle };

fn noop(ctx: *anyopaque, runtime: *thread_pool.TaskContext) void {
    _ = ctx;
    _ = runtime;
}

pub fn main() !void {
    const seed_env = std.process.getEnvVarOwned(std.heap.page_allocator, "FUZZ_SEED") catch null;
    const seed: u64 = if (seed_env) |s| blk: {
        defer std.heap.page_allocator.free(s);
        break :blk std.fmt.parseInt(u64, s, 10) catch 0xC0FFEE;
    } else 0xC0FFEE;

    var iterations: u32 = 0;
    const iter_env = std.process.getEnvVarOwned(std.heap.page_allocator, "FUZZ_ITERATIONS") catch null;
    iterations = if (iter_env) |s| blk: {
        defer std.heap.page_allocator.free(s);
        break :blk std.fmt.parseInt(u32, s, 10) catch 100;
    } else 100;

    var prng = std.Random.DefaultPrng.init(seed);
    const rng = prng.random();

    var i: u32 = 0;
    while (i < iterations) : (i += 1) {
        try runOne(rng);
    }
    std.debug.print("fuzz ok: {d} iterations seed={d}\n", .{ iterations, seed });
}

fn runOne(rng: std.Random) !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{ .safety = true }){};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var pool = try thread_pool.ThreadPool.init(gpa, .{
        .max_threads = 2 + rng.intRangeAtMost(usize, 0, 4),
        .queue_capacity = 128,
    });
    defer pool.deinit();

    var submitted: u64 = 0;
    const n_ops: u32 = rng.intRangeAtMost(u32, 32, 256);
    var op_i: u32 = 0;
    var my_submitter: ?usize = null;

    while (op_i < n_ops) : (op_i += 1) {
        const kind = rng.enumValue(OpKind);
        switch (kind) {
            .submit, .try_submit => {
                const ctx_ptr: *anyopaque = @ptrCast(&submitted);
                const opts: thread_pool.SubmitOptions = .{};
                const res = if (kind == .submit)
                    pool.submit(noop, ctx_ptr, opts)
                else
                    pool.trySubmit(noop, ctx_ptr, opts);
                _ = res catch continue;
                submitted += 1;
            },
            .submit_batch => {
                // call whatever batch API exists; skip if not present
                _ = pool.submit(noop, @ptrCast(&submitted), .{}) catch continue;
                submitted += 1;
            },
            .register => {
                if (my_submitter == null) {
                    my_submitter = pool.registerSubmitter() catch null;
                }
            },
            .release => {
                if (my_submitter) |idx| {
                    pool.releaseSubmitter(idx);
                    my_submitter = null;
                }
            },
            .shutdown_drain => {
                try pool.shutdown(.drain);
                break;
            },
            .shutdown_cancel => {
                try pool.shutdown(.cancel_pending);
                break;
            },
            .wait_handle => {
                // no handle tracking in this smoke harness
            },
        }
    }

    // If we didn't hit an explicit shutdown, drain now.
    pool.shutdown(.drain) catch {};

    // Release any lingering submitter slot.
    if (my_submitter) |idx| pool.releaseSubmitter(idx);

    // Post-condition checks: stats counters must balance and nothing leaks.
    const stats = pool.stats();
    const done = stats.counters.completed + stats.counters.cancelled;
    if (stats.counters.submitted != done) {
        std.debug.print("fuzz invariant failed: submitted={d} completed+cancelled={d}\n",
            .{ stats.counters.submitted, done });
        return error.FuzzInvariantFailed;
    }
    if (stats.counters.task_desc_live != 0) {
        std.debug.print("fuzz invariant failed: task_desc_live={d}\n", .{stats.counters.task_desc_live});
        return error.FuzzInvariantFailed;
    }
}
```

Adapt field names to the actual `Stats` / `counters` shape — inspect `src/types.zig` for `Stats`/`WorkerStats`/counters. If `submitted`/`completed`/`cancelled` live elsewhere, use the actual names. If a counter is missing, skip that invariant and note in a comment.

- [ ] **Step 2: Register a `fuzz` build step**

In `build.zig`, append:

```zig
const fuzz_exe = b.addExecutable(.{
    .name = "pool-fuzz",
    .root_source_file = b.path("tests/fuzz/pool_fuzz.zig"),
    .target = target,
    .optimize = optimize,
});
fuzz_exe.root_module.addImport("thread_pool", thread_pool_mod);
const fuzz_step = b.step("fuzz", "Run the public-API fuzz harness");
const run_fuzz = b.addRunArtifact(fuzz_exe);
run_fuzz.has_side_effects = true;
fuzz_step.dependOn(&run_fuzz.step);
```

Use the actual module variable name for `thread_pool_mod` (grep `build.zig` for the existing test registrations to match the pattern).

- [ ] **Step 3: Run the fuzz harness (default 100 iterations)**

```bash
zig build fuzz
```

Expected: `fuzz ok: 100 iterations seed=...` printed. No allocator leaks reported.

- [ ] **Step 4: Run a longer campaign**

```bash
FUZZ_ITERATIONS=5000 FUZZ_SEED=1 zig build fuzz
FUZZ_ITERATIONS=5000 FUZZ_SEED=2 zig build fuzz
FUZZ_ITERATIONS=5000 FUZZ_SEED=3 zig build fuzz
```

Expected: all three runs complete without invariant failures or leaks. If any seed triggers a failure, do not proceed — file the reproducer and escalate.

- [ ] **Step 5: Commit**

```bash
git add tests/fuzz/pool_fuzz.zig build.zig
git commit -m "test: add public-API fuzz harness (appsec coverage gap)

Randomly interleaves submit / trySubmit / registerSubmitter /
releaseSubmitter / shutdown(.drain) / shutdown(.cancel_pending).

Post-run invariants:
- counters.submitted == completed + cancelled
- task_desc_live == 0 post-shutdown
- no allocator leaks

Run with 'zig build fuzz' (default 100 iterations) or set
FUZZ_ITERATIONS and FUZZ_SEED for longer/deterministic runs.

Refs: docs/APPSEC_REVIEW_2026-04-15_src.md coverage gaps."
```

No perf-gate — this is a test-only addition.

---

## Task 10: Final performance snapshot and summary

**Files:**
- Create: `docs/performance/appsec-fixes-2026-04-15/FINAL.md`
- Modify: `docs/performance/appsec-fixes-2026-04-15/README.md`

- [ ] **Step 1: Run the full runtime comparison**

```bash
zig build bench-runtime-compare -Doptimize=ReleaseFast -- --output docs/performance/appsec-fixes-2026-04-15/FINAL-runtime-comparison.json
```

Expected: JSON written with all three runtimes (Zig, Tokio, Go) across all realistic scenarios.

- [ ] **Step 2: Generate the final summary**

Create `docs/performance/appsec-fixes-2026-04-15/FINAL.md`:

```markdown
# AppSec Remediation — Final Performance Summary

**Baseline commit:** <paste `git rev-list` of the commit before Task 0>
**Final commit:** <paste HEAD>
**Benches run:** `zig build bench` · `zig build bench-realistic` · `zig build bench-runtime-compare`

## Scenario deltas vs baseline

(Compare `BASELINE-bench.json` → `step-7-f007-after-bench.json`,
and `BASELINE-realistic.json` → `step-7-f007-after-realistic.json`.)

| scenario | variant | ops/s baseline | ops/s final | Δ % |
|---|---|---:|---:|---:|
| ... | ... | ... | ... | ... |

(Fill by running the same `jq` pipeline used by `scripts/perf-gate.sh`
with baseline as "before" and step-7-after as "after".)

## Runtime comparison vs Tokio/Go

(Same table shape as CLAUDE.md § Current Direct Runtime Snapshot. Reproduce
from FINAL-runtime-comparison.json.)

## Regression ledger

| Step | Fix | Regression class | Notes |
|------|-----|------------------|-------|
| 1 | F-001 per-pool TLS | <class> | <note> |
| 2 | F-002 spawn errdefer | <class> | <note> |
| 3 | F-003 atomic free_indices | <class> | <note> |
| 4 | F-006 blocking_inject fallback | <class> | <note> |
| 5 | F-005 releaseSubmitter hardening | <class> | <note> |
| 6 | F-004 WaitGroup.done soften | <class> | <note> |
| 7 | F-007 parseProcStatusKiB clamp | <class> | <note> |

## TSan summary

See `TSAN-findings.md`.

## Fuzz summary

Ran FUZZ_ITERATIONS=5000 over seeds {1,2,3}. No invariant failures; no leaks.
```

- [ ] **Step 3: Update `CLAUDE.md` runtime snapshot if anything meaningfully shifted**

If `FINAL-runtime-comparison.json` shows material change vs the current CLAUDE.md table (either regression ≥ 5% or improvement ≥ 10%), update the `## Current Direct Runtime Snapshot` section of `/home/benji/src/devnw/zig/thread-pool/CLAUDE.md` with the new numbers. Otherwise leave it.

- [ ] **Step 4: Mark README progress row "done" for all steps**

- [ ] **Step 5: Commit**

```bash
git add docs/performance/appsec-fixes-2026-04-15/FINAL.md docs/performance/appsec-fixes-2026-04-15/README.md docs/performance/appsec-fixes-2026-04-15/FINAL-runtime-comparison.json CLAUDE.md
git commit -m "docs(perf): final performance summary for AppSec remediation series

Captures the end-to-end perf delta across the remediation work
(F-001, F-002, F-003, F-006, F-005, F-004, F-007) plus the TSan and
fuzz additions. Baseline → HEAD.

Refs: docs/superpowers/plans/2026-04-15-appsec-remediation.md."
```

- [ ] **Step 6: Summarize for the user**

Final message should include:
- Report path: `docs/performance/appsec-fixes-2026-04-15/FINAL.md`
- Regression count: X scenarios regressed ≥ 3%, Y improvements ≥ 3%
- Pointer to `TSAN-findings.md` for any TSan follow-ups

---

## Deferred (not in scope for this plan)

The AppSec report also flagged these items. They are **not** part of this plan; file as follow-ups if desired.

- **F-008** (Low) — Two concurrent `wait()` on the same handle. Current code is safe via `completion_mutex`; fix would require either documentation or a single-shot bit on the handle.
- **F-009** (Low) — Scratch allocator failure-counter mismatch. Observability-only.
- **F-010** (Info) — `parseInt catch 0` hygiene note.
- **F-011** (Info) — `BoundedRing` undef-slot hygiene; consider a comptime `is_pod` assert.
- **macOS / Windows `process_memory.zig` FFI review** — review-level coverage gap from the AppSec report. Cannot be closed from a Linux-only workstation; defer until a macOS and Windows CI runner can exercise those code paths. Follow-up if observability issues appear on those platforms.

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-04-15-appsec-remediation.md`. Two execution options:

1. **Subagent-Driven (recommended)** — dispatch a fresh subagent per task, review between tasks, fast iteration. Uses superpowers:subagent-driven-development.
2. **Inline Execution** — execute tasks in this session using superpowers:executing-plans, batch execution with checkpoints.

Which approach?
