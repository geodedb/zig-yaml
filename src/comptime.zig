// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Comptime YAML Parser
//! Parses YAML at compile time for embedding configuration.
//!
//! Supports a subset of YAML features suitable for configuration:
//! - Simple key-value mappings
//! - Sequences (lists)
//! - String values
//! - Null, boolean, and integer values
//!
//! Not supported at comptime (use runtime parser for these):
//! - Anchors and aliases
//! - Tags
//! - Complex multi-line scalars
//! - Flow collections

const std = @import("std");

/// Comptime YAML value representation
pub const Value = union(enum) {
    null,
    bool: bool,
    int: i64,
    str: []const u8,
    seq: []const Value,
    map: []const KVPair,

    pub const KVPair = struct {
        key: []const u8,
        value: Value,
    };

    /// Get string value or null if not a string
    pub fn asString(self: Value) ?[]const u8 {
        return switch (self) {
            .str => |s| s,
            else => null,
        };
    }

    /// Get integer value or null if not an integer
    pub fn asInt(self: Value) ?i64 {
        return switch (self) {
            .int => |i| i,
            else => null,
        };
    }

    /// Get boolean value or null if not a boolean
    pub fn asBool(self: Value) ?bool {
        return switch (self) {
            .bool => |b| b,
            else => null,
        };
    }

    /// Get sequence or null if not a sequence
    pub fn asSeq(self: Value) ?[]const Value {
        return switch (self) {
            .seq => |s| s,
            else => null,
        };
    }

    /// Get map or null if not a map
    pub fn asMap(self: Value) ?[]const KVPair {
        return switch (self) {
            .map => |m| m,
            else => null,
        };
    }

    /// Get value at key in map
    pub fn get(self: Value, key: []const u8) ?Value {
        const m = self.asMap() orelse return null;
        for (m) |kv| {
            if (std.mem.eql(u8, kv.key, key)) {
                return kv.value;
            }
        }
        return null;
    }
};

/// Parse YAML string at compile time.
/// Returns the root value of the first document.
pub fn parse(comptime input: []const u8) Value {
    comptime {
        var parser = Parser.init(input);
        return parser.parseDocument();
    }
}

/// Parse YAML and return a specific field from the root map
pub fn parseField(comptime input: []const u8, comptime field: []const u8) ?Value {
    const root = parse(input);
    return root.get(field);
}

