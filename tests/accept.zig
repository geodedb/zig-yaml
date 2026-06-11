// SPDX-License-Identifier: MIT
// Copyright (c) 2024 DevNW

//! YAML 1.2.2 Acceptance Tests
//! Tests the exact outputs specified in the requirements.

const std = @import("std");
const yaml = @import("yaml");

// ============================================================================
// T1: Core schema -> debugJsonValue
// ============================================================================

test "T1: core schema resolution" {
    const allocator = std.testing.allocator;

    const input = "---\na: 1\nb: true\nc: null\nd: [x, y]\n";
    const expected = "{\"d\":[{\"@\":[[\"a\",1],[\"b\",true],[\"c\",null],[\"d\",[\"x\",\"y\"]]]}]}";

    const docs = try yaml.loadAll(allocator, input, .{});
    defer {
        for (docs) |*d| d.deinit();
        allocator.free(docs);
    }

    // Resolve all documents to values
    var values = try allocator.alloc(yaml.Value, docs.len);
    defer {
        for (values) |*v| yaml.freeValue(allocator, v);
        allocator.free(values);
    }

    for (docs, 0..) |*doc, i| {
        values[i] = try yaml.resolveToValue(allocator, doc, .{});
    }

    const result = try yaml.debugJsonValue(allocator, values);
    defer allocator.free(result);

    try std.testing.expectEqualStrings(expected, result);
}

// ============================================================================
// T2: Anchors/aliases preserved -> debugJsonGraph
// ============================================================================

test "T2: anchors and aliases in graph" {
    const allocator = std.testing.allocator;

    const input = "---\nbase: &B {x: 1}\nuse: *B\n";
    const expected = "{\"d\":[{\"k\":\"m\",\"i\":[[{\"k\":\"s\",\"t\":\"!!str\",\"v\":\"base\"},{\"k\":\"m\",\"a\":\"B\",\"i\":[[{\"k\":\"s\",\"t\":\"!!str\",\"v\":\"x\"},{\"k\":\"s\",\"t\":\"!!int\",\"v\":\"1\"}]]}],[{\"k\":\"s\",\"t\":\"!!str\",\"v\":\"use\"},{\"k\":\"*\",\"r\":\"B\"}]]}]}";

    const docs = try yaml.loadAll(allocator, input, .{});
    defer {
        for (docs) |*d| d.deinit();
        allocator.free(docs);
    }

    const result = try yaml.debugJsonGraph(allocator, docs);
    defer allocator.free(result);

    try std.testing.expectEqualStrings(expected, result);
}

// ============================================================================
// T3: Block scalars
// ============================================================================

test "T3: block scalars literal and folded" {
    const allocator = std.testing.allocator;

    const input = "---\nlit: |-\n  a\n  b\nfold: >-\n  a\n  b\n";
    const expected = "{\"d\":[{\"@\":[[\"lit\",\"a\\nb\"],[\"fold\",\"a b\"]]}]}";

    const docs = try yaml.loadAll(allocator, input, .{});
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

    const result = try yaml.debugJsonValue(allocator, values);
    defer allocator.free(result);

    try std.testing.expectEqualStrings(expected, result);
}

// ============================================================================
// T4: Canonical dump
// ============================================================================

test "T4: canonical emitter output" {
    const allocator = std.testing.allocator;

    // Parse T1 input
    const input = "---\na: 1\nb: true\nc: null\nd: [x, y]\n";
    const expected = "---\na: 1\nb: true\nc: null\nd:\n  - x\n  - y\n...\n";

    const docs = try yaml.loadAll(allocator, input, .{});
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

    const result = try yaml.dumpAll(allocator, values, .{});
    defer allocator.free(result);

    try std.testing.expectEqualStrings(expected, result);
}

// ============================================================================
// T5: Invalid alias error
// ============================================================================

test "T5: undefined anchor error" {
    const allocator = std.testing.allocator;

    const input = "---\na: *NOPE\n";

    const docs = try yaml.loadAll(allocator, input, .{});
    defer {
        for (docs) |*d| d.deinit();
        allocator.free(docs);
    }

    // Try to resolve - should fail on undefined anchor
    for (docs) |*doc| {
        const result = yaml.resolveToValue(allocator, doc, .{});
        if (result) |v| {
            // Should have failed - but clean up if it didn't
            var value = v;
            yaml.freeValue(allocator, &value);
            try std.testing.expect(false);
        } else |err| {
            // Expected error
            try std.testing.expect(err == error.UndefinedAnchor);
        }
    }
}

// ============================================================================
// T6: Alias cycle detection
// ============================================================================

test "T6: alias cycle detection" {
    const allocator = std.testing.allocator;

    // A cyclic alias: list contains itself
    const input = "---\n- &a\n  - *a\n";

    const docs = try yaml.loadAll(allocator, input, .{});
    defer {
        for (docs) |*d| d.deinit();
        allocator.free(docs);
    }

    // The document parses successfully, but resolving should detect the cycle
    for (docs) |*doc| {
        const result = yaml.resolveToValue(allocator, doc, .{});
        if (result) |v| {
            // Should have failed - but clean up if it didn't
            var value = v;
            yaml.freeValue(allocator, &value);
            try std.testing.expect(false);
        } else |err| {
            // Expected error
            try std.testing.expect(err == error.AliasCycle);
        }
    }
}

// ============================================================================
// Additional tests
// ============================================================================

test "multi-document stream" {
    const allocator = std.testing.allocator;

    const input = "---\nfirst: 1\n---\nsecond: 2\n";

    const docs = try yaml.loadAll(allocator, input, .{});
    defer {
        for (docs) |*d| d.deinit();
        allocator.free(docs);
    }

    try std.testing.expectEqual(@as(usize, 2), docs.len);
}

