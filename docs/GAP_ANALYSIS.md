# Gap Analysis — Zig YAML Library

Requirements-to-code gap analysis derived from the repository's own documentation and
stated intent. There is no external issue tracker access for this run; requirements are
taken from `README.md`, `docs/API.md`, `docs/ARCHITECTURE.md`, `CHANGELOG.md`, and the
public API surface in `src/yaml.zig`.

- **Date:** 2026-06-11 (third pass — FINAL verification after all remaining gaps were implemented)
- **Toolchain used for verification:** Zig 0.16.0 (CI-pinned `ZIG_VERSION: "0.16.0"`)
- **Baseline build/test state (third pass):** `zig build test` → **green (exit 0)**;
  `zig build test --summary all` → **194/194 tests passed** across all modules
  (62 in `tests/accept.zig` incl. 21 `GAP-00NN` regression tests, plus per-module
  test runs), all under `std.testing.allocator` (detects leaks/double-free).
  `zig build test-suite` → **compiles and runs**, exiting 0 gracefully
  (`Failed to open test suite directory: error.FileNotFound`) when the corpus is
  absent; CI fetches the corpus and runs it as a tracking signal.
  `zig build check` → exit 0.

## Third-pass verification summary (2026-06-11) — ALL GAPS CLOSED

Every previously-open gap (GAP-0001, GAP-0004 … GAP-0018) has been implemented and
**verified Closed** against current code + tests. GAP-0002 and GAP-0003 were already
closed in the second pass and remain closed (re-verified). The library now reports
**zero open gaps**.

| Gap | Prior | Now | One-line verdict |
|---|---|---|---|
| GAP-0001 | High (Open) | **Closed** | Tree comparison implemented + CI `test-suite` job + README claim scoped; corpus is an external CI fetch by design |
| GAP-0002 | Closed | **Closed** (re-verified) | Aliases deep-resolve to independent trees; resolve+free clean under leak detector |
| GAP-0003 | Closed | **Closed** (re-verified) | `unique_keys` enforced in composer; sibling-map false-positive ruled out by probe |
| GAP-0004 | Medium (Open) | **Closed** | `max_line_width` wraps flow collections (`emitter.zig` `currentColumn`/`flowSeparatorBreak`) |
| GAP-0005 | Medium (Open) | **Closed** | Real glob matcher + public `yaml.schema.pattern` |
| GAP-0006 | High (Open) | **Closed** | Unsupported `%YAML` major rejected → `error.UnsupportedYamlVersion`/`unsupported_yaml_version` |
| GAP-0007 | Medium (Open) | **Closed** | Core schema rejects leading-zero decimals → string |
| GAP-0008 | Medium (Open) | **Closed** | JSON schema restricted numeric parser (decimal only) |
| GAP-0009 | Low (Open) | **Closed** | Overflowing plain int → `big_int` under core/json |
| GAP-0010 | High (Open) | **Closed** | Folded scalar preserves breaks around more-indented lines |
| GAP-0011 | Medium (Open) | **Closed** | Quoted/plain blank-line folding (`break_count`/`pending_breaks`) |
| GAP-0012 | Medium (Open) | **Closed** | Complex `?`/`:` keys (collection/mapping/multiline) parse + resolve |
| GAP-0013 | Medium (Open) | **Closed (documented)** | `dumpAll` alias-inlining documented; graph-level preservation clarified |
| GAP-0014 | Low (Open) | **Closed** | Non-specific tag standardized to `"?"` across parser/composer/`NodeMeta` |
| GAP-0015 | Low (Open) | **Closed** | `int_range` handles `.big_int` consistently |
| GAP-0016 | Low (Open) | **Closed** | Public `yaml.schema.oneOf` + real `one_of` error-string leak fix |
| GAP-0017 | Medium (Open) | **Closed** | `toJson` rejects non-scalar keys (`error.UnsupportedKey`); big_int keys unique |
| GAP-0018 | Low (Open) | **Closed (documented)** | Comptime subset + caps documented; OOB `@compileError` bounds guards added |

