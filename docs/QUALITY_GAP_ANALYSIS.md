# Quality Gap Analysis — zig-yaml

Code-quality review of the Zig YAML 1.2 parser library (`src/*.zig`, `build.zig`,
`Makefile`, `scripts/detect_diamond_deps.py`). ~7,946 LOC.

- Toolchain at review time: Zig 0.16.0 (`build.zig.zon` declares
  `minimum_zig_version = "0.15.1"`).
- Build state: `zig build test` passes (`Build Summary: 15/15 steps succeeded;
  176/176 tests passed`) on Zig 0.16.0 after a full `rm -rf .zig-cache` clean.
- Method: every finding below is backed by a `file:line` citation that was read
  and, where feasible, reproduced. Confirmed-by-execution findings are marked.

## Second-pass re-review (2026-06-11)

A remediation pass landed (working tree vs HEAD) addressing the highest-severity
findings. This review verified the new code and tests. Outcome:

- **Resolved:** QUAL-0001 (double-free), QUAL-0002 (`loadAllWithDetails`
  ownership/location), QUAL-0003 (version drift), QUAL-0004 (`@ptrCast` layout
  guard). Marked `Status: Resolved` below with verification notes.
- **Still open:** QUAL-0005..QUAL-0017 (unchanged; not in scope of this pass).
- **New:** QUAL-0018 (`unique_keys` dedups on raw scalar text, not canonical
  value — partial vs spec), QUAL-0019 (resolver alias-cache removal is a
  potential perf cliff for legitimate heavy alias reuse — non-blocking),
  QUAL-0020 (`.zig-cache` incremental state can wedge the build; a full clean is
  required to trust green — tooling/DX note).

## Third-pass re-review (2026-06-11, ~1460-line YAML-compliance changeset)

A large feature changeset (~1460 lines across `resolver.zig`, `scanner.zig`,
`validate.zig`, `emitter.zig`, `json.zig`, `parser.zig`, `composer.zig`,
`error.zig`, `yaml.zig`, plus tests) implementing 18 YAML compliance gaps was
re-reviewed for quality. Build verified green: `zig build test --summary all` →
`15/15 steps succeeded; 194/194 tests passed` (Zig 0.16.0). Outcome:

- **No regressions in prior Resolved findings.** QUAL-0001 (`resolved_cache`
  still absent), QUAL-0003 (version still single-sourced via `build_info`),
  QUAL-0004 (layout guards intact at `yaml.zig:956-962`) all verified
  still-resolved.
- **Materially improved by this changeset (acceptance criteria now met):**
  - **QUAL-0010 → Resolved.** New `parseIntCore`/`parseIntJson`/`parseJsonFloat`
    (`resolver.zig:506-585`) replace `std.fmt.parseInt` for schema resolution.
    Verified by probe: `1_000`→str, `0755`→str, `+42`→int, `0x1F`/`0o17`→int,
    `i64::MAX`→int, overflow→big_int. Conformance gap closed for the
    core/json schema path. (Residual MIN-as-big_int noted in **QUAL-0023**.)
  - **QUAL-0018 → Resolved (documentation criterion).** The `unique_keys`
    semantics (scalar-content dedup; non-scalar and canonically-equal scalars
    not deduplicated) are now explicitly documented on the public option
    (`yaml.zig:103-112`) and the enforcement is implemented and tested
    (`composer.zig:308-340`). The "document the limitation" acceptance
    criterion is met; the optional stronger canonical-dedup remains future work.
- **New findings:** QUAL-0021 (Low — quoted-scalar folding flush lacks the
  `result.items.len > 0` guard the plain/block folders have, emitting a spurious
  leading space; verified by probe), QUAL-0022 (Low — explicit `!!int` tag path
  still routes through the looser legacy `parseInt`, diverging from the new
  strict `parseIntCore` used by schema resolution), QUAL-0023 (Low — `i64::MIN`
  resolves to `big_int` rather than `int`; lossless but not strictly the
  `!!int` value QUAL-0010 specified).
- **Net assessment:** the changeset is high quality. Error handling is careful
  (checked sexagesimal arithmetic, errdefer cleanup in `resolveSeq`/`resolveMap`,
  typed `error.UnsupportedKey` instead of silent `<complex>` key collision,
  `error.MaxDepthExceeded`/`MaxNodesExceeded` budgets that correctly bound
  alias-amplification). The `one_of` validator fix (`validate.zig:206-214`)
  correctly frees all four owned error strings, matching the `deinit` free
  pattern. **No new High or Critical quality issue exists.**

Severity legend: Critical (memory safety / data loss / crash), High (incorrect
behavior or contract break likely to bite users), Medium (maintainability or
robustness risk), Low (polish / minor correctness edge / docs).

## Table of Contents

| ID | Severity | Category | Status | Title |
|----|----------|----------|--------|-------|
| QUAL-0001 | Critical | reliability | Resolved | `freeValue` double-frees shared anchor/alias subtrees (resolver cache aliasing) |
| QUAL-0002 | High | reliability | Resolved | `loadAllWithDetails` leaks documents on `a.alloc` failure |
| QUAL-0003 | High | api | Resolved | Library version is inconsistent across `src/yaml.zig`, `build.zig.zon`, and git tags |
| QUAL-0004 | High | maintainability | Resolved | `@ptrCast` type-punning between public `Value`/`Node` and inner types is fragile and undocumented |
| QUAL-0005 | Medium | reliability | Open | `parseFloat`/`parseFloat11` return `Value{ .str = "" }` as a non-float sentinel |
| QUAL-0006 | Medium | deadcode | Open | Unused public/private helpers: `composer.loadAll`, `getCanonicalTag`, scanner lookahead helpers, `ParseError.name` |
| QUAL-0007 | Medium | duplication | Open | Schema/number/tag-inference logic is reimplemented 3+ times across resolver, debug_json, emitter |
| QUAL-0008 | Medium | api | Open | `ParseOptions` → inner `parser_mod.ParseOptions` mapping is copy-pasted in 4 functions |
| QUAL-0009 | Medium | maintainability | Open | `i64`-min and underscore handling differ between `parseInt` (core) and `parseInt11` (yaml11) |
| QUAL-0010 | Medium | reliability | Resolved | `parseInt` accepts grammatically-invalid integers via `std.fmt.parseInt` quirks |
| QUAL-0011 | Medium | docs | Partially resolved | Comptime parser silently truncates/over-runs fixed-size buffers with no diagnostic |
| QUAL-0012 | Low | api | Open | `ParseError.format()` uses a shared static buffer (documented foot-gun, but still a hazard) |
| QUAL-0013 | Low | maintainability | Open | `LimitChecker` has three near-identical constructors |
| QUAL-0014 | Low | docs | Open | `pending_key` scanner field is dead state; many scanner state fields are undocumented |
| QUAL-0015 | Low | maintainability | Open | `scanNextToken` is a ~400-line monolith with deeply duplicated tab/`:` validation |
| QUAL-0016 | Low | api | Open | `loadAll` duplicates document-move logic already present in `composer.loadAll` |
| QUAL-0017 | Low | docs | Open | Public reader/file APIs depend on caller's `reader()` shape with no documented contract |
| QUAL-0018 | Low | reliability | Resolved | `unique_keys` dedups on raw scalar text, not canonical/resolved key value |
| QUAL-0019 | Low | performance | Open | Resolver alias-cache removal can quadratically re-materialize heavily-reused anchors |
| QUAL-0020 | Low | tooling | Open | Incremental `.zig-cache` state can wedge `zig build test`; full clean needed to trust green |
| QUAL-0021 | Low | reliability | **Resolved** | Added the `result.items.len > 0` guard to both quoted fold flushes (`src/scanner.zig`); a leading line break no longer emits a spurious space. Tests `QUAL-0021*` |
| QUAL-0022 | Low | duplication | **Resolved** | Documented the intentional split: `parseInt` is the lenient explicit-`!!int` parser, schema resolution stays strict via `parseIntCore` (doc comment on `src/resolver.zig` `parseInt`) |
| QUAL-0023 | Low | reliability | **Resolved** | `parseIntCore`/`parseIntJson` decimal branches now parse the full signed value, so `i64::MIN` resolves to `.int`. Tests `QUAL-0023*` |

