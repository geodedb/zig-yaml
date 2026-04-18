# Layout Offsets Heatmap

Generated: 2026-04-16. Zig 0.16.0 / x86\_64-linux.

This document enumerates the field offsets and cacheline placement of the
hot structs inside `src/pool.zig`. It is the reference for
OBSERVABILITY-PIVOT / R-06: any refactor that changes these offsets must
update both this doc **and** the matching `comptime` asserts in
`src/pool.zig`. The asserts are deliberately size-bounded rather than
exact-offset, because Zig's plain-`struct` layout is compiler-choice
(field reordering for alignment); locking exact offsets would wedge the
codebase on any compiler upgrade. The asserts that do fire at compile
time catch the invariants that actually matter for correctness and
performance:

- dispatch-hot read group size (TaskDescriptor, Worker)
- cacheline-isolation of hot counter groups (Counters -- extern)
- alignment constraints (sync.Mutex, std.atomic.Value)

---

## `TaskDescriptor` (plain struct -- Zig-reordered)

`@sizeOf(TaskDescriptor) = 96 bytes` (Zig 0.16.0 / x86\_64). Hot group
ends at `submit_ns` (offset 64), i.e. exactly one cacheline.

| Field          | Observed offset | Kind          | Touched by                         |
| -------------- | --------------: | ------------- | ---------------------------------- |
| `task_fn`      |               0 | pointer       | submit, runTask.invokeTask         |
| `ctx`          |               8 | pointer       | submit, runTask.invokeTask         |
| `options`      |              16 | SubmitOptions | submit, runTask.finalizeTask       |
| `generation`   |              56 | u64           | submit, runTask stale-filter       |
| `submit_ns`    |              64 | u64 (cold)    | snapshot path only (R-01)          |
| `start_ns`     |              72 | u64 (cold)    | watchdog + R-01 summary            |
| `complete_ns`  |              80 | u64 (cold)    | R-01 summary                       |
| `claimed_by`   |              88 | atomic i32    | runTask CAS (claim sentinel, dbg)  |
| `state`        |              92 | atomic u8     | runTask CAS (state gate)           |

**Invariants (enforced in `pool.zig` comptime block):**

1. `@offsetOf(TaskDescriptor, "submit_ns") <= SubmitOptions + 3*u64 + 16` -- bounds the hot read group.
2. `@sizeOf(TaskDescriptor) <= 128` -- descriptor slab per-entry size bound.

**Note on `state`:** Zig's auto-reordering placed `state` at offset 92,
after `claimed_by`. This works because the state CAS and the
claim-sentinel CAS are both already in the second cacheline, so they
share dispatch-hot-path line traffic. Moving `state` back to the front
would require marking TaskDescriptor `extern struct`, which loses
alignment slack on 32-bit platforms.

---

## `Worker` (plain struct -- Zig-reordered)

`@sizeOf(Worker) = 1912 bytes` (Zig 0.16.0 / x86\_64). This is dominated
by `WorkerScratch` (contains an inline allocator arena) and the three
latency histograms (`wait_histogram`, `exec_histogram`, `wake_histogram`).

Hot fields used per-dispatch:

- `scratch` -- task scratch allocator, touched on every runTask.
- `wait_histogram` / `exec_histogram` / `wake_histogram` -- observed on
  task-start / task-complete / park-return respectively. Merged at
  `statsSnapshot` only.
- `busy_ns` / `idle_ns` -- summary counters.
- `started` / `completed` / `steals` / `steal_failures` / `parks` /
  `wakeups` -- dispatch-path counters.
- `park_mutex` / `park_cond` / `is_parked` -- the park handshake.
- `lifo_slot` -- tokio-style single-slot LIFO cache (owner-only).
- `owned_queue_len` -- owner-private local-queue length tracker.
- `serves_lane` -- lane routing gate (one byte).
- `current_task_started_ns` -- watchdog heartbeat.

**Invariants (enforced in `pool.zig` comptime block):**

1. `@alignOf(sync.Mutex) >= @alignOf(u32)` -- Zig 0.16.0 `std.Thread.Mutex`
   is futex-based (u32 state), so the atomic state word does not straddle
   a natural alignment boundary.
2. `@sizeOf(Worker) <= 4096` -- ceiling at two pages. A future refactor
   that blows past this bound must explicitly update the invariant after
   documenting why the growth is acceptable (accidental cacheline-
   splitting field additions trip here first).

---

## `Counters` (`extern struct` -- fixed C-ABI layout)

`Counters` is `extern struct` specifically because the park handshake
depends on `queued_tasks` and `queued_tasks_blocking` each owning their
own cacheline. Extern layout gives us order-stable offsets across Zig
compiler versions.

| Field                       | Offset                    | Cacheline | Writers                             |
| --------------------------- | ------------------------: | --------: | ----------------------------------- |
| `queued_tasks`              |                         0 |         0 | submit path (default lane)          |
| `_pad0a`                    |                         8 |         0 | padding                             |
| `submitted`                 |             `cache_line`  |         1 | submit path (all lanes)             |
| `_pad0b`                    | `cache_line + 8`          |         1 | padding                             |
| `active_tasks`              |         `2 * cache_line`  |         2 | runTask (start) / runTask (finalize)|
| `cancelled`                 | `2 * cache_line + 8`      |         2 | cancelDescriptor                    |
| `_pad1`                     | `2 * cache_line + 16`     |         2 | padding                             |
| `queued_tasks_blocking`     |         `3 * cache_line`  |         3 | submit path (blocking lane)         |
| `_pad1b`                    | `3 * cache_line + 8`      |         3 | padding                             |
| `wakeups` ... `overflow_active` | 4\*cache\_line onward |   4+      | cold observability counters         |

Where `cache_line = std.atomic.cache_line` (64 bytes on x86\_64,
platform-dependent).

**Invariants (enforced in `pool.zig` comptime block):**

1. `queued_tasks` at offset 0.
2. `submitted` at offset `cache_line`.
3. `active_tasks` at offset `2 * cache_line`.
4. `queued_tasks_blocking` at offset `3 * cache_line`.
5. `cancelled` at offset `2 * cache_line + 8` -- shares line with
   `active_tasks` by design (both are runtime write-side-only, never
   touched by submitters).

**Why the blocking-lane separation matters:** the park handshake's SC
load of `queued_tasks` must not observe a blocking-lane increment, else a
default-lane worker would unpark on every blocking-lane submit with
nothing to do. Putting the two counters on separate cachelines makes
this physical: a submitter's write to `queued_tasks_blocking` never
invalidates the default-worker read line for `queued_tasks`.

---

## Updating this doc

When a struct layout changes:

1. Run `zig build test` -- if a `comptime` assert in `pool.zig` fires,
   read the error location and update either the struct or the bound.
2. Re-run a quick `@compileLog` probe on the affected struct to capture
   new observed offsets. Delete the `@compileLog` before committing.
3. Update the field offset tables above.
4. Update the "Observed on Zig X.Y.Z / arch" line in the opening header
   if the compiler version moved.
5. If the layout change is motivated by a performance win, link the
   relevant `docs/performance/<date-slug>/` writeup.
