# Option 3 Brainstorm — Worker-Local Incoming Queues

> **Status:** brainstorm only. No code, no plan. Surfaces design questions for human review before any plan is written. Spawned from the 2026-04-13 wrap-up doc Option 3 sketch and the 2026-04-14 audit that flagged Phase H + Option 5 as already-shipped.

## What the wrap-up doc said

> "Instead of the submitter choosing 'LIFO slot of current worker' vs 'inject queue', extend the LIFO to a per-Worker incoming queue that ONLY the worker pops from (single-reader) and ONLY non-owner submitters push to (multi-writer). The submitter rotates between worker-local queues via its `wake_hint`. This amortizes submit-side atomic cost across N independent cachelines."
>
> "For flood_1m (single submitter pushing 1M tasks), this spreads the writes across 56 cachelines instead of 1-2."

## What the code actually looks like today

The submitter path in `enqueueTask` (`src/pool.zig:587-606`):

- **If caller is a worker** (`tls_worker_index != null`, work-stealing variant): try own LIFO slot → own local_queue.tryPushBottom → fall through to inject_queue.
- **If caller is external** (no TLS index): goes **straight to inject_queue.tryPush**, bypassing LIFO and local_queue entirely.

The dispatch path in `nextTask` (`src/pool.zig:686-748`):

1. own LIFO slot (swap-to-empty, owner-only writer)
2. own local_queue.popBottom (Chase-Lev / ring; owner-only writer, multi-stealer reader)
3. inject_queue.pop + drain up to `inject_batch_size` items into own local_queue
4. steal from random victim's local_queue (peek-then-steal-half)
5. else null → `idle()` → park

The current inject_queue is `BoundedRing(u32)` — Vyukov MPMC, lock-free, per-slot sequence numbers (`src/queue/bounded_ring.zig:7-99`). One head cacheline + one tail cacheline + N slots. **Every external submit and every worker that dequeues hammers the same head/tail pair.**

flood_1m's submitter is a **non-worker thread**, so 100% of its 1M submits hit `inject_queue.tryPush` — and 56 workers race to `pop` from the same queue.

## The proposed change

Add a per-Worker `incoming: BoundedRing(u32)` (or similar) that:

- Multi-producer for *external* submitters (workers still go LIFO/local_queue first per current logic).
- Single-consumer for the owning worker (reads in `nextTask` before/after own local_queue).
- Submitter rotates target via `wake_hint % workers.len` (already exists in `Core.wake_hint` from the abandoned G3 work — not currently in use, can be repurposed).

Stealing from someone else's `incoming` is **out of scope** for this proposal — leaves the SPMC simplicity intact and avoids re-introducing a multi-reader on the new queue. If a worker's incoming is empty but other workers have work, the existing local_queue steal path picks it up because the wake target's first dispatch will pull from incoming → local_queue → become a steal victim.

## Cost sketch

**Per submit (current):** 1 CAS on `inject_queue.tail` (cacheline X, hot across all 56 cores). 1 store to claim slot's value + sequence release-store.

**Per submit (proposed):** 1 CAS on `incoming[X].tail` (cacheline X_W, hot only between submitter and worker W). Submitter rotates W = (wake_hint++) % N.

**Cacheline pressure:**

- Current: 1 cacheline (head/tail of single ring) ping-pongs between 1 submitter and 56 readers continuously.
- Proposed: 56 cachelines, each ping-ponging between 1 submitter and 1 reader. Submitter touches a different cacheline on every submit (cold-in-L1 each iteration) but no inter-reader contention.