---

## QUAL-0001 — `freeValue` double-frees shared anchor/alias subtrees

- **Status:** Resolved (2026-06-11)
- **Severity:** Critical
- **Category:** reliability
- **Location:** `src/resolver.zig:85-113` (cache), `src/resolver.zig:42-61` (`freeValue`)

**Resolution (verified):** The `resolved_cache` was removed entirely
(`src/resolver.zig:68-95`). `resolve()` now expands each alias by *re-resolving*
its target subtree (`resolver.zig:131-137`), so every `*alias` produces an
independent copy with no shared heap pointers — the resolved `Value` is a true
tree that `freeValue` owns and releases exactly once. Cycle detection is
preserved independently via the `visiting` set (`resolver.zig:116-121`).
Amplification from this change is bounded by new node/depth budgets
(`countNode`/`enterDepth`, see QUAL-0019). Regression coverage added in
`tests/accept.zig:643-668` (`SEC F-01: *` — map, seq, scalar, multi-alias,
nested, reused-as-value) plus errdefer-path tests
(`tests/accept.zig:879-917`), all under `std.testing.allocator` (detects
double-free and leaks). `zig build test` → 176/176 pass.

```zig
// resolver.zig:91-112 — resolve() returns the *cached* Value for repeat node ids
if (self.resolved_cache.get(node_id)) |cached| {
    return cached;                 // shallow copy: same heap pointers
}
...
try self.resolved_cache.put(node_id, result);
return result;
```

```zig
// resolver.zig:42 — freeValue walks the tree and frees every slice it sees
pub fn freeValue(allocator: std.mem.Allocator, value: *const Value) void { ... }
```

**Description:** When a document contains an anchor referenced by more than one
alias (e.g. `base: &a [1,2,3]` with `*a` used twice), `Resolver.resolve` caches
the resolved `Value` and returns the *same* `Value` — including the same
heap-allocated `.seq`/`.map`/`.str`/`.big_int` pointers — for every alias site.
The resulting `Value` tree is therefore a DAG with shared sub-objects, not a
tree. `freeValue` recurses structurally and frees each shared slice once per
reference, producing a double free / heap corruption.

Reproduced on Zig 0.16.0 with the testing allocator: the program aborts with
`SIGABRT` inside `freeValue` (`resolver.zig:55` → `yaml.zig:564`) for input
containing two aliases to one anchor. This is a use-after-free/double-free
reachable from the public `resolveToValue` + `freeValue` API with ordinary
valid YAML, so it is exploitable as a crash/DoS and corrupts the heap.

**Acceptance Criteria:**

- A test parses YAML with one anchor and ≥2 aliases, calls `resolveToValue`
  then `freeValue`, and passes under `std.testing.allocator` (no leak, no double
  free) in Debug and ReleaseSafe.
- The resolved value model has a single, documented ownership rule (either:
  deep-copy each alias expansion so the tree is a true tree, or reference-count /
  arena-own the values so `freeValue` frees each allocation exactly once).
- A fuzz/property test that frees every resolved document from the YAML test
  suite passes without allocator errors.

**Suggested fix:** Remove the structural-sharing optimization for owned values,
or make resolved `Value` trees arena-owned (free the whole arena at once instead
of walking pointers). If the cache is kept for cycle/perf reasons, have each
alias expansion `dupe` its subtree so no two `Value`s share a heap pointer.
Cycle detection (`visiting`) can be preserved independently of the value cache.

---

## QUAL-0002 — `loadAllWithDetails` leaks documents on allocation failure

- **Status:** Resolved (location contract) / Partially addressed (OOM branch)
- **Severity:** High
- **Category:** reliability
- **Location:** `src/yaml.zig:401-411`

**Resolution (verified):** The synthesized error location is now normalized:
the `a.alloc` OOM branch emits `line = 1, col = 1` (`src/yaml.zig:404-409`)
instead of `0,0`, and the composer/parser fall-through branches clamp with
`@max(1, …)` (`src/yaml.zig:378-399`). The ">= 1" location contract is now
enforced by a new test, `tests/accept.zig` (`yaml: loadAllWithDetails composer
error has location >= 1`, `src/yaml.zig:1052-1068`), which drives the
composer-only `duplicate_key` path (historically `line=0`) and asserts
`err.line >= 1 and err.col >= 1`.

**Residual (not blocking, no separate finding):** the *ownership* concern in the
original finding — the OOM branch relying on `defer comp.deinit()` to free the
already-composed `inner_docs` — is unchanged; there is still no
`std.testing.FailingAllocator` test exercising the `a.alloc` failure path. The
behavior is correct as written (the move that zeroes `items.len` happens only on
success, so `deinit` still owns the docs in the OOM branch), but the acceptance
criterion "OOM branch covered by a failing-allocator test" is not yet met. Track
under QUAL-0002 if a failing-allocator harness is added later.

```zig
const result = a.alloc(Document, inner_docs.len) catch {
    return .{ .documents = &.{}, .parse_error = ParseError{ .code = .internal_error, ... } };
};
```

**Description:** `composeAll()` returns `inner_docs`, a slice of fully
constructed `composer.Document` values, each owning an arena, a `nodes`
ArrayList, and an `anchors` hashmap. If the subsequent `a.alloc(Document, ...)`
fails (OOM), the function returns early with `documents = &.{}` and never
deinits the already-composed `inner_docs`. Because `comp.documents.items.len`
is only zeroed on the success path (line 418), the `defer comp.deinit()` *will*
still free them in this specific path — but the success path then sets
`items.len = 0` so the moved-out docs are owned by the caller. The OOM branch is
inconsistent with that ownership protocol and relies on subtle interaction with
`deinit`; any future change to the move logic turns this into a leak. The error
`Value` is also constructed with `line = 0, col = 0` which violates the
"location info ≥ 1" contract asserted in the tests at `yaml.zig:976-979`.

**Acceptance Criteria:**

- The OOM branch of `loadAllWithDetails` is covered by a failing-allocator test
  (e.g. `std.testing.FailingAllocator`) that shows zero leaks and zero double
  frees regardless of which allocation fails.