test "flow collections" {
    const allocator = std.testing.allocator;

    const input = "{a: 1, b: [1, 2, 3]}";

    const docs = try yaml.loadAll(allocator, input, .{});
    defer {
        for (docs) |*d| d.deinit();
        allocator.free(docs);
    }

    try std.testing.expectEqual(@as(usize, 1), docs.len);
}

test "quoted strings" {
    const allocator = std.testing.allocator;

    const input = "single: 'hello'\ndouble: \"world\\n\"";

    const docs = try yaml.loadAll(allocator, input, .{});
    defer {
        for (docs) |*d| d.deinit();
        allocator.free(docs);
    }

    try std.testing.expectEqual(@as(usize, 1), docs.len);
}

test "nested structures" {
    const allocator = std.testing.allocator;

    const input =
        \\root:
        \\  level1:
        \\    level2:
        \\      value: deep
    ;

    const docs = try yaml.loadAll(allocator, input, .{});
    defer {
        for (docs) |*d| d.deinit();
        allocator.free(docs);
    }

    try std.testing.expectEqual(@as(usize, 1), docs.len);
}

test "special float values" {
    const allocator = std.testing.allocator;

    const input = "inf: .inf\nninf: -.inf\nnan: .nan";

    const docs = try yaml.loadAll(allocator, input, .{});
    defer {
        for (docs) |*d| d.deinit();
        allocator.free(docs);
    }

    var value = try yaml.resolveToValue(allocator, &docs[0], .{});
    defer yaml.freeValue(allocator, &value);
}

test "integer formats" {
    const allocator = std.testing.allocator;

    const input = "dec: 42\nhex: 0x2A\noct: 0o52";

    const docs = try yaml.loadAll(allocator, input, .{});
    defer {
        for (docs) |*d| d.deinit();
        allocator.free(docs);
    }

    var value = try yaml.resolveToValue(allocator, &docs[0], .{});
    defer yaml.freeValue(allocator, &value);
}

test "failsafe schema" {
    const allocator = std.testing.allocator;

    const input = "value: true";

    const docs = try yaml.loadAll(allocator, input, .{ .schema = .failsafe });
    defer {
        for (docs) |*d| d.deinit();
        allocator.free(docs);
    }

    var value = try yaml.resolveToValue(allocator, &docs[0], .{ .schema = .failsafe });
    defer yaml.freeValue(allocator, &value);

    // In failsafe schema, "true" should be a string, not a bool
    switch (value) {
        .map => |items| {
            if (items.len > 0) {
                switch (items[0].v) {
                    .str => |s| try std.testing.expectEqualStrings("true", s),
                    else => try std.testing.expect(false),
                }
            }
        },
        else => try std.testing.expect(false),
    }
}

test "streaming event iterator" {
    const allocator = std.testing.allocator;

    const input = "---\na: 1\nb: 2\n";

    var iter = try yaml.streamEvents(allocator, input, .{});
    defer iter.deinit();

    var event_count: usize = 0;
    var scalar_count: usize = 0;

    while (try iter.next()) |event| {
        event_count += 1;
        switch (event) {
            .scalar => scalar_count += 1,
            else => {},
        }
    }

    // stream_start, doc_start, map_start, scalar(a), scalar(1), scalar(b), scalar(2), map_end, doc_end, stream_end
    try std.testing.expect(event_count >= 4);
    try std.testing.expectEqual(@as(usize, 4), scalar_count);
}

test "schema validation - valid" {
    const allocator = std.testing.allocator;

    const input = "name: test\ncount: 42\nenabled: true";

    const docs = try yaml.loadAll(allocator, input, .{});
    defer {
        for (docs) |*d| d.deinit();
        allocator.free(docs);
    }

    var value = try yaml.resolveToValue(allocator, &docs[0], .{});
    defer yaml.freeValue(allocator, &value);

    // Define expected schema
    const test_schema = yaml.schema.mapOf(yaml.schema.str, yaml.schema.any);

    var result = try yaml.validateValue(allocator, value, test_schema);
    defer result.deinit(allocator);

    try std.testing.expect(result.valid);
    try std.testing.expectEqual(@as(usize, 0), result.errors.len);
}

test "schema validation - invalid type" {
    const allocator = std.testing.allocator;

    const input = "value: not_a_number";

    const docs = try yaml.loadAll(allocator, input, .{});
    defer {
        for (docs) |*d| d.deinit();
        allocator.free(docs);
    }

    var value = try yaml.resolveToValue(allocator, &docs[0], .{});
    defer yaml.freeValue(allocator, &value);

    // Expect an integer value
    const test_schema = yaml.schema.mapOf(yaml.schema.str, yaml.schema.int);

    var result = try yaml.validateValue(allocator, value, test_schema);
    defer result.deinit(allocator);

    // Should fail validation - string is not an int
    try std.testing.expect(!result.valid);
    try std.testing.expect(result.errors.len > 0);
}

test "JSON conversion - simple" {
    const allocator = std.testing.allocator;

    const input = "name: test\ncount: 42\nenabled: true";

    const docs = try yaml.loadAll(allocator, input, .{});
    defer {
        for (docs) |*d| d.deinit();
        allocator.free(docs);
    }

    var value = try yaml.resolveToValue(allocator, &docs[0], .{});
    defer yaml.freeValue(allocator, &value);

    const json = try yaml.toJson(allocator, value, .{});
    defer allocator.free(json);

    // Verify it's valid JSON-like output
    try std.testing.expect(json.len > 0);
    try std.testing.expect(json[0] == '{');
    try std.testing.expect(json[json.len - 1] == '}');

    // Should contain our values
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"test\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "42") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "true") != null);
}

