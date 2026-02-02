// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Unified YAML Error Types
//! This module provides the consolidated error types used across all YAML components.

const std = @import("std");

/// Unified error codes for all YAML parsing errors
pub const ErrorCode = enum {
    unexpected_token,
    invalid_indentation,
    undefined_anchor,
    duplicate_key,
    invalid_escape,
    unterminated_string,
    invalid_tag,
    max_depth_exceeded,
    max_nodes_exceeded,
    max_aliases_exceeded,
    input_too_large,
    scalar_too_large,
    invalid_utf8,
    tab_in_indentation,
    alias_cycle,
    invalid_anchor_name,
    invalid_directive,
    invalid_block_scalar,
    internal_error,

    /// Returns a human-readable description of the error
    pub fn message(self: ErrorCode) []const u8 {
        return switch (self) {
            .unexpected_token => "unexpected token in input",
            .invalid_indentation => "invalid indentation",
            .undefined_anchor => "reference to undefined anchor",
            .duplicate_key => "duplicate key in mapping",
            .invalid_escape => "invalid escape sequence in string",
            .unterminated_string => "unterminated quoted string",
            .invalid_tag => "invalid or unknown tag",
            .max_depth_exceeded => "maximum nesting depth exceeded",
            .max_nodes_exceeded => "maximum number of nodes exceeded",
            .max_aliases_exceeded => "maximum number of aliases exceeded",
            .input_too_large => "input exceeds maximum allowed size",
            .scalar_too_large => "scalar value exceeds maximum allowed size",
            .invalid_utf8 => "invalid UTF-8 encoding in input",
            .tab_in_indentation => "tabs are not allowed for indentation",
            .alias_cycle => "alias creates a circular reference",
            .invalid_anchor_name => "invalid anchor name",
            .invalid_directive => "invalid YAML directive",
            .invalid_block_scalar => "invalid block scalar header",
            .internal_error => "internal parser error",
        };
    }
};

/// Detailed parse error with location information
pub const ParseError = struct {
    code: ErrorCode,
    line: u32,
    col: u32,
    offset: u32 = 0,
    /// Optional additional context (e.g., anchor name for undefined anchor errors)
    context: []const u8 = "",
    /// Optional name field for backwards compatibility
    name: []const u8 = "",

    /// Returns a human-readable description of the error
    pub fn message(self: ParseError) []const u8 {
        return self.code.message();
    }

    /// Formats the error with location information to a provided buffer.
    /// Returns a slice of the buffer containing the formatted string.
    pub fn formatBuf(self: ParseError, buf: []u8) []const u8 {
        var stream = std.io.fixedBufferStream(buf);
        const writer = stream.writer();
        if (self.context.len > 0) {
            writer.print("{s} at line {d}, column {d}: {s}", .{
                self.code.message(),
                self.line,
                self.col,
                self.context,
            }) catch {};
        } else {
            writer.print("{s} at line {d}, column {d}", .{
                self.code.message(),
                self.line,
                self.col,
            }) catch {};
        }
        return stream.getWritten();
    }

    /// Formats the error with location information to a static buffer.
    /// Useful for quick error display without allocation.
    /// WARNING: The returned slice points to a static buffer that will be
    /// overwritten on subsequent calls.
    pub fn format(self: ParseError) []const u8 {
        const S = struct {
            var buf = std.mem.zeroes([256]u8);
        };
        return self.formatBuf(&S.buf);
    }
};

/// Scanner-specific errors
pub const ScanError = error{
    UnexpectedCharacter,
    InvalidEscapeSequence,
    UnterminatedString,
    InvalidAnchorName,
    InvalidTagHandle,
    InvalidDirective,
    TabInIndentation,
    InvalidBlockScalarHeader,
    InvalidUtf8,
    OutOfMemory,
};

/// Parser-level errors (simplified for error union)
pub const ParserError = error{
    ParseFailed,
    OutOfMemory,
};

/// Composer-level errors
pub const ComposerError = error{
    UndefinedAnchor,
    DuplicateKey,
    MaxDepthExceeded,
    MaxNodesExceeded,
    OutOfMemory,
    ParseFailed,
    AliasCycle,
};

