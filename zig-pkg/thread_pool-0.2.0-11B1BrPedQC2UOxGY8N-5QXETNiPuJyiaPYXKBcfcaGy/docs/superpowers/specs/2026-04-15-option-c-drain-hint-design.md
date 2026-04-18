# Option C — Drain-Hint Ordering (Design)

**Parent brainstorm:** `docs/superpowers/brainstorms/2026-04-15-inject-head-contention.md`
**Target hotspot:** `BoundedRing.popMany` at 16.64% worker self-time;
13.43% pure atomic loads on `inject_queue.head` and per-slot
`sequence` cachelines (v2 profile 2026-04-14).
**Status:** CLOSED 2026-04-15 — implementation passed unit tests
but SIGSEGV'd in `test-stress` `phase h: double-dequeue race
reproducer` at ~15% rate (2/13 ReleaseFast runs). Same failure
signature as Option D's blocked reorder. See "Failure mode" at
bottom of this doc.

## Intent

Replace today's "every worker tries `popMany` every `nextTask`
iteration" (→ 56-way head-CAS contention) with a *hint-based*
ordering:

1. Only the worker the submitter *just woke* is expected to drain
   the inject queue on its next `nextTask` pass.
2. Non-hinted workers bitmap-steal from peers first; they fall back
   to `popMany` only if bitmap-steal returns nothing.

Under saturation this makes inject-queue head contention 1-way
most of the time; it becomes N-way only when the pool has drained
all distributed work and multiple workers simultaneously fall
through to the `popMany` fallback — i.e. precisely the moments
where contention is cheap because there's nothing else to do.

## Non-goals

- Not modifying `BoundedRing` semantics or `popMany` API. The hint
  is external: everyone still calls the same unchanged `popMany`.
- Not touching shutdown synchronization. `cancelQueuedTasks`
  continues to drain `inject_queue` via `inject_queue.pop()` under
  `state != .running`; worker's hint logic becomes moot during
  shutdown because the hint is never set while shutdown is pending
  (the only hint writer is `notifySubmits`, gated by `enqueueTask`
  which runs only when `state == .running`).
- Not touching the wake-one-per-notify invariant or the park
  handshake (seq_cst `queued_tasks` + `is_parked` pair).

## Data

Add one field to `Core`:

```zig
/// Latest hint from `notifySubmits` — the index of the worker the
/// submitter just woke (or attempted to). Workers read this in
/// `nextTask` to decide whether to drain inject *before* bitmap-steal
/// (hinted) or only as a fallback (non-hinted). Monotonic store
/// suffices: the hint is advisory; wrong reads degrade to today's
/// behavior (redundant popMany calls), never to a lost item.
/// Initial -1 = "no hint" (pre-first-submit and post-drain).
drain_hint: std.atomic.Value(i32) align(std.atomic.cache_line) =
    std.atomic.Value(i32).init(-1),
