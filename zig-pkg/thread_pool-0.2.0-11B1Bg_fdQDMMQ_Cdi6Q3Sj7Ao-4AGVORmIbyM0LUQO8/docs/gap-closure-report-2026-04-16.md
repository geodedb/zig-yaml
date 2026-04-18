# Gap Closure Completion Report -- 2026-04-16

## Scope

7-gap closure sweep on `devnw/zig/thread-pool` (GitLab project 81217842).
Driven by the manifest at `.cache/audit/gap-close-implementation.json` and
verified against `/tmp/gap-verify-report.md` (full suite + TSan + perf gates
all green).

## Outcome Summary

| Outcome | Count | Gap-IDs |
|---|---|---|
| Fully closed | 6 | SEC-018, REV-001, QS-008, QS-002, QS-003, OBSERVABILITY-PIVOT |
| Partially closed (issue remains open) | 1 | COMPTIME-ELISION (PERF-P-09) |
| Blocked | 0 | -- |
| Won't-do | 0 | -- |

## Closed Items

| Gap-ID | Issue | Commit | Evidence |
|---|---|---|---|
| SEC-018 (F-008 confidential) | [#23](https://gitlab.com/devnw/zig/thread-pool/-/issues/23) | `57f77f7` | `src/pool.zig` CAS-guard in `Core.wait()`; double-wait stress + TSan soak clean. Implementer used `cmpxchgWeak .acq_rel/.acquire` (equivalently correct vs the proposed `cmpxchgStrong .acq_rel/.monotonic`: weak+acq_rel tolerates spurious failure inside the existing loop and publishes terminal-state observation with the success ordering). |
| REV-001 | [#35](https://gitlab.com/devnw/zig/thread-pool/-/issues/35) | `5faccb5` | Panic contract documented; ADR at `docs/security/REV-001.md`; skew observability hooks in `src/pool.zig`. |
| QS-008 | [#18](https://gitlab.com/devnw/zig/thread-pool/-/issues/18) | `429caab` | 24 public symbols now documented in `src/types.zig`; `grep -c '^///' src/types.zig` = **159**. |
| QS-002 | [#15](https://gitlab.com/devnw/zig/thread-pool/-/issues/15) | `301392b` | `Core.init` **147 → 60 lines** via `allocateStorage` / `initDescriptorFreelist` / `initWorkers` / `spawnWorkers` helpers. F-002 errdefer cleanup order preserved verbatim. |
| QS-003 | [#16](https://gitlab.com/devnw/zig/thread-pool/-/issues/16) | `a0259e6` | Hot-path `Core.runTask` decomposed into `recordTaskStart` / `invokeTask` / `finalizeTask`. Atomic ordering preserved. Paired n=20 A/B: **+16.3% conn_churn_seq / +11.7% producer_contention** (stddev-disjoint, no regression on other scenarios). |
| OBSERVABILITY-PIVOT | [#46](https://gitlab.com/devnw/zig/thread-pool/-/issues/46) | `3356d1d`, `a39092a`, `7c9d2e6`, `5561a46`, `e75f4e0`, `f1e7b67` | R-01 p999/p9999; R-02 per-lane histograms; R-03 wake-latency histogram; R-06 layout heatmap + `@offsetOf` asserts; R-10 `max_pool_memory_bytes` + `memory_budget_used_bytes`; `PERF_GAP_ANALYSIS.md` tracker flipped Closed. |

## Partially Closed (Issue Remains Open)

| Gap-ID | Issue | Landed | Deferred |
|---|---|---|---|
| COMPTIME-ELISION (PERF-P-09) | [#73](https://gitlab.com/devnw/zig/thread-pool/-/issues/73) (open, scope reduced) | `c9a05e8` — `-Dtimestamp-mode` + `-Dscheduler-variant` | `-Dqueue-kind` and `-Dlane-extension` deferred; scope-reduce comment posted on #73. |

## Blocked Items

None.

## Won't-Do Items

None.

## GitLab Issues Updated

| Gap-ID | Issue | Action | Label Change |
|---|---|---|---|
| SEC-018 | #23 | closed with closure comment | +`Gap-Implemented` |
| REV-001 | #35 | closed with closure comment | +`Gap-Implemented` |
| QS-008 | #18 | closed with closure comment | +`Gap-Implemented` |
| QS-002 | #15 | closed with closure comment | +`Gap-Implemented` |
| QS-003 | #16 | closed with closure comment | +`Gap-Implemented` |
| OBSERVABILITY-PIVOT | #46 | closed with closure comment | +`Gap-Implemented` |
| COMPTIME-ELISION | #73 | kept open, scope-reduce comment | -`Gap-NotImplemented` / +`Gap-Partial` |

### Issue-ID Correction

The original task briefing mapped `QS-008 → #21`, `QS-002 → #16`,
`QS-003 → #18`. The actual GitLab mapping (verified via
`glab issue list --search`) is:

- QS-002 = **#15** (not #16)
- QS-003 = **#16** (not #18)
- QS-008 = **#18** (not #21)
- #21 is `QR-001` (lane/watchdog/overflow unit tests) -- **not** in this sweep.

Closures were executed against the correct issue numbers. The
`docs/QUALITY_GAP_ANALYSIS.md` table also had stale issue-ID references and
has been fixed in this doc-update commit.

## Tests Executed

| Command | Result |
|---|---|
| `zig build test --summary all` | PASS (47/47 + 1 skip) |
| `zig build test-integration --summary all` | PASS |
| `zig build test-stress --summary all` | PASS |
| `zig build test-all --summary all` | PASS |
| `zig build bench -- --output benchmarks/results/latest.json` | PASS (no regression) |
| `zig build test -Doptimize=ReleaseFast -Dtsan=true` | TSan clean |

## Measured Performance Deltas

| Scenario | Pre-QS-003 | Post-QS-003 | Delta |
|---|---|---|---|
| `conn_churn_seq` | baseline | +16.3% | paired n=20, stddev-disjoint |
| `producer_contention` | baseline | +11.7% | paired n=20, stddev-disjoint |
| Other scenarios | -- | neutral | no regression in `flood_1m_batched`, `contended_spawn_8x`, `mixed_fast_slow` |

## Security Notes

- **SEC-018** closes a Medium-severity CWE-416 (UAF) + CWE-362 (race) bug in the
  `TaskHandle.wait()` descriptor-release path. The CAS ensures at most one
  waiter publishes release. No new fuzz corpus entries were required; the
  existing double-wait stress reproducer is now clean.
- **REV-001** is a caller-contract hardening; default panic aborts as before.
  The ADR at `docs/security/REV-001.md` is the canonical reference for hosts
  using a custom `std.debug.setPanicHandler`.
- **SEC-018 vs public-label SEC-018**: the confidential F-008 SEC-018 closed
  here (#23) is distinct from the public-label SEC-018 (#30, `queue_capacity`
  non-pow2 on 32-bit bypasses validation). The public one remains Partial and
  is still tracked in `GAP_ANALYSIS.md`.

## Remaining Blockers

None. COMPTIME-ELISION is a scope reduction, not a blocker.

## Documentation Artifacts Updated

- `docs/GAP_ANALYSIS.md` — added "Recently Resolved" breadcrumb table; added
  COMPTIME-ELISION row marked Partial; distinguished confidential SEC-018
  (#23, closed) from public SEC-018 (#30, Partial).
- `docs/GAP_ANALYSIS_RESOLVED.md` — appended 2026-04-16 Gap-Closure Sweep
  section with all 6 closures + COMPTIME-ELISION breadcrumb.
- `docs/QUALITY_GAP_ANALYSIS.md` — QS-002/003/008 rows flipped Closed with
  correct commit + issue refs; Top-5 list updated; "Closed This Sweep" table
  added.
- `docs/PERF_GAP_ANALYSIS.md` — Top-5 list updated to reflect
  OBSERVABILITY-PIVOT closed and COMPTIME-ELISION partial. (Stack-rank table
  was already marked correctly by the implementer at `f1e7b67`.)
- `docs/gap-closure-report-2026-04-16.md` — this file.

## Next Review

2026-05-16 -- next scheduled gap-analysis sweep.