test "JSON conversion - pretty print" {
    const allocator = std.testing.allocator;

    const input = "items:\n  - a\n  - b";

    const docs = try yaml.loadAll(allocator, input, .{});
    defer {
        for (docs) |*d| d.deinit();
        allocator.free(docs);
    }

    var value = try yaml.resolveToValue(allocator, &docs[0], .{});
    defer yaml.freeValue(allocator, &value);

    const json = try yaml.toJson(allocator, value, .{ .pretty = true });
    defer allocator.free(json);

    // Pretty print should contain newlines
    try std.testing.expect(std.mem.indexOf(u8, json, "\n") != null);
}

test "comptime parsing - simple map" {
    const config = comptime yaml.comptimeParse(
        \\name: myapp
        \\version: 42
        \\enabled: true
    );

    // Access values at comptime
    const name = comptime config.get("name").?.asString().?;
    const version = comptime config.get("version").?.asInt().?;
    const enabled = comptime config.get("enabled").?.asBool().?;

    try std.testing.expectEqualStrings("myapp", name);
    try std.testing.expectEqual(@as(i64, 42), version);
    try std.testing.expect(enabled);
}

test "comptime parsing - nested structure" {
    const config = comptime yaml.comptimeParse(
        \\database:
        \\  host: localhost
        \\  port: 5432
    );

    const db = comptime config.get("database").?;
    const host = comptime db.get("host").?.asString().?;
    const port = comptime db.get("port").?.asInt().?;

    try std.testing.expectEqualStrings("localhost", host);
    try std.testing.expectEqual(@as(i64, 5432), port);
}

test "comptime parsing - sequence" {
    const config = comptime yaml.comptimeParse(
        \\items:
        \\  - one
        \\  - two
        \\  - three
    );

    const items = comptime config.get("items").?.asSeq().?;
    try std.testing.expectEqual(@as(usize, 3), items.len);
    try std.testing.expectEqualStrings("one", items[0].asString().?);
}

// ============================================================================
// YAML 1.1 Compatibility Mode Tests
// ============================================================================

test "YAML 1.1 - boolean yes/no/on/off" {
    const allocator = std.testing.allocator;

    const input =
        \\enabled: yes
        \\disabled: no
        \\active: on
        \\inactive: off
        \\short_true: y
        \\short_false: n
    ;

    const docs = try yaml.loadAll(allocator, input, .{ .schema = .yaml11 });
    defer {
        for (docs) |*d| d.deinit();
        allocator.free(docs);
    }

    var value = try yaml.resolveToValue(allocator, &docs[0], .{ .schema = .yaml11 });
    defer yaml.freeValue(allocator, &value);

    // All should resolve to booleans
    const map = value.map;
    for (map) |pair| {
        // Key should be string
        try std.testing.expect(pair.k == .str);
        // Value should be bool
        try std.testing.expect(pair.v == .bool);
    }
}

test "YAML 1.1 - octal with leading zero" {
    const allocator = std.testing.allocator;

    const input =
        \\permissions: 0755
        \\mask: 077
    ;

    const docs = try yaml.loadAll(allocator, input, .{ .schema = .yaml11 });
    defer {
        for (docs) |*d| d.deinit();
        allocator.free(docs);
    }

    var value = try yaml.resolveToValue(allocator, &docs[0], .{ .schema = .yaml11 });
    defer yaml.freeValue(allocator, &value);

    const map = value.map;
    // permissions: 0755 = 493
    try std.testing.expectEqual(@as(i64, 493), map[0].v.int);
    // mask: 077 = 63
    try std.testing.expectEqual(@as(i64, 63), map[1].v.int);
}

test "YAML 1.1 - binary integers" {
    const allocator = std.testing.allocator;

    const input =
        \\flags: 0b1010
        \\mask: 0B11110000
    ;

    const docs = try yaml.loadAll(allocator, input, .{ .schema = .yaml11 });
    defer {
        for (docs) |*d| d.deinit();
        allocator.free(docs);
    }

    var value = try yaml.resolveToValue(allocator, &docs[0], .{ .schema = .yaml11 });
    defer yaml.freeValue(allocator, &value);

    const map = value.map;
    // 0b1010 = 10
    try std.testing.expectEqual(@as(i64, 10), map[0].v.int);
    // 0B11110000 = 240
    try std.testing.expectEqual(@as(i64, 240), map[1].v.int);
}

test "YAML 1.1 - sexagesimal integers" {
    const allocator = std.testing.allocator;

    const input =
        \\duration: 1:30:00
        \\timeout: 5:00
    ;

    const docs = try yaml.loadAll(allocator, input, .{ .schema = .yaml11 });
    defer {
        for (docs) |*d| d.deinit();
        allocator.free(docs);
    }

    var value = try yaml.resolveToValue(allocator, &docs[0], .{ .schema = .yaml11 });
    defer yaml.freeValue(allocator, &value);

    const map = value.map;
    // 1:30:00 = 5400 (1*3600 + 30*60 + 0)
    try std.testing.expectEqual(@as(i64, 5400), map[0].v.int);
    // 5:00 = 300 (5*60 + 0)
    try std.testing.expectEqual(@as(i64, 300), map[1].v.int);
}

