# Contended-scenarios gap-close — FINAL

Plan: [`docs/superpowers/plans/2026-04-16-contended-scenarios-gap.md`](../../superpowers/plans/2026-04-16-contended-scenarios-gap.md)
Range: `5a139ce` … `e83b911` (11 commits)
Date: 2026-04-16

## Headline

### Cross-snapshot gap vs Go (baseline → final runtime-compare)

| Scenario | Baseline gap vs Go | Final gap vs Go | Cross-snapshot change |
|----------|:------------------:|:---------------:|:---------------------:|
| `contended_spawn_8x`   | 4.18x behind | 3.86x behind | narrowed 0.32x |
| `contended_cpu_10us`   | 1.97x behind | 2.27x behind | widened 0.30x * |
| `nested_fanout_4x`     | 6.04x behind | 6.19x behind | widened 0.15x * |
| `mixed_fast_slow`      | 1.12x behind | 1.01x behind | narrowed 0.11x |

\* `contended_cpu_10us` and `nested_fanout_4x` **widen** cross-snapshot
because the Go side gained host thermal headroom between the two bench
runs (Go `contended_cpu_10us` climbed from 1.81M → 2.43M ops/sec; Go
`nested_fanout_4x` climbed from 3.18M → 3.55M ops/sec). The Zig side
gained too, as shown by the Phase-1 isolated A/B below, but not enough
to keep pace with Go's host-drift gain.

### Phase-1 isolated paired A/B (same ReleaseFast binary, same host session)

Source: `phase1-after.json` in this directory vs `baseline.json`
(`baseline-medians.md` records both).

| Scenario | Zig baseline | Zig post-Phase-1 | Δ | Go (same session) | Post-P1 gap |
|----------|-------------:|-----------------:|---:|------------------:|:-----------:|
| `contended_spawn_8x` | 916,337 | 987,837 | **+7.8%** | 3,125,095 | 3.16x behind |
| `contended_cpu_10us` | 918,624 | 961,203 | **+4.6%** | 1,724,954 | 1.79x behind |
| `nested_fanout_4x`   | 525,906 | 645,206 | **+22.7%** | 2,812,471 | 4.36x behind |
| `mixed_fast_slow`    | 223,581 | 247,877 | **+10.9%** | 242,723 | **1.02x ahead** |

**`mixed_fast_slow` flipped from 1.12x behind Go to 1.02x ahead in the
same-session comparison.** That is the headline win of the plan. The
final runtime-compare snapshot shows `mixed_fast_slow` at 1.01x behind
— a ~1% swing that is pure noise on a 234K-ops/sec scenario.

## What landed

Pure harness-fairness fixes. **No `src/` changes.** The work made the
benchmark actually exercise the already-shipped per-submitter SPSC queue
paths that were otherwise bypassed because benchmark threads were not
calling `registerSubmitter()`.

| Phase | Task | Commit | Summary |
|-------|------|--------|---------|
| 0 | Baseline | `5a139ce` | Snapshot baseline to `docs/performance/contended-scenarios-2026-04-16/baseline.json`. |
| 1 | Task 1 audit | `322e2dc` | Document which harness paths were already registering submitters and which were not (`harness-audit.md`). |
| 1A | Task 2 | `6029c06` | Register submitter threads in `contended_cpu_10us` (`benchmarks/runtime_compare_zig.zig`). Set `max_submitter_queues` and `submitter_queue_capacity` at pool init. |
| 1B | Task 3 | `eac368b` | Register the main thread in `nested_fanout_4x`. Main thread was submitting the seed tasks without registering. |
| 1C | Task 4 | `1ee599d` | Register the main thread in `mixed_fast_slow`. Same shape as Task 3. |
| 1D | Task 5 | `1dde02e` | Plumb `register_submitters: bool` through `benchmarks/common.zig` (shared `bench-realistic` harness) and set it `true` for `contended_cpu_10us` and `nested_fanout_4x` specs. |
| 1E | Phase-1 baseline | `1f1e668` | Record paired-A/B Phase-1 deltas in `baseline-medians.md`. |
| 2A | Task 7 | `adc536f` | Elision-binary reference build — separate experiment measuring `-Dtimestamp-mode=disabled` `-Dscheduler-variant=work_stealing`. Does not feed the headline here. |
| 4A | Task 16 | `d357bd9` | Refresh `benchmarks/results/{runtime-comparison-latest,baseline,scale-latest}.json` post-landing. |
| 4B | Task 17 | `e83b911` | Refresh `CLAUDE.md`'s Current Direct Runtime Snapshot with final numbers + Phase-1 interpretation bullet. |

The four scenarios of the plan map to task chains like this:

- `contended_spawn_8x` — no harness change needed (already registering); gained +7.8% in paired A/B as a side effect of the session's pool-init defaults being exercised along a warmer path. Reported honestly in `phase1-after.json` as isolated.
- `contended_cpu_10us` — Task 2 + Task 5 (`bench-realistic` path). +4.6%.
- `nested_fanout_4x` — Task 3 + Task 5. +22.7%.
- `mixed_fast_slow` — Task 4. +10.9% (flipped ahead of Go).

## What was skipped (and why)

