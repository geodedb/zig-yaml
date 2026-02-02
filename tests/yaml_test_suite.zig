// SPDX-License-Identifier: MIT
// Copyright (c) 2024 DevNW

//! YAML Test Suite Runner
//! Runs tests from the official yaml-test-suite against our parser.
//! See: https://github.com/yaml/yaml-test-suite

const std = @import("std");
const yaml = @import("yaml");

const TestResult = struct {
    id: []const u8,
    name: []const u8,
    passed: bool,
    expected_fail: bool,
    actual_fail: bool,
    error_msg: ?[]const u8,
};

const TestStats = struct {
    total: usize = 0,
    passed: usize = 0,
    failed: usize = 0,
    skipped: usize = 0,
    expected_failures: usize = 0,
    unexpected_failures: usize = 0,
    unexpected_passes: usize = 0,
};

/// Convert parser events to the test.event format used by yaml-test-suite
fn eventsToTreeFormat(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var parser = yaml.Parser.init(allocator, input, .{}) catch |err| {
        return std.fmt.allocPrint(allocator, "ERROR: {}", .{err});
    };
    defer parser.deinit();

    var result = std.ArrayList(u8){};
    errdefer result.deinit(allocator);

    while (true) {
        const event = parser.nextEvent() catch |err| {
            try result.appendSlice(allocator, "ERROR\n");
            _ = err;
            break;
        };

        switch (event) {
            .stream_start => try result.appendSlice(allocator, "+STR\n"),
            .stream_end => {
                try result.appendSlice(allocator, "-STR\n");
                break;
            },
            .doc_start => try result.appendSlice(allocator, " +DOC\n"),
            .doc_end => try result.appendSlice(allocator, " -DOC\n"),
            .seq_start => |meta| {
                try result.appendSlice(allocator, "  +SEQ");
                try writeNodeMeta(allocator, &result, meta);
                try result.append(allocator, '\n');
            },
            .seq_end => try result.appendSlice(allocator, "  -SEQ\n"),
            .map_start => |meta| {
                try result.appendSlice(allocator, "  +MAP");
                try writeNodeMeta(allocator, &result, meta);
                try result.append(allocator, '\n');
            },
            .map_end => try result.appendSlice(allocator, "  -MAP\n"),
            .scalar => |s| {
                try result.appendSlice(allocator, "   =VAL");
                try writeNodeMeta(allocator, &result, s.meta);
                try result.appendSlice(allocator, " :");
                try writeEscapedValue(allocator, &result, s.value);
                try result.append(allocator, '\n');
            },
            .alias => |name| {
                try result.appendSlice(allocator, "   *ALI ");
                try result.appendSlice(allocator, name);
                try result.append(allocator, '\n');
            },
        }
    }

    return result.toOwnedSlice(allocator);
}

fn writeNodeMeta(allocator: std.mem.Allocator, result: *std.ArrayList(u8), meta: yaml.NodeMeta) !void {
    if (meta.anchor) |anchor| {
        try result.appendSlice(allocator, " &");
        try result.appendSlice(allocator, anchor);
    }
    // Write tag if not implicit (? means no explicit tag)
    if (!std.mem.eql(u8, meta.tag, "?") and meta.tag.len > 0) {
        try result.appendSlice(allocator, " <");
        try result.appendSlice(allocator, meta.tag);
        try result.append(allocator, '>');
    }
}

fn writeEscapedValue(allocator: std.mem.Allocator, result: *std.ArrayList(u8), value: []const u8) !void {
    for (value) |c| {
        switch (c) {
            '\n' => try result.appendSlice(allocator, "\\n"),
            '\t' => try result.appendSlice(allocator, "\\t"),
            '\\' => try result.appendSlice(allocator, "\\\\"),
            else => try result.append(allocator, c),
        }
    }
}

