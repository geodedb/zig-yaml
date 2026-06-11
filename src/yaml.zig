// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! # YAML 1.2.2 Parser Library for Zig
//!
//! A complete YAML 1.2.2 implementation with:
//! - Streaming event-based parser (O(n))
//! - Document graph representation
//! - Schema-based value resolution (failsafe, json, core)
//! - Canonical emitter
//!
//! ## Quick Start
//! ```zig
//! const yaml = @import("yaml");
//!
//! // Parse and resolve to values
//! var docs = try yaml.loadAll(allocator, input, .{});
//! defer for (docs) |*d| d.deinit();
//!
//! for (docs) |doc| {
//!     const value = try yaml.resolveToValue(allocator, &doc, .{});
//!     // Use value...
//! }
//! ```
//!
//! ## Memory Efficiency
//!
//! For large documents, use the streaming `Parser` API instead of `loadAll()`:
//!
//! ```zig
//! var parser = try yaml.Parser.init(allocator, input, .{});
//! defer parser.deinit();
//! while (true) {
//!     const event = try parser.nextEvent();
//!     if (event == .stream_end) break;
//!     // Process events without building full document tree
//! }
//! ```
//!
//! Configure resource limits via `ParseOptions` to prevent DoS attacks.

const std = @import("std");
const build_info = @import("build_info");

// ============================================================================
// Version Information
// ============================================================================

/// Library version as string. Single-sourced from build.zig.zon via build
/// options so the manifest version and this constant can never drift.
pub const version_string: []const u8 = build_info.version;

/// Library version, parsed from the single-sourced `version_string`.
pub const version = std.SemanticVersion.parse(version_string) catch
    @compileError("build.zig.zon version is not valid semver: " ++ version_string);

// Re-export submodules
pub const scanner = @import("scanner.zig");
pub const parser_mod = @import("parser.zig");
pub const composer_mod = @import("composer.zig");
pub const resolver_mod = @import("resolver.zig");
pub const emitter_mod = @import("emitter.zig");
pub const debug_json = @import("debug_json.zig");
pub const limits = @import("limits.zig");
pub const validate_mod = @import("validate.zig");
pub const json_mod = @import("json.zig");
pub const comptime_mod = @import("comptime.zig");
pub const err_mod = @import("error.zig");

/// Parallel operations (requires `thread_pool`).
pub const parallel = @import("parallel.zig");

// ============================================================================
// Public Types (as specified in API)
// ============================================================================

/// YAML schema for value resolution.
///
/// The schema determines how plain scalars are interpreted:
/// - `failsafe`: All scalars are strings (no type inference)
/// - `json`: JSON-compatible types (null, bool, int, float, string)
/// - `core`: Full YAML 1.2.2 core schema (default, includes octal/hex/inf/nan)
/// - `yaml11`: YAML 1.1 compatibility (yes/no booleans, 0-prefix octal, sexagesimal)
pub const Schema = enum {
    /// Failsafe schema: all scalars are strings
    failsafe,
    /// JSON schema: null, bool, int, float, string
    json,
    /// Core schema: full YAML 1.2.2 type resolution (default)
    core,
    /// YAML 1.1 compatibility: yes/no/on/off booleans, 0-prefix octal, binary, sexagesimal
    yaml11,
};

/// Options for parsing YAML documents.
///
/// All limits have sensible defaults for typical use cases.
/// Adjust limits for security-sensitive applications or
/// when processing very large documents.
pub const ParseOptions = struct {
    /// Schema for resolving scalar types (default: core)
    schema: Schema = .core,
    /// Whether to reject duplicate keys in mappings (default: true).
    ///
    /// Duplicate detection compares scalar key *content*, so plain and quoted
    /// spellings of the same key (`a` and "a") are caught. Two limitations:
    /// non-scalar keys (e.g. `[a]` used as a complex key) are not deduplicated,
    /// and scalars that are textually different but resolve to the same value
    /// under the active schema (e.g. `0x1` and `1`, or yaml11 `yes` and `true`)
    /// are treated as distinct. Returns error.DuplicateKey on a repeated key.
    unique_keys: bool = true,
    /// Maximum input size in bytes (default: 8MB)
    max_bytes: usize = 8 * 1024 * 1024,
    /// Maximum nesting depth (default: 200)
    max_depth: u16 = 200,
    /// Maximum number of nodes (default: 1M)
    max_nodes: u32 = 1_000_000,
    /// Maximum number of aliases (default: 5000)
    max_aliases: u32 = 5000,
    /// Maximum scalar size in bytes (default: 1MB)
    max_scalar_bytes: usize = 1024 * 1024,
};

// Re-export consolidated error types
pub const ErrorCode = err_mod.ErrorCode;
pub const ParseError = err_mod.ParseError;
// Note: formatError and writeError are defined locally below with yaml-specific handling

