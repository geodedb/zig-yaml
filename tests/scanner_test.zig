// SPDX-License-Identifier: MIT
// Copyright (c) 2024 DevNW

//! Direct Scanner Unit Tests
//! Tests the scanner/tokenizer in isolation from the parser.

const std = @import("std");
const yaml = @import("yaml");

const Scanner = yaml.scanner.Scanner;
const TokenType = yaml.scanner.TokenType;

// ============================================================================
// Basic Token Tests
// ============================================================================

test "scanner: stream start and end" {
    const allocator = std.testing.allocator;
    var scanner = try Scanner.init(allocator, "", .{});
    defer scanner.deinit();

    const t1 = try scanner.nextToken();
    try std.testing.expect(t1 != null);
    try std.testing.expectEqual(TokenType.stream_start, t1.?.type);

    const t2 = try scanner.nextToken();
    try std.testing.expect(t2 != null);
    try std.testing.expectEqual(TokenType.stream_end, t2.?.type);

    const t3 = try scanner.nextToken();
    try std.testing.expect(t3 == null);
}

test "scanner: document markers" {
    const allocator = std.testing.allocator;
    var scanner = try Scanner.init(allocator, "---\n...", .{});
    defer scanner.deinit();

    _ = try scanner.nextToken(); // stream_start

    const doc_start = try scanner.nextToken();
    try std.testing.expect(doc_start != null);
    try std.testing.expectEqual(TokenType.doc_start, doc_start.?.type);

    const doc_end = try scanner.nextToken();
    try std.testing.expect(doc_end != null);
    try std.testing.expectEqual(TokenType.doc_end, doc_end.?.type);
}

test "scanner: plain scalar" {
    const allocator = std.testing.allocator;
    var scanner = try Scanner.init(allocator, "hello", .{});
    defer scanner.deinit();

    _ = try scanner.nextToken(); // stream_start

    const scalar = try scanner.nextToken();
    try std.testing.expect(scalar != null);
    try std.testing.expectEqual(TokenType.scalar, scalar.?.type);
    try std.testing.expectEqualStrings("hello", scalar.?.value);
}

test "scanner: single-quoted string" {
    const allocator = std.testing.allocator;
    var scanner = try Scanner.init(allocator, "'hello world'", .{});
    defer scanner.deinit();

    _ = try scanner.nextToken(); // stream_start

    const scalar = try scanner.nextToken();
    try std.testing.expect(scalar != null);
    try std.testing.expectEqual(TokenType.scalar, scalar.?.type);
    try std.testing.expectEqualStrings("hello world", scalar.?.value);
    try std.testing.expectEqual(yaml.scanner.ScalarStyle.single_quoted, scalar.?.style);
}

test "scanner: double-quoted string" {
    const allocator = std.testing.allocator;
    var scanner = try Scanner.init(allocator, "\"hello\\nworld\"", .{});
    defer scanner.deinit();

    _ = try scanner.nextToken(); // stream_start

    const scalar = try scanner.nextToken();
    try std.testing.expect(scalar != null);
    try std.testing.expectEqual(TokenType.scalar, scalar.?.type);
    try std.testing.expectEqualStrings("hello\nworld", scalar.?.value);
    try std.testing.expectEqual(yaml.scanner.ScalarStyle.double_quoted, scalar.?.style);
}

// ============================================================================
// Flow Collection Tests
// ============================================================================

test "scanner: flow sequence" {
    const allocator = std.testing.allocator;
    var scanner = try Scanner.init(allocator, "[a, b, c]", .{});
    defer scanner.deinit();

    _ = try scanner.nextToken(); // stream_start

    const seq_start = try scanner.nextToken();
    try std.testing.expect(seq_start != null);
    try std.testing.expectEqual(TokenType.flow_seq_start, seq_start.?.type);

    // a
    const a = try scanner.nextToken();
    try std.testing.expect(a != null);
    try std.testing.expectEqual(TokenType.scalar, a.?.type);
    try std.testing.expectEqualStrings("a", a.?.value);

    // , (flow_entry)
    const comma1 = try scanner.nextToken();
    try std.testing.expect(comma1 != null);
    try std.testing.expectEqual(TokenType.flow_entry, comma1.?.type);

    // b
    const b = try scanner.nextToken();
    try std.testing.expect(b != null);
    try std.testing.expectEqual(TokenType.scalar, b.?.type);

    // ,
    _ = try scanner.nextToken();

    // c
    const c = try scanner.nextToken();
    try std.testing.expect(c != null);
    try std.testing.expectEqual(TokenType.scalar, c.?.type);

    const seq_end = try scanner.nextToken();
    try std.testing.expect(seq_end != null);
    try std.testing.expectEqual(TokenType.flow_seq_end, seq_end.?.type);
}