- Error `ParseError`s returned from this function use `line`/`col` ≥ 1 (or the
  contract is explicitly relaxed and the test updated).

**Suggested fix:** On `a.alloc` failure, explicitly `for (inner_docs) |*d| d.deinit();`
before returning (or restructure so `comp.deinit()` is solely responsible and
the move happens last). Normalize the synthesized error location to `1,1`.

---

## QUAL-0003 — Library version is inconsistent across sources

- **Status:** Resolved (2026-06-11)
- **Severity:** High
- **Category:** api
- **Location:** `src/yaml.zig:49-58`, `build.zig.zon:3`

**Resolution (verified):** Version is now single-sourced from `build.zig.zon`.
`build.zig:12-16` creates a `build_info` options module
(`build_info.addOption([]const u8, "version", @import("build.zig.zon").version)`)
and imports it into the yaml, unit-test, and check modules (`build.zig:48,59,175`).
`src/yaml.zig:49-55` sets `version_string = build_info.version` and derives the
`std.SemanticVersion` by parsing that string at comptime (with a `@compileError`
if the manifest version is not valid semver). The hard-coded `0.2.0` literal is
gone, so `yaml.version`, `yaml.version_string`, and `build.zig.zon`'s `.version`
cannot drift. Covered by `tests/accept.zig`-adjacent test (`yaml: version is
single-sourced from build.zig.zon`, `src/yaml.zig:1070-1074`).

```zig
// src/yaml.zig
pub const version = std.SemanticVersion{ .major = 0, .minor = 2, .patch = 0, ... };
pub const version_string = "0.2.0";
```

```zon
// build.zig.zon
.version = "0.1.4",
```

**Description:** The library exposes `yaml.version` / `yaml.version_string` as
`0.2.0`, while the package manifest (`build.zig.zon`) and the most recent git
tags/commits (`v0.1.4`, "bump to v0.1.4") declare `0.1.4`. Consumers that gate
on `yaml.version` get a different answer than the package manager. This is a
public-API correctness/consistency defect that erodes trust in the version
contract and breaks any compatibility check.

**Acceptance Criteria:**

- `yaml.version_string`, the `std.SemanticVersion` literal, and
  `build.zig.zon`'s `.version` all report the identical version.
- A test (or a CI check / pre-commit hook) asserts the three stay in lockstep,
  or the in-source constant is derived from a single source of truth.

**Suggested fix:** Pick one source of truth. Either generate the Zig constants
from `build.zig.zon` at build time (via a generated file/option), or add a test
that string-compares `version_string` against the manifest and a Makefile
`release` step that updates both.

---

## QUAL-0004 — `@ptrCast` type-punning between public and inner types is fragile

- **Status:** Resolved (2026-06-11)
- **Severity:** High
- **Category:** maintainability
- **Location:** `src/yaml.zig:263-267` (`Document.node`), `561-565` (`freeValue`),
  `835-871` (`convertValue` / `convertValueToInner`)

**Resolution (verified):** A `comptime` layout-guard block now fails the build
the moment the punned type pairs diverge (`src/yaml.zig:874-912`).
`assertSameSizeAlign` checks `@sizeOf`/`@alignOf`; `assertSameUnionTags` walks
the tag enums and checks tag name + value equality pairwise. The `comptime {}`
block asserts the layout of `Value`↔`resolver_mod.Value`,
`ValueKVPair`↔`resolver_mod.ValueKVPair`, and `Node`↔`composer_mod.Node`. Any
reordered/added tag or changed field in only one of a pair becomes a compile
error with a descriptive message rather than silent UB. This satisfies
acceptance criterion (b).

**Residual (note, not blocking):** the guard covers top-level size/align and
union tag identity, not per-field `@offsetOf` of every nested struct
(`NodeMeta`, slice element layout). For the current flat unions this is
sufficient (a field-type change shifts `@sizeOf`/`@alignOf` and trips the
guard), but a same-size field swap inside a payload struct could still slip
through. Re-exporting the inner types (acceptance criterion (a)) would eliminate
the pun entirely and remains the stronger fix.

```zig
// yaml.zig:846-853 — "convert" by reinterpreting memory, NOT recursing
.seq => |items| { return .{ .seq = @ptrCast(items) }; },
.map => |items| { return .{ .map = @ptrCast(items) }; },
```

```zig
// yaml.zig:264-266 — Node returned by reinterpreting composer.Node
return @ptrCast(self.inner.node(id));
```

**Description:** The public `yaml.Value`/`yaml.Node` and the internal
`resolver_mod.Value`/`composer_mod.Node` are kept byte-compatible and converted
by `@ptrCast`/`@alignCast` rather than by structural conversion. `convertValue`
even comments "we can't allocate here / memory layout is compatible." This is an
implicit, compiler-unchecked invariant: the two `union(enum)` declarations and
their field structs (including `NodeMeta`, `ValueKVPair`, slice element layout)
must remain bit-identical forever. Zig does not guarantee layout equivalence of
two distinct types, and reordering a single tag or field in `resolver.Value`
silently produces undefined behavior with no test or comptime guard. This is the
single biggest latent maintainability hazard in the codebase.

**Acceptance Criteria:**

- Either (a) the public types are replaced by `pub const Value = resolver_mod.Value;`
  re-exports (eliminating the pun entirely), or (b) a `comptime` assertion block
  verifies `@sizeOf`, `@alignOf`, and per-field `@offsetOf` equality for every
  punned type pair, failing the build on divergence.
- No `@ptrCast` between the two type families remains without an adjacent
  comptime layout assertion.

**Suggested fix:** Prefer re-exporting the inner types from `yaml.zig` (the
wrapper structs add little beyond doc comments). If a separate public surface is
required, add a `comptime { std.debug.assert(@sizeOf(A) == @sizeOf(B)); ... }`
guard next to each cast and a unit test that round-trips a nested value.

---

## QUAL-0005 — Float parsers use `Value{ .str = "" }` as a non-float sentinel

- **Status:** Open
- **Severity:** Medium
- **Category:** reliability
- **Location:** `src/resolver.zig:293`, `src/resolver.zig:328`

```zig
// resolver.zig:296-329 parseFloat()
// Not a float
return Value{ .str = "" };
```

**Description:** `parseFloat`/`parseFloat11` return a `Value` even though their
only legitimate outputs are float-like. To signal "not a float" they return
`Value{ .str = "" }` — an in-band sentinel. Callers (`resolveCoreSchema`,
`resolveYaml11Schema`) `switch` on the result and treat any non-`float`/`inf`/`nan`
as "fall through to string." This works only because the sentinel happens to be
a `.str`; it conflates "the value is the empty string" with "parse failed," and
the `.str` payload is a non-owned empty literal while every other `.str` in the
resolver is allocator-owned (`dupe`d). A future change that frees resolver
strings uniformly would try to free a string literal.

**Acceptance Criteria:**

- `parseFloat`/`parseFloat11` return `?Value` (or a dedicated result enum), and
  callers branch on the optional rather than inspecting a sentinel payload.
- No code path can emit a non-owned `.str` into a resolved value tree that is
  later passed to `freeValue`.