pub const NodeMeta = struct {
    tag: []const u8 = "?",
    anchor: ?[]const u8 = null,
};

pub const ScalarStyle = enum {
    plain,
    single_quoted,
    double_quoted,
    literal,
    folded,
};

pub const Event = union(enum) {
    stream_start,
    stream_end,
    doc_start,
    doc_end,
    seq_start: NodeMeta,
    seq_end,
    map_start: NodeMeta,
    map_end,
    scalar: struct {
        meta: NodeMeta,
        style: ScalarStyle,
        value: []const u8,
    },
    alias: []const u8,
};

// ============================================================================
// Parser API (Streaming / Memory-Efficient)
// ============================================================================

/// SAX-style streaming parser for memory-efficient YAML processing.
///
/// Unlike `loadAll()` which builds the entire document graph in memory,
/// the Parser provides events one at a time, allowing processing of
/// arbitrarily large documents with bounded memory usage.
///
/// ## Memory Efficiency
///
/// For large documents, prefer the streaming Parser over loadAll():
/// - Events are generated on-demand, not buffered
/// - Scalar values reference the original input (no copies for plain scalars)
/// - Only the current event needs to be in memory
///
/// ## Example: Streaming Processing
///
/// ```zig
/// var parser = try yaml.Parser.init(allocator, input, .{});
/// defer parser.deinit();
///
/// while (true) {
///     const event = try parser.nextEvent();
///     switch (event) {
///         .stream_end => break,
///         .scalar => |s| processScalar(s.value),
///         .map_start => startObject(),
///         .map_end => endObject(),
///         // ... handle other events
///     }
/// }
/// ```
///
/// ## Use Cases
///
/// - Processing large log files or data dumps
/// - Extracting specific fields from large documents
/// - Building custom data structures without intermediate representation
pub const Parser = struct {
    inner: parser_mod.Parser,
    last_error: ?ParseError,

    /// Initialize a streaming parser.
    /// The input slice must remain valid for the lifetime of the parser.
    pub fn init(a: std.mem.Allocator, input: []const u8, o: ParseOptions) !Parser {
        const inner_opts = parser_mod.ParseOptions{
            .schema = convertSchema(o.schema),
            .unique_keys = o.unique_keys,
            .max_bytes = o.max_bytes,
            .max_depth = o.max_depth,
            .max_nodes = o.max_nodes,
            .max_aliases = o.max_aliases,
            .max_scalar_bytes = o.max_scalar_bytes,
        };
        return Parser{
            .inner = try parser_mod.Parser.init(a, input, inner_opts),
            .last_error = null,
        };
    }

    pub fn nextEvent(self: *Parser) !Event {
        const inner_event = self.inner.nextEvent() catch |err| {
            if (self.inner.getLastError()) |pe| {
                self.last_error = ParseError{
                    .code = convertErrorCode(pe.code),
                    .line = pe.line,
                    .col = pe.col,
                    .offset = pe.offset,
                    .context = pe.name, // Pass through context from parser
                };
            }
            return err;
        };
        return convertEvent(inner_event);
    }

    pub fn deinit(self: *Parser) void {
        self.inner.deinit();
    }

    pub fn getLastError(self: *const Parser) ?ParseError {
        return self.last_error;
    }
};

// ============================================================================
// Graph API
// ============================================================================

pub const NodeId = u32;

pub const Document = struct {
    inner: composer_mod.Document,

    pub fn init(allocator: std.mem.Allocator) Document {
        return .{ .inner = composer_mod.Document.init(allocator) };
    }

    pub fn deinit(self: *Document) void {
        self.inner.deinit();
    }

    pub fn root(self: *const Document) NodeId {
        return self.inner.root;
    }

    pub fn node(self: *const Document, id: NodeId) *const Node {
        // We need to return pointer to converted node
        // For now, return inner node with type pun
        return @ptrCast(self.inner.node(id));
    }

    pub fn arena(self: *Document) *std.heap.ArenaAllocator {
        return &self.inner.arena;
    }
};

pub const Node = union(enum) {
    s: struct {
        meta: NodeMeta,
        style: ScalarStyle,
        v: []const u8,
    },
    q: struct {
        meta: NodeMeta,
        items: []NodeId,
    },
    m: struct {
        meta: NodeMeta,
        items: []struct { k: NodeId, v: NodeId },
    },
    a: []const u8,
};

/// Result of loading YAML with error details
pub const LoadResult = struct {
    documents: []Document,
    /// Error information if parsing failed (null on success)
    parse_error: ?ParseError,

    pub fn deinit(self: *LoadResult, a: std.mem.Allocator) void {
        for (self.documents) |*d| d.deinit();
        a.free(self.documents);
    }
};