test "YAML 1.1 vs core schema - 'yes' handling" {
    const allocator = std.testing.allocator;

    const input = "value: yes\n";

    // With YAML 1.1 schema: yes -> bool true
    {
        const docs = try yaml.loadAll(allocator, input, .{ .schema = .yaml11 });
        defer {
            for (docs) |*d| d.deinit();
            allocator.free(docs);
        }
        var value = try yaml.resolveToValue(allocator, &docs[0], .{ .schema = .yaml11 });
        defer yaml.freeValue(allocator, &value);

        try std.testing.expect(value.map[0].v == .bool);
        try std.testing.expect(value.map[0].v.bool == true);
    }

    // With core schema: yes -> string "yes"
    {
        const docs = try yaml.loadAll(allocator, input, .{ .schema = .core });
        defer {
            for (docs) |*d| d.deinit();
            allocator.free(docs);
        }
        var value = try yaml.resolveToValue(allocator, &docs[0], .{ .schema = .core });
        defer yaml.freeValue(allocator, &value);

        try std.testing.expect(value.map[0].v == .str);
        try std.testing.expectEqualStrings("yes", value.map[0].v.str);
    }
}

// ============================================================================
// Security / memory-safety regression tests
//
// These encode the acceptance criteria for the findings in
// docs/APPSEC_REVIEW_2026-06-11.md (F-01..F-04) and the gap/quality reviews.
// They run under std.testing.allocator, which detects double-free and leaks.
// ============================================================================

/// Resolve `input` to a Value tree and immediately free it.
/// Asserts the full resolveToValue + freeValue contract is leak/corruption-free.
fn resolveAndFree(allocator: std.mem.Allocator, input: []const u8, opts: yaml.ParseOptions) !void {
    const docs = try yaml.loadAll(allocator, input, opts);
    defer {
        for (docs) |*d| d.deinit();
        allocator.free(docs);
    }
    for (docs) |*doc| {
        var value = try yaml.resolveToValue(allocator, doc, opts);
        yaml.freeValue(allocator, &value);
    }
}

test "SEC F-01: single alias to a map resolves and frees cleanly" {
    // Was a double-free: the alias shared the map's heap pointers, freed twice.
    try resolveAndFree(std.testing.allocator, "[&x {k: v}, *x]", .{});
}

test "SEC F-01: single alias to a sequence resolves and frees cleanly" {
    try resolveAndFree(std.testing.allocator, "[&x [1, 2, 3], *x]", .{});
}

test "SEC F-01: single alias to a scalar resolves and frees cleanly" {
    try resolveAndFree(std.testing.allocator, "[&x hello, *x]", .{});
}

test "SEC F-01: multiple aliases to one anchor resolve and free cleanly" {
    try resolveAndFree(std.testing.allocator, "[&x {k: vvvvv}, *x, *x, *x]", .{});
}

test "SEC F-01: nested aliases resolve and free cleanly" {
    const input =
        \\a: &a [1, 2]
        \\b: &b [*a, *a]
        \\c: [*b, *b, *a]
    ;
    try resolveAndFree(std.testing.allocator, input, .{});
}

test "SEC F-01: anchored map reused as map value frees cleanly" {
    try resolveAndFree(std.testing.allocator, "base: &B {x: 1}\nuse: *B\n", .{});
}

test "SEC F-02: billion-laughs alias expansion is bounded, not OOM/crash" {
    const allocator = std.testing.allocator;
    // 6 levels, 9-way fan-out: each level references the previous 9 times.
    const input =
        \\a: &a ["x","x","x","x","x","x","x","x","x"]
        \\b: &b [*a,*a,*a,*a,*a,*a,*a,*a,*a]
        \\c: &c [*b,*b,*b,*b,*b,*b,*b,*b,*b]
        \\d: &d [*c,*c,*c,*c,*c,*c,*c,*c,*c]
        \\e: &e [*d,*d,*d,*d,*d,*d,*d,*d,*d]
        \\f: &f [*e,*e,*e,*e,*e,*e,*e,*e,*e]
        \\g: [*f,*f,*f,*f,*f,*f,*f,*f,*f]
    ;
    const docs = try yaml.loadAll(allocator, input, .{});
    defer {
        for (docs) |*d| d.deinit();
        allocator.free(docs);
    }
    // Resolution must refuse to materialize ~4.7M nodes under the default
    // 1M node budget. Either node or depth budget may trip first.
    const result = yaml.resolveToValue(allocator, &docs[0], .{});
    if (result) |v| {
        var value = v;
        yaml.freeValue(allocator, &value);
        return error.TestExpectedResourceLimit;
    } else |err| {
        try std.testing.expect(err == error.MaxNodesExceeded or err == error.MaxDepthExceeded);
    }
}

test "SEC F-03: deep nesting with raised max_depth errors, never crashes" {
    const allocator = std.testing.allocator;
    // 4000 nested flow sequences. With a raised max_depth this previously
    // drove unbounded native recursion to SIGSEGV; it must now error gracefully.
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);
    try buf.appendNTimes(allocator, '[', 4000);
    try buf.appendNTimes(allocator, ']', 4000);

    const opts = yaml.ParseOptions{ .max_depth = 60000 };
    // loadAll (composer) must bound recursion at the hard ceiling.
    const docs_res = yaml.loadAll(allocator, buf.items, opts);
    if (docs_res) |docs| {
        defer {
            for (docs) |*d| d.deinit();
            allocator.free(docs);
        }
        // If it composed, resolving must also be bounded and not crash.
        for (docs) |*doc| {
            const r = yaml.resolveToValue(allocator, doc, opts);
            if (r) |v| {
                var value = v;
                yaml.freeValue(allocator, &value);
            } else |err| {
                try std.testing.expect(err == error.MaxDepthExceeded or err == error.MaxNodesExceeded);
            }
        }
    } else |err| {
        try std.testing.expect(err == error.MaxDepthExceeded or err == error.ParseFailed);
    }
}

test "SEC F-03: streaming parser enforces max_depth" {
    const allocator = std.testing.allocator;
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);
    try buf.appendNTimes(allocator, '[', 1000);

    var p = try yaml.Parser.init(allocator, buf.items, .{ .max_depth = 100 });
    defer p.deinit();
    var depth_error = false;
    while (true) {
        const event = p.nextEvent() catch {
            depth_error = true;
            break;
        };
        if (event == .stream_end) break;
    }
    try std.testing.expect(depth_error);
    if (p.getLastError()) |e| {
        try std.testing.expect(e.code == .max_depth_exceeded);
    }
}