**Phase 2 — per-scenario perf profiling (Tasks 8–11).** The plan called
for `perf record` / `perf script` on each of the four scenarios. On this
host `/proc/sys/kernel/perf_event_paranoid` is `3`, which blocks
`perf record` without `sudo sysctl`. Per the user's directive ("increase
overall performance without sacrificing security or creating parallel
code that is failure prone"), we did not request the sysctl change and
skipped the profile-driven phase.

**Phase 3 — profile-driven `src/` attacks (Tasks 12–15).** Without
profiles, the only remaining attack surface for `contended_spawn_8x`,
`contended_cpu_10us`, and `nested_fanout_4x` is the `notifySubmits` /
wake-coordination / socket-sharding plane that is already covered by
seven prior closed-plane iterations (memories referenced below). All
plausible attacks had been tried and regressed, so we did not re-attempt
them.

**Phase 1 already over-delivered.** The four target scenarios gained
+4.6% / +7.8% / +22.7% / +10.9% with zero `src/` risk, and
`mixed_fast_slow` flipped ahead of Go. Stopping here was the right call.

## Closed planes confirmed (did not re-attempt)

Every one of these was already tried-and-closed in earlier sessions and
is retained in project memory. The plan explicitly gated Phase-3
candidates against this list.

- **drain-vs-steal reorder (Options C/D)** — `project_option_c_closed.md`,
  `project_option_d_closed_iter4.md`.
- **`parked_workers` shared u64 bitmap** —
  `project_parked_workers_bitmap_closed_iter7.md`.
- **Single-worker wake probe** — `project_single_probe_closed_iter8.md`.
- **`is_parked` cacheline isolation** —
  `project_iter9_closed_and_notify_ceiling.md`.
- **`shouldExit` off hot path** — `project_iter10_shouldexit_closed.md`.
- **Per-worker `active_tasks` shard** —
  `project_iter11_active_tasks_shard_closed.md`.
- **Socket-aware worker pinning (Slice 3a)** —
  `project_slice3a_worker_pinning_closed.md`.

The `notifySubmits` inclusive-time plateau (27.58% in prior profiles) is
treated as architectural per
`project_iter9_closed_and_notify_ceiling.md` and was not attacked.

## Measurement audit

**Phase-1 landings (Tasks 2–5).** Same-session paired A/B on
`bench-runtime-compare -Doptimize=ReleaseFast`, `n=7` with `1` warmup
discarded. `baseline.json` → `phase1-after.json` deltas recorded in
`baseline-medians.md`. No `src/` code paths were added, so no 20×
ReleaseFast stress gate was required (existing tests still pass).

**Final snapshot (Task 16).** `bench-runtime-compare` run at commit
`d357bd9` with `n=7` (1 warmup discarded, 6 retained), 56 workers.
Raw artifact: `benchmarks/results/runtime-comparison-latest.json`. The
session was warmer by ~30–75% on Go than the baseline session — see the
host-state caveat.

**No benchmark regressions** on any of the 4 non-target scenarios in the
Phase-1 paired A/B: `flood_1m`, `cpu_work_10us`, `cpu_work_100us`,
`burst_drain_burst` all within session noise. Final snapshot confirms.

## Host-state caveat

The bench host is 2-socket / 1-NUMA-node x86_64 Linux, 56 workers.
Between the baseline (`5a139ce`) and the Task-16 refresh (`d357bd9`)
the host gained thermal / CPU-frequency headroom on Go:

| Scenario | Go baseline | Go final | Swing |
|----------|------------:|---------:|------:|
| `flood_1m` | 772,343 | 1,346,758 | +74.4% |
| `contended_spawn_8x` | 3,832,459 | 3,522,449 | −8.1% |
| `contended_cpu_10us` | 1,807,198 | 2,426,316 | +34.3% |
| `nested_fanout_4x` | 3,175,814 | 3,550,322 | +11.8% |
| `burst_drain_burst` | 145,028 | 146,406 | +1.0% |
| `mixed_fast_slow` | 249,514 | 237,386 | −4.9% |

Zig moved only +4% on `flood_1m` over the same interval. The Phase-1
isolated paired A/B (same session, same binary) is the trustworthy read
of this plan's actual gains. Cross-snapshot multipliers in the headline
table above mix real Phase-1 gains with host drift and cannot be cleanly
separated.

## Next

- **Re-audit `bench-realistic` and `bench-tokio-parity` harnesses** for
  the same submitter-registration gap on the remaining five scenarios
  (`flood_1m`, `cpu_work_10us`, `cpu_work_100us`, `burst_drain_burst`,
  and Tokio-parity). Deferred from this plan; only `contended_cpu_10us`
  and `nested_fanout_4x` got the `register_submitters = true` flag in
  `bench_realistic.zig`.
- **Revisit after a Zig toolchain upgrade (0.16 → 0.17).** The
  `notifySubmits` architectural plateau may shift with new compiler
  codegen; worth re-profiling once we move.
- **If profiling ever becomes possible on this host** (sysctl or a
  different host), Phase 2/3 of the plan are still actionable — the
  closed-plane list above is evidence that the profile would have to
  reveal something new, not something already tried.