/// Parse all YAML documents from a string.
///
/// Returns a slice of Document objects. Each document must be deinitialized
/// when no longer needed, and the slice itself must be freed.
///
/// ## Example
/// ```zig
/// var docs = try yaml.loadAll(allocator, input, .{});
/// defer {
///     for (docs) |*d| d.deinit();
///     allocator.free(docs);
/// }
/// ```
///
/// ## Errors
/// Returns an error if parsing fails due to invalid YAML syntax or
/// resource limits being exceeded.
pub fn loadAll(a: std.mem.Allocator, input: []const u8, o: ParseOptions) ![]Document {
    const inner_opts = parser_mod.ParseOptions{
        .schema = convertSchema(o.schema),
        .unique_keys = o.unique_keys,
        .max_bytes = o.max_bytes,
        .max_depth = o.max_depth,
        .max_nodes = o.max_nodes,
        .max_aliases = o.max_aliases,
        .max_scalar_bytes = o.max_scalar_bytes,
    };

    var comp = try composer_mod.Composer.init(a, input, inner_opts);
    defer comp.deinit();

    const inner_docs = try comp.composeAll();

    var result = try a.alloc(Document, inner_docs.len);
    for (inner_docs, 0..) |inner, i| {
        result[i] = .{ .inner = inner };
    }

    // Clear composer's list without freeing (docs moved to result)
    comp.documents.items.len = 0;

    return result;
}

/// Load all YAML documents with detailed error information.
/// Returns a LoadResult with parse_error set on failure.
/// Unlike loadAll, this function captures error details for better diagnostics.
pub fn loadAllWithDetails(a: std.mem.Allocator, input: []const u8, o: ParseOptions) LoadResult {
    const inner_opts = parser_mod.ParseOptions{
        .schema = convertSchema(o.schema),
        .unique_keys = o.unique_keys,
        .max_bytes = o.max_bytes,
        .max_depth = o.max_depth,
        .max_nodes = o.max_nodes,
        .max_aliases = o.max_aliases,
        .max_scalar_bytes = o.max_scalar_bytes,
    };

    var comp = composer_mod.Composer.init(a, input, inner_opts) catch |err| {
        return .{
            .documents = &.{},
            .parse_error = ParseError{
                .code = mapComposerErrorToCode(err),
                .line = 1,
                .col = 1,
                .offset = 0,
            },
        };
    };
    defer comp.deinit();

    const inner_docs = comp.composeAll() catch |err| {
        // Try to get detailed error from parser first
        if (comp.getParserError()) |pe| {
            return .{
                .documents = &.{},
                .parse_error = ParseError{
                    .code = convertErrorCode(pe.code),
                    // Locations are 1-based; clamp so the documented "line/col
                    // are >= 1" contract holds even if a source left them unset.
                    .line = @max(1, pe.line),
                    .col = @max(1, pe.col),
                    .offset = pe.offset,
                    .context = pe.name,
                },
            };
        }
        // Fall back to composer error info. Composer-only errors (duplicate
        // key, undefined anchor, resource limits) may not carry a location, so
        // clamp to >= 1 rather than emitting 0,0.
        return .{
            .documents = &.{},
            .parse_error = ParseError{
                .code = mapComposerErrorToCode(err),
                .line = @max(1, comp.getErrorLine()),
                .col = @max(1, comp.getErrorCol()),
                .offset = 0,
                .context = comp.getErrorName(),
            },
        };
    };

    const result = a.alloc(Document, inner_docs.len) catch {
        return .{
            .documents = &.{},
            .parse_error = ParseError{
                .code = .internal_error,
                .line = 1,
                .col = 1,
                .offset = 0,
            },
        };
    };

    for (inner_docs, 0..) |inner, i| {
        result[i] = .{ .inner = inner };
    }

    // Clear composer's list without freeing (docs moved to result)
    comp.documents.items.len = 0;

    return .{
        .documents = result,
        .parse_error = null,
    };
}

fn mapComposerErrorToCode(err: anyerror) ErrorCode {
    return switch (err) {
        error.UndefinedAnchor => .undefined_anchor,
        error.DuplicateKey => .duplicate_key,
        error.MaxDepthExceeded => .max_depth_exceeded,
        error.MaxNodesExceeded => .max_nodes_exceeded,
        error.AliasCycle => .alias_cycle,
        error.ParseFailed => .unexpected_token,
        else => .internal_error,
    };
}

/// Load all YAML documents from a reader.
/// Reads all content into memory first, then parses.
/// The caller owns the returned slice and must call deinit() on each document.
pub fn loadAllFromReader(a: std.mem.Allocator, reader: anytype, o: ParseOptions) ![]Document {
    // Read all content into a buffer
    const content = try reader.readAllAlloc(a, o.max_bytes);
    defer a.free(content);

    return try loadAll(a, content, o);
}

