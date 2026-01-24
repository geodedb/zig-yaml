// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Document Graph Example
//!
//! Demonstrates working with the document graph representation, which preserves
//! anchors, aliases, and the full structure of YAML documents. This is useful
//! for round-trip processing and when you need to maintain the original structure.

const std = @import("std");
const yaml = @import("yaml");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Example with anchors and aliases
    const input =
        \\---
        \\# Define reusable configuration blocks using anchors
        \\defaults: &defaults
        \\  timeout: 30
        \\  retries: 3
        \\  ssl: true
        \\
        \\development:
        \\  <<: *defaults
        \\  host: localhost
        \\  port: 3000
        \\
        \\production:
        \\  <<: *defaults
        \\  host: api.example.com
        \\  port: 443
        \\
        \\# Shared reference
        \\shared_config: &shared
        \\  version: "1.0"
        \\
        \\services:
        \\  - name: auth
        \\    config: *shared
        \\  - name: api
        \\    config: *shared
    ;

    std.debug.print("=== Document Graph Example ===\n", .{});
    std.debug.print("Input:\n{s}\n\n", .{input});

    // Parse to document graph (preserves structure)
    var docs = try yaml.loadAll(allocator, input, .{});
    defer {
        for (docs) |*d| d.deinit();
        allocator.free(docs);
    }

    for (docs, 0..) |*doc, i| {
        std.debug.print("=== Document {d} Graph ===\n", .{i + 1});
        try printDocumentGraph(doc, allocator);
        std.debug.print("\n", .{});

        // Resolve to values (follows aliases)
        std.debug.print("=== Document {d} Resolved Values ===\n", .{i + 1});
        const value = try yaml.resolveToValue(allocator, doc, .{});
        defer yaml.freeValue(allocator, &value);

        // Emit back to YAML
        const output = try yaml.dumpAll(allocator, &.{value}, .{
            .doc_start = true,
            .doc_end = true,
        });
        defer allocator.free(output);

        std.debug.print("{s}\n", .{output});
    }

    // Demonstrate direct graph traversal
    std.debug.print("=== Direct Graph Traversal ===\n", .{});
    try traverseGraph(&docs[0]);
}

/// Print the document graph structure
fn printDocumentGraph(doc: *const yaml.Document, allocator: std.mem.Allocator) !void {
    // Use debug JSON output for visualization
    const docs_slice: []const yaml.Document = @as([*]const yaml.Document, @ptrCast(doc))[0..1];
    const json = try yaml.debugJsonGraph(allocator, docs_slice);
    defer allocator.free(json);
    std.debug.print("{s}\n", .{json});
}

/// Traverse the document graph directly
fn traverseGraph(doc: *const yaml.Document) !void {
    const writer = std.io.getStdErr().writer();

    const root = doc.root();
    try writer.print("Root node ID: {d}\n", .{root});

    try traverseNode(doc, root, 0);
}

fn traverseNode(doc: *const yaml.Document, node_id: yaml.NodeId, depth: usize) !void {
    const writer = std.io.getStdErr().writer();
    const indent = depth * 2;
    const spaces = "                                        "[0..@min(indent, 40)];

    const node = doc.node(node_id);

    switch (node.*) {
        .s => |scalar| {
            try writer.print("{s}[{d}] Scalar: \"{s}\"", .{ spaces, node_id, scalar.v });
            if (scalar.meta.anchor) |anchor| {
                try writer.print(" &{s}", .{anchor});
            }
            try writer.print("\n", .{});
        },
        .q => |seq| {
            try writer.print("{s}[{d}] Sequence ({d} items)", .{ spaces, node_id, seq.items.len });
            if (seq.meta.anchor) |anchor| {
                try writer.print(" &{s}", .{anchor});
            }
            try writer.print("\n", .{});
            for (seq.items) |item_id| {
                try traverseNode(doc, item_id, depth + 1);
            }
        },
        .m => |map| {
            try writer.print("{s}[{d}] Mapping ({d} pairs)", .{ spaces, node_id, map.items.len });
            if (map.meta.anchor) |anchor| {
                try writer.print(" &{s}", .{anchor});
            }
            try writer.print("\n", .{});
            for (map.items) |kv| {
                try writer.print("{s}  Key:\n", .{spaces});
                try traverseNode(doc, kv.k, depth + 2);
                try writer.print("{s}  Value:\n", .{spaces});
                try traverseNode(doc, kv.v, depth + 2);
            }
        },
        .a => |alias_name| {
            try writer.print("{s}[{d}] Alias: *{s}\n", .{ spaces, node_id, alias_name });
        },
    }
}
