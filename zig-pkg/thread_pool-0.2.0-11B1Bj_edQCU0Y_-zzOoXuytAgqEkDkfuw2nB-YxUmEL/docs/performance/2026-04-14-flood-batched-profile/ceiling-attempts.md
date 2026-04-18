# Steal-Peek Bottleneck — Ceiling Attempts

**Parent:** `README.md` (profile identifying 43.79% worker self-time
in `LocalQueue.len` from victim-peek).
**Baseline:** `172f2db` (post-profile commit; = `36aaa04` codewise).
**Method:** paired n=10 BSSB A/B (20 samples per arm), same-session,
same host.
**Gate (README):** ≥+15% flood_1m_batched CLEAN → land; +5%..+15% →
land if contended_spawn_8x doesn't regress; <+5% → shelf.

## Ceiling 1: `.acquire` → `.monotonic` on peek loads

**Hypothesis:** Memory-fence cost on acquire loads contributes to
the 43.79% hotspot.

**Stub:** `src/queue/ring_queue.zig` — demote both `head.load` and
`tail.load` in `RingQueue.len()` from `.acquire` to `.monotonic`.

**Result:**

| Scenario | Baseline median | Stub median | Δ | Sep |
|---|---:|---:|---:|:---|
| flood_1m | 387,574 | 393,247 | +1.5% | overlap |
| flood_1m_batched | 924,598 | 934,184 | +1.0% | overlap |
| contended_spawn_8x | 647,116 | 633,756 | -2.1% | overlap |
| contended_spawn_8x_batched | 648,041 | 656,950 | +1.4% | overlap |

**Verdict:** below the +5% shelf threshold on every scenario —
statistical noise. **Closed.**

**Why it failed:** On x86 (this host's Xeon E5-2680 v4), aligned
u32 `load .acquire` and `load .monotonic` emit the same machine
instruction (plain `MOV`) — Intel's TSO memory model makes every
load acquire-by-default. There is no fence to remove. The 43.79%
is pure cacheline-coherence cost, unaffected by the ordering mode.
This would matter on ARM/Power but not here.

Raw: `ceiling1_monotonic_peek_raw.txt`.

## Ceiling 2: probe cap at K=8 victims

**Hypothesis:** Reducing the probe count from 55 → 8 per `nextTask`
steal pass cuts coherence traffic ~7×; worker parking cost is less
than the saved coherence.

**Stub:** `src/pool.zig` — change the steal loop from iterating
`self.workers.len` victims to `@min(8, self.workers.len)`. If all 8
probes miss, fall through to `steal_failures` and return null
(worker parks).

**Result:**

| Scenario | Baseline median | Stub median | Δ | Sep |
|---|---:|---:|---:|:---|
| flood_1m | 398,049 | 403,138 | +1.3% | overlap |
| flood_1m_batched | 926,266 | 894,159 | **-3.5%** | overlap (negative) |
| contended_spawn_8x | 646,476 | 724,156 | **+12.0%** | **CLEAN** |
| contended_spawn_8x_batched | 673,289 | 574,165 | **-14.7%** | **CLEAN (negative)** |

**Verdict:** Directly **FAILS the gate** — primary target
flood_1m_batched trends negative (-3.5% overlap) and
contended_spawn_8x_batched takes a **-14.7% CLEAN regression**.
The +12% CLEAN on contended_spawn_8x is real but cannot offset
two negatives. **Closed.**

**Why it failed:** The probe cap trades coherence cost for park
latency. Parking too eagerly causes workers to miss work that
existed on victim indices 8..55. For `contended_spawn_8x_batched`
specifically (8 submitters × 64-task batches), work arrives in
concentrated bursts across all submitter-side locality — a 14%
probe coverage isn't enough to find it before the submitter has
moved on, so workers park → re-wake churn.

The fact that the two scenarios with `_batched` (concentrated
bursts) both degraded while the non-batched (spread) both helped
tells us probe-cap is a **scenario-specific win**, not a universal
one. Any future probe-cap work must adapt K based on workload
shape — which is itself expensive state.

Raw: `ceiling2_probe_cap_raw.txt`.

## What both ceilings confirm

1. The 43.79% cost **is** cacheline coherence on victim peeks —
   Ceiling 1 proved it's not fence cost.
2. Reducing probe count naively **trades throughput across
   scenarios** rather than winning universally — Ceiling 2 proved
   the missed-work cost outweighs the saved coherence cost for
   concentrated-burst workloads.

## Remaining attacks (ranked, not pursued)

Per `README.md` candidate list:

- **#3 (per-socket non-empty bitmap).** Owners set/clear a bit on
  len 0↔1 transitions. Stealers read 1 u64 to find K candidate
  victims. Collapses 55 probes to 1 read. High implementation
  cost, possibly NUMA-aware bitmap partitioning. This is the next
  direction if picked up.
- **#4 (co-locate head/tail for peek-only reads).** Today they're
  on separate cachelines for write-side isolation. For peek reads,
  pack them into one u64 (head:u32, tail:u32) read atomically.
  Needs duplication: owner writes both lines + the packed
  peek-cache. Medium implementation cost. Probably smaller win
  than #3 since the second load in the peek is the cheap one once
  the first line's miss has stalled.
- **#5 (probe-free: skip peek, just steal).** Would work if
  `stealHalf` on empty could bail without its own 2 acquire loads
  — but it does the same pair internally. No structural win.

## Gate decision summary

Both ceilings FAIL their gates. The direction is **pivoting** —
not closed. Future work on flood_1m_batched must attack the
victim-peek coherence via a structural change (attack #3 or #4)
rather than micro-tuning the per-probe load cost or probe count.

## Files

- `ceiling1_monotonic_peek_raw.txt` — n=10 paired A/B raw output
- `ceiling2_probe_cap_raw.txt` — n=10 paired A/B raw output
- No source changes landed; both stubs reverted immediately post-
  measurement.