The trade-off is non-obvious: the current model loses badly to *coherence storms* (56 readers invalidating each other's reads of the head); the proposed model loses to *cold-line traversal* on the submitter side (every submit touches a different cacheline, paying L1 → L2/L3 round trips).

**Hypothesis:** on a 56-core box where submitter is the bottleneck (per the re-profile: submitter 100% CPU-bound, zero voluntary blocks), losing 1 hot line for 56 distributed lines is a net win because the current single hot line is the worst-case for MESI coherence. A modeled best case is that submitter spends N cycles less per submit on cache-line acquisition (hard to estimate without measurement; could be 30-100 cycles, could be near zero if the submitter's `tail` writes were already mostly serialized through the store buffer).

**Worst case:** if 56 cold-line traversals per submit cost more than the saved coherence storm, this regresses flood_1m. Same-session paired A/B is mandatory.

## Open design questions

1. **Capacity sizing.** Total queue capacity becomes `N × per_worker_capacity`. Options:
   - **Same total capacity:** `per_worker = global_capacity / N`. With current default `queue_capacity = 4096` and 56 workers, that's ~73 slots per worker. Tiny per-worker buffer → frequent QueueFull rotations.
   - **Same per-worker as today's global:** total capacity becomes 56× larger (`56 × 4096 = 230K slots`). Memory cost: `230K × 16 bytes/slot ≈ 3.7 MB` of inject queue. Acceptable.
   - **Configurable separately.** Probably the right answer for a first cut: add `incoming_capacity` to `Config` defaulting to `queue_capacity / max_threads` rounded to power-of-2, with a minimum (e.g., 64).

2. **What if target worker's incoming is full?**
   - **Rotate to next worker** (probe up to N before giving up). Risk: hot-spot worker (long-running tasks) holds incoming-full while N-1 others are empty; rotation finds them quickly.
   - **Fall back to global inject_queue.** Keep the existing inject_queue as a backstop. Adds back the cacheline-storm path under saturation but preserves the QueueFull ceiling.
   - **Return QueueFull immediately.** Aggressive backpressure. Loses the existing escape valve.

3. **Dispatch precedence in `nextTask`.** Where does incoming fit?
   - **After LIFO, before local_queue:** wake-target worker's freshest work runs first. Pairs with wake-hint semantics — the wake means "I just put something for you in your incoming."
   - **After LIFO, after local_queue:** own local_queue drains first (oldest queued work first). Less aggressive but more predictable latency.
   - **Drain incoming → local_queue in batches** (mirror the existing inject_queue drain). Best for batch-amortization but adds complexity.
   - **First-cut bias:** check incoming AFTER local_queue (drain own work first), or replace inject_queue as step 3 entirely. Either is defensible.

4. **Fallback global inject_queue: keep or remove?**
   - **Keep:** safety net for incoming-full case + non-rotating submit pattern (e.g., submit from a signal handler with no `tls_worker_index` and no rotation context). Minimal complexity. Slight memory overhead (the existing 4096-slot ring stays).
   - **Remove:** cleaner, but blocks the QueueFull-on-saturation case (#2 above) from having a fallback.
   - **First-cut bias:** keep, mark for removal once incoming-only path proves stable under stress.

5. **Owner-as-submitter case.** When a worker submits its own task, current code uses LIFO/local_queue. With incoming added, should an owner-submit also flow into incoming as a fallback before falling to global inject? Probably yes (it's the worker's own queue, single-writer-from-self path is even cheaper). But rotation logic changes if the owner doesn't want to pollute its own incoming with work it could just LIFO-slot.

6. **Wake-scan interaction.** Currently `enqueueTask` post-push reads `is_parked[]` and signals one parked worker (`src/pool.zig:622-639`). With per-worker incoming, the natural pairing is: submitter chose worker W, so it should signal W specifically (not scan). This:
   - Removes the wake-scan loop (a known cost — see the abandoned wake-gate work).
   - **Risk:** if worker W is busy and worker V is parked, V doesn't get woken and waits for the next steal-scan to find W's work. Adds latency.
   - **Mitigation:** if W isn't parked, fall back to existing scan. But that puts the scan back on the slow path of busy targets.

7. **Cancellation + shutdown drain.** The drain loop at `src/pool.zig:952` (`while (self.inject_queue.pop())`) needs extension to drain N incoming queues. Mechanical change.

8. **Stress test coverage.** Phase H added `tests/stress/double_dequeue_race.zig` for the queue-layer race. The new incoming queue is a new MPMC structure (or, more likely, a per-worker MPSC) — needs its own race coverage. Reusing `BoundedRing` (already battle-tested as MPMC) is the lowest-risk path; specializing to MPSC for the incoming case is a perf optimization that should be deferred until measurement justifies it.

## What I'd want from the human before writing a plan

1. **Capacity policy** (Q1): pick one of the three sizing strategies, or describe a constraint.
2. **Fallback policy** (Q2 + Q4): keep global inject_queue as backstop, or commit to incoming-only?
3. **Dispatch precedence** (Q3): incoming before or after own local_queue?
4. **Wake coupling** (Q6): tightly couple wake to the chosen incoming target, or keep wake-scan independent?
5. **Whether to specialize to MPSC** (Q8): keep BoundedRing(MPMC) for v1, or commit to writing a new MPSC ring for the incoming-specific case?

Reasonable defaults if the human doesn't want to make all these calls:

- Capacity: configurable, default `max(64, queue_capacity / max_threads rounded to power-of-2)`.
- Fallback: keep global inject_queue as backstop (mark for removal post-validation).
- Dispatch: incoming AFTER own local_queue, BEFORE inject (i.e., insert at step 2.5 in nextTask).
- Wake: tightly couple — submitter signals the chosen worker only, falls back to scan if target isn't parked.
- Queue type: reuse BoundedRing(MPMC) for v1.

## Cost estimate (to guide go/no-go)

- Plan authoring: 1-2 hours.
- Implementation (assuming defaults above): touches `Worker` struct (add `incoming: BoundedRing(u32)`), `Core.init/deinit`, `enqueueTask` (route to incoming when external), `nextTask` (drain incoming), shutdown drain, cancellation. Estimated ~200-300 lines of changes spread across 1 file (`src/pool.zig`).
- Tests: extend stress reproducer for incoming-full rotation, new unit test for SPMC contract.
- Validation: 20× ReleaseFast stress gate, 100× pre-merge stress gate, paired A/B vs main on flood_1m and contended_spawn_8x.
- Risk: medium. Touches submit hot path (Phase H race-fix gate applies — any timing change must re-validate). Steal-half semantics unchanged. Cancellation/shutdown semantics unchanged for global inject_queue backstop.

## Risk callouts

- **Host drift means flood_1m A/B is noisy on this box.** A regression of <5% will be in the noise floor. A win of <10% may be unprovable on the current host. Recommendation: only commit Option 3 if it produces a same-session paired A/B win of ≥10%, OR run on a quiet host.
- **Submit-path change → Phase H race re-exposure risk.** Sentinel is always-on (`claim_sentinel_enabled = true`); ReleaseSafe stress will catch any new race. Keep the sentinel always-on through the Option 3 work; revert decision is a separate clean-up.
- **Memory cost is real but manageable.** With sane capacity sizing, ~3-4 MB of additional queue memory.