**Suggested fix:** Change the signature to `ResolveError!?Value` returning `null`
for "not a float," and have callers do `if (try self.parseFloat(value)) |f| return f;`.

---

## QUAL-0006 — Dead code: unused helpers and fields

- **Status:** Open
- **Severity:** Medium
- **Category:** deadcode
- **Location:**
  - `src/composer.zig:296-312` — `pub fn loadAll` (no caller in `src/` or `tests/`)
  - `src/resolver.zig:589-600` — `pub fn getCanonicalTag` (no caller)
  - `src/scanner.zig:1981-1985` `skipWhitespaceFrom`, `1995-2000` `skipComment`,
    `2015-2029` `skipWhitespaceAndComments` (defined, never called)
  - `src/scanner.zig:82,133` — `pending_key: bool` (set once to `false`, never read)
  - `src/error.zig:66` / `src/yaml.zig` — `ParseError.name` (declared, never assigned;
    only ever read as the always-empty default)

**Description:** Several public and private symbols are never referenced.
`composer.loadAll` duplicates `yaml.loadAll`. `getCanonicalTag` is superseded by
`debug_json.getResolvedTag`. Three file-scope `skip*` lookahead helpers in the
scanner are dead (the scanner uses inline loops instead). `pending_key` is
vestigial scanner state. `ParseError.name` is a "backwards compatibility" field
that is read in `yaml.zig:225` (`.context = pe.name`) but is never set, so it
always passes the empty string. Dead code inflates the surface, confuses readers
about which path is authoritative, and hides the real data flow (e.g. the
`name`/`context` duality).

**Acceptance Criteria:**

- Each listed symbol is either removed, or has a real caller / test that
  exercises it.
- `ParseError` has a single context field with a clear, exercised purpose; the
  `name` vs `context` duplication is resolved.
- A grep for each removed symbol returns no matches in `src/` and `tests/`.

**Suggested fix:** Delete `composer.loadAll`, `getCanonicalTag`, the three unused
scanner `skip*` helpers, and `pending_key`. Collapse `ParseError.name` into
`context` (or delete it and the `.context = pe.name` read).

---

## QUAL-0007 — Number/tag-inference logic duplicated across modules

- **Status:** Open
- **Severity:** Medium
- **Category:** duplication
- **Location:** `src/resolver.zig:379-438,446-527`,
  `src/debug_json.zig:216-406`, `src/emitter.zig:314-399`

**Description:** The "what type does this scalar look like" logic exists in at
least three independent copies:

- `resolver.zig`: `parseBool`, `parseInt`, `parseStdFloat`, `parseBool11`,
  `parseInt11`, sexagesimal parsing.
- `debug_json.zig`: `inferScalarTag`, `looksLikeInt`, `looksLikeInt11`,
  `looksLikeFloat` (re-implements the same null/bool/int/float classification).
- `emitter.zig`: `needsQuoting` + `looksLikeNumber` (re-implements number/reserved-
  word detection to decide quoting).

The null literals (`null`/`Null`/`NULL`/`~`), bool literals, inf/nan spellings,
and octal/hex/binary prefixes are spelled out verbatim in multiple places. These
copies can (and likely will) drift: e.g. `debug_json.looksLikeInt` does not
handle YAML 1.1 underscores or `0o`/leading-zero octal the same way `parseInt11`
does in every branch, so the debug tag and the resolved value can disagree.

**Acceptance Criteria:**

- Scalar classification (is-null / is-bool / is-int / is-float, per schema) lives
  in one module and is imported by resolver, debug_json, and the emitter's
  quoting decision.
- A test feeds a corpus of scalars through both the resolver and the tag-inference
  path and asserts they agree for every schema.

**Suggested fix:** Extract a `scalar_kind.zig` (or add to `resolver.zig`) with a
single `classify(value, schema) -> {null,bool,int,float,str}` plus the reserved-
word sets, and have all three consumers call it.

---

## QUAL-0008 — `ParseOptions` → inner options mapping is copy-pasted

- **Status:** Open
- **Severity:** Medium
- **Category:** api
- **Location:** `src/yaml.zig:202-210, 321-329, 351-359, 546-554`

```zig
const inner_opts = parser_mod.ParseOptions{
    .schema = convertSchema(o.schema),
    .unique_keys = o.unique_keys,
    .max_bytes = o.max_bytes,
    .max_depth = o.max_depth,
    .max_nodes = o.max_nodes,
    .max_aliases = o.max_aliases,
    .max_scalar_bytes = o.max_scalar_bytes,
};
```

**Description:** This exact 8-line struct-building block is repeated four times
(`Parser.init`, `loadAll`, `loadAllWithDetails`, `resolveToValue`). Adding a new
option requires editing all four sites; missing one silently drops the option on
some entry points. The two `ParseOptions` types are field-for-field identical
except for the `schema` enum, so the duplication carries no real abstraction
benefit.

**Acceptance Criteria:**

- A single helper (e.g. `fn toInnerOptions(o: ParseOptions) parser_mod.ParseOptions`)
  is the only place that maps public→inner options, and all four call sites use it.
- Adding a field to `ParseOptions` requires editing exactly one mapping site.

**Suggested fix:** Add `fn toInnerOptions(o: ParseOptions) parser_mod.ParseOptions`
in `yaml.zig` and replace the four inline blocks. Better: make `parser_mod.Schema`
a re-export of `yaml.Schema` so even `convertSchema` disappears.

---

## QUAL-0009 — `i64`-min and underscore handling differ between integer parsers

- **Status:** Open
- **Severity:** Medium
- **Category:** maintainability
- **Location:** `src/resolver.zig:395-425` (`parseInt`), `467-527` (`parseInt11`)

**Description:** `parseInt11` strips underscores before decimal parsing
(`resolver.zig:517-525`) and supports binary, leading-zero octal, and
sexagesimal; `parseInt` (core schema) supports none of those and never strips
underscores. Beyond the intended schema differences, both share the
"parse magnitude then negate" structure (`return if (negative) -v else v;`) with
no shared helper, so the octal/hex branches are duplicated almost verbatim
(`resolver.zig:411-420` vs `489-504`). This duplication is a drift risk: a fix
to hex parsing in one is unlikely to be mirrored in the other.

**Acceptance Criteria:**

- The shared radix-prefix handling (`0x`/`0o`) is implemented once and reused by
  both parsers, with schema-specific extras (binary, leading-zero octal,
  sexagesimal, underscores) layered on top.
- Tests cover `i64::MIN`, `i64::MAX`, and `+`/`-` for both schemas.

**Suggested fix:** Factor a `parseRadix(s, negative) ?i64` helper used by both;
keep schema-specific prefixes in the respective callers.

---

## QUAL-0010 — `parseInt` accepts grammatically-invalid integers

- **Status:** Resolved (2026-06-11, third pass)
- **Severity:** Medium
- **Category:** reliability
- **Location:** `src/resolver.zig:506-547` (`parseIntCore`/`parseIntJson`),
  `src/resolver.zig:549-585` (`parseJsonFloat`)