```

Own cacheline to avoid false sharing with `workers_nonempty` and
`counters`. Hint is written by the submitter thread (at most one
writer per notify) and read by 56 consumers — low write traffic,
high read traffic: shared-state cacheline with rare invalidations.

## Producer side (`notifySubmits`)

After the existing wake-scan loop, store the last-targeted index.
Two variants considered; prefer V1 for simplicity:

### V1 (preferred)

```zig
var woke_idx: i32 = -1;
while (off < self.workers.len) : (off += 1) {
    const idx = (hint_idx + off) % self.workers.len;
    // ... existing park/signal logic ...
    if (/* signaled */) { woke_idx = @intCast(idx); break; }
}
if (woke_idx >= 0) {
    self.drain_hint.store(woke_idx, .monotonic);
}
```

- If no worker was parked (`woke_idx < 0`), leave the hint stale.
  Rationale: hint staleness only means "some worker other than the
  truly-hinted one will drain" — a mild efficiency loss, not a
  correctness issue. A parked-free pool is already saturated;
  whoever finishes their task first will fall through to the
  fallback `popMany`.
- `.monotonic` because the hint is advisory. If a worker reads a
  stale value, it either (a) is the stale target and drains
  (correct, just not optimal) or (b) is not the target and relies
  on fallback `popMany`. Neither outcome violates safety.

### V2 (rejected)

Clear-hint-on-no-wake (`drain_hint.store(-1)` when `woke_idx < 0`)
makes the hint "definitely fresh or -1." Complicates the reader
and buys nothing: a -1 hint means every worker falls through to
step 5 fallback, which is exactly today's all-workers-popMany
behavior. So clearing is strictly worse than leaving stale.

## Consumer side (`nextTask`)

Current `nextTask` order (work_stealing path):

1. LIFO slot
2. `popBottom` (own local)
3. `popMany` (inject drain)
4. bitmap-steal (peer locals)

Proposed:

1. LIFO slot
2. `popBottom`
3. **IF `drain_hint == worker_index`:** `popMany`. If n > 0, return.
4. bitmap-steal. If success, return.
5. **`popMany` (fallback for non-hinted workers, or hinted-but-empty).**
   If n > 0, return.
6. `steal_failures++`, return null.

Step 3 is the "hinted-first" path: the worker the submitter just
woke attempts inject drain before any peer-steal. Step 5 is the
"everyone else" fallback: after failing bitmap-steal (bitmap read
showed no peer has stealable work), the worker tries inject.

### Why this ordering works

Under `flood_1m_batched` (target scenario):

- Submitter pushes 64-item batch → wakes worker W via notify →
  `drain_hint := W`.
- W runs `nextTask`: step 3 fires (hint matches). `popMany(32)`
  succeeds. W distributes 31 items to its local queue via
  `tryPushBottom`, keeps 1 for itself. Returns.
- W's `markWorkerNonEmpty(W)` flips W's bit in `workers_nonempty`.
- Other workers run `nextTask`: steps 1-2 empty, step 3 skipped
  (hint ≠ their index), step 4 bitmap-steal succeeds (W is set).
  They each stealHalf from W. W's local drains quickly.
- Submitter pushes next 64-item batch → notifySubmits scans for
  parked workers. Most are busy (running tasks they stole from W).
  Woke a different parked worker W' → `drain_hint := W'`.
- Cycle repeats with W' as drainer.

Number of concurrent `popMany` calls per submit batch: 1 (hinted)
if W drains before peers expand — otherwise some fallback calls
once W's local drains. Far below today's 56.

Under `contended_spawn_8x`:

- 8 worker threads spawn tasks *from within* workers. These go to
  the owning worker's LIFO/local queue (step 1-2 of submit), not
  inject.
- Inject queue rarely has items.
- Hint is usually stale or -1. All workers read step 3 false.
- Bitmap-steal dominates (step 4). Fallback `popMany` (step 5) is
  rarely reached and when it is, inject is likely empty.
- Net behavior ≈ today. Expected: neutral.

Under `flood_1m` (unbatched):

- Single submitter, 1 item per push, hint cycles per-submit.
- Hinted worker drains 1 item via popMany. Distributes 0 to local
  (only 1 item, which it runs itself). Nothing to steal.
- Non-hinted workers: step 4 finds empty bitmap (hinted worker's
  local has nothing). Step 5 fallback popMany — may or may not
  find items depending on submitter rate.
- This is the weakest scenario for Option C — the drain-distribute
  pattern is broken (no distribution with batch=1), so non-hinted
  workers must popMany-fallback.
- Expected: neutral to slight win (fallback popMany still has
  contention, but the hinted worker gets a clean drain first).

## Correctness

### No lost wakeups

The park handshake is unchanged:

```text
submitter:  push → queued_tasks.fetchAdd(.seq_cst) → is_parked.load(.seq_cst) → signal
worker:     is_parked.store(.seq_cst) → queued_tasks.load(.seq_cst) → wait
```

The SC total order still guarantees the parking worker either
observes the submitter's `queued_tasks` increment (and bails out)
or the submitter observes `is_parked == 1` (and signals). The
hint is orthogonal — it only affects *which* consumer path the
woken worker takes in `nextTask`, never whether it wakes.

### No stuck items

A stuck item would require all workers to indefinitely skip
`popMany`. That can't happen because:

- A worker only skips step 3's popMany if the hint doesn't match.
- A worker only skips step 5's popMany if step 4 bitmap-steal
  succeeded — i.e. it's making progress, will return, re-enter
  `nextTask`, try again.
- When a worker reaches step 5, it always calls popMany. So the
  fallback guarantees drain under quiescence.

### No races with `cancelQueuedTasks`

