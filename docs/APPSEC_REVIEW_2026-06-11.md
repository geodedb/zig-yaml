# Application Security Code Review — `devnw/zig/yaml` (YAML 1.2 parser library)

Defensive, evidence-first review grounded in OWASP Top 10:2025 and CIS Controls v8.1.2. All findings below were verified by reading the source on disk and, for the four runtime memory/DoS findings, by building the library with Zig 0.16.0 and running proof-of-concept programs against it. PoC harnesses were removed after verification.

---

## 1. Scope and Assumptions

**Reviewed (read from disk):**

- `src/` — `composer.zig`, `comptime.zig`, `debug_json.zig`, `emitter.zig`, `error.zig`, `json.zig`, `limits.zig`, `parallel.zig`, `parser.zig`, `resolver.zig`, `scanner.zig`, `validate.zig`, `yaml.zig` (~7,700 LOC)
- `build.zig`, `build.zig.zon`, `.gitlab-ci.yml`, `.gitleaks.toml`, `scripts/detect_diamond_deps.py`
- `tests/fuzz_test.zig` (helpers) and `build.zig` test wiring

**Dynamic verification:** built the `yaml` module with a stubbed `thread_pool` (a network dependency, not on the input path) under Zig 0.16.0 Debug (runtime safety checks on) and ran 6 PoC programs. SIGSEGV, double-free, and integer-overflow results below are reproduced crashes, not inferences.

**Assumptions:**

- Primary trust boundary: the `input: []const u8` passed to `loadAll`/`Parser.init`/`resolveToValue` is **untrusted**. This matches the library's own docs ("Configure resource limits via `ParseOptions` to prevent DoS attacks", `yaml.zig:40`).
- Library consumers may call `resolveToValue` + `freeValue` (the documented happy path in `yaml.zig:14-23`).
- Consumers may raise `ParseOptions` limits above defaults (the limits are public, tunable fields).

**Auth model:** Not applicable — this is a parsing library with no authentication, authorization, session, network, or persistence surface. A01/A02(authz)/A04/A07 are out of scope by design; A05 (injection) does not apply in the SQL/OS/template sense but *resource/parse-safety* is the domain-equivalent.

**Not reviewed / out of scope:** `tests/*` (beyond fuzz helpers), `examples/`, `bench/`, `docs/`, the vendored `testdata/yaml-test-suite`, the `thread_pool` dependency source (only its pin was reviewed), and the `ci-catalog` component internals (third-party, not in this repo).

---

## 2. Executive Summary

- **Highest risk (Critical): a single duplicated alias to a collection corrupts the heap.** Input `[&x {k: v}, *x]` resolved via the documented `resolveToValue` → `freeValue` path produces a double-free / use-after-free ("switch on corrupt value" panic, reproduced). Root cause: `resolver.zig` memoizes resolved nodes and returns **shared heap pointers** for every alias/repeat, but `freeValue` walks the tree and frees each pointer once per occurrence. This is reachable with trivial, realistic untrusted YAML and is the most serious issue in the codebase.
- **High: billion-laughs amplification is effectively unbounded.** 250 input bytes expanded to **6,053,451 resolved nodes** (~24,000×) with default limits, because `max_nodes`/`max_aliases` bound the *composer graph and source alias count*, not the *resolved Value-tree expansion*. The resolver enforces no node budget. Adding two more nesting levels yields memory/CPU exhaustion. (Reproduced.)
- **High: `max_depth` is not enforced on the streaming `Parser`/`resolver`, and the composer's enforced recursion is native-stack.** With a consumer-raised `max_depth`, deeply nested input drives unbounded native recursion in `composer.composeNode` → SIGSEGV (reproduced at `max_depth=65000`). The default `max_depth=200` is safe (graceful `MaxDepthExceeded`, reproduced), so this is gated on a consumer raising the limit — but the limit's safety ceiling is undocumented and the streaming/resolve paths ignore it entirely.
- **Medium: integer-overflow panic on untrusted `yaml11` scalars.** `parseSexagesimal` computes `current*10` / `result*60` with no overflow guard; input `99999999999999999999:59:59` under the `yaml11` schema panics (reproduced) — a DoS on any consumer using `schema=.yaml11`.
- **Low/Info: supporting hygiene gaps** — version string mismatch (`0.1.4` zon vs `0.2.0` source), comptime fixed-buffer overflow with no bounds checks, mutable CI component tags, a latent dangling-pointer pattern in the composer, and `unique_keys` being declared but never enforced.
- **Overall confidence: High** for the four reproduced runtime findings; Medium-High for the rest. The default-configured `loadAll` path (without `resolveToValue`) is reasonably hardened; the danger concentrates in the **resolver** and in **consumer-tunable limits**.

