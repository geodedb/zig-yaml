# Architecture

`thread-pool` is built around bounded task descriptors, a fixed worker
cap, and three scheduler variants behind one public API. This page
maps the components and ownership rules; deep algorithm details live
in [ALGORITHMS.md](ALGORITHMS.md).

## Component Map

```mermaid
flowchart TB
    subgraph Public[Public surface - src/root.zig]
        TP[ThreadPool]
        TYPES[Config / SubmitOptions / Stats / WaitGroup / TaskHandle]
    end
    subgraph Core[Core - src/pool.zig]
        EN[enqueuePush<br/>submit / submitBatch fast path]
        NT[notifySubmits<br/>wake coalescing]
        WM[workerMain<br/>nextTask / runTask / idle]
        WD[watchdogMain<br/>overflow spawn]
    end
    subgraph Queues[Queue primitives - src/queue]
        IQ[BoundedRing<br/>inject + blocking_inject<br/>MPMC Vyukov]
        LQ[LocalQueue tagged union<br/>RingQueue SPMC - default<br/>WorkDeque Chase-Lev - opt-in]
        SQ[submitter_queues<br/>RingQueue per registered submitter]
    end
    subgraph State[Per-worker state]
        LIFO[lifo_slot<br/>atomic u64 entry]
        OQL[owned_queue_len<br/>owner-private upper bound]
        DCW[desc_cache<br/>SPSC LIFO 32]
        PARK[park_cond + is_parked + park_mutex]
    end
    subgraph Caches[src/pool/desc_cache.zig]
        DCS[desc_caches slice<br/>one per submitter slot<br/>SPSC LIFO 32]
    end
    subgraph Descriptor[Descriptor pool]
        DESC[descriptors array<br/>bounded by queue_capacity]
        FREE[task_desc_free head - atomic u32 freelist]
        LIVE[task_desc_live counter]
    end
    TP --> EN
    TP --> WM
    EN --> DCW
    EN --> DCS
    EN --> LIFO
    EN --> LQ
    EN --> SQ
    EN --> IQ
    EN --> NT
    NT --> PARK
    WM --> LIFO
    WM --> LQ
    WM --> IQ
    WM --> SQ
    WM --> DESC
    DESC --> FREE
    DESC --> LIVE
    WD --> WM
```

## Ownership Rules

| Resource | Writers | Readers | Sync |
|---|---|---|---|
| `inject_queue` / `blocking_inject` | any | any worker | Vyukov MPMC seq + CAS |
| `local_queues[i]` | worker `i` (bottom) | any worker (top) | RingQueue/Chase-Lev protocol |
| `submitter_queues[i]` | submitter owning slot `i` | any worker | RingQueue SPMC protocol |
| `workers[i].lifo_slot` | worker `i` only | worker `i` only | single atomic swap/store |
| `workers[i].desc_cache` | worker `i` only | worker `i` only | no atomics — SPSC |
| `desc_caches[i]` | submitter owning slot `i` | submitter owning slot `i` | no atomics — SPSC |
| `workers_nonempty` u64 bitmap | worker `i` transitions 0↔1 | any (victim scan) | fetchOr / fetchAnd |
| `counters.*` | any | any | atomic monotonic / seq_cst |
| `tls_worker_slot` / `tls_submitter_slot` | the owning thread | the owning thread | thread-local |

## Lifetimes

- **Pool** owns every allocation reported by `statsSnapshot()`:
  `inject_queue` buffer, per-worker scratch buffers, local queues,
  submitter queues, descriptor array, DescCaches.
- **Worker threads** spawn during `init`; join during `shutdown`.
- **Overflow workers** spawn lazily via the watchdog and retire after
  `2 * watchdog_interval_ns` of idleness.
- **Descriptors** reuse only after `.completed` / `.cancelled` →
  `.free` transition. Waitable descriptors stay allocated until
  `wait()` returns.

## Task Submission Pipeline

```mermaid
sequenceDiagram
    participant App as Application
    participant TP as ThreadPool
    participant DC as DescCache (TLS)
    participant LF as lifo_slot / local_queue
    participant SQ as submitter_queues
    participant IQ as inject_queue
    participant W as Parked worker
    App->>TP: submit(task_fn, ctx, opts)
    TP->>TP: enqueuePush
    alt TLS is worker & cache hit
        TP->>DC: tryPop (zero atomics)
    else TLS is worker & cache miss
        TP->>DC: acquireDescriptorBatch -> refill (32)
    else TLS is submitter
        TP->>DC: same - per-submitter cache
    else no TLS context
        TP->>TP: single acquireDescriptor (global freelist)
    end
    TP->>TP: descriptor.state := queued, pack entry
    alt worker-TLS path
        TP->>LF: lifo_slot.store if empty
        opt lifo full
            TP->>LF: local_queue.tryPushBottom
        end
    else submitter-TLS path
        TP->>SQ: tryPushBottom
        opt submitter full
            TP->>IQ: inject_queue.tryPush
        end
    else no TLS
        TP->>IQ: inject_queue.tryPush
    end
    TP->>TP: notifySubmits(count, lane)
    Note over TP: lane_counter.fetchAdd seq_cst<br/>park handshake
    alt batch boundary
        TP->>W: scanAndWake: signal one parked worker
    end
    App-->>TP: TaskHandle or void
```

