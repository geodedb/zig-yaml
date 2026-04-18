# Inject-Queue Head Contention — Attack Design

**Parent profile:** `docs/performance/2026-04-14-flood-batched-profile-v2/`
**Root cause:** `BoundedRing.popMany` at 16.64% worker self-time;
13.43% pure atomic loads on `inject_queue.head` and per-slot
`sequence` cachelines. 56 workers concurrently attempt popMany on
the single central inject queue; 1 winner per head-CAS, 55 losers
return 0 after burning head+tail+cmpxchg coherence traffic.
**Blocked attacks:** Option B sharded inject (regressed -7.6%),
bitmap-steal-before-popMany reorder (SIGSEGV in shutdown stress).

## Constraints this must satisfy

1. No regression on contended_spawn_8x (+17% CLEAN from bitmap).
2. No stress regression — especially in shutdown drain paths
   (cancelQueuedTasks interacts with inject + local queues).
3. Ceiling gate: ≥+15% flood_1m_batched CLEAN or ≥+5..+15% with
   no other CLEAN regression.

## Option A — Inject-nonempty producer flag

**Design:**

- Add `Core.inject_nonempty: std.atomic.Value(u8)` aligned, set
  to 1 on producer's successful `tryPush`, cleared to 0 when a
  consumer's `popMany` returns 0 after a successful head-CAS
  (consumer observed empty under exclusion).
- Consumer reads flag BEFORE popMany. If 0, skip popMany entirely
  (no head/tail/CAS).

**Cost when inject empty:** 1 atomic load (flag). Saves 2 shared
loads + 1 failed CAS per consumer nextTask.

**Cost when inject non-empty:** Identical to today (no skip).

