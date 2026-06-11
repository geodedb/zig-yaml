// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! YAML 1.2.2 Event-based Parser
//!
//! Converts tokens from scanner into a stream of parse events using a
//! push-down automaton (state machine with stack).
//!
//! # Parser State Machine
//!
//! The parser uses a stack-based state machine where each state represents
//! a parsing context. States are pushed when entering nested structures
//! and popped when exiting them.
//!
//! ## State Flow Overview
//!
//! ```
//! stream_start
//!     │
//!     ├──▶ implicit_doc_start (content without explicit ---)
//!     │         │
//!     └──▶ doc_start (explicit ---) ──▶ doc_content ──▶ doc_end
//!                                            │
//!                                            ▼
//!                                      block_node / flow_node
//!                                            │
//!               ┌────────────────────────────┼────────────────────────────┐
//!               │                            │                            │
//!               ▼                            ▼                            ▼
//!         Block Sequence              Block Mapping               Flow Collections
//!         block_seq_first_entry       block_map_first_key         flow_seq_first_entry
//!         block_seq_entry             block_map_key               flow_seq_entry
//!         indentless_seq_entry        block_map_value             flow_map_first_key
//!                                     block_map_empty_key         flow_map_key/value
//! ```
//!
//! ## State Descriptions
//!
//! - `stream_start`: Initial state, emits STREAM-START event
//! - `implicit_doc_start`: Document started without explicit `---`
//! - `doc_start`: Explicit document start with `---`
//! - `doc_content`: Parsing document root content
//! - `doc_end`: Document ended, looking for next doc or stream end
//! - `block_node`: Parsing a block-level node (scalar, seq, or map)
//! - `block_node_or_indentless_seq`: Node that might be an indentless sequence
//! - `flow_node`: Parsing a flow-level node
//! - `block_seq_*`: Block sequence parsing states
//! - `block_map_*`: Block mapping parsing states
//! - `flow_seq_*`: Flow sequence parsing states
//! - `flow_map_*`: Flow mapping parsing states
//! - `end`: Terminal state, emits STREAM-END
//!
//! ## Events Produced
//!
//! The parser produces these events (SAX-style):
//! - `stream_start` / `stream_end`: Stream boundaries
//! - `doc_start` / `doc_end`: Document boundaries
//! - `seq_start` / `seq_end`: Sequence (list) boundaries
//! - `map_start` / `map_end`: Mapping (dict) boundaries
//! - `scalar`: Scalar value with style and optional tag/anchor
//! - `alias`: Reference to an anchored node

const std = @import("std");
const scanner = @import("scanner.zig");
const limits = @import("limits.zig");
const error_mod = @import("error.zig");

// Re-export error types from consolidated module
pub const ErrorCode = error_mod.ErrorCode;
pub const ParseError = error_mod.ParseError;
pub const ParserError = error_mod.ParserError;

pub const ScalarStyle = enum {
    plain,
    single_quoted,
    double_quoted,
    literal,
    folded,
};