`cancelQueuedTasks` drains inject via `inject_queue.pop()` (not
`popMany`). This is already concurrent with worker popMany calls
on HEAD — the ring is MPMC-safe for concurrent consumers. Adding
a hint doesn't change that.

Shutdown path:

- `shutdown(.cancel_pending)` calls `cancelQueuedTasks` first,
  draining inject while `state == .shutdown_requested`.
- Workers still in `nextTask` may hit step 3 or step 5 popMany
  concurrent with shutdown's pop. Both paths call the same ring
  operations — already safe today.
- No worker uses the hint for correctness; the hint never
  transitions a worker into park or into a shutdown-specific
  state. Nothing to synchronize.

### Hint staleness

- Race: submitter stores hint W, worker W' (W' ≠ W) reads hint = W,
  skips step 3. Later reads hint = W' (after later notify)…
  Worker W runs nextTask, reads hint = W, popMany. Fine.
- Race: two submitters race, hint flickers. At most one worker is
  the current hint target at any instant (monotonic store is
  atomic). Worst case: both hint targets drain in parallel — 2-way
  contention. Still far below 56-way.
- Race: worker reads hint = self, commits to step 3, but by the
  time popMany runs, hint has moved. Worker still drains as if
  hinted. Correct behavior — just an extra drainer this cycle.

## Measurement plan

1. `zig build test` (unit) — must pass.
2. `zig build test-stress` 20× (ReleaseFast) — required per
   project measurement rules (submit-path change).
3. Paired n=10 BSSB A/B against `d9f509c` (current main):
    - `flood_1m_batched` — primary gate scenario.
    - `flood_1m` — secondary, check for unbatched regression.
    - `contended_spawn_8x` — regression guard, inject-light.
    - `contended_spawn_8x_batched` — regression guard.
4. Gate:
    - ≥+15% flood_1m_batched CLEAN → land.
    - +5..+15% flood_1m_batched with no CLEAN regression elsewhere
      → land.
    - <+5% or any CLEAN regression → revert and close Option C.

## Rejected variants

### C-sticky — single long-lived drainer

Maintain a `drainer_index` that persists across submits, only
rotating when the current drainer parks or CAS-claims release.
Rejected because it fails the "drainer busy" case: if the
designated drainer is mid-task when inject fills, nobody else
drains and inject backs up to backpressure. The hint-per-notify
design is self-healing because each notify targets a parked (not
busy) worker.

### C-cas-takeover — any worker can CAS-claim drainer role

After K bitmap-steal failures, worker attempts
`drainer_index.cmpxchgStrong(current, self)` and drains on
success. Rejected as redundant with the step-5 fallback — the
fallback already gives non-hinted workers a chance to popMany
under quiescence, with zero CAS overhead.

### C-queue-of-drainers — lock-free queue of candidate drainers

Submitters enqueue indices; drainers dequeue. Rejected as
massively overcomplicated for a contention reduction that the
simpler step-5 fallback already provides.

## Open questions

1. Does monotonic/release-acquire matter for `drain_hint`?
    - Monotonic store on submitter side is safe because the hint
      is a pure hint (no synchronizes-with obligations on the
      *pointed-at worker*). The worker's popMany has its own
      `.acquire` load on inject head/tail for the items themselves.
    - `.acquire` load on consumer side is cheap — single shared
      cacheline, no release paired with it beyond read-my-own-recent.
    - Decision: monotonic store + monotonic load. Revisit if a
      memory-model concern surfaces during implementation.

2. Should the hint be the *woken* worker or the *wake-scan start*?
    - Woken worker (V1 above) is simpler: we know exactly who
      got the signal.
    - Wake-scan start (`hint_idx` from line 711 before the loop)
      would give a prediction even when no worker was parked.
    - Decision: start with V1. If the "no worker parked" case
      matters, revisit later.

3. Should multiple hints coexist (a small bitmap of hinted workers
   rather than a single index)?
    - Not needed for the primary gate. Single-drainer is
      sufficient to cut 56-way contention to 1-way.
    - Deferred.

## Implementation sketch (for next iteration)

No code changes in this iteration. The expected diff when
implementing:

1. Add `drain_hint` field to `Core` struct.
2. Add `drain_hint.store(...)` to the tail of `notifySubmits`'s
   wake-scan loop (inside the `break` branch).
3. Refactor `nextTask`'s work-stealing block: extract inject
   drain to a helper or duplicate the popMany block once (step 3
   and step 5), gated by the hint check.
