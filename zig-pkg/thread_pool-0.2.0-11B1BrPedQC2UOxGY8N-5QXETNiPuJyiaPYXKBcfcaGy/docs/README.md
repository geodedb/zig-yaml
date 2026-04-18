# thread-pool Documentation

Documentation for setup, API usage, testing, benchmarking, algorithms,
and performance history.

## Start Here

- [Getting Started](getting-started.md) — install, build, first pool
- [API Reference](api-reference.md) — every public symbol
- [Examples](examples.md) — batch submit, blocking lanes, cancellation
- [FAQ](faq.md)

## Architecture & Algorithms

- [Architecture](architecture.md) — component layout + ownership rules
- [Design](DESIGN.md) — rationale, queue design, memory model, shutdown
- [**Algorithms**](ALGORITHMS.md) — mermaid diagrams for each pipeline
  (submit flow, worker loop, descriptor lifecycle, DescCache, Chase-Lev
  deque, RingQueue SPMC, Vyukov MPMC, wake coalescing, lane routing,
  watchdog, shutdown)
- [Scheduler Decision](SCHEDULER_DECISION.md) — variant-picking rubric

## Testing & Benchmarks

- [Testing](TESTING.md) — validation matrix, TSan, fuzz, stress gate
- [**Benchmarks**](BENCHMARKS.md) — scenario matrix, measurement
  protocol, current snapshot, A/B loop reference
- [Runtime Comparison](RUNTIME_COMPARISON.md) — Zig vs Tokio vs Go
  same-host snapshot + analysis
- [Performance Tracking](PERFORMANCE_TRACKING.md) — long-form per-phase
  delta history

## Security

- [AppSec Review (2026-04-15)](APPSEC_REVIEW_2026-04-15_src.md) —
  full-src audit; all 7 priority findings fixed.
- [AppSec Remediation FINAL](performance/appsec-fixes-2026-04-15/FINAL.md) —
  end-to-end performance ledger + same-compiler bisect + optimisation
  pass.
- [TSan Baseline Findings](performance/appsec-fixes-2026-04-15/TSAN-findings.md) —
  zero warnings on current `main`.
- [Remediation Plan](superpowers/plans/2026-04-15-appsec-remediation.md) —
  the 11-task plan that produced the fixes.
- [SEC-018 — `wait()` idempotency ADR](security/SEC-018.md)
- [REV-001 — `task_fn` panic contract ADR](security/REV-001.md)

## Gap Analyses

- [Gap Analysis (current)](GAP_ANALYSIS.md)
- [Gap Analysis Resolved](GAP_ANALYSIS_RESOLVED.md)
- [Quality Gap Analysis](QUALITY_GAP_ANALYSIS.md)
- [Performance Gap Analysis](PERF_GAP_ANALYSIS.md)
- [Performance Targets](PERFORMANCE_TARGETS.md)

## Performance Archive

Chronological (most recent first):

- [2026-04-17 Go-gap round 3 (FAILED)](performance/2026-04-17-go-gap-round3/FINAL.md) —
  externalised per-worker DescCache reverted; indirection cost dominated
  Worker-size savings on all 3 primary targets. **Closed plane.**
- [2026-04-17 Go-gap round 2 (FAILED)](performance/2026-04-17-go-gap-round2/FINAL.md) —
  lifo-rotate + batched submitBatch both reverted; **closed-plane
  reference** for future rounds.
- [2026-04-16 Go-gap contended (DescCache landing)](performance/2026-04-16-go-gap-contended/FINAL.md) —
  `nested_fanout_4x +81.26%`; `contended_spawn_8x +35.98%`;
  `contended_cpu_10us +31.71%`.
- [2026-04-15 AppSec Remediation Perf Ledger](performance/appsec-fixes-2026-04-15/README.md) —
  BASELINE → per-step → FINAL, same-compiler bisect, `-Dsingle-pool`
  optimisation data.
- [2026-04-15 Direct Runtime Comparison](performance/2026-04-15-runtime-comparison/README.md)
- [2026-04-15 Post-Gen-Tag Profile](performance/2026-04-15-post-gen-tag-profile/README.md)
- [2026-04-14 Scratch Fast-Path + Idle Queue (reverted)](performance/2026-04-14-scratch-fastpath-idle-queue/README.md)

## Handoffs & Reviews

- [Current Handoff (2026-04-15)](HANDOFF-2026-04-15.md)
- [Previous Handoff (2026-04-14)](HANDOFF-2026-04-14.md)
- [2026-04-14 Codex Review](codex-review-2026-04-14.md)
- [Gap Closure Report (2026-04-16)](gap-closure-report-2026-04-16.md)

## Quick Links

- [Repository README](../README.md)
- [Contributing](../CONTRIBUTING.md)
- [Security](../SECURITY.md)
- [Changelog](../CHANGELOG.md)