**Resolution (verified):** Schema int/float detection no longer delegates to
`std.fmt.parseInt` for grammar validation. New `parseIntCore` (`resolver.zig:506`)
validates the core grammar explicitly (`[-+]?[0-9]+` with no leading zero, plus
`0o`/`0x`) before parsing, `parseIntJson` (`resolver.zig:535`) validates the
JSON grammar (decimal, optional `-`, no `+`, no leading zero), and
`parseJsonFloat` (`resolver.zig:549`) implements the JSON-number grammar by hand.
Overflow is preserved as `big_int` via the `IntResult` union rather than falling
through to string. Verified by probe under `std.testing.allocator`:
`1_000`→`str` (no underscores in core), `0755`→`str` (leading-zero decimal not a
core int), `+42`→`int`, `0x1F`/`0o17`→`int`, `i64::MAX`→`int`,
`9223372036854775808`→`big_int`. The first acceptance criterion (`1_000` is a
string under core/json, underscores only under yaml11) is met. The
most-negative-value criterion is partially met — see **QUAL-0023** (MIN is now
preserved losslessly as `big_int` rather than as a string, but not as `int`).

```zig
const v = std.fmt.parseInt(i64, s, 10) catch return null;
```

**Description:** Core-schema int detection delegates to `std.fmt.parseInt`, which
accepts inputs the YAML 1.2 core schema does **not** treat as integers — notably
`std.fmt.parseInt` accepts internal `_` separators (e.g. `1_000`) and a leading
`+`/`-` per Zig's grammar. The core schema regexp is
`[-+]?[0-9]+ | 0o[0-7]+ | 0x[0-9a-fA-F]+`, with **no** underscores. As a result,
`1_000` resolves to the integer `1000` under the core schema in this library,
whereas a conformant YAML 1.2 processor resolves it to the *string* `"1_000"`.
This is a silent conformance/correctness gap (the value's type and downstream
JSON output change). Conversely, `i64::MIN` (`-9223372036854775808`) fails to
parse (magnitude overflows `i64`) and falls back to a string, so the most-
negative integer is mishandled.

**Acceptance Criteria:**

- `1_000` (and similar underscore forms) resolves to `!!str` under `core`/`json`
  schemas; underscores are only accepted under `yaml11`.
- `-9223372036854775808` resolves to `!!int` with value `i64::MIN`.
- Tests assert both behaviors against the YAML test suite expectations.

**Suggested fix:** Validate the integer grammar explicitly (or parse the
magnitude as the digits only and reject stray `_`/signs for core), and special-
case the most-negative value (parse as `i65`/`i128` then range-check, or detect
the exact MIN literal).

---

## QUAL-0011 — Comptime parser silently overflows fixed buffers

- **Status:** Partially resolved (2026-06-11)
- **Severity:** Medium → Low (bounds now diagnosed; docs still incomplete)
- **Category:** docs (also reliability)
- **Location:** `src/comptime.zig:164` (`items: [256]Value`), `201` (`[128]`),
  `332`/`365` (`[64]`), `107` (`indent_stack: [64]usize`)

**Partial resolution (verified):** Four `@compileError` bounds guards were added
so over-long collections now produce a clear, actionable diagnostic instead of a
raw index-out-of-bounds:

- block sequence > 256 items (`src/comptime.zig:185`)
- block mapping > 128 keys (`src/comptime.zig:237`)
- flow sequence > 64 items (`src/comptime.zig:348`)
- flow mapping > 64 keys (`src/comptime.zig:390`)

This satisfies the second acceptance criterion (clear `@compileError` naming the
limit). **Still open:** the module doc comment (`src/comptime.zig:6-17`) does not
yet list these concrete caps, and the `indent_stack: [64]usize` nesting cap
(`comptime.zig:107`) has **no** guard — exceeding 64 levels of nesting still
produces a raw bounds failure. Lower severity to Low and keep open until the
header documents the caps and the indent-stack guard is added.

```zig
fn parseSequence(self: *Parser, seq_indent: usize) Value {
    var items: [256]Value = undefined;
    var count: usize = 0;
    while (...) { items[count] = ...; count += 1; }   // no bound check
```

**Description:** The comptime parser writes into fixed-size stack arrays without
bounds checks: sequences cap at 256 items, mappings at 128, flow collections at
64, and indentation nesting at 64. At comptime, an over-long input triggers a
hard `@compileError`-style index-out-of-bounds (acceptable but cryptic); the
documented "subset of YAML" limits (`comptime.zig:6-17`) do not mention these
size caps at all. A user embedding a moderately large config gets an opaque
compiler error with no hint that the limit is 256 items.

**Acceptance Criteria:**

- The module doc comment lists the concrete size limits (items/keys/flow/nesting).
- Exceeding a limit produces a clear `@compileError` with the limit and the
  field name, not a raw bounds-check failure.

**Suggested fix:** Add `if (count >= items.len) @compileError("comptime YAML: too many sequence items (max 256)");`
guards, and document the caps in the header.

---

## QUAL-0012 — `ParseError.format()` returns a shared static buffer

- **Status:** Open
- **Severity:** Low
- **Category:** api
- **Location:** `src/error.zig:94-104`

```zig
pub fn format(self: ParseError) []const u8 {
    const S = struct { var buf: [256]u8 = undefined; };
    return self.formatBuf(&S.buf);
}
```

**Description:** `format()` returns a slice into a single process-global static
buffer. The doc comment warns about it, but it is still a thread-unsafe, re-entrancy-
unsafe foot-gun on a `pub` API: two errors formatted "simultaneously" (or one
held across a second `format()` call) silently corrupt each other. The library
otherwise advertises thread-pool parallelism (`parallel.zig`), making a global
mutable buffer especially incongruous.

**Acceptance Criteria:**

- `format()` is either removed in favor of `formatBuf(caller_buffer)` /
  `formatError(allocator)`, or it is documented as not thread-safe and excluded
  from any parallel code path (and a test asserts the buffer-reuse caveat).

**Suggested fix:** Deprecate/remove `format()`; steer callers to `formatBuf`
(caller-owned buffer) or `yaml.formatError` (allocator-owned).

---

## QUAL-0013 — `LimitChecker` has three near-identical constructors

- **Status:** Open
- **Severity:** Low
- **Category:** maintainability
- **Location:** `src/limits.zig:30-65` (`init`, `initFromParseOptions`, `initWithDefaults`)

**Description:** `LimitChecker` exposes `init(anytype)` (field-probing via
`@hasField`), `initFromParseOptions(anytype)` (assumes all fields present), and
`initWithDefaults()`. They overlap heavily; `init` and `initFromParseOptions`
are both called from the codebase (`scanner` uses `init`, `parser`/`composer`
use `initFromParseOptions`) with the same `ParseOptions` value, just differing in
defensiveness. Two ways to build the same thing from the same input invites
divergence (e.g. a new limit added to one constructor but not the other).

**Acceptance Criteria:**

- A single constructor strategy is used for `ParseOptions` inputs across scanner,
  parser, and composer.
- Adding a new limit field requires updating one place.

**Suggested fix:** Keep `init(anytype)` (handles partial structs and full
`ParseOptions` alike) and `initWithDefaults`; remove `initFromParseOptions` and
update the two callers.