/// Extract test cases from a parsed YAML test suite file
fn extractTestCases(allocator: std.mem.Allocator, file_content: []const u8, file_id: []const u8) ![]TestCase {
    var cases = std.ArrayList(TestCase){};
    errdefer cases.deinit(allocator);

    // Parse the test file (it's a YAML sequence of test documents)
    const docs = yaml.loadAll(allocator, file_content, .{}) catch |err| {
        std.debug.print("Failed to parse test file {s}: {}\n", .{ file_id, err });
        return cases.toOwnedSlice(allocator);
    };
    defer {
        for (docs) |*d| d.deinit();
        allocator.free(docs);
    }

    // Each document should be a sequence of test cases
    for (docs) |*doc| {
        var value = yaml.resolveToValue(allocator, doc, .{}) catch continue;
        defer yaml.freeValue(allocator, &value);

        // Check if it's a sequence (multiple tests) or a map (single test)
        switch (value) {
            .seq => |items| {
                for (items, 0..) |item, idx| {
                    if (extractSingleTestCase(allocator, item, file_id, idx)) |tc| {
                        try cases.append(allocator, tc);
                    }
                }
            },
            .map => {
                if (extractSingleTestCase(allocator, value, file_id, 0)) |tc| {
                    try cases.append(allocator, tc);
                }
            },
            else => {},
        }
    }

    return cases.toOwnedSlice(allocator);
}

const TestCase = struct {
    id: []const u8,
    name: []const u8,
    yaml_input: []const u8,
    expected_tree: []const u8,
    expected_fail: bool,
    allocator: std.mem.Allocator,

    fn deinit(self: *TestCase) void {
        self.allocator.free(self.id);
        self.allocator.free(self.name);
        self.allocator.free(self.yaml_input);
        self.allocator.free(self.expected_tree);
    }
};

fn extractSingleTestCase(allocator: std.mem.Allocator, value: yaml.Value, file_id: []const u8, idx: usize) ?TestCase {
    switch (value) {
        .map => |items| {
            var name: ?[]const u8 = null;
            var yaml_input: ?[]const u8 = null;
            var expected_tree: ?[]const u8 = null;
            var expected_fail: bool = false;

            for (items) |pair| {
                const key_str = switch (pair.k) {
                    .str => |s| s,
                    else => continue,
                };

                if (std.mem.eql(u8, key_str, "name")) {
                    name = switch (pair.v) {
                        .str => |s| s,
                        else => null,
                    };
                } else if (std.mem.eql(u8, key_str, "yaml")) {
                    yaml_input = switch (pair.v) {
                        .str => |s| s,
                        else => null,
                    };
                } else if (std.mem.eql(u8, key_str, "tree")) {
                    expected_tree = switch (pair.v) {
                        .str => |s| s,
                        else => null,
                    };
                } else if (std.mem.eql(u8, key_str, "fail")) {
                    expected_fail = switch (pair.v) {
                        .bool => |b| b,
                        else => false,
                    };
                }
            }

            if (yaml_input) |yi| {
                // Generate ID
                var id_buf = std.mem.zeroes([32]u8);
                const id = std.fmt.bufPrint(&id_buf, "{s}:{d}", .{ file_id, idx }) catch file_id;

                return TestCase{
                    .id = allocator.dupe(u8, id) catch return null,
                    .name = allocator.dupe(u8, name orelse "unnamed") catch return null,
                    .yaml_input = allocator.dupe(u8, yi) catch return null,
                    .expected_tree = allocator.dupe(u8, expected_tree orelse "") catch return null,
                    .expected_fail = expected_fail,
                    .allocator = allocator,
                };
            }
        },
        else => {},
    }
    return null;
}

/// Run a single test case
fn runTestCase(allocator: std.mem.Allocator, tc: *const TestCase, verbose: bool) TestResult {
    // Preprocess YAML input - handle special characters from test suite
    const processed_input = preprocessYamlInput(allocator, tc.yaml_input) catch {
        return TestResult{
            .id = tc.id,
            .name = tc.name,
            .passed = false,
            .expected_fail = tc.expected_fail,
            .actual_fail = true,
            .error_msg = "Failed to preprocess input",
        };
    };
    defer allocator.free(processed_input);

    // Try to parse
    var parser = yaml.Parser.init(allocator, processed_input, .{}) catch {
        // Parse failed during init
        return TestResult{
            .id = tc.id,
            .name = tc.name,
            .passed = tc.expected_fail, // Pass if we expected failure
            .expected_fail = tc.expected_fail,
            .actual_fail = true,
            .error_msg = null,
        };
    };
    defer parser.deinit();

    // Consume all events with a safety limit
    var parse_failed = false;
    var event_count: usize = 0;
    const max_events: usize = 10000;
    while (true) {
        const event = parser.nextEvent() catch {
            parse_failed = true;
            break;
        };
        event_count += 1;
        if (event == .stream_end) break;
        if (event_count > max_events) {
            parse_failed = true;
            break;
        }
    }

    if (parse_failed) {
        if (verbose and !tc.expected_fail) {
            std.debug.print("    UNEXPECTED FAIL: {s} - parser error\n", .{tc.name});
        }
        return TestResult{
            .id = tc.id,
            .name = tc.name,
            .passed = tc.expected_fail,
            .expected_fail = tc.expected_fail,
            .actual_fail = true,
            .error_msg = null,
        };
    }

    // If we expected failure but parsing succeeded, that's unexpected
    if (tc.expected_fail) {
        if (verbose) {
            std.debug.print("    UNEXPECTED PASS: {s} - should have failed\n", .{tc.name});
        }
        return TestResult{
            .id = tc.id,
            .name = tc.name,
            .passed = false,
            .expected_fail = true,
            .actual_fail = false,
            .error_msg = "Expected parse failure but parsing succeeded",
        };
    }

    // Parse succeeded as expected
    return TestResult{
        .id = tc.id,
        .name = tc.name,
        .passed = true,
        .expected_fail = false,
        .actual_fail = false,
        .error_msg = null,
    };
}