- **New bugs introduced this pass:** **NONE.** No new Critical/High *bug*
  (memory-safety, crash, or wrong-result-on-valid-input) exists. The three
  highest-risk rewrites were adversarially probed:
  - **Resolver numeric rewrite** (`parseIntCore`/`parseIntJson`/`parseJsonFloat`,
    `big_int`): verified across core/json/yaml11 for `-0`, `+5`, `00`, `0x`, `0o`,
    20+ digit overflow (both signs), `1.`, `.5`, `1e` — no crash, no leak,
    internally consistent.
  - **Scanner folding restructure** (`break_count`/`pending_breaks`/
    `prev_more_indented`): verified folded clip/strip/keep, more-indented at
    first/last/middle, blank-line runs, empty/only-blank scalars, literal,
    and quoted/plain multi-break folding — no crash, no leak.
  - **Validate `one_of` leak fix**: verified every-alternative-fails (owned
    `allocPrint` messages freed), early-success break path, nested seq-of-oneof,
    big_int range both signs, pattern backtracking — clean under the leak detector.
  - **Bonus hardening verified safe:** `limits.hard_max_depth` clamp (prevents
    native-stack overflow when `max_depth` is raised) and comptime fixed-buffer
    `@compileError` bounds checks (prevent OOB writes).

- **Open gap count after this pass:** **0.**

## Method & Evidence Standard

Every closed gap below cites a documented promise (doc + heading), a concrete code
location (`file:line`), and the passing regression test that verifies it. All findings
were corroborated by `zig build test` (194/194 green under the leak-detecting allocator)
and by targeted adversarial probe programs run under `std.heap.DebugAllocator` (written
to `/tmp`, deleted after use; no tracked file was modified during verification).

---

## Status Breakdown

| Documented capability | Status |
|---|---|
| Streaming event parser (`Parser`, `streamEvents`) | Implemented |
| `loadAll` / `loadAllWithDetails` / `loadAllFromReader` / `loadAllFromFile` | Implemented |
| Document graph (anchors/aliases preserved) | Implemented |
| Value resolution: `failsafe` schema | Implemented |
| Value resolution: `json` schema | Implemented (GAP-0008 Closed) |
| Value resolution: `core` schema | Implemented (GAP-0007, GAP-0009 Closed) |
| Value resolution: `yaml11` schema | Implemented |
| Anchors/aliases resolution + cycle detection | Implemented (GAP-0002 Closed) |
| Multi-document streams (`---`/`...`) | Implemented |
| `%TAG` directive | Implemented |
| `%YAML` directive (version semantics) | Implemented (GAP-0006 Closed) |
| Tags (verbatim/`!!`/`!local`) | Implemented (tag-default standardized, GAP-0014 Closed) |
| Block scalars: literal `\|` | Implemented |
| Block scalars: folded `>` (more-indented lines) | Implemented (GAP-0010 Closed) |
| Quoted/flow line folding (blank-line semantics) | Implemented (GAP-0011 Closed) |
| Complex/explicit `?` keys (multi-line/collection) | Implemented (GAP-0012 Closed) |
| `unique_keys` option | Implemented (GAP-0003 Closed; scalar-only, documented) |
| `max_line_width` emit option | Implemented (GAP-0004 Closed) |
| Resource limits (bytes/depth/nodes/aliases/scalar) | Implemented (+ `hard_max_depth` clamp) |
| Emitter options (indent/doc markers/styles/quotes) | Implemented |
| Round-trip fidelity for anchors/aliases | Documented (GAP-0013 Closed: graph-level only; `dumpAll` inlines) |
| Validation: primitives + most combinators | Implemented |
| Validation: `pattern` constraint | Implemented (GAP-0005 Closed; glob) |
| Validation: `int_range` on big integers | Implemented (GAP-0015 Closed) |
| Validation: `one_of` public builder | Implemented (GAP-0016 Closed) |
| JSON conversion (`toJson`) | Implemented (GAP-0017 Closed: non-scalar keys rejected) |
| Comptime parsing | Implemented (GAP-0018 Closed; subset documented, bounds-guarded) |
| yaml-test-suite tree comparison + CI wiring | Implemented (GAP-0001 Closed; corpus is external CI fetch) |

### Open gap counts by severity (after third pass)

| Severity | Count | Gap IDs |
|---|---|---|
| Critical | 0 | — |
| High | 0 | — |
| Medium | 0 | — |
| Low | 0 | — |

**Total open gaps: 0.** All 18 tracked gaps are Closed/Resolved (see Resolved Gaps section).

> No open gap remains, and no open gap is a *bug*. No new Critical/High bug was
> introduced by the closure work.

---

## Resolved Gaps (all 18 tracked gaps)

Each entry: requirement source → resolution evidence (`file:line`) → regression test.

### GAP-0001 — yaml-test-suite tree comparison + CI wiring — **Closed**

- **Severity:** High → Closed
- **Requirement:** `README.md:15-19` (YAML 1.2.2 conformance via yaml-test-suite);
  the shipped `tests/yaml_test_suite.zig` runner.