test "SEC F-04: oversized sexagesimal under yaml11 returns string, never panics" {
    const allocator = std.testing.allocator;
    const input = "x: 99999999999999999999:59:59\n";
    const docs = try yaml.loadAll(allocator, input, .{ .schema = .yaml11 });
    defer {
        for (docs) |*d| d.deinit();
        allocator.free(docs);
    }
    var value = try yaml.resolveToValue(allocator, &docs[0], .{ .schema = .yaml11 });
    defer yaml.freeValue(allocator, &value);
    // Overflowing value must fall through to a string, not panic/wrap.
    try std.testing.expect(value.map[0].v == .str);
}

test "SEC F-04: oversized decimal under yaml11 returns string, never panics" {
    const allocator = std.testing.allocator;
    const input = "x: 999999999999999999999999999999\n";
    const docs = try yaml.loadAll(allocator, input, .{ .schema = .yaml11 });
    defer {
        for (docs) |*d| d.deinit();
        allocator.free(docs);
    }
    var value = try yaml.resolveToValue(allocator, &docs[0], .{ .schema = .yaml11 });
    defer yaml.freeValue(allocator, &value);
    try std.testing.expect(value.map[0].v == .str or value.map[0].v == .big_int);
}

test "SEC: unique_keys rejects duplicate mapping keys by default" {
    const allocator = std.testing.allocator;
    const input = "{a: 1, a: 2}";
    const result = yaml.loadAll(allocator, input, .{});
    if (result) |docs| {
        for (docs) |*d| d.deinit();
        allocator.free(docs);
        return error.TestExpectedDuplicateKey;
    } else |err| {
        try std.testing.expect(err == error.DuplicateKey);
    }
}

test "SEC: unique_keys=false accepts duplicate mapping keys" {
    const allocator = std.testing.allocator;
    const input = "{a: 1, a: 2}";
    const docs = try yaml.loadAll(allocator, input, .{ .unique_keys = false });
    defer {
        for (docs) |*d| d.deinit();
        allocator.free(docs);
    }
    try std.testing.expectEqual(@as(usize, 1), docs.len);
}

test "SEC: unique_keys isolates keys across nesting levels" {
    const allocator = std.testing.allocator;
    // Inner 'a' must NOT collide with outer 'a' (per-depth set isolation).
    try resolveAndFree(allocator, "{a: {a: 1}}", .{});
    // Sibling nested mappings reusing a key name at the same depth are fine.
    try resolveAndFree(allocator, "{x: {k: 1}, y: {k: 2}}", .{});
    // A genuine duplicate inside a nested mapping still rejects.
    const r = yaml.loadAll(allocator, "{p: {a: 1, a: 2}}", .{});
    if (r) |docs| {
        for (docs) |*d| d.deinit();
        allocator.free(docs);
        return error.TestExpectedDuplicateKey;
    } else |err| {
        try std.testing.expect(err == error.DuplicateKey);
    }
}

test "SEC F-08: many-document stream composes/resolves/frees cleanly" {
    const allocator = std.testing.allocator;
    // 64 documents forces the composer's documents ArrayList to reallocate
    // several times. A stored pointer into it would dangle; an index stays
    // valid. Resolve + free every document under the checking allocator.
    var input = std.ArrayList(u8).empty;
    defer input.deinit(allocator);
    var i: usize = 0;
    while (i < 64) : (i += 1) {
        var num_buf: [16]u8 = undefined;
        const num = std.fmt.bufPrint(&num_buf, "{d}", .{i}) catch unreachable;
        try input.appendSlice(allocator, "---\nk: ");
        try input.appendSlice(allocator, num);
        try input.append(allocator, '\n');
    }

    const docs = try yaml.loadAll(allocator, input.items, .{});
    defer {
        for (docs) |*d| d.deinit();
        allocator.free(docs);
    }
    try std.testing.expectEqual(@as(usize, 64), docs.len);

    for (docs) |*doc| {
        var value = try yaml.resolveToValue(allocator, doc, .{});
        yaml.freeValue(allocator, &value);
    }
}

// ============================================================================
// Schema compliance regression tests (GAP-0007 / GAP-0008 / GAP-0009)
// ============================================================================

/// Resolve a single-scalar document to its Value (caller must freeValue).
fn resolveScalar(allocator: std.mem.Allocator, input: []const u8, opts: yaml.ParseOptions) !yaml.Value {
    const docs = try yaml.loadAll(allocator, input, opts);
    defer {
        for (docs) |*d| d.deinit();
        allocator.free(docs);
    }
    return try yaml.resolveToValue(allocator, &docs[0], opts);
}

test "GAP-0007: core schema rejects leading-zero decimals as int" {
    const allocator = std.testing.allocator;
    // 0755 is NOT a core integer -> string "0755".
    {
        var v = try resolveScalar(allocator, "0755\n", .{ .schema = .core });
        defer yaml.freeValue(allocator, &v);
        try std.testing.expect(v == .str);
        try std.testing.expectEqualStrings("0755", v.str);
    }
    // 0o755 -> int 493
    {
        var v = try resolveScalar(allocator, "0o755\n", .{ .schema = .core });
        defer yaml.freeValue(allocator, &v);
        try std.testing.expect(v == .int);
        try std.testing.expectEqual(@as(i64, 493), v.int);
    }
    // 0x1F -> int 31
    {
        var v = try resolveScalar(allocator, "0x1F\n", .{ .schema = .core });
        defer yaml.freeValue(allocator, &v);
        try std.testing.expect(v == .int);
        try std.testing.expectEqual(@as(i64, 31), v.int);
    }
    // plain decimal still works
    {
        var v = try resolveScalar(allocator, "42\n", .{ .schema = .core });
        defer yaml.freeValue(allocator, &v);
        try std.testing.expect(v == .int);
        try std.testing.expectEqual(@as(i64, 42), v.int);
    }
}

