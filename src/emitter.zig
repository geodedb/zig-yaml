// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! YAML 1.2.2 Canonical Emitter
//! Emits YAML in canonical form: LF, 2-space indent, block style, deterministic escaping.

const std = @import("std");
const resolver = @import("resolver.zig");

/// Collection formatting style
pub const CollectionStyle = enum {
    /// Always use block style (default, most readable)
    block,
    /// Use flow style for simple leaf collections
    flow_simple,
    /// Always use flow style (compact)
    flow,
};

/// String quoting style
pub const QuoteStyle = enum {
    /// Quote only when necessary (default)
    minimal,
    /// Always use single quotes
    single,
    /// Always use double quotes
    double,
};

/// Emitter options for customizing YAML output
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

pub const EmitError = error{
    OutOfMemory,
};

pub fn dumpAll(allocator: std.mem.Allocator, docs: []const resolver.Value, opts: EmitOptions) EmitError![]u8 {
    var emitter = Emitter.init(allocator, opts);
    defer emitter.deinit();

    for (docs) |doc| {
        try emitter.emitDocument(doc);
    }

    return emitter.toOwnedSlice();
}

const Emitter = struct {
    allocator: std.mem.Allocator,
    buffer: std.ArrayList(u8),
    opts: EmitOptions,

    fn init(allocator: std.mem.Allocator, opts: EmitOptions) Emitter {
        return .{
            .allocator = allocator,
            .buffer = .empty,
            .opts = opts,
        };
    }

    fn deinit(self: *Emitter) void {
        self.buffer.deinit(self.allocator);
    }

    fn toOwnedSlice(self: *Emitter) EmitError![]u8 {
        return self.buffer.toOwnedSlice(self.allocator) catch return error.OutOfMemory;
    }

    fn emitDocument(self: *Emitter, value: resolver.Value) EmitError!void {
        // Emit document start marker if enabled
        if (self.opts.doc_start) {
            try self.write("---\n");
        }

        try self.emitValue(value, 0, false);

        // Ensure final newline if needed
        if (self.buffer.items.len > 0 and self.buffer.items[self.buffer.items.len - 1] != '\n') {
            try self.write("\n");
        }

        // Emit document end marker if enabled
        if (self.opts.doc_end) {
            try self.write("...\n");
        }
    }

    fn emitValue(self: *Emitter, value: resolver.Value, indent: usize, inline_first: bool) EmitError!void {
        switch (value) {
            .null => try self.write("null"),
            .bool => |b| try self.write(if (b) "true" else "false"),
            .int => |i| {
                var buf: [32]u8 = undefined;
                const str = std.fmt.bufPrint(&buf, "{d}", .{i}) catch unreachable;
                try self.write(str);
            },
            .big_int => |s| try self.write(s),
            .float => |f| {
                var buf: [64]u8 = undefined;
                const str = std.fmt.bufPrint(&buf, "{d}", .{f}) catch unreachable;
                try self.write(str);
            },
            .inf_pos => try self.write(".inf"),
            .inf_neg => try self.write("-.inf"),
            .nan => try self.write(".nan"),
            .str => |s| try self.emitString(s),
            .seq => |items| try self.emitSeq(items, indent, inline_first),
            .map => |items| try self.emitMap(items, indent, inline_first),
        }
    }

    fn emitString(self: *Emitter, s: []const u8) EmitError!void {
        switch (self.opts.quote_style) {
            .minimal => {
                if (needsQuoting(s)) {
                    try self.emitDoubleQuoted(s);
                } else {
                    try self.write(s);
                }
            },
            .single => try self.emitSingleQuoted(s),
            .double => try self.emitDoubleQuoted(s),
        }
    }

    fn emitSingleQuoted(self: *Emitter, s: []const u8) EmitError!void {
        try self.write("'");
        for (s) |c| {
            if (c == '\'') {
                // Single quotes are escaped by doubling in YAML
                try self.write("''");
            } else {
                self.buffer.append(self.allocator, c) catch return error.OutOfMemory;
            }
        }
        try self.write("'");
    }

    fn emitDoubleQuoted(self: *Emitter, s: []const u8) EmitError!void {
        try self.write("\"");
        for (s) |c| {
            switch (c) {
                '"' => try self.write("\\\""),
                '\\' => try self.write("\\\\"),
                '\n' => try self.write("\\n"),
                '\r' => try self.write("\\r"),
                '\t' => try self.write("\\t"),
                0x00...0x08, 0x0B, 0x0C, 0x0E...0x1F, 0x7F => {
                    var buf: [4]u8 = undefined;
                    const hex = std.fmt.bufPrint(&buf, "\\x{X:0>2}", .{c}) catch unreachable;
                    try self.write(hex);
                },
                else => {
                    self.buffer.append(self.allocator, c) catch return error.OutOfMemory;
                },
            }
        }
        try self.write("\"");
    }

    fn emitSeq(self: *Emitter, items: []const resolver.Value, indent: usize, inline_first: bool) EmitError!void {
        if (items.len == 0) {
            try self.write("[]");
            return;
        }

        // Use flow style if requested and appropriate
        if (self.shouldUseFlowStyle(items)) {
            try self.emitFlowSeq(items);
            return;
        }

        for (items, 0..) |item, i| {
            if (i > 0 or !inline_first) {
                try self.writeIndent(indent);
            }
            try self.write("- ");

            // For nested collections, start on new line
            switch (item) {
                .seq, .map => {
                    try self.write("\n");
                    try self.emitValue(item, indent + self.opts.indent, false);
                },
                else => {
                    try self.emitValue(item, indent + self.opts.indent, true);
                    try self.write("\n");
                },
            }
        }
    }

    fn shouldUseFlowStyle(self: *Emitter, items: []const resolver.Value) bool {
        return switch (self.opts.collection_style) {
            .block => false,
            .flow => true,
            .flow_simple => {
                // Use flow for simple leaf sequences (no nested collections)
                for (items) |item| {
                    switch (item) {
                        .seq, .map => return false,
                        else => {},
                    }
                }
                return items.len <= 10; // Keep flow short
            },
        };
    }

    fn emitFlowSeq(self: *Emitter, items: []const resolver.Value) EmitError!void {
        try self.write("[");
        for (items, 0..) |item, i| {
            if (i > 0) try self.write(", ");
            try self.emitValue(item, 0, true);
        }
        try self.write("]");
    }

    fn emitMap(self: *Emitter, items: []const resolver.ValueKVPair, indent: usize, inline_first: bool) EmitError!void {
        if (items.len == 0) {
            try self.write("{}");
            return;
        }

        // Use flow style if requested and appropriate
        if (self.shouldUseFlowStyleMap(items)) {
            try self.emitFlowMap(items);
            return;
        }

        for (items, 0..) |item, i| {
            if (i > 0 or !inline_first) {
                // Add blank lines between top-level keys if enabled
                if (self.opts.blank_lines_between_keys and indent == 0 and i > 0) {
                    try self.write("\n");
                }
                try self.writeIndent(indent);
            }

            // Emit key
            try self.emitValue(item.k, indent, true);
            try self.write(":");

            // Emit value
            switch (item.v) {
                .seq, .map => {
                    try self.write("\n");
                    try self.emitValue(item.v, indent + self.opts.indent, false);
                },
                else => {
                    try self.write(" ");
                    try self.emitValue(item.v, indent + self.opts.indent, true);
                    try self.write("\n");
                },
            }
        }
    }

    fn shouldUseFlowStyleMap(self: *Emitter, items: []const resolver.ValueKVPair) bool {
        return switch (self.opts.collection_style) {
            .block => false,
            .flow => true,
            .flow_simple => {
                // Use flow for simple leaf mappings
                for (items) |item| {
                    switch (item.v) {
                        .seq, .map => return false,
                        else => {},
                    }
                }
                return items.len <= 5; // Keep flow short
            },
        };
    }

    fn emitFlowMap(self: *Emitter, items: []const resolver.ValueKVPair) EmitError!void {
        try self.write("{");
        for (items, 0..) |item, i| {
            if (i > 0) try self.write(", ");
            try self.emitValue(item.k, 0, true);
            try self.write(": ");
            try self.emitValue(item.v, 0, true);
        }
        try self.write("}");
    }

    fn writeIndent(self: *Emitter, indent: usize) EmitError!void {
        var i: usize = 0;
        while (i < indent) : (i += 1) {
            self.buffer.append(self.allocator, ' ') catch return error.OutOfMemory;
        }
    }

    fn write(self: *Emitter, s: []const u8) EmitError!void {
        self.buffer.appendSlice(self.allocator, s) catch return error.OutOfMemory;
    }
};

