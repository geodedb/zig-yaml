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
