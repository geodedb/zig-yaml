# API Reference

This document provides an overview of the yaml library API. For full documentation, generate the autodocs using `zig build docs`.

## Quick Reference

### Main Module: `yaml`

```zig
const yaml = @import("yaml");
```

## Loading Documents

### Primary Functions

| Function | Description |
|----------|-------------|
| `loadAll(allocator, input, options)` | Parse all YAML documents from a string |
| `loadAllWithDetails(allocator, input, options)` | Parse with detailed error information |
| `loadAllFromFile(allocator, path, options)` | Parse all documents from a file |
| `loadAllFromReader(allocator, reader, options)` | Parse from a reader |

### Usage

```zig
// Basic parsing
var docs = try yaml.loadAll(allocator, input, .{});
defer {
    for (docs) |*d| d.deinit();
    allocator.free(docs);
}

// With detailed errors
var result = yaml.loadAllWithDetails(allocator, input, .{});
if (result.parse_error) |err| {
    std.debug.print("Error: {s} at {d}:{d}\n", .{
        err.message(), err.line, err.col,
    });
} else {
    defer result.deinit(allocator);
    // Use result.documents...
}
```

## Streaming Parser

For memory-efficient processing of large documents.

### Parser

```zig
var parser = try yaml.Parser.init(allocator, input, .{});
defer parser.deinit();

while (true) {
    const event = try parser.nextEvent();
    if (event == .stream_end) break;

    switch (event) {
        .scalar => |s| processScalar(s.value),
        .map_start => startObject(),
        .map_end => endObject(),
        // ...
    }
}
```

### EventIterator

```zig
var iter = try yaml.streamEvents(allocator, input, .{});
defer iter.deinit();

while (try iter.next()) |event| {
    // Process event
}
```

### Events

| Event | Description |
|-------|-------------|
| `stream_start` | Beginning of the YAML stream |
| `stream_end` | End of the YAML stream |
| `doc_start` | Document boundary (---) |
| `doc_end` | Document end (...) |
| `scalar` | Scalar value with tag, anchor, style |
| `seq_start` | Start of sequence |
| `seq_end` | End of sequence |
| `map_start` | Start of mapping |
| `map_end` | End of mapping |
| `alias` | Alias reference (*name) |

## Document Graph

The Document type preserves YAML structure including anchors and aliases.

### Document API

| Method | Description |
|--------|-------------|
| `root()` | Get root node ID |
| `node(id)` | Get node by ID |
| `deinit()` | Free document memory |

### Node Types

```zig
pub const Node = union(enum) {
    s: struct { meta: NodeMeta, style: ScalarStyle, v: []const u8 },  // Scalar
    q: struct { meta: NodeMeta, items: []NodeId },                    // Sequence
    m: struct { meta: NodeMeta, items: []struct { k: NodeId, v: NodeId } }, // Mapping
    a: []const u8,                                                     // Alias
};
```

## Value Resolution

Resolve document graphs to typed values.

### resolveToValue

```zig
const value = try yaml.resolveToValue(allocator, &doc, .{});
defer yaml.freeValue(allocator, &value);
```

### Value Type

```zig
pub const Value = union(enum) {
    null,
    bool: bool,
    int: i64,
    big_int: []const u8,  // For integers exceeding i64
    float: f64,
    inf_pos,              // Positive infinity
    inf_neg,              // Negative infinity
    nan,                  // Not a number
    str: []const u8,
    seq: []Value,
    map: []struct { k: Value, v: Value },
};
```

## Emitter

Convert values back to YAML text.

### dumpAll

```zig
const output = try yaml.dumpAll(allocator, &.{value}, .{
    .indent = 2,
    .doc_start = true,
    .doc_end = true,
    .collection_style = .block,
    .quote_style = .minimal,
});
defer allocator.free(output);
```

### EmitOptions

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `indent` | u8 | 2 | Spaces per indent level |
| `doc_start` | bool | true | Include `---` marker |
| `doc_end` | bool | true | Include `...` marker |
| `collection_style` | CollectionStyle | .block | block, flow_simple, flow |
| `quote_style` | QuoteStyle | .minimal | minimal, single, double |
| `blank_lines_between_keys` | bool | false | Add blank lines |