/// Load all YAML documents from a file.
/// The caller owns the returned slice and must call deinit() on each document.
pub fn loadAllFromFile(a: std.mem.Allocator, path: []const u8, o: ParseOptions) ![]Document {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    return try loadAllFromReader(a, file.reader(), o);
}

/// Iterator for streaming events from a parser.
/// Provides a convenient interface for processing YAML as a stream of events.
pub const EventIterator = struct {
    parser: Parser,
    done: bool,

    pub fn next(self: *EventIterator) !?Event {
        if (self.done) return null;

        const event = try self.parser.nextEvent();
        if (event == .stream_end) {
            self.done = true;
        }
        return event;
    }

    pub fn deinit(self: *EventIterator) void {
        self.parser.deinit();
    }

    pub fn getLastError(self: *const EventIterator) ?ParseError {
        return self.parser.getLastError();
    }
};

/// Create an event iterator for streaming parsing.
/// Use this when you want to process events one at a time without building the full document tree.
pub fn streamEvents(a: std.mem.Allocator, input: []const u8, o: ParseOptions) !EventIterator {
    return EventIterator{
        .parser = try Parser.init(a, input, o),
        .done = false,
    };
}

/// Create an event iterator from a reader.
/// Reads all content into memory first, then provides streaming events.
pub fn streamEventsFromReader(a: std.mem.Allocator, reader: anytype, o: ParseOptions) !struct {
    iterator: EventIterator,
    buffer: []u8,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        self.iterator.deinit();
        allocator.free(self.buffer);
    }
} {
    const content = try reader.readAllAlloc(a, o.max_bytes);
    errdefer a.free(content);

    return .{
        .iterator = try streamEvents(a, content, o),
        .buffer = content,
    };
}

// ============================================================================
// Resolved Values API
// ============================================================================

pub const ValueKVPair = struct { k: Value, v: Value };

pub const Value = union(enum) {
    null,
    bool: bool,
    int: i64,
    big_int: []const u8,
    float: f64,
    inf_pos,
    inf_neg,
    nan,
    str: []const u8,
    seq: []Value,
    map: []ValueKVPair,
};

/// Resolve a Document's graph structure to a Value tree.
///
/// This applies schema-based type resolution to scalar values,
/// resolves anchor/alias references, and produces a tree of
/// typed values (null, bool, int, float, string, sequence, mapping).
///
/// ## Parameters
/// - `a`: Allocator for the Value tree
/// - `doc`: Document to resolve
/// - `o`: Options (schema determines type resolution rules)
///
/// ## Returns
/// A Value tree. Call `freeValue` to release when done.
///
/// ## Aliases and resource limits
/// Each alias is expanded into an independent copy of its target subtree, so
/// the returned Value is a true tree that `freeValue` owns and releases exactly
/// once (no shared pointers). Because expansion re-materializes the target, an
/// anchor referenced N times costs N copies; total expansion is bounded by
/// `o.max_nodes` (returns error.MaxNodesExceeded) and nesting by `o.max_depth`
/// (returns error.MaxDepthExceeded), which together defeat alias-amplification
/// (billion-laughs) attacks.
pub fn resolveToValue(a: std.mem.Allocator, doc: *const Document, o: ParseOptions) !Value {
    const inner_opts = parser_mod.ParseOptions{
        .schema = convertSchema(o.schema),
        .unique_keys = o.unique_keys,
        .max_bytes = o.max_bytes,
        .max_depth = o.max_depth,
        .max_nodes = o.max_nodes,
        .max_aliases = o.max_aliases,
        .max_scalar_bytes = o.max_scalar_bytes,
    };

    const inner_value = try resolver_mod.resolveToValue(a, &doc.inner, inner_opts);
    return convertValue(inner_value);
}

/// Recursively free all allocations inside a Value
pub fn freeValue(a: std.mem.Allocator, value: *const Value) void {
    // Since Value and resolver_mod.Value have the same memory layout,
    // we can use ptrCast
    resolver_mod.freeValue(a, @ptrCast(value));
}

// ============================================================================
// Emitter API
// ============================================================================

/// Collection formatting style for emitter
pub const CollectionStyle = emitter_mod.CollectionStyle;

/// String quoting style for emitter
pub const QuoteStyle = emitter_mod.QuoteStyle;

/// Options for YAML emission
pub const EmitOptions = struct {
    /// Number of spaces per indentation level
    indent: u8 = 2,
    /// Include document start marker (---)
    doc_start: bool = true,
    /// Include document end marker (...)
    doc_end: bool = true,
    /// Collection formatting style
    collection_style: CollectionStyle = .block,
    /// String quoting style
    quote_style: QuoteStyle = .minimal,
    /// Maximum line width for flow collections (0 = no limit)
    max_line_width: u16 = 0,
    /// Add blank line between top-level keys
    blank_lines_between_keys: bool = false,
};

