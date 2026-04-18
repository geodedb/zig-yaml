# Phase H — nextTask Double-Dequeue Race (CLOSED)

**Status:** SHIPPED to main 2026-04-13. Race fix is in production; this directory is historical reference.

**Merge:** `a75ed98` (`fix: merge Phase H (nextTask double-dequeue race) from feat/phase-h-fix-double-dequeue-race`).

## Investigation arc (commits)

1. `ac12f3c` `test(phase h): add deterministic double-dequeue reproducer`
2. `58f8ec2` `chore(phase h): add per-descriptor claim sentinel for double-dequeue`
3. `39a94be` `chore(phase h): make claim sentinel always-on for race investigation`
4. `960c48a` `test(phase h): force park regime in reproducer with spin=0`
5. `819a925` `docs(phase h): diagnose nextTask scheduler race root cause`
6. `710a98f` `fix(phase h): gate runTask dispatch with state CAS`
7. `daedce6` `fix(phase h): balance queued_tasks under ghost-dispatch + cap stealHalf retries`
8. `e7b6703` `docs(phase h): close out — 100/100 ReleaseFast validation`
9. `a75ed98` (merge to main)

## Open follow-up

The `claim_sentinel_enabled = true` flag at `src/pool.zig:167` is leftover always-on (intended to revert to `std.debug.runtime_safety` post-fix per the original plan's Task 6, but no commit has done so). Per-dispatch cost is ~2 atomic ops per task. Decision pending: keep as permanent safety net or revert per the TODO. See `plan.md` Task 2 Step 1 commentary.

## Files

- `plan.md` — the original Phase H implementation plan (kept verbatim as-authored 2026-04-13). The line numbers in the plan are stale (code drifted) but the structural prescriptions match what was actually implemented and merged.