---

## QUAL-0014 — Vestigial / undocumented scanner state

- **Status:** Open
- **Severity:** Low
- **Category:** docs
- **Location:** `src/scanner.zig:82-94`

**Description:** The `Scanner` struct carries ~15 boolean/optional flags that
encode subtle YAML disambiguation state (`flow_after_value`, `map_value_line`,
`block_entry_line`, `block_map_started_line`, `has_root_value`,
`seen_yaml_directive`, `pending_directive`, `doc_start_line`, …). Most have a
one-line inline comment, but the interactions (which flags are mutually
exclusive, when each is reset — several are cleared only in `advanceLine`) are
undocumented, and `pending_key` (line 82) is dead (see QUAL-0006). For a 2,000-
line hand-written scanner this is the primary onboarding obstacle.

**Acceptance Criteria:**

- A short "scanner state machine" doc block (in-file or `docs/`) explains the
  lifetime/reset rules of each per-line and per-document flag.
- Dead flags are removed.

**Suggested fix:** Add a state-field reference table at the top of `Scanner`,
group per-line flags (reset in `advanceLine`) vs per-document flags (reset on
`---`/`...`), and delete `pending_key`.

---

## QUAL-0015 — `scanNextToken` is a 400-line monolith with duplicated validation

- **Status:** Open
- **Severity:** Low
- **Category:** maintainability
- **Location:** `src/scanner.zig:293-690`

**Description:** `scanNextToken` is a single ~400-line function. Within it, the
"tab-in-separator after an indicator" validation is copy-pasted three times for
`-`, `?`, and `:` (`scanner.zig:482-503`, `520-541`, `615-636`) with only the
indicator set differing, and the "is this scalar/anchor/tag/alias followed by `:`
so it's a map key" lookahead is reimplemented separately in `scanAnchor`,
`scanAlias`, `scanTag`, `scanDoubleQuoted`, `scanSingleQuoted`, and
`scanPlainScalar`. The lookahead helper functions that would consolidate this
(`isValueIndicatorAt`, `skipSpacesFrom`) exist but are only partially used.

**Acceptance Criteria:**

- The tab-in-separator check is a single helper called from the `-`/`?`/`:` arms.
- The "followed by `:` ⇒ map key" lookahead is one helper reused by the scalar/
  anchor/tag/alias scanners.
- `scanNextToken` is decomposed so no single function exceeds a reviewable size.

**Suggested fix:** Extract `fn rejectTabBeforeIndicator(self, after_pos)` and
`fn isImplicitKeyHere(self, start_col) bool`, route all indicator arms and
scanners through them, and split flow vs block handling into sub-functions.

---

## QUAL-0016 — `loadAll` duplicates the document-move dance

- **Status:** Open
- **Severity:** Low
- **Category:** maintainability
- **Location:** `src/yaml.zig:336-344`, `src/composer.zig:296-312`

**Description:** The "alloc a result slice, copy composed docs in, then
`comp.documents.items.len = 0` to transfer ownership without freeing" pattern is
implemented identically in `yaml.loadAll`, `yaml.loadAllWithDetails`, and the
(dead, see QUAL-0006) `composer.loadAll`. Setting `items.len = 0` directly is a
non-obvious ownership transfer that bypasses the ArrayList API and is easy to get
wrong; centralizing it would make the invariant explicit and testable.

**Acceptance Criteria:**

- A single `composer` API (e.g. `takeDocuments(allocator) ![]Document`) performs
  the move and is used by both public load functions.
- The raw `documents.items.len = 0` assignment appears in exactly one place.

**Suggested fix:** Add `Composer.takeDocuments` that allocs the result, moves the
docs, and clears the internal list; call it from both `loadAll` and
`loadAllWithDetails`; delete `composer.loadAll`.

---

## QUAL-0017 — Reader/file APIs depend on undocumented `reader()` shape

- **Status:** Open
- **Severity:** Low
- **Category:** docs
- **Location:** `src/yaml.zig:441-456, 494-510`

```zig
pub fn loadAllFromReader(a, reader: anytype, o) ![]Document {
    const content = try reader.readAllAlloc(a, o.max_bytes);
```

**Description:** `loadAllFromReader`/`streamEventsFromReader` accept `anytype`
and call `reader.readAllAlloc(a, max)`, and `loadAllFromFile` passes
`file.reader()`. The required reader shape (`readAllAlloc(allocator, max)`) is
not documented, and the exact `reader()` API changed across recent Zig std
versions (the `Io.Reader` reorganization). With the stated 0.15.1→0.16.0 range,
callers cannot tell from the signature or docs what interface they must supply,
and the file path silently couples to whatever `std.fs.File.reader()` returns in
the active toolchain. There is no test exercising the reader/file entry points
(grep finds no `loadAllFromReader`/`loadAllFromFile` callers in `tests/`).

**Acceptance Criteria:**

- The doc comments state the exact reader contract (`readAllAlloc(allocator, max)`),
  the ownership of the returned buffer, and the supported Zig version(s).
- At least one test exercises `loadAllFromReader` (e.g. with a fixed-buffer
  stream) so the contract is enforced by CI.

**Suggested fix:** Document the reader requirement, add a `std.io`-based smoke
test, and consider taking a concrete reader type (or a `[]const u8` plus a
separate helper) rather than `anytype` to make the contract compiler-checked.

---

## QUAL-0018 — `unique_keys` deduplicates on raw scalar text, not canonical key value

- **Status:** Resolved (2026-06-11, third pass — documentation criterion met)
- **Severity:** Low
- **Category:** reliability (conformance)
- **Location:** `src/composer.zig:323-340` (`checkDuplicateKey`),
  `src/yaml.zig:103-112` (public `unique_keys` doc)

**Resolution (verified):** The primary acceptance criterion — document the
scalar-source-text semantics on the public option — is met. The `unique_keys`
doc comment (`yaml.zig:103-112`) now states explicitly that duplicate detection
compares scalar key *content* (catching plain vs quoted spellings), that
non-scalar keys are not deduplicated, and that canonically-equal scalars with
different spellings (`0x1` vs `1`, yaml11 `yes` vs `true`) are treated as
distinct. `checkDuplicateKey` (`composer.zig:323`) carries the same caveat
inline. The optional stronger fix (dedup on resolved canonical value) remains
future work but is not required by the acceptance criteria. Per-depth key-set
pooling (`keySetForDepth`, `composer.zig:308`) is correctly designed: sets are
heap-boxed so the pointer handed to a mapping stays valid while deeper mappings
grow the pool, and siblings at a depth reuse a cleared set — no aliasing bug.

```zig
// composer.zig:296-307
fn checkDuplicateKey(self: *Self, doc: *Document, key_id: NodeId, seen: *std.StringHashMap(void)) ComposerError!void {
    const key_node = doc.node(key_id);
    const key_str = switch (key_node.*) {
        .s => |s| s.v,
        else => return, // only scalar keys are deduplicated
    };
    const gop = try seen.getOrPut(key_str);
    if (gop.found_existing) { self.last_error_name = "duplicate key"; return error.DuplicateKey; }
}
```

