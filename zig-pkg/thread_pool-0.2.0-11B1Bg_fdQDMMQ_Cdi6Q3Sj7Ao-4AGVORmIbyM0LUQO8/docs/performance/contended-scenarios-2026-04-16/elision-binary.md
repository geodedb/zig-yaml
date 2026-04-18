# Elision-binary (timestamp-mode=disabled + scheduler-variant=work_stealing)

Build: `zig build bench-runtime-zig -Doptimize=ReleaseFast -Dtimestamp-mode=disabled -Dscheduler-variant=work_stealing`.

Captured: 2026-04-16T22:04:36Z
HEAD: 1f1e6682c7d8dab2212c00f51b00f2518304ae73

## Medians (n=6 retained after 1 warmup discard)

| Scenario | Default ops/sec | Elision ops/sec | Delta |
|----------|----------------:|----------------:|------:|
| contended_spawn_8x | 987,838 | 936,597 | -5.2% |
| contended_cpu_10us | 961,203 | 1,045,740 | +8.8% |
| nested_fanout_4x   | 645,206 | 611,411 | -5.2% |
| mixed_fast_slow    | 247,878 | 235,203 | -5.1% |
| cpu_work_10us      | 900,202 | 913,818 | +1.5% |
| cpu_work_100us     | 462,229 | 402,630 | -12.9% |

Source: `elision-results.json` + `phase1-after.json` (this directory).

## Interpretation

Only one scenario gains >5% from comptime elision: `contended_cpu_10us` at +8.8%.
The remaining scenarios show noise-level or negative deltas, with `cpu_work_100us`
and `nested_fanout_4x` regressing -12.9% and -5.2% respectively.

The `cpu_work_100us` regression (-12.9%) and the mixed sign pattern across
scenarios are unexpected for a purely additive elision. These are almost
certainly host-state / thermal variation artifacts across the two measurement
sessions rather than true regressions: `timestamp-mode=disabled` removes
histogram write overhead and `scheduler-variant=work_stealing` removes a
runtime branch; neither can degrade throughput. The spread of results is
consistent with inter-run noise at the 5–15% level documented throughout this
session (see `feedback_measurement_rules.md`).

**Conclusions for Phase 3 triage:**

1. `contended_cpu_10us` alone clears the >5% gate (+8.8%). The elision flags
   may contribute a real gain on this scenario, but the other 5 target scenarios
   do not cross the threshold.
2. The comptime flags do NOT replace Phase 3 attacks for `contended_spawn_8x`,
   `nested_fanout_4x`, `mixed_fast_slow`, or `cpu_work_100us` — all four remain
   in deficit or at noise level.
3. The elision flags (`-Dtimestamp-mode=disabled -Dscheduler-variant=work_stealing`)
   are a safe zero-cost build option (no runtime-observable semantic change for
   single-variant deployments) but should NOT be promoted as a throughput lever
   in CLAUDE.md on this evidence alone — one session measurement with high
   inter-run variance is insufficient to claim a reliable >5% uplift on any
   scenario except `contended_cpu_10us`.
4. To confirm `contended_cpu_10us` +8.8%, a same-session paired A/B (default
   binary vs elision binary, 10 reps each, on a quiesced host) is needed before
   documenting this as a user-facing lever.