4. No changes to `BoundedRing`, `cancelQueuedTasks`,
   `workers_nonempty`, park/unpark, or the submit path.

Estimated diff: ~30 lines of code + struct field.

## Rollback plan

If stress/A-B fails: revert the nextTask + notifySubmits changes
(single commit), leave the struct field in place for a follow-up
iteration. Update this doc with the failure mode.

## Failure mode (2026-04-15)

Implemented per the spec. `zig build test` PASS. `zig build
test-stress -Doptimize=ReleaseFast` crashed with **signal 11
(SIGSEGV)** in `stress.double_dequeue_race.test.phase h:
double-dequeue race reproducer` at a ~15% rate across 13 runs
(2 failures, both in that single test; pre-change control was
5/5 PASS). Failing seed example: `0x186b1479`.

### Why the correctness proof missed it

The spec's "No races with `cancelQueuedTasks`" section argued
that ring operations already tolerate concurrent consumers and
that shutdown is safe. That is true of the ring, but the SIGSEGV
target is `double_dequeue_race` — a test that exercises the
phase-H ghost-duplicate path where a descriptor can be emitted
by multiple queue paths concurrently and must be filtered via
the atomic `.queued → .running` transition in `runTask`. The
design didn't reason about whether changing the *order* of inject
drain vs bitmap-steal for non-hinted workers changes the duplicate
emission rate or visibility window, and evidently it does.

### Why the same symptom as Option D

Option D was "popMany-after-bitmap-steal only" — the exact
pattern this implementation applies to non-hinted workers (step
4 before step 5). Any change that moves inject drain *after*
bitmap-steal re-creates Option D's SIGSEGV signature. The design
doc's brainstorm noted D was "blocked on understanding the
SIGSEGV root cause" — Option C inherited that block the moment
it made non-hinted workers drain-last.

### Remaining paths forward

1. **Hint-only, no fallback** — step 5 removed. Non-hinted
   workers never touch inject. Loses forward-progress guarantee
   under stale-hint quiescence; would need a replacement
   quiescence safety net (e.g., hinted worker re-hints before
   parking, or a periodic "any-worker-can-drain" tick). Not yet
   designed.
2. **Hint-only with pre-park drain** — non-hinted workers skip
   inject in nextTask but drain it once before calling `park`.
   Keeps quiescence safety, avoids bitmap-steal-then-drain
   reorder. Would need new design doc.
3. **Post-mortem on the SIGSEGV** — before any Option D / C
   variant, instrument or `rr`-record the crash to learn whether
   duplicates leak through `.queued → .running` or whether this
   is a distinct use-after-free in the stealing/shutdown path.
   Capturing a core dump + backtrace from the failing seed is
   the prerequisite for all reorder-based attacks.

### Reverted changes

`src/pool.zig` working-tree changes discarded (never committed).
The `drain_hint` field from the spec was NOT retained in-tree;
the closed-out design doc stands on its own. A future iteration
that re-opens this attack should re-derive from the design.

### Post-mortem — SEGV is a null task_fn dereference (2026-04-15)

Partial diagnosis from a diagnostic-reproducer iteration (all
pool.zig instrumentation reverted, never committed). Findings:

- **Fault site:** `src/pool.zig:953` —
  `descriptor.task_fn.?(descriptor.ctx.?, &runtime)`. The SEGV is
  "Segmentation fault at address 0x0": a null function pointer
  call. Not a use-after-free of the descriptor arena itself; the
  descriptor struct is live but `task_fn` has been cleared to
  null.
- **Only two `task_fn` writers exist:**
  - `enqueuePush` (pool.zig:~620) — writes the non-null task_fn
    *before* storing `state = .queued` via
    `descriptor.state.store(.queued, .release)` (pool.zig:653).
    So state=.queued synchronizes-with a non-null task_fn by
    the standard release-acquire pairing.
  - `releaseDescriptor` (pool.zig:1167) — writes `task_fn = null`
    *after* state has transitioned through
    `.running → .completed → .free`.
- **Key diagnostic:** Adding an `@atomicLoad(?TaskFn, ...,
  .acquire)` probe *immediately after* the successful CAS
  `.queued → .running` (pool.zig:905) shows `task_fn` as non-null
  at probe time, yet the call at line 953 faults ~10% of runs
  (4 failures in 40 ReleaseFast runs with the probe installed,
  both in `double_dequeue_race` and `park_handshake` tests). The
  only explanation consistent with this observation is **another
  thread writes `task_fn = null` via `releaseDescriptor` between
  the probe and the call** — i.e. another thread already ran the
  task and released the descriptor in the same CAS-filter window.