/// Emit Value trees as YAML text.
///
/// Converts Value trees back to YAML text format with configurable
/// formatting options.
///
/// ## Anchors / aliases
/// `dumpAll` serializes a resolved `Value` tree, in which aliases have already
/// been expanded into independent subtrees (see `resolveToValue`). It therefore
/// **inlines** what were anchor/alias references rather than re-emitting
/// `&name`/`*name`, and shared structure is duplicated. Anchor/alias
/// *preservation* is available only at the document-graph layer (`Document` /
/// `Node.a` / `Document.anchors`), not through the `resolveToValue` → `dumpAll`
/// value pipeline. A cyclic graph cannot be represented as a `Value` at all
/// (resolution rejects it with `error.AliasCycle`).
///
/// ## Example
/// ```zig
/// const output = try yaml.dumpAll(allocator, &.{value}, .{});
/// defer allocator.free(output);
/// std.debug.print("{s}", .{output});
/// ```
///
/// ## Returns
/// Caller-owned YAML string. Free with allocator when done.
pub fn dumpAll(a: std.mem.Allocator, docs: []const Value, o: EmitOptions) ![]u8 {
    // Convert Values to inner format
    var inner_docs = try a.alloc(resolver_mod.Value, docs.len);
    defer a.free(inner_docs);

    for (docs, 0..) |doc, i| {
        inner_docs[i] = convertValueToInner(doc);
    }

    return try emitter_mod.dumpAll(a, inner_docs, .{
        .indent = o.indent,
        .doc_start = o.doc_start,
        .doc_end = o.doc_end,
        .collection_style = o.collection_style,
        .quote_style = o.quote_style,
        .max_line_width = o.max_line_width,
        .blank_lines_between_keys = o.blank_lines_between_keys,
    });
}

// ============================================================================
// Debug Helpers API
// ============================================================================

pub fn debugJsonValue(a: std.mem.Allocator, vals: []const Value) ![]u8 {
    var inner_vals = try a.alloc(resolver_mod.Value, vals.len);
    defer a.free(inner_vals);

    for (vals, 0..) |val, i| {
        inner_vals[i] = convertValueToInner(val);
    }

    return try debug_json.debugJsonValue(a, inner_vals);
}

pub fn debugJsonGraph(a: std.mem.Allocator, docs: []const Document) ![]u8 {
    var inner_docs = try a.alloc(composer_mod.Document, docs.len);
    defer a.free(inner_docs);

    for (docs, 0..) |doc, i| {
        inner_docs[i] = doc.inner;
    }

    return try debug_json.debugJsonGraph(a, inner_docs);
}

// ============================================================================
// Error Formatting API
// ============================================================================

/// Format a parse error into an allocator-owned string.
/// Caller must free the returned slice.
pub fn formatError(a: std.mem.Allocator, err: ParseError) ![]u8 {
    var buf: [512]u8 = undefined;
    const msg = err.formatBuf(&buf);
    return try a.dupe(u8, msg);
}

/// Format a parse error to a writer
pub fn writeError(writer: anytype, err: ParseError) !void {
    if (err.context.len > 0) {
        try writer.print("{s} at line {d}, column {d}: {s}", .{
            err.code.message(),
            err.line,
            err.col,
            err.context,
        });
    } else {
        try writer.print("{s} at line {d}, column {d}", .{
            err.code.message(),
            err.line,
            err.col,
        });
    }
}

// ============================================================================
// Validation API
// ============================================================================

/// Schema definition for validation
pub const ValidationSchema = validate_mod.Schema;

/// Validation error details
pub const ValidationError = validate_mod.ValidationError;

/// Validation result
pub const ValidationResult = validate_mod.ValidationResult;

/// Validate a value against a schema
pub fn validateValue(a: std.mem.Allocator, value: Value, s: ValidationSchema) !ValidationResult {
    const inner_value = convertValueToInner(value);
    return try validate_mod.validate(a, inner_value, s);
}

// ============================================================================
// JSON Conversion API
// ============================================================================

pub const JsonOptions = json_mod.JsonOptions;

/// Convert a resolved YAML value to JSON string.
/// NaN and Infinity values will return error.InvalidFloat since JSON doesn't support them.
pub fn toJson(a: std.mem.Allocator, value: Value, options: JsonOptions) ![]u8 {
    const inner_value = convertValueToInner(value);
    return try json_mod.toJson(a, inner_value, options);
}

