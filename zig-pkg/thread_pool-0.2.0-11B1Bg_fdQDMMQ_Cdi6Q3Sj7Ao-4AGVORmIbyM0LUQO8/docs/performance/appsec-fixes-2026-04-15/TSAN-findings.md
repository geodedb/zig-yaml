# TSan Findings — AppSec Remediation 2026-04-15

## Environment

- Commit: 5b143d6a797273b881b8798cc27a665994de1d82
- Zig version: 0.15.2
- Host: linux x86_64
- Command: `mise x zig@0.15.2 -- zig build test-stress -Dtsan --summary all`
- Run date: 2026-04-15

## Summary

| Classification | Count |
|---|---:|
| Real races (follow-up needed) | 0 |
| Known-benign (documented) | 0 |
| Likely false positives | 0 |
| Total warnings | 0 |

ThreadSanitizer reported **zero warnings** across all three test suites.

| Suite | Command | Result | Tests |
|---|---|---|---|
| `test-stress` | `zig build test-stress -Dtsan` | passed | 14/14 |
| `test` (unit) | `zig build test -Dtsan` | passed | 41/42 (1 skipped) |
| `test-integration` | `zig build test-integration -Dtsan` | passed | 23/23 |

The prior fixes — F-001 (per-pool TLS scoping), F-002 (spawn-aware errdefer),
F-003 (atomic free_indices), and F-005 (CAS-based releaseSubmitter) — appear to
close the data-race surface exposed by the full test suite under TSan. The
single skipped unit test was already skipped before TSan (platform-conditional,
not a TSan suppression).

## Build option added

`-Dtsan=[bool]` was added to `build.zig`. When set, it:

1. Switches the stress suite optimize mode from `ReleaseFast` to `Debug` so
   races are not eliminated by the optimiser before TSan can observe them.
2. Sets `sanitize_thread = true` on the root modules for `unit_tests`,
   `integration_tests`, and `stress_tests`.

The option is wired through the `all_tests_step` automatically because that
step references the same compile artifacts.

## Coverage notes

This run exercised the `test-stress` (14 scenarios), `test` (41 unit tests),
and `test-integration` (23 scenarios) suites. The workloads include:

- Multi-threaded flood submission with many workers
- Work-stealing across scheduler variants (`global_queue`, `work_stealing`,
  `lane_extension`)
- WaitGroup rendezvous under concurrent completion
- Per-submitter queue register/release cycling
- Stats counter accumulation under parallel tasks
- Pool shutdown races (drain vs. submit)

A clean TSan result here provides strong signal that the concurrent data paths
corrected in F-001 through F-005 are sound under the current workloads. It
does not guarantee TSan-clean under every possible access pattern.

## Recommended follow-ups

No real races were found. The following non-urgent extensions are worth
considering in a future pass:

- **Fuzz harness under TSan** (Task 9): once the public-API fuzz harness is
  in place, run it with `-Dtsan` for a few minutes to exercise scheduler
  interleavings that the bounded stress suite does not reach.
- **Extend stress suite duration** for CI nightly: a short TSan run passes in
  ~15 s; a longer soak (30–60 s per scenario) would surface lower-probability
  races that require more thread interleavings to trigger.