- **Implication — true double-dispatch:** For `releaseDescriptor`
  to fire, some *other* worker must have successfully transitioned
  the descriptor `queued → running → completed → free` while our
  worker was between the acquire-probe and the call. That requires
  the other worker to have also won the CAS `.queued → .running`
  for the same descriptor+generation. The phase-H CAS filter is
  designed to prevent exactly this (it's atomic — only one winner),
  yet two winners are occurring under Option C's reorder.
- **Signature matches Option D.** Both attacks move inject drain
  *after* bitmap-steal. The brainstorm already noted this reorder
  is suspicious; the post-mortem confirms the mechanism is a
  double-CAS-win on the same descriptor, not a ring-level use-
  after-free.

### Root cause — still unresolved

The individual queue protocols are each correct:

- `BoundedRing.popMany` (Vyukov MPMC) claims slots atomically
  via head CAS + per-slot sequence; no descriptor index can be
  emitted to two consumers from the inject queue.
- `RingQueue.stealHalf` (Chase-Lev-like SPMC) uses top CAS +
  bottom load with the standard steal/pop protocol; no descriptor
  can be stolen twice.
- `BoundedRing.pop` (used only by `cancelQueuedTasks` during
  shutdown) holds `state != .running` invariant at entry.

The double-dispatch must arise at the *seam* — a descriptor
whose index is live in the inject ring AND in some worker's
local deque concurrently. Most plausible mechanism: the inject
drain's push-to-local step (`lq.tryPushBottom(buf[i])` in
`tryDrainInject`) does not preclude the same index already
existing in the local ring through some earlier path. Under the
today-order (drain before steal), the local-ring ingress
temporally precedes any steal attempt; under Option C's reorder,
a non-hinted worker can `stealHalf` a local ring while the
hint-drain concurrently pushes fresh indices into it. If the
stealer samples a slot that was earlier emitted by inject and
subsequently re-emitted by inject (descriptor was recycled, a
classic A/B/A on descriptor indices with generation reuse), both
workers could race to CAS the same index in the current
generation.

This is still a hypothesis. Confirmation requires either:

- A descriptor-level dispatch counter (monotonic counter per
  `(index, generation)` pair, panic on ≥2), or
- A debugger-driven core dump analysis (not available in this
  environment — no gdb/lldb installed).

### What NOT to do next

- **Do not reopen Options C or D as-designed.** Both reorder
  bitmap-steal before inject drain for some worker set. Both
  SEGV. Root cause is unfixed.
- **Do not assume `@atomicLoad(.acquire)` on `task_fn` fixes the
  race.** An earlier 20/20-PASS observation under ReleaseFast
  was noise — the `n=40` re-run returned to ~10% failure. The
  probe is diagnostic only.

### Candidate forward paths (ranked)

1. **Descriptor dispatch counter.** Add an atomic u32 counter
   per descriptor; bump-on-dispatch before CAS, panic if pre-CAS
   counter already >0 (i.e. someone else dispatched this
   generation). Confirms / refutes the double-dispatch hypothesis
   cheaply. Instrumentation only — does not land in production.
2. **Hint-only with pre-park drain.** Non-hinted workers never
   touch inject in `nextTask`; the hinted worker and the
   about-to-park worker drain. Avoids the reorder entirely.
   Needs a fresh design doc; the Option C failure mode here
   should be cited in its correctness proof.
3. **Non-reorder attacks on inject head contention.** E.g. a
   sharded inject queue (Option B from the brainstorm) that
   splits head-CAS pressure across N rings rather than serializing
   drain differently. No reorder, no dispatch-count risk.

All reorder-based attacks remain blocked on path 1 (dispatch
counter) confirming the double-dispatch hypothesis and
identifying the specific seam — or a debugger becoming available.

### Post-mortem iteration 2 (2026-04-15) — double-dispatch confirmed