const Parser = struct {
    input: []const u8,
    pos: usize,
    line: usize,
    col: usize,
    indent_stack: [64]usize,
    indent_depth: usize,

    fn init(input: []const u8) Parser {
        return .{
            .input = input,
            .pos = 0,
            .line = 1,
            .col = 1,
            .indent_stack = [_]usize{0} ** 64,
            .indent_depth = 0,
        };
    }

    fn parseDocument(self: *Parser) Value {
        self.skipWhitespaceAndComments();

        // Skip document start marker if present
        if (self.startsWith("---")) {
            self.advance(3);
            self.skipToNextLine();
        }

        return self.parseValue(0);
    }

    fn parseValue(self: *Parser, _: usize) Value {
        self.skipWhitespaceAndComments();

        if (self.isAtEnd()) {
            return .null;
        }

        const indent = self.currentIndent();

        // Check for sequence item
        if (self.peek() == '-' and self.peekAt(1) == ' ') {
            return self.parseSequence(indent);
        }

        // Check for mapping key
        if (self.isAlphanumeric(self.peek()) or self.peek() == '"' or self.peek() == '\'') {
            // Look ahead for colon
            var look = self.pos;
            while (look < self.input.len and self.input[look] != ':' and self.input[look] != '\n') {
                look += 1;
            }
            if (look < self.input.len and self.input[look] == ':') {
                return self.parseMapping(indent);
            }
        }

        // Parse as scalar
        return self.parseScalar();
    }

    fn parseSequence(self: *Parser, seq_indent: usize) Value {
        var items: [256]Value = undefined;
        var count: usize = 0;

        while (!self.isAtEnd()) {
            self.skipWhitespaceAndComments();

            const indent = self.currentIndent();
            if (indent < seq_indent) break;
            if (indent != seq_indent) break;

            if (self.peek() != '-') break;
            self.advance(1); // Skip -

            // Skip space after -
            if (self.peek() == ' ') {
                self.advance(1);
            }

            const item_indent = if (self.peek() == '\n') seq_indent + 2 else self.col;
            self.skipSpaces();

            if (self.peek() == '\n') {
                self.skipToNextLine();
                items[count] = self.parseValue(item_indent);
            } else {
                items[count] = self.parseValue(item_indent);
            }

            count += 1;
            self.skipToNextLine();
        }

        const result = items[0..count].*;
        return .{ .seq = &result };
    }

    fn parseMapping(self: *Parser, map_indent: usize) Value {
        var items: [128]Value.KVPair = undefined;
        var count: usize = 0;

        while (!self.isAtEnd()) {
            self.skipWhitespaceAndComments();

            const indent = self.currentIndent();
            if (indent < map_indent) break;
            if (indent != map_indent) break;

            // Parse key
            const key = self.parseKey();
            if (key.len == 0) break;

            // Expect colon
            if (self.peek() != ':') break;
            self.advance(1);

            // Skip space after colon
            self.skipSpaces();

            // Parse value
            var value: Value = undefined;
            if (self.peek() == '\n' or self.isAtEnd()) {
                // Value on next line (nested structure)
                self.skipToNextLine();
                const value_indent = map_indent + 2;
                value = self.parseValue(value_indent);
            } else {
                // Value on same line
                value = self.parseInlineValue();
                self.skipToNextLine();
            }

            items[count] = .{ .key = key, .value = value };
            count += 1;
        }

        const result = items[0..count].*;
        return .{ .map = &result };
    }

    fn parseKey(self: *Parser) []const u8 {
        const start = self.pos;

        // Quoted key
        if (self.peek() == '"' or self.peek() == '\'') {
            return self.parseQuotedString();
        }

        // Plain key
        while (!self.isAtEnd() and self.peek() != ':' and self.peek() != '\n') {
            self.advance(1);
        }

        return std.mem.trim(u8, self.input[start..self.pos], " \t");
    }

    fn parseInlineValue(self: *Parser) Value {
        self.skipSpaces();

        // Flow sequence
        if (self.peek() == '[') {
            return self.parseFlowSequence();
        }

        // Flow mapping
        if (self.peek() == '{') {
            return self.parseFlowMapping();
        }

        return self.parseScalar();
    }

    fn parseScalar(self: *Parser) Value {
        // Quoted string
        if (self.peek() == '"' or self.peek() == '\'') {
            return .{ .str = self.parseQuotedString() };
        }

        const start = self.pos;
        while (!self.isAtEnd() and self.peek() != '\n' and self.peek() != '#') {
            self.advance(1);
        }

        const raw = std.mem.trim(u8, self.input[start..self.pos], " \t");

        // Try to parse as special values
        if (raw.len == 0 or std.mem.eql(u8, raw, "null") or std.mem.eql(u8, raw, "~")) {
            return .null;
        }

        if (std.mem.eql(u8, raw, "true") or std.mem.eql(u8, raw, "True") or std.mem.eql(u8, raw, "TRUE")) {
            return .{ .bool = true };
        }

        if (std.mem.eql(u8, raw, "false") or std.mem.eql(u8, raw, "False") or std.mem.eql(u8, raw, "FALSE")) {
            return .{ .bool = false };
        }

        // Try integer
        if (std.fmt.parseInt(i64, raw, 10)) |i| {
            return .{ .int = i };
        } else |_| {}

        return .{ .str = raw };
    }

    fn parseQuotedString(self: *Parser) []const u8 {
        const quote = self.peek();
        self.advance(1);

        const start = self.pos;
        while (!self.isAtEnd() and self.peek() != quote) {
            if (self.peek() == '\\') {
                self.advance(1); // Skip escape
            }
            self.advance(1);
        }

        const result = self.input[start..self.pos];
        if (!self.isAtEnd()) {
            self.advance(1); // Skip closing quote
        }

        return result;
    }

    fn parseFlowSequence(self: *Parser) Value {
        self.advance(1); // Skip [

        var items: [64]Value = undefined;
        var count: usize = 0;

        while (!self.isAtEnd() and self.peek() != ']') {
            self.skipSpaces();

            if (self.peek() == ',') {
                self.advance(1);
                continue;
            }

            if (self.peek() == ']') break;

            items[count] = self.parseFlowValue();
            count += 1;

            self.skipSpaces();
            if (self.peek() == ',') {
                self.advance(1);
            }
        }

        if (!self.isAtEnd()) {
            self.advance(1); // Skip ]
        }

        const result = items[0..count].*;
        return .{ .seq = &result };
    }

    fn parseFlowMapping(self: *Parser) Value {
        self.advance(1); // Skip {

        var items: [64]Value.KVPair = undefined;
        var count: usize = 0;

        while (!self.isAtEnd() and self.peek() != '}') {
            self.skipSpaces();

            if (self.peek() == ',') {
                self.advance(1);
                continue;
            }

            if (self.peek() == '}') break;

            const key = self.parseKey();
            if (self.peek() == ':') {
                self.advance(1);
            }
            self.skipSpaces();

            const value = self.parseFlowValue();

            items[count] = .{ .key = key, .value = value };
            count += 1;

            self.skipSpaces();
            if (self.peek() == ',') {
                self.advance(1);
            }
        }

        if (!self.isAtEnd()) {
            self.advance(1); // Skip }
        }

        const result = items[0..count].*;
        return .{ .map = &result };
    }

    fn parseFlowValue(self: *Parser) Value {
        self.skipSpaces();

        if (self.peek() == '[') {
            return self.parseFlowSequence();
        }

        if (self.peek() == '{') {
            return self.parseFlowMapping();
        }

        // Parse until , or ] or }
        const start = self.pos;
        while (!self.isAtEnd()) {
            const c = self.peek();
            if (c == ',' or c == ']' or c == '}' or c == '\n') break;
            self.advance(1);
        }

        const raw = std.mem.trim(u8, self.input[start..self.pos], " \t");

        // Try special values
        if (raw.len == 0 or std.mem.eql(u8, raw, "null")) {
            return .null;
        }
        if (std.mem.eql(u8, raw, "true")) {
            return .{ .bool = true };
        }
        if (std.mem.eql(u8, raw, "false")) {
            return .{ .bool = false };
        }
        if (std.fmt.parseInt(i64, raw, 10)) |i| {
            return .{ .int = i };
        } else |_| {}

        return .{ .str = raw };
    }

    // Helper functions
    fn peek(self: *Parser) u8 {
        if (self.pos >= self.input.len) return 0;
        return self.input[self.pos];
    }

    fn peekAt(self: *Parser, offset: usize) u8 {
        const idx = self.pos + offset;
        if (idx >= self.input.len) return 0;
        return self.input[idx];
    }

    fn advance(self: *Parser, count: usize) void {
        var i: usize = 0;
        while (i < count and self.pos < self.input.len) : (i += 1) {
            if (self.input[self.pos] == '\n') {
                self.line += 1;
                self.col = 1;
            } else {
                self.col += 1;
            }
            self.pos += 1;
        }
    }

    fn isAtEnd(self: *Parser) bool {
        return self.pos >= self.input.len;
    }

    fn startsWith(self: *Parser, prefix: []const u8) bool {
        if (self.pos + prefix.len > self.input.len) return false;
        return std.mem.eql(u8, self.input[self.pos..][0..prefix.len], prefix);
    }

    fn skipSpaces(self: *Parser) void {
        while (!self.isAtEnd() and (self.peek() == ' ' or self.peek() == '\t')) {
            self.advance(1);
        }
    }

    fn skipToNextLine(self: *Parser) void {
        while (!self.isAtEnd() and self.peek() != '\n') {
            self.advance(1);
        }
        if (!self.isAtEnd()) {
            self.advance(1); // Skip newline
        }
    }

    fn skipWhitespaceAndComments(self: *Parser) void {
        while (!self.isAtEnd()) {
            if (self.peek() == ' ' or self.peek() == '\t' or self.peek() == '\n' or self.peek() == '\r') {
                self.advance(1);
            } else if (self.peek() == '#') {
                self.skipToNextLine();
            } else {
                break;
            }
        }
    }

    fn currentIndent(self: *Parser) usize {
        // Find start of current line
        var line_start = self.pos;
        while (line_start > 0 and self.input[line_start - 1] != '\n') {
            line_start -= 1;
        }

        // Count leading spaces
        var indent: usize = 0;
        var i = line_start;
        while (i < self.input.len and self.input[i] == ' ') {
            indent += 1;
            i += 1;
        }

        return indent;
    }

    fn isAlphanumeric(self: *Parser, c: u8) bool {
        _ = self;
        return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_' or c == '-';
    }
};