fn needsQuoting(s: []const u8) bool {
    if (s.len == 0) return true;

    // Reserved words
    if (std.mem.eql(u8, s, "true") or
        std.mem.eql(u8, s, "false") or
        std.mem.eql(u8, s, "True") or
        std.mem.eql(u8, s, "False") or
        std.mem.eql(u8, s, "TRUE") or
        std.mem.eql(u8, s, "FALSE") or
        std.mem.eql(u8, s, "null") or
        std.mem.eql(u8, s, "Null") or
        std.mem.eql(u8, s, "NULL") or
        std.mem.eql(u8, s, "~") or
        std.mem.eql(u8, s, ".inf") or
        std.mem.eql(u8, s, ".Inf") or
        std.mem.eql(u8, s, ".INF") or
        std.mem.eql(u8, s, "-.inf") or
        std.mem.eql(u8, s, "-.Inf") or
        std.mem.eql(u8, s, "-.INF") or
        std.mem.eql(u8, s, "+.inf") or
        std.mem.eql(u8, s, "+.Inf") or
        std.mem.eql(u8, s, "+.INF") or
        std.mem.eql(u8, s, ".nan") or
        std.mem.eql(u8, s, ".NaN") or
        std.mem.eql(u8, s, ".NAN"))
    {
        return true;
    }

    // Check if it looks like a number
    if (looksLikeNumber(s)) return true;

    // Special characters that need quoting
    for (s) |c| {
        switch (c) {
            ':', '#', '[', ']', '{', '}', ',', '&', '*', '!', '|', '>', '\'', '"', '%', '@', '`', '\n', '\r', '\t' => return true,
            0x00...0x08, 0x0B, 0x0C, 0x0E...0x1F, 0x7F => return true,
            else => {},
        }
    }

    // Leading/trailing spaces
    if (s[0] == ' ' or s[s.len - 1] == ' ') return true;

    // Leading indicators
    const first = s[0];
    if (first == '-' or first == '?' or first == ':' or first == '!' or first == '&' or first == '*' or first == '|' or first == '>') {
        return true;
    }

    return false;
}

fn looksLikeNumber(s: []const u8) bool {
    if (s.len == 0) return false;

    var i: usize = 0;
    if (s[0] == '+' or s[0] == '-') {
        i = 1;
        if (i >= s.len) return false;
    }

    // Check for leading digit or .
    if ((s[i] >= '0' and s[i] <= '9') or s[i] == '.') {
        // Could be a number
        var has_digit = false;
        while (i < s.len) {
            const c = s[i];
            if (c >= '0' and c <= '9') {
                has_digit = true;
            } else if (c == '.' or c == 'e' or c == 'E' or c == '+' or c == '-') {
                // Continue
            } else if (c == 'x' or c == 'X' or c == 'o' or c == 'O') {
                // Hex or octal prefix
                return true;
            } else {
                return false;
            }
            i += 1;
        }
        return has_digit;
    }

    return false;
}