Reopened under stress with `claim_sentinel_enabled = true` (forced,
not `std.debug.runtime_safety`) and the **minimal** reorder from
Option D (all workers bitmap-steal before inject drain; no hint
field, no tryDrainInject helper — just swapping the two blocks in
nextTask). Goal: determine whether (a) today's code double-dispatches
but stays silent because the sentinel is gated off in ReleaseFast,
or (b) the reorder itself introduces the double-dispatch.

Results:

| Configuration | 20× ReleaseFast test-stress |
|---|---|
| Today's main, sentinel FORCED ON | 20 PASS, 0 FAIL |
| Option D reorder, sentinel FORCED ON | 9 PASS, 11 FAIL |
| — of those FAILs: `double-dequeue:` panics | **2** |
| — of those FAILs: SEGV at `task_fn.?(...)` | 0 (elided by probe) |

With a `@atomicLoad(?TaskFn, &descriptor.task_fn, .acquire)` probe
right before the call, 11/20 runs panic with "NULL-TF-AT-CALL"
instead of SEGV'ing. Ten of the eleven panics report `state=free`,
meaning the descriptor has fully transitioned
`.running → .completed → .free` between our CAS-win and the
probe — i.e., a SECOND worker ran the task and called
`releaseDescriptor` while we were between CAS and call. The
remaining case reports `state=running claimed_by=self` — the
stale-memory-view variant where we see null task_fn even though
our own .running state is still current.

Concrete panic examples:

```text
thread X panic: NULL-TF-AT-CALL: desc=38 worker=10 state=free gen=4360 claimed_by=10
thread Y panic: double-dequeue: descriptor 17 claimed by worker 13, now worker 9 also tried to claim it
thread Z panic: NULL-TF-AT-CALL: desc=17 worker=13 state=running gen=6373 claimed_by=13
```