test "scanner: flow mapping" {
    const allocator = std.testing.allocator;
    var scanner = try Scanner.init(allocator, "{a: 1, b: 2}", .{});
    defer scanner.deinit();

    _ = try scanner.nextToken(); // stream_start

    const map_start = try scanner.nextToken();
    try std.testing.expect(map_start != null);
    try std.testing.expectEqual(TokenType.flow_map_start, map_start.?.type);

    // Key 'a'
    const key_a = try scanner.nextToken();
    try std.testing.expect(key_a != null);
    try std.testing.expectEqual(TokenType.scalar, key_a.?.type);

    // Value indicator
    const val1 = try scanner.nextToken();
    try std.testing.expect(val1 != null);
    try std.testing.expectEqual(TokenType.value, val1.?.type);

    // Value '1'
    const v1 = try scanner.nextToken();
    try std.testing.expect(v1 != null);
    try std.testing.expectEqual(TokenType.scalar, v1.?.type);
}

// ============================================================================
// Block Collection Tests
// ============================================================================

test "scanner: block sequence" {
    const allocator = std.testing.allocator;
    var scanner = try Scanner.init(allocator, "- a\n- b\n- c", .{});
    defer scanner.deinit();

    _ = try scanner.nextToken(); // stream_start

    const seq_start = try scanner.nextToken();
    try std.testing.expect(seq_start != null);
    try std.testing.expectEqual(TokenType.block_seq_start, seq_start.?.type);

    const entry1 = try scanner.nextToken();
    try std.testing.expect(entry1 != null);
    try std.testing.expectEqual(TokenType.block_entry, entry1.?.type);

    const a = try scanner.nextToken();
    try std.testing.expect(a != null);
    try std.testing.expectEqual(TokenType.scalar, a.?.type);
    try std.testing.expectEqualStrings("a", a.?.value);
}

test "scanner: block mapping" {
    const allocator = std.testing.allocator;
    var scanner = try Scanner.init(allocator, "key: value", .{});
    defer scanner.deinit();

    _ = try scanner.nextToken(); // stream_start

    const map_start = try scanner.nextToken();
    try std.testing.expect(map_start != null);
    try std.testing.expectEqual(TokenType.block_map_start, map_start.?.type);

    const key = try scanner.nextToken();
    try std.testing.expect(key != null);
    try std.testing.expectEqual(TokenType.scalar, key.?.type);
    try std.testing.expectEqualStrings("key", key.?.value);

    const val_ind = try scanner.nextToken();
    try std.testing.expect(val_ind != null);
    try std.testing.expectEqual(TokenType.value, val_ind.?.type);

    const val = try scanner.nextToken();
    try std.testing.expect(val != null);
    try std.testing.expectEqual(TokenType.scalar, val.?.type);
    try std.testing.expectEqualStrings("value", val.?.value);
}

// ============================================================================
// Anchor and Alias Tests
// ============================================================================

test "scanner: anchor" {
    const allocator = std.testing.allocator;
    var scanner = try Scanner.init(allocator, "&anchor value", .{});
    defer scanner.deinit();

    _ = try scanner.nextToken(); // stream_start

    const anchor = try scanner.nextToken();
    try std.testing.expect(anchor != null);
    try std.testing.expectEqual(TokenType.anchor, anchor.?.type);
    try std.testing.expectEqualStrings("anchor", anchor.?.value);
}

test "scanner: alias" {
    const allocator = std.testing.allocator;
    var scanner = try Scanner.init(allocator, "*anchor", .{});
    defer scanner.deinit();

    _ = try scanner.nextToken(); // stream_start

    const alias = try scanner.nextToken();
    try std.testing.expect(alias != null);
    try std.testing.expectEqual(TokenType.alias, alias.?.type);
    try std.testing.expectEqualStrings("anchor", alias.?.value);
}

// ============================================================================
// Tag Tests
// ============================================================================

test "scanner: verbatim tag" {
    const allocator = std.testing.allocator;
    var scanner = try Scanner.init(allocator, "!<tag:example.com,2024:custom> value", .{});
    defer scanner.deinit();

    _ = try scanner.nextToken(); // stream_start

    const tag = try scanner.nextToken();
    try std.testing.expect(tag != null);
    try std.testing.expectEqual(TokenType.tag, tag.?.type);
}

