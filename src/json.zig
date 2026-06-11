// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! YAML to JSON Conversion
//! Converts resolved YAML values to JSON format.

const std = @import("std");
const resolver = @import("resolver.zig");

pub const Value = resolver.Value;

pub const JsonOptions = struct {
    /// Pretty print with indentation
    pretty: bool = false,
    /// Indentation string for pretty printing (default: 2 spaces)
    indent: []const u8 = "  ",
};

pub const JsonError = error{
    OutOfMemory,
    /// NaN and Infinity cannot be represented in JSON
    InvalidFloat,
    /// A non-scalar (sequence/mapping) or non-finite map key cannot be
    /// represented as a JSON object key. Returned instead of silently
    /// collapsing distinct complex keys onto one placeholder key.
    UnsupportedKey,
};

/// Convert a YAML value to JSON string
pub fn toJson(allocator: std.mem.Allocator, value: Value, options: JsonOptions) JsonError![]u8 {
    var writer = JsonWriter.init(allocator, options);
    defer writer.deinit();
    try writer.writeValue(value);
    return try writer.toOwnedSlice();
}

/// Convert multiple YAML values to a JSON array
pub fn toJsonArray(allocator: std.mem.Allocator, values: []const Value, options: JsonOptions) JsonError![]u8 {
    var writer = JsonWriter.init(allocator, options);
    defer writer.deinit();

    try writer.output.append(allocator, '[');
    if (options.pretty and values.len > 0) {
        try writer.output.append(allocator, '\n');
    }
    writer.depth += 1;

    for (values, 0..) |v, i| {
        if (i > 0) {
            try writer.output.append(allocator, ',');
            if (options.pretty) {
                try writer.output.append(allocator, '\n');
            }
        }
        if (options.pretty) {
            try writer.writeIndent();
        }
        try writer.writeValue(v);
    }

    writer.depth -= 1;
    if (options.pretty and values.len > 0) {
        try writer.output.append(allocator, '\n');
        try writer.writeIndent();
    }
    try writer.output.append(allocator, ']');

    return try writer.toOwnedSlice();
}

