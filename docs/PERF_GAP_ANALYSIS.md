# Performance Gap Analysis — devnw/zig/yaml

Performance review of the Zig YAML 1.2.2 library, focused on hot-path
throughput and allocation efficiency for well-formed input. DoS / resource-limit
concerns (billion-laughs, unbounded resolver expansion) are covered separately in
`docs/APPSEC_REVIEW_2026-06-11.md` and are out of scope here except where they
overlap with throughput.

- Date: 2026-06-11
- Reviewer: performance review (manual, evidence-based)
- Scope: `src/scanner.zig`, `src/parser.zig`, `src/resolver.zig`,
  `src/composer.zig`, `src/json.zig`, `src/parallel.zig`, `bench/parallel_bench.zig`
- Method: read-only static review with file:line citations. No product code modified.

## Re-review note (2026-06-11, third pass — YAML-compliance feature changeset)

A third performance pass was run after a large (~1460-line) YAML-compliance
feature changeset landed across `src/scanner.zig` (§7.3/§8.1.3 line-break
folding restructure), `src/resolver.zig` (core/JSON-schema numeric parsers,
`big_int` preservation, resolver resource budgets), `src/emitter.zig`
(`max_line_width` flow wrapping via `currentColumn()`), `src/composer.zig`
(`current_doc` index, per-depth `key_set_pool`), `src/parser.zig`
(`UnsupportedYamlVersion`, streaming depth checks), `src/json.zig`,
`src/validate.zig`. Build/test green (`zig build test`, exit 0).

Focus: did the NEW code add any regression on the hot parse path?

Verification outcome (hot-path):

- **Scanner fold-flush restructure — O(1) amortized, NOT quadratic. Not a
  regression.** `scanDoubleQuoted`/`scanSingleQuoted` (`src/scanner.zig:1031-1038`,
  `1255-1263`) and `scanPlainScalar` (`src/scanner.zig:1758-1767`) replaced the
  old "append one space per newline immediately" with a deferred break-run
  counter (`break_count`/`pending_breaks`) flushed once when the next non-break
  char is reached. Each input break char is counted exactly once (the plain-scalar
  break-counting `while` at `src/scanner.zig:1694-1697` advances `self.pos` as it
  counts — no re-scan); the flush appends `k-1` newlines, which are genuine
  output bytes. Total append work over a scalar = output length = O(n). The only
  new per-character cost is one comparison (`if (ch != '\n' and ch != '\r' and
  break_count > 0)`) in the double/single-quoted loops — strictly O(1)/char, no
  change in asymptotic class. `confidence::confirmed` (static; the flush guard
  resets `break_count = 0` so a run is flushed at most once).
- **Resolver numeric parsers — linear, allocation-free until classification. Not
  a regression.** `parseIntCore` (`src/resolver.zig:505-534`), `parseIntJson`
  (`src/resolver.zig:538-551`), and `parseJsonFloat` (`src/resolver.zig:556-587`)
  each do a single O(scalar_len) pass and call `std.fmt.parseInt`/`parseFloat`
  (non-allocating). A heap `dupe` happens only on the `.big` branch (value matches
  the integer grammar but overflows i64 — rare) or the `.str` fallthrough (same as
  the prior `parseInt`/`parseStdFloat` behavior). The common int/float/ordinary-
  string scalar allocates exactly as before. `parseStdFloat` gained a single extra
  `x/X/p/P` reject check inside its existing one-pass loop — O(1)/char.
  `confidence::confirmed`.
- **Emitter `currentColumn()` back-scan — bounded, cold path, NOT a hot-path
  regression; tracked as NEW PERF-0012 (P3).** It scans backward to the last
  newline on every flow separator, but (1) it is on the emit/serialize path only,
  never the parse path; (2) it is gated behind `self.opts.max_line_width > 0`
  (default 0), and Zig `and` short-circuits, so in the default config
  `flowSeparatorBreak` calls `write(" ")` without ever invoking `currentColumn()`;
  (3) once a line exceeds `max_line_width` a newline is emitted and the back-scan
  resets, so scan length is bounded by `max_line_width` (a `u16`) in steady state.
  Worst case is O(items²) within a single not-yet-wrapped flow line, capped near
  the wrap width. Filed as **PERF-0012 (P3)** for completeness. See entry.
- **No new per-node / per-mapping allocation on the hot path.** The composer
  scalar branch (`src/composer.zig:184-202`) is allocation-unchanged from the
  prior review (still the PERF-0002 `dupeInArena` of tag/anchor/value; the default
  tag literal flipped `"!"`→`"?"`, both compile-time-constant slices, duped
  identically). Per-mapping `unique_keys` was already de-allocated via the
  per-depth `key_set_pool` (PERF-0011, resolved). Resolver `big_int` allocates
  only on i64 overflow. `confidence::confirmed`.

Prior P1 hot-path findings re-verified UNCHANGED (not regressed):

- **PERF-0001** — `orderedRemove(0)` still present at 15 scanner sites
  (`src/scanner.zig:183, 200, 340, 370, 515, 554, 677, 867, 915, 997, 1070, 1112,
  1362, 1404, 1879`) plus the parser at `src/parser.zig:250`. Neither helped nor
  worsened by the feature changeset.
- **PERF-0002** — double-copy (scanner `dupe`/`allocated_strings` → composer
  `dupeInArena`) intact; the fold restructure still builds the scalar in a
  per-scalar `ArrayList` then `toOwnedSlice`s it.
- **PERF-0003** — zero `ensureTotalCapacity`/`initCapacity` anywhere in `src/`
  (grep confirmed); collection `ArrayList`s still start `.empty`.

**Conclusion: NO NEW P0 or P1 regression on the hot parse path.** One NEW P3
(PERF-0012, emitter-only, bounded, default-config-inactive) was added.

