# Quality Gap Analysis

Last updated: 2026-04-16

## Summary

- **Critical:** 0 | **High:** 3 open + 3 closed | **Medium:** 15 | **Low:** 12 | **Info:** 0
- **Total open findings (new audit):** 29 open + 3 closed on 2026-04-16 (QS-002, QS-003, QS-008)
- **Legacy Q-xxx open items carried over:** 12 (from 2026-04-11 audit pass)
- **Formal gates (2026-04-16):** `zig fmt` clean, `zig build check` clean, `zig build test` 47 pass / 1 skip / 0 fail; `test-all` + TSan stress all pass post-closure

### Top 5 Risks (current pass, by PriorityScore)

1. **QS-001** Split 2087-line src/pool.zig monolith (PriorityScore 80)
2. ~~**QS-003** Decompose 130-line hot-path Core.runTask~~ — **Closed 2026-04-16 (a0259e6)**
3. ~~**QS-002** Decompose 147-line Core.init with nested errdefers~~ — **Closed 2026-04-16 (301392b)**
4. ~~**QS-008** Document 24 undocumented public symbols in src/types.zig~~ — **Closed 2026-04-16 (429caab)**
5. **QR-001** Add unit-level tests for lane/watchdog/overflow slices (PriorityScore 48)

### Closed This Sweep (2026-04-16)

