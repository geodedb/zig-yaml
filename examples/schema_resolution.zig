// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Schema Resolution Example
//!
//! Demonstrates how different YAML schemas (failsafe, json, core, yaml11)
//! affect how plain scalars are interpreted as typed values.

const std = @import("std");
const yaml = @import("yaml");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // YAML with values that resolve differently under different schemas
    const input =
        \\# Nulls
        \\null_tilde: ~
        \\null_word: null
        \\null_empty:
        \\
        \\# Booleans
        \\bool_true: true
        \\bool_yes: yes
        \\bool_on: on
        \\
        \\# Integers
        \\int_decimal: 42
        \\int_octal_12: 0o755
        \\int_octal_11: 0755
        \\int_hex: 0xff
        \\int_binary: 0b1010
        \\
        \\# Floats
        \\float_decimal: 3.14
        \\float_exp: 1.2e-5
        \\float_inf: .inf
        \\float_nan: .nan
        \\
        \\# Sexagesimal (YAML 1.1)
        \\time: 1:30:00
    ;

    std.debug.print("=== Schema Resolution Example ===\n", .{});
    std.debug.print("Input:\n{s}\n\n", .{input});

    // Test with different schemas
    const schemas = [_]struct { s: yaml.Schema, name: []const u8 }{
        .{ .s = .failsafe, .name = "Failsafe" },
        .{ .s = .json, .name = "JSON" },
        .{ .s = .core, .name = "Core (YAML 1.2)" },
        .{ .s = .yaml11, .name = "YAML 1.1" },
    };

    for (schemas) |schema_info| {
        std.debug.print("=== {s} Schema ===\n", .{schema_info.name});

        var docs = try yaml.loadAll(allocator, input, .{ .schema = schema_info.s });
        defer {
            for (docs) |*d| d.deinit();
            allocator.free(docs);
        }

        for (docs) |*doc| {
            const value = try yaml.resolveToValue(allocator, doc, .{ .schema = schema_info.s });
            defer yaml.freeValue(allocator, &value);

            try printResolvedMap(value);
        }

        std.debug.print("\n", .{});
    }

    // Demonstrate schema differences
    std.debug.print("=== Key Differences ===\n\n", .{});
    try demonstrateDifferences(allocator);
}

fn printResolvedMap(value: yaml.Value) !void {
    const writer = std.io.getStdErr().writer();

    switch (value) {
        .map => |items| {
            for (items) |kv| {
                switch (kv.k) {
                    .str => |key| {
                        try writer.print("  {s}: ", .{key});
                        try printValueType(kv.v);
                        try writer.print("\n", .{});
                    },
                    else => {},
                }
            }
        },
        else => try writer.print("  Not a mapping\n", .{}),
    }
}

fn printValueType(value: yaml.Value) !void {
    const writer = std.io.getStdErr().writer();

    switch (value) {
        .null => try writer.print("null", .{}),
        .bool => |b| try writer.print("bool({s})", .{if (b) "true" else "false"}),
        .int => |i| try writer.print("int({d})", .{i}),
        .big_int => |s| try writer.print("big_int({s})", .{s}),
        .float => |f| try writer.print("float({d})", .{f}),
        .inf_pos => try writer.print("float(+inf)", .{}),
        .inf_neg => try writer.print("float(-inf)", .{}),
        .nan => try writer.print("float(nan)", .{}),
        .str => |s| try writer.print("str(\"{s}\")", .{s}),
        .seq => |items| try writer.print("seq[{d}]", .{items.len}),
        .map => |items| try writer.print("map{{{d}}}", .{items.len}),
    }
}

fn demonstrateDifferences(allocator: std.mem.Allocator) !void {
    const writer = std.io.getStdErr().writer();

    const test_cases = [_]struct { input: []const u8, desc: []const u8 }{
        .{ .input = "yes", .desc = "yes" },
        .{ .input = "no", .desc = "no" },
        .{ .input = "on", .desc = "on" },
        .{ .input = "off", .desc = "off" },
        .{ .input = "0755", .desc = "0755 (octal)" },
        .{ .input = "1:30:00", .desc = "1:30:00 (time)" },
    };

    const schemas = [_]struct { s: yaml.Schema, name: []const u8 }{
        .{ .s = .core, .name = "Core" },
        .{ .s = .yaml11, .name = "1.1" },
    };

    // Header
    try writer.print("Value          | Core           | YAML 1.1\n", .{});
    try writer.print("---------------|----------------|----------------\n", .{});

    for (test_cases) |tc| {
        try writer.print("{s: <14} |", .{tc.desc});

        for (schemas) |schema_info| {
            var docs = try yaml.loadAll(allocator, tc.input, .{ .schema = schema_info.s });
            defer {
                for (docs) |*d| d.deinit();
                allocator.free(docs);
            }

            if (docs.len > 0) {
                const value = try yaml.resolveToValue(allocator, &docs[0], .{ .schema = schema_info.s });
                defer yaml.freeValue(allocator, &value);

                var buf: [32]u8 = undefined;
                const type_str = try formatValueType(&buf, value);
                try writer.print(" {s: <14} |", .{type_str});
            }
        }
        try writer.print("\n", .{});
    }
}

fn formatValueType(buf: []u8, value: yaml.Value) ![]const u8 {
    return switch (value) {
        .null => "null",
        .bool => |b| if (b) "bool(true)" else "bool(false)",
        .int => |i| std.fmt.bufPrint(buf, "int({d})", .{i}) catch "int(?)",
        .float => "float",
        .str => "str",
        else => "other",
    };
}