**Description:** The new `unique_keys` enforcement (which correctly closes
GAP-0003 and is well-tested for the common case) deduplicates on the raw scalar
*source text* of the key, with two documented-but-incomplete edges:

1. **Non-scalar keys are never deduplicated** (`else => return`). `{? [a]: 1, ? [a]: 2}`
   and `{? {x: 1}: a, ? {x: 1}: b}` pass even with `unique_keys = true`. The
   inline comment states this intentionally, so it is a known limitation, but it
   diverges from the YAML spec, which defines key uniqueness on the *resolved*
   key for all node kinds.
2. **Canonically-equal scalars that differ in source text are treated as
   distinct.** Under the `yaml11`/`core` schemas, `{0x1: a, 1: b}` (both resolve
   to int `1`) and `{yes: a, true: b}` (yaml11 bools) are accepted, because
   dedup compares `"0x1"` vs `"1"` as strings. GAP-0003's own suggested fix said
   to dedup "per the spec, on the resolved/canonical key"; the implementation
   dedups on raw text instead.

The common cases (`{a: 1, a: 2}`, plain vs quoted `a` / `"a"` — same bytes) are
handled correctly and tested (`tests/accept.zig` `SEC: unique_keys *`,
`src/yaml.zig:1052-1068`). This is a conformance gap, not a safety bug.

**Acceptance Criteria:**

- The limitation is documented in the public `unique_keys` doc comment
  (`src/yaml.zig` / `docs/API.md`): "duplicate detection compares scalar key
  source text; canonically-equal scalars with different spellings and non-scalar
  keys are not deduplicated."
- (Optional, stronger) dedup keys on their resolved canonical value so
  `{0x1: a, 1: b}` and collection keys are caught.

**Suggested fix:** At minimum, document the scalar-source-text semantics on the
public option. If spec-conformant dedup is desired, key the `seen` set on the
resolved scalar value (and add collection-key hashing) rather than `s.v`.

---

## QUAL-0019 — Resolver alias-cache removal can quadratically re-materialize reused anchors

- **Status:** Open (non-blocking; documented tradeoff)
- **Severity:** Low
- **Category:** performance
- **Location:** `src/resolver.zig:113-138` (`resolve`), `131-137` (alias branch)

**Description:** Removing `resolved_cache` (the QUAL-0001 fix) means an alias is
resolved by **re-walking and re-allocating its entire target subtree on every
reference**. This is the correct and necessary fix for the double-free (each
expansion must be independently owned), and abusive amplification is now bounded
by the `max_nodes` (default 1M) and `max_depth` budgets. However, for *legitimate*
input that reuses one large anchor many times — e.g. a 10k-node anchored config
block referenced 50 times — resolution cost and peak memory are now
`O(references × subtree_size)` instead of the previous `O(subtree_size)`. A
document that previously resolved cheaply via the cache can now do ~50× the work
and allocate ~50× the memory (until it trips the node budget). This is a
deliberate security/correctness-over-speed tradeoff, called out here so it is a
known, intentional characteristic rather than a surprise regression.

**Acceptance Criteria (if ever revisited):**

- If alias-heavy throughput becomes a concern, reintroduce sharing safely via a
  reference-counted or arena-owned value model so `freeValue` frees each
  allocation exactly once (the path QUAL-0001's acceptance criteria already
  anticipated), rather than a raw shared-pointer cache.
- Otherwise: document in `docs/` that alias expansion is O(refs × subtree) and
  bounded by `max_nodes`, so operators size `max_nodes` accordingly.

**Suggested fix:** None required now. Note the complexity in the resolver/limits
docs; consider arena-owned resolved values if a future perf pass needs sharing.

---

## QUAL-0020 — Incremental `.zig-cache` state can wedge `zig build test`

- **Status:** Open (tooling / DX)
- **Severity:** Low
- **Category:** tooling
- **Location:** build/test workflow (no single source line)

**Description:** During this review, a partial cache clean (`rm -rf
.zig-cache/o .zig-cache/h`) left the incremental cache in an inconsistent state
that produced **two different spurious failures** on successive runs: first a
phantom compile error (`tests/accept.zig:851: error set is discarded — _ = err;`
pointing at source that no longer contained that statement), then a phantom
runtime failure (`accept.test.poc: alias to alias chain` failing inside
`loadAll`). A full `rm -rf .zig-cache` cleared both, after which the suite is
deterministically green (`15/15 steps succeeded; 176/176 tests passed`) on both
cold and warm runs. Separately, the `zig build` wrapper exit code observed
through a shell pipe was an unreliable `0` even when the build summary reported a
failed step, so **`zig build test`'s textual `Build Summary` line — not the
process exit code — is the trustworthy pass/fail signal** in this environment.

This is not a defect in the library code; it is a build/CI reliability note. If
CI keys off the exit code alone and reuses a warm `.zig-cache`, a wedged cache
could either mask a real failure or surface a phantom one.

**Acceptance Criteria:**

- CI parses the `Build Summary`/`tests passed` line (or runs `zig build test`
  with a clean cache on the gating job) rather than trusting the exit code alone.
- A short note in `docs/`/CONTRIBUTING about doing a full `rm -rf .zig-cache`
  (not a partial subdir clean) when the build behaves inconsistently.

**Suggested fix:** Add a CI assertion on the summary text and/or a clean-cache
gate; document the full-clean guidance for contributors.

---

## QUAL-0021 — Quoted-scalar fold flush lacks the empty-buffer guard

- **Status:** Open
- **Severity:** Low
- **Category:** reliability (conformance edge)
- **Location:** `src/scanner.zig:1031-1038` (double-quoted),
  `src/scanner.zig:1318-1325` (single-quoted)

```zig
// scanner.zig:1031 — double-quoted break-run flush (no result.items.len guard)
if (ch != '\n' and ch != '\r' and break_count > 0) {
    if (break_count == 1) {
        try result.append(self.allocator, ' ');
    } else {
        for (0..break_count - 1) |_| try result.append(self.allocator, '\n');
    }
    break_count = 0;
}
```

**Description:** The new §7.3 line-folding restructure introduced a pending
break-run that is flushed when the next non-break character is reached. The
**plain-scalar** flush (`scanner.zig:1758-1766`) and the **block-folded** flush
(`scanner.zig:1579-1593`) both guard the flush with `if (result.items.len > 0)`,
so a scalar that *opens* with a line break does not emit a leading fold space.
The **double-quoted** (`1031`) and **single-quoted** (`1318`) flushes omit that
guard. Result: a quoted scalar whose content begins with a line break emits a
spurious leading space.

Reproduced with the value-resolution probe under `std.testing.allocator`:
`"\n  foo"` resolves to `" foo"` (leading space) and `'\n  foo'` likewise. The
normal multi-line cases are correct — `"foo\n  bar"`→`"foo bar"`,
`"foo\n\n  bar"`→`"foo\nbar"`, `"foo\n\n\n  bar"`→`"foo\n\nbar"` — so this is a
narrow first-line edge, not a folding-logic defect. It is both a minor
conformance edge and an avoidable inconsistency across the three otherwise-
parallel folding implementations.

**Acceptance Criteria:**

