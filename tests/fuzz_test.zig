// SPDX-License-Identifier: MIT
// Copyright (c) 2024 DevNW

//! YAML Parser Fuzz/Robustness Tests
//! Tests parser robustness with arbitrary inputs.
//!
//! Run corpus tests with: zig build test-fuzz
//!
//! These tests verify that the parser handles all kinds of inputs
//! gracefully without crashing or causing undefined behavior.

const std = @import("std");
const yaml = @import("yaml");

const Allocator = std.mem.Allocator;

// ============================================================================
// Test Helpers
// ============================================================================

/// Parse input and ensure no crashes or undefined behavior
fn parseAndFree(allocator: Allocator, input: []const u8) void {
    // Try to parse with reasonable limits to avoid OOM during testing
    const opts = yaml.ParseOptions{
        .max_bytes = 64 * 1024, // 64KB max
        .max_depth = 50,
        .max_nodes = 10_000,
        .max_aliases = 100,
    };

    // loadAll should either succeed or return a well-defined error
    const docs = yaml.loadAll(allocator, input, opts) catch {
        // All errors are expected possibilities
        return;
    };

    // If parsing succeeded, properly clean up
    defer {
        for (docs) |*d| d.deinit();
        allocator.free(docs);
    }

    // Try to resolve to values
    for (docs) |*doc| {
        var value = yaml.resolveToValue(allocator, doc, opts) catch {
            // Resolution errors are fine
            continue;
        };
        yaml.freeValue(allocator, &value);
    }
}

/// Parse using the streaming API
fn parseStreaming(allocator: Allocator, input: []const u8) void {
    const opts = yaml.ParseOptions{
        .max_bytes = 64 * 1024,
        .max_depth = 50,
        .max_nodes = 10_000,
        .max_aliases = 100,
    };

    var parser = yaml.Parser.init(allocator, input, opts) catch {
        return;
    };
    defer parser.deinit();

    // Consume all events
    while (true) {
        const event = parser.nextEvent() catch {
            // Errors are fine
            break;
        };
        if (event == .stream_end) break;
    }
}

// ============================================================================
// Corpus-based Tests
// ============================================================================

test "corpus: edge cases" {
    const allocator = std.testing.allocator;

    // Collection of known edge cases and potentially problematic inputs
    const corpus = [_][]const u8{
        // Empty and minimal inputs
        "",
        "\n",
        " ",
        "\t",
        "---",
        "...",
        "---\n...",

        // Null variations
        "~",
        "null",
        "Null",
        "NULL",

        // Boolean variations
        "true",
        "false",
        "True",
        "False",
        "TRUE",
        "FALSE",

        // Number edge cases
        "0",
        "-0",
        "+0",
        "0.0",
        ".inf",
        "-.inf",
        ".nan",
        "0x0",
        "0o0",
        "1e100",
        "1e-100",

        // String edge cases
        "''",
        "\"\"",
        "'\\n'",
        "\"\\n\"",
        "|\n  text",
        ">\n  text",
        "|+\n  text",
        "|-\n  text",

        // Collection edge cases
        "[]",
        "{}",
        "[,]",
        "{,}",
        "- ",
        ": ",
        "a: ",
        ": b",

        // Nested structures
        "[[[]]]",
        "{{{}}}",
        "- - - a",
        "a:\n  b:\n    c: d",

        // Anchors and aliases
        "&a null",
        "*a",
        "&a *a",
        "- &a\n- *a",

        // Tags
        "!foo bar",
        "!!str 123",
        "!<!foo> bar",

        // Directives
        "%YAML 1.2",
        "%TAG ! tag:",
        "%YAML 1.2\n---",

        // Special characters
        "a#b",
        "a: #comment",
        "a: b #comment",

        // Multiline
        "a: |\n  line1\n  line2",
        "a: >\n  line1\n  line2",

        // Flow collections
        "[a, b, c]",
        "{a: 1, b: 2}",
        "[{a: 1}, {b: 2}]",
        "{a: [1, 2], b: [3, 4]}",

        // Unicode
        "\\u0000",
        "\\U00000000",
        "\xC0\x80", // Overlong encoding
        "\xED\xA0\x80", // Surrogate half

        // Potential crash inputs from common parsers
        "---\n...\n---",
        "!!binary |\n  R0lGODlh",
        "*",
        "&",
        "!",
        "?",
        ":",
        "-",
        "[",
        "]",
        "{",
        "}",
        "'",
        "\"",
        "|",
        ">",
        "%",
        "@",
        "`",

        // Deeply nested (within limits)
        "- - - - - - - - - - a",
        "a: {b: {c: {d: {e: {f: g}}}}}",

        // Large scalars (small for testing)
        "a" ** 100,
        "- " ** 50,

        // Mixed indentation edge cases
        "a:\n b:\n  c: d",
        "a:\n\tb: c",

        // Document boundaries
        "---\na: 1\n---\nb: 2",
        "...\n---",
    };

    for (corpus) |input| {
        parseAndFree(allocator, input);
        parseStreaming(allocator, input);
    }
}