---

## 3. Findings Table

| ID | Severity | Confidence | Title | Location | OWASP 2025 | Status |
|----|----------|-----------|-------|----------|-----------|--------|
| F-01 | **Critical** | High | Double-free / UAF via shared alias pointers in `freeValue` | `resolver.zig:42-61, 92-112` | A10 / A06 | Confirmed (PoC) |
| F-02 | **High** | High | Unbounded alias-expansion amplification (billion-laughs) in resolver | `resolver.zig:85-113, 331-376` | A10 / A06 | Confirmed (PoC) |
| F-03 | **High** | High | `max_depth` unenforced on streaming/resolve; native-stack recursion → SIGSEGV | `parser.zig:410-519`, `composer.zig:168-271`, `resolver.zig:331-376` | A10 | Confirmed (PoC) |
| F-04 | **Medium** | High | Integer-overflow panic in sexagesimal parsing (`yaml11`) | `resolver.zig:530-551, 466-527` | A10 | Confirmed (PoC) |
| F-05 | **Low** | High | Version string mismatch (supply-chain/provenance) | `build.zig.zon:3` vs `yaml.zig:58` | A08 | Confirmed |
| F-06 | **Low** | High | Comptime parser fixed-buffer overflow, no bounds checks | `comptime.zig:164-241, 329-401` | A10 | Confirmed |
| F-07 | **Low** | Medium | Mutable CI component pins (tags, not SHAs) | `.gitlab-ci.yml:11-24` | A03 / A08 | Confirmed |
| F-08 | **Low** | Medium | Latent dangling pointer: `current_doc` into reallocating `ArrayList` | `composer.zig:151` | A10 | Latent |
| F-09 | **Info** | High | `unique_keys` option declared but never enforced | `parser.zig:105`, `composer.zig` | A06 | Confirmed |
| F-10 | **Info** | Medium | Emitter/JSON writers recurse natively over Value trees | `emitter.zig:103-123`, `json.zig:90-209` | A10 | Noted |

---

## 4. Finding Details

### F-01 — Critical — Double-free / use-after-free via shared alias pointers

**OWASP A10 (Mishandling of Exceptional Conditions) / A06 (Insecure Design); CWE-415 (Double Free), CWE-416 (Use After Free)**

**Evidence.** The resolver memoizes every resolved node and returns the *same* `Value` (with shared `.str`/`.seq`/`.map` heap pointers) on repeat:

```zig
// resolver.zig:91-112
if (self.resolved_cache.get(node_id)) |cached| {
    return cached;                 // returns SHARED heap pointers
}
...
try self.resolved_cache.put(node_id, result);
```

An alias node resolves by returning its target's resolved value (`resolver.zig:104-108`), so the *same* allocated seq/map/str slice is embedded into the parent tree at every alias site. `freeValue` then recursively frees each embedded pointer once per occurrence:

```zig
// resolver.zig:42-61
.seq => |items| { for (items) |*item| freeValue(allocator, item); allocator.free(items); }
.map => |items| { for (items) |*pair| { freeValue(.., &pair.k); freeValue(.., &pair.v);} allocator.free(items); }
```

