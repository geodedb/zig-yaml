# yaml

A complete YAML 1.2.2 parser and emitter library for Zig.

## Status

| Aspect | Info |
|--------|------|
| API Stability | Beta |
| Zig Version | 0.15.1+ |
| Platforms | Linux, macOS, Windows |

## Features

- Full YAML 1.2.2 specification support
- Streaming event-based parser (O(n) complexity)
- Document graph representation with anchor/alias preservation
- Schema-based value resolution (failsafe, json, core)
- Canonical emitter with deterministic output
- Zero external dependencies (stdlib only)
- Resource limits for safety against DoS attacks

## Installation

Add to your `build.zig.zon`:

```zig
.dependencies = .{
    .yaml = .{
        .url = "https://gitlab.com/devnw/zig/yaml/-/archive/v0.1.0/yaml-v0.1.0.tar.gz",
        .hash = "<run: zig fetch URL>",
    },
},
```

To get the hash, run:
```bash
zig fetch https://gitlab.com/devnw/zig/yaml/-/archive/v0.1.0/yaml-v0.1.0.tar.gz
```

Then in your `build.zig`:

```zig
const yaml = b.dependency("yaml", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("yaml", yaml.module("yaml"));
```

## Quick Start

```zig
const yaml = @import("yaml");
const std = @import("std");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const input =
        \\---
        \\server:
        \\  host: localhost
        \\  port: 8080
        \\features:
        \\  - auth
        \\  - logging
    ;

    // Load documents
    var docs = try yaml.loadAll(allocator, input, .{});
    defer {
        for (docs) |*d| d.deinit();
        allocator.free(docs);
    }

    // Resolve to values
    for (docs) |*doc| {
        const value = try yaml.resolveToValue(allocator, doc, .{});
        // Use value...
    }
}
```

## API Reference

### Parser (Event-based)

```zig
pub const Parser = struct {
    pub fn init(a: Allocator, input: []const u8, o: ParseOptions) !Parser;
    pub fn nextEvent(self: *Parser) !Event;
    pub fn deinit(self: *Parser) void;
};
```

### Document Graph

```zig
pub fn loadAll(a: Allocator, input: []const u8, o: ParseOptions) ![]Document;

pub const Document = struct {
    pub fn deinit(self: *Document) void;
    pub fn node(self: *const Document, id: NodeId) *const Node;
};
```

### Value Resolution

```zig
pub fn resolveToValue(a: Allocator, doc: *const Document, o: ParseOptions) !Value;

pub const Value = union(enum) {
    null, bool: bool, int: i64, big_int: []const u8,
    float: f64, inf_pos, inf_neg, nan,
    str: []const u8, seq: []Value,
    map: []struct { k: Value, v: Value },
};
```

### Emitter

```zig
pub fn dumpAll(a: Allocator, docs: []const Value, o: EmitOptions) ![]u8;
```

### Options

```zig
pub const ParseOptions = struct {
    schema: Schema = .core,           // failsafe, json, core
    unique_keys: bool = true,
    max_bytes: usize = 8*1024*1024,   // 8 MiB
    max_depth: u16 = 200,
    max_nodes: u32 = 1_000_000,
    max_aliases: u32 = 5000,
    max_scalar_bytes: usize = 1024*1024,
};
```

## Supported YAML Features

- Multi-document streams (`---` / `...`)
- Directives (`%YAML`, `%TAG`)
- Tags (verbatim `!<uri>`, shorthand `!!type`, primary `!tag`)
- Anchors (`&name`) and aliases (`*name`)
- Block collections (sequences and mappings)
- Flow collections (`[...]` and `{...}`)
- All scalar styles:
  - Plain
  - Single-quoted (`'...'`)
  - Double-quoted (`"..."` with escape sequences)
  - Literal block (`|` with chomping indicators)
  - Folded block (`>` with chomping indicators)
- Comments (ignored)

## Testing

```bash
# Run all tests
zig build test

# Run unit tests only
zig build test-unit

# Run acceptance tests only
zig build test-accept
```

## Design Rationale

1. **Layered architecture** (scanner -> parser -> composer -> resolver) enables streaming, testability, and clear separation of concerns per YAML spec stages.

2. **O(n) streaming scan** achieved by single-pass tokenization with indent stack tracking; no quadratic rescans for block scalar boundaries.

3. **Graph-first design** preserves anchors/aliases in document representation, enabling round-trip fidelity and cycle detection during resolution.

4. **Schema resolution deferred** to value layer allows same document graph to be interpreted under different schemas without re-parsing.

5. **Resource limits enforced early** at scanner/parser level prevents DoS from deeply nested structures, large scalars, or alias bombs.

6. **Canonical emitter determinism** via block-style output, sorted traversal order, and predictable escaping ensures reproducible serialization.

7. **No YAML 1.1 merge key** (`<<`) processing avoids implicit data transformations that break security expectations in configuration files.

## License

Apache-2.0 License - see LICENSE file for details.