test "corpus: malformed inputs" {
    const allocator = std.testing.allocator;

    // Inputs that should definitely fail but not crash
    const malformed = [_][]const u8{
        // Unterminated strings
        "'unterminated",
        "\"unterminated",

        // Invalid escape sequences
        "\"\\q\"",
        "\"\\xGG\"",
        "\"\\uGGGG\"",

        // Invalid indentation
        "a:\n b: c\n  d: e",

        // Tab in indentation
        "a:\n\tb: c",

        // Invalid anchors
        "&",
        "& anchor",
        "&123 value",

        // Invalid aliases
        "*",
        "* alias",

        // Invalid tags
        "! value",
        "!! value",
        "!<> value",

        // Invalid directives
        "%",
        "%INVALID",
        "%YAML",
        "%YAML x.y",

        // Duplicate keys (if strict mode)
        "a: 1\na: 2",

        // Circular aliases
        "&a *a",

        // Block scalar issues
        "|x\n  text",
        ">x\n  text",
        "|0\n  text",

        // Flow collection issues
        "[a: 1: 2]",
        "{a, b}",
        "[}",
        "{]",
    };

    for (malformed) |input| {
        // These should fail gracefully
        parseAndFree(allocator, input);
        parseStreaming(allocator, input);
    }
}

test "corpus: binary data" {
    const allocator = std.testing.allocator;

    // Binary/random data patterns
    var prng = std.Random.DefaultPrng.init(0x12345678);
    const random = prng.random();

    var buf: [256]u8 = undefined;

    // Test with various lengths of random data
    const lengths = [_]usize{ 1, 2, 4, 8, 16, 32, 64, 128, 256 };
    for (lengths) |len| {
        random.bytes(buf[0..len]);
        parseAndFree(allocator, buf[0..len]);
        parseStreaming(allocator, buf[0..len]);
    }
}

test "corpus: repeated patterns" {
    const allocator = std.testing.allocator;

    // Patterns that might trigger edge cases through repetition
    const patterns = [_][]const u8{
        "- ",
        "a: ",
        "  ",
        "\n",
        "---\n",
        "...\n",
        "&a ",
        "*a ",
        "!tag ",
    };

    for (patterns) |pattern| {
        // Build up repeated patterns
        var buf: [1024]u8 = undefined;
        var len: usize = 0;

        while (len + pattern.len <= buf.len) {
            @memcpy(buf[len..][0..pattern.len], pattern);
            len += pattern.len;
        }

        if (len > 0) {
            parseAndFree(allocator, buf[0..len]);
            parseStreaming(allocator, buf[0..len]);
        }
    }
}

test "corpus: stress large nesting" {
    const allocator = std.testing.allocator;

    // Test deep nesting within limits
    var buf: [512]u8 = undefined;

    // Deep sequence nesting: - - - - - value
    for (0..20) |depth| {
        var pos: usize = 0;
        for (0..depth) |_| {
            @memcpy(buf[pos..][0..2], "- ");
            pos += 2;
        }
        @memcpy(buf[pos..][0..5], "value");
        pos += 5;

        parseAndFree(allocator, buf[0..pos]);
        parseStreaming(allocator, buf[0..pos]);
    }

    // Deep map nesting: a:\n  b:\n    c: value
    for (1..10) |depth| {
        var pos: usize = 0;
        for (0..depth) |i| {
            // Add key
            buf[pos] = 'a' + @as(u8, @intCast(i % 26));
            pos += 1;
            buf[pos] = ':';
            pos += 1;
            buf[pos] = '\n';
            pos += 1;
            // Add indent for next level
            for (0..(i + 1) * 2) |_| {
                buf[pos] = ' ';
                pos += 1;
            }
        }
        @memcpy(buf[pos..][0..5], "value");
        pos += 5;

        parseAndFree(allocator, buf[0..pos]);
        parseStreaming(allocator, buf[0..pos]);
    }
}

test "corpus: unicode edge cases" {
    const allocator = std.testing.allocator;

    const unicode_tests = [_][]const u8{
        // Valid UTF-8 sequences
        "hello",
        "\xC2\xA9", // Copyright symbol
        "\xE2\x9C\x93", // Check mark
        "\xF0\x9F\x98\x80", // Emoji (grinning face)

        // BOM
        "\xEF\xBB\xBFhello",

        // Common characters that need escaping
        "colon: value",
        "hash # comment",
        "quote: 'single'",
        "quote: \"double\"",

        // Non-printable characters
        "bell\x07here",
        "tab\there",
        "newline\nhere",

        // Edge of valid ranges
        "\x7F", // DEL
        "\xC2\x80", // First 2-byte sequence
        "\xDF\xBF", // Last 2-byte sequence
        "\xE0\xA0\x80", // First 3-byte sequence
        "\xEF\xBF\xBD", // Replacement character
    };

    for (unicode_tests) |input| {
        parseAndFree(allocator, input);
        parseStreaming(allocator, input);
    }
}
