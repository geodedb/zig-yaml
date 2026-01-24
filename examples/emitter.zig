// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Emitter Example
//!
//! Demonstrates emitting YAML from resolved values with various formatting options.
//! The emitter produces canonical YAML output with configurable style.

const std = @import("std");
const yaml = @import("yaml");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Parse a YAML document
    const input =
        \\server:
        \\  host: localhost
        \\  port: 8080
        \\  features:
        \\    - auth
        \\    - logging
        \\    - metrics
        \\users:
        \\  - name: alice
        \\    role: admin
        \\  - name: bob
        \\    role: user
    ;

    std.debug.print("=== Emitter Example ===\n", .{});
    std.debug.print("Input:\n{s}\n\n", .{input});

    // Parse and resolve
    var docs = try yaml.loadAll(allocator, input, .{});
    defer {
        for (docs) |*d| d.deinit();
        allocator.free(docs);
    }

    var values = try allocator.alloc(yaml.Value, docs.len);
    defer {
        for (values) |*v| yaml.freeValue(allocator, v);
        allocator.free(values);
    }

    for (docs, 0..) |*doc, i| {
        values[i] = try yaml.resolveToValue(allocator, doc, .{});
    }

    // Emit with different options
    std.debug.print("=== Default (Block Style) ===\n", .{});
    {
        const output = try yaml.dumpAll(allocator, values, .{});
        defer allocator.free(output);
        std.debug.print("{s}\n", .{output});
    }

    std.debug.print("=== Flow Style ===\n", .{});
    {
        const output = try yaml.dumpAll(allocator, values, .{
            .collection_style = .flow,
            .doc_start = false,
            .doc_end = false,
        });
        defer allocator.free(output);
        std.debug.print("{s}\n", .{output});
    }

    std.debug.print("=== Block with Double Quotes ===\n", .{});
    {
        const output = try yaml.dumpAll(allocator, values, .{
            .quote_style = .double,
            .doc_start = true,
            .doc_end = false,
        });
        defer allocator.free(output);
        std.debug.print("{s}\n", .{output});
    }

    std.debug.print("=== 4-Space Indent with Blank Lines ===\n", .{});
    {
        const output = try yaml.dumpAll(allocator, values, .{
            .indent = 4,
            .blank_lines_between_keys = true,
        });
        defer allocator.free(output);
        std.debug.print("{s}\n", .{output});
    }

    // Demonstrate emitting special values
    std.debug.print("=== Special Values ===\n", .{});
    try emitSpecialValues(allocator);

    // Round-trip demonstration
    std.debug.print("=== Round-Trip ===\n", .{});
    try demonstrateRoundTrip(allocator);
}

fn emitSpecialValues(allocator: std.mem.Allocator) !void {
    const special_yaml =
        \\values:
        \\  null_val: null
        \\  bool_true: true
        \\  bool_false: false
        \\  int_positive: 42
        \\  int_negative: -17
        \\  float_val: 3.14159
        \\  infinity: .inf
        \\  neg_infinity: -.inf
        \\  not_a_number: .nan
        \\  empty_string: ""
        \\  special_chars: "hello\nworld"
    ;

    var docs = try yaml.loadAll(allocator, special_yaml, .{});
    defer {
        for (docs) |*d| d.deinit();
        allocator.free(docs);
    }

    var values = try allocator.alloc(yaml.Value, docs.len);
    defer {
        for (values) |*v| yaml.freeValue(allocator, v);
        allocator.free(values);
    }

    for (docs, 0..) |*doc, i| {
        values[i] = try yaml.resolveToValue(allocator, doc, .{});
    }

    const output = try yaml.dumpAll(allocator, values, .{});
    defer allocator.free(output);
    std.debug.print("{s}\n", .{output});
}

fn demonstrateRoundTrip(allocator: std.mem.Allocator) !void {
    const original =
        \\config:
        \\  name: test
        \\  enabled: true
        \\  count: 42
    ;

    std.debug.print("Original:\n{s}\n", .{original});

    // Parse
    var docs = try yaml.loadAll(allocator, original, .{});
    defer {
        for (docs) |*d| d.deinit();
        allocator.free(docs);
    }

    // Resolve
    var values = try allocator.alloc(yaml.Value, docs.len);
    defer {
        for (values) |*v| yaml.freeValue(allocator, v);
        allocator.free(values);
    }

    for (docs, 0..) |*doc, i| {
        values[i] = try yaml.resolveToValue(allocator, doc, .{});
    }

    // Emit
    const emitted = try yaml.dumpAll(allocator, values, .{
        .doc_start = false,
        .doc_end = false,
    });
    defer allocator.free(emitted);

    std.debug.print("Emitted:\n{s}\n", .{emitted});

    // Parse again to verify
    var docs2 = try yaml.loadAll(allocator, emitted, .{});
    defer {
        for (docs2) |*d| d.deinit();
        allocator.free(docs2);
    }

    std.debug.print("Round-trip successful: parsed {d} document(s)\n", .{docs2.len});
}