/// Preprocess YAML input to handle special test suite characters
fn preprocessYamlInput(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var result = std.ArrayList(u8){};
    errdefer result.deinit(allocator);

    var i: usize = 0;
    while (i < input.len) {
        const c = input[i];

        // Check for multi-byte UTF-8 sequences (special characters)
        if (c >= 0x80) {
            // ␣ (U+2423) = trailing space - 3 bytes: E2 90 A3
            if (i + 2 < input.len and c == 0xE2 and input[i + 1] == 0x90 and input[i + 2] == 0xA3) {
                try result.append(allocator, ' ');
                i += 3;
                continue;
            }
            // ↵ (U+21B5) = trailing newline - 3 bytes: E2 86 B5
            if (i + 2 < input.len and c == 0xE2 and input[i + 1] == 0x86 and input[i + 2] == 0xB5) {
                try result.append(allocator, '\n');
                i += 3;
                continue;
            }
            // ∎ (U+220E) = no final newline - 3 bytes: E2 88 8E - just skip
            if (i + 2 < input.len and c == 0xE2 and input[i + 1] == 0x88 and input[i + 2] == 0x8E) {
                i += 3;
                continue;
            }
            // ← (U+2190) = carriage return - 3 bytes: E2 86 90
            if (i + 2 < input.len and c == 0xE2 and input[i + 1] == 0x86 and input[i + 2] == 0x90) {
                try result.append(allocator, '\r');
                i += 3;
                continue;
            }
            // ⇔ (U+21D4) = BOM - 3 bytes: E2 87 94
            if (i + 2 < input.len and c == 0xE2 and input[i + 1] == 0x87 and input[i + 2] == 0x94) {
                try result.appendSlice(allocator, "\xEF\xBB\xBF"); // UTF-8 BOM
                i += 3;
                continue;
            }
            // Tab representations: » (U+00BB), — (U+2014, em-dash)
            // ————» = tab, ———» = tab, ——» = tab, —» = tab, » = tab
            // — (U+2014) = 3 bytes: E2 80 94, » (U+00BB) = 2 bytes: C2 BB
            // Check for ————» first (4 em-dashes + ») - 14 bytes total
            if (i + 13 < input.len and c == 0xE2 and input[i + 1] == 0x80 and input[i + 2] == 0x94 and
                input[i + 3] == 0xE2 and input[i + 4] == 0x80 and input[i + 5] == 0x94 and
                input[i + 6] == 0xE2 and input[i + 7] == 0x80 and input[i + 8] == 0x94 and
                input[i + 9] == 0xE2 and input[i + 10] == 0x80 and input[i + 11] == 0x94 and
                input[i + 12] == 0xC2 and input[i + 13] == 0xBB)
            {
                try result.append(allocator, '\t');
                i += 14;
                continue;
            }
            // Check for ———» (3 em-dashes + »)
            if (i + 10 < input.len and c == 0xE2 and input[i + 1] == 0x80 and input[i + 2] == 0x94 and
                input[i + 3] == 0xE2 and input[i + 4] == 0x80 and input[i + 5] == 0x94 and
                input[i + 6] == 0xE2 and input[i + 7] == 0x80 and input[i + 8] == 0x94 and
                input[i + 9] == 0xC2 and input[i + 10] == 0xBB)
            {
                try result.append(allocator, '\t');
                i += 11;
                continue;
            }
            // Check for ——» (2 em-dashes + »)
            if (i + 7 < input.len and c == 0xE2 and input[i + 1] == 0x80 and input[i + 2] == 0x94 and
                input[i + 3] == 0xE2 and input[i + 4] == 0x80 and input[i + 5] == 0x94 and
                input[i + 6] == 0xC2 and input[i + 7] == 0xBB)
            {
                try result.append(allocator, '\t');
                i += 8;
                continue;
            }
            // Check for —» (1 em-dash + »)
            if (i + 4 < input.len and c == 0xE2 and input[i + 1] == 0x80 and input[i + 2] == 0x94 and
                input[i + 3] == 0xC2 and input[i + 4] == 0xBB)
            {
                try result.append(allocator, '\t');
                i += 5;
                continue;
            }
            // Check for » alone
            if (c == 0xC2 and i + 1 < input.len and input[i + 1] == 0xBB) {
                try result.append(allocator, '\t');
                i += 2;
                continue;
            }
        }

        try result.append(allocator, c);
        i += 1;
    }

    return result.toOwnedSlice(allocator);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const test_suite_dir = "testdata/yaml-test-suite/src";

    var stats = TestStats{};
    var parse_errors: usize = 0;
    var file_count: usize = 0;

    // Open and iterate through test files
    var dir = std.fs.cwd().openDir(test_suite_dir, .{ .iterate = true }) catch |err| {
        std.debug.print("Failed to open test suite directory: {}\n", .{err});
        return;
    };
    defer dir.close();

    // Collect all files first to sort them
    var files = std.ArrayList([]const u8){};
    defer {
        for (files.items) |f| allocator.free(f);
        files.deinit(allocator);
    }

    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".yaml")) continue;
        try files.append(allocator, try allocator.dupe(u8, entry.name));
    }

    std.debug.print("Found {} test files\n", .{files.items.len});

    // Process all files
    const max_files: usize = files.items.len;

    for (files.items) |name| {
        file_count += 1;

        // Read test file
        const file_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ test_suite_dir, name }) catch continue;
        defer allocator.free(file_path);

        const file_content = std.fs.cwd().readFileAlloc(allocator, file_path, 1024 * 1024) catch continue;
        defer allocator.free(file_content);

        // Extract file ID (without .yaml extension)
        const file_id = name[0 .. name.len - 5];

        // Extract and run test cases
        const cases = extractTestCases(allocator, file_content, file_id) catch |err| {
            std.debug.print("  [{}/{}] {s}: parse error: {}\n", .{ file_count, max_files, file_id, err });
            parse_errors += 1;
            continue;
        };
        defer {
            for (cases) |*c| {
                var tc = c.*;
                tc.deinit();
            }
            allocator.free(cases);
        }

        if (cases.len == 0) {
            std.debug.print("  [{}/{}] {s}: no test cases found\n", .{ file_count, files.items.len, file_id });
            continue;
        }

        var file_passed: usize = 0;
        var file_failed: usize = 0;
        for (cases) |*tc| {
            const result = runTestCase(allocator, tc, true);
            stats.total += 1;

            if (result.passed) {
                stats.passed += 1;
                file_passed += 1;
                if (result.expected_fail) {
                    stats.expected_failures += 1;
                }
            } else {
                stats.failed += 1;
                file_failed += 1;
                if (result.expected_fail and !result.actual_fail) {
                    stats.unexpected_passes += 1;
                } else if (!result.expected_fail and result.actual_fail) {
                    stats.unexpected_failures += 1;
                }
            }
        }
        // Print result immediately instead of storing failed tests
        std.debug.print("  [{}/{}] {s}: {}/{} passed\n", .{ file_count, max_files, file_id, file_passed, cases.len });
    }

    std.debug.print("\n(Skipped {} test files due to parse errors)\n", .{parse_errors});

    // Print summary
    std.debug.print("\n=== YAML Test Suite Results ===\n", .{});
    std.debug.print("Total:               {d}\n", .{stats.total});
    std.debug.print("Passed:              {d}\n", .{stats.passed});
    std.debug.print("Failed:              {d}\n", .{stats.failed});
    std.debug.print("Expected failures:   {d}\n", .{stats.expected_failures});
    std.debug.print("Unexpected failures: {d}\n", .{stats.unexpected_failures});
    std.debug.print("Unexpected passes:   {d}\n", .{stats.unexpected_passes});

    // Don't print failed test details - they reference freed memory

    const pass_rate = if (stats.total > 0) @as(f64, @floatFromInt(stats.passed)) / @as(f64, @floatFromInt(stats.total)) * 100.0 else 0.0;
    std.debug.print("\nPass rate: {d:.1}%\n", .{pass_rate});
}