- **Resolution evidence:**
  - Runner compiles/runs under Zig 0.16.0; `eventsToTreeFormat` rewritten to the
    official flat event format (`tests/yaml_test_suite.zig:31-94`) and `compareTrees`
    added with `+DOC`/`-DOC` marker normalization (`:101-127`).
  - Comparison is wired into `runTestCase` (`tests/yaml_test_suite.zig:344-356`):
    the emitted event tree is compared against each case's `tree` expectation, not
    just parse-success.
  - CI job added: `.gitlab-ci.yml:150-167` (`test-suite`) fetches the upstream
    corpus and runs `zig build test-suite` (`allow_failure: true` tracking signal).
  - README compliance claim scoped from "Full … support" to "Broad … support …
    being driven toward full coverage" (`README.md:15-19`).
  - The corpus itself is an external fixture fetched by CI (not vendored); this is
    the documented resolution. The runner skips gracefully if the corpus is absent.
- **Regression tests:** `tests/yaml_test_suite.zig:592` (tree serialization),
  `:601` (marker normalization), `:611` (real structural mismatch detected).

### GAP-0002 — alias-to-anchored-collection double-free — **Closed (re-verified)**

- **Severity:** Critical → Closed
- **Resolution evidence:** Resolver expands each alias into an independent copy of its
  target subtree (`src/resolver.zig:131-137`); `freeValue` owns a true tree
  (`src/resolver.zig:44-64`). Adversarial probe (alias to anchored map with nested
  seq, used twice) resolves+frees clean under the leak detector.
- **Regression tests:** `tests/accept.zig:645-673` (`SEC F-01`), `:675-702` (`SEC F-02`,
  billion-laughs bounded by `max_nodes`/`max_depth`).

### GAP-0003 — `unique_keys` not enforced — **Closed (re-verified)**

- **Severity:** High → Closed
- **Resolution evidence:** Enforced in composer via per-depth reusable key-sets
  (`src/composer.zig:240-291`, `keySetForDepth` `:313-322`, `checkDuplicateKey`
  `:328-339`); pool is correctly deinit'd (`:131-137`). Probe confirms sibling
  mappings sharing a key name (`a.k`, `b.k`) do **not** false-positive, while a true
  duplicate (`a.x` twice) yields `duplicate_key`. Scalar-only limitation documented
  (`src/yaml.zig` `ParseOptions.unique_keys` doc comment).
- **Regression tests:** `tests/accept.zig` `SEC: unique_keys …` cases.

### GAP-0004 — `max_line_width` not applied — **Closed**

- **Severity:** Medium → Closed
- **Requirement:** `docs/API.md`/`src/emitter.zig:42-43` `EmitOptions.max_line_width`.
- **Resolution evidence:** `Emitter.currentColumn` (`src/emitter.zig:226-235`) and
  `flowSeparatorBreak` (`:239-246`) wrap flow items after a separator when the line
  exceeds the limit; wired into `emitFlowSeq` (`:248-259`) and `emitFlowMap`
  (`:318-331`). `max_line_width = 0` keeps a single line.
- **Regression tests:** `tests/accept.zig:1079` (wraps), `:1102` (0 = one line).

### GAP-0005 — `pattern` constraint was a stub — **Closed**

- **Severity:** Medium → Closed
- **Resolution evidence:** Iterative, allocation-free, recursion-free glob matcher
  `globMatch` (`src/validate.zig:404-428`) — `*` = any run, `?` = one char; wired into
  the `.pattern` arm (`:275-284`); public builders `validate.pattern`/`yaml.schema.pattern`
  (`src/validate.zig:392-394`, `src/yaml.zig:827-829`).
- **Regression tests:** `tests/accept.zig:1019`; `src/validate.zig:430` (`globMatch basics`).

### GAP-0006 — `%YAML` version not honored — **Closed**

- **Severity:** High → Closed
- **Resolution evidence:** `scanDirective` parses the major version and returns
  `error.UnsupportedYamlVersion` when `major != 1` (`src/scanner.zig:747-753`);
  declared in `ScanError` (`src/error.zig:116`) and mapped to
  `ErrorCode.unsupported_yaml_version` (`src/error.zig:28,52,167`). `%YAML 1.x`
  accepted; `%YAML 2.0` refused.
- **Regression tests:** `tests/accept.zig:1137` (1.x accepted), `:1149` (2.0 → error +
  `unsupported_yaml_version` code).

### GAP-0007 — core schema accepted leading-zero decimals — **Closed**

- **Severity:** Medium → Closed
- **Resolution evidence:** `parseIntCore` rejects a leading-zero decimal
  (`src/resolver.zig:528-529`), so `0755` → string; `0o755` → 493; `0x1F` → 31.