/// Convert multiple resolved YAML values to a JSON array.
pub fn toJsonArray(a: std.mem.Allocator, values: []const Value, options: JsonOptions) ![]u8 {
    var inner_values = try a.alloc(resolver_mod.Value, values.len);
    defer a.free(inner_values);

    for (values, 0..) |v, i| {
        inner_values[i] = convertValueToInner(v);
    }

    return try json_mod.toJsonArray(a, inner_values, options);
}

// ============================================================================
// Comptime Parsing API
// ============================================================================

/// Comptime YAML value type
pub const ComptimeValue = comptime_mod.Value;

/// Parse YAML at compile time.
/// Returns the root value of the document.
/// This enables embedding YAML configuration directly in the binary.
///
/// ## Supported subset
/// The comptime parser is intentionally a **subset** of the runtime parser,
/// sized for embedding small, trusted configuration (`@embedFile`/literals),
/// not arbitrary untrusted input. It supports block and flow mappings and
/// sequences, plain and quoted scalars, and nested structures. It does NOT
/// implement anchors/aliases, tags, multi-document streams, directives, block
/// scalars (`|`/`>`), or schema-based typing, and it has fixed comptime
/// capacity limits (block sequence ≤ 256 items, block mapping ≤ 128 keys, flow
/// collections ≤ 64 entries, nesting ≤ 64) that fail the build with a clear
/// `@compileError` when exceeded. For anything beyond small embedded config,
/// use the runtime `loadAll` / `resolveToValue` API.
///
/// Example:
/// ```zig
/// const config = comptime yaml.comptimeParse(@embedFile("config.yaml"));
/// const name = config.get("name").?.asString().?;
/// ```
pub fn comptimeParse(comptime input: []const u8) ComptimeValue {
    return comptime_mod.parse(input);
}

/// Parse YAML and return a specific field from the root map.
pub fn comptimeParseField(comptime input: []const u8, comptime field: []const u8) ?ComptimeValue {
    return comptime_mod.parseField(input, field);
}

/// Schema builder helpers
pub const schema = struct {
    pub const any = ValidationSchema.any;
    pub const @"null" = ValidationSchema.null;
    pub const @"bool" = ValidationSchema.bool;
    pub const int = ValidationSchema.int;
    pub const float = ValidationSchema.float;
    pub const str = ValidationSchema.str;

    pub fn stringEnum(values: []const []const u8) ValidationSchema {
        return validate_mod.stringEnum(values);
    }

    pub fn optional(comptime inner: ValidationSchema) ValidationSchema {
        return validate_mod.optional(inner);
    }

    pub fn seqOf(comptime item: ValidationSchema) ValidationSchema {
        return validate_mod.seqOf(item);
    }

    pub fn mapOf(comptime key: ValidationSchema, comptime value_schema: ValidationSchema) ValidationSchema {
        return validate_mod.mapOf(key, value_schema);
    }

    pub fn intRange(min: ?i64, max: ?i64) ValidationSchema {
        return .{ .int_range = .{ .min = min, .max = max } };
    }

    pub fn object(fields: []const ValidationSchema.Field) ValidationSchema {
        return .{ .object = fields };
    }

    /// Glob-style string pattern: `*` matches any run, `?` matches one char.
    pub fn pattern(p: []const u8) ValidationSchema {
        return validate_mod.pattern(p);
    }

    /// Union schema: the value must match one of the alternatives.
    pub fn oneOf(schemas: []const *const ValidationSchema) ValidationSchema {
        return validate_mod.oneOf(schemas);
    }
};

// ============================================================================
// Conversion Helpers
// ============================================================================

fn convertSchema(s: Schema) parser_mod.Schema {
    return switch (s) {
        .failsafe => .failsafe,
        .json => .json,
        .core => .core,
        .yaml11 => .yaml11,
    };
}

fn convertErrorCode(code: parser_mod.ErrorCode) ErrorCode {
    // Both yaml.zig and parser.zig now use the same ErrorCode from error.zig
    return code;
}

fn convertScalarStyle(s: parser_mod.ScalarStyle) ScalarStyle {
    return switch (s) {
        .plain => .plain,
        .single_quoted => .single_quoted,
        .double_quoted => .double_quoted,
        .literal => .literal,
        .folded => .folded,
    };
}

fn convertEvent(e: parser_mod.Event) Event {
    return switch (e) {
        .stream_start => .stream_start,
        .stream_end => .stream_end,
        .doc_start => .doc_start,
        .doc_end => .doc_end,
        .seq_start => |m| .{ .seq_start = .{ .tag = m.tag, .anchor = m.anchor } },
        .seq_end => .seq_end,
        .map_start => |m| .{ .map_start = .{ .tag = m.tag, .anchor = m.anchor } },
        .map_end => .map_end,
        .scalar => |s| .{ .scalar = .{
            .meta = .{ .tag = s.meta.tag, .anchor = s.meta.anchor },
            .style = convertScalarStyle(s.style),
            .value = s.value,
        } },
        .alias => |name| .{ .alias = name },
    };
}