**Attack scenario (non-destructive).** A service ingests untrusted YAML and calls the documented `loadAll` → `resolveToValue` → `freeValue` sequence. Input `[&x {k: vvvvv}, *x]` (one anchor + one alias to a collection) causes `freeValue` to traverse the aliased map twice and free its backing allocation twice.

**Reproduced output:**

```text
thread panic: switch on corrupt value
  resolver.zig:43  in freeValue   <- switch (value.*)
  resolver.zig:54  in freeValue
  yaml.zig:564     in freeValue
  poc:13           yaml.freeValue(a, &v);
```

(Also reproduced with two aliases `[&x {k:v}, *x, *x]`.)

**Impact.** Heap corruption on untrusted input through the library's primary documented API. Double-free/UAF can crash the process (DoS) and, depending on allocator and heap state, is a memory-safety primitive that can escalate beyond a crash. This is the canonical reason YAML-with-aliases is dangerous, and it lands in the *free* path that every correct consumer must call.

**Root cause.** Aliases create a DAG (shared nodes), but `freeValue` assumes an owned tree. Memoization shares pointers without any ownership/dedup tracking.

**Remediation (choose one):**

- **Preferred — deep-copy on alias resolution.** When returning a cached value for a *second* use, return an independent deep copy so the result is a true tree that `freeValue` can own. Bound copies by a node budget (see F-02) to avoid amplification.
- **Or — arena-own the resolved tree.** Allocate the whole `Value` tree in an arena returned to the caller; replace `freeValue` with `arena.deinit()`. This removes per-node frees entirely and is the cleanest fix for both F-01 and F-02's free path. Document that aliases produce shared structure that must not be mutated/freed per-node.
- **Or — reference counting / visited-set free.** Track freed allocations in a `visited` set and free each backing pointer once. More error-prone; not recommended over the arena approach.

**Regression tests.** Add fuzz/unit cases asserting `loadAll`+`resolveToValue`+`freeValue` is clean under `std.heap.DebugAllocator` for: single alias to a map, single alias to a seq, single alias to a scalar, N aliases to one anchor, and nested aliases. These must run in the existing `fuzz_test.zig` harness, which today calls `freeValue` (`tests/fuzz_test.zig:46`) but evidently lacks an aliased-collection corpus seed.

---

### F-02 — High — Unbounded alias-expansion amplification (billion-laughs)

**OWASP A10 / A06; CWE-776 (XML/Entity Expansion analog), CWE-400 (Uncontrolled Resource Consumption)**

**Evidence.** `max_nodes`/`max_aliases` are enforced only in the *composer* (`composer.zig:169` `addNode`, `parser.zig:436/460` `addAlias`) and the composer stores each alias as a *single* `.a` node — so the composer graph stays tiny regardless of expansion. The resolver, which performs the actual expansion, enforces **no node budget**:

```zig
// resolver.zig:331-346 resolveSeq — allocates a fresh expanded array per parent,
// recursively resolving each child; no LimitChecker, no max_nodes consultation.
```

**Attack scenario.** Classic 7-level, 9-way billion-laughs (250 bytes), default `ParseOptions`:

```text
input bytes: 250
resolved node count (expanded): 6053451      // ~24,000x amplification, completed without error
```

`max_aliases=5000` counts the 63 alias *tokens* in source, never the expansion; `max_nodes=1M` is never checked during resolution. Two more levels → memory/CPU exhaustion.

**Impact.** Memory/CPU DoS from tiny untrusted input via the documented resolve path. Directly contradicts the library's stated DoS protections.

**Root cause.** Resource accounting lives in the composer/parser, but the expensive expansion lives in the resolver, which has no `LimitChecker`.

**Remediation.** Thread a `LimitChecker` (or a simple `nodes_produced` counter seeded with `max_nodes`) into `Resolver`, incremented in `resolveScalar`/`resolveSeq`/`resolveMap`, returning `error.MaxNodesExceeded` when exceeded. If you adopt the deep-copy fix for F-01, enforce the budget *during* copy so amplification is caught early. Also add a `max_depth` check here (see F-03).

