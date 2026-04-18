# Algorithms Reference

This document consolidates the core algorithms that drive `thread-pool`,
with mermaid diagrams for each pipeline and pseudocode tied back to the
source files. Use it as the entry point when reasoning about scheduling,
queueing, descriptor lifecycle, or wake behaviour.

All algorithm names in headings map directly to a file or function under
`src/`; line numbers intentionally omitted so the document does not rot
with refactors — search for the symbol name instead.

## Table Of Contents

- [Top-Level Task Pipeline](#top-level-task-pipeline)
- [Descriptor Lifecycle](#descriptor-lifecycle)
- [DescCache (SPSC LIFO)](#desccache-spsc-lifo)
- [Chase-Lev Work-Stealing Deque](#chase-lev-work-stealing-deque)
- [RingQueue (SPMC)](#ringqueue-spmc)
- [BoundedRing (Vyukov MPMC)](#boundedring-vyukov-mpmc)
- [Worker Scheduling Loop](#worker-scheduling-loop)
- [Wake Coalescing + Parked-Worker Scan](#wake-coalescing--parked-worker-scan)
- [Lane Routing And Rebalancing](#lane-routing-and-rebalancing)
- [Watchdog + Overflow Spawn](#watchdog--overflow-spawn)
- [Shutdown](#shutdown)
- [Comptime Elision Hooks](#comptime-elision-hooks)

---

## Top-Level Task Pipeline

End-to-end flow for a single `submit()` / `submitBatch()` call, from user
thread through the pool into an executing worker.

```mermaid
flowchart TB
    U[User thread calls submit task_fn, ctx, options]
    U --> V{lane == .blocking?}
    V -- yes --> Binj[Push onto blocking_inject BoundedRing]
    V -- no --> W{TLS worker slot belongs to this pool?}
    W -- yes --> L[Owner-local LIFO slot: CAS empty to entry]
    L -->|slot was empty| OK1[Push succeeded]
    L -->|slot was not empty| LQ[Push to owner local_queue tryPushBottom]
    W -- no --> S{TLS submitter slot registered?}
    S -- yes --> SQ[Push to submitter_queues slot tryPushBottom]
    S -- no --> INJ[Push to inject_queue BoundedRing tryPush]
    LQ -->|ok| OK1
    LQ -->|full| SQFallback[Fall through to submitter/inject]
    SQFallback --> S
    SQ -->|ok| OK1
    SQ -->|full| INJ
    OK1 --> Notify[notifySubmits: fetchAdd queue_depth + scanAndWake]
    Binj --> Notify
    INJ --> Notify
    Notify --> Worker[scanAndWake: wake 1 parked worker in lane]
    Worker --> Loop[Worker workerMain loop picks up work via nextTask]
    Loop --> Run[runTask executes task_fn ctx]
    Run --> Release[releaseDescriptor: drain-on-release into DescCache or freelist]
```

Key design points:

1. **LIFO slot is owner-only.** Only the worker thread that owns a given
   worker slot ever writes to `lifo_slot`. Stealers never touch it. This
   makes the fast-path submit a single release store when the slot is
   empty.
2. **Per-submitter queues are SPMC.** Only the submitter thread that
   registered for slot `i` pushes to `submitter_queues[i]`; any worker
   may steal from head.
3. **`inject_queue` is MPMC.** It is the fallback when both LIFO and
   local paths miss, and the ground truth for `global_queue` variant.
4. **Wake coalescing:** notify side wakes at most one parked worker per
   batch of `wake_coalesce_batch` submits. Between flushes, parked
   workers re-park bail via the seq-cst `queued_tasks` handshake.

Reference: `src/pool.zig::enqueuePush`, `src/pool.zig::enqueueTask`,
`src/pool.zig::notifySubmits`.

---

## Descriptor Lifecycle

Each submitted task owns one `TaskDescriptor` from a bounded preallocated
array (`queue_capacity` entries). The state machine below is enforced by
a CAS-guarded `descriptor.state` field plus a `generation` tag that
invalidates stale handles.

```mermaid
stateDiagram-v2
    [*] --> free: Pool init
    free --> reserved: acquireDescriptor or acquireDescriptorBatch
    reserved --> queued: enqueuePush sets fields + state.store(.queued)
    queued --> running: runTask CAS .queued to .running (Phase H)
    queued --> cancelled: cancelQueuedTasks CAS during shutdown
    running --> completed: finalizeTask (normal path)
    running --> cancelled: cooperative token isCancelled at invokeTask
    completed --> free: releaseDescriptor (non-waitable) or wait() CAS
    cancelled --> free: same
    free --> [*]: Pool deinit
```

Invariants:

- **Generation tag in queue entries.** `QueueEntry = {u32 gen, u32 idx}`.
  `runTask` filters entries whose gen doesn't match the descriptor's
  current generation — closes double-dispatch on recycled slots.
- **CAS-on-release (SEC-018).** `releaseDescriptor` uses
  `state.cmpxchgStrong(expected, .free)` so concurrent `wait()` calls
  cannot double-push onto the freelist.
- **Active invariant.** `task_desc_live == 0` post-shutdown; fuzz harness
  asserts this every iteration.
- **Panic contract (REV-001).** `task_fn` must not panic — Zig panics are
  non-catchable; the pool cannot self-heal from a panicked task.

Reference: `src/pool.zig::runTask`, `src/pool.zig::finalizeTask`,
`src/pool.zig::releaseDescriptor`, `src/pool.zig::acquireDescriptor`.

---

## DescCache (SPSC LIFO)

The 32-entry LIFO descriptor cache that gates the global freelist on the
hot submit path. One instance per submitter slot and one per worker.
Both owner classes are single-writer / single-reader by construction —
no atomic ops in the fast path.

```mermaid
flowchart LR
    subgraph Submit[Submit hot path]
        A[enqueuePush wants a descriptor]
        A --> B{cache.tryPop returns value?}
        B -- yes --> C[Use it - zero atomics]
        B -- no --> D[acquireDescriptorBatch - up to 32 from freelist]
        D --> E[Use batch index 0 for this submit]
        D --> F[Push batch 1 to n into cache for future submits]
    end
    subgraph Release[Release drain-on-release]
        G[Task completes, releaseDescriptor called]
        G --> H{Owner slot's cache exists?}
        H -- yes --> I[cache.push idx]
        I -- full --> J[Fall back to freelist push]
        I -- ok --> K[Done - zero atomics]
        H -- no --> J
    end
    subgraph Drain[Drain on deinit/release]
        L[Pool deinit or slot release]
        L --> M[cache.drainAll into scratch buffer]
        M --> N[Push all into inject/freelist bounded spin]
    end
```

Why it matters:

- Removes per-submit coherence traffic on the global `task_desc_free`
  head CAS. On `nested_fanout_4x` this lifted worker-context submits
  by `+81.26%` paired vs the pre-`DescCache` baseline.
- Bounded 32 entries per slot — full drain fits in a single 128-byte
  copy loop, so drain-on-release is cheap.
- Drain-on-release preserves `task_desc_live == 0` at shutdown: the slot
  being released drains its cache to the inject/freelist **before** the
  `free_mask` CAS publishes the slot as free.

Reference: `src/pool/desc_cache.zig`, `src/pool.zig::acquireDescriptorBatch`,
`src/pool.zig::drainWorkerDescCaches`.

---

## Chase-Lev Work-Stealing Deque

`WorkDeque` is the classic lock-free Chase-Lev deque. It remains exported
as an optional `queue_kind = .chase_lev` and for experimentation; the
default owner-local queue is `RingQueue` (see next section).

```mermaid
sequenceDiagram
    participant Owner as Owner worker
    participant Deque
    participant Stealer as Any other worker
    Note over Owner,Stealer: Invariants — bottom monotonically up by owner, top up by CAS winners
    Owner->>Deque: tryPushBottom value
    Note right of Deque: buffer idx (bottom mask) := value (unordered), then bottom.store(+1, .release)
    Owner->>Deque: popBottom (LIFO)
    Note right of Deque: b-- (seq_cst), load top (seq_cst). If t == b, CAS top to t+1 — race with stealers
    Stealer->>Deque: stealTop (FIFO)
    Note right of Deque: load top (seq_cst), bottom (acquire). CAS top to t+1 — one winner
```

Properties:

- **Owner-only** for `tryPushBottom` and `popBottom`.
- **Any thread** for `stealTop`; contested slots resolve via a strong CAS
  on `top`. A losing stealer returns null without retrying so the caller
  can pick another victim.
- **Power-of-two buffer size**, masked with `size - 1` for wrap.
- **No batch steal** — Chase-Lev's linearization proof doesn't generalize
  to batched takes; for that we use the `RingQueue` variant.

Reference: `src/queue/work_deque.zig`.

---

## RingQueue (SPMC)

The default owner-local queue, modelled on Tokio's
`runtime/scheduler/multi_thread/queue.rs` and Go's `runq*` in
`runtime/proc.go`. Single producer (owner) writes tail; any thread may
`stealHalf` in batches from head.

```mermaid
flowchart LR
    subgraph ownerpush[Owner push tail]
        OP1[t := tail load]
        OP1 --> OP2{tail - head >= cap?}
        OP2 -- yes --> OP3[Return false - full]
        OP2 -- no --> OP4[buffer t mask := value unordered]
        OP4 --> OP5[tail.store t+1 release]
    end
    subgraph ownerpop[Owner pop tail LIFO]
        OPP1[new_tail := tail - 1 seq_cst]
        OPP1 --> OPP2[h := head load seq_cst]
        OPP2 -- empty --> OPP3[Restore tail, return null]
        OPP2 --> OPP4{h == new_tail last?}
        OPP4 -- yes --> OPP5[CAS head to h+1 race with stealers]
        OPP4 -- no --> OPP6[Return buffer new_tail mask]
    end
    subgraph stealhalf[Stealer stealHalf]
        S1[h := head, t := tail acquire]
        S1 --> S2{avail == 0 or overflow?}
        S2 -- yes --> S3[Return 0 or retry up to 256]
        S2 -- no --> S4[n := avail+1 / 2, cap at dst.len]
        S4 --> S5[Copy n slots from h monotonic]
        S5 --> S6[CAS head to h+n seq_cst]
        S6 -- lost --> S4
        S6 -- won --> S7[Return n]
    end
```

Correctness sketch:

- Owner is the sole writer of `tail` and of slot contents.
- Stealers synchronise with each other via seq-cst CAS on `head`, which
  is the linearization point of a batch.
- Owner never writes slot `i` while `head <= i < tail`, so stealer reads
  between load-head and CAS-head are safe — worst case another stealer
  wins the CAS and the loser's reads are discarded.
- Owner-vs-stealer race on the last element: seq-cst fence on tail then
  re-read head, same pattern as Chase-Lev's `popBottom`.

Reference: `src/queue/ring_queue.zig`.

---

## BoundedRing (Vyukov MPMC)

The shared inject queue `inject_queue` uses a Vyukov-style bounded MPMC
ring. Per-slot `sequence` word encodes both "producer turn" and
"consumer turn" so push and pop interleave without locks.

```mermaid
flowchart TB
    subgraph tryPush[tryPush value]
        P1[tail := tail load]
        P1 --> P2[slot := buffer tail mask]
        P2 --> P3[seq := slot.sequence load acquire]
        P3 --> P4{diff := seq - tail}
        P4 -- 0 --> P5[CAS tail to tail+1 monotonic]
        P5 -- won --> P6[slot.value := value]
        P6 --> P7[slot.sequence.store tail+1 release]
        P5 -- lost --> P1
        P4 -- "<0" --> P8[Full, return false]
        P4 -- ">0" --> P1
    end
    subgraph pop[pop returns value?]
        G1[head := head load]
        G1 --> G2[slot := buffer head mask]
        G2 --> G3[seq := slot.sequence load acquire]
        G3 --> G4{diff := seq - head+1}
        G4 -- 0 --> G5[CAS head to head+1 monotonic]
        G5 -- won --> G6[value := slot.value]
        G6 --> G7[slot.sequence.store head+cap release]
        G5 -- lost --> G1
        G4 -- "<0" --> G8[Empty, return null]
        G4 -- ">0" --> G1
    end
    subgraph popMany[popMany buf]
        M1[Reserve up to buf.len in one head CAS]
        M1 --> M2[Per slot: spin until sequence == head+i+1]
        M2 --> M3[Copy value, republish sequence += cap]
    end
```

`popMany` is the **inject-drain fast path** — a single strong CAS reserves
up to N entries (default: `inject_batch_size`, up to 32) so worker
drains amortise head-CAS traffic. On `flood_1m_batched` this cut head-CAS
rate by the drain-batch factor (median `+14%` at drain=32 in the 2026-04-14
inject-head contention audit).

Reference: `src/queue/bounded_ring.zig`.

---

## Worker Scheduling Loop

Each worker runs `workerMain(self, worker_index)` in a tight loop that
calls `nextTask` to find work, `runTask` to execute it, or `idle` to park
when nothing is available.

```mermaid
flowchart TB
    Start[workerMain begin] --> Check{shouldExit?}
    Check -- yes --> Stop[Worker exits]
    Check -- no --> Next[nextTask worker_index]
    Next -- null --> Idle[idle worker_index - park on park_cond]
    Idle --> Check
    Next -- entry --> Run[runTask worker_index, entry]
    Run --> Check
```

`nextTask` drain order (default work-stealing variant):

```mermaid
flowchart TB
    A[Enter nextTask]
    A --> L{lifo_slot != EMPTY?}
    L -- yes --> LR[swap EMPTY, return entry - acquire]
    L -- no --> LQ{local_queue popBottom?}
    LQ -- entry --> LQR[Decrement owned_queue_len, return entry]
    LQ -- null --> INJ[tryDrainLaneForWorker own lane]
    INJ --> INJA{lane_inject popMany n > 0?}
    INJA -- yes --> INJR[Return first, spill n-1 to local_queue]
    INJA -- no --> SUB[Drain any submitter_queues whose mask bit is set]
    SUB --> SUBR{stolen?}
    SUBR -- yes --> SUBRet[Return]
    SUBR -- no --> STEAL[Iterate workers_nonempty bitmap]
    STEAL --> STEALA[For each victim: lq.stealHalf up to steal_batch_size]
    STEALA -- any --> STEALR[Return first, rest into own local_queue]
    STEALA -- none --> REBAL{rebalanceLane possible?}
    REBAL -- yes --> INJ
    REBAL -- no --> RET[Return null]
```

Key optimisations captured in this diagram:

1. **`workers_nonempty` bitmap** — a `u64` where bit `i` is set when
   worker `i`'s `owned_queue_len > 0`. Steal pass iterates set bits
   instead of probing 55 victim queues' heads. Landed at e533955;
   `+17%` contended_spawn_8x clean A/B.
2. **Non-empty local reconciliation** — when `popBottom` returns null
   with `owned_queue_len > 0`, stealers drained it, so reconcile to 0
   and clear the bitmap bit.
3. **Inject drain → local spill** — `popMany` reserves up to
   `inject_batch_size` in one head CAS, then spills the tail into the
   worker's local deque so each inject drain satisfies many submits.
4. **Cross-lane rebalance (L3)** — blocking workers always help the
   default lane when own lane is empty; default workers help blocking
   only under `cpu_helps_blocking`.

Reference: `src/pool.zig::workerMain`, `src/pool.zig::nextTask`,
`src/pool.zig::tryDrainLaneForWorker`, `src/pool.zig::rebalanceLane`.

---

## Wake Coalescing + Parked-Worker Scan

`notifySubmits` batches the park handshake + futex wake, and `scanAndWake`
probes at most one parked worker per notify.

```mermaid
sequenceDiagram
    participant Sub as Submitter thread
    participant Counter as counters + lane_counter
    participant Park as parked worker
    Note over Sub: enqueuePush succeeded
    Sub->>Counter: submitted.fetchAdd(1, .monotonic)
    Sub->>Counter: lane_counter.fetchAdd(1, .seq_cst)  [park handshake]
    alt batch boundary (submitted % wake_coalesce_batch == 0)
        Sub->>Park: scanAndWake(lane)
        Note over Park: iterate workers from submitted % scan_len<br/>first is_parked == 1 wins<br/>lock park_mutex, cond.signal
    else between batches
        Note over Sub: no wake - parked worker's re-park<br/>handshake checks lane_counter > 0
    end
```

Why it works:

- **SC fetchAdd** on `lane_counter` plus SC read by a parking worker form
  an SC total order. A worker that is about to park first does an SC load
  of `lane_counter`; if it sees `> 0`, it bails back to `nextTask`.
- **Wake at most one** per notify — a wake-up-to-`count` variant regressed
  `flood_1m_batched` `~50%` due to thundering-herd on the inject head
  cacheline (measured in 2026-04-14 cascading-wake plan, memoised as a
  closed plane).
- **Scan hint from `submitted % scan_len`** rotates the first-probed
  worker across submits so consecutive waves don't always hit worker 0.

Reference: `src/pool.zig::notifySubmits`, `src/pool.zig::scanAndWake`.

---

## Lane Routing And Rebalancing

The `lane_extension` scheduler adds a dedicated blocking lane with its
own inject queue, worker range, and rebalance rules. Default lane
workers own slot `[blocking_workers, max_threads)`; blocking workers
own `[0, blocking_workers)`.

```mermaid
flowchart LR
    subgraph Submit[submit path]
        S[enqueuePush]
        S --> L{lane?}
        L -- default --> DI[default inject_queue + local/submitter]
        L -- blocking --> BI{blocking_workers > 0?}
        BI -- yes --> BQ[blocking_inject queue]
        BI -- no --> DI
    end
    subgraph Drain[nextTask drain]
        W[worker.serves_lane]
        W -- default --> DD[Drain default: inject, submitters, steal default-lane workers]
        W -- blocking --> BD[Drain blocking: inject, steal blocking workers]
        DD -->|empty + config.cpu_helps_blocking| BD
        BD -->|empty + blocking_workers > 0| DD
    end
```

Slice history (L1 → L4) lives in
`docs/superpowers/specs/2026-04-15-lane-extension-scheduler-design.md`.
L3 added cross-lane rebalance; L4 added watchdog observability and
overflow spawn/retire.

Reference: `src/pool.zig::tryDrainLaneForWorker`,
`src/pool.zig::rebalanceLane`, `src/pool.zig::laneInjectQueue`,
`src/pool.zig::laneMask`.

---

## Watchdog + Overflow Spawn

Optional watchdog thread that ticks every `watchdog_interval_ns` and
spawns one overflow worker per tick when it detects a default-lane stall
longer than `blocking_promotion_timeout_ns`.

```mermaid
flowchart TB
    Tick[Wake every watchdog_interval_ns] --> Stop{watchdog_stop?}
    Stop -- yes --> Exit[Thread exits]
    Stop -- no --> Reap[reapRetiredOverflow: join any retired threads]
    Reap --> Scan[Scan default-lane workers current_task_started_ns]
    Scan --> Det{worker.now - started > timeout?}
    Det -- yes --> Incr[counters.watchdog_stalls_detected.fetchAdd 1]
    Det --> More{more workers?}
    More -- yes --> Scan
    More -- no --> Spawn{stalls_this_tick > 0?}
    Spawn -- yes --> MaybeSpawn[maybeSpawnOverflow: spawn up to one overflow thread]
    Spawn -- no --> Tick
    MaybeSpawn --> Tick
```

Overflow workers retire themselves after `2 * watchdog_interval_ns` of
idleness; the watchdog then joins them on its next tick. Both the
spawn and retire paths are zero-cost when
`Config.max_overflow_workers == 0`.

Reference: `src/pool.zig::watchdogMain`,
`src/pool.zig::maybeSpawnOverflow`, `src/pool.zig::overflowWorkerMain`.

---

## Shutdown

Two modes:

- `drain` — reject new submissions, let queued + running work finish,
  join workers, release memory.
- `cancel_pending` — reject new submissions, cancel queued tasks (CAS
  `.queued → .cancelled`), let running tasks finish.

```mermaid
flowchart LR
    Start[shutdown mode, timeout] --> Flag[state := shutting_down - reject future submits]
    Flag --> Mode{mode?}
    Mode -- drain --> Wait[Wait for queued_tasks + active_tasks == 0]
    Mode -- cancel_pending --> Cancel[cancelQueuedTasks - CAS queued to cancelled for every queued descriptor]
    Cancel --> Wait
    Wait --> Stop[watchdog_stop := true, wake watchdog]
    Stop --> Wake[Broadcast park_cond across all workers]
    Wake --> Join[Join all worker threads + watchdog]
    Join --> Drain2[drainWorkerDescCaches: flush per-worker DescCache into freelist]
    Drain2 --> DrainSub[drainSubmitterDescCaches + submitter_queues]
    DrainSub --> Verify[Assert task_desc_live == 0]
    Verify --> Free[deinit: free all owned allocations, release queues]
```

Key subtleties:

- `task_desc_live == 0` is the post-shutdown invariant; DescCache drain
  order matters (see [DescCache](#desccache-spsc-lifo)).
- `shutdown(.drain)` with `backpressure = .block` is fine — the submit
  path sees `shutting_down` and returns `error.PoolShutdown` before it
  can block on a full queue.
- Fuzz harness asserts shutdown terminates within 5 seconds across
  32–256 random ops per iteration.

Reference: `src/pool.zig::shutdown`, `src/pool.zig::cancelQueuedTasks`,
`src/pool.zig::joinAllWorkers`, `src/pool.zig::drainWorkerDescCaches`.

---

## Comptime Elision Hooks

Build-time specialisation points. All `fold to a constant` when
`-D<flag>` is passed; unused branches drop out of the ReleaseFast binary
and its associated coherence cost disappears.

```mermaid
flowchart LR
    subgraph Flags
        F1[-Dsingle-pool bool - skip per-pool TLS identity check]
        F2["-Dtimestamp-mode {disabled, completion_only, full}"]
        F3["-Dscheduler-variant {global_queue, work_stealing, lane_extension}"]
    end
    subgraph Branches[Hot-path branches elided]
        B1[tlsWorkerIndexFor - pool identity check]
        B2[recordTaskStart - wait_histogram.observe]
        B3[enqueuePush - local_queue push block]
        B4[nextTask - local+steal drain block]
    end
    F1 --> B1
    F2 --> B2
    F3 --> B3
    F3 --> B4
```

**Safety notes:**

- `-Dsingle-pool=true` **restores** the pre-F-001 cross-pool OOB hazard
  for the index-within-bounds case. Use only in processes that host
  exactly one `ThreadPool`. Measured gain: 6–17% on
  `contended_spawn_8x`, `cpu_work_100us`, `mixed_fast_slow`.
- `-Dtimestamp-mode=disabled` is always safe; it elides histogram writes
  and makes wait/exec latency fields always report zero.
- `-Dscheduler-variant=<v>` is always safe; it pins
  `Config.scheduler_variant` at build time and drops the alternative
  scheduler's drain/submit branches.

Reference: `build.zig`, `src/pool.zig::usesLocalQueues`,
`src/pool.zig::timestampsEnabled`, `src/pool.zig::single_pool_mode`.

---

## Further Reading

- [DESIGN.md](DESIGN.md) — higher-level design rationale and public API
  surface.
- [architecture.md](architecture.md) — component layout and ownership.
- [BENCHMARKS.md](BENCHMARKS.md) — per-scenario methodology and current
  numbers.
- [RUNTIME_COMPARISON.md](RUNTIME_COMPARISON.md) — Zig vs Tokio vs Go
  same-host comparison.
- [PERFORMANCE_TRACKING.md](PERFORMANCE_TRACKING.md) — long-form
  per-phase deltas and historical rationale.
- `docs/performance/2026-04-16-go-gap-contended/FINAL.md` — DescCache
  landing post-mortem.
- `docs/performance/2026-04-17-go-gap-round2/FINAL.md` — closed-plane
  record of lifo-rotate + batched-submitBatch attempts.
