# Audit — Baseline Validity of 2026-04-13 Re-Profile Measurements

**Date:** 2026-04-14
**Trigger:** 2026-04-14 paired baseline (post-`geode` stop) confirmed the 566K morning median is not reproducible. Mean today ≈ 414K with cluster at 363-412K. This audit reviews which conclusions from the 2026-04-13 re-profile and downstream investigations remain valid, and which need re-measurement.

## Timeline reconstruction (file mtimes)

| Time (EDT) | Event | Median flood_1m |
|---|---|---|
| 14:36 | Baseline (`baseline.txt`, `3506b29`) | **566K** (n=10) |
| 15:20 | A/B: submitted.fetchAdd stub (`ab-submitted-raw.txt`) | 803K |
| 19:55 | A/B: descriptor CAS stub (`ab-descriptor-raw.txt`) | 485K |
| 20:03 | A/B: wake-scan stub (`ab-wake-scan-raw.txt`) | 763K |

The "morning baseline" framing in the wrap-up doc is **wrong on two counts**:

1. Baseline was at 14:36, **not morning**. Mid-afternoon.
2. Even at 14:36, baseline.txt had two outlier runs (run 6: 401K, run 7: 483K) — meaning host transients existed BEFORE the late-evening drift. The 566K is the median of a noisy n=10, not a stable steady-state.

## Baseline.txt anatomy

n=10 at 14:36, sorted: **401K, 483K, 556K, 559K, 564K, 569K, 572K, 575K, 583K** (one duplicate 568K). Cluster of 8 runs in 556–583K, two outliers (~17%, ~14% below cluster).

Today's n=10 (post-geode, `b12203b` source-equivalent), sorted: **363K, 369K, 374K, 376K, 386K, 390K, 411K, 412K, 521K, 534K**. Cluster of 8 runs in 363–412K, two HIGH outliers (likely cold-cache fast paths on early runs of fresh process state).

**Distribution shape is the same** (tight cluster + 2 outliers), but the cluster has shifted DOWN ~30%. The 566K cluster has not been observed today regardless of geode state.

## Per-conclusion audit

### G3 / submitted.fetchAdd ceiling: +42%

- A/B at 15:20, **44 minutes after baseline**. Same conditions plausible.
- Stubbed n=10: min 657K, median 803K, max 1027K. Every stubbed run (including min) beat the baseline median by ≥16%.
- **Verdict on relative lift: VALID.** +42% is a robust between-version comparison taken under similar host conditions.
- **Verdict on absolute prediction:** the 803K stubbed median is not reproducible today — same drift that lowered baseline 566K → ~390K would lower the stubbed median proportionally to ~565K. The RELATIVE lift carries; the ABSOLUTE number does not.
- **Verdict on the abandoned G3 real-impl attempt (+1.7% paired same-session):** VALID. The real implementation traded old-cacheline reads for new-cacheline reads (Core.wake_hint, Worker.steal_hint). That is a structural finding independent of host state. The +1.7% is the actual achievable real-impl lift; the +42% is a ceiling we cannot reach without restructuring more than a single atomic.

### Descriptor CAS: -14% under load

- A/B at 19:55, **5h 19min after baseline**. SUMMARY explicitly flags as suspect: "Under-load measurement is noise."
- Stubbed median 485K (BELOW baseline 566K).
- **Verdict: PRE-FLAGGED AS NOISE; conclusion to deprioritize was already mechanism-based, not measurement-based.** No action needed. Stands.

### Wake-scan: +34.8% (under host load 22-30)

- A/B at 20:03, **5h 27min after baseline**. SUMMARY explicitly notes: "the baseline was collected before the current geode spike. This biases toward UNDER-estimating the stubbed lift."
- Stubbed n=10: min 573K, median 763K, max 875K. Notable: **min 573K is barely above baseline median 566K** (+1.2%). Most of the lift is concentrated in the upper-quartile runs.
- **Verdict on relative lift: PARTIALLY CONFOUNDED.** The +34.8% comparison crosses host states (clean baseline vs drifted stub). The direction (positive) is clear — the stub did improve over baseline by some margin. The magnitude is unreliable: the gap could be smaller (if stub got lucky with quieter intervals during the late-evening run) OR larger (if drift was suppressing the stub more than baseline). Cannot disambiguate without re-measurement.
- **Verdict on the abandoned wake-gate paired same-session attempts:** VALID. The 3 attempts (basic, cacheline-aligned, aligned+monotonic) all measured against fresh same-session baselines and all regressed (-11%, -2.5%, -8.9%). Those PAIRED conclusions are independent of the 566K reference.
- **Action item:** if wake-scan redesign is revisited, the +34.8% ceiling should be re-measured against a same-session baseline before locking in design intent. The original ceiling number should not be cited as evidence of available lift.