## Re-review note (2026-06-11, second pass)

A second performance pass was run after memory-safety / DoS fixes landed in
`src/resolver.zig` (removed the alias `resolved_cache`; aliases now re-resolve
their target subtree, bounded by `max_nodes`/`max_depth`), `src/parser.zig`
(depth tracking in `nextEvent`), `src/composer.zig` (per-map `StringHashMap`
for `unique_keys` dedup; `current_doc` changed from pointer to index),
`src/limits.zig`, and `src/yaml.zig`. Build/test green (`zig build test`, exit 0).

Verification outcome:

- **PERF-0001..PERF-0003, PERF-0005..PERF-0010 — still accurate, unchanged.**
  All cited line numbers re-verified against current files. None were
  accidentally fixed or worsened. `orderedRemove(0)` still present at all 16
  scanner sites + `parser.zig:250`; zero `ensureTotalCapacity`/`initCapacity`
  anywhere in `src/`; double-copy, prescan, parallel, json, and eql-chain
  findings all confirmed verbatim.
- **PERF-0004 — partially resolved.** The pointer-into-`ArrayList` dangling
  hazard is fixed (`current_doc` is now `?usize`, `composer.zig:100/154/160`).
  The by-value `Document` (arena-by-value) copy through two layers
  (`composer.loadAll` / `yaml.loadAll`, `composer.zig:334-340`,
  `yaml.zig:340-346`) remains. Severity dropped P2 → P3. See updated entry.
- **Resolver re-resolution (cache removal) — assessed, ACCEPTABLE, not a new
  finding.** See "Assessment: resolver re-resolution" below.
- **NEW: PERF-0011 (P2)** — per-non-empty-mapping `StringHashMap` allocation for
  `unique_keys`, on by default. See entry.
- **Depth bookkeeping in `nextEvent` — assessed, NOT a regression.** See
  "Assessment: nextEvent depth bookkeeping" below.

### Assessment: resolver re-resolution (removed `resolved_cache`)

`Resolver.resolve` (`src/resolver.zig:113-139`) expands an alias by calling
`resolveAnchor` then **recursively re-resolving the target subtree**, with no
memoization. Cost is therefore O(Σ subtree_size over all references) instead of
the previous memoized O(graph_size). This is bounded by `countNode`
(`src/resolver.zig:101-104`), a resolver-private `nodes_produced` counter capped
at `max_nodes` (default 1,000,000), independent of the composer's graph-node
count, plus `enterDepth` for nesting. Conclusion: **acceptable.** (1) For
legitimate documents (an anchor referenced a handful of times) the work equals
the size of the output tree the caller actually requested — not wasteful. (2)
For adversarial alias fan-out (billion-laughs) the expansion trips
`error.MaxNodesExceeded` before exhausting memory, which is the whole point of
the change; the prior cache produced an aliasing graph that was a double-free /
shared-pointer hazard for `freeValue`. The CPU cost is the correct, intended
tradeoff for a true owned tree. No issue is filed; the behavior is documented at
`yaml.zig:554-561`.

### Assessment: `nextEvent` depth bookkeeping