// Also create a test that can be run with zig build test
test "yaml test suite basic parsing" {
    const allocator = std.testing.allocator;

    // Test a few basic cases inline
    const basic_tests = [_]struct { input: []const u8, should_pass: bool }{
        .{ .input = "key: value", .should_pass = true },
        .{ .input = "- a\n- b\n- c", .should_pass = true },
        .{ .input = "{a: 1, b: 2}", .should_pass = true },
        .{ .input = "[1, 2, 3]", .should_pass = true },
        .{ .input = "---\na: 1\n---\nb: 2", .should_pass = true },
        // Test case from N782 - invalid document markers in flow
        .{ .input = "[\n--- ,\n...\n]", .should_pass = false },
        // PW8X - Anchors on empty scalars
        .{ .input = "- &a\n- a", .should_pass = true },
        // 7ZZ5 - Empty flow collections
        .{ .input = "---\nnested: []\nkey1: {}", .should_pass = true },
    };

    for (basic_tests) |t| {
        var parser = try yaml.Parser.init(allocator, t.input, .{});
        defer parser.deinit();

        var success = true;
        var event_count: usize = 0;
        while (true) {
            const event = parser.nextEvent() catch {
                success = false;
                break;
            };
            event_count += 1;
            if (event == .stream_end) break;
            // Safety: stop after too many events
            if (event_count > 1000) {
                success = false;
                break;
            }
        }

        try std.testing.expectEqual(t.should_pass, success);
    }
}