test "scanner: shorthand tag" {
    const allocator = std.testing.allocator;
    var scanner = try Scanner.init(allocator, "!!str value", .{});
    defer scanner.deinit();

    _ = try scanner.nextToken(); // stream_start

    const tag = try scanner.nextToken();
    try std.testing.expect(tag != null);
    try std.testing.expectEqual(TokenType.tag, tag.?.type);
}

// ============================================================================
// Block Scalar Tests
// ============================================================================

test "scanner: literal block scalar" {
    const allocator = std.testing.allocator;
    var scanner = try Scanner.init(allocator, "|\n  line1\n  line2", .{});
    defer scanner.deinit();

    _ = try scanner.nextToken(); // stream_start

    const scalar = try scanner.nextToken();
    try std.testing.expect(scalar != null);
    try std.testing.expectEqual(TokenType.scalar, scalar.?.type);
    try std.testing.expectEqual(yaml.scanner.ScalarStyle.literal, scalar.?.style);
}

test "scanner: folded block scalar" {
    const allocator = std.testing.allocator;
    var scanner = try Scanner.init(allocator, ">\n  line1\n  line2", .{});
    defer scanner.deinit();

    _ = try scanner.nextToken(); // stream_start

    const scalar = try scanner.nextToken();
    try std.testing.expect(scalar != null);
    try std.testing.expectEqual(TokenType.scalar, scalar.?.type);
    try std.testing.expectEqual(yaml.scanner.ScalarStyle.folded, scalar.?.style);
}

// ============================================================================
// Directive Tests
// ============================================================================

test "scanner: YAML directive" {
    const allocator = std.testing.allocator;
    var scanner = try Scanner.init(allocator, "%YAML 1.2\n---\ntest", .{});
    defer scanner.deinit();

    _ = try scanner.nextToken(); // stream_start

    const directive = try scanner.nextToken();
    try std.testing.expect(directive != null);
    try std.testing.expectEqual(TokenType.directive, directive.?.type);

    const doc_start = try scanner.nextToken();
    try std.testing.expect(doc_start != null);
    try std.testing.expectEqual(TokenType.doc_start, doc_start.?.type);
}

// ============================================================================
// Edge Cases
// ============================================================================

test "scanner: empty document" {
    const allocator = std.testing.allocator;
    var scanner = try Scanner.init(allocator, "---\n...", .{});
    defer scanner.deinit();

    _ = try scanner.nextToken(); // stream_start
    const doc_start = try scanner.nextToken();
    try std.testing.expectEqual(TokenType.doc_start, doc_start.?.type);

    const doc_end = try scanner.nextToken();
    try std.testing.expectEqual(TokenType.doc_end, doc_end.?.type);
}

test "scanner: comment handling" {
    const allocator = std.testing.allocator;
    var scanner = try Scanner.init(allocator, "# comment\nvalue # inline", .{});
    defer scanner.deinit();

    _ = try scanner.nextToken(); // stream_start

    const scalar = try scanner.nextToken();
    try std.testing.expect(scalar != null);
    try std.testing.expectEqual(TokenType.scalar, scalar.?.type);
    try std.testing.expectEqualStrings("value", scalar.?.value);
}

test "scanner: multi-document stream" {
    const allocator = std.testing.allocator;
    var scanner = try Scanner.init(allocator, "---\ndoc1\n---\ndoc2", .{});
    defer scanner.deinit();

    _ = try scanner.nextToken(); // stream_start

    const doc1_start = try scanner.nextToken();
    try std.testing.expectEqual(TokenType.doc_start, doc1_start.?.type);

    const doc1_val = try scanner.nextToken();
    try std.testing.expectEqual(TokenType.scalar, doc1_val.?.type);
    try std.testing.expectEqualStrings("doc1", doc1_val.?.value);

    const doc2_start = try scanner.nextToken();
    try std.testing.expectEqual(TokenType.doc_start, doc2_start.?.type);
}

test "scanner: nested structure indentation" {
    const allocator = std.testing.allocator;
    const input =
        \\root:
        \\  child1:
        \\    value: 1
        \\  child2: 2
    ;
    var scanner = try Scanner.init(allocator, input, .{});
    defer scanner.deinit();

    _ = try scanner.nextToken(); // stream_start

    // Verify we get proper block structure tokens
    var token_count: usize = 0;
    while (try scanner.nextToken()) |_| {
        token_count += 1;
        if (token_count > 100) break; // Safety limit
    }

    try std.testing.expect(token_count > 5);
}

// ============================================================================
// Error Cases
// ============================================================================