Full diagram with the three scheduler variants and lane routing lives
in [ALGORITHMS.md § Top-Level Task Pipeline](ALGORITHMS.md#top-level-task-pipeline).

## Worker Scheduling Loop

```mermaid
flowchart TB
    Boot[workerMain entry<br/>tls_worker_slot set] --> Top
    Top{shouldExit?} -- yes --> Exit[Return]
    Top -- no --> Next[nextTask worker_index]
    Next -- entry --> Run[runTask<br/>runTask - gen filter - state CAS - invokeTask - finalizeTask]
    Run --> Top
    Next -- null --> Idle[idle<br/>park on park_cond with timedWait]
    Idle -- signalled --> Top
    Idle -- timeout --> Top

    Next --> DrainPriority[Drain priority:<br/>1. lifo_slot swap - acquire<br/>2. local_queue popBottom<br/>3. tryDrainLaneForWorker own lane<br/>4. cross-lane rebalance if allowed]
    DrainPriority --> Steal[Iterate workers_nonempty<br/>for each set bit:<br/>victim_queue.stealHalf -> own local_queue]
```

Details:

- **LIFO slot first** makes worker-context submit → drain a cache-resident
  handoff.
- **`owned_queue_len` reconciliation:** if `popBottom` returns null but
  the owner counter was > 0, stealers drained the queue — reset to 0 and
  clear the bitmap bit.
- **Steal-half** copies up to `(len+1)/2` entries in one CAS; first entry
  is returned, rest spill into the worker's own local queue.
- **Cross-lane rebalance (L3):** blocking workers always help default;
  default workers help blocking only under `cpu_helps_blocking`.

## Descriptor Lifecycle

```mermaid
stateDiagram-v2
    [*] --> free
    free --> reserved: acquireDescriptor{Batch}
    reserved --> queued: enqueuePush publishes fields<br/>+ state.store(.queued, .release)
    queued --> running: runTask state CAS .queued->.running
    queued --> cancelled: cancelQueuedTasks CAS during shutdown
    running --> completed: finalizeTask
    running --> cancelled: cooperative token
    completed --> free: releaseDescriptor CAS<br/>(drain-on-release to DescCache<br/>or push to freelist)
    cancelled --> free: same
```

- **Gen tag:** `QueueEntry = {u32 gen, u32 idx}`; `runTask` filters
  recycled-slot entries via `entry_gen == descriptor.generation`.
- **Exactly-once dispatch:** `state.cmpxchgStrong(.queued, .running)` is
  the single serialization point.
- **Idempotent release (SEC-018):** concurrent `wait()` calls can't
  double-push; the CAS on `state` ensures exactly one release path.
- **Panic contract (REV-001):** `task_fn` must not panic; non-catchable
  by design.

## Wake Coalescing + Parked-Worker Scan

```mermaid
sequenceDiagram
    participant S as Submitter
    participant C as counters.submitted + lane_counter
    participant P as Parked worker
    S->>C: submitted.fetchAdd(1, .monotonic)
    S->>C: lane_counter.fetchAdd(1, .seq_cst)<br/>[park handshake]
    alt submitted % wake_coalesce_batch == 0
        S->>P: scanAndWake(lane)
        Note over P: Iterate lane's worker range from<br/>rel_hint = submitted % scan_len<br/>Wake first is_parked == 1
    else between boundaries
        Note over P: Re-parks bail via SC load of<br/>lane_counter > 0
    end
```

- **Wake one per batch.** Wake-up-to-`count` variants regress
  `flood_1m_batched ~50%` via thundering-herd on inject head.
- **Hint rotation** avoids consistently waking worker 0.

## Queue Primitives

```mermaid
flowchart LR
    subgraph A[BoundedRing - Vyukov MPMC]
        A1[inject_queue<br/>blocking_inject]
    end
    subgraph B[RingQueue - SPMC]
        B1[local_queues i - default]
        B2[submitter_queues i]
    end
    subgraph C[WorkDeque - Chase-Lev]
        C1[local_queues i<br/>queue_kind = .chase_lev]
    end
    subgraph D[DescCache - SPSC LIFO 32]
        D1[workers i .desc_cache]
        D2[desc_caches i]
    end
```

See [ALGORITHMS.md](ALGORITHMS.md) for full correctness sketches + CAS
protocol diagrams for each.

## Observability

`statsSnapshot()` returns a single read-consistent view:

- lifecycle counters (`submitted`, `started`, `completed`, `cancelled`)
- queue depth current + peak (per lane)
- steals / steal-failures / wakeups / parks (aggregate + per worker)
- wait and execution latency histograms (when `timestamp_mode == .full`)
- wake-latency histogram (per worker, OBSERVABILITY-PIVOT R-03)
- per-worker scratch + local-queue metrics
- process memory on Linux / macOS / Windows
- watchdog stall counter + overflow spawn/retire counters

## Resource Model

- Task descriptors: bounded by `Config.queue_capacity`.
- Per-worker local queue capacity: bounded by `Config.local_queue_capacity`
  (power-of-two, max `65536`).
- Worker count: capped at `64` (bounded by `workers_nonempty` u64 bitmap).
- Submitter slots: capped at `64` (bounded by `submitter_free_mask` u64).
- Scratch: bounded by `worker_scratch_cap_bytes` per worker.
- `purgeWorkerCaches()` is quiescent-only
  (`active_tasks == 0 && queued_tasks == 0`), returns
  `error.PoolBusy` otherwise.

## Further Reading

- [ALGORITHMS.md](ALGORITHMS.md) — every pipeline + pseudocode
- [DESIGN.md](DESIGN.md) — rationale, API contract, memory model
- [SCHEDULER_DECISION.md](SCHEDULER_DECISION.md) — variant-picking rubric
- [PERFORMANCE_TRACKING.md](PERFORMANCE_TRACKING.md) — delta history
- [BENCHMARKS.md](BENCHMARKS.md) — scenario matrix + measurement protocol