**Regression tests.** Assert the 7×9 billion-laughs payload returns `error.MaxNodesExceeded` (not success, not OOM) under default options; assert linear inputs still resolve.

---

### F-03 — High — `max_depth` unenforced on streaming/resolve; native-stack recursion → SIGSEGV

**OWASP A10; CWE-674 (Uncontrolled Recursion), CWE-770 (Allocation Without Limits)**

**Evidence.**

- The streaming `Parser` declares `max_depth` (`parser.zig:107`) but **never checks it** — grep shows the only other reference is the error-code mapping (`parser.zig:1205`). `parseNode` recurses via `pushState(.block_node)` + `parseNextEvent` with no depth counter.
- The composer *does* call `pushDepth`/`popDepth` (`composer.zig:192,224`), but its recursion is **native-stack** (`composer.zig:205` `composeNode` → `composeNode`). The depth check only converts a too-deep document into an error *if* `max_depth` is below the native-stack ceiling.
- The resolver has **no depth limit at all** (`grep` confirms none), recursing natively in `resolveSeq`/`resolveMap`.

**Attack scenario.** Default `max_depth=200` is safe — reproduced graceful `MaxDepthExceeded` on 100,000 `[` characters. But a consumer that raises the limit (a documented, public knob) is exposed:

```text
// max_depth=65000, input = "[" * 100000
=== running (composer/resolver native recursion, max_depth=65000) ===
Segmentation fault at address 0x7ffd5de33ac0
  scanner.zig:293 ... composer.zig:205 in composeNode
  composer.zig:205 in composeNode   <- (repeated native frames)
```

**Impact.** Hard crash (DoS) of the host process on untrusted input whenever a consumer raises `max_depth` above the (undocumented, platform-dependent) safe stack ceiling — and the streaming `Parser` consumers get no depth protection at all, accumulating unbounded heap state (`state_stack`) bounded only by `max_bytes`.

**Root cause.** Recursion-depth safety is conflated with the configurable `max_depth`, and that single check is absent from two of the three entry paths.

**Remediation.**

- Document and clamp a hard recursion ceiling independent of `max_depth` (e.g., reject `max_depth` above a safe maximum, or cap effective recursion at a constant the native stack tolerates).
- Enforce `max_depth` in the streaming `Parser` (increment on `seq_start`/`map_start`, decrement on `*_end`) so streaming consumers are protected.
- Enforce a depth limit in the resolver (see F-02 remediation — a shared `LimitChecker` covers both).

**Regression tests.** Add cases asserting deep nesting returns `error.MaxDepthExceeded` for: streaming `Parser`, `resolveToValue`, and `loadAll` with a *raised* `max_depth` (e.g. 100,000) — none should SIGSEGV.

---

### F-04 — Medium — Integer-overflow panic in sexagesimal parsing (`yaml11`)

**OWASP A10; CWE-190 (Integer Overflow), CWE-754 (Improper Check for Exceptional Conditions)**

**Evidence.**

```zig
// resolver.zig:541-542
} else if (std.ascii.isDigit(c)) {
    current = current * 10 + @as(i64, c - '0');   // unchecked
// resolver.zig:530-551 also: result = result * 60 + current;  (unchecked)
```

**Attack scenario.** Consumer uses `schema=.yaml11` (a supported, documented schema) and ingests untrusted YAML. `x: 99999999999999999999:59:59` triggers:

```text
thread panic: integer overflow
  resolver.zig:542 in parseSexagesimal   <- current = current * 10 + ...
  resolver.zig:484 in parseInt11
  resolver.zig:240 in resolveYaml11Schema
```

**Impact.** Process abort (DoS) on untrusted scalar input under the `yaml11` schema. In `ReleaseFast` builds (one of the CI matrix targets) the overflow would silently wrap to a wrong integer value instead of panicking — a correctness/data-integrity issue.

