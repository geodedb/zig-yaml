// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Basic YAML Parsing Example
//!
//! Demonstrates parsing YAML documents and resolving values using the yaml library.
//! This is the simplest way to work with YAML data.

const std = @import("std");
const yaml = @import("yaml");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Example YAML document
    const input =
        \\---
        \\server:
        \\  host: localhost
        \\  port: 8080
        \\  ssl: true
        \\database:
        \\  url: postgres://localhost/mydb
        \\  pool_size: 10
        \\features:
        \\  - authentication
        \\  - logging
        \\  - metrics
    ;

    std.debug.print("=== Parsing YAML ===\n", .{});
    std.debug.print("{s}\n\n", .{input});

    // Parse YAML documents
    var docs = try yaml.loadAll(allocator, input, .{});
    defer {
        for (docs) |*d| d.deinit();
        allocator.free(docs);
    }

    std.debug.print("Parsed {d} document(s)\n\n", .{docs.len});

    // Resolve each document to typed values
    for (docs, 0..) |*doc, i| {
        std.debug.print("=== Document {d} ===\n", .{i + 1});

        const value = try yaml.resolveToValue(allocator, doc, .{});
        defer yaml.freeValue(allocator, &value);

        // Print the resolved value structure
        try printValue(value, 0);
        std.debug.print("\n", .{});
    }
}

/// Recursively print a Value with indentation
fn printValue(value: yaml.Value, indent: usize) !void {
    const writer = std.io.getStdErr().writer();
    const spaces = "                                        "[0..indent];

    switch (value) {
        .null => try writer.print("{s}null\n", .{spaces}),
        .bool => |b| try writer.print("{s}{}\n", .{ spaces, b }),
        .int => |i| try writer.print("{s}{d}\n", .{ spaces, i }),
        .big_int => |s| try writer.print("{s}{s} (big_int)\n", .{ spaces, s }),
        .float => |f| try writer.print("{s}{d}\n", .{ spaces, f }),
        .inf_pos => try writer.print("{s}.inf\n", .{spaces}),
        .inf_neg => try writer.print("{s}-.inf\n", .{spaces}),
        .nan => try writer.print("{s}.nan\n", .{spaces}),
        .str => |s| try writer.print("{s}\"{s}\"\n", .{ spaces, s }),
        .seq => |items| {
            try writer.print("{s}[\n", .{spaces});
            for (items) |item| {
                try printValue(item, indent + 2);
            }
            try writer.print("{s}]\n", .{spaces});
        },
        .map => |items| {
            try writer.print("{s}{{\n", .{spaces});
            for (items) |kv| {
                // Print key inline
                switch (kv.k) {
                    .str => |s| try writer.print("{s}  {s}:\n", .{ spaces, s }),
                    else => {
                        try writer.print("{s}  ", .{spaces});
                        try printValue(kv.k, 0);
                        try writer.print(":\n", .{});
                    },
                }
                try printValue(kv.v, indent + 4);
            }
            try writer.print("{s}}}\n", .{spaces});
        },
    }
}