### Compound estimate: 820K-950K realistic ceiling

- Compounded G3 (+42%) and wake-scan (+34.8%) with 50% cannibalization assumption, against the 566K baseline.
- **Verdict: DOUBLY UNRELIABLE.** Both inputs are confounded (G3 absolute is unreproducible today, wake-scan +34.8% is host-confounded), and the cannibalization assumption (50%) was stated as a guess.
- **Action item:** stop citing the 820K-950K range. If a successor estimate is needed, use today's same-session baseline (~390-414K) and an updated combined-stub measurement.

### Tokio gap accounting: 5-15M target, 4.5-14× gap

- Computed gap from 566K current → Tokio target.
- **Verdict: UNDER-STATED if 390-414K is the real steady-state.** Real gap is closer to 12-38× from today's measurement.
- **Implication:** the conclusion ("architectural changes needed; single-atomic isn't enough") is **strengthened**, not weakened, by the corrected baseline. The decision to pivot away from single-atomic optimization was sound.

### Wrap-up doc claim: "single-atomic surface appears exhausted"

- Based on PAIRED same-session results: G3 real-impl null (+1.7%), wake-gate 3 paired regressions, descriptor CAS deprioritized on mechanism.
- **Verdict: VALID.** All three component conclusions are paired same-session and independent of the 566K reference. The "exhausted" claim stands.

## Drift cause: corrections to the wrap-up doc

The wrap-up doc attributed the drift primarily to the `geode` co-tenant. The 2026-04-14 evidence:

| Variable | With geode | Without geode | Conclusion |
|---|---|---|---|
| Mean flood_1m (n=10) | 392K | 414K | ~5% improvement, within noise |
| Median flood_1m | 392K | 388K | Essentially unchanged |
| 566K reproducibility | No | No | Geode was NOT the gating cause |

**Real drift suspects (post-audit):**

- 4-day uptime — kernel state, transparent hugepage fragmentation, page cache pollution, scheduler statistics buildup. Cannot be reset without reboot.
- Long-lived user processes — 4 active claude sessions + multiple node processes from prior agent runs collectively consume ~25% CPU before any benchmark begins. These compete with the bench's 56-worker fan-out for CPU time.
- The morning baseline's own 2/10 outliers (401K, 483K) suggest the "stable 566K" was always a metastable state, not a robust steady-state. A reboot might recover it; might not.

## Recommendations carried forward to Option 3 work

1. **Use today's paired same-session baseline (~414K) as the reference for any A/B work.** Do not cite 566K as the reference for new measurements.
2. **Express all Option 3 perf claims as RELATIVE deltas vs paired same-session baseline taken in the same hour.** Absolute numbers should be reported but not load-bearing for go/no-go decisions.
3. **Don't pursue wake-scan redesign on the strength of the +34.8% A/B alone.** Re-measure under same-session conditions before designing.
4. **Don't pursue any single-atomic optimization.** The "single-atomic surface exhausted" conclusion is the most robust finding from the prior session and remains valid.
5. **Do not assume reboot recovers 566K.** It might (clearing kernel state); it might not (if drift was always intermittent). Treat 414K as the new steady-state until evidence proves otherwise.

## Files reviewed

- `docs/performance/reprofile-2026-04-13/baseline.txt` — raw n=10
- `docs/performance/reprofile-2026-04-13/SUMMARY.md` — top-line conclusions
- `docs/performance/reprofile-2026-04-13/ab-submitted-fetchadd.md` — G3 A/B
- `docs/performance/reprofile-2026-04-13/ab-wake-scan.md` — wake-scan A/B
- `docs/performance/reprofile-2026-04-13/ab-descriptor-cas.md` — descriptor CAS A/B (skim only; pre-flagged as noise)
- `docs/superpowers/plans/2026-04-13-session-wrap-up-and-next-steps.md` — synthesis doc
- `docs/performance/wake-scan-gate-abandoned/README.md` — paired wake-gate results (cited, not re-read)

## Files NOT audited (not in scope of this audit)

- The Phase H docs and post-mortem — Phase H is correctness work, not a perf claim, so baseline drift doesn't affect its validity.
- The Counters layout fix close-out — also correctness work.
- The `2026-04-11-*` plans (lock-free freelist, chase-lev, event-wakeup, lock-free inject queue) — those are architectural plans whose ceilings haven't been measured against this baseline.