`parser.nextEvent` (`src/parser.zig:258-264`) now calls
`limit_checker.pushDepth()`/`popDepth()` on `seq_start`/`map_start` and
`seq_end`/`map_end`. Both are branch-only integer ops (`src/limits.zig:90-97`):
a single comparison + increment/decrement, **no allocation, no syscall**. It
fires only on collection boundaries (not per scalar), so it is O(1) per
collection and negligible against the existing per-event work. Note depth is now
counted in two independent `LimitChecker`s (parser's streaming path and the
composer's `composeNode`, `src/composer.zig:196/228`); this is redundant
*bookkeeping* but each is O(1) and the duplication is intentional (protects
direct streaming consumers that bypass the composer). **Not a performance
regression.**

## Summary

| PerfSeverity | Count |
|--------------|-------|
| P0           | 0     |
| P1           | 3     |
| P2           | 4     |
| P3           | 5     |
| **Total**    | **12** |

Third-pass delta (YAML-compliance feature changeset): PERF-0012 added (P3,
emitter `currentColumn()` back-scan, cold/emit path, default-config-inactive).
No P0/P1 regression on the hot parse path; scanner fold-flush is O(1) amortized,
resolver numeric parsers are linear and allocation-free until classification, no
new per-node/per-mapping allocation. PERF-0001..0003 P1 hot-path findings
re-verified unchanged.

Second-pass delta: PERF-0004 reclassified P2 → P3 (pointer hazard fixed, copy
remains); PERF-0011 added (P2). No P0/P1 regressions introduced by the
memory-safety changes.

### Top 5 findings

1. **PERF-0001 (P1, algorithmic)** — `Scanner.nextToken` drains the token queue
   with `orderedRemove(0)`, an O(n) shift, in 16 call sites. The queue is the
   primary token-delivery path, making token delivery O(queue_len) per token.
2. **PERF-0002 (P1, memory)** — Every scalar/anchor/tag/key is `dupe`d in the
   scanner into `allocated_strings`, then `dupe`d **again** into the document
   arena by the composer. Two full copies of every string token plus per-token
   bookkeeping allocations.
3. **PERF-0003 (P1, memory)** — `Parser.nextEvent` and `Composer` build/drain
   `event_queue` and per-collection `ArrayList`s that all start `.empty` with no
   capacity hint, and the event queue also uses `orderedRemove(0)`.
4. **PERF-0004 (P2, memory)** — `composer.Document` holds an `ArenaAllocator` by
   value and is **copied by value** out of an `ArrayList` in `composeAll`/`loadAll`;
   combined with taking `&self.documents.items[...]` while still appending, this is
   both a pointer-stability hazard and forces defensive copies.
5. **PERF-0005 (P2, concurrency)** — `parallel.zig` takes a global mutex on
   **every** `parallelMapArray`/`parallelReduce` call to lazily fetch the pool, and
   writes adjacent result chunks that share cache lines (false sharing). It is also
   dead in the parse path (only a smoke test + standalone bench call it).

---

## PERF-0001 — O(n) `orderedRemove(0)` token-queue drain in the scanner hot path

- **Status:** Open
- **PerfSeverity:** P1
- **Category:** algorithmic
- **Location:** `src/scanner.zig:182` (and 15 more sites: lines 199, 339, 369, 514, 553, 676, 859, 907, 989, 1050, 1092, 1332, 1374, 1823)

```zig
pub fn nextToken(self: *Self) ScanError!?Token {
    if (self.token_queue.items.len > 0) return self.token_queue.orderedRemove(0);
    ...
```

- **Description:** `std.ArrayList.orderedRemove(0)` removes the first element and
  `@memmove`s every remaining element down one slot — O(n) in the current queue
  length. `token_queue` is not an occasional error path: it is the normal delivery
  channel for `block_end`, `block_map_start`, `block_seq_start`, `doc_start`,
  `doc_end`, and `value` tokens. During `unwindIndent` a deeply nested structure
  pushes many `block_end` tokens at once (one per indent level), and each is then
  drained with a front-removal. For a document with maximum nesting depth `d`,
  closing the structure is O(d^2) token shifts; across a whole document the
  queue-drain cost is superlinear in the number of structural tokens. Every
  `Token` is `struct{ ... 7 fields incl. 4 slices }` (~72 bytes), so the memmove
  moves real bytes, not just pointers.
- **Acceptance Criteria:**
  - Token delivery from the queue is amortized O(1) (e.g. ring buffer, head index
    into the `ArrayList`, or `std.fifo`/`std.DoublyLinkedList`), with no
    `orderedRemove(0)` remaining in `nextToken` or the structural-token emit paths.
  - A micro-benchmark parsing a deeply-nested document (e.g. 150 levels of nested
    block maps, repeated) shows tokenization time scaling linearly with depth
    rather than quadratically, with a measurable wall-clock improvement on the
    nested-structure case.
  - Existing scanner/parser tests still pass.
- **Suggested fix:** Replace front-removal with a head-index cursor: keep a
  `head: usize` into `token_queue`, return `token_queue.items[head]` and increment
  `head`; compact/reset when `head == items.len`. Alternatively use a
  `std.fifo.LinearFifo(Token, .Dynamic)` or `std.DoublyLinkedList`. This removes the
  per-token memmove entirely.

---

## PERF-0002 — Double-copy of every scalar/property string (scanner dupe + composer arena dupe)

- **Status:** Open
- **PerfSeverity:** P1
- **Category:** memory
- **Location:** scanner side `src/scanner.zig:1021-1022`, `1303-1304`, `1567-1568`, `1716-1717`, `793-794`, `885-886`, `952-955`, `724-725`; composer side `src/composer.zig:173-183`, `209`, `248`, `273-276`

```zig
// scanner.zig (scanPlainScalar, similar in every scan* fn)
const val = try result.toOwnedSlice(self.allocator);
try self.allocated_strings.append(self.allocator, val);   // copy #1 owned by scanner

// composer.zig composeNode(.scalar)
.v = try self.dupeInArena(doc, s.value),                  // copy #2 into the doc arena
```

- **Description:** Each user-facing string is materialized **twice**. The scanner
  builds it in a per-scalar `std.ArrayList(u8)` (`result`), `toOwnedSlice`s it into
  a freshly-allocated buffer, and tracks that buffer in `allocated_strings` (an
  extra `append` per token, plus a second free pass in `deinit`). The composer then
  calls `dupeInArena` to copy the **same bytes** into the document arena so they
  outlive the scanner. For a document that is mostly scalars (the common case), this
  doubles the bytes allocated and copied for content, plus one `allocated_strings`
  slot per token. `collectNodeMeta`/`composeNode` additionally `dupeInArena` the tag
  string (often the constant `"?"`/`"!"`) and anchor for **every** node
  (`composer.zig:175-179`), and re-dupes the anchor a third time when registering it
  (`composer.zig:181-183`). For plain unquoted scalars that contain no escapes and
  no line folding, the scanner-side `ArrayList` build is itself avoidable — the
  bytes are a contiguous slice of `input`.
- **Acceptance Criteria:**
  - For plain scalars with no escapes/folding, the scanner returns a slice into the
    original `input` (zero-copy) instead of building an `ArrayList` and duplicating.
  - The composer no longer makes a second copy of strings that already live for the
    document lifetime (e.g. scanner allocations are transferred/owned by the arena,
    or scalars referencing `input` are arena-duped exactly once).
  - Constant tag strings (`"?"`, `"!"`, `"!!"`-prefixed) are not heap-duplicated per
    node; only non-constant tags/anchors are duped, and each anchor is duped at most
    once.
  - A benchmark over a scalar-heavy document shows a reduction in total bytes
    allocated (e.g. via `std.heap.GeneralPurposeAllocator` total_requested or a
    counting allocator) of roughly the content size, and a wall-clock improvement.
- **Suggested fix:** Give plain/unfolded scalar tokens a `value` that aliases
  `input[start..end]` and a flag indicating "no allocation needed"; only fall back to
  the `ArrayList` builder when escapes, folding, or quote-doubling actually require
  transformation. Have the composer dupe into the arena once from that slice, and
  skip duping for compile-time-constant tag literals. Transfer ownership of
  genuinely-allocated scalar buffers to the arena instead of re-copying.

---

## PERF-0003 — Unbounded-growth `ArrayList`s with no capacity hints in parser/composer queues

- **Status:** Open
- **PerfSeverity:** P1
- **Category:** memory
- **Location:** `src/parser.zig:250` (event queue drain), `src/composer.zig:195-207` (seq items), `src/composer.zig:227-246` (map items), `src/scanner.zig:127/76` (`token_queue` init `.empty`)

```zig
// parser.zig
if (self.event_queue.items.len > 0) {
    return self.event_queue.orderedRemove(0);   // O(n) front removal, same class as PERF-0001
}

// composer.zig composeNode(.seq_start)
var items: std.ArrayList(NodeId) = .empty;       // no ensureTotalCapacity
while (true) { ... try items.append(self.allocator, item_id); }
const items_slice = try doc.arena.allocator().dupe(NodeId, items.items);  // then copied again
```

- **Description:** Two compounding inefficiencies. (1) `event_queue` is drained with
  `orderedRemove(0)` — the same O(n) front-shift as PERF-0001, on the parser's main
  event path. (2) Every block sequence and block mapping in `composeNode` builds a
  temporary `ArrayList` (`items`) with **no capacity reservation**, so it reallocs
  via geometric growth (1→2→4→8…), then `dupe`s the final slice into the arena and
  frees the temporary. That is: N appends with log(N) reallocs, plus a full copy into
  the arena, plus a free — per collection. `grep` confirms there are zero
  `ensureTotalCapacity`/`initCapacity` calls anywhere in `src/`. `doc.nodes` also
  grows from `.empty` with one `append` per node and no reservation.
- **Acceptance Criteria:**
  - `event_queue` drain is amortized O(1) (no `orderedRemove(0)`).
  - Collection composition either builds directly in the arena, or reserves capacity
    before the append loop, eliminating the intermediate `ArrayList` + second copy
    for sequences and mappings.
  - A counting allocator over a collection-heavy document shows fewer total
    allocations (reallocs) and no second copy of the items arrays.
- **Suggested fix:** Use a head-index cursor for `event_queue` (as in PERF-0001).
  For collections, either (a) append `NodeId`/`KVPair` straight into an arena-backed
  `std.ArrayList` so the final `dupe` is unnecessary, or (b) when the count is known
  cheaply, `ensureTotalCapacity` first. Optionally reserve `doc.nodes` capacity based
  on an input-size heuristic.

---

## PERF-0004 — `Document` (with embedded `ArenaAllocator`) copied by value through two layers

- **Status:** Partially resolved (2026-06-11 second pass)
- **PerfSeverity:** ~~P2~~ → **P3** (pointer-dangling hazard fixed; by-value copy remains)
- **Category:** memory
- **Location:** `src/composer.zig:39-60` (Document holds arena by value), `src/composer.zig:334-340` and `src/yaml.zig:340-346` (by-value move out)

```zig
// composer.zig composeAll(.doc_start) — FIXED: now stores an index, not a pointer
const doc = Document.init(self.allocator);
try self.documents.append(self.allocator, doc);
self.current_doc = self.documents.items.len - 1;   // ?usize index — stable across growth
```

- **Second-pass update:** The dangling-pointer hazard is **fixed**. `current_doc`
  is now `?usize` (`src/composer.zig:100`), set to an index
  (`src/composer.zig:154`) and dereferenced via
  `&self.documents.items[idx]` only at point of use (`src/composer.zig:160-161`),
  so appending additional documents in a multi-document stream can realloc
  `documents` without invalidating it. The **remaining** performance angle is the
  by-value `Document` move: `composer.loadAll` copies each `Document` (arena
  struct included) into a fresh `result` slice (`src/composer.zig:334-337`), and
  `yaml.loadAll` does the same again (`yaml.zig:340-343`), followed by the
  "clear list without freeing" dance (`comp.documents.items.len = 0`). This is two
  by-value moves of a struct that embeds an `ArenaAllocator`; it is only sound
  because the arena's state is pointer-stable, and it blocks reserving the
  documents vector up front. Lower impact now that correctness is assured, hence
  the drop to P3.
- **Acceptance Criteria:**
  - ~~`current_doc` is not invalidated by appending additional documents.~~ **Done.**
  - Documents are not copied by value through two layers (`composer.loadAll` then
    `yaml.loadAll`); ownership transfer avoids the double move.
  - A counting allocator over a multi-document stream shows no per-document
    struct-copy churn beyond a single hand-off.
- **Suggested fix:** Collapse the two-layer move so the inner documents slice is
  handed up once (e.g. `yaml.loadAll` wraps the composer's slice in place rather
  than re-`alloc` + copy), or box `Document` so only a pointer is moved. Reserve
  the documents vector when the document count is bounded.

---

## PERF-0005 — `parallel.zig`: global mutex per call, false sharing on result chunks, and dead in the parse path

- **Status:** Open
- **PerfSeverity:** P2
- **Category:** concurrency
- **Location:** `src/parallel.zig:12-20` (mutex per `getPool`), `src/parallel.zig:64-83` (map chunks), `src/parallel.zig:113-137` (reduce chunks); usage confirmed only at `src/yaml.zig:1013` (test) and `bench/parallel_bench.zig:58,86`

```zig
pub fn getPool() *tp.ThreadPool {
    pool_mutex.lock();              // taken on EVERY parallel call
    defer pool_mutex.unlock();
    if (global_pool == null) { ... }
    return &global_pool.?;
}
```

- **Description:** Three issues. (1) `getPool` locks `pool_mutex` on **every**
  invocation just to read an already-initialized global; after the one-time init this
  is pure contention/overhead on the parallel fast path. (2) `parallelMapArray`
  slices `results` into contiguous chunks handed to different threads
  (`results[idx..end]`); adjacent chunk boundaries share a cache line, so threads
  writing neighbouring elements cause false-sharing ping-pong — for the
  `R = i64`/`i32` element types used here, up to 8 elements straddle a 64-byte line at
  each boundary. (3) The module is not used anywhere in the actual YAML
  parse/compose/resolve pipeline — only a smoke test and the standalone
  `parallel_bench` call it — so it currently adds API/maintenance surface and a
  `page_allocator`-backed thread pool that never benefits real parsing. The bench
  also times pool spin-up inside the measured region on first use
  (`bench/parallel_bench.zig:55-61`), biasing the reported parallel numbers.
- **Acceptance Criteria:**
  - `getPool` reads the initialized pool without taking a lock on the hot path (lock
    only on the first/init transition), e.g. via `std.once`/atomic, while remaining
    thread-safe.
  - Result chunk boundaries are aligned to cache-line granularity (or chunks are
    sized/padded so no two threads write the same 64-byte line); a benchmark shows the
    parallel path no longer regresses versus sequential at the small/medium sizes
    where false sharing dominates.
  - Either the parallel API is wired into a real parsing/resolution path with a
    demonstrated speedup, or it is explicitly documented as an opt-in utility (and the
    bench excludes one-time pool init from the measured region).
- **Suggested fix:** Use `std.once` or an atomic-acquire fast path in `getPool`. Round
  chunk starts up to a cache-line multiple of `R`, or give each thread a padded
  scratch result and gather at the end. Move first-touch pool init out of the timed
  loop in the bench (warm up once before timing).

---

## PERF-0006 — Repeated full-input prescans before tokenization (UTF-8 validation + size check)

- **Status:** Open
- **PerfSeverity:** P2
- **Category:** algorithmic
- **Location:** `src/scanner.zig:107-109`, `src/limits.zig:104-108`

```zig
var checker = limits.LimitChecker.init(opts);
try checker.checkInputSize(input.len);
try limits.validateUtf8(input);     // full O(n) pass over the whole input
```

- **Description:** `Scanner.init` runs `std.unicode.utf8ValidateSlice(input)` — a full
  linear pass over the entire buffer — before tokenization begins, and tokenization
  then walks the same bytes again. For large inputs this is a second full pass over
  memory that is about to be streamed anyway. The scanner already inspects bytes
  individually as it advances, so UTF-8 well-formedness could be validated
  incrementally during the scan (only on the multi-byte sequences actually
  encountered) rather than as a separate prepass. This is a throughput tax
  proportional to input size on every parse, including the common all-ASCII case where
  validation could be a cheap SIMD/`@Vector` ASCII fast-path.
- **Acceptance Criteria:**
  - UTF-8 validation is either folded into the scan (validated as bytes are consumed)
    or short-circuited with an ASCII fast path so all-ASCII inputs avoid the full
    general-purpose validator.
  - A benchmark on a large ASCII document shows reduced parse time versus the current
    unconditional `utf8ValidateSlice` prepass, with identical rejection behavior on
    invalid UTF-8 (same error, same position class).
- **Suggested fix:** Add an ASCII fast path (`@Vector`-based byte scan for `>= 0x80`)
  and only run full UTF-8 validation on regions containing non-ASCII bytes; or validate
  continuation bytes inline in `advance`/`advanceLine` so no separate O(n) pass is
  needed.

---

## PERF-0007 — Per-`nextToken` heap allocations for tags/anchors/directives accumulated for the scanner lifetime

- **Status:** Open
- **PerfSeverity:** P3
- **Category:** memory
- **Location:** `src/scanner.zig:80-81` (`tag_directives`, `allocated_strings`), `src/scanner.zig:952-955` (tag handle+suffix dupe per tag), `src/scanner.zig:1924-1930` (`resolveTag` allocPrint per resolved tag)

```zig
// scanTag: two heap dupes per tag token, retained until scanner deinit
const alloc_handle = try self.allocator.dupe(u8, handle);
const alloc_suffix = try self.allocator.dupe(u8, suffix);
try self.allocated_strings.append(self.allocator, alloc_handle);
try self.allocated_strings.append(self.allocator, alloc_suffix);
```

- **Description:** Every tag emits two `dupe`s (handle + suffix) plus two
  `allocated_strings` appends, and `resolveTag` (called once per tagged node by the
  parser) does an `allocPrint` to concatenate prefix+suffix and stores that too. These
  buffers all live in `allocated_strings` and are individually freed one-by-one in
  `deinit` (`src/scanner.zig:154-156`). The handle/suffix slices already point into
  `input` at scan time (`self.input[...]`), so the dupes are only needed because the
  token outlives the scan position — but for handle/suffix that are slices of `input`,
  no copy is required at all. This is lower severity than PERF-0002 because tags are
  usually sparse, but on tag-heavy documents it is redundant churn plus an O(n) free
  loop at teardown.
- **Acceptance Criteria:**
  - Tag handle/suffix tokens reference `input` directly when they are unmodified
    slices of it, avoiding the per-tag dupes; only `resolveTag`'s concatenation
    allocates (ideally into the arena, freed in bulk).
  - `allocated_strings` no longer grows by 2+ entries per tag, and teardown does not do
    a per-tag individual free for slices that point into `input`.
- **Suggested fix:** Store start/end offsets into `input` for handle/suffix on the
  token and only allocate in `resolveTag`. Back `resolveTag` results with an arena so
  the per-string free loop in `deinit` is replaced by a single arena reset.

---

## PERF-0008 — JSON writer formats every integer/float via `bufPrint` + slice append

- **Status:** Open
- **PerfSeverity:** P3
- **Category:** memory
- **Location:** `src/json.zig:108-118`, `src/json.zig:231-235`

```zig
fn writeInt(self: *JsonWriter, i: i64) !void {
    var buf: [32]u8 = undefined;
    const formatted = std.fmt.bufPrint(&buf, "{d}", .{i}) catch return error.OutOfMemory;
    try self.output.appendSlice(self.allocator, formatted);
}
```

- **Description:** The `output` `ArrayList(u8)` starts `.empty` (no capacity hint), so
  serializing a large value tree reallocs the output buffer repeatedly via geometric
  growth. Numbers are formatted into a stack buffer then `appendSlice`d (an extra
  copy + a bounds/grow check per number). `writeIndent` (pretty mode) appends the
  indent string in a per-level loop (`for (0..self.depth)`), so indentation work is
  O(depth) appends per line, O(depth^2) over a deeply nested branch. None of this is on
  the core parse path (JSON output is opt-in), hence P3.
- **Acceptance Criteria:**
  - `output` reserves capacity up front based on an estimate of value-tree size (e.g.
    node count × small constant), reducing reallocs during serialization.
  - Numbers are formatted directly into the output buffer (reserve worst-case width,
    format in place, advance len) instead of stack buffer + `appendSlice`.
  - A benchmark serializing a large numeric/array-heavy value shows fewer output
    reallocs and lower wall-clock time; output bytes are byte-identical.
- **Suggested fix:** `ensureTotalCapacity` on `output` before writing; format integers
  with `std.fmt.formatInt`/`bufPrintIntToSlice` directly into reserved output space;
  precompute indentation strings or write runs with `appendNTimes`.

---

## PERF-0009 — Linear `mem.eql` chains for null/bool/inf/nan resolution per scalar

- **Status:** Open
- **PerfSeverity:** P3
- **Category:** algorithmic
- **Location:** `src/resolver.zig:187-218` (`resolveCoreSchema`), `src/resolver.zig:296-329` (`parseFloat`), `src/resolver.zig:379-393` (`parseBool`)

```zig
fn resolveCoreSchema(self: *Resolver, value: []const u8) ResolveError!Value {
    if (value.len == 0 or
        std.mem.eql(u8, value, "null") or std.mem.eql(u8, value, "Null") or
        std.mem.eql(u8, value, "NULL") or std.mem.eql(u8, value, "~")) ...
    if (parseBool(value)) |b| ...        // more eql chains
    if (parseInt(value)) |v| ...
    const float_result = try self.parseFloat(value);  // 9 more eql for inf/nan
```

- **Description:** Core-schema resolution runs every plain scalar through a cascade of
  `std.mem.eql` comparisons (null variants, then bool variants, then int parse, then a
  9-way inf/nan `eql` cascade in `parseFloat`, then `parseStdFloat` which itself scans
  the string for `.`/`e`). For the overwhelmingly common case of an ordinary string
  scalar, this is many full-length byte comparisons before falling through to the
  `str` branch. A cheap first-byte/length discriminator would reject most strings
  before any `eql`. This runs once per scalar during `resolveToValue`, so on
  scalar-heavy documents it is measurable, though far cheaper than the copies in
  PERF-0002, hence P3.
- **Acceptance Criteria:**
  - Scalar resolution dispatches on a cheap discriminator (first byte and/or length)
    before running full-string `eql`, so typical string scalars short-circuit with at
    most one or two comparisons.
  - Resolution results are unchanged for all existing tests (null/bool/int/float/str
    classification identical).
  - A benchmark resolving a string-scalar-heavy document shows reduced time in
    `resolveScalar`.
- **Suggested fix:** Switch on `value[0]` (and `value.len`) to gate the candidate set:
  only attempt null/bool/inf/nan `eql` when the first byte can start one of those
  tokens; only attempt numeric parse when the first byte is a digit/sign/`.`. Fall
  straight to `str` otherwise.

---

## PERF-0010 — `parallel_bench` reports skewed speedups (cold pool + tiny mapFn + GPA)

- **Status:** Open
- **PerfSeverity:** P3
- **Category:** config
- **Location:** `bench/parallel_bench.zig:6-7` (3 warmup / 5 runs), `bench/parallel_bench.zig:54-61` (timed region includes first pool init), `bench/parallel_bench.zig:108-110` (GPA for a perf bench)

```zig
const WARMUP_RUNS = 3;
const BENCH_RUNS = 5;
...
var timer = try std.time.Timer.start();
parallel.parallelMapArray(i64, i64, items, results_par, double);  // first call also spins up the pool
par_total += timer.read();
```

- **Description:** The benchmark's measured parallel region includes one-time thread
  pool creation on first use (`getPool` → `ThreadPool.init` on `page_allocator`),
  inflating the parallel timing and depressing reported speedup; the documented
  `WARMUP_RUNS = 3` constant is defined but never actually used to warm the pool before
  timing. The work function (`double`/`add`) is a single arithmetic op, so the loop is
  memory-bandwidth bound and the parallel version mostly measures task-dispatch
  overhead, not compute — at the small sizes it will look "[SLOW]" regardless of pool
  quality. Using a `GeneralPurposeAllocator` (with safety bookkeeping) for the data
  arrays adds allocator overhead unrelated to the parallel primitive under test.
  Net effect: the bench's numbers are not a faithful measurement of the parallel
  primitives, which undermines using it to make optimization decisions.
- **Acceptance Criteria:**
  - The thread pool is initialized (warmed) before the timed loop; the measured region
    contains only the operation under test.
  - `WARMUP_RUNS` is actually executed (discarded) before the measured `BENCH_RUNS`,
    or removed if unused.
  - The bench documents that the trivial `mapFn` measures dispatch overhead, or uses a
    non-trivial per-element cost so speedup reflects real parallel compute; data arrays
    use a low-overhead allocator (e.g. an arena or `page_allocator`) so allocator noise
    does not dominate.
- **Suggested fix:** Call `parallel.getPool()` (or one throwaway `parallelMapArray`)
  before timing; run the `WARMUP_RUNS` loop and discard it; optionally parameterize the
  work function with a heavier kernel; switch bench data allocation off the safety GPA.

---

## PERF-0011 — Per-mapping `StringHashMap` allocation for `unique_keys` (on by default)

- **Status:** RESOLVED (2026-06-11, same day) — fixed via a per-depth pool of
  reusable, heap-boxed `StringHashMap` sets on the `Composer` (`key_set_pool`).
  `keySetForDepth(depth)` returns a `clearRetainingCapacity`-d set indexed by the
  current nesting depth, so allocations are amortized to **O(distinct nesting
  depths)** (bounded by `max_depth`) instead of O(number of mappings). Sets are
  heap-boxed so the pointer handed to a mapping stays valid while deeper mappings
  grow the pool. Per-depth indexing (not a single shared set) preserves correct
  isolation across nesting — regression-tested by
  `"SEC: unique_keys isolates keys across nesting levels"` in `tests/accept.zig`
  (`{a: {a: 1}}` must not false-positive; `{p: {a: 1, a: 2}}` must still reject).
  Verified green under Debug/ReleaseSafe/ReleaseFast and the leak-detecting
  `std.testing.allocator`.
- **PerfSeverity:** P2 (resolved)
- **Category:** memory
- **Location (original):** per-`map_start` `seen_keys` init/deinit; now
  `src/composer.zig` `key_set_pool` + `keySetForDepth` + `checkDuplicateKey`.

```zig
.map_start => |meta| {
    ...
    // Allocated for EVERY mapping because unique_keys defaults to true.
    var seen_keys = std.StringHashMap(void).init(self.allocator);
    defer seen_keys.deinit();
    while (true) {
        ...
        if (self.options.unique_keys) {
            try self.checkDuplicateKey(doc, key_id, &seen_keys);  // getOrPut -> first call grows to 8 slots
        }
        ...
    }
}
```

- **Description:** Duplicate-key detection was added to `composeNode`'s `map_start`
  branch. `std.StringHashMap(void).init` itself is allocation-free (it stores the
  allocator and an empty unmanaged map; verified in std `hash_map.zig` — `init`
  sets `.unmanaged = .empty`), so an **empty** mapping (`{}`) costs nothing because
  the loop breaks on `map_end` before any `getOrPut`. But for **every non-empty
  mapping**, the first `checkDuplicateKey` call does `seen.getOrPut(key_str)`,
  which triggers `growIfNeeded` → `grow` to `minimal_capacity = 8`, i.e. one heap
  allocation of the initial metadata+keys block (≈8 × `sizeof([]const u8)` = 128 B
  for keys + 8 B metadata + alignment; values are zero-sized), plus the matching
  `deinit` free. Because `unique_keys` defaults to **true**, this is **one extra
  heap alloc + free per non-empty mapping in the document**, on the common
  `loadAll` path, even when no duplicate ever occurs and even when the caller does
  not care about duplicate-key rejection. For a mapping-heavy document (e.g. a
  large config or a list of records) this is N allocations proportional to the
  mapping count, each also paying Wyhash over every key (`getOrPut` hashes the full
  key bytes). The in-code comment "Only allocated when enforcement is on" is
  accurate but understates it: enforcement is on by default, so in practice this
  allocates for almost every document. This is a genuine NEW cost introduced by the
  unique-keys correctness fix (it did not exist when the prior PERF doc was
  written), hence P2 rather than P3 — it is on the default hot path and scales with
  document structure.
- **Acceptance Criteria:**
  - The per-mapping hash set is not heap-allocated for small mappings: e.g. a
    linear-scan fallback for mappings below a threshold (say ≤ 8–16 keys, where
    O(k²) `mem.eql` beats a hash-set alloc), only promoting to a `StringHashMap`
    for larger mappings; or a single reusable, `clearRetainingCapacity`-d set hung
    off the `Composer` so the allocation is amortized once for the whole parse
    instead of once per mapping.
  - A counting allocator over a document with many small mappings shows the
    allocation count no longer grows linearly with the number of mappings (one
    amortized allocation, or zero for the small-mapping fast path), with identical
    `DuplicateKey` behavior on all existing tests.
  - A wall-clock benchmark on a mapping-heavy document (e.g. thousands of small
    mappings) shows reduced parse time versus the per-mapping-alloc baseline.
- **Suggested fix:** Hoist a single `StringHashMap(void)` (or a small
  `std.ArrayList([]const u8)` for the linear-scan path) onto the `Composer` and
  `clearRetainingCapacity()` it at each `map_start` instead of `init`/`deinit` per
  mapping — this turns N allocations into 1 (amortized, reused across all mappings
  in the stream). For the common case of tiny mappings, a stack/inline linear scan
  avoids the hash machinery entirely. Skip the structure when
  `options.unique_keys == false`.

## PERF-0012 — Emitter `currentColumn()` back-scans to last newline on every flow separator

- **Status:** Resolved (2026-06-11) — replaced `currentColumn()` with
  `lineExceeds(limit)` (`src/emitter.zig`), which stops scanning as soon as the
  column passes `limit`. The back-scan is now O(min(line_length, max_line_width))
  per separator instead of O(line_length), bounding the worst case to the wrap
  width. Emitter-only and default-inactive (`max_line_width` defaults to 0).
- **PerfSeverity:** P3
- **Category:** algorithmic
- **Location:** `src/emitter.zig:226-234` (`currentColumn`), `src/emitter.zig:239-246`
  (`flowSeparatorBreak`), called from `emitFlowSeq` (`src/emitter.zig:248-258`) and
  `emitFlowMap` (`src/emitter.zig:318-330`)

```zig
fn currentColumn(self: *const Emitter) usize {
    var col: usize = 0;
    var i = self.buffer.items.len;
    while (i > 0) {                       // back-scan to the last '\n'
        i -= 1;
        if (self.buffer.items[i] == '\n') break;
        col += 1;
    }
    return col;
}

fn flowSeparatorBreak(self: *Emitter, cont_indent: usize) EmitError!void {
    if (self.opts.max_line_width > 0 and self.currentColumn() > self.opts.max_line_width) { ... }
    ...
}
```

- **Description:** `max_line_width` flow wrapping (new in this changeset) measures
  the current output column by scanning `self.buffer` backward to the previous
  newline once per flow-item separator. Within a single flow line that has not yet
  been wrapped, successive separators scan a monotonically growing suffix, so
  emitting N flow items on one un-wrapped line is O(N²) in the bytes scanned. This
  is **bounded and not on the parse path**:
  1. **Emit/serialize only.** `currentColumn` is reachable solely from
     `emitFlowSeq`/`emitFlowMap`; the scan/parse/compose/resolve pipeline never
     calls it. The hot parse path is unaffected.
  2. **Inactive by default.** `EmitOptions.max_line_width` defaults to `0`
     (`src/emitter.zig:43`). Zig's `and` short-circuits, so when wrapping is off
     `flowSeparatorBreak` takes the `else` branch (`write(" ")`) and never calls
     `currentColumn` at all — zero overhead in the default configuration.
  3. **Self-bounding when on.** Once a line passes `max_line_width`, a `"\n"` is
     emitted and the next back-scan resets; steady-state scan length is bounded by
     `max_line_width` (a `u16`, typically ~80). The quadratic is confined to one
     not-yet-wrapped line and capped near the wrap width, not the document size.
  Hence P3.
- **Acceptance Criteria:**
  - The current column is tracked incrementally (e.g. a `col` field on the emitter
    advanced by `write`/`writeIndent` and reset to 0 on `"\n"`) instead of
    re-derived by a backward buffer scan, making `flowSeparatorBreak` O(1).
  - Emitted bytes are byte-identical for all existing emitter tests across
    `max_line_width` = 0 and > 0.
  - A benchmark dumping a single wide flow collection (e.g. thousands of items)
    with `max_line_width > 0` shows wall-clock scaling linearly with item count
    rather than quadratically.
- **Suggested fix:** Maintain `self.column: usize` on the `Emitter`; increment it
  in `write`/`writeIndent` by the number of bytes written since the last newline
  (reset to 0 whenever a `'\n'` is written), and read it directly in
  `flowSeparatorBreak`. This removes the back-scan entirely and is O(1) per
  separator. `confidence::confirmed` (static analysis; default config exercises
  none of this code).

## Notes & non-findings

- The scanner's core advance loop is genuinely single-pass O(n) for the common path;
  the per-token lookaheads (`look_pos` scans to detect implicit keys) are bounded by
  line length, not document length, and are not quadratic in practice for normal
  input. They are not flagged.
- Resource-limit / amplification concerns (alias expansion, depth, node count) are
  intentionally excluded — see `docs/APPSEC_REVIEW_2026-06-11.md`.
- All findings above are static-analysis-confidence; each acceptance criterion
  specifies the benchmark/measurement that would confirm the win before closing.
- **(second pass) Resolver re-resolution is not flagged.** Removing the alias
  `resolved_cache` makes alias expansion O(Σ references × subtree_size) instead of
  memoized, but it is bounded by the resolver's `max_nodes` budget
  (`src/resolver.zig:101-104`) and produces a correct owned tree. The CPU cost is
  the intended tradeoff; see "Assessment: resolver re-resolution" above. `confidence::confirmed`.
- **(second pass) `nextEvent` depth bookkeeping is not flagged.** The
  `pushDepth`/`popDepth` calls added to the streaming path
  (`src/parser.zig:258-264`) are branch-only O(1) integer ops on collection
  boundaries with no allocation; negligible. See "Assessment: nextEvent depth
  bookkeeping" above. `confidence::confirmed`.
- **(third pass) Scanner §7.3/§8.1.3 fold-flush restructure is not flagged.** The
  break-run counter + single deferred flush (`break_count`/`pending_breaks` in
  `scanDoubleQuoted`/`scanSingleQuoted`/`scanPlainScalar`,
  `src/scanner.zig:1028-1038`, `1311-1320`, `1641-1767`) is O(1) amortized: each
  input break char is counted once, each output byte appended once, and a run is
  flushed at most once (the guard resets the counter to 0). It adds one
  comparison per character in the quoted-scalar loops — no asymptotic change.
  `confidence::confirmed`.
- **(third pass) Resolver core/JSON numeric parsers are not flagged.**
  `parseIntCore`/`parseIntJson`/`parseJsonFloat` (`src/resolver.zig:505-587`) are
  single-pass O(scalar_len) and allocation-free until classification; they call
  non-allocating `std.fmt.parseInt`/`parseFloat` and only `dupe` on i64 overflow
  (`.big`) or the string fallthrough (unchanged from prior behavior).
  `confidence::confirmed`.
- **(third pass) Streaming depth check on `nextEvent` is not flagged (re-confirmed).**
  The added `pushDepth`/`popDepth` on `seq_start`/`map_start`/`seq_end`/`map_end`
  (`src/parser.zig:256-269`) remain branch-only O(1) ops on collection boundaries.
  `confidence::confirmed`.