test "yaml test file loading" {
    const allocator = std.testing.allocator;

    // Test that we can parse a test file with block sequence at root
    const test_input =
        \\- name: Test 1
        \\  yaml: |
        \\    key: value
        \\- name: Test 2
        \\  yaml: |
        \\    other: value
    ;

    // Now try loadAll
    const docs = yaml.loadAll(allocator, test_input, .{}) catch |err| {
        std.debug.print("loadAll error: {}\n", .{err});
        return error.TestFailed;
    };
    defer {
        for (docs) |*d| {
            var doc = d.*;
            doc.deinit();
        }
        allocator.free(docs);
    }

    // Should have 1 document with a sequence at root
    try std.testing.expectEqual(@as(usize, 1), docs.len);

    var value = try yaml.resolveToValue(allocator, &docs[0], .{});
    defer yaml.freeValue(allocator, &value);

    // Should be a sequence, not null
    try std.testing.expect(value != .null);
    try std.testing.expect(value == .seq);
}

test "load actual test file" {
    const allocator = std.testing.allocator;

    // Test MUS6 (multiple test cases without ---)
    {
        const content = std.fs.cwd().readFileAlloc(allocator, "testdata/yaml-test-suite/src/MUS6.yaml", 64 * 1024) catch return;
        defer allocator.free(content);

        const docs = yaml.loadAll(allocator, content, .{}) catch |err| {
            std.debug.print("MUS6 loadAll error: {}\n", .{err});
            return error.TestFailed;
        };
        defer {
            for (docs) |*d| {
                var doc = d.*;
                doc.deinit();
            }
            allocator.free(docs);
        }

        try std.testing.expect(docs.len >= 1);
        var value = try yaml.resolveToValue(allocator, &docs[0], .{});
        defer yaml.freeValue(allocator, &value);
        try std.testing.expect(value == .seq);
        try std.testing.expect(value.seq.len == 7);
    }

    // Test N782 (block literal containing --- and ...)
    {
        const content = std.fs.cwd().readFileAlloc(allocator, "testdata/yaml-test-suite/src/N782.yaml", 64 * 1024) catch return;
        defer allocator.free(content);

        const docs = yaml.loadAll(allocator, content, .{}) catch |err| {
            std.debug.print("N782 loadAll error: {}\n", .{err});
            return error.TestFailed;
        };
        defer {
            for (docs) |*d| {
                var doc = d.*;
                doc.deinit();
            }
            allocator.free(docs);
        }

        try std.testing.expect(docs.len >= 1);
        var value = try yaml.resolveToValue(allocator, &docs[0], .{});
        defer yaml.freeValue(allocator, &value);
        try std.testing.expect(value == .seq);
        try std.testing.expect(value.seq.len == 1);
    }
}