/// Resolver-level errors
pub const ResolveError = error{
    UndefinedAnchor,
    AliasCycle,
    OutOfMemory,
};

/// Limit-related errors
pub const LimitError = error{
    InputTooLarge,
    ScalarTooLarge,
    MaxDepthExceeded,
    MaxNodesExceeded,
    MaxAliasesExceeded,
};

/// Convert a ScanError to an ErrorCode
pub fn scanErrorToCode(err: ScanError) ErrorCode {
    return switch (err) {
        error.UnexpectedCharacter => .unexpected_token,
        error.InvalidEscapeSequence => .invalid_escape,
        error.UnterminatedString => .unterminated_string,
        error.InvalidAnchorName => .invalid_anchor_name,
        error.InvalidTagHandle => .invalid_tag,
        error.InvalidDirective => .invalid_directive,
        error.TabInIndentation => .tab_in_indentation,
        error.InvalidBlockScalarHeader => .invalid_block_scalar,
        error.InvalidUtf8 => .invalid_utf8,
        error.OutOfMemory => .internal_error,
    };
}

/// Convert a ComposerError to an ErrorCode
pub fn composerErrorToCode(err: ComposerError) ErrorCode {
    return switch (err) {
        error.UndefinedAnchor => .undefined_anchor,
        error.DuplicateKey => .duplicate_key,
        error.MaxDepthExceeded => .max_depth_exceeded,
        error.MaxNodesExceeded => .max_nodes_exceeded,
        error.AliasCycle => .alias_cycle,
        error.ParseFailed => .unexpected_token,
        error.OutOfMemory => .internal_error,
    };
}

/// Convert a LimitError to an ErrorCode
pub fn limitErrorToCode(err: LimitError) ErrorCode {
    return switch (err) {
        error.InputTooLarge => .input_too_large,
        error.ScalarTooLarge => .scalar_too_large,
        error.MaxDepthExceeded => .max_depth_exceeded,
        error.MaxNodesExceeded => .max_nodes_exceeded,
        error.MaxAliasesExceeded => .max_aliases_exceeded,
    };
}

/// Allocates and returns a formatted error message string.
/// Caller owns the returned memory.
pub fn formatError(allocator: std.mem.Allocator, err: ParseError) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s} at line {d}, column {d}", .{
        err.code.message(),
        err.line,
        err.col,
    });
}

/// Writes a formatted error message to any writer.
pub fn writeError(writer: anytype, err: ParseError) !void {
    try writer.print("{s} at line {d}, column {d}", .{
        err.code.message(),
        err.line,
        err.col,
    });
}

// ============================================================================
// Tests
// ============================================================================

test "error: ErrorCode.message returns correct strings" {
    try std.testing.expectEqualStrings("unexpected token in input", ErrorCode.unexpected_token.message());
    try std.testing.expectEqualStrings("invalid indentation", ErrorCode.invalid_indentation.message());
    try std.testing.expectEqualStrings("reference to undefined anchor", ErrorCode.undefined_anchor.message());
    try std.testing.expectEqualStrings("tabs are not allowed for indentation", ErrorCode.tab_in_indentation.message());
}

test "error: ParseError.format includes location" {
    const err = ParseError{
        .code = .unexpected_token,
        .line = 5,
        .col = 10,
    };
    const msg = err.format();
    try std.testing.expect(std.mem.indexOf(u8, msg, "line 5") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "column 10") != null);
}

test "error: scanErrorToCode conversion" {
    try std.testing.expectEqual(ErrorCode.invalid_escape, scanErrorToCode(error.InvalidEscapeSequence));
    try std.testing.expectEqual(ErrorCode.unterminated_string, scanErrorToCode(error.UnterminatedString));
    try std.testing.expectEqual(ErrorCode.tab_in_indentation, scanErrorToCode(error.TabInIndentation));
}

test "error: composerErrorToCode conversion" {
    try std.testing.expectEqual(ErrorCode.undefined_anchor, composerErrorToCode(error.UndefinedAnchor));
    try std.testing.expectEqual(ErrorCode.duplicate_key, composerErrorToCode(error.DuplicateKey));
    try std.testing.expectEqual(ErrorCode.alias_cycle, composerErrorToCode(error.AliasCycle));
}
