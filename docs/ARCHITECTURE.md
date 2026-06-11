# Architecture

This document describes the architecture of the yaml library.

## Module Structure

```text
src/
├── yaml.zig        # Main entry point and unified public API
├── scanner.zig     # Lexical tokenization (O(n) streaming)
├── parser.zig      # Event-based parser (push-down automaton)
├── composer.zig    # Document graph construction
├── resolver.zig    # Schema-based value resolution
├── emitter.zig     # Canonical YAML output
├── validate.zig    # Schema validation
├── json.zig        # JSON conversion
├── comptime.zig    # Compile-time parsing
├── limits.zig      # Resource limit enforcement
├── error.zig       # Error types and codes
└── debug_json.zig  # Debug output utilities
```

## Processing Pipeline

The library implements a layered architecture following the YAML 1.2.2 specification stages:

```text
┌─────────────────────────────────────────────────────────────────────┐
│                         Input (YAML text)                           │
└─────────────────────────────────────────────────────────────────────┘
                                  │
                                  ▼
┌─────────────────────────────────────────────────────────────────────┐
│  Scanner (scanner.zig)                                              │
│  ─────────────────────                                              │
│  • Single-pass lexical analysis                                     │
│  • O(n) streaming tokenization                                      │
│  • Indent stack tracking for block structures                       │
│  • Handles all scalar styles (plain, quoted, block)                 │
│  • Validates UTF-8 and escape sequences                             │
│  Output: Token stream                                               │
└─────────────────────────────────────────────────────────────────────┘
                                  │
                                  ▼
┌─────────────────────────────────────────────────────────────────────┐
│  Parser (parser.zig)                                                │
│  ───────────────────                                                │
│  • Push-down automaton (state machine with stack)                   │
│  • Converts tokens to SAX-style events                              │
│  • Handles implicit document starts                                 │
│  • Manages block/flow context transitions                           │
│  Output: Event stream                                               │
└─────────────────────────────────────────────────────────────────────┘
                                  │
                    ┌─────────────┴─────────────┐
                    │                           │
                    ▼                           ▼
    ┌───────────────────────────┐   ┌───────────────────────────┐
    │  Streaming API            │   │  Composer (composer.zig)  │
    │  ─────────────            │   │  ────────────────────────  │
    │  • Direct event access    │   │  • Builds document graph  │
    │  • Memory efficient       │   │  • Preserves anchors      │
    │  • Custom processing      │   │  • Tracks aliases         │
    │                           │   │  Output: Document[]       │
    └───────────────────────────┘   └───────────────────────────┘
                                                │
                                                ▼
                                    ┌───────────────────────────┐
                                    │  Resolver (resolver.zig)  │
                                    │  ────────────────────────  │
                                    │  • Schema-based typing    │
                                    │  • Anchor resolution      │
                                    │  • Cycle detection        │
                                    │  Output: Value tree       │
                                    └───────────────────────────┘
                                                │
                           ┌────────────────────┼────────────────────┐
                           │                    │                    │
                           ▼                    ▼                    ▼
               ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐
               │    Emitter      │  │    Validator    │  │  JSON Convert   │
               │  ─────────────  │  │  ─────────────  │  │  ─────────────  │
               │  YAML output    │  │  Schema check   │  │  JSON string    │
               └─────────────────┘  └─────────────────┘  └─────────────────┘
```

## Core Components

### Scanner (`scanner.zig`)

The scanner performs lexical analysis, converting raw YAML text into tokens.

Key features:

- **Single-pass processing**: O(n) complexity with no backtracking
- **Indent tracking**: Maintains a stack for block structure indentation
- **Scalar handling**: Processes all five scalar styles:
  - Plain (unquoted)
  - Single-quoted (`'...'`)
  - Double-quoted (`"..."` with escape sequences)
  - Literal block (`|`)
  - Folded block (`>`)
- **Error position tracking**: Maintains line/column for error reporting

Token types:

```text
STREAM-START/END, DOC-START/END (---/...)
KEY (?), VALUE (:), BLOCK-ENTRY (-)
FLOW-SEQ-START/END ([]), FLOW-MAP-START/END ({})
ANCHOR (&), ALIAS (*), TAG (!), DIRECTIVE (%)
SCALAR (with style indicator)
```

### Parser (`parser.zig`)

The parser converts tokens into a stream of events using a push-down automaton.

State machine overview:

```text
stream_start
    │
    ├──▶ implicit_doc_start (content without ---)
    │
    └──▶ doc_start (explicit ---) ──▶ doc_content ──▶ doc_end
                                           │
                                           ▼
                                     block_node / flow_node
                                           │
              ┌────────────────────────────┼────────────────────────────┐
              │                            │                            │
              ▼                            ▼                            ▼
        Block Sequence              Block Mapping               Flow Collections
```