const JsonWriter = struct {
    allocator: std.mem.Allocator,
    output: std.ArrayList(u8),
    options: JsonOptions,
    depth: usize,

    fn init(allocator: std.mem.Allocator, options: JsonOptions) JsonWriter {
        return .{
            .allocator = allocator,
            .output = .empty,
            .options = options,
            .depth = 0,
        };
    }

    fn deinit(self: *JsonWriter) void {
        self.output.deinit(self.allocator);
    }

    fn toOwnedSlice(self: *JsonWriter) ![]u8 {
        return try self.output.toOwnedSlice(self.allocator);
    }

    fn writeValue(self: *JsonWriter, value: Value) JsonError!void {
        switch (value) {
            .null => try self.writeRaw("null"),
            .bool => |b| try self.writeRaw(if (b) "true" else "false"),
            .int => |i| try self.writeInt(i),
            .big_int => |s| try self.writeRaw(s),
            .float => |f| try self.writeFloat(f),
            .inf_pos, .inf_neg, .nan => return error.InvalidFloat,
            .str => |s| try self.writeString(s),
            .seq => |items| try self.writeArray(items),
            .map => |items| try self.writeObject(items),
        }
    }

    fn writeRaw(self: *JsonWriter, s: []const u8) !void {
        try self.output.appendSlice(self.allocator, s);
    }

    fn writeInt(self: *JsonWriter, i: i64) !void {
        var buf: [32]u8 = undefined;
        const formatted = std.fmt.bufPrint(&buf, "{d}", .{i}) catch return error.OutOfMemory;
        try self.output.appendSlice(self.allocator, formatted);
    }

    fn writeFloat(self: *JsonWriter, f: f64) !void {
        var buf: [32]u8 = undefined;
        const formatted = std.fmt.bufPrint(&buf, "{d}", .{f}) catch return error.OutOfMemory;
        try self.output.appendSlice(self.allocator, formatted);
    }

    fn writeString(self: *JsonWriter, s: []const u8) !void {
        try self.output.append(self.allocator, '"');
        for (s) |c| {
            switch (c) {
                '"' => try self.output.appendSlice(self.allocator, "\\\""),
                '\\' => try self.output.appendSlice(self.allocator, "\\\\"),
                '\n' => try self.output.appendSlice(self.allocator, "\\n"),
                '\r' => try self.output.appendSlice(self.allocator, "\\r"),
                '\t' => try self.output.appendSlice(self.allocator, "\\t"),
                0x08 => try self.output.appendSlice(self.allocator, "\\b"),
                0x0C => try self.output.appendSlice(self.allocator, "\\f"),
                else => {
                    if (c < 0x20) {
                        // Control character - escape as \u00XX
                        var buf: [6]u8 = undefined;
                        _ = std.fmt.bufPrint(&buf, "\\u{x:0>4}", .{c}) catch unreachable;
                        try self.output.appendSlice(self.allocator, &buf);
                    } else {
                        try self.output.append(self.allocator, c);
                    }
                },
            }
        }
        try self.output.append(self.allocator, '"');
    }

    fn writeArray(self: *JsonWriter, items: []const Value) !void {
        try self.output.append(self.allocator, '[');

        if (self.options.pretty and items.len > 0) {
            try self.output.append(self.allocator, '\n');
        }
        self.depth += 1;

        for (items, 0..) |item, i| {
            if (i > 0) {
                try self.output.append(self.allocator, ',');
                if (self.options.pretty) {
                    try self.output.append(self.allocator, '\n');
                }
            }
            if (self.options.pretty) {
                try self.writeIndent();
            }
            try self.writeValue(item);
        }

        self.depth -= 1;
        if (self.options.pretty and items.len > 0) {
            try self.output.append(self.allocator, '\n');
            try self.writeIndent();
        }
        try self.output.append(self.allocator, ']');
    }

    fn writeObject(self: *JsonWriter, items: []const resolver.ValueKVPair) !void {
        try self.output.append(self.allocator, '{');

        if (self.options.pretty and items.len > 0) {
            try self.output.append(self.allocator, '\n');
        }
        self.depth += 1;

        for (items, 0..) |kv, i| {
            if (i > 0) {
                try self.output.append(self.allocator, ',');
                if (self.options.pretty) {
                    try self.output.append(self.allocator, '\n');
                }
            }
            if (self.options.pretty) {
                try self.writeIndent();
            }

            // JSON keys must be strings
            try self.writeKeyAsString(kv.k);
            try self.output.append(self.allocator, ':');
            if (self.options.pretty) {
                try self.output.append(self.allocator, ' ');
            }
            try self.writeValue(kv.v);
        }

        self.depth -= 1;
        if (self.options.pretty and items.len > 0) {
            try self.output.append(self.allocator, '\n');
            try self.writeIndent();
        }
        try self.output.append(self.allocator, '}');
    }

    fn writeKeyAsString(self: *JsonWriter, key: Value) !void {
        // Convert key to string representation
        switch (key) {
            .str => |s| try self.writeString(s),
            .int => |i| {
                try self.output.append(self.allocator, '"');
                try self.writeInt(i);
                try self.output.append(self.allocator, '"');
            },
            .bool => |b| try self.writeString(if (b) "true" else "false"),
            .null => try self.writeString("null"),
            .float => |f| {
                try self.output.append(self.allocator, '"');
                try self.writeFloat(f);
                try self.output.append(self.allocator, '"');
            },
            // A big integer is still a scalar with a unique textual form.
            .big_int => |s| try self.writeString(s),
            // Sequence/mapping keys and non-finite floats have no faithful JSON
            // key representation; refuse rather than collide distinct keys.
            else => return error.UnsupportedKey,
        }
    }

    fn writeIndent(self: *JsonWriter) !void {
        for (0..self.depth) |_| {
            try self.output.appendSlice(self.allocator, self.options.indent);
        }
    }
};