| Gap-ID | Commit | Issue | Evidence |
|--------|--------|-------|----------|
| QS-002 | `301392b` | [#15](https://gitlab.com/devnw/zig/thread-pool/-/issues/15) | `Core.init` 147 → 60 lines; F-002 errdefer chain preserved |
| QS-003 | `a0259e6` | [#16](https://gitlab.com/devnw/zig/thread-pool/-/issues/16) | Hot-path decomposed; +16.3% conn_churn_seq / +11.7% producer_contention paired A/B |
| QS-008 | `429caab` | [#18](https://gitlab.com/devnw/zig/thread-pool/-/issues/18) | 24 public symbols documented; `grep -c '^///' src/types.zig` = 159 |

## Stack-Ranked Findings — 2026-04-16 Audit Pass

| Rank | Severity | PriorityScore | Category | Finding | Component | Issue URL | Fix Summary | Effort | Status |
|------|----------|---------------|----------|---------|-----------|-----------|-------------|--------|--------|
| 1 | High | 80 | readability | QS-001 Split 2087-line pool.zig into worker/descriptor/lanes/watchdog/stats | src/pool.zig | [#14](https://gitlab.com/devnw/zig/thread-pool/-/issues/14) | 5-way file split, target <700 lines each | L | Open |
| 2 | High | 64 | readability/perf | QS-003 Extract recordTaskStart/invokeTask/finalizeTask from Core.runTask | src/pool.zig:1670-1887 | [#16](https://gitlab.com/devnw/zig/thread-pool/-/issues/16) | Inline helpers, preserve atomic ordering | M | **Closed 2026-04-16 (a0259e6)** — see `GAP_ANALYSIS_RESOLVED.md` |
| 3 | High | 60 | readability | QS-002 Extract allocateStorage/initDescriptorFreelist/initWorkers/spawnWorkers | src/pool.zig:408-554 | [#15](https://gitlab.com/devnw/zig/thread-pool/-/issues/15) | Target 30-40 line orchestrator | M | **Closed 2026-04-16 (301392b)** — see `GAP_ANALYSIS_RESOLVED.md` |
| 4 | High | 60 | docs/api-contract | QS-008 Add /// to 24 undocumented public symbols in types.zig | src/types.zig:4-378 | [#18](https://gitlab.com/devnw/zig/thread-pool/-/issues/18) | Enum + struct + method doc blocks | M | **Closed 2026-04-16 (429caab)** — see `GAP_ANALYSIS_RESOLVED.md` |
| 5 | High | 48 | tests | QR-001 Unit tests for lane/watchdog/overflow slices | tests/unit.zig | [#24](https://gitlab.com/devnw/zig/thread-pool/-/issues/24) | 6 new unit tests + injectable clock | M | Open |
| 6 | High | 48 | reliability/ci-cd | QR-002 CI gate for -Dsingle-pool + comptime safety assertion | build.zig, .gitlab-ci.yml | [#28](https://gitlab.com/devnw/zig/thread-pool/-/issues/28) | Add test-single-pool job | S | Open |
| 7 | Medium | 36 | docs | QS-009 Document ThreadPool.init, registerSubmitter, releaseSubmitter | src/pool.zig:1986-2070 | [#31](https://gitlab.com/devnw/zig/thread-pool/-/issues/31) | /// on 3 methods + F-005 cite | S | Open |
| 8 | Medium | 36 | api-contract | QR-003 Declare ConfigError explicit error set | src/types.zig:234 | [#41](https://gitlab.com/devnw/zig/thread-pool/-/issues/41) | 19-variant error set + signature update | S | Open |
| 9 | Medium | 36 | api-contract | QR-004 Declare SubmitError/WaitError/ShutdownError/RegisterError/PurgeError | src/pool.zig | [#43](https://gitlab.com/devnw/zig/thread-pool/-/issues/43) | Explicit sets through facade | S-M | Open |
| 10 | Medium | 32 | readability | QS-004 Simplify 93-line Core.enqueuePush (8-level indent) | src/pool.zig:1017-1109 | [#34](https://gitlab.com/devnw/zig/thread-pool/-/issues/34) | 3-branch dispatch helper extraction | M | Open |
| 11 | Medium | 32 | docs | QR-009 Add module-level //! headers to pool.zig and types.zig | src/pool.zig, src/types.zig | [#58](https://gitlab.com/devnw/zig/thread-pool/-/issues/58) | Invariants listed at file head | S | Open |
| 12 | Medium | 24 | readability | QS-005 Extract helpers from statsSnapshot/nextTask/idle | src/pool.zig | [#45](https://gitlab.com/devnw/zig/thread-pool/-/issues/45) | Preserve SC handshake verbatim | M | Open |
| 13 | Medium | 24 | api-contract/docs | QR-005 Document SubmitOptions defaults + .block deadlock footgun | src/types.zig:268-275 | [#49](https://gitlab.com/devnw/zig/thread-pool/-/issues/49) | /// on struct + cross-link Config | S | Open |
| 14 | Medium | 24 | api-contract | QR-006 Document or fix Stats.worker_stats aliasing/lifetime | src/types.zig:378-409 | [#53](https://gitlab.com/devnw/zig/thread-pool/-/issues/53) | Either doc + single-caller rule, or dupe slice | S-M | Open |
| 15 | Medium | 24 | reliability/tests | QR-007 Inject clock source for deterministic watchdog tests | src/pool.zig:1176-1203 | [#61](https://gitlab.com/devnw/zig/thread-pool/-/issues/61) | NowFn typedef or watchdogTick extraction | M | Open |
| 16 | Medium | 24 | hygiene (cluster) | QS-HYG Repo hygiene: CODEOWNERS, SECURITY.md, Makefile, zig-0.15.2/, stray binaries, topology.zig | Repo-wide | [#77](https://gitlab.com/devnw/zig/thread-pool/-/issues/77) | Collapsed meta issue (6 sub-tasks) | M | Open |
| 17 | Medium | 24 | reliability/ci-cd | QS-015 Add -Dsanitize=address + scheduled ASan soak | build.zig, .gitlab-ci.yml | [#66](https://gitlab.com/devnw/zig/thread-pool/-/issues/66) | Mirror tsan-stress-soak job | S-M | Open |
| 18 | Medium | 24 | reliability/ci-cd | QS-016 Wire kcov coverage + GitLab coverage stanza | build.zig, .gitlab-ci.yml | [#69](https://gitlab.com/devnw/zig/thread-pool/-/issues/69) | Nightly coverage-linux job | M | Open |
| 19 | Medium | 24 | ci-cd | QS-018 Pre-commit gate: max 1200 line files, max 150 line functions | .pre-commit-config.yaml | [#73](https://gitlab.com/devnw/zig/thread-pool/-/issues/73) | scripts/quality-gate.py | S | Open |
| 20 | Medium | 16 | reliability | QR-008 Test overflow-worker spawn-failure path | src/pool.zig:1205-1221 | — | Suspected — belly-of-rlimit test required | M | Not tracked (below cutoff; confidence suspected) |
| 21 | Medium | 16 | readability | QS-020 35 lines at >=6 indent levels | src/pool.zig | — | Subsumed by QS-001/QS-004/QS-005 | — | Subsumed |
| 22 | Low | 16 | readability | QS-006 Three queue impls duplicate mask+SC idioms | src/queue/*.zig | — | Extract src/queue/common.zig | S | Doc-only |
| 23 | Low | 12 | api | QR-012 Config.hot_spinners + wake_every_n_tasks cross-field coupling | src/types.zig:77-102 | — | Optional nested HotSpinnerConfig (0.3.0 break) | S | Doc-only |
| 24 | Low | 12 | api | QR-013 Config.normalized() `catch X` silently accepts non-pow2 | src/types.zig:197-232 | — | Propagate error or explicit validate ranges | S | Doc-only |
| 25 | Low | 12 | docs | QR-010 Add stress reproducers for closed F-001/F-002/F-004/F-005 | tests/stress/ | — | 4 new TSan-gated stress tests | M | Doc-only |
| 26 | Low | 12 | docs | QR-011 Promote key design choices into docs/adr/ ADR files | docs/ | — | 5 ADR files extracted from docs/* | S-M | Doc-only |
| 27 | Low | 8 | docs | QS-019 Doc nowNs + updatePeakU32 | src/pool.zig:2073-2086 | — | 2 /// blocks | S | Doc-only |
| 28 | Low | 8 | reliability | QS-017 JSON schema for benchmark result files | benchmarks/ | — | draft-07 schema + ajv CI step | S | Doc-only |

**Cutoff note:** All High and Medium findings (scores >= 24) received GitLab issues. Medium finding QR-008 (score 16, confidence::suspected) was explicitly not tracked — the cost of a spawn-failure harness exceeds the expected value absent confirmation. QS-020 is subsumed by QS-001/QS-004/QS-005. Low-severity items (scores 8-16) are tracked in this document only; they will be promoted if they cluster with a related fix or if a maintainer elects to batch-address.

## Legacy Q-xxx Open Items (carried from 2026-04-11 audit)

These items predate the 2026-04-16 QS/QR scan and remain open pending separate resolution. Issue URLs are not yet filed for these; tracked in this document.

| ID | Severity | PriorityScore | Category | Finding | Component | Status |
|------|----------|---------------|----------|---------|-----------|--------|
| Q-023 | Medium | 40 | maintainability | deinitOwned missing recordOwnedFree for inject_queue buffer | pool.zig:678 vs :149 | Open |
| Q-024 | Medium | 40 | api-contract | process_memory.private_peak_bytes reports current not peak on Linux | process_memory.zig:73-74 | Open |
| Q-004 | Medium | 28 | tests | .block backpressure policy untested | tests/*.zig | Partially Fixed |
| Q-025 | Medium | 24 | docs | submitBatch doc says "atomically" but behavior is sequential | pool.zig:745-748 | Open |
| Q-028 | Low | 18 | docs | DESIGN.md says inject queue "Mutex-protected" but it is lock-free Vyukov | DESIGN.md:52 | Open |
| Q-029 | Low | 18 | docs | DESIGN.md says work-stealing "is not currently lock-free" | DESIGN.md:99 | Open |
| Q-006 | Low | 12 | api-contract | lane_extension variant still visible in public enum | types.zig:6,99 | Partially Fixed |
| Q-018 | Low | 12 | perf | compare.zig readDocument leak mitigated but no explicit free | compare.zig:45 | Open |
| Q-026 | Low | 12 | readability | Core.waitGroup() ignores self parameter | pool.zig:244-247 | Open |
| Q-030 | Low | 12 | maintainability | Code duplication: nowNs()/Counter/updatePeak | multi-file | Open |
| Q-020 | Low | 8 | maintainability | version constant in root.zig unreferenced | root.zig:16 | Open |
| Q-021 | Low | 8 | cleanup | CODEOWNERS contains placeholder @your-username | CODEOWNERS:3 | **Superseded by QS-HYG sub-task** |
| Q-027 | Low | 8 | readability | Magic sentinel 0xFFFFFFFF used as raw literal | pool.zig:158 vs :613 | Open |

## Findings by Category (2026-04-16 pass)

### readability / maintainability

- QS-001 (High, 80) — pool.zig monolith split
- QS-003 (High, 64) — Core.runTask decomposition
- QS-002 (High, 60) — Core.init decomposition
- QS-004 (Medium, 32) — enqueuePush simplification
- QS-005 (Medium, 24) — statsSnapshot/nextTask/idle helpers
- QS-020 (Medium, 16) — subsumed

### docs / api-contract

- QS-008 (High, 60) — types.zig doc coverage
- QS-009 (Medium, 36) — facade doc gaps
- QR-003 (Medium, 36) — ConfigError set
- QR-004 (Medium, 36) — Submit/Wait/Shutdown/Register/Purge sets
- QR-005 (Medium, 24) — SubmitOptions + .block footgun
- QR-006 (Medium, 24) — Stats.worker_stats aliasing
- QR-009 (Medium, 32) — module //! headers

### tests / reliability

- QR-001 (High, 48) — unit tests for lanes/watchdog/overflow
- QR-002 (High, 48) — -Dsingle-pool CI gate
- QR-007 (Medium, 24) — injectable clock
- QS-015 (Medium, 24) — ASan CI
- QS-016 (Medium, 24) — coverage instrumentation
- QS-018 (Medium, 24) — pre-commit size/complexity gate

### hygiene

- QS-HYG (Medium, 24) — cluster meta: CODEOWNERS, SECURITY.md, Makefile/zig-0.15.2, stray binaries, topology.zig

## Remediation Roadmap

### Quick Wins (< 1 day each)

| ID | Fix | Effort | Issue |
|----|-----|--------|-------|
| QR-002 | Add `test-single-pool` CI job + comptime assertion | S | #28 |
| QR-003 | Declare ConfigError; update validate signature | S | #41 |
| QS-009 | /// on ThreadPool.init / register / release | S | #31 |
| QR-005 | /// on SubmitOptions documenting .block footgun | S | #49 |
| QR-009 | //! headers on pool.zig + types.zig | S | #58 |
| QS-018 | Pre-commit size gate script | S | #73 |
| QS-HYG | Individual sub-tasks (CODEOWNERS, SECURITY.md, stray binaries) | S each | #77 |

### Medium (1-5 days)

| ID | Fix | Effort | Issue |
|----|-----|--------|-------|
| QS-002 | Decompose Core.init | M | #16 |
| QS-003 | Decompose Core.runTask (perf-gated) | M | #18 |
| QS-004 | Simplify enqueuePush | M | #34 |
| QS-005 | Extract statsSnapshot / nextTask / idle helpers | M | #45 |
| QS-008 | Doc 24 types.zig public symbols | M | #21 |
| QR-001 | 6 new unit tests + injectable clock | M | #24 |
| QR-004 | Explicit error sets through facade | S-M | #43 |
| QR-006 | Fix or document Stats.worker_stats aliasing | S-M | #53 |
| QR-007 | Injectable clock / watchdogTick | M | #61 |
| QS-015 | ASan build option + scheduled job | S-M | #66 |
| QS-016 | kcov pipeline | M | #69 |

### Strategic (> 5 days)

| ID | Fix | Effort | Issue |
|----|-----|--------|-------|
| QS-001 | Split pool.zig into 5 files | L | #14 |

## Scoring Methodology

```text
PriorityScore = Impact(1-5) * Likelihood(1-5) * 4
```

- **Impact**: 5=outage/UB, 4=frequent bugs/major dev drag, 3=moderate, 2=minor, 1=polish.
- **Likelihood**: 5=ubiquitous/touched often, 4=often encountered, 3=sometimes, 2=rare, 1=edge-case.
- **Range**: 4 (lowest) to 100 (highest).
- **Cutoff**: High severity auto-qualifies for a tracked issue regardless of score. Medium qualifies at score >= 24 with `confidence::confirmed`. Low only escalates to an issue if trivially fixable AND part of a cluster (see QS-HYG).
- All new findings tagged `confidence::confirmed` except QR-008 (`confidence::suspected`, not tracked).