The sentinel fires AND the null-task_fn probe fires in the same
seed (desc=17): worker 13 CAS-wins state, but worker 9 ALSO
CAS-wins sentinel (the "loser" from worker 13's perspective),
meaning two workers both passed `state.cmpxchgStrong(.queued,
.running)` on the same descriptor+generation. That is the CAS
atomicity invariant being broken — two winners on a single
compare-and-swap against the same address.

Hypothesis update: this is not a classic A/B/A on descriptor
indices (which would leave the sentinel silent, because the
stale-gen worker and the rightful-gen worker would never race on
the same generation's state). It is a true double-CAS-win on the
SAME (descriptor, generation). The mechanism is still unclear —
the single-word state field and x86 `lock cmpxchg` should be
serializing. Candidate mechanisms yet to disprove:

- **Mixed-atomicity undefined behavior.** `descriptor.state` is
  `std.atomic.Value(TaskState)` accessed atomically, but
  `descriptor.task_fn` and several other fields are written via
  plain stores in `enqueuePush` and cleared via plain stores in
  `releaseDescriptor`. Zig's memory model treats mixing atomic
  and non-atomic accesses to *different* fields of the same
  struct as defined if no concurrent accesses target the
  non-atomic fields — but `descriptor.* = .{}` in
  `acquireDescriptor` (pool.zig:1116) writes the atomic state
  field via a non-atomic bulk memcpy, before the final
  `state.store(.reserved, .release)` at line 1122. A concurrent
  reader's atomic load of `state` during that bulk store is
  technically UB; the compiler may be generating code that
  violates the expected happens-before in ReleaseFast.
- **`descriptor.* = .{}` torn write.** The bulk struct reset
  writes `state` twice — once as part of the memcpy (default
  `.free`), once via the explicit `state.store(.reserved,
  .release)`. On x86 TSO the intermediate `.free` is observable;
  on non-x86 the release store's position relative to the memcpy
  is the concern. We're only running x86 in this test, so likely
  not this.
- **Stale queue emission + no in-dispatch generation check.**
  `descriptor.generation` is `u64` (pool.zig:129), so wrap
  aliasing is not the issue — panic messages show gen values in
  the single-digit-to-100k range, nowhere near u64 wrap. BUT:
  `runTask` never compares the descriptor's generation against
  the generation in the queue entry, because **queue entries
  carry only the u32 index, not the generation**. A queue entry
  popped after the descriptor was recycled cannot be detected as
  stale. The state CAS is the only gate, and if the new
  generation's submitter has also stored `state=.queued`, the
  stale entry's CAS passes. Two CAS-winners could arise if two
  queue entries both carry index D and the state oscillates
  `.queued → .running → .free → .reserved → .queued → .running`
  fast enough between their CAS attempts. The reorder widens
  this window.

### Next iteration candidates

1. **Generation tag on queue entries.** Pack `{index:u32,
   generation:u32}` into the queue's u64 slot (today it's just
   u32 index + 4 bytes of padding). Check the packed gen against
   `descriptor.generation` in `runTask` *before* the state CAS.
   Mismatch → stale entry → silent skip. This closes the stale-
   entry window without changing any queue invariants. Expected
   outcome: reorder + sentinel now PASSes stress because stale
   entries are filtered before they can contend. Highest-yield
   diagnostic and a plausible production fix.
2. **Mixed-atomicity audit.** Convert `task_fn` and `ctx` writes
   in `enqueuePush` and `releaseDescriptor` to `@atomicStore`
   with `.release`, then rerun. If the 1-in-11 `state=running
   claimed_by=self` panic disappears, the codegen is splitting
   the plain-store → atomic-store edge; that's a separate bug
   from the double-dispatch.
3. **Cancelled variant.** The descriptor state machine has
   `.cancelled` as a sibling of `.completed`; verify the CAS in
   `runTask` can't see a `.cancelled` state transitioned in by
   a concurrent `cancelQueuedTasks` during stress. Lowest
   expected yield; do last.

Path 1 is also the forward path for any queue-level fix: if
stale-entry filtering works, Option D and C become viable as
designed.

## Iteration 3 (2026-04-15) — generation-tagged queue entries FIX LANDED

Path 1 from "Next iteration candidates" above was implemented and
validated. The stale-entry double-dispatch window is now closed at
the queue layer, independently of the Option C/D reorder question.

### Change summary

`src/pool.zig`:

- New `pub const QueueEntry = u64` with `packEntry(index, gen)`,
  `entryIndex(entry)`, `entryGen(entry)` helpers. Layout is
  `{gen_tag: u32 high, index: u32 low}`; `gen_tag` is
  `@truncate(descriptor.generation)`.
- `LocalQueue` union, `lifo_slot`, and `inject_queue` all widened
  from `u32` to `QueueEntry`. `LIFO_SLOT_EMPTY` widened to
  `0xFFFF_FFFF_FFFF_FFFF`.
- `enqueuePush` packs `{index, generation}` into the entry before
  writing any queue slot.
- `runTask` and `cancelDescriptor` now take `QueueEntry`, decode
  index + gen, and reject mismatches **before** the state CAS:

```zig
if (@as(u32, @truncate(descriptor.generation)) != entry_gen) {
    return;
}
```

  A mismatch means the descriptor was recycled between enqueue and
  dispatch — the entry is stale and silently dropped. No counter
  manipulation, no wake-up, no task body invocation.

### Validation matrix

All at `-Doptimize=ReleaseFast`, 20 runs each:

| Scenario                                                       | Before iter 3 | After iter 3 |
|----------------------------------------------------------------|---------------|--------------|
| Main order, sentinel off (default config)                      | 20/20         | 20/20        |
| Main order, sentinel forced on                                 | 20/20         | 20/20        |
| **Reorder (bitmap-steal before inject-drain), sentinel on**    | **9/20**      | **20/20**    |

The third row is the key result: the stale-entry filter closes the
canonical double-dequeue panic + the NULL-TF-AT-CALL probe panics
that iter 2 diagnosed. Reorder-based attacks (Options C, D, and
future inject-head-contention variants) are now **unblocked** at
the queue layer.

### Performance (n=5 paired BSSB, tokio-parity)

| Scenario                   | Δ        |
|----------------------------|----------|
| flood_1m                   | +2.0%    |
| flood_1m_batched           | +0.7%    |
| contended_spawn_8x         | -0.9%    |
| contended_spawn_8x_batched | +0.4%    |

Within ±2% session variance — no regression from widening queue
slot from u32 to u64.

### Unit + stress

- `zig build test`: PASS
- `zig build test-stress -Doptimize=ReleaseFast` x20 (default
  config): 20/20 PASS

### Outcome for this spec

Option C's original drain-hint design is still closed as written
(the correctness proof missed the drain-vs-steal visibility
question, and the hint field is no longer needed). But the
**mechanism that blocked it** — stale-entry double-dispatch
through the state CAS — is now fixed. A future drain-hint or
inject-contention attack can cite this fix instead of waiting on
the SIGSEGV post-mortem.
