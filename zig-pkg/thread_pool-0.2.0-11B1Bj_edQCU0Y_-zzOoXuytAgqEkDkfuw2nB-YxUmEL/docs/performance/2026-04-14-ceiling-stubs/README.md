# 2026-04-14 — Ceiling A/Bs for profile targets #1 and #2

Follow-up to `docs/performance/2026-04-14-post-revert-profile/README.md`.
The profile identified two structural hotspots burning ~30% of worker
cycles. Per the profile doc's own guidance ("before any code change,
A/B-disable the target"), both were stubbed out and measured against
baseline `5da9962` to establish the theoretical ceiling on flood_1m.

**Headline result:** both ceilings are small enough that neither target
is worth pursuing. The benchmark is memory-bound; freeing the cycles
measured by `perf record` does not translate to throughput gains.

## Environment

- Host: 2× Xeon E5-2680 v4, 56 logical cores, schedutil, paranoid=0
- Uptime at start of pair 1: ~4h 15m, load avg 0.3-0.6
- Uptime at end of pair 2: ~4h 17m, load avg 6.6 (self-load from back-to-back
  runs; paired balanced-order mitigates this)
- Binary: ReleaseFast, debug info preserved
- Method: balanced-order alternation, n=10 per variant per pair

## Pair 1 — Target #1 ceiling: skip steal-loop entirely

### Stub

`src/pool.zig:707-743` — replaced the full 36-line steal-scan (pseudo-
random start, 55-victim scan, `len()` peek, `steal()` call, local push-
back) with an unconditional `steal_failures++; return null`. Workers
that hit empty local + empty inject queue now immediately fall through
to the park path.

Effect on flood_1m: the scheduler loses steal-based load redistribution,
but the submitter still drives 1M tasks through `inject_queue`; each
worker drains its share via `inject_queue.pop()` in `nextTask`. The
10.75%-of-cycles coherence storm on `LocalQueue.len()` reads is
eliminated.

### Results

| Scenario | BASE median | NOSTEAL median | Δ | Distribution overlap? |
|----------|------------:|---------------:|---:|:---|
| flood_1m | 386,146 | 405,440 | **+5.0%** | Yes — NOSTEAL min 374,629 < BASE max 465,064 |
| contended_spawn_8x | 582,222 | 615,723 | **+5.8%** | Yes — NOSTEAL min 549,965 < BASE max 609,601 |

Full distributions (n=10 each):

```text
flood_1m BASE:    min=358647  median=386146  max=465064  mean=394770
flood_1m NOSTEAL: min=374629  median=405440  max=443981  mean=405860
contended   BASE: min=541258  median=582222  max=609601  mean=579777
contended NOSTEAL:min=549965  median=615723  max=672579  mean=618974
```

### Interpretation

Target #1's theoretical ceiling on flood_1m is ~5% median delta, with
heavy distribution overlap. By this project's measurement rules (rule 3:
distribution-overlap is the correctness bar), this is **not a decisive
win** — the delta is within the 15-20% flood_1m noise floor.

The 10.75% of cycles that the profile attributed to `LocalQueue.len()`
acquire-load storm does not translate to 10% throughput: the benchmark
is memory-bound (0.35 IPC, 38.89% L1 miss per the post-revert profile),
so reclaiming worker CPU cycles only helps up to the point where the
coherence traffic itself decreases. The stub removes both the CPU cycles
AND the cacheline bouncing, and still only buys ~5%.

**Important caveat:** the NOSTEAL stub is not a pure "cheap peek"
optimization — it eliminates the entire steal subsystem, including the
actual steal work that would legitimately help when inject_queue is
drained but some worker still has local work. For flood_1m and
contended_spawn_8x, the submitter-driven inject-queue path dominates, so
losing steals is cheap. In yield-heavy or spawn-chain workloads the loss
would matter more. Any real optimization targeting `len()` coherence must
preserve the actual `steal()` call — likely via a sharded parked-worker
bitmap or age-limited victim cache — and can only hope to capture a
fraction of the 5% stub-ceiling.

### Conclusion for target #1

Not worth pursuing. Any steal-scan optimization that preserves correctness
will capture less than the 5% ceiling, overlap will stay heavy, and the
prior Phase-G/F attempts that touched steal infrastructure all regressed
(per `feedback_measurement_rules` memory and the wake-scan-gate,
option3-worker-local-incoming-abandoned audit trails).

## Pair 2 — Target #2 ceiling: replace TaskState CAS with non-atomic load+store

### Stub

