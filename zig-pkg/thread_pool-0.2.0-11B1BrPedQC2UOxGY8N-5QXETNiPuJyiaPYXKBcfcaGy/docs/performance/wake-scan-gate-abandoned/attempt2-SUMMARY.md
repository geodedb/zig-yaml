# Wake-Scan Parked-Count Gate — Attempt 2 (cacheline-aligned)

## Result

| Measurement | Median | Min | Max | n |
|---|---|---|---|---|
| PRE-gate (main `fa371be`) | 395352 ops/s | 368753 | 477850 | 10 |
| POST-gate attempt2 (`2b590bf`) | 385489 ops/s | 360324 | 513962 | 10 |

**Delta:** -2.49% relative, -9863 ops/s absolute.

**Vs attempt 1:** attempt 1 was -11.0%. Delta improvement from cacheline alignment: ~8.5pp (regression shrank from -11.0% to -2.49%).

**Decision:** REGRESSION (still below the -2% abandon threshold, though by a narrow margin).

## CPU freq

- PRE: min 2896 / mean 2914 / max 3300 MHz (n=70)
- POST: min 2896 / mean 2912 / max 3300 MHz (n=73)

Freq delta: -2 MHz mean (0.07%). Negligible — cannot explain the -2.49% ops/s delta.

## Fix applied

`Sync.parked_count: std.atomic.Value(u32) align(std.atomic.cache_line) = ...` at `src/pool.zig:226`. Isolates worker-side fetchAdd/Sub from any other hot Sync field. Commit `2b590bf`.

The alignment did substantially mitigate false-sharing — attempt 1 was -11.0%, attempt 2 is -2.49%. But the approach still loses ~2.5% on flood_1m, which is outside the acceptable envelope.

## Recommendation

Abandon the parked-count-gate approach on this branch. The residual -2.49% is consistent across the paired measurement and is not explained by CPU frequency drift. Most plausible remaining causes:

1. The extra atomic load on the wake-scan submit fast path still adds latency even with the cacheline-isolated counter.
2. Worker-side fetchAdd/Sub on a dedicated cacheline shifts contention onto the counter's own line (many workers park/unpark in flood_1m), trading submit-side false-sharing for worker-side counter contention.
3. The gate semantics may be suppressing otherwise-useful wakes in hot flood conditions, lengthening tail latency in a way ops_per_sec picks up.

Next action: do NOT merge `feat/wake-scan-parked-count-gate`. Return to the wake-scan redesign plan and triage a different gate primitive (e.g., a worker-local "I'm parked" flag checked only when the submit thread already has a Core reference, avoiding the shared counter entirely).