**Correctness:** Stale flag=1 with empty queue → consumer calls
popMany, which returns 0 (today's behavior). Stale flag=0 with
work in queue → consumer skips popMany, will retry next nextTask
call when producer re-sets flag. Racy window bounded by
producer's flag store being `.release` and consumer's `.acquire`:
any slot committed before the flag store is visible to any
consumer that reads flag=1 and does popMany. Producers that push
after consumer's flag=0 read set flag=1 on their own push — next
consumer pass will see it.

**Fit for flood_1m_batched:** Poor. Inject is never empty under
saturation; flag is always 1; no skip triggered. **Won't clear
the gate.**

**Fit for other scenarios:** Good — contended_spawn_8x and
flood_1m have longer inject-empty windows where consumers avoid
the 2 shared loads.

**Risk:** Low. No reorder, no shutdown interaction.

**Verdict:** LAND if it's measurable on any scenario without
regressing others. But treat as a generic optimization, not a
flood_1m_batched fix.

### Option A — CLOSED 2026-04-15 (tried, failed)

Implemented clear-and-recheck variant (producer conditional set,
consumer clears on popMany=0, double-check popMany to close race).
Stress (`zig build test-stress`, ReleaseFast) ran >5 min vs HEAD's
~3.7 s — 30–60× slowdown.

**Root cause:** `popMany` returns 0 for two reasons — (1) queue
genuinely empty at snapshot, (2) CAS lost to a competing consumer.
Case (2) leaves the queue non-empty. The consumer-clear path
treated both identically, writing flag=0 under heavy contention
where CAS-loss is common. With 56 consumers racing, many clears
fired while the queue still held items; other consumers then read
flag=0 and skipped `popMany` entirely, falling through to bitmap-
steal against local queues that (under a batched flood) hadn't yet
had any drain result distributed. Net effect was self-inflicted
serialization: only the popMany winner drained, losers quit the
inject path and starved.

**No-clear variant** (producer set only, no consumer clear) is
stress-clean (3×3 runs within 3.4–4.1 s of HEAD) but trivially
useless: after the first push, flag stays 1 forever, and the
consumer-side flag load degenerates to a guaranteed-true check
that always falls through to today's `popMany`. Zero benefit on
any hot path.

**Why the recheck didn't save it:** The recheck popMany on the
*same* consumer does eventually drain the items, but only after
the flag was already cleared. During the window between
store-flag-0 and the recheck, *other* consumers' flag loads
observe 0 and skip. Under high-rate production (e.g.
`flood_1m_batched` pushing 64-item batches), that window is wide
enough that dozens of workers quit the inject path per clear, and
the next producer's conditional set doesn't fire fast enough to
re-open it before they park or bitmap-steal into emptiness.

**What would be required to make A work:** Distinguish true-empty
from CAS-lost inside `popMany` (new return signal) so the consumer
only clears flag on true-empty. That is effectively a `popMany`
API change and was not pursued. No-clear-only variant was also
evaluated and rejected as zero-benefit.

## Option B — FetchAdd-based head reservation

**Design sketch:**

Replace `head.cmpxchgStrong(head, head+take)` with
`head.fetchAdd(take)`. fetchAdd returns pre-add value; every
caller wins.

**Fatal issue:** Unconditional fetchAdd can over-claim past tail
(consumer claims 32 slots when queue has 5). Over-claimed slots
don't get drained; next producer push expects `seq == tail` but
finds `seq == old_seq` (from last cycle's producer) — push
stalls. Plus head is moved past real data, so future consumers
skip valid items.

**Rollback variants:**

1. After fetchAdd, load tail. If `reserved_end > tail`, truncate
   and `head.fetchSub` the excess. Fetch-sub race with other
   consumers' fetchAdd ordering is hazardous; creates a window
   where head < actual_consumed which breaks producer's
   `tail - head < capacity` invariant.
2. "Claimed" counter separate from "head" counter; head lags
   claimed until slots are physically drained. Requires a
   redesign of BoundedRing's 3-counter invariant (head/tail/seq).
   Too invasive for a speculative win.

**Verdict:** CLOSED. fetchAdd doesn't cleanly map onto BoundedRing
semantics; no safe reduction of head contention this way.

## Option C — Single-drainer by wake target

**Design:**

Submitter's `notifySubmits` wakes exactly one worker (already
the design) and sets that worker's `is_drain_target: u8 = 1`.
Only workers with `is_drain_target == 1` attempt inject popMany
in their nextTask; others skip. Drainer clears their flag on
successful drain and pushes stolen items to local; peers steal
via bitmap.

**Benefits:**

- At most 1-2 workers call popMany at any moment (the most
  recently woken + transient hand-offs). Head contention drops
  from 55-way to 1-way.
- Peers use bitmap-steal only — matches today's cheap path.

**Correctness issues:**

1. If drainer is busy (executing a long task) while inject fills,
   no one drains → queue backs up → producer blocks on
   backpressure. Mitigation: any worker whose bitmap-steal
   fails K times claims drainer role by CAS on a
   `drainer_worker_index: u32`. Adds complexity.
2. Shutdown: `cancelQueuedTasks` iterates inject independently
   of drainer flag. Should be safe as long as workers also check
   shutdown state and bail out of popMany.
3. Wake target changing mid-execution: if a worker parks before
   draining, drainer flag leaks. Need to clear on park path.

**Verdict:** HIGH CEILING but high implementation complexity.
Worth pursuing AFTER Option F fails, because F is cheaper to try.

## Option D — Original v2 README candidate (drain-before-park only)

**Design:** popMany runs only as the last step before park (after
bitmap-steal fails). Essentially the reorder attack that broke
stress — but with explicit shutdown synchronization.

**Why it broke (unrecovered):** Unknown — suspected
cancelQueuedTasks race with bitmap-steal exposed a pre-existing
latent bug. Need post-mortem before retrying.

**Verdict:** BLOCKED on understanding the SIGSEGV root cause.
Defer until someone captures a core dump.

## Option E — Inject depth hint (atomic counter)

Variant of A using a `u64` counter instead of a boolean flag.
Producer fetchAdds, consumer fetchSubs. Enables "is there at
least K items" checks. More flexible than A but also more
write-contention (producer writes every push; consumer writes
every drain). On write-heavy workloads this new line becomes a
new bottleneck. **Verdict:** Dominated by A for the empty-skip
use case.

## Option F — Worker-local popMany rate limiter

**Design:**

Each worker maintains a thread-local `nextTask_local_empty_count:
usize` (no atomic). Incremented when `popBottom` returns null.
Only when `(count & 3) == 0` does the worker attempt inject
popMany; on other iterations it skips straight to bitmap-steal.

**Cost:** One usize increment per nextTask local-empty. Zero
atomic overhead.

**Benefit:** 4× reduction in popMany calls → 4× reduction in
head-CAS race. 55-way contention → 14-way contention (still bad
but measurable).

**Risk:** Tasks in inject wait longer to be drained. If submitter
pushes faster than 14 drainers × 32-per-drain rate, queue backs
up. At 1M tasks/sec, drain rate needed ~1M/sec. Current drain
rate is ~50 drain-successes per second × 56 workers × 32 items
= saturated. Rate-limited: 50 × 14 × 32 = 22k drain-successes/sec
vs 1M needed. Wait, that doesn't match... let me reconsider.

Actually, "drain rate" per second across all workers combined
must equal the submitter's push rate. If we have 56 workers each
capable of 1M popMany attempts/sec and 1 wins per attempt round,
effective drain rate is governed by submitter. Rate limiting
consumers doesn't reduce the drain rate if even 1 worker polls
frequently — it just shifts contention.

Hmm, actually the rate limit is per-worker. If each worker drops
3/4 of popMany calls, total popMany rate drops 4×. But the
winners still drain 32 items each. If each winner takes 32 items,
50 wins/sec per worker = 56 × 50 × 32 = 90k items/sec. Need 1M.
Not enough by 10×.

Unless the CURRENT drain rate is much higher than 50 wins/sec
per worker. Let me reason: at 1M tasks/sec, items drained/sec
must be 1M. If winner takes 32 items, needs 31k wins/sec total.
Divided by 56 workers = 560 wins/sec per worker. Attempts much
higher (due to losers). Say 10x → 5600 attempts/sec per worker.

With rate-limit 1/4: 5600/4 = 1400 attempts/sec per worker →
1400/10 = 140 wins/sec per worker → 140 × 56 × 32 = 250k items/
sec. Still below 1M.

So rate-limiting by 4× drops drain throughput ~4× too. Queue
backs up, producer blocks on backpressure. Not viable for
flood_1m_batched.

**Unless:** the rate-limit reduces CONTENTION enough that the
remaining calls win at higher rate (fewer losers to CAS-race
against). That's the bet. 14-way contention is much easier to
win than 55-way.

With 14-way contention instead of 55, CAS success rate per
attempt might be 14x higher. So drain rate could stay the same
OR increase. Net win.

But this is speculative without a measurement.

**Verdict:** Quick to implement (~20 lines). Cheap experiment.
TRY IT.

## Option G — Longer drain batch

Change `inject_batch_size` from 32 → 64 or 128. Winners drain
more per call → fewer total popMany calls needed. Contention
drops proportionally.

**Risk:** Larger batches mean more per-slot sequence spinning
during popMany's fill loop (producer may not have written all 64
slots yet). Could increase spin cost enough to offset contention
savings.