## Schema Selection

### Available Schemas

| Schema | Description |
|--------|-------------|
| `.failsafe` | All scalars remain as strings |
| `.json` | JSON-compatible types (null, bool, int, float) |
| `.core` | Full YAML 1.2.2 core schema (default) |
| `.yaml11` | YAML 1.1 compatibility mode |

### Schema Differences

| Value | Core | YAML 1.1 |
|-------|------|----------|
| yes/no | string | bool |
| on/off | string | bool |
| 0755 | int(755) | int(493) octal |
| 1:30:00 | string | int(5400) |

## Validation

Validate values against schemas.

### Schema Types

```zig
const yaml = @import("yaml");

// Primitives
yaml.schema.any
yaml.schema.@"null"
yaml.schema.@"bool"
yaml.schema.int
yaml.schema.float
yaml.schema.str

// Combinators
yaml.schema.optional(inner_schema)
yaml.schema.seqOf(item_schema)
yaml.schema.mapOf(key_schema, value_schema)
yaml.schema.intRange(min, max)
yaml.schema.stringEnum(values)
yaml.schema.object(fields)
```

### Example

```zig
const port_schema = yaml.schema.intRange(1, 65535);
const server_schema = yaml.schema.object(&.{
    .{ .name = "host", .schema = &yaml.schema.str, .required = true },
    .{ .name = "port", .schema = &port_schema, .required = true },
});

var result = try yaml.validateValue(allocator, value, server_schema);
defer result.deinit(allocator);

if (!result.valid) {
    for (result.errors) |err| {
        std.debug.print("Error at {s}: {s}\n", .{ err.path, err.message });
    }
}
```

## JSON Conversion

Convert YAML values to JSON.

```zig
const json = try yaml.toJson(allocator, value, .{
    .pretty = true,
    .indent = 2,
});
defer allocator.free(json);
```

## Comptime Parsing

Parse YAML at compile time for embedded configuration.

```zig
const config = comptime yaml.comptimeParse(@embedFile("config.yaml"));
const name = config.get("name").?.asString().?;
```

## Error Handling

### ParseError

```zig
pub const ParseError = struct {
    code: ErrorCode,
    line: u32,
    col: u32,
    offset: usize,
    context: []const u8,

    pub fn message(self: ParseError) []const u8;
    pub fn formatBuf(self: ParseError, buf: []u8) []const u8;
};
```

### Error Codes

| Code | Description |
|------|-------------|
| `unexpected_token` | Unexpected token in input |
| `invalid_escape` | Invalid escape sequence |
| `unterminated_string` | Unclosed string |
| `undefined_anchor` | Reference to undefined anchor |
| `duplicate_key` | Duplicate mapping key |
| `tab_in_indentation` | Tab used for indentation |
| `max_depth_exceeded` | Nesting too deep |
| `max_nodes_exceeded` | Too many nodes |
| `max_aliases_exceeded` | Too many aliases |
| `input_too_large` | Input exceeds size limit |
| `scalar_too_large` | Scalar exceeds size limit |

### Error Formatting

```zig
// Format to allocated string
const msg = try yaml.formatError(allocator, err);
defer allocator.free(msg);

// Format to writer
try yaml.writeError(stderr, err);
```

## Parse Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `schema` | Schema | .core | Schema for type resolution |
| `unique_keys` | bool | true | Reject duplicate keys |
| `max_bytes` | usize | 8 MB | Maximum input size |
| `max_depth` | u16 | 200 | Maximum nesting depth |
| `max_nodes` | u32 | 1,000,000 | Maximum node count |
| `max_aliases` | u32 | 5,000 | Maximum alias count |
| `max_scalar_bytes` | usize | 1 MB | Maximum scalar size |

## Generating Full Documentation

```bash
# Generate HTML documentation
zig build docs

# View documentation
open zig-out/docs/index.html
```

The generated documentation includes full API details from doc comments in the source code.