fn convertValue(v: resolver_mod.Value) Value {
    return switch (v) {
        .null => .null,
        .bool => |b| .{ .bool = b },
        .int => |i| .{ .int = i },
        .big_int => |s| .{ .big_int = s },
        .float => |f| .{ .float = f },
        .inf_pos => .inf_pos,
        .inf_neg => .inf_neg,
        .nan => .nan,
        .str => |s| .{ .str = s },
        .seq => |items| {
            // Need to convert recursively - but we can't allocate here
            // Return as-is since memory layout is compatible
            return .{ .seq = @ptrCast(items) };
        },
        .map => |items| {
            return .{ .map = @ptrCast(items) };
        },
    };
}

fn convertValueToInner(v: Value) resolver_mod.Value {
    return switch (v) {
        .null => .null,
        .bool => |b| .{ .bool = b },
        .int => |i| .{ .int = i },
        .big_int => |s| .{ .big_int = s },
        .float => |f| .{ .float = f },
        .inf_pos => .inf_pos,
        .inf_neg => .inf_neg,
        .nan => .nan,
        .str => |s| .{ .str = s },
        .seq => |items| .{ .seq = @ptrCast(items) },
        .map => |items| .{ .map = @ptrCast(items) },
    };
}

// ============================================================================
// Layout compatibility guards
//
// The public Value/Node/ValueKVPair types are intentionally bit-identical
// re-declarations of the inner resolver_mod/composer_mod types. The conversion
// helpers above pun between them with @ptrCast on the seq/map payloads and
// Document.node() pun-casts the whole node, which is only sound while the
// layouts match exactly. These comptime assertions fail the build the moment
// a tag is reordered/added or a field changes in only one of the pair, turning
// silent undefined behavior into a compile error.
// ============================================================================

fn assertSameSizeAlign(comptime A: type, comptime B: type) void {
    if (@sizeOf(A) != @sizeOf(B)) {
        @compileError("yaml: layout drift — @sizeOf(" ++ @typeName(A) ++ ") != @sizeOf(" ++ @typeName(B) ++ ")");
    }
    if (@alignOf(A) != @alignOf(B)) {
        @compileError("yaml: layout drift — @alignOf(" ++ @typeName(A) ++ ") != @alignOf(" ++ @typeName(B) ++ ")");
    }
}

fn assertSameUnionTags(comptime A: type, comptime B: type) void {
    const ta = @typeInfo(@typeInfo(A).@"union".tag_type.?).@"enum";
    const tb = @typeInfo(@typeInfo(B).@"union".tag_type.?).@"enum";
    if (ta.fields.len != tb.fields.len) {
        @compileError("yaml: layout drift — tag count differs between " ++ @typeName(A) ++ " and " ++ @typeName(B));
    }
    inline for (ta.fields, tb.fields) |fa, fb| {
        if (!std.mem.eql(u8, fa.name, fb.name) or fa.value != fb.value) {
            @compileError("yaml: layout drift — tag mismatch between " ++ @typeName(A) ++ " and " ++ @typeName(B) ++ " at '" ++ fa.name ++ "'");
        }
    }
}

comptime {
    assertSameSizeAlign(Value, resolver_mod.Value);
    assertSameUnionTags(Value, resolver_mod.Value);
    assertSameSizeAlign(ValueKVPair, resolver_mod.ValueKVPair);
    assertSameSizeAlign(Node, composer_mod.Node);
    assertSameUnionTags(Node, composer_mod.Node);
}

// ============================================================================
// Tests
// ============================================================================

test "yaml: basic parsing" {
    const allocator = std.testing.allocator;

    const input = "---\nkey: value\n";
    var p = try Parser.init(allocator, input, .{});
    defer p.deinit();

    var event = try p.nextEvent();
    try std.testing.expect(event == .stream_start);

    event = try p.nextEvent();
    try std.testing.expect(event == .doc_start);
}

test "yaml: loadAll basic" {
    const allocator = std.testing.allocator;

    const input = "---\na: 1\n";
    const docs = try loadAll(allocator, input, .{});
    defer {
        for (docs) |*d| d.deinit();
        allocator.free(docs);
    }

    try std.testing.expectEqual(@as(usize, 1), docs.len);
}