**Verdict:** Trivial to test (1-line config change). Include as
a quick measurement alongside F.

## Recommended next step

1. **Measure Option G** (inject_batch_size bump) first — 1-line
   change, immediate signal whether batch-size-vs-contention is
   a productive axis.
2. If G wins: also try Option F (rate-limited popMany) to see if
   they stack.
3. If neither: escalate to Option C (single-drainer by wake
   target), with explicit design for shutdown synchronization.
4. Revisit Option D (post-mortem the SIGSEGV) if we need to
   understand the shutdown race independent of optimization.

As of 2026-04-15: Options B, F, G, A all tried and closed. D is
blocked on SIGSEGV root cause. C is the only remaining viable
candidate and requires a design-first approach (no more code
without an explicit shutdown-synchronization plan). E is
dominated.

## Measurement plan (for any attack)

- n=10 BSSB paired A/B vs current main (`5f50106`).
- `zig build test` + `zig build test-stress` 5× before A/B.
- Full scenario matrix: flood_1m, flood_1m_batched,
  contended_spawn_8x, contended_spawn_8x_batched.
- Gate: ≥+15% flood_1m_batched CLEAN → land; +5..+15% with no
  CLEAN regression → land; otherwise document as closed ceiling.

## Iteration 4 (2026-04-15) — Option D CLOSED under gen-tag