test "scanner: tab in indentation error" {
    const allocator = std.testing.allocator;
    // Tab as indentation before content in block context
    var scanner = try Scanner.init(allocator, "key:\n\tvalue", .{});
    defer scanner.deinit();

    _ = try scanner.nextToken(); // stream_start
    _ = try scanner.nextToken(); // block_map_start
    _ = try scanner.nextToken(); // key scalar
    _ = try scanner.nextToken(); // value indicator

    const result = scanner.nextToken();
    try std.testing.expectError(error.TabInIndentation, result);
}

test "scanner: unterminated single quote" {
    const allocator = std.testing.allocator;
    var scanner = try Scanner.init(allocator, "'unterminated", .{});
    defer scanner.deinit();

    _ = try scanner.nextToken(); // stream_start

    const result = scanner.nextToken();
    try std.testing.expectError(error.UnterminatedString, result);
}

test "scanner: unterminated double quote" {
    const allocator = std.testing.allocator;
    var scanner = try Scanner.init(allocator, "\"unterminated", .{});
    defer scanner.deinit();

    _ = try scanner.nextToken(); // stream_start

    const result = scanner.nextToken();
    try std.testing.expectError(error.UnterminatedString, result);
}

// ============================================================================
// Position Tracking Tests
// ============================================================================

test "scanner: line and column tracking" {
    const allocator = std.testing.allocator;
    var scanner = try Scanner.init(allocator, "a: 1\nb: 2", .{});
    defer scanner.deinit();

    _ = try scanner.nextToken(); // stream_start

    const map_start = try scanner.nextToken();
    try std.testing.expectEqual(@as(u32, 1), map_start.?.start_line);
    try std.testing.expectEqual(@as(u32, 1), map_start.?.start_col);
}

// ============================================================================
// UTF-8 Escape Sequence Tests
// ============================================================================

test "scanner: escape sequence \\x produces valid UTF-8" {
    const allocator = std.testing.allocator;

    // \x7F should produce the ASCII DEL character (single byte)
    var scanner1 = try Scanner.init(allocator, "\"\\x7F\"", .{});
    defer scanner1.deinit();
    _ = try scanner1.nextToken(); // stream_start
    const scalar1 = try scanner1.nextToken();
    try std.testing.expectEqualStrings("\x7F", scalar1.?.value);

    // \xA9 should produce U+00A9 (©) as UTF-8: 0xC2 0xA9
    var scanner2 = try Scanner.init(allocator, "\"\\xA9\"", .{});
    defer scanner2.deinit();
    _ = try scanner2.nextToken(); // stream_start
    const scalar2 = try scanner2.nextToken();
    try std.testing.expectEqualStrings("\xC2\xA9", scalar2.?.value);

    // \xFF should produce U+00FF (ÿ) as UTF-8: 0xC3 0xBF
    var scanner3 = try Scanner.init(allocator, "\"\\xFF\"", .{});
    defer scanner3.deinit();
    _ = try scanner3.nextToken(); // stream_start
    const scalar3 = try scanner3.nextToken();
    try std.testing.expectEqualStrings("\xC3\xBF", scalar3.?.value);
}

test "scanner: escape sequence \\u produces valid UTF-8" {
    const allocator = std.testing.allocator;

    // \u00A9 should produce U+00A9 (©) as UTF-8
    var scanner1 = try Scanner.init(allocator, "\"\\u00A9\"", .{});
    defer scanner1.deinit();
    _ = try scanner1.nextToken(); // stream_start
    const scalar1 = try scanner1.nextToken();
    try std.testing.expectEqualStrings("\xC2\xA9", scalar1.?.value);

    // \u2713 should produce U+2713 (✓) as UTF-8
    var scanner2 = try Scanner.init(allocator, "\"\\u2713\"", .{});
    defer scanner2.deinit();
    _ = try scanner2.nextToken(); // stream_start
    const scalar2 = try scanner2.nextToken();
    try std.testing.expectEqualStrings("\xE2\x9C\x93", scalar2.?.value);
}

test "scanner: escape sequence \\U produces valid UTF-8" {
    const allocator = std.testing.allocator;

    // \U0001F600 should produce U+1F600 (😀) as UTF-8
    var scanner1 = try Scanner.init(allocator, "\"\\U0001F600\"", .{});
    defer scanner1.deinit();
    _ = try scanner1.nextToken(); // stream_start
    const scalar1 = try scanner1.nextToken();
    try std.testing.expectEqualStrings("\xF0\x9F\x98\x80", scalar1.?.value);
}