- **Regression tests:** `tests/accept.zig:869`.

### GAP-0008 — json schema over-resolved hex/octal/hex-float — **Closed**

- **Severity:** Medium → Closed
- **Resolution evidence:** JSON gets a restricted numeric parser: `parseIntJson`
  (decimal only, no `+`, no leading zero) (`src/resolver.zig:536-548`) and
  `parseJsonFloat` (JSON-number grammar, rejects hex floats/`+`/Inf/NaN)
  (`:553-584`); `resolveJsonSchema` no longer delegates to the core parser
  (`:193-217`).
- **Regression tests:** `tests/accept.zig:901` (hex/octal/hex-float/leading-zero → string).

### GAP-0009 — overflowing plain int became string — **Closed**

- **Severity:** Low → Closed
- **Resolution evidence:** `IntResult{ .big }` on i64 overflow (`src/resolver.zig:491-500`);
  core/json paths return `Value.big_int` preserving the digit string
  (`:239-243`, `:207-211`).
- **Regression tests:** `tests/accept.zig:924` (20+ digit → big_int under core and json).

### GAP-0010 — folded scalar didn't preserve more-indented breaks — **Closed**

- **Severity:** High → Closed
- **Resolution evidence:** `prev_more_indented`/`more_indented` tracking in
  `scanBlockScalar` (`src/scanner.zig:1559,1578,1586-1596`): breaks adjacent to a
  more-indented line are preserved (`\n`), other single breaks fold to a space, and
  the more-indented line keeps its extra leading spaces. Literal handling/chomping
  unchanged. Probes confirm more-indented at first/last/middle and blank-line combos.
- **Regression tests:** `tests/accept.zig:945`.

### GAP-0011 — quoted/plain blank-line folding — **Closed**

- **Severity:** Medium → Closed
- **Resolution evidence:** `break_count` run-folding in `scanDoubleQuoted`
  (`src/scanner.zig:1028-1038,1249`) and `scanSingleQuoted` (`:1315-1325,1426`), and
  `pending_breaks` in `scanPlainScalar` (`:1643,1747,1758-1767`): a single break →
  space, a run of k breaks → k-1 newlines (§7.3).
- **Regression tests:** `tests/accept.zig:967` (double), `:983` (single), `:997` (flow plain).

### GAP-0012 — complex `?` keys — **Closed**

- **Severity:** Medium → Closed
- **Resolution evidence:** Block and flow explicit-key handling binds a `?` key to its
  `:` value (`src/parser.zig:710+`, `:899-946`); collection/mapping/multiline keys
  parse and resolve into the graph.
- **Regression tests:** `tests/accept.zig:1177` (`? [a,b]`), `:1200` (`? {x:1}`),
  `:1219` (multi-line block-scalar key).

### GAP-0013 — round-trip alias inlining — **Closed (documented)**

- **Severity:** Medium → Closed
- **Resolution evidence:** `dumpAll` docstring documents that aliases are expanded
  during resolution and therefore inlined on emit; anchor/alias preservation is
  graph-level only; cyclic graphs are rejected with `error.AliasCycle`
  (`src/yaml.zig:615-636`).
- **Regression tests:** `tests/accept.zig:1239` (no `&`/`*`; aliased mapping appears twice).

### GAP-0014 — non-specific tag default inconsistency — **Closed**

- **Severity:** Low → Closed
- **Resolution evidence:** Non-specific tag standardized to `"?"` in the public
  `NodeMeta` default (`src/yaml.zig:130`), parser struct default (`src/parser.zig:82`)
  and all fallbacks (`collectNodeMeta` `:596` + every hardcoded `.tag = "?"`), and the
  composer (`src/composer.zig:14`, fallback `:295`). The resolver treats `"!"` and
  `"?"` as non-specific, so resolution is unaffected.
- **Regression tests:** `tests/accept.zig:1163` (plain scalar event tag is `"?"`;
  `(NodeMeta{}).tag == "?"`).

### GAP-0015 — `int_range` rejected big integers — **Closed**

- **Severity:** Low → Closed
- **Resolution evidence:** `.big_int` handled in the `int_range` arm
  (`src/validate.zig:259-271`): a positive big_int is above any i64 max, a negative one
  below any i64 min, evaluated against the configured bounds.
- **Regression tests:** `tests/accept.zig:1057`.

### GAP-0016 — `one_of` had no public builder (+ real error-string leak) — **Closed**

- **Severity:** Low → Closed
- **Resolution evidence:** Public `validate.oneOf`/`yaml.schema.oneOf`
  (`src/validate.zig:397-399`, `src/yaml.zig:832-834`). The failed-attempt path now
  frees each owned error string (path/message/expected/actual) before
  `shrinkRetainingCapacity` (`src/validate.zig:206-215`) — a genuine leak fix verified
  under the leak detector with every-alternative-fails inputs.