Events produced:

- `stream_start` / `stream_end`
- `doc_start` / `doc_end`
- `seq_start` / `seq_end`
- `map_start` / `map_end`
- `scalar` (with metadata)
- `alias`

### Composer (`composer.zig`)

The composer builds a document graph from parser events.

Key features:

- **Graph representation**: Nodes are identified by `NodeId` (u32)
- **Anchor registration**: Tracks anchors for later alias resolution
- **Arena allocation**: Document memory is arena-allocated for efficient cleanup
- **Alias preservation**: Aliases stored as separate node type for graph fidelity

Document structure:

```zig
pub const Document = struct {
    arena: ArenaAllocator,
    root: NodeId,
    nodes: ArrayList(Node),
    anchors: StringHashMap(NodeId),
};
```

### Resolver (`resolver.zig`)

The resolver converts document graphs to typed values based on the selected schema.

Schemas supported:

| Schema | Description |
|--------|-------------|
| `failsafe` | All scalars as strings |
| `json` | null, bool, int, float, string |
| `core` | YAML 1.2.2 full type inference |
| `yaml11` | YAML 1.1 compatibility (yes/no, 0-prefix octal) |

Features:

- **Cycle detection**: Prevents infinite loops in alias resolution
- **Caching**: Resolved values cached for repeated alias access
- **Big integer support**: Integers exceeding i64 preserved as strings

### Emitter (`emitter.zig`)

The emitter converts value trees back to YAML text.

Features:

- **Canonical output**: Deterministic formatting
- **Style options**: Block vs. flow collections
- **Quote control**: Minimal, single, or double quoting
- **Safe escaping**: Special characters properly escaped

### Validator (`validate.zig`)

The validator checks values against type schemas.

Schema types:

- Primitives: `any`, `null`, `bool`, `int`, `float`, `str`
- Containers: `seq`, `map`, `object`
- Combinators: `optional`, `one_of`
- Constraints: `int_range`, `enum_values`, `pattern`

### Limits (`limits.zig`)

Resource limits prevent denial-of-service attacks.

Enforced limits:

| Limit | Default | Purpose |
|-------|---------|---------|
| `max_bytes` | 8 MB | Input size |
| `max_depth` | 200 | Nesting depth |
| `max_nodes` | 1M | Node count |
| `max_aliases` | 5000 | Alias count |
| `max_scalar_bytes` | 1 MB | Scalar size |

## Memory Management

### Allocation Strategy

- **Document memory**: Arena allocator for fast bulk deallocation
- **Resolved values**: Caller-owned, freed via `freeValue()`
- **Emitter output**: Caller-owned slice
- **Parser state**: Stack-allocated where possible

### Deallocation Patterns

```zig
// Documents
var docs = try yaml.loadAll(allocator, input, .{});
defer {
    for (docs) |*d| d.deinit();
    allocator.free(docs);
}

// Values
const value = try yaml.resolveToValue(allocator, &doc, .{});
defer yaml.freeValue(allocator, &value);

// Emitter output
const output = try yaml.dumpAll(allocator, values, .{});
defer allocator.free(output);
```

## Error Handling

### Error Propagation

Errors flow up through the pipeline with position tracking:

```text
Scanner → Parser → Composer → Public API
   ↓         ↓         ↓          ↓
 line/col  line/col  context   ParseError
```

### Error Information

```zig
pub const ParseError = struct {
    code: ErrorCode,
    line: u32,
    col: u32,
    offset: usize,
    context: []const u8,
};
```

## Design Rationale

1. **Layered architecture**: Scanner → Parser → Composer → Resolver enables streaming, testability, and clear separation per YAML spec stages.

2. **O(n) streaming scan**: Single-pass tokenization with indent stack tracking; no quadratic rescans for block scalar boundaries.

3. **Graph-first design**: Preserves anchors/aliases in document representation, enabling round-trip fidelity and cycle detection during resolution.

4. **Schema resolution deferred**: Same document graph can be interpreted under different schemas without re-parsing.

5. **Resource limits enforced early**: Scanner/parser level enforcement prevents DoS from deeply nested structures, large scalars, or alias bombs.

6. **Canonical emitter determinism**: Block-style output, predictable escaping ensures reproducible serialization.

7. **No YAML 1.1 merge key** (`<<`) processing: Avoids implicit data transformations that break security expectations in configuration files.

## Dependencies

- **Zero external dependencies**: Uses only Zig standard library
- **Compile-time support**: No runtime dependencies for comptime parsing
