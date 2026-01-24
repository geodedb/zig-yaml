// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Error Handling Example
//!
//! Demonstrates proper error handling when parsing YAML, including
//! accessing detailed error information for diagnostics.

const std = @import("std");
const yaml = @import("yaml");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== Error Handling Example ===\n\n", .{});

    // Example 1: Handling parse errors
    try handleParseErrors(allocator);

    // Example 2: Using loadAllWithDetails for better diagnostics
    try handleWithDetails(allocator);

    // Example 3: Streaming parser error handling
    try handleStreamingErrors(allocator);

    // Example 4: Resource limit errors
    try handleResourceLimits(allocator);
}

fn handleParseErrors(allocator: std.mem.Allocator) !void {
    std.debug.print("--- Basic Error Handling ---\n", .{});

    const invalid_cases = [_]struct { input: []const u8, desc: []const u8 }{
        .{ .input = "a: [b", .desc = "Unterminated flow sequence" },
        .{ .input = "{a: b", .desc = "Unterminated flow mapping" },
        .{ .input = "  bad indent", .desc = "Invalid indentation" },
        .{ .input = "\"unterminated", .desc = "Unterminated string" },
        .{ .input = "*undefined_anchor", .desc = "Undefined anchor" },
    };

    for (invalid_cases) |tc| {
        std.debug.print("\n  Testing: {s}\n", .{tc.desc});
        std.debug.print("  Input: {s}\n", .{tc.input});

        _ = yaml.loadAll(allocator, tc.input, .{}) catch |err| {
            std.debug.print("  Error: {s}\n", .{@errorName(err)});
            continue;
        };

        std.debug.print("  Unexpectedly succeeded\n", .{});
    }

    std.debug.print("\n", .{});
}

fn handleWithDetails(allocator: std.mem.Allocator) !void {
    std.debug.print("--- Detailed Error Information ---\n", .{});

    const invalid_yaml =
        \\config:
        \\  valid: true
        \\  broken: [a, b
        \\  more: data
    ;

    std.debug.print("Input:\n{s}\n", .{invalid_yaml});

    var result = yaml.loadAllWithDetails(allocator, invalid_yaml, .{});

    if (result.parse_error) |err| {
        std.debug.print("\nParse Error Details:\n", .{});
        std.debug.print("  Code: {s}\n", .{@tagName(err.code)});
        std.debug.print("  Message: {s}\n", .{err.message()});
        std.debug.print("  Location: line {d}, column {d}\n", .{ err.line, err.col });

        if (err.context.len > 0) {
            std.debug.print("  Context: {s}\n", .{err.context});
        }

        // Format as user-friendly message
        const formatted = try yaml.formatError(allocator, err);
        defer allocator.free(formatted);
        std.debug.print("  Formatted: {s}\n", .{formatted});
    } else {
        std.debug.print("\nUnexpectedly succeeded\n", .{});
        result.deinit(allocator);
    }

    std.debug.print("\n", .{});
}

fn handleStreamingErrors(allocator: std.mem.Allocator) !void {
    std.debug.print("--- Streaming Parser Errors ---\n", .{});

    const invalid_yaml = "key: {broken";

    std.debug.print("Input: {s}\n", .{invalid_yaml});

    var parser = try yaml.Parser.init(allocator, invalid_yaml, .{});
    defer parser.deinit();

    var event_count: usize = 0;

    while (true) {
        const event = parser.nextEvent() catch |err| {
            std.debug.print("\nError after {d} events: {s}\n", .{ event_count, @errorName(err) });

            if (parser.getLastError()) |parse_error| {
                std.debug.print("  Message: {s}\n", .{parse_error.message()});
                std.debug.print("  Location: line {d}, column {d}\n", .{ parse_error.line, parse_error.col });

                // Write to stderr
                const stderr = std.io.getStdErr().writer();
                stderr.print("  Full error: ", .{}) catch {};
                yaml.writeError(stderr, parse_error) catch {};
                stderr.print("\n", .{}) catch {};
            }
            break;
        };

        event_count += 1;
        std.debug.print("  Event {d}: {s}\n", .{ event_count, @tagName(event) });

        if (event == .stream_end) break;
    }

    std.debug.print("\n", .{});
}

fn handleResourceLimits(allocator: std.mem.Allocator) !void {
    std.debug.print("--- Resource Limit Errors ---\n", .{});

    // Create a deeply nested structure
    var deeply_nested = std.ArrayList(u8).init(allocator);
    defer deeply_nested.deinit();

    // Build nested structure: [[[[...]]]]
    for (0..50) |_| {
        try deeply_nested.append('[');
    }
    try deeply_nested.appendSlice("value");
    for (0..50) |_| {
        try deeply_nested.append(']');
    }

    std.debug.print("Testing with depth limit of 10...\n", .{});

    _ = yaml.loadAll(allocator, deeply_nested.items, .{
        .max_depth = 10,
    }) catch |err| {
        std.debug.print("  Error: {s}\n", .{@errorName(err)});
    };

    // Test with byte limit
    const large_scalar = "x" ** 100;
    std.debug.print("\nTesting with scalar size limit of 50 bytes...\n", .{});

    _ = yaml.loadAll(allocator, large_scalar, .{
        .max_scalar_bytes = 50,
    }) catch |err| {
        std.debug.print("  Error: {s}\n", .{@errorName(err)});
    };

    std.debug.print("\n", .{});
}