`src/pool.zig:773-776` — replaced the `descriptor.state.cmpxchgStrong(
.queued, .running, .acq_rel, .acquire)` with a plain `state.load(
.acquire)` followed by a `state.store(.running, .release)` on match.
Removes the lock-prefixed CMPXCHG atomic RMW (the 18.91% worker-cycles
hotspot).

**Safety:** this stub is race-vulnerable. Two workers can both observe
`state == .queued` and both proceed to execute the task body + decrement
queued_tasks. That's exactly what Phase H's CAS prevents.

### Results

The benchmark panicked with `WaitGroup: done() called more times than
add()` on the second NOCAS flood_1m iteration — the double-dispatch race
materialized immediately. 19 of 20 runs completed (the crashed iteration
is missing NOCAS's pair). Usable data:

| Scenario | BASE median | NOCAS median | Δ | Distribution overlap? |
|----------|------------:|-------------:|---:|:---|
| flood_1m | 389,774 | 397,682 | **+2.0%** | Yes — heavy overlap |
| contended_spawn_8x | 556,673 | 592,601 | +6.4% | Yes — NOCAS min 515,306 < BASE max 577,937 |

Full distributions:

```text
flood_1m BASE:   n=10 min=365030 median=389774 max=545221 mean=401239
flood_1m NOCAS:  n=9  min=346143 median=397682 max=407251 mean=384206
contended BASE:  n=10 min=506677 median=556673 max=577937 mean=549395
contended NOCAS: n=9  min=515306 median=592601 max=612048 mean=583283
```

### Interpretation

The flood_1m median moves +2%, well inside noise. The CAS is 18.91% of
worker cycles, yet eliminating the RMW produces essentially no throughput
gain.

Why: the 18.91% figure is "cold-line read-for-ownership + atomic RMW",
and the stub still pays the cold-line fetch. An `atomic.load(.acquire)`
on a cacheline the submitter just wrote still requires fetching the line
into the worker's L1 (shared, not exclusive). The subsequent
`store(.release)` still requires the line exclusive. The lock-prefix
itself is a small fraction of the total cost; the cacheline transit is
the dominant cost, and the stub does not avoid it.

The contended_spawn_8x +6.4% with BASE/NOCAS distribution overlap is
noise-dominated; cannot be read as a win. With the missing 10th NOCAS
data point, the n=9 sample is also less statistically robust.

### Conclusion for target #2

Not worth pursuing. The real cost of `TaskState.cmpxchgStrong` is the
cacheline coherence cost, which any state-transition mechanism must pay.
Alternative designs (e.g., packing state into the queue slot CAS, so the
state bit is co-located with the pop acquire) would require fundamental
restructuring and were flagged in the profile doc as "needs full
brainstorm" — this A/B shows the brainstorm effort would pay off at
most ~2% on flood_1m even if the entire state transition were free.

## Overall conclusion

Per the profile doc's own stop-condition:

> "If both ceilings are small (<5%), stop chasing flood_1m. The current
> 380-400K ops/s may be the architectural ceiling on this machine for
> this submit model, and further Tokio-parity gains require a different
> benchmark (yield-heavy, spawn-chain) or a different submit API
> (batched submit)."

Both ceilings are at-or-below 5% on flood_1m. **Stop chasing flood_1m
micro-optimizations on the current single-submitter model.** Productive
directions from here:

1. **Batched submit API.** Add `submitBatch(tasks: []const Task)` that
   pushes N tasks with a single inject_queue head-CAS cycle, amortizing
   per-submit atomic cost. flood_1m would need a bench variant that uses
   it; steady-state throughput should scale with batch size up to
   `inject_batch_size`.
2. **Yield-heavy / spawn-chain benchmark scenarios.** The current
   `tokio_parity` suite covers only pure-throughput and multi-producer-
   contention. Tokio's yield_now() and chained-spawn benches measure
   reschedule latency and nested-submit throughput — different bottlenecks
   that may have more headroom.
3. **Accept the current throughput as the architectural ceiling and
   redirect effort.** Correctness, observability, diagnostics, or a
   first-class continuation/callback API (which would unblock the
   missing Tokio bench variants) may produce more user-visible value per
   engineering-hour than squeezing the remaining throughput.

The profile doc's target #3 (sentinel dispatch) was already ruled out
in-session. With #1 and #2 now also ruled out, the flood_1m-focused
optimization track is closed.

## Correctness / stress validation

Stubs are intentionally broken builds; no stress gate run. Baseline
`5da9962` has its own passing 20× stress gate documented in the sentinel-
revert commit message.

Stub files are discarded (worktrees removed via `git worktree remove
--force`). Only this audit trail remains.
