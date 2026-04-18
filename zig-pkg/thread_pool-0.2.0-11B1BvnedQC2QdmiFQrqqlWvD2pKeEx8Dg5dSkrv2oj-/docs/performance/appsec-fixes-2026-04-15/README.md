# AppSec Remediation — Performance Tracking (2026-04-15)

Spec: `docs/APPSEC_REVIEW_2026-04-15_src.md`
Plan: `docs/superpowers/plans/2026-04-15-appsec-remediation.md`

## Baselines

- `BASELINE-bench.json` — output of `zig build bench` on the starting commit.
- `BASELINE-realistic.json` — output of `zig build bench-realistic -Doptimize=ReleaseFast`.

## Per-step artifacts

Each remediation step produces five files:

- `STEP-<N>-<name>-before-bench.json`
- `STEP-<N>-<name>-after-bench.json`
- `STEP-<N>-<name>-before-realistic.json`
- `STEP-<N>-<name>-after-realistic.json`
- `STEP-<N>-<name>-diff.md` — markdown delta table.

Update the Status and Regression class columns in the table below after each step's diff is reviewed.

## Step progress

| Step | Fix | Status | Regression class |
|------|-----|--------|------------------|
| 1 | F-001 per-pool TLS | done | clean (bench noise, see diff) |
| 2 | F-002 spawn errdefer | done | clean (bench + p95 noise, ruled out by construction) |
| 3 | F-003 atomic free_indices | done | clean (zero codegen delta on x86_64; all low-stddev scenarios flat-to-improved) |
| 4 | F-006 no unreachable blocking_inject | done | clean (contention-bench variance within historical 9–10% CV; realistic scenarios flat-to-improved) |
| 5 | F-005 harden releaseSubmitter | done | clean (releaseSubmitter is cold-path lifecycle, not exercised in any bench; all shifts are sample-to-sample noise within known 9–14% CV, see diff) |
| 6 | F-004 soften WaitGroup.done | done | clean (bench noise, ruled out by construction on underflow-only code path) |
| 7 | F-007 clamp parseProcStatusKiB | done | clean (bench noise, ruled out by construction on stats-sampling-only code path) |
| 8 | TSan stress run | done | clean — zero warnings across unit/integration/stress |
| 9 | Fuzz harness | done | clean — 100 + 5000×3 iterations across 3 seeds |
| 10 | Final perf snapshot | done | see [FINAL.md](FINAL.md) |
