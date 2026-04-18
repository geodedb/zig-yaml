# Counters Layout Correctness Fix

## Summary

This branch (`fix/counters-layout-correctness`) lands two related correctness fixes extracted from the larger (null-perf) Phase G3 attempt:

1. Split `counters.submitted` onto its own cacheline.
2. Convert `Counters` to `extern struct` + `align(std.atomic.cache_line)` on the embedded `counters` field in `Core` + comptime `@offsetOf` asserts.

Together, these make the cacheline padding inside `Counters` load-bearing for the first time. Prior to this fix, Zig's auto-layout was silently reordering the `_pad0`/`_pad1` padding fields to the struct's tail, so all hot-write atomics (`queued_tasks`, `submitted`, `active_tasks`, `cancelled`) were packed into a single 32-byte span and shared a cacheline. The padding existed but was inert.

The comptime block locks the invariant at `@offsetOf(Counters, "queued_tasks") == 0`, `@offsetOf(Counters, "submitted") == cache_line_size`, `@offsetOf(Counters, "active_tasks") == 2 * cache_line_size` — a future field reorder surfaces as a compile-time error.

An observability regression test guards `Stats.submitted == N` after N spawns, to prevent future refactors from silently breaking the observability contract.

## What was NOT landed

The full Phase G3 plan additionally attempted to replace hot-path loads of `counters.submitted` with non-atomic rotation counters (`Core.wake_hint`, `Worker.steal_hint`). Measurement at `feat/g3-submitted-replacement@c2ad9ed` showed +1.7% vs pre-G3 — within noise. The measured null result made those changes not worth the added mechanism complexity; they were dropped.

## Measurements

Note: measured during host conditions of load 3-7 and co-tenant `geode` process chewing ~100% CPU. Absolute numbers are host-environment-dependent; the comparison is the useful signal.

- Pre-fix (main `9da9462`) n=10: see `docs/performance/phase-g3-close/paired-remeasure-pre.txt`.
- This branch n=10 (HEAD `43dc226`): see `flood_1m-n10.txt`.
  - flood_1m ops/s: median **383520**, min 359853, max 446600, n=10.

Stress validation: 20× ReleaseFast PASS (see `stress-20x.txt`).

## Why this is worth landing

Even though the measured perf delta is within noise on today's host, the layout fix is a real bug fix: any future perf work that assumes the `Counters` padding is load-bearing would be operating on a false premise. Landing this fix establishes a correct foundation for downstream cacheline-aware changes.

## References

- Full Phase G3 attempt: `docs/superpowers/plans/2026-04-13-phase-g3-submitted-replacement.md`
- G3 close-out with the null-perf finding: `docs/performance/phase-g3-close/SUMMARY.md`
- Audit-trail branch (full G3 attempt): `feat/g3-submitted-replacement`