test "yaml: error message formatting" {
    // Test ErrorCode.message()
    try std.testing.expectEqualStrings("tabs are not allowed for indentation", ErrorCode.tab_in_indentation.message());
    try std.testing.expectEqualStrings("reference to undefined anchor", ErrorCode.undefined_anchor.message());
    try std.testing.expectEqualStrings("unexpected token in input", ErrorCode.unexpected_token.message());

    // Test ParseError.message()
    const err = ParseError{
        .code = .invalid_escape,
        .line = 5,
        .col = 10,
        .offset = 42,
    };
    try std.testing.expectEqualStrings("invalid escape sequence in string", err.message());

    // Test ParseError.formatBuf()
    var buf: [256]u8 = undefined;
    const formatted = err.formatBuf(&buf);
    try std.testing.expectEqualStrings("invalid escape sequence in string at line 5, column 10", formatted);

    // Test ParseError with context
    const err_with_ctx = ParseError{
        .code = .undefined_anchor,
        .line = 3,
        .col = 8,
        .offset = 20,
        .context = "missing_anchor",
    };
    const formatted_ctx = err_with_ctx.formatBuf(&buf);
    try std.testing.expectEqualStrings("reference to undefined anchor at line 3, column 8: missing_anchor", formatted_ctx);
}

test "yaml: formatError allocates string" {
    const allocator = std.testing.allocator;

    const err = ParseError{
        .code = .tab_in_indentation,
        .line = 1,
        .col = 1,
        .offset = 0,
    };

    const msg = try formatError(allocator, err);
    defer allocator.free(msg);

    try std.testing.expectEqualStrings("tabs are not allowed for indentation at line 1, column 1", msg);
}

test "yaml: loadAllWithDetails success" {
    const allocator = std.testing.allocator;

    const input = "---\na: 1\nb: 2\n";
    var result = loadAllWithDetails(allocator, input, .{});

    // Should succeed with no error
    try std.testing.expect(result.parse_error == null);
    try std.testing.expectEqual(@as(usize, 1), result.documents.len);

    result.deinit(allocator);
}

test "yaml: loadAllWithDetails with error" {
    const allocator = std.testing.allocator;

    // Invalid YAML should fail
    const input = "a: [b"; // Unterminated flow sequence
    const result = loadAllWithDetails(allocator, input, .{});

    // Should have an error with location info
    try std.testing.expect(result.parse_error != null);
    if (result.parse_error) |err| {
        // Verify we get location information
        try std.testing.expect(err.line >= 1);
        try std.testing.expect(err.col >= 1);
        // Error message should be non-empty
        try std.testing.expect(err.message().len > 0);
    }
}

test "yaml: loadAllWithDetails syntax error" {
    const allocator = std.testing.allocator;

    // Invalid block structure - indentation error
    const input = "a:\nb: c"; // 'b' should be indented under 'a'
    const result = loadAllWithDetails(allocator, input, .{});

    // This actually parses as two separate values, not an error
    // Let's use something that definitely fails
    const input2 = "[[["; // Multiple unclosed brackets
    const result2 = loadAllWithDetails(allocator, input2, .{});

    // Should have an error with location info
    try std.testing.expect(result2.parse_error != null);
    if (result2.parse_error) |err| {
        try std.testing.expect(err.line >= 1);
        try std.testing.expect(err.message().len > 0);
    }

    // Clean up success case if result parsed successfully
    if (result.parse_error == null) {
        var r = result;
        r.deinit(allocator);
    }
}

test "yaml: loadAllWithDetails composer error has location >= 1" {
    const allocator = std.testing.allocator;

    // Duplicate key is a composer-only error that historically left the
    // location unset (line=0). The location must still satisfy the >= 1
    // contract documented for ParseError. The error result carries an empty
    // (non-heap) documents slice, so it must not be deinit'd.
    const result = loadAllWithDetails(allocator, "{a: 1, a: 2}", .{});

    try std.testing.expect(result.parse_error != null);
    try std.testing.expectEqual(@as(usize, 0), result.documents.len);
    if (result.parse_error) |err| {
        try std.testing.expectEqual(ErrorCode.duplicate_key, err.code);
        try std.testing.expect(err.line >= 1);
        try std.testing.expect(err.col >= 1);
    }
}

test "yaml: version is single-sourced from build.zig.zon" {
    // version_string is injected from the manifest; version is parsed from it.
    try std.testing.expect(version_string.len > 0);
    try std.testing.expectEqual(version.major, (std.SemanticVersion.parse(version_string) catch unreachable).major);
}

test "parallel re-export is reachable" {
    // Smoke test: verify parallel.zig is reachable through the public yaml
    // module, and exercise parallelReduce end-to-end.
    const data = [_]i32{ 1, 2, 3, 4, 5 };
    const sum = parallel.parallelReduce(i32, &data, 0, struct {
        fn add(a: i32, b: i32) i32 {
            return a + b;
        }
    }.add);
    try std.testing.expectEqual(@as(i32, 15), sum);

    // deinitPool() must be a no-op-safe callable through the re-export.
    parallel.deinitPool();
}