test "scanner: escape sequence \\u rejects surrogate pairs" {
    const allocator = std.testing.allocator;

    // \uD800 is a surrogate pair (high surrogate) - invalid Unicode scalar value
    var scanner1 = try Scanner.init(allocator, "\"\\uD800\"", .{});
    defer scanner1.deinit();
    _ = try scanner1.nextToken(); // stream_start
    const result1 = scanner1.nextToken();
    try std.testing.expectError(error.InvalidEscapeSequence, result1);

    // \uDFFF is a surrogate pair (low surrogate) - invalid Unicode scalar value
    var scanner2 = try Scanner.init(allocator, "\"\\uDFFF\"", .{});
    defer scanner2.deinit();
    _ = try scanner2.nextToken(); // stream_start
    const result2 = scanner2.nextToken();
    try std.testing.expectError(error.InvalidEscapeSequence, result2);
}

test "scanner: escape sequence \\U rejects invalid code points" {
    const allocator = std.testing.allocator;

    // \U00110000 is beyond the valid Unicode range (max is U+10FFFF)
    var scanner1 = try Scanner.init(allocator, "\"\\U00110000\"", .{});
    defer scanner1.deinit();
    _ = try scanner1.nextToken(); // stream_start
    const result1 = scanner1.nextToken();
    try std.testing.expectError(error.InvalidEscapeSequence, result1);

    // \UFFFFFFFF is way beyond the valid Unicode range
    var scanner2 = try Scanner.init(allocator, "\"\\UFFFFFFFF\"", .{});
    defer scanner2.deinit();
    _ = try scanner2.nextToken(); // stream_start
    const result2 = scanner2.nextToken();
    try std.testing.expectError(error.InvalidEscapeSequence, result2);
}

test "scanner: escape sequence \\x equivalence with \\u00XX" {
    const allocator = std.testing.allocator;

    // Per YAML 1.2.2 spec, \xNN is equivalent to \u00NN
    // Test that \xA0 produces same result as \u00A0
    var scanner1 = try Scanner.init(allocator, "\"\\xA0\"", .{});
    defer scanner1.deinit();
    _ = try scanner1.nextToken();
    const scalar1 = try scanner1.nextToken();

    var scanner2 = try Scanner.init(allocator, "\"\\u00A0\"", .{});
    defer scanner2.deinit();
    _ = try scanner2.nextToken();
    const scalar2 = try scanner2.nextToken();

    try std.testing.expectEqualStrings(scalar1.?.value, scalar2.?.value);
}

// ============================================================================
// Error Recovery Tests
// ============================================================================

test "scanner: error context for unterminated double-quoted string" {
    const allocator = std.testing.allocator;
    var scanner1 = try Scanner.init(allocator, "\"unterminated", .{});
    defer scanner1.deinit();

    // Get stream start
    _ = try scanner1.nextToken();

    // This should fail with unterminated string
    const result = scanner1.nextToken();
    try std.testing.expect(result == error.UnterminatedString);

    // Check error context was recorded
    const err_info = scanner1.getErrorInfo();
    try std.testing.expectEqual(@as(u32, 1), err_info.line);
    try std.testing.expectEqual(@as(u32, 1), err_info.col);
    try std.testing.expectEqualStrings("in double-quoted string", err_info.context);
}

test "scanner: error context for unterminated single-quoted string" {
    const allocator = std.testing.allocator;
    var scanner1 = try Scanner.init(allocator, "'unterminated", .{});
    defer scanner1.deinit();

    // Get stream start
    _ = try scanner1.nextToken();

    // This should fail with unterminated string
    const result = scanner1.nextToken();
    try std.testing.expect(result == error.UnterminatedString);

    // Check error context was recorded
    const err_info = scanner1.getErrorInfo();
    try std.testing.expectEqual(@as(u32, 1), err_info.line);
    try std.testing.expectEqual(@as(u32, 1), err_info.col);
    try std.testing.expectEqualStrings("in single-quoted string", err_info.context);
}

test "scanner: error context for invalid block scalar" {
    const allocator = std.testing.allocator;
    // | with invalid indicator
    var scanner1 = try Scanner.init(allocator, "|#not valid", .{});
    defer scanner1.deinit();

    // Get stream start
    _ = try scanner1.nextToken();

    // This should fail with invalid block scalar header
    const result = scanner1.nextToken();
    try std.testing.expect(result == error.InvalidBlockScalarHeader);

    // Check error context was recorded
    const err_info = scanner1.getErrorInfo();
    try std.testing.expectEqualStrings("in literal block scalar", err_info.context);
}