test "GAP-0008: json schema only resolves JSON-legal numbers" {
    const allocator = std.testing.allocator;
    const Case = struct { in: []const u8, is_str: bool };
    const cases = [_]Case{
        .{ .in = "0xff\n", .is_str = true }, // hex int -> string
        .{ .in = "0o755\n", .is_str = true }, // octal int -> string
        .{ .in = "0x1.8p3\n", .is_str = true }, // hex float -> string
        .{ .in = "0755\n", .is_str = true }, // leading-zero -> string
        .{ .in = "42\n", .is_str = false }, // decimal int -> int
        .{ .in = "1.5\n", .is_str = false }, // float -> float
        .{ .in = "1e3\n", .is_str = false }, // exp float -> float
    };
    for (cases) |c| {
        var v = try resolveScalar(allocator, c.in, .{ .schema = .json });
        defer yaml.freeValue(allocator, &v);
        if (c.is_str) {
            try std.testing.expect(v == .str);
        } else {
            try std.testing.expect(v == .int or v == .float);
        }
    }
}

test "GAP-0009: out-of-range plain integer resolves to big_int" {
    const allocator = std.testing.allocator;
    // 20+ digit integer exceeds i64 -> big_int (preserving digits), not string.
    {
        var v = try resolveScalar(allocator, "99999999999999999999\n", .{ .schema = .core });
        defer yaml.freeValue(allocator, &v);
        try std.testing.expect(v == .big_int);
        try std.testing.expectEqualStrings("99999999999999999999", v.big_int);
    }
    // json schema likewise preserves big integers
    {
        var v = try resolveScalar(allocator, "123456789012345678901234567890\n", .{ .schema = .json });
        defer yaml.freeValue(allocator, &v);
        try std.testing.expect(v == .big_int);
    }
}

// ============================================================================
// Line-folding compliance (GAP-0010 folded block, GAP-0011 quoted/plain)
// ============================================================================

test "GAP-0010: folded scalar preserves breaks around more-indented lines" {
    const allocator = std.testing.allocator;
    const input =
        \\fold: >
        \\  a
        \\  b
        \\    c
        \\  d
        \\
    ;
    var v = try resolveScalar(allocator, input, .{});
    defer yaml.freeValue(allocator, &v);
    const s = v.map[0].v.str;
    // a and b fold to a space; the more-indented "c" keeps its break + indent;
    // the break after c (prev line more-indented) is also preserved.
    try std.testing.expect(std.mem.indexOf(u8, s, "a b") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "\n  c") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "c\nd") != null);
    // c must NOT be folded onto b's line.
    try std.testing.expect(std.mem.indexOf(u8, s, "b c") == null);
}

test "GAP-0011: double-quoted multi-line folds breaks per spec" {
    const allocator = std.testing.allocator;
    // Single break -> space.
    {
        var v = try resolveScalar(allocator, "key: \"a\n  b\"\n", .{});
        defer yaml.freeValue(allocator, &v);
        try std.testing.expectEqualStrings("a b", v.map[0].v.str);
    }
    // Blank line (2 breaks) -> 1 newline.
    {
        var v = try resolveScalar(allocator, "key: \"a\n\n  b\"\n", .{});
        defer yaml.freeValue(allocator, &v);
        try std.testing.expectEqualStrings("a\nb", v.map[0].v.str);
    }
}

test "GAP-0011: single-quoted multi-line folds breaks per spec" {
    const allocator = std.testing.allocator;
    {
        var v = try resolveScalar(allocator, "key: 'a\n  b'\n", .{});
        defer yaml.freeValue(allocator, &v);
        try std.testing.expectEqualStrings("a b", v.map[0].v.str);
    }
    {
        var v = try resolveScalar(allocator, "key: 'a\n\n  b'\n", .{});
        defer yaml.freeValue(allocator, &v);
        try std.testing.expectEqualStrings("a\nb", v.map[0].v.str);
    }
}

test "GAP-0011: flow plain multi-line folds breaks per spec" {
    const allocator = std.testing.allocator;
    // Single break inside a flow-plain scalar folds to a space.
    {
        var v = try resolveScalar(allocator, "[a\n b]\n", .{});
        defer yaml.freeValue(allocator, &v);
        try std.testing.expect(v.seq.len == 1);
        try std.testing.expectEqualStrings("a b", v.seq[0].str);
    }
    // Blank line folds to a newline.
    {
        var v = try resolveScalar(allocator, "[a\n\n b]\n", .{});
        defer yaml.freeValue(allocator, &v);
        try std.testing.expect(v.seq.len == 1);
        try std.testing.expectEqualStrings("a\nb", v.seq[0].str);
    }
}

// ============================================================================
// Validation gaps (GAP-0005 pattern, GAP-0015 int_range big_int, GAP-0016 one_of)
// ============================================================================

test "GAP-0005: pattern constraint performs real matching" {
    const allocator = std.testing.allocator;
    const s = yaml.schema.pattern("v?.*");
    {
        var r = try yaml.validateValue(allocator, .{ .str = "v1.2.3" }, s);
        defer r.deinit(allocator);
        try std.testing.expect(r.valid);
    }
    {
        var r = try yaml.validateValue(allocator, .{ .str = "x1.2.3" }, s);
        defer r.deinit(allocator);
        try std.testing.expect(!r.valid);
    }
}