With the gen-tagged queue entries fix landed at `85f0aaa`, the
SIGSEGV prerequisite noted for Option D was resolved. Iter 4
retried the bare reorder (bitmap-steal before inject-drain).

**Stress:** 20/20 PASS at `-Doptimize=ReleaseFast` (one run in a
first pass hit a 120s outer `timeout` ceiling — not an assertion
failure; on the second pass with 180s ceiling, 20/20 PASS under
wall-clock).

**Performance (n=10 paired BSSB medians):**

| Scenario                   | A (main 85f0aaa) | B (Option D) | Δ        |
|----------------------------|------------------|--------------|----------|
| flood_1m                   | 372,796          | 373,568      | +0.2%    |
| **flood_1m_batched**       | **805,655**      | **775,165**  | **-3.8%**|
| contended_spawn_8x         | 709,153          | 757,562      | +6.8%    |
| contended_spawn_8x_batched | 642,339          | 683,812      | +6.4%    |

**Verdict:** Headline flood_1m_batched **regresses 3.8%** vs the
+15% gate. Contended scenarios gain ~+6-7% but not enough to
offset the regression on the primary target.

**Why the regression** (hypothesis): under reorder, fewer workers
drain inject via popMany but more workers contend on a single
victim's SPMC top (stealHalf CAS). In `flood_1m_batched` the
injector is an external submitter and workers otherwise have empty
locals, so bitmap-steal-first concentrates N-1 stealers on
whoever just drained — converting MPMC inject contention into
SPMC steal contention with worse amortization (popMany batches 32,
stealHalf only (len+1)/2). Inject's MPMC head with popMany batch=32
absorbs the 56-worker contention better than one victim's top
with steal_batch_size=8.

**Status:** Option D CLOSED. Reorder is not a productive axis for
flood_1m_batched. Options F (rate limiter) and a new "sharded
inject" variant remain as open candidates.

## Iteration 5 (2026-04-15) — Option G CLOSED

Bumped `inject_batch_size` default 32 → 64 and widened the
popMany buf in `nextTask` to `[64]QueueEntry`. Post-gen-tag,
this is the simplest remaining attack on the 16.64% popMany
hotspot.

**Stress:** 20/20 PASS at `-Doptimize=ReleaseFast` (180s
outer-timeout).

**Performance (n=10 paired BSSB, medians):**

| Scenario                   | A (main 5d8c46f) | B (batch=64) | Δ        |
|----------------------------|------------------|--------------|----------|
| flood_1m                   | 381,611          | 366,874      | **-3.9%**|
| flood_1m_batched           | 813,090          | 829,436      | +2.0%    |
| contended_spawn_8x         | 715,031          | 742,470      | +3.8%    |
| contended_spawn_8x_batched | 632,406          | 607,817      | **-3.9%**|

**Verdict:** `flood_1m_batched` +2.0% is well below the +15%
gate. Two regressions on `flood_1m` and `contended_spawn_8x_batched`
on top of it. Mixed signal; closing without landing.

**Hypothesis for the non-win:** If popMany's self-time was
dominated by CAS contention, bigger batches (fewer calls) should
have reduced that linearly. That didn't happen. Likely the
dominant cost in popMany is either:

- sequence-spin waits (producer hasn't finished writing the slot
  yet) — bigger batches widen this window
- cacheline misses on the slot reads themselves — bigger batches
  mean more misses per call, not fewer

Either would explain why bumping the batch size doesn't help.

**Status:** Option G CLOSED. Combined with Option D closure
(iter 4), both straightforward attacks on the popMany hotspot
have failed. Next iteration should **re-profile post-gen-tag**
before picking the next attack — the widening from u32 to u64
queue slots may have shifted where the time goes. After that,
either sharded-inject (high ceiling, big change) or an
unrelated hotspot surfaced by the fresh profile.