- **Regression tests:** `tests/accept.zig:1034`.

### GAP-0017 — `toJson` collapsed complex keys to `"<complex>"` — **Closed**

- **Severity:** Medium → Closed
- **Resolution evidence:** `writeKeyAsString` stringifies scalar keys (incl. big_int
  uniquely) and returns `error.UnsupportedKey` for seq/map/inf/nan keys
  (`src/json.zig:215-236`); `UnsupportedKey` declared in `JsonError` (`:26`).
- **Regression tests:** `tests/accept.zig:1112` (non-scalar key rejected), `:1122`
  (big_int key preserved uniquely).

### GAP-0018 — comptime subset undocumented (+ OOB risk) — **Closed (documented + guarded)**

- **Severity:** Low → Closed
- **Resolution evidence:** `comptimeParse` docstring documents the supported subset and
  caps (`src/yaml.zig:767-784`). Fixed-size buffers are now bounds-checked with a clear
  `@compileError` **before** the write (seq 256, map 128, flow 64)
  (`src/comptime.zig:185,237,348,390`), closing the OOB-write sub-point.
- **Note:** comptime remains an intentional subset (no floats, fixed caps, 2-space
  indent, undecoded escapes), now documented.

### Version drift (doc) — **Closed (re-verified)**

- Single-sourced from `build.zig.zon` via `build_info` (`build.zig`, `src/yaml.zig`);
  asserted by test.

---

## Cross-cutting hardening verified this pass (not gaps; defensive improvements)

- **`limits.hard_max_depth` (1024) clamp** (`src/limits.zig:18-31,91`,
  `src/resolver.zig:88`): the effective depth is `min(max_depth, hard_max_depth)`, so
  raising `max_depth` can no longer drive native-stack recursion into a SIGSEGV.
  Verified: billion-laughs input trips `error.MaxNodesExceeded` gracefully.
- **comptime fixed-buffer `@compileError` bounds checks** (`src/comptime.zig`):
  prevent out-of-bounds writes at compile time.

## Deliberate, documented non-features (not gaps)

- **No YAML 1.1 merge key (`<<`) processing** — explicitly intended
  (`README.md`, `docs/ARCHITECTURE.md`). A literal `<<` key is kept as an ordinary
  string key. Working as documented.

## Residual cosmetic notes (not gaps)

- A `core` schema `big_int` preserves the original lexeme including any sign/`0x`
  prefix (e.g. an overflowing `-0xFF…` retains `0x`). This is the documented
  "preserve digits" intent; it is consistent and non-crashing. Purely a
  representation nuance, tracked here for completeness.
- README install snippet pins an example version URL; update on release.
- `README.md:18` historically lagged the `yaml11` schema mention; verify on next
  README edit.

## Coverage Summary (verified Implemented — no gap)

- Streaming `Parser`/`EventIterator` and `loadAll*` entry points; **194/194** tests
  pass under `zig build test --summary all`.
- Resource limits enforced: `max_bytes`, `max_scalar_bytes`, `max_depth`
  (+ `hard_max_depth` clamp), `max_nodes`, `max_aliases`.
- `%TAG` directive stored and applied; `%YAML` version validated and unsupported
  majors rejected (GAP-0006).
- Multi-document streams and `---`/`...` boundaries.
- Literal + folded block scalars with chomping + explicit/auto indent + more-indented
  preservation (GAP-0010).
- Double/single-quoted escapes incl. `\xNN`/`\uNNNN`/`\UNNNNNNNN`, surrogate/over-range
  rejection; blank-line folding (GAP-0011).
- `failsafe`/`json`/`core`/`yaml11` resolution; restricted JSON numerics (GAP-0008),
  core leading-zero rejection (GAP-0007), big_int overflow preservation (GAP-0009).
- Alias cycle detection; alias deep-resolution to independent trees (GAP-0002).
- Emitter options incl. `max_line_width` flow wrapping (GAP-0004).
- Validation primitives + `optional`/`seqOf`/`mapOf`/`object`/`stringEnum`/`intRange`/
  `pattern`/`oneOf` builders (GAP-0005, GAP-0015, GAP-0016); `one_of` leak-free.
- `toJson` scalar/seq/map coverage with `inf`/`nan` → `error.InvalidFloat` and
  non-scalar keys → `error.UnsupportedKey` (GAP-0017).
- yaml-test-suite runner with event-tree comparison + CI job (GAP-0001).