test "GAP-0016: one_of public builder works" {
    const allocator = std.testing.allocator;
    const int_s: yaml.ValidationSchema = yaml.schema.int;
    const str_s: yaml.ValidationSchema = yaml.schema.str;
    const alts = [_]*const yaml.ValidationSchema{ &int_s, &str_s };
    const s = yaml.schema.oneOf(&alts);
    {
        var r = try yaml.validateValue(allocator, .{ .int = 5 }, s);
        defer r.deinit(allocator);
        try std.testing.expect(r.valid);
    }
    {
        var r = try yaml.validateValue(allocator, .{ .str = "hi" }, s);
        defer r.deinit(allocator);
        try std.testing.expect(r.valid);
    }
    {
        var r = try yaml.validateValue(allocator, .{ .bool = true }, s);
        defer r.deinit(allocator);
        try std.testing.expect(!r.valid);
    }
}

test "GAP-0015: int_range validates big_int consistently" {
    const allocator = std.testing.allocator;
    const s = yaml.schema.intRange(0, 100);
    // A positive big_int exceeds any i64 max -> above maximum (invalid).
    {
        var r = try yaml.validateValue(allocator, .{ .big_int = "99999999999999999999" }, s);
        defer r.deinit(allocator);
        try std.testing.expect(!r.valid);
    }
    // With only a min bound, a positive big_int satisfies it (valid).
    {
        const s2 = yaml.schema.intRange(0, null);
        var r = try yaml.validateValue(allocator, .{ .big_int = "99999999999999999999" }, s2);
        defer r.deinit(allocator);
        try std.testing.expect(r.valid);
    }
}

// ============================================================================
// Emitter + JSON gaps (GAP-0004 max_line_width, GAP-0017 toJson complex keys)
// ============================================================================

test "GAP-0004: max_line_width wraps flow collections" {
    const allocator = std.testing.allocator;
    // A flow sequence of many short items; with a small width it must wrap.
    var items: [20]yaml.Value = undefined;
    for (&items, 0..) |*it, i| {
        _ = i;
        it.* = .{ .int = 7 };
    }
    const seq = yaml.Value{ .seq = &items };
    const out = try yaml.dumpAll(allocator, &.{seq}, .{ .collection_style = .flow, .max_line_width = 20 });
    defer allocator.free(out);

    // The flow collection must have wrapped (contain an internal newline) and
    // no line may run away far beyond the configured width.
    var saw_wrap = false;
    var line_iter = std.mem.splitScalar(u8, out, '\n');
    while (line_iter.next()) |line| {
        if (std.mem.indexOfScalar(u8, line, ',') != null and std.mem.indexOfScalar(u8, line, ']') == null) saw_wrap = true;
        try std.testing.expect(line.len <= 20 + 8); // width + small margin for one item
    }
    try std.testing.expect(saw_wrap);
}

test "GAP-0004: max_line_width=0 keeps flow on one line" {
    const allocator = std.testing.allocator;
    var three = [_]yaml.Value{ .{ .int = 1 }, .{ .int = 2 }, .{ .int = 3 } };
    const seq = yaml.Value{ .seq = &three };
    const out = try yaml.dumpAll(allocator, &.{seq}, .{ .collection_style = .flow, .max_line_width = 0, .doc_start = false, .doc_end = false });
    defer allocator.free(out);
    // No wrapping inside the brackets.
    try std.testing.expect(std.mem.indexOf(u8, out, "[1, 2, 3]") != null);
}

test "GAP-0017: toJson rejects non-scalar map keys" {
    const allocator = std.testing.allocator;
    // A map whose key is itself a sequence cannot be a JSON key.
    var key_items = [_]yaml.Value{.{ .int = 1 }};
    const pair = yaml.ValueKVPair{ .k = .{ .seq = &key_items }, .v = .{ .int = 2 } };
    var pairs = [_]yaml.ValueKVPair{pair};
    const map = yaml.Value{ .map = &pairs };
    try std.testing.expectError(error.UnsupportedKey, yaml.toJson(allocator, map, .{}));
}

test "GAP-0017: toJson stringifies big_int keys uniquely" {
    const allocator = std.testing.allocator;
    var pairs = [_]yaml.ValueKVPair{
        .{ .k = .{ .big_int = "99999999999999999999" }, .v = .{ .int = 1 } },
    };
    const map = yaml.Value{ .map = &pairs };
    const out = try yaml.toJson(allocator, map, .{});
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "99999999999999999999") != null);
}

// ============================================================================
// %YAML directive version handling (GAP-0006)
// ============================================================================

test "GAP-0006: %YAML 1.x versions are accepted" {
    const allocator = std.testing.allocator;
    for ([_][]const u8{ "%YAML 1.1\n---\nfoo\n", "%YAML 1.2\n---\nfoo\n", "%YAML 1.3\n---\nfoo\n" }) |input| {
        const docs = try yaml.loadAll(allocator, input, .{});
        defer {
            for (docs) |*d| d.deinit();
            allocator.free(docs);
        }
        try std.testing.expectEqual(@as(usize, 1), docs.len);
    }
}

test "GAP-0006: unsupported %YAML major version is refused" {
    const allocator = std.testing.allocator;
    // loadAll surfaces it as a parse failure.
    try std.testing.expectError(error.ParseFailed, yaml.loadAll(allocator, "%YAML 2.0\n---\nfoo\n", .{}));
    // loadAllWithDetails reports the specific, documented error code.
    const result = yaml.loadAllWithDetails(allocator, "%YAML 2.0\n---\nfoo\n", .{});
    try std.testing.expect(result.parse_error != null);
    try std.testing.expectEqual(yaml.ErrorCode.unsupported_yaml_version, result.parse_error.?.code);
}