**Root cause.** Base-60/base-10 accumulation without saturating/checked arithmetic.

**Remediation.** Use checked arithmetic and treat overflow as "not a number" (fall through to string), matching how other numeric parses degrade:

```zig
current = std.math.add(i64, std.math.mul(i64, current, 10) catch return null, c - '0') catch return null;
```

Apply the same to the `result * 60 + current` step. Audit `parseInt`/`parseInt11` negation (`-v`) for the `minInt(i64)` edge while here; the tested `int-min` case resolved cleanly, but the `-v` pattern (`resolver.zig:413,424,...`) is overflow-prone in principle for the exact `9223372036854775808` magnitude path.

**Regression tests.** Assert oversized sexagesimal and 20+ digit decimals under `.yaml11` return a string `Value` (or a defined error), never panic, in both Debug and ReleaseFast.

---

### F-05 — Low — Version string mismatch (provenance/supply-chain)

**OWASP A08; CWE-1059/process integrity**

**Evidence.** `build.zig.zon:3` → `.version = "0.1.4"`; `src/yaml.zig:49-58` → `version = 0.2.0` / `version_string = "0.2.0"`. The input contract also states the package is "yaml v0.1.4".

**Impact.** Consumers and SBOM tooling read inconsistent versions; semantic-release and the SBOM stage (`.gitlab-ci.yml:20-24`) may emit incorrect provenance, undermining dependency-pinning guarantees downstream.