- The quoted flushes guard with `if (result.items.len > 0)` so a leading line
  break does not emit a leading space, matching the plain/block folders.
- A test asserts `"\n  foo"` and `'\n  foo'` resolve without a leading space.

**Suggested fix:** Wrap the `1031` and `1318` flush bodies in
`if (result.items.len > 0) { ... }`, mirroring `scanner.zig:1759`.

---

## QUAL-0022 — Explicit `!!int` tag uses looser legacy `parseInt`

- **Status:** Open
- **Severity:** Low
- **Category:** duplication / maintainability
- **Location:** `src/resolver.zig:170` (call site), `src/resolver.zig:441-471`
  (`parseInt`), vs `src/resolver.zig:506-547` (`parseIntCore`/`parseIntJson`)

**Description:** The QUAL-0010 fix added strict `parseIntCore`/`parseIntJson`
for schema-based resolution, but the explicit `!!int` tag path
(`resolveExplicitTag`, `resolver.zig:170`) still calls the **legacy** `parseInt`
(line 441), which delegates to `std.fmt.parseInt` and therefore accepts
underscores (`1_000`), leading-zero octal-as-decimal quirks, and leading `+`
inside the radix branches — the exact looseness QUAL-0010 removed from the
schema path. So `!!int 1_000` and `!!int 0755` resolve to integers, while bare
`1_000`/`0755` correctly resolve to strings. The codebase now has two core-int
parsers with divergent grammars (`parseInt` at 441 used only for explicit tags,
`parseIntCore` at 506 used for schemas), which is a drift hazard: a future fix
to one is unlikely to be mirrored in the other (this is QUAL-0009/QUAL-0007
duplication, now narrowed to the explicit-tag path).

The behavior is *defensible* (an explicit `!!int` tag is the author forcing
integer interpretation, so leniency is arguably acceptable), so this is a
maintainability/consistency finding, not a correctness bug.

**Acceptance Criteria:**

- The explicit `!!int` path and the schema-resolution path share one integer
  grammar/parser (or the intentional difference is documented at both sites).
- A test pins the chosen `!!int 1_000` / `!!int 0755` behavior so it cannot
  drift silently.

**Suggested fix:** Route `resolveExplicitTag`'s int case through `parseIntCore`
(returning `big_int` on overflow, consistent with the schema path), or add a
comment at `resolver.zig:170` and `441` documenting the deliberate leniency and
a test that locks it in. Removing `parseInt` in favor of `parseIntCore` would
also close part of QUAL-0009.

---

## QUAL-0023 — `i64::MIN` resolves to `big_int` instead of `int`

- **Status:** Open
- **Severity:** Low
- **Category:** reliability (conformance edge)
- **Location:** `src/resolver.zig:493-503` (`applySign`), `506-531` (`parseIntCore`)

```zig
fn applySign(neg: bool, parsed: std.fmt.ParseIntError!i64) ?IntResult {
    if (parsed) |v| {
        return IntResult{ .int = if (neg) -v else v };
    } else |err| return switch (err) {
        error.Overflow => IntResult.big,
        error.InvalidCharacter => null,
    };
}
```

**Description:** `parseIntCore` parses the *unsigned magnitude* with
`std.fmt.parseInt(i64, ...)` and applies the sign afterward in `applySign`. For
`-9223372036854775808` (`i64::MIN`), the magnitude `9223372036854775808`
overflows `i64` (max magnitude `9223372036854775807`), so `parseInt` returns
`error.Overflow`, `applySign` returns `.big`, and the sign is never applied —
the value is preserved as `big_int` (the exact source text). `i64::MIN` is a
*valid* `i64`, so a fully conformant resolver would yield `int = -9223372036854775808`.

This is strictly better than the pre-QUAL-0010 behavior (which fell through to a
*string*) and is lossless, so it is a low-severity precision edge, not a
regression. Verified by probe: `-9223372036854775808` → `big_int -9223372036854775808`.

**Acceptance Criteria:**

- `-9223372036854775808` resolves to `!!int` with value `i64::MIN` (or the
  big_int fallback is explicitly documented as the intended behavior for the
  boundary).
- A test pins the chosen behavior.

**Suggested fix:** In `parseIntCore`/`parseIntJson`, when the unsigned-magnitude
parse overflows *and* `neg` is set, retry by parsing the full signed string
(`std.fmt.parseInt(i64, value, base)`) which handles `i64::MIN` directly; only
return `.big` if that also overflows. Alternatively special-case the exact MIN
literal.

---

## Notes / Non-findings

- **Third pass (2026-06-11):** `zig build test --summary all` →
  `15/15 steps succeeded; 194/194 tests passed` on Zig 0.16.0. The
  ~1460-line YAML-compliance changeset was reviewed in full. New code reviewed
  positively (no new finding) includes: the resolver node/depth budgets
  (`countNode`/`enterDepth`, `resolver.zig:88-111`) which correctly bound
  alias-amplification (each `resolve()` counts exactly one materialized node;
  aliases re-count their whole expansion); checked sexagesimal arithmetic
  (`resolver.zig:686-698`, no panic/wrap on overflow); the `one_of` validator
  fix (`validate.zig:206-214`) which frees all four owned error strings matching
  the `deinit` free pattern; `globMatch` (`validate.zig:401-426`, iterative,
  bounded, no allocation/recursion); the emitter line-wrapping (`currentColumn`
  scan-back is bounded by `max_line_width` and short-circuited when width is 0,
  not quadratic); `json.zig` `UnsupportedKey` (typed error replacing silent
  `<complex>` key collision; `big_int` keys now serialize their text);
  `composer.current_doc` switched from a dangling pointer to a growth-stable
  index (`composer.zig:97-101`); and the `%YAML` major-version gate
  (`scanner.zig:747-753`, rejects 2.0/0.9, accepts 1.x — verified by probe).
- `zig build test` passes on Zig 0.16.0 at review time
  (`15/15 steps succeeded; 176/176 tests passed`) after a full `rm -rf
  .zig-cache`; the thread-pool dep (now pinned to `v0.2.5`,
  `build.zig.zon:8-9`) resolved from `zig-pkg/` (no network needed).
- The new SEC/poc tests added in this pass assert *meaningful* conditions, not
  just "no crash": F-01 tests run under `std.testing.allocator` (detects
  double-free and leaks), F-02/F-03/node-budget tests assert the specific
  `error.MaxNodesExceeded`/`MaxDepthExceeded` and fail if resolution
  unexpectedly *succeeds* (`tests/accept.zig:691-704`), the depth boundary test
  asserts off-by-one (depth N allowed at `max_depth=N`, rejected at `N-1`,
  `tests/accept.zig:920-943`), and the errdefer tests assert exact error types.
  The streaming-parser test also confirms `getLastError().code ==
  .max_depth_exceeded`. These are strong assertions.
- The scanner's correctness heuristics (tab handling, implicit-key detection)
  are intricate but appear functional and test-backed; they are flagged here only
  for maintainability/duplication (QUAL-0014, QUAL-0015), not correctness.
- `scripts/detect_diamond_deps.py` is well-documented and self-contained; no
  quality gaps identified beyond its own stated scope.
