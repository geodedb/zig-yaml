// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Streaming Parser Example
//!
//! Demonstrates the streaming (SAX-style) event-based parser for memory-efficient
//! processing of large YAML documents. Events are generated on-demand without
//! building the full document tree in memory.

const std = @import("std");
const yaml = @import("yaml");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Example: Multi-document YAML stream
    const input =
        \\---
        \\name: document1
        \\items:
        \\  - one
        \\  - two
        \\  - three
        \\---
        \\name: document2
        \\config:
        \\  key: value
        \\  nested:
        \\    deep: true
    ;

    std.debug.print("=== Streaming Parser Example ===\n", .{});
    std.debug.print("Input:\n{s}\n\n", .{input});

    // Method 1: Using Parser directly
    std.debug.print("--- Method 1: Direct Parser ---\n", .{});
    try streamWithParser(allocator, input);

    // Method 2: Using EventIterator
    std.debug.print("\n--- Method 2: Event Iterator ---\n", .{});
    try streamWithIterator(allocator, input);

    // Method 3: Selective extraction
    std.debug.print("\n--- Method 3: Selective Extraction ---\n", .{});
    try extractNames(allocator, input);
}

/// Stream events using Parser directly
fn streamWithParser(allocator: std.mem.Allocator, input: []const u8) !void {
    var parser = try yaml.Parser.init(allocator, input, .{});
    defer parser.deinit();

    var depth: usize = 0;
    var event_count: usize = 0;

    while (true) {
        const event = parser.nextEvent() catch |err| {
            if (parser.getLastError()) |parse_error| {
                std.debug.print("Parse error: {s} at line {d}, col {d}\n", .{
                    parse_error.message(),
                    parse_error.line,
                    parse_error.col,
                });
            }
            return err;
        };

        event_count += 1;
        try printEvent(event, depth);

        switch (event) {
            .stream_end => break,
            .seq_start, .map_start => depth += 1,
            .seq_end, .map_end => depth -|= 1, // Saturating subtract
            else => {},
        }
    }

    std.debug.print("\nTotal events: {d}\n", .{event_count});
}

/// Stream events using EventIterator (more convenient API)
fn streamWithIterator(allocator: std.mem.Allocator, input: []const u8) !void {
    var iter = try yaml.streamEvents(allocator, input, .{});
    defer iter.deinit();

    var scalar_count: usize = 0;
    var map_count: usize = 0;
    var seq_count: usize = 0;

    while (try iter.next()) |event| {
        switch (event) {
            .scalar => scalar_count += 1,
            .map_start => map_count += 1,
            .seq_start => seq_count += 1,
            else => {},
        }
    }

    std.debug.print("Statistics:\n", .{});
    std.debug.print("  Scalars: {d}\n", .{scalar_count});
    std.debug.print("  Mappings: {d}\n", .{map_count});
    std.debug.print("  Sequences: {d}\n", .{seq_count});
}

/// Example: Extract only specific fields without full parsing
fn extractNames(allocator: std.mem.Allocator, input: []const u8) !void {
    var parser = try yaml.Parser.init(allocator, input, .{});
    defer parser.deinit();

    var names = std.ArrayList([]const u8).init(allocator);
    defer names.deinit();

    var looking_for_name_value = false;

    while (true) {
        const event = try parser.nextEvent();

        switch (event) {
            .stream_end => break,
            .scalar => |s| {
                if (looking_for_name_value) {
                    // This is the value after a "name" key
                    try names.append(s.value);
                    looking_for_name_value = false;
                } else if (std.mem.eql(u8, s.value, "name")) {
                    // Next scalar is the name value
                    looking_for_name_value = true;
                }
            },
            else => {
                // If we see a non-scalar after "name" key, reset
                if (looking_for_name_value and event != .scalar) {
                    looking_for_name_value = false;
                }
            },
        }
    }

    std.debug.print("Extracted 'name' values:\n", .{});
    for (names.items) |name| {
        std.debug.print("  - {s}\n", .{name});
    }
}

/// Print a single event with indentation
fn printEvent(event: yaml.Event, depth: usize) !void {
    const writer = std.io.getStdErr().writer();
    const indent = depth * 2;
    const spaces = "                                        "[0..@min(indent, 40)];

    switch (event) {
        .stream_start => try writer.print("{s}STREAM-START\n", .{spaces}),
        .stream_end => try writer.print("{s}STREAM-END\n", .{spaces}),
        .doc_start => try writer.print("{s}DOC-START\n", .{spaces}),
        .doc_end => try writer.print("{s}DOC-END\n", .{spaces}),
        .seq_start => |meta| {
            try writer.print("{s}SEQ-START", .{spaces});
            try printMeta(meta);
            try writer.print("\n", .{});
        },
        .seq_end => try writer.print("{s}SEQ-END\n", .{spaces}),
        .map_start => |meta| {
            try writer.print("{s}MAP-START", .{spaces});
            try printMeta(meta);
            try writer.print("\n", .{});
        },
        .map_end => try writer.print("{s}MAP-END\n", .{spaces}),
        .scalar => |s| {
            try writer.print("{s}SCALAR: \"{s}\"", .{ spaces, s.value });
            try printMeta(s.meta);
            try writer.print(" (style: {s})\n", .{@tagName(s.style)});
        },
        .alias => |name| try writer.print("{s}ALIAS: *{s}\n", .{ spaces, name }),
    }
}

fn printMeta(meta: yaml.NodeMeta) !void {
    const writer = std.io.getStdErr().writer();
    if (meta.anchor) |anchor| {
        try writer.print(" &{s}", .{anchor});
    }
    if (!std.mem.eql(u8, meta.tag, "?") and !std.mem.eql(u8, meta.tag, "!")) {
        try writer.print(" <{s}>", .{meta.tag});
    }
}