**Remediation.** Single-source the version (derive `yaml.zig`'s constant from the zon at build time, or make CI assert equality). Add a pre-commit/CI check.

---

### F-06 — Low — Comptime parser fixed-buffer overflow, no bounds checks

**OWASP A10; CWE-787 (Out-of-bounds Write) / CWE-1284 (Improper Validation of Specified Quantity)**

**Evidence.** `comptime.zig` uses fixed stack buffers and writes without bounds checks:

```zig
// comptime.zig:164  var items: [256]Value = undefined;   then items[count]=..; count+=1;  (line 187-192)
// comptime.zig:201  var items: [128]Value.KVPair = undefined;  (line 235-236)
// comptime.zig:332/365  [64] flow buffers
```

There is no `count < items.len` guard before `items[count] = ...`.

**Impact.** **Build-time only** (the comptime parser runs over `@embedFile`/literals, not runtime untrusted input — so not a runtime vuln). A config file with >256 sequence items / >128 map keys / >64 flow items causes a comptime out-of-bounds write / compile error rather than a clean diagnostic. Low severity because the attacker surface is the developer's own embedded config, not external input.

**Remediation.** Add `if (count >= items.len) @compileError("yaml comptime: collection too large");` before each write, with a clear message. Document the comptime size limits.

---

### F-07 — Low — Mutable CI component pins

**OWASP A03 (Software Supply Chain Failures); CWE-1357 (Reliance on Insufficiently Trustworthy Component)**

**Evidence.** `.gitlab-ci.yml:11-24` pins `ci-catalog` components by **tag** (`@v1.7.1`, `@v1.2.1`). Git tags are mutable; a compromised or re-pointed tag changes the security-scanning/SBOM/release pipeline that gates this repo. By contrast, the one *code* dependency is correctly SHA-pinned (`build.zig.zon:8` `#d45eb0a...` + package hash — good, see Secure Design Notes).

**Impact.** Supply-chain risk: the pipeline that produces SBOMs and releases is only as trustworthy as a mutable tag in a separate repo.

**Remediation.** Pin components to immutable commit SHAs (GitLab CI supports `@<sha>` for components) or vendor/verify them. The Zig toolchain itself *is* SHA-256 verified (`.gitlab-ci.yml:59-71`), which is the right model to extend to components.

---

### F-08 — Low — Latent dangling pointer into reallocating `ArrayList`

**OWASP A10; CWE-825 (Expired Pointer Dereference)**

**Evidence.**

```zig
// composer.zig:150-151
try self.documents.append(self.allocator, doc);
self.current_doc = &self.documents.items[self.documents.items.len - 1]; // pointer into ArrayList storage
```

`current_doc` points into `documents.items`, which reallocates on the next `append`. Today it is re-assigned on every `.doc_start` and only used between `doc_start` and `doc_end` before any further append, so it is currently benign — but it is a fragile pattern one refactor away from a UAF in multi-document streams. Note also `loadAll`/`loadAllWithDetails` move `Document` structs *by value* out of the list (`yaml.zig:337-344`, `composer.zig:304-309`); `Document` embeds an `ArenaAllocator` and `StringHashMap` — moving these by value is sound in current Zig std (state is heap/handle-based) but should be covered by a test under `DebugAllocator`.

**Remediation.** Store `current_doc` as an index into `documents`, not a pointer; dereference on use. Add a multi-document `loadAll` round-trip test under `DebugAllocator`.

---

### F-09 — Info — `unique_keys` declared but not enforced

**OWASP A06; CWE-694 (Use of Multiple Resources with Duplicate Identifier)**

**Evidence.** `ParseOptions.unique_keys: bool = true` (`yaml.zig:107`, `parser.zig:105`) is plumbed through `init` but no duplicate-key detection exists in `composer.zig`'s `map_start` handling (it appends all `KVPair`s unconditionally, `composer.zig:227-255`). `ComposerError.DuplicateKey` exists but is never returned.

**Impact.** Security-relevant only as a config-confusion/last-key-wins hazard (duplicate keys in policy/config YAML can mask values). Defaults claim rejection but silently accept.

**Remediation.** Either implement duplicate-key rejection when `unique_keys` is set, or change the default/docs to reflect actual behavior. Add a test for `{a: 1, a: 2}`.

---

### F-10 — Info — Native recursion in emitter/JSON writers

**OWASP A10; CWE-674**

**Evidence.** `emitter.zig:103-123` (`emitValue`→`emitSeq`/`emitMap`) and `json.zig:90-209` (`writeValue`→`writeArray`/`writeObject`) recurse natively over `Value` trees with no depth cap. These operate on already-resolved trees, which are depth-bounded by the composer on the default path — so this is only reachable via hand-constructed `Value` trees or in combination with F-03. Noted for completeness; fix naturally falls out of a shared depth budget.

---

## 5. Secure Design Notes (positive controls observed)

- **Input is UTF-8-validated and size-capped up front.** `scanner.zig:106-109` calls `checker.checkInputSize` and `validateUtf8` in `Scanner.init`, before any scanning — a clean early gate (CIS secure-design).
- **Default limits are genuinely protective on the `loadAll` path.** Verified: 100,000 nested `[` with default `max_depth=200` returns a graceful `MaxDepthExceeded`, no crash. Scalar size is enforced at each scalar (`scanner.zig:1023,1305,1569` `checkScalarSize`).
- **No unsafe sinks.** No `eval`, command/SQL/template construction, file/network egress on the parse path, or deserialization-of-code. The only filesystem touch is the explicit, opt-in `loadAllFromFile` (`yaml.zig:451`), which correctly bounds reads via `readAllAlloc(o.max_bytes)` (`yaml.zig:443`).
- **The code dependency is strongly pinned.** `thread_pool` is pinned by both git commit SHA and Zig package hash (`build.zig.zon:8-9`) — the correct supply-chain posture (CIS 16.x, A03). The `detect_diamond_deps.py` guard adds defense against transitive hash divergence.
- **Toolchain integrity in CI.** Zig is downloaded and **SHA-256-verified against the signed ziglang.org index** (`.gitlab-ci.yml:59-71`) with `--strict` — a strong, often-missing control.
- **Security tooling is wired in.** SAST, dependency scanning, secret scanning, gitleaks, SBOM generate+scan, and coverage-guided fuzzing are all present (`.gitlab-ci.yml`), and the fuzz harness already exercises `loadAll`+`resolveToValue`+`freeValue` (`tests/fuzz_test.zig`) — the right structure to catch F-01/F-02 once aliased-collection corpus seeds are added.
- **Resolver has cycle detection.** `visiting` set returns `error.AliasCycle` on self-referential aliases (`resolver.zig:86-97`) — direct cycles are handled (it's the *shared-DAG free*, not cycles, that breaks in F-01).
- **The `comptime` parser cannot be reached by runtime untrusted input** — it only processes build-time embedded data, correctly bounding F-06's blast radius to the build.

---

## 6. Coverage Gaps and Questions

- **`thread_pool` dependency source not reviewed** (only its pin). `parallel.zig:17` `@panic("thread-pool: init failed")` would abort the host if pool init fails — acceptable for a parallel-helper but worth a graceful fallback. Parallel helpers are not on the untrusted-parse path.
- **`emitter.zig` and `debug_json.zig` were read only at the API/recursion level**, not line-by-line for quoting/escape correctness. An emitter round-trip injection review (does emitting attacker-controlled scalars produce YAML that re-parses to a *different* structure?) is worth a follow-up, though it's a data-integrity rather than memory-safety concern.
- **ReleaseFast behavior of the overflow/double-free findings** was verified only in Debug. F-04 will *wrap silently* (not panic) in ReleaseFast; F-01's double-free behavior is allocator-dependent in release. The CI matrix runs ReleaseFast/Safe/Small tests — adding the PoC corpus there will characterize release behavior.
- **Open questions for the maintainer:**
  1. Is `resolveToValue`+`freeValue` the intended public contract for untrusted input, or is arena-ownership preferred? (Drives F-01 fix choice.)
  2. Should `max_depth` be a *correctness* limit or a *safety* limit? (Drives whether to clamp it, per F-03.)
  3. Is the `yaml11` schema exposed to untrusted input in practice? (Drives F-04 priority.)

---

## 7. Prioritized Next Actions

1. **Fix F-01 (Critical) immediately.** Adopt arena-ownership for the resolved `Value` tree (replace per-node `freeValue` with `arena.deinit()`), or deep-copy on alias resolution. This is the one finding that is memory corruption on trivial, realistic untrusted input through the documented API.
2. **Fix F-02 + F-03 together (High).** Introduce a single `LimitChecker` shared by the parser, composer, **and resolver**, enforcing `max_nodes` and `max_depth` on every path including streaming and resolution; clamp `max_depth` to a documented native-stack-safe ceiling.
3. **Fix F-04 (Medium).** Checked arithmetic in `parseSexagesimal` (and audit `-v` negation); fall through to string on overflow. Add ReleaseFast test coverage.
4. **Add alias/depth/amplification corpus seeds to `fuzz_test.zig`** (single alias to map/seq/scalar; N aliases; billion-laughs; raised-`max_depth` deep nesting) and run them under `DebugAllocator` across the existing Debug/ReleaseSafe/ReleaseFast/ReleaseSmall matrix. These would have caught F-01–F-04.
5. **Resolve F-05 version mismatch** with a CI assertion (cheap provenance fix).
6. **Pin CI components by SHA (F-07)** and add bounds checks to the comptime parser (F-06).
7. **Decide on F-09 `unique_keys`** — implement or correct the documented default. Convert `current_doc` to an index (F-08) and add a multi-document round-trip test.

**Confidence statement:** No claim here is speculative for the four runtime findings — F-01, F-02, F-03, and F-04 were each reproduced as a crash/measurement against the built library under Zig 0.16.0. For the reviewed scope, the default `loadAll`-without-resolve path is reasonably hardened, but the **resolver and consumer-tunable limits** contain confirmed memory-safety and DoS defects that should block use against untrusted input until F-01–F-03 are remediated.
