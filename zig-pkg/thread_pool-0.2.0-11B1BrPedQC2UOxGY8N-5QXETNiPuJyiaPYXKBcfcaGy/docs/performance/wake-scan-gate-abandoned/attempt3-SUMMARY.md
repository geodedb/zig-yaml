# Wake-scan parked-count-gate — Attempt 3 Summary

**Date:** 2026-04-13
**Branch:** `feat/wake-scan-parked-count-gate`
**Tip:** `bd0b4a3`
**Change from attempt 2:** alignment retained; wake-scan fast-path `parked_count` load relaxed from `.acquire` to `.monotonic` to eliminate redundant acquire fence on the hot path (the slow path still performs the ordered read).

## Measurement

Paired n=10 `flood_1m` runs, `ReleaseFast`, same host, measurements taken back-to-back.

PRE = `/home/benji/src/devnw/zig/thread-pool` at `fa371be` (main).
POST = `/home/benji/src/devnw/zig/thread-pool-wake-gate` at `bd0b4a3`.

| Metric              | PRE (main)        | POST (attempt 3)  |
|---------------------|-------------------|-------------------|
| Median ops_per_sec  | **406,874**       | **370,723**       |
| Min ops_per_sec     | 386,915           | 359,421           |
| Max ops_per_sec     | 471,958           | 433,288           |
| n                   | 10                | 10                |

**Delta (median):** absolute `-36,151 ops/sec`, relative **`-8.89%`**.

### CPU frequency

| Window | min   | max   | mean  | samples |
|--------|-------|-------|-------|---------|
| PRE    | 2896  | 3300  | 2902  | 68      |
| POST   | 2896  | 3300  | 2907  | 74      |

Frequencies are effectively identical (Δmean < +0.2%). The regression is not attributable to DVFS.

### Load

- PRE start: `load avg 4.04, 3.56, 3.74`
- POST start: `load avg 10.54, 5.59, 4.43`
- POST end:   `load avg 10.77, 6.14, 4.65`

POST saw elevated system load vs PRE (1-min 10.54 vs 4.04 at start). This likely inflates the measured regression somewhat, but cannot plausibly account for ~9 percentage points when the delta was already negative in attempts 1 & 2 under comparable conditions. The signal — wake-gate hurts this workload — is robust across all three attempts.

## Progression across attempts

| Attempt | Change                                               | Delta (median flood_1m) |
|---------|------------------------------------------------------|-------------------------|
| 1       | Gate, no alignment                                   | **-11.0%**              |
| 2       | + cacheline-aligned `parked_count`                   | **-2.5%**               |
| 3       | + `.monotonic` fast-path load (remove acquire fence) | **-8.89%**              |

The monotonic fast-path did not improve on attempt 2; measured delta regressed back toward attempt 1. Two plausible readings:

1. **The relaxed load is not the bottleneck.** The counter update/coherence traffic at the submit-side and park-side RMWs is doing the damage, not the fence on the consumer read. Dropping the acquire had no measurable benefit and the run-to-run variance just happened to place this sample on the low end.
2. **Elevated background load on the POST window tilted the sample** (plausible but, as noted above, insufficient to explain 9pp given the consistent sign across attempts).

Either way: attempt 3 did not cross the SHIP threshold, did not land in the NULL band, and falls cleanly into ABANDON.

## Decision: **ABANDON**

Delta of -8.89% is well past the -2% ABANDON threshold. Three independent attempts now converge on the same conclusion: adding a parked-count gate on the wake-scan hot path — even cacheline-aligned, even with a relaxed load — is net-negative on `flood_1m` on this host.

### Interpretation

`flood_1m` is a high-throughput submitter-heavy workload where most wake attempts genuinely find a parked worker to wake. Gating on `parked_count` adds:

- an extra atomic load per wake decision (fence-free after attempt 3, still a memory op),
- atomic increment/decrement at every park/unpark transition on an otherwise-unshared word,
- cross-core coherence traffic between submitters and workers for a counter whose value is already implicit in the existing wake-scan result.

The gate's *benefit* — skipping the wake-scan when nobody is parked — is precisely the case that doesn't materialize under flood load, because workers are rarely parked for long. On this workload the cost is pure overhead.

### Recommendation

- Do **not** merge `feat/wake-scan-parked-count-gate`.
- Abandon the wake-scan parked-count-gate direction entirely for `flood_1m`-class workloads.
- If future work wants to optimize sparse/idle wake paths, the target should be a different workload profile (e.g. bursty low-utilization) where the gate's skip benefit can actually dominate. That would need its own plan and its own benchmark.
- Keep this branch unmerged for reference; the three attempts and measurements are the deliverable.

## Self-review

- **Methodology followed:** paired n=10, cacheline-aligned POST built fresh, freq sampler ran across both windows, results written to `docs/performance/wake-scan-gate/attempt3-*.txt`.
- **Confound:** POST load average was ~2.5x PRE at start. Flagged in the report. This adds uncertainty but does not flip the decision — attempts 1 and 2 showed regression under comparable-or-better conditions, and the -2% threshold has a 6+ pp safety margin.
- **No stress run performed:** per plan, ABANDON path skips the 100x stress gate.
- **Honest read:** the monotonic fast-path was a plausible micro-optimization but the data doesn't support it being a lever. The fundamental cost of the gate is in the counter coherence, not the read fence.