pub const NodeMeta = struct {
    tag: []const u8 = "?",
    anchor: ?[]const u8 = null,
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

pub const ParseOptions = struct {
    schema: Schema = .core,
    unique_keys: bool = true,
    max_bytes: usize = 8 * 1024 * 1024,
    max_depth: u16 = 200,
    max_nodes: u32 = 1_000_000,
    max_aliases: u32 = 5000,
    max_scalar_bytes: usize = 1024 * 1024,
};

/// Schema selection for tag resolution
/// See: https://yaml.org/spec/1.2.2/#recommended-schemas
pub const Schema = enum {
    /// Failsafe schema: all values remain as strings
    failsafe,
    /// JSON schema: null, true, false, integers, floats
    json,
    /// Core schema (YAML 1.2): case-insensitive null/bool/int/float
    core,
    /// YAML 1.1 compatibility: yes/no/on/off booleans, 0-prefix octal, sexagesimal
    yaml11,
};

pub const Parser = struct {
    allocator: std.mem.Allocator,
    scan: scanner.Scanner,
    options: ParseOptions,
    limit_checker: limits.LimitChecker,

    // State
    current_token: ?scanner.Token,
    event_queue: std.ArrayList(Event),

    // Error info
    last_error: ?ParseError,

    // Parsing state stack
    state_stack: std.ArrayList(State),
    implicit_doc: bool,

    // Pending properties
    pending_anchor: ?[]const u8,
    pending_anchor_col: ?u32, // Column of the pending anchor (for two-anchor detection)
    pending_tag: ?[]const u8,

    // Peeked token (for lookahead in flow sequences)
    peeked_token: ?scanner.Token,

    /// Parser state machine states.
    ///
    /// The parser maintains a stack of states to handle nested structures.
    /// Each state determines what tokens are expected and what events to emit.
    ///
    /// State transitions:
    /// - `stream_start` → `implicit_doc_start` or `doc_start`
    /// - `doc_start/implicit_doc_start` → `doc_content`
    /// - `doc_content` → `block_node` (then `doc_end` after node)
    /// - `block_node` → collection states or scalar (then pop)
    /// - `block_seq_*` → `block_node` for each entry
    /// - `block_map_*` → `block_node_or_indentless_seq` for keys/values
    /// - `flow_*` → `flow_node` for nested content
    /// - `doc_end` → `doc_start` or `end`
    const State = enum {
        /// Initial state: expecting STREAM-START token
        stream_start,
        /// Document started implicitly (content without explicit ---)
        implicit_doc_start,
        /// Explicit document start (---) seen or expected
        doc_start,
        /// Parsing the root content of a document
        doc_content,
        /// Document ended, looking for ... or --- or stream end
        doc_end,
        /// Parsing a block-level node (could be scalar, sequence, or mapping)
        block_node,
        /// Block node that might be followed by indentless sequence entries
        block_node_or_indentless_seq,
        /// Parsing a flow-level node (inside [ ] or { })
        flow_node,
        /// First entry of a block sequence (after initial -)
        block_seq_first_entry,
        /// Subsequent entries of a block sequence
        block_seq_entry,
        /// Entry in an indentless sequence (- not indented relative to key)
        indentless_seq_entry,
        /// First key of a block mapping
        block_map_first_key,
        /// Subsequent keys in a block mapping
        block_map_key,
        /// Value in a block mapping (after the :)
        block_map_value,
        /// Empty key in a block mapping (implicit null key)
        block_map_empty_key,
        /// First entry in a flow sequence [
        flow_seq_first_entry,
        /// Subsequent entries in a flow sequence
        flow_seq_entry,
        /// Key of an implicit mapping inside a flow sequence
        flow_seq_entry_map_key,
        /// Value of an implicit mapping inside a flow sequence
        flow_seq_entry_map_value,
        /// First key in a flow mapping {
        flow_map_first_key,
        /// Subsequent keys in a flow mapping
        flow_map_key,
        /// Value in a flow mapping (after the :)
        flow_map_value,
        /// Empty value in a flow mapping (implicit null value)
        flow_map_empty_value,
        /// Terminal state: stream has ended
        end,
    };

    const Self = @This();

    pub fn init(a: std.mem.Allocator, input: []const u8, opts: ParseOptions) ParserError!Self {
        var scan = scanner.Scanner.init(a, input, opts) catch |err| {
            return mapScanError(err);
        };
        errdefer scan.deinit();

        return Self{
            .allocator = a,
            .scan = scan,
            .options = opts,
            .limit_checker = limits.LimitChecker.initFromParseOptions(opts),
            .current_token = null,
            .event_queue = .empty,
            .last_error = null,
            .state_stack = .empty,
            .implicit_doc = false,
            .pending_anchor = null,
            .pending_anchor_col = null,
            .pending_tag = null,
            .peeked_token = null,
        };
    }

    pub fn deinit(self: *Self) void {
        self.scan.deinit();
        self.event_queue.deinit(self.allocator);
        self.state_stack.deinit(self.allocator);
    }

    pub fn nextEvent(self: *Self) ParserError!Event {
        // Return queued events first
        const event = if (self.event_queue.items.len > 0)
            self.event_queue.orderedRemove(0)
        else
            try self.parseNextEvent();

        // Enforce nesting depth on the streaming path so direct consumers (not
        // just the composer) are protected against deeply nested input driving
        // unbounded native recursion / state-stack growth. Effective depth is
        // clamped to a stack-safe ceiling inside the limit checker.
        switch (event) {
            .seq_start, .map_start => self.limit_checker.pushDepth() catch {
                return self.setDepthError();
            },
            .seq_end, .map_end => self.limit_checker.popDepth(),
            else => {},
        }

        return event;
    }

    fn setDepthError(self: *Self) ParserError {
        const tok = self.current_token;
        self.last_error = ParseError{
            .code = .max_depth_exceeded,
            .line = if (tok) |t| @max(1, t.start_line) else 1,
            .col = if (tok) |t| @max(1, t.start_col) else 1,
            .offset = if (tok) |t| t.start_offset else 0,
        };
        return error.ParseFailed;
    }

    pub fn getLastError(self: *const Self) ?ParseError {
        return self.last_error;
    }

    fn parseNextEvent(self: *Self) ParserError!Event {
        if (self.current_token == null) {
            self.current_token = self.getNextToken() catch |err| {
                return self.setScanError(err);
            };
        }

        _ = self.current_token orelse {
            return Event.stream_end;
        };

        // State machine
        return switch (self.curState()) {
            .stream_start => try self.parseStreamStart(),
            .implicit_doc_start => try self.parseImplicitDocStart(),
            .doc_start => try self.parseDocStart(),
            .doc_content => try self.parseDocContent(),
            .doc_end => try self.parseDocEnd(),
            .block_node => try self.parseBlockNode(),
            .block_node_or_indentless_seq => try self.parseBlockNodeOrIndentlessSeq(),
            .flow_node => try self.parseFlowNode(),
            .block_seq_first_entry => try self.parseBlockSeqFirstEntry(),
            .block_seq_entry => try self.parseBlockSeqEntry(),
            .indentless_seq_entry => try self.parseIndentlessSeqEntry(),
            .block_map_first_key => try self.parseBlockMapFirstKey(),
            .block_map_key => try self.parseBlockMapKey(),
            .block_map_value => try self.parseBlockMapValue(),
            .block_map_empty_key => try self.parseBlockMapEmptyKey(),
            .flow_seq_first_entry => try self.parseFlowSeqFirstEntry(),
            .flow_seq_entry => try self.parseFlowSeqEntry(),
            .flow_seq_entry_map_key => try self.parseFlowSeqEntryMapKey(),
            .flow_seq_entry_map_value => try self.parseFlowSeqEntryMapValue(),
            .flow_map_first_key => try self.parseFlowMapFirstKey(),
            .flow_map_key => try self.parseFlowMapKey(),
            .flow_map_value => try self.parseFlowMapValue(),
            .flow_map_empty_value => try self.parseFlowMapEmptyValue(),
            .end => Event.stream_end,
        };
    }

    fn parseStreamStart(self: *Self) ParserError!Event {
        const token = self.current_token.?;
        if (token.type == .stream_start) {
            self.current_token = null;
            self.popState();
            try self.pushState(.implicit_doc_start);
            return Event.stream_start;
        }
        return self.setError(.unexpected_token, token);
    }

    fn parseImplicitDocStart(self: *Self) ParserError!Event {
        const token = self.current_token.?;

        // Check for explicit doc start/end or directive
        if (token.type == .directive or token.type == .doc_start or token.type == .doc_end or token.type == .stream_end) {
            self.popState();
            try self.pushState(.doc_start);
            return try self.parseNextEvent();
        }

        // Implicit document
        self.popState();
        try self.pushState(.doc_end);
        try self.pushState(.block_node);
        self.implicit_doc = true;
        return Event.doc_start;
    }

    fn parseDocStart(self: *Self) ParserError!Event {
        // Skip directives
        while (self.current_token != null and self.current_token.?.type == .directive) {
            self.current_token = null;
            self.current_token = self.getNextToken() catch |err| {
                return self.setScanError(err);
            };
        }

        const tok = self.current_token orelse return Event.stream_end;

        if (tok.type == .stream_end) {
            self.popState();
            return Event.stream_end;
        }

        if (tok.type == .doc_start) {
            self.current_token = null;
            self.popState();
            try self.pushState(.doc_end);
            try self.pushState(.doc_content);
            return Event.doc_start;
        }

        if (tok.type == .doc_end) {
            self.current_token = null;
            // Stay in doc_start state for next doc
            return try self.parseNextEvent();
        }

        // Implicit document
        self.popState();
        try self.pushState(.doc_end);
        try self.pushState(.block_node);
        self.implicit_doc = true;
        return Event.doc_start;
    }

    fn parseDocContent(self: *Self) ParserError!Event {
        self.popState();

        const token = self.current_token.?;

        if (token.type == .doc_end or token.type == .stream_end or token.type == .doc_start) {
            // Empty document
            return Event{ .scalar = .{
                .meta = .{ .tag = "?", .anchor = null },
                .style = .plain,
                .value = "",
            } };
        }

        try self.pushState(.block_node);
        return try self.parseNextEvent();
    }

    fn parseDocEnd(self: *Self) ParserError!Event {
        self.popState();
        self.implicit_doc = false;

        const token = self.current_token orelse {
            try self.pushState(.end);
            return Event.doc_end;
        };

        if (token.type == .stream_end) {
            self.current_token = null;
            try self.pushState(.end);
            return Event.doc_end;
        }

        if (token.type == .doc_end) {
            self.current_token = null;
            try self.pushState(.doc_start);
            return Event.doc_end;
        }

        try self.pushState(.doc_start);
        return Event.doc_end;
    }

    fn parseBlockNode(self: *Self) ParserError!Event {
        return try self.parseNode(true, false);
    }

    fn parseBlockNodeOrIndentlessSeq(self: *Self) ParserError!Event {
        return try self.parseNode(true, true);
    }

    fn parseFlowNode(self: *Self) ParserError!Event {
        return try self.parseNode(false, false);
    }

    fn parseNode(self: *Self, block: bool, indentless_seq: bool) ParserError!Event {
        self.popState();

        const token = self.current_token orelse {
            return Event{ .scalar = .{
                .meta = self.collectNodeMeta(),
                .style = .plain,
                .value = "",
            } };
        };

        // Handle alias
        if (token.type == .alias) {
            self.current_token = null;
            self.limit_checker.addAlias() catch {
                return self.setError(.max_aliases_exceeded, token);
            };
            return Event{ .alias = token.value };
        }

        // Handle properties (anchor, tag)
        try self.parseNodeProperties();

        const tok = self.current_token orelse {
            return Event{ .scalar = .{
                .meta = self.collectNodeMeta(),
                .style = .plain,
                .value = "",
            } };
        };

        // Handle content
        if (tok.type == .alias) {
            // An alias cannot have an anchor or tag - it just references another node
            if (self.pending_anchor != null or self.pending_tag != null) {
                return self.setError(.unexpected_token, tok);
            }
            self.current_token = null;
            self.limit_checker.addAlias() catch {
                return self.setError(.max_aliases_exceeded, tok);
            };
            return Event{ .alias = tok.value };
        }

        if (tok.type == .scalar) {
            self.current_token = null;
            return Event{ .scalar = .{
                .meta = self.collectNodeMeta(),
                .style = convertScalarStyle(tok.style),
                .value = tok.value,
            } };
        }

        if (tok.type == .flow_seq_start) {
            self.current_token = null;
            try self.pushState(.flow_seq_first_entry);
            return Event{ .seq_start = self.collectNodeMeta() };
        }

        if (tok.type == .flow_map_start) {
            self.current_token = null;
            try self.pushState(.flow_map_first_key);
            return Event{ .map_start = self.collectNodeMeta() };
        }

        if (block) {
            if (tok.type == .block_seq_start) {
                self.current_token = null;
                try self.pushState(.block_seq_first_entry);
                return Event{ .seq_start = self.collectNodeMeta() };
            }

            if (tok.type == .block_map_start) {
                self.current_token = null;
                try self.pushState(.block_map_first_key);
                return Event{ .map_start = self.collectNodeMeta() };
            }

            // Block entry starts implicit seq
            if (tok.type == .block_entry and indentless_seq) {
                try self.pushState(.indentless_seq_entry);
                return Event{ .seq_start = self.collectNodeMeta() };
            }

            // Value token alone starts implicit mapping with empty key
            if (tok.type == .value) {
                try self.pushState(.block_map_empty_key);
                return Event{ .map_start = self.collectNodeMeta() };
            }
        }

        // Empty scalar
        return Event{ .scalar = .{
            .meta = self.collectNodeMeta(),
            .style = .plain,
            .value = "",
        } };
    }

    fn parseNodeProperties(self: *Self) ParserError!void {
        self.pending_anchor = null;
        self.pending_anchor_col = null;
        self.pending_tag = null;

        while (self.current_token) |token| {
            if (token.type == .anchor) {
                // If we already have an anchor, check if this is "two anchors on same node"
                if (self.pending_anchor != null) {
                    // If second anchor is on a DIFFERENT line AND at a lower column than first,
                    // it's likely value continuation = two anchors on same node
                    // e.g., "key: &a" on line 1 then "&b value" on line 2
                    if (self.pending_anchor_col) |first_col| {
                        // Second anchor at lower column than first means it's continuation of value
                        // (first anchor was after ':' on same line as key)
                        if (token.start_col < first_col) {
                            return error.ParseFailed;
                        }
                    }
                    // Second anchor at same/higher column - it's for nested content
                    break;
                }
                self.pending_anchor = token.value;
                self.pending_anchor_col = token.start_col;
                self.current_token = null;
                self.current_token = self.getNextToken() catch |err| {
                    return self.setScanError(err);
                };
            } else if (token.type == .tag) {
                // Resolve tag
                if (token.tag_handle.len == 0) {
                    // Verbatim tag
                    self.pending_tag = token.tag_suffix;
                } else {
                    self.pending_tag = self.scan.resolveTag(token.tag_handle, token.tag_suffix) catch |err| {
                        return self.setScanError(err);
                    };
                }
                self.current_token = null;
                self.current_token = self.getNextToken() catch |err| {
                    return self.setScanError(err);
                };
            } else {
                break;
            }
        }
    }

    fn collectNodeMeta(self: *Self) NodeMeta {
        const meta = NodeMeta{
            // Use "?" for implicit/unresolved tags, "!" only for explicit non-specific
            .tag = self.pending_tag orelse "?",
            .anchor = self.pending_anchor,
        };
        self.pending_anchor = null;
        self.pending_anchor_col = null;
        self.pending_tag = null;
        return meta;
    }

    fn parseBlockSeqFirstEntry(self: *Self) ParserError!Event {
        return try self.parseBlockSeqEntry();
    }

    fn parseBlockSeqEntry(self: *Self) ParserError!Event {
        // Fetch next token if needed
        if (self.current_token == null) {
            self.current_token = self.getNextToken() catch |err| {
                return self.setScanError(err);
            };
        }

        const token = self.current_token orelse {
            self.popState();
            return Event.seq_end;
        };

        if (token.type == .block_entry) {
            self.current_token = null;
            self.current_token = self.getNextToken() catch |err| {
                return self.setScanError(err);
            };

            const next = self.current_token;
            if (next == null or next.?.type == .block_entry or next.?.type == .block_end) {
                // Empty entry - stay in block_seq_entry state for next iteration
                return Event{ .scalar = .{
                    .meta = .{ .tag = "?", .anchor = null },
                    .style = .plain,
                    .value = "",
                } };
            }

            // Push block_node to parse the entry content
            // Don't push another block_seq_entry - current state handles iteration
            try self.pushState(.block_node);
            return try self.parseNextEvent();
        }

        if (token.type == .block_end) {
            self.current_token = null;
            self.popState();
            return Event.seq_end;
        }

        // End of block
        self.popState();
        return Event.seq_end;
    }

    fn parseIndentlessSeqEntry(self: *Self) ParserError!Event {
        // Fetch next token if needed
        if (self.current_token == null) {
            self.current_token = self.getNextToken() catch |err| {
                return self.setScanError(err);
            };
        }

        const token = self.current_token orelse {
            self.popState();
            return Event.seq_end;
        };

        if (token.type == .block_entry) {
            self.current_token = null;
            self.current_token = self.getNextToken() catch |err| {
                return self.setScanError(err);
            };

            const next = self.current_token;
            if (next == null or next.?.type == .block_entry or next.?.type == .key or next.?.type == .value) {
                // Empty entry
                return Event{ .scalar = .{
                    .meta = .{ .tag = "?", .anchor = null },
                    .style = .plain,
                    .value = "",
                } };
            }

            // Don't push another indentless_seq_entry - current state handles iteration
            try self.pushState(.block_node);
            return try self.parseNextEvent();
        }

        self.popState();
        return Event.seq_end;
    }

    fn parseBlockMapFirstKey(self: *Self) ParserError!Event {
        return try self.parseBlockMapKey();
    }

    fn parseBlockMapKey(self: *Self) ParserError!Event {
        // Fetch next token if needed
        if (self.current_token == null) {
            self.current_token = self.getNextToken() catch |err| {
                return self.setScanError(err);
            };
        }

        const token = self.current_token orelse {
            self.popState();
            return Event.map_end;
        };

        if (token.type == .key) {
            self.current_token = null;
            self.current_token = self.getNextToken() catch |err| {
                return self.setScanError(err);
            };

            const next = self.current_token;
            if (next == null or next.?.type == .key or next.?.type == .value or next.?.type == .block_end) {
                // Empty key - replace current state with block_map_value
                self.popState();
                try self.pushState(.block_map_value);
                return Event{ .scalar = .{
                    .meta = .{ .tag = "?", .anchor = null },
                    .style = .plain,
                    .value = "",
                } };
            }

            // Replace current state with block_map_value
            self.popState();
            try self.pushState(.block_map_value);
            try self.pushState(.block_node_or_indentless_seq);
            return try self.parseNextEvent();
        }

        // Implicit key from scalar/anchor/tag/alias - replace current state with block_map_value
        if (token.type == .scalar or token.type == .flow_seq_start or token.type == .flow_map_start or
            token.type == .anchor or token.type == .tag or token.type == .alias)
        {
            self.popState();
            try self.pushState(.block_map_value);
            try self.pushState(.block_node_or_indentless_seq);
            return try self.parseNextEvent();
        }

        // Value token without key means empty key
        if (token.type == .value) {
            // Emit empty key, transition to block_map_value
            self.popState();
            try self.pushState(.block_map_value);
            return Event{ .scalar = .{
                .meta = .{ .tag = "?", .anchor = null },
                .style = .plain,
                .value = "",
            } };
        }

        if (token.type == .block_end) {
            self.current_token = null;
            self.popState();
            return Event.map_end;
        }

        // End of block
        self.popState();
        return Event.map_end;
    }

    fn parseBlockMapValue(self: *Self) ParserError!Event {
        // Fetch next token if needed
        if (self.current_token == null) {
            self.current_token = self.getNextToken() catch |err| {
                return self.setScanError(err);
            };
        }

        const token = self.current_token orelse {
            self.popState();
            try self.pushState(.block_map_key);
            return Event{ .scalar = .{
                .meta = .{ .tag = "?", .anchor = null },
                .style = .plain,
                .value = "",
            } };
        };

        if (token.type == .value) {
            self.current_token = null;
            self.current_token = self.getNextToken() catch |err| {
                return self.setScanError(err);
            };

            const next = self.current_token;
            if (next == null or next.?.type == .key or next.?.type == .value or next.?.type == .block_end) {
                // Empty value
                self.popState();
                try self.pushState(.block_map_key);
                return Event{ .scalar = .{
                    .meta = .{ .tag = "?", .anchor = null },
                    .style = .plain,
                    .value = "",
                } };
            }

            self.popState();
            try self.pushState(.block_map_key);
            try self.pushState(.block_node_or_indentless_seq);
            return try self.parseNextEvent();
        }

        // Missing value
        self.popState();
        try self.pushState(.block_map_key);
        return Event{ .scalar = .{
            .meta = .{ .tag = "?", .anchor = null },
            .style = .plain,
            .value = "",
        } };
    }

    fn parseBlockMapEmptyKey(self: *Self) ParserError!Event {
        // Emit empty key, then transition to block_map_value
        self.popState();
        try self.pushState(.block_map_value);
        return Event{ .scalar = .{
            .meta = .{ .tag = "?", .anchor = null },
            .style = .plain,
            .value = "",
        } };
    }

    fn parseFlowSeqFirstEntry(self: *Self) ParserError!Event {
        return try self.parseFlowSeqEntryImpl(true);
    }

    fn parseFlowSeqEntry(self: *Self) ParserError!Event {
        return try self.parseFlowSeqEntryImpl(false);
    }

    fn parseFlowSeqEntryImpl(self: *Self, first_entry: bool) ParserError!Event {
        // Fetch next token if needed
        if (self.current_token == null) {
            self.current_token = self.getNextToken() catch |err| {
                return self.setScanError(err);
            };
        }

        const token = self.current_token orelse {
            self.popState();
            return Event.seq_end;
        };

        if (token.type == .flow_seq_end) {
            self.current_token = null;
            self.popState();
            return Event.seq_end;
        }

        // Block indicators are not allowed in flow context
        if (token.type == .block_seq_start or token.type == .block_map_start) {
            return self.setError(.unexpected_token, token);
        }

        if (token.type == .flow_entry) {
            // Comma at start of sequence is invalid: [ , a ]
            if (first_entry) {
                return self.setError(.unexpected_token, token);
            }
            self.current_token = null;
            self.current_token = self.getNextToken() catch |err| {
                return self.setScanError(err);
            };

            // Check for double comma: [ a, , b ]
            if (self.current_token) |next| {
                if (next.type == .flow_entry) {
                    return self.setError(.unexpected_token, next);
                }
            }
        } else if (!first_entry) {
            // After first entry, we must have a comma before next entry
            // (unless it's the end of the sequence, which is handled above)
            // Value token is allowed for implicit mappings
            if (token.type != .value and token.type != .key) {
                return self.setError(.unexpected_token, token);
            }
        }

        const tok = self.current_token orelse {
            self.popState();
            return Event.seq_end;
        };

        if (tok.type == .flow_seq_end) {
            self.current_token = null;
            self.popState();
            return Event.seq_end;
        }

        // Check for explicit key '?'
        if (tok.type == .key) {
            self.current_token = null;
            self.popState();
            try self.pushState(.flow_seq_entry);
            try self.pushState(.flow_seq_entry_map_key);
            return Event{ .map_start = .{ .tag = "?", .anchor = null } };
        }

        // Check for implicit mapping (value token ':' means empty key)
        if (tok.type == .value) {
            // Don't consume the value token - let flow_seq_entry_map_key see it
            self.popState();
            try self.pushState(.flow_seq_entry);
            try self.pushState(.flow_seq_entry_map_key);
            return Event{ .map_start = .{ .tag = "?", .anchor = null } };
        }

        // Check if scalar/quoted is followed by ':' (implicit mapping with key)
        if (tok.type == .scalar or tok.type == .anchor or tok.type == .tag) {
            // Peek ahead to see if this is an implicit mapping key
            // We need to save current token, get next, check, and restore
            const saved_token = self.current_token;
            self.current_token = null;
            // Ensure state is restored on error
            errdefer self.current_token = saved_token;

            // Skip anchor/tag if present to find the scalar
            const peek_token = saved_token;
            if (peek_token != null and (peek_token.?.type == .anchor or peek_token.?.type == .tag)) {
                // For anchors/tags, we'd need more complex lookahead - just process normally for now
                self.current_token = saved_token;
            } else if (peek_token != null and peek_token.?.type == .scalar) {
                // Get the token after the scalar
                const next_tok = self.getNextToken() catch |err| {
                    return self.setScanError(err);
                };
                if (next_tok != null and next_tok.?.type == .value) {
                    // This is an implicit mapping! scalar:value pattern
                    // Restore current_token to the scalar for processing by map_key state
                    // And save the value token for later
                    self.current_token = saved_token;
                    self.peeked_token = next_tok;
                    self.popState();
                    try self.pushState(.flow_seq_entry);
                    try self.pushState(.flow_seq_entry_map_key);
                    return Event{ .map_start = .{ .tag = "?", .anchor = null } };
                }
                // Not a mapping - restore and continue normally
                // Save the peeked token to be processed later
                self.peeked_token = next_tok;
                self.current_token = saved_token;
            } else {
                self.current_token = saved_token;
            }
        }

        // Replace current state with flow_seq_entry for next iteration
        self.popState();
        try self.pushState(.flow_seq_entry);
        try self.pushState(.flow_node);
        return try self.parseNextEvent();
    }

    fn parseFlowSeqEntryMapKey(self: *Self) ParserError!Event {
        // Fetch next token if needed
        if (self.current_token == null) {
            self.current_token = self.getNextToken() catch |err| {
                return self.setScanError(err);
            };
        }

        const token = self.current_token orelse {
            self.popState();
            return Event.map_end;
        };

        if (token.type == .value or token.type == .flow_entry or token.type == .flow_seq_end) {
            // Empty key - replace state with map_value
            self.popState();
            try self.pushState(.flow_seq_entry_map_value);
            return Event{ .scalar = .{
                .meta = .{ .tag = "?", .anchor = null },
                .style = .plain,
                .value = "",
            } };
        }

        // Replace state with map_value, then parse key as flow_node
        self.popState();
        try self.pushState(.flow_seq_entry_map_value);
        try self.pushState(.flow_node);
        return try self.parseNextEvent();
    }

    fn parseFlowSeqEntryMapValue(self: *Self) ParserError!Event {
        // Fetch next token if needed
        if (self.current_token == null) {
            self.current_token = self.getNextToken() catch |err| {
                return self.setScanError(err);
            };
        }

        const token = self.current_token orelse {
            self.popState();
            return Event.map_end;
        };

        if (token.type == .value) {
            self.current_token = null;
            self.current_token = self.getNextToken() catch |err| {
                return self.setScanError(err);
            };

            const next = self.current_token;
            if (next == null or next.?.type == .flow_entry or next.?.type == .flow_seq_end) {
                // Empty value
                self.popState();
                return Event{ .scalar = .{
                    .meta = .{ .tag = "?", .anchor = null },
                    .style = .plain,
                    .value = "",
                } };
            }

            // Parse the value as a flow node
            // After flow_node returns, we'll come back here... no wait, we popped!
            // So we need to queue the map_end for after the value
            self.popState();
            try self.pushState(.flow_node);
            try self.event_queue.append(self.allocator, Event.map_end);
            return try self.parseNextEvent();
        }

        // No value token - missing value, emit map_end
        self.popState();
        return Event.map_end;
    }

    fn parseFlowMapFirstKey(self: *Self) ParserError!Event {
        return try self.parseFlowMapKeyImpl(true);
    }

    fn parseFlowMapKey(self: *Self) ParserError!Event {
        return try self.parseFlowMapKeyImpl(false);
    }

    fn parseFlowMapKeyImpl(self: *Self, first_entry: bool) ParserError!Event {
        const token = self.current_token orelse {
            self.popState();
            return Event.map_end;
        };

        if (token.type == .flow_map_end) {
            self.current_token = null;
            self.popState();
            return Event.map_end;
        }

        if (token.type == .flow_entry) {
            // Comma at start of mapping is invalid: { , k: v }
            if (first_entry) {
                return self.setError(.unexpected_token, token);
            }
            self.current_token = null;
            self.current_token = self.getNextToken() catch |err| {
                return self.setScanError(err);
            };

            // Check for double comma: { k: v, , k: v }
            if (self.current_token) |next| {
                if (next.type == .flow_entry) {
                    return self.setError(.unexpected_token, next);
                }
            }
        } else if (!first_entry) {
            // After first entry, we must have a comma before next entry
            // (unless it's the end of the mapping, which is handled above)
            return self.setError(.unexpected_token, token);
        }

        const tok = self.current_token orelse {
            self.popState();
            return Event.map_end;
        };

        if (tok.type == .flow_map_end) {
            self.current_token = null;
            self.popState();
            return Event.map_end;
        }

        if (tok.type == .key) {
            self.current_token = null;
            self.current_token = self.getNextToken() catch |err| {
                return self.setScanError(err);
            };

            const next = self.current_token;
            if (next == null or next.?.type == .value or next.?.type == .flow_entry or next.?.type == .flow_map_end) {
                // Empty key - replace current state
                self.popState();
                try self.pushState(.flow_map_value);
                return Event{ .scalar = .{
                    .meta = .{ .tag = "?", .anchor = null },
                    .style = .plain,
                    .value = "",
                } };
            }
        }

        // Replace current state with flow_map_value for next iteration
        self.popState();
        try self.pushState(.flow_map_value);
        try self.pushState(.flow_node);
        return try self.parseNextEvent();
    }

    fn parseFlowMapValue(self: *Self) ParserError!Event {
        const token = self.current_token orelse {
            self.popState();
            try self.pushState(.flow_map_key);
            return Event{ .scalar = .{
                .meta = .{ .tag = "?", .anchor = null },
                .style = .plain,
                .value = "",
            } };
        };

        if (token.type == .value) {
            self.current_token = null;
            self.current_token = self.getNextToken() catch |err| {
                return self.setScanError(err);
            };

            const next = self.current_token;
            if (next == null or next.?.type == .flow_entry or next.?.type == .flow_map_end) {
                self.popState();
                try self.pushState(.flow_map_key);
                return Event{ .scalar = .{
                    .meta = .{ .tag = "?", .anchor = null },
                    .style = .plain,
                    .value = "",
                } };
            }

            self.popState();
            try self.pushState(.flow_map_key);
            try self.pushState(.flow_node);
            return try self.parseNextEvent();
        }

        // Missing value - implicit null
        self.popState();
        try self.pushState(.flow_map_key);
        return Event{ .scalar = .{
            .meta = .{ .tag = "?", .anchor = null },
            .style = .plain,
            .value = "",
        } };
    }

    fn parseFlowMapEmptyValue(self: *Self) ParserError!Event {
        self.popState();
        try self.pushState(.flow_map_key);
        return Event{ .scalar = .{
            .meta = .{ .tag = "?", .anchor = null },
            .style = .plain,
            .value = "",
        } };
    }

    fn pushState(self: *Self, state: State) ParserError!void {
        self.state_stack.append(self.allocator, state) catch return error.OutOfMemory;
    }

    fn popState(self: *Self) void {
        if (self.state_stack.items.len > 0) {
            _ = self.state_stack.pop();
        }
    }

    /// Returns the current state, defaulting to stream_start if stack is empty.
    /// This provides safe access to the state stack without risk of null pointer.
    fn curState(self: *const Self) State {
        return if (self.state_stack.items.len > 0)
            self.state_stack.items[self.state_stack.items.len - 1]
        else
            .stream_start;
    }

    fn getNextToken(self: *Self) !?scanner.Token {
        // Return peeked token if available
        if (self.peeked_token) |token| {
            self.peeked_token = null;
            return token;
        }
        return try self.scan.nextToken();
    }

    fn setError(self: *Self, code: ErrorCode, token: scanner.Token) ParserError {
        self.last_error = ParseError{
            .code = code,
            .line = token.start_line,
            .col = token.start_col,
            .offset = token.start_offset,
        };
        return error.ParseFailed;
    }

    /// Set error from scanner error, using scanner's error position tracking
    fn setScanError(self: *Self, err: anyerror) ParserError {
        if (err == error.OutOfMemory) return error.OutOfMemory;

        // Get error info from scanner
        const err_info = self.scan.getErrorInfo();

        // Convert scanner error to error code
        const code: ErrorCode = switch (err) {
            error.UnexpectedCharacter => .unexpected_token,
            error.InvalidEscapeSequence => .invalid_escape,
            error.UnterminatedString => .unterminated_string,
            error.InvalidAnchorName => .invalid_anchor_name,
            error.InvalidTagHandle => .invalid_tag,
            error.InvalidDirective => .invalid_directive,
            error.UnsupportedYamlVersion => .unsupported_yaml_version,
            error.TabInIndentation => .tab_in_indentation,
            error.InvalidBlockScalarHeader => .invalid_block_scalar,
            error.InvalidUtf8 => .invalid_utf8,
            error.InputTooLarge => .input_too_large,
            error.ScalarTooLarge => .scalar_too_large,
            error.MaxDepthExceeded => .max_depth_exceeded,
            error.MaxNodesExceeded => .max_nodes_exceeded,
            error.MaxAliasesExceeded => .max_aliases_exceeded,
            else => .internal_error,
        };

        self.last_error = ParseError{
            .code = code,
            .line = err_info.line,
            .col = err_info.col,
            .offset = err_info.offset,
            .context = err_info.context,
        };

        return error.ParseFailed;
    }

    fn mapScanError(err: anyerror) ParserError {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return error.ParseFailed;
    }
};

fn convertScalarStyle(style: scanner.ScalarStyle) ScalarStyle {
    return switch (style) {
        .plain => .plain,
        .single_quoted => .single_quoted,
        .double_quoted => .double_quoted,
        .literal => .literal,
        .folded => .folded,
    };
}