// ============================================================================
// Tag convention (GAP-0014) and complex keys (GAP-0012)
// ============================================================================

test "GAP-0014: plain scalar carries the '?' non-specific tag" {
    const allocator = std.testing.allocator;
    var p = try yaml.Parser.init(allocator, "foo\n", .{});
    defer p.deinit();
    // stream_start, doc_start, then the scalar.
    _ = try p.nextEvent();
    _ = try p.nextEvent();
    const ev = try p.nextEvent();
    try std.testing.expect(ev == .scalar);
    try std.testing.expectEqualStrings("?", ev.scalar.meta.tag);
    // The public NodeMeta default matches the runtime convention.
    try std.testing.expectEqualStrings("?", (yaml.NodeMeta{}).tag);
}

test "GAP-0012: explicit complex keys parse and resolve" {
    const allocator = std.testing.allocator;
    // Collection-valued key bound to a value via '?'/':' at matching indent.
    const input =
        \\? [a, b]
        \\: value
    ;
    const docs = try yaml.loadAll(allocator, input, .{});
    defer {
        for (docs) |*d| d.deinit();
        allocator.free(docs);
    }
    var v = try yaml.resolveToValue(allocator, &docs[0], .{});
    defer yaml.freeValue(allocator, &v);
    try std.testing.expect(v == .map);
    try std.testing.expectEqual(@as(usize, 1), v.map.len);
    // Key is the sequence [a, b]; value is "value".
    try std.testing.expect(v.map[0].k == .seq);
    try std.testing.expectEqual(@as(usize, 2), v.map[0].k.seq.len);
    try std.testing.expect(v.map[0].v == .str);
    try std.testing.expectEqualStrings("value", v.map[0].v.str);
}

test "GAP-0012: mapping-valued complex key parses and resolves" {
    const allocator = std.testing.allocator;
    const input =
        \\? {x: 1}
        \\: value
    ;
    const docs = try yaml.loadAll(allocator, input, .{});
    defer {
        for (docs) |*d| d.deinit();
        allocator.free(docs);
    }
    var v = try yaml.resolveToValue(allocator, &docs[0], .{});
    defer yaml.freeValue(allocator, &v);
    try std.testing.expect(v == .map);
    try std.testing.expect(v.map[0].k == .map);
    try std.testing.expect(v.map[0].v == .str);
    try std.testing.expectEqualStrings("value", v.map[0].v.str);
}

test "GAP-0012: multi-line block-scalar complex key parses and resolves" {
    const allocator = std.testing.allocator;
    const input = "? |-\n  multi\n  line\n: value\n";
    const docs = try yaml.loadAll(allocator, input, .{});
    defer {
        for (docs) |*d| d.deinit();
        allocator.free(docs);
    }
    var v = try yaml.resolveToValue(allocator, &docs[0], .{});
    defer yaml.freeValue(allocator, &v);
    try std.testing.expect(v == .map);
    try std.testing.expect(v.map[0].k == .str);
    try std.testing.expectEqualStrings("multi\nline", v.map[0].k.str);
    try std.testing.expectEqualStrings("value", v.map[0].v.str);
}

// ============================================================================
// Round-trip alias behavior (GAP-0013, documented inlining)
// ============================================================================

test "GAP-0013: dumpAll inlines aliases (documented behavior)" {
    const allocator = std.testing.allocator;
    const docs = try yaml.loadAll(allocator, "base: &B {x: 1}\nuse: *B\n", .{});
    defer {
        for (docs) |*d| d.deinit();
        allocator.free(docs);
    }
    var v = try yaml.resolveToValue(allocator, &docs[0], .{});
    defer yaml.freeValue(allocator, &v);
    const out = try yaml.dumpAll(allocator, &.{v}, .{});
    defer allocator.free(out);
    // Aliases are expanded during resolution, so emission inlines them: no
    // anchor (&) or alias (*) markers, and the aliased mapping appears twice.
    try std.testing.expect(std.mem.indexOfScalar(u8, out, '&') == null);
    try std.testing.expect(std.mem.indexOfScalar(u8, out, '*') == null);
    var count: usize = 0;
    var idx: usize = 0;
    while (std.mem.indexOfPos(u8, out, idx, "x: 1")) |p| {
        count += 1;
        idx = p + 1;
    }
    try std.testing.expectEqual(@as(usize, 2), count);
}

// ============================================================================
// Quality follow-ups (QUAL-0021 leading-break, QUAL-0023 i64::MIN)
// ============================================================================

test "QUAL-0021: quoted scalar with leading line break has no spurious space" {
    const allocator = std.testing.allocator;
    {
        var v = try resolveScalar(allocator, "key: \"\n  foo\"\n", .{});
        defer yaml.freeValue(allocator, &v);
        try std.testing.expectEqualStrings("foo", v.map[0].v.str);
    }
    {
        var v = try resolveScalar(allocator, "key: '\n  foo'\n", .{});
        defer yaml.freeValue(allocator, &v);
        try std.testing.expectEqualStrings("foo", v.map[0].v.str);
    }
}

test "QUAL-0023: i64::MIN resolves to int, not big_int" {
    const allocator = std.testing.allocator;
    {
        var v = try resolveScalar(allocator, "-9223372036854775808\n", .{ .schema = .core });
        defer yaml.freeValue(allocator, &v);
        try std.testing.expect(v == .int);
        try std.testing.expectEqual(@as(i64, std.math.minInt(i64)), v.int);
    }
    {
        var v = try resolveScalar(allocator, "-9223372036854775808\n", .{ .schema = .json });
        defer yaml.freeValue(allocator, &v);
        try std.testing.expect(v == .int);
        try std.testing.expectEqual(@as(i64, std.math.minInt(i64)), v.int);
    }
}
