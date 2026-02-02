// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! YAML 1.2.2 Scanner (Tokenizer)
//! Converts input bytes into tokens for the parser.
//! O(n) streaming scan - no quadratic rescans.

const std = @import("std");
const limits = @import("limits.zig");

pub const TokenType = enum {
    stream_start,
    stream_end,
    directive,
    doc_start,
    doc_end,
    block_seq_start,
    block_map_start,
    block_end,
    flow_seq_start,
    flow_seq_end,
    flow_map_start,
    flow_map_end,
    block_entry,
    flow_entry,
    key,
    value,
    anchor,
    alias,
    tag,
    scalar,
};

pub const ScalarStyle = enum { plain, single_quoted, double_quoted, literal, folded };

pub const Token = struct {
    type: TokenType,
    start_line: u32,
    start_col: u32,
    start_offset: u32,
    end_offset: u32,
    style: ScalarStyle = .plain,
    value: []const u8 = "",
    chomping: Chomping = .clip,
    tag_handle: []const u8 = "",
    tag_suffix: []const u8 = "",
};

pub const Chomping = enum { strip, clip, keep };

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
} || limits.LimitError;

pub const Scanner = struct {
    allocator: std.mem.Allocator,
    input: []const u8,
    pos: usize,
    line: u32,
    col: u32,
    limit_checker: limits.LimitChecker,
    indent_stack: std.ArrayList(i32),
    block_type_stack: std.ArrayList(bool), // true = sequence, false = mapping
    indent: i32,
    is_sequence: bool, // true if current block is a sequence
    flow_level: u32,
    token_queue: std.ArrayList(Token),
    stream_started: bool,
    stream_ended: bool,
    doc_started: bool,
    tag_directives: std.StringHashMap([]const u8),
    allocated_strings: std.ArrayList([]const u8),
    pending_key: bool,
    block_map_started_line: ?u32, // Track line where block_map_start was emitted from lookahead
    flow_after_value: bool, // In flow context, are we after a ':' (in value position)?
    flow_context_stack: std.ArrayList(FlowContext), // Track whether each flow level is sequence or mapping
    flow_start_col_stack: std.ArrayList(u32), // Track the starting column of each flow context
    flow_start_line_stack: std.ArrayList(u32), // Track the starting line of each flow context
    seen_yaml_directive: bool, // Track if we've seen a %YAML directive for current document
    seen_content: bool, // Track if we've seen any content (for directive validation)
    pending_directive: bool, // Track if we have a pending directive that needs a document
    doc_start_line: ?u32, // Track line where explicit --- was seen (to reject block maps on same line)
    map_value_line: ?u32, // Track line where last map value (:) was emitted (to reject nested implicit keys)
    block_entry_line: ?u32, // Track line where last block entry (-) was emitted
    has_root_value: bool, // Track if document already has a root value (for rejecting multiple roots)

    // Error recovery: track where errors occur for better diagnostics
    error_line: u32 = 1,
    error_col: u32 = 1,
    error_offset: u32 = 0,
    error_context: []const u8 = "",

    const FlowContext = enum { sequence, mapping };

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, input: []const u8, opts: anytype) ScanError!Self {
        var checker = limits.LimitChecker.init(opts);
        try checker.checkInputSize(input.len);
        try limits.validateUtf8(input);

        var tag_dirs = std.StringHashMap([]const u8).init(allocator);
        try tag_dirs.put("!", "!");
        try tag_dirs.put("!!", "tag:yaml.org,2002:");

        return Self{
            .allocator = allocator,
            .input = input,
            .pos = 0,
            .line = 1,
            .col = 1,
            .limit_checker = checker,
            .indent_stack = .{},
            .block_type_stack = .{},
            .indent = -1,
            .is_sequence = false,
            .flow_level = 0,
            .token_queue = .{},
            .stream_started = false,
            .stream_ended = false,
            .doc_started = false,
            .tag_directives = tag_dirs,
            .allocated_strings = .{},
            .pending_key = false,
            .block_map_started_line = null,
            .flow_after_value = false,
            .flow_context_stack = .{},
            .flow_start_col_stack = .{},
            .flow_start_line_stack = .{},
            .seen_yaml_directive = false,
            .seen_content = false,
            .pending_directive = false,
            .doc_start_line = null,
            .map_value_line = null,
            .block_entry_line = null,
            .has_root_value = false,
        };
    }

    pub fn deinit(self: *Self) void {
        self.indent_stack.deinit(self.allocator);
        self.block_type_stack.deinit(self.allocator);
        self.token_queue.deinit(self.allocator);
        self.tag_directives.deinit();
        for (self.allocated_strings.items) |s| {
            self.allocator.free(s);
        }
        self.allocated_strings.deinit(self.allocator);
        self.flow_context_stack.deinit(self.allocator);
        self.flow_start_col_stack.deinit(self.allocator);
        self.flow_start_line_stack.deinit(self.allocator);
    }

    /// Record the current position as the error location with optional context
    fn recordError(self: *Self, context: []const u8) void {
        self.error_line = self.line;
        self.error_col = self.col;
        self.error_offset = @intCast(self.pos);
        self.error_context = context;
    }

    /// Get the error position information
    pub fn getErrorInfo(self: *const Self) struct { line: u32, col: u32, offset: u32, context: []const u8 } {
        return .{
            .line = self.error_line,
            .col = self.error_col,
            .offset = self.error_offset,
            .context = self.error_context,
        };
    }

    pub fn nextToken(self: *Self) ScanError!?Token {
        if (self.token_queue.items.len > 0) return self.token_queue.orderedRemove(0);

        if (!self.stream_started) {
            self.stream_started = true;
            return Token{ .type = .stream_start, .start_line = self.line, .start_col = self.col, .start_offset = @intCast(self.pos), .end_offset = @intCast(self.pos) };
        }

        if (self.stream_ended) return null;

        try self.scanToNextToken();

        if (self.pos >= self.input.len) {
            // Directive without a following document is an error
            if (self.pending_directive) {
                return error.InvalidDirective;
            }
            try self.unwindIndent(-1);
            if (self.token_queue.items.len > 0) return self.token_queue.orderedRemove(0);
            self.stream_ended = true;
            return Token{ .type = .stream_end, .start_line = self.line, .start_col = self.col, .start_offset = @intCast(self.pos), .end_offset = @intCast(self.pos) };
        }

        return try self.scanNextToken();
    }

    fn scanToNextToken(self: *Self) ScanError!void {
        while (self.pos < self.input.len) {
            // Track tabs and spaces for indentation validation
            // YAML spec: only spaces count for indentation
            var tab_at_col_1 = false;
            var seen_tab_in_leading = false;
            var space_count: u32 = 0;
            const start_col = self.col;

            while (self.pos < self.input.len) {
                const c = self.input[self.pos];
                if (c == ' ') {
                    space_count += 1;
                    self.advance();
                } else if (c == '\t') {
                    // Tab at column 1 is problematic for indentation
                    if (self.col == 1) {
                        tab_at_col_1 = true;
                    }
                    // Tab anywhere in leading whitespace after a space is also problematic
                    // if followed by block structure (DK95-case7)
                    if (start_col == 1) {
                        seen_tab_in_leading = true;
                    }
                    self.advance();
                } else break;
            }

            // If tab was at column 1 and now have content, validate
            if (tab_at_col_1 and self.pos < self.input.len) {
                const next = self.input[self.pos];
                const is_content = next != '\n' and next != '\r' and next != '#';

                if (is_content) {
                    if (self.flow_level == 0) {
                        // Block context: tab at col 1 before content = error
                        // Allow flow indicators (they start new flow context)
                        if (next != '[' and next != '{') {
                            return error.TabInIndentation;
                        }
                    } else {
                        // Flow context: tab at col 1 before content (not closing bracket) = error
                        // Y79Y: tab immediately before content in flow = invalid
                        if (next != ']' and next != '}') {
                            return error.TabInIndentation;
                        }
                    }
                }
            }

            // DK95-case7: Tab in leading whitespace (after spaces) before block key
            // Check if tab is being used as part of "indentation" for a block key
            if (seen_tab_in_leading and !tab_at_col_1 and self.flow_level == 0 and self.pos < self.input.len) {
                const next = self.input[self.pos];
                // Look for block key pattern: alphanumeric followed eventually by ':'
                if (next != '\n' and next != '\r' and next != '#' and next != '[' and next != '{') {
                    // Scan ahead to see if this is a key (has ':' followed by whitespace)
                    var look = self.pos;
                    while (look < self.input.len and self.input[look] != '\n' and self.input[look] != '\r') {
                        if (self.input[look] == ':') {
                            // Check if ':' is a value indicator (followed by whitespace or EOL)
                            const after_colon = look + 1;
                            if (after_colon >= self.input.len or isWsNl(self.input[after_colon])) {
                                // This looks like a block key - tabs in indentation is an error
                                return error.TabInIndentation;
                            }
                        }
                        look += 1;
                    }
                }
            }
            if (self.pos < self.input.len and self.input[self.pos] == '#') {
                // '#' is only a comment if preceded by whitespace or at start of line
                // Check actual previous character in the input
                const preceded_by_ws = (self.pos == 0) or isWsNl(self.input[self.pos - 1]);
                if (!preceded_by_ws) {
                    return error.UnexpectedCharacter;
                }
                while (self.pos < self.input.len and self.input[self.pos] != '\n') self.advance();
            }
            if (self.pos < self.input.len and (self.input[self.pos] == '\n' or self.input[self.pos] == '\r')) {
                self.advanceLine();
            } else break;
        }
    }

    fn scanNextToken(self: *Self) ScanError!?Token {
        const c = self.input[self.pos];
        const start_line = self.line;
        const start_col = self.col;
        const start_pos = self.pos;

        // Check flow indentation: content in flow context spanning multiple lines
        // cannot appear at column 1 (would be ambiguous with block structures)
        // Exception: if the outermost flow started at column 1, content is allowed there
        // Exception: closing brackets ] and } are allowed at column 1 (they close the flow)
        if (self.flow_level > 0 and self.flow_start_col_stack.items.len > 0 and start_col == 1) {
            // Allow closing brackets at column 1
            if (c != ']' and c != '}') {
                const outermost_flow_col = self.flow_start_col_stack.items[0];
                // If the outermost flow didn't start at column 1, reject column 1 content
                if (outermost_flow_col != 1) {
                    return error.UnexpectedCharacter;
                }
            }
        }

        if (c == '%' and self.col == 1) return try self.scanDirective();
        if (self.col == 1 or (self.pos > 0 and isWs(self.input[self.pos - 1]))) {
            if (self.checkDocStart()) {
                try self.unwindIndent(-1);
                self.advance();
                self.advance();
                self.advance();
                // Reset tag directives for new document ONLY if we had content before
                // (custom directives only apply to the document they're defined in)
                // If this --- follows directives (pending_directive=true), those directives apply
                if (self.seen_content) {
                    self.tag_directives.clearRetainingCapacity();
                    try self.tag_directives.put("!", "!");
                    try self.tag_directives.put("!!", "tag:yaml.org,2002:");
                }
                self.doc_started = true;
                self.pending_directive = false;
                self.seen_content = false;
                self.seen_yaml_directive = false;
                self.doc_start_line = start_line;
                self.has_root_value = false;
                const doc_start_token = Token{ .type = .doc_start, .start_line = start_line, .start_col = start_col, .start_offset = @intCast(start_pos), .end_offset = @intCast(self.pos) };
                // If there are queued block_end tokens, queue doc_start and return from queue
                if (self.token_queue.items.len > 0) {
                    try self.token_queue.append(self.allocator, doc_start_token);
                    return self.token_queue.orderedRemove(0);
                }
                return doc_start_token;
            }
            if (self.checkDocEnd()) {
                try self.unwindIndent(-1);
                self.advance();
                self.advance();
                self.advance();
                // Check for invalid content after document end marker (only whitespace/comment allowed on same line)
                var check_pos = self.pos;
                while (check_pos < self.input.len and self.input[check_pos] == ' ') check_pos += 1;
                if (check_pos < self.input.len and self.input[check_pos] != '\n' and
                    self.input[check_pos] != '\r' and self.input[check_pos] != '#')
                {
                    // Check if it's a new document marker (--- or ...) which is allowed
                    if (!(check_pos + 2 < self.input.len and
                        ((self.input[check_pos] == '-' and self.input[check_pos + 1] == '-' and self.input[check_pos + 2] == '-') or
                            (self.input[check_pos] == '.' and self.input[check_pos + 1] == '.' and self.input[check_pos + 2] == '.'))))
                    {
                        return error.UnexpectedCharacter;
                    }
                }
                self.doc_started = false;
                self.seen_content = false;
                self.seen_yaml_directive = false;
                const doc_end_token = Token{ .type = .doc_end, .start_line = start_line, .start_col = start_col, .start_offset = @intCast(start_pos), .end_offset = @intCast(self.pos) };
                // If there are queued block_end tokens, queue doc_end and return from queue
                if (self.token_queue.items.len > 0) {
                    try self.token_queue.append(self.allocator, doc_end_token);
                    return self.token_queue.orderedRemove(0);
                }
                return doc_end_token;
            }
        }

        switch (c) {
            '[' => {
                self.flow_level += 1;
                self.flow_after_value = false;
                self.seen_content = true;
                try self.flow_context_stack.append(self.allocator, .sequence);
                try self.flow_start_col_stack.append(self.allocator, start_col);
                try self.flow_start_line_stack.append(self.allocator, start_line);
                self.advance();
                return Token{ .type = .flow_seq_start, .start_line = start_line, .start_col = start_col, .start_offset = @intCast(start_pos), .end_offset = @intCast(self.pos) };
            },
            ']' => {
                // Capture start line of the flow being closed (if any) before popping
                const flow_started_line: ?u32 = if (self.flow_start_line_stack.items.len > 0)
                    self.flow_start_line_stack.items[0] // Use outermost flow's start line
                else
                    null;
                if (self.flow_level > 0) self.flow_level -= 1;
                if (self.flow_context_stack.items.len > 0) _ = self.flow_context_stack.pop();
                if (self.flow_start_col_stack.items.len > 0) _ = self.flow_start_col_stack.pop();
                if (self.flow_start_line_stack.items.len > 0) _ = self.flow_start_line_stack.pop();
                self.advance();
                // If we just closed the outermost flow (flow_level now 0), check for implicit key usage
                if (self.flow_level == 0 and flow_started_line != null) {
                    const look_pos = skipSpacesFrom(self.input, self.pos);
                    const value_check = isValueIndicatorAt(self.input, look_pos);
                    if (value_check.found) {
                        // This is a flow collection used as an implicit key
                        // Multi-line implicit keys are not allowed
                        if (flow_started_line.? != start_line) {
                            return error.UnexpectedCharacter;
                        }
                    } else {
                        // Not followed by ':', so this is a root value (unless inside another block)
                        if (self.indent < 0) {
                            self.has_root_value = true;
                        }
                    }
                }
                return Token{ .type = .flow_seq_end, .start_line = start_line, .start_col = start_col, .start_offset = @intCast(start_pos), .end_offset = @intCast(self.pos) };
            },
            '{' => {
                self.flow_level += 1;
                self.flow_after_value = false;
                self.seen_content = true;
                try self.flow_context_stack.append(self.allocator, .mapping);
                try self.flow_start_col_stack.append(self.allocator, start_col);
                try self.flow_start_line_stack.append(self.allocator, start_line);
                self.advance();
                return Token{ .type = .flow_map_start, .start_line = start_line, .start_col = start_col, .start_offset = @intCast(start_pos), .end_offset = @intCast(self.pos) };
            },
            '}' => {
                // Capture start line of the flow being closed (if any) before popping
                const flow_started_line: ?u32 = if (self.flow_start_line_stack.items.len > 0)
                    self.flow_start_line_stack.items[0] // Use outermost flow's start line
                else
                    null;
                if (self.flow_level > 0) self.flow_level -= 1;
                if (self.flow_context_stack.items.len > 0) _ = self.flow_context_stack.pop();
                if (self.flow_start_col_stack.items.len > 0) _ = self.flow_start_col_stack.pop();
                if (self.flow_start_line_stack.items.len > 0) _ = self.flow_start_line_stack.pop();
                self.advance();
                const map_end_token = Token{ .type = .flow_map_end, .start_line = start_line, .start_col = start_col, .start_offset = @intCast(start_pos), .end_offset = @intCast(self.pos) };
                // Check if '}' is followed by ':' (flow mapping as implicit key)
                if (self.flow_level > 0) {
                    var look_pos = self.pos;
                    while (look_pos < self.input.len and isWsNl(self.input[look_pos])) look_pos += 1;
                    if (look_pos < self.input.len and self.input[look_pos] == ':') {
                        // Consume whitespace up to ':'
                        while (self.pos < look_pos) {
                            if (self.input[self.pos] == '\n' or self.input[self.pos] == '\r') {
                                self.advanceLine();
                            } else {
                                self.advance();
                            }
                        }
                        self.advance(); // consume ':'
                        self.flow_after_value = true;
                        const value_token = Token{ .type = .value, .start_line = self.line, .start_col = self.col - 1, .start_offset = @intCast(look_pos), .end_offset = @intCast(self.pos) };
                        try self.token_queue.append(self.allocator, value_token);
                        return map_end_token;
                    }
                } else if (flow_started_line != null) {
                    // At block level, check for multi-line implicit keys
                    const look_pos = skipSpacesFrom(self.input, self.pos);
                    const value_check = isValueIndicatorAt(self.input, look_pos);
                    if (value_check.found) {
                        // This is a flow collection used as an implicit key
                        // Multi-line implicit keys are not allowed
                        if (flow_started_line.? != start_line) {
                            return error.UnexpectedCharacter;
                        }
                    } else {
                        // Not followed by ':', so this is a root value (unless inside another block)
                        if (self.indent < 0) {
                            self.has_root_value = true;
                        }
                    }
                }
                return map_end_token;
            },
            ',' => {
                self.flow_after_value = false;
                self.advance();
                return Token{ .type = .flow_entry, .start_line = start_line, .start_col = start_col, .start_offset = @intCast(start_pos), .end_offset = @intCast(self.pos) };
            },
            '-' => if (self.flow_level == 0 and (self.pos + 1 >= self.input.len or isWsNl(self.input[self.pos + 1]))) {
                // Check for tab in separator after '-' - tabs before indicators are not allowed
                // Scan through all whitespace (space and tab) after '-'
                var ws_check = self.pos + 1;
                var has_tab = false;
                while (ws_check < self.input.len and (self.input[ws_check] == ' ' or self.input[ws_check] == '\t')) {
                    if (self.input[ws_check] == '\t') has_tab = true;
                    ws_check += 1;
                }
                if (has_tab and ws_check < self.input.len) {
                    const next_char = self.input[ws_check];
                    // Reject if we find another indicator after tabs
                    if (next_char == '?' or next_char == ':') {
                        return error.UnexpectedCharacter;
                    }
                    // For '-', only reject if it's not a negative number (not followed by a digit)
                    if (next_char == '-') {
                        const after_dash = ws_check + 1;
                        if (after_dash >= self.input.len or self.input[after_dash] < '0' or self.input[after_dash] > '9') {
                            return error.UnexpectedCharacter;
                        }
                    }
                }
                const current_indent: i32 = @intCast(self.col - 1);
                // Unwind any blocks that are at higher indentation
                try self.unwindIndent(current_indent);
                try self.checkIndent(current_indent, true);
                self.advance();
                self.block_entry_line = start_line; // Track that we emitted a block entry on this line
                const entry_token = Token{ .type = .block_entry, .start_line = start_line, .start_col = start_col, .start_offset = @intCast(start_pos), .end_offset = @intCast(self.pos) };
                // If unwindIndent/checkIndent added tokens to queue, return those first
                if (self.token_queue.items.len > 0) {
                    try self.token_queue.append(self.allocator, entry_token);
                    return self.token_queue.orderedRemove(0);
                }
                return entry_token;
            },
            '?' => if (self.flow_level > 0 or (self.pos + 1 < self.input.len and isWsNl(self.input[self.pos + 1]))) {
                // Check for tab in separator after '?' - tabs before indicators/keys are not allowed in block context
                if (self.flow_level == 0) {
                    var ws_check = self.pos + 1;
                    var has_tab = false;
                    while (ws_check < self.input.len and (self.input[ws_check] == ' ' or self.input[ws_check] == '\t')) {
                        if (self.input[ws_check] == '\t') has_tab = true;
                        ws_check += 1;
                    }
                    if (has_tab and ws_check < self.input.len) {
                        const next_char = self.input[ws_check];
                        // Reject if we find another indicator after tabs
                        if (next_char == '-' or next_char == '?' or next_char == ':') {
                            return error.UnexpectedCharacter;
                        }
                        // Check for tab before key: pattern
                        var key_check = ws_check;
                        while (key_check < self.input.len and self.input[key_check] != ':' and self.input[key_check] != '\n' and self.input[key_check] != '\r') {
                            key_check += 1;
                        }
                        if (key_check < self.input.len and self.input[key_check] == ':') {
                            return error.UnexpectedCharacter;
                        }
                    }
                }
                // Check if we need to emit block_map_start for this explicit key
                if (self.flow_level == 0) {
                    const key_indent: i32 = @intCast(start_col - 1);
                    try self.unwindIndent(key_indent);
                    try self.checkIndent(key_indent, false);
                }
                self.advance();
                const key_token = Token{ .type = .key, .start_line = start_line, .start_col = start_col, .start_offset = @intCast(start_pos), .end_offset = @intCast(self.pos) };
                if (self.token_queue.items.len > 0) {
                    try self.token_queue.append(self.allocator, key_token);
                    return self.token_queue.orderedRemove(0);
                }
                return key_token;
            },
            ':' => {
                // In flow context, ':' followed by flow indicators is a value indicator
                // In block context, only ':' followed by whitespace/newline/EOF is a value indicator
                // BUT: ':' at the start of a line in flow context is NOT a value indicator
                // (implicit keys must have ':' on the same line as the key)
                const is_val = self.pos + 1 >= self.input.len or isWsNl(self.input[self.pos + 1]) or
                    (self.flow_level > 0 and (self.input[self.pos + 1] == ',' or self.input[self.pos + 1] == '[' or self.input[self.pos + 1] == ']' or self.input[self.pos + 1] == '{' or self.input[self.pos + 1] == '}'));

                // Check 1: In flow SEQUENCE context, ':' at start of line with content on previous line
                // means an implicit key spanning multiple lines, which is invalid in sequences
                // (Flow mappings allow key on one line, ':' on next)
                const in_flow_seq = self.flow_context_stack.items.len > 0 and
                    self.flow_context_stack.items[self.flow_context_stack.items.len - 1] == .sequence;
                if (is_val and in_flow_seq and start_pos > 0) {
                    var check = start_pos - 1;
                    // Skip whitespace to find newline
                    while (check > 0 and (self.input[check] == ' ' or self.input[check] == '\t')) check -= 1;
                    if (self.input[check] == '\n' or self.input[check] == '\r') {
                        // ':' is at start of line - check if there's content before the newline (implicit key)
                        if (check > 0) check -= 1;
                        if (check > 0 and self.input[check] == '\r') check -= 1;
                        // Skip whitespace on the previous line
                        while (check > 0 and (self.input[check] == ' ' or self.input[check] == '\t')) check -= 1;
                        // If the previous line has content (not just structural tokens), reject
                        if (check > 0) {
                            const prev_char = self.input[check];
                            // If prev_char is content (not {, [, ,, newline), this is a multiline implicit key
                            if (prev_char != '{' and prev_char != '[' and prev_char != ',' and prev_char != '\n' and prev_char != '\r') {
                                return error.UnexpectedCharacter;
                            }
                        }
                    }
                }

                // Check 2: In VALUE position (after ':'), content before newline + ':' at line start = missing comma
                if (is_val and self.flow_level > 0 and self.flow_after_value and start_pos > 0) {
                    var check = start_pos - 1;
                    // Skip whitespace to find newline
                    while (check > 0 and (self.input[check] == ' ' or self.input[check] == '\t')) check -= 1;
                    if (self.input[check] == '\n' or self.input[check] == '\r') {
                        // ':' is at start of line in VALUE position - check if there's content before the newline
                        // If so, that content was the value, and this ':' starts a new entry (missing comma)
                        if (check > 0) check -= 1;
                        if (check > 0 and self.input[check] == '\r') check -= 1;
                        // Skip whitespace on the previous line
                        while (check > 0 and (self.input[check] == ' ' or self.input[check] == '\t')) check -= 1;
                        // If the previous line has content (not just structural tokens), reject
                        if (check > 0) {
                            const prev_char = self.input[check];
                            // If prev_char is not a structural token ({, [, ,) or newline, there's content = missing comma
                            if (prev_char != '{' and prev_char != '[' and prev_char != ',' and prev_char != '\n' and prev_char != '\r') {
                                return error.UnexpectedCharacter;
                            }
                        }
                    }
                }
                if (is_val) {
                    // Check for tab in separator after ':' - tabs before indicators/keys are not allowed in block context
                    if (self.flow_level == 0) {
                        var ws_check = self.pos + 1;
                        var has_tab = false;
                        while (ws_check < self.input.len and (self.input[ws_check] == ' ' or self.input[ws_check] == '\t')) {
                            if (self.input[ws_check] == '\t') has_tab = true;
                            ws_check += 1;
                        }
                        if (has_tab and ws_check < self.input.len) {
                            const next_char = self.input[ws_check];
                            // Reject if we find another indicator after tabs
                            if (next_char == '-' or next_char == '?' or next_char == ':') {
                                return error.UnexpectedCharacter;
                            }
                            // Check for tab before key: pattern
                            var key_check = ws_check;
                            while (key_check < self.input.len and self.input[key_check] != ':' and self.input[key_check] != '\n' and self.input[key_check] != '\r') {
                                key_check += 1;
                            }
                            if (key_check < self.input.len and self.input[key_check] == ':') {
                                return error.UnexpectedCharacter;
                            }
                        }
                    }
                    if (self.flow_level == 0) {
                        const key_indent: i32 = @intCast(start_col - 1);
                        // Always unwind to this indent level first
                        try self.unwindIndent(key_indent);
                        // Check if ':' is at start of line (empty key) - may need block_map_start
                        var is_line_start = (start_pos == 0);
                        if (start_pos > 0) {
                            var check_pos = start_pos - 1;
                            while (check_pos > 0 and self.input[check_pos] == ' ') check_pos -= 1;
                            is_line_start = (check_pos == 0 and self.input[0] == ' ') or self.input[check_pos] == '\n';
                        }
                        if (is_line_start and self.indent < key_indent) {
                            try self.checkIndent(key_indent, false);
                        }
                        // Track that we emitted a value token on this line (for nested implicit key detection)
                        // Only for implicit keys (not at line start) - explicit key values can have mappings
                        if (!is_line_start) {
                            self.map_value_line = start_line;

                            // Check for block sequence entry on same line after ':' - this is invalid
                            // for implicit keys (e.g., "key: - a" should fail)
                            // Look ahead past ':' and whitespace to check for '-'
                            var seq_check = self.pos + 1; // pos is still at ':', so skip it
                            while (seq_check < self.input.len and self.input[seq_check] == ' ') seq_check += 1;
                            if (seq_check < self.input.len and self.input[seq_check] == '-') {
                                const after_dash = seq_check + 1;
                                if (after_dash >= self.input.len or isWsNl(self.input[after_dash])) {
                                    return error.UnexpectedCharacter;
                                }
                            }
                        }
                    }
                    self.advance();
                    if (self.flow_level > 0) self.flow_after_value = true;

                    const value_token = Token{ .type = .value, .start_line = start_line, .start_col = start_col, .start_offset = @intCast(start_pos), .end_offset = @intCast(self.pos) };
                    if (self.token_queue.items.len > 0) {
                        try self.token_queue.append(self.allocator, value_token);
                        return self.token_queue.orderedRemove(0);
                    }
                    return value_token;
                }
            },
            '&' => return try self.scanAnchor(),
            '*' => return try self.scanAlias(),
            '!' => return try self.scanTag(),
            '"' => return try self.scanDoubleQuoted(),
            '\'' => return try self.scanSingleQuoted(),
            '|', '>' => return try self.scanBlockScalar(c == '|'),
            else => {},
        }
        return try self.scanPlainScalar();
    }

    fn scanDirective(self: *Self) ScanError!Token {
        const start_line = self.line;
        const start_col = self.col;
        const start_pos = self.pos;

        // Directive after content without document end marker is invalid
        // (if there was a ..., seen_content would have been reset)
        // Also invalid if document was started with --- (directives must come before ---)
        if (self.seen_content or self.doc_started) {
            return error.InvalidDirective;
        }

        self.advance();
        const name_start = self.pos;
        while (self.pos < self.input.len and isNsChar(self.input[self.pos])) self.advance();
        const name = self.input[name_start..self.pos];
        while (self.pos < self.input.len and self.input[self.pos] == ' ') self.advance();
        var value_buf = std.ArrayList(u8){};
        defer value_buf.deinit(self.allocator);
        while (self.pos < self.input.len and self.input[self.pos] != '\n') {
            // '#' is only a comment if preceded by whitespace
            if (self.input[self.pos] == '#') {
                if (self.pos > 0 and isWs(self.input[self.pos - 1])) {
                    break; // Valid comment start
                } else {
                    return error.InvalidDirective; // '#' without preceding whitespace
                }
            }
            try value_buf.append(self.allocator, self.input[self.pos]);
            self.advance();
        }
        const value = std.mem.trim(u8, value_buf.items, " \t");
        const alloc_value = try self.allocator.dupe(u8, value);
        try self.allocated_strings.append(self.allocator, alloc_value);
        if (std.mem.eql(u8, name, "YAML")) {
            // Check for duplicate YAML directive
            if (self.seen_yaml_directive) {
                return error.InvalidDirective;
            }
            self.seen_yaml_directive = true;
            // %YAML directive: validate first version token, reject non-version-like extra content
            var parts = std.mem.splitScalar(u8, value, ' ');
            const version = parts.next() orelse "";
            // Version must be like "1.2" or "1.12345" (digit(s).digit(s))
            if (std.mem.indexOfScalar(u8, version, '.')) |dot_idx| {
                if (dot_idx == 0 or dot_idx == version.len - 1) {
                    return error.InvalidDirective;
                }
                for (version[0..dot_idx]) |c| {
                    if (!std.ascii.isDigit(c)) return error.InvalidDirective;
                }
                for (version[dot_idx + 1 ..]) |c| {
                    if (!std.ascii.isDigit(c)) return error.InvalidDirective;
                }
            } else {
                return error.InvalidDirective;
            }
            // Check for extra content that's not version-like (e.g., "foo")
            if (parts.next()) |extra| {
                // If extra content doesn't look like a version, reject
                if (std.mem.indexOfScalar(u8, extra, '.') == null) {
                    // Check if it's all digits (still invalid but tolerated per spec edge cases)
                    var all_digits = true;
                    for (extra) |c| {
                        if (!std.ascii.isDigit(c)) {
                            all_digits = false;
                            break;
                        }
                    }
                    if (!all_digits) {
                        return error.InvalidDirective;
                    }
                }
            }
        } else if (std.mem.eql(u8, name, "TAG")) {
            var parts = std.mem.splitScalar(u8, value, ' ');
            const handle = parts.next() orelse "";
            const prefix = parts.next() orelse "";
            if (handle.len > 0 and prefix.len > 0) {
                const h = try self.allocator.dupe(u8, handle);
                const p = try self.allocator.dupe(u8, prefix);
                try self.allocated_strings.append(self.allocator, h);
                try self.allocated_strings.append(self.allocator, p);
                try self.tag_directives.put(h, p);
            }
        }
        const alloc_name = try self.allocator.dupe(u8, name);
        try self.allocated_strings.append(self.allocator, alloc_name);
        self.pending_directive = true;
        return Token{ .type = .directive, .start_line = start_line, .start_col = start_col, .start_offset = @intCast(start_pos), .end_offset = @intCast(self.pos), .value = alloc_name, .tag_suffix = alloc_value };
    }

    fn scanAnchor(self: *Self) ScanError!Token {
        const start_line = self.line;
        const start_col = self.col;
        const start_pos = self.pos;
        self.advance();
        const name_start = self.pos;
        while (self.pos < self.input.len and isAnchorChar(self.input[self.pos])) self.advance();
        if (self.pos == name_start) return error.InvalidAnchorName;
        const name = self.input[name_start..self.pos];
        const alloc_name = try self.allocator.dupe(u8, name);
        try self.allocated_strings.append(self.allocator, alloc_name);

        const anchor_token = Token{ .type = .anchor, .start_line = start_line, .start_col = start_col, .start_offset = @intCast(start_pos), .end_offset = @intCast(self.pos), .value = alloc_name };

        // Check if this anchor starts a map key (anchor [scalar] :)
        if (self.flow_level == 0) {
            var look_pos = self.pos;
            // Skip whitespace
            while (look_pos < self.input.len and self.input[look_pos] == ' ') look_pos += 1;
            // Check for invalid anchor before sequence entry on same line
            if (look_pos < self.input.len and self.input[look_pos] == '-') {
                const after_dash = look_pos + 1;
                if (after_dash >= self.input.len or isWsNl(self.input[after_dash])) {
                    return error.UnexpectedCharacter;
                }
            }
            // Check for : directly, or skip plain scalar content then check for :
            var found_colon = false;
            if (look_pos < self.input.len and self.input[look_pos] == ':') {
                const next_after_colon = look_pos + 1;
                if (next_after_colon >= self.input.len or isWsNl(self.input[next_after_colon])) {
                    found_colon = true;
                }
            } else if (look_pos < self.input.len and !isWsNl(self.input[look_pos]) and self.input[look_pos] != ':') {
                // If next char is a flow indicator, anchor is for flow collection, not a map key
                const next_char = self.input[look_pos];
                if (next_char == '{' or next_char == '[') {
                    // Anchor is on a flow collection, not a map key - don't look for colon
                } else if (next_char == '*') {
                    // Next is an alias - this is anchor + alias, which is invalid
                    // But we still need to handle indentation properly if there's a ':' after
                    // Look past the alias for ':'
                    look_pos += 1;
                    while (look_pos < self.input.len and isAnchorChar(self.input[look_pos])) look_pos += 1;
                    while (look_pos < self.input.len and self.input[look_pos] == ' ') look_pos += 1;
                    if (look_pos < self.input.len and self.input[look_pos] == ':') {
                        const next_after_colon = look_pos + 1;
                        if (next_after_colon >= self.input.len or isWsNl(self.input[next_after_colon])) {
                            found_colon = true;
                        }
                    }
                } else if (next_char == '&') {
                    // Next is another anchor - don't skip it
                } else {
                    // Skip potential plain scalar content (until we hit ws, newline, or :)
                    while (look_pos < self.input.len) {
                        const c = self.input[look_pos];
                        if (c == '\n' or c == '\r') break;
                        if (c == ':' and (look_pos + 1 >= self.input.len or isWsNl(self.input[look_pos + 1]))) {
                            found_colon = true;
                            break;
                        }
                        look_pos += 1;
                    }
                }
            }
            if (found_colon) {
                // This anchor is part of a map key, emit block_map_start if needed
                const key_indent: i32 = @intCast(start_col - 1);
                try self.unwindIndent(key_indent);
                try self.checkIndent(key_indent, false);
                // Mark that a key started on this line (even if no block_map_start emitted)
                self.block_map_started_line = start_line;
                if (self.token_queue.items.len > 0) {
                    try self.token_queue.append(self.allocator, anchor_token);
                    return self.token_queue.orderedRemove(0);
                }
            } else {
                // Anchor is NOT a key - it's anchoring a value
                // Check: if anchor is at or below current indent level and at start of line,
                // it's at invalid indentation (value must be more indented than parent block)
                const anchor_indent: i32 = @intCast(start_col - 1);
                if (anchor_indent <= self.indent and self.indent >= 0 and start_col == 1) {
                    // Anchor at start of line at or below block indent - invalid
                    return error.UnexpectedCharacter;
                }
            }
        }

        return anchor_token;
    }

    fn scanAlias(self: *Self) ScanError!Token {
        const start_line = self.line;
        const start_col = self.col;
        const start_pos = self.pos;
        self.advance();
        const name_start = self.pos;
        while (self.pos < self.input.len and isAnchorChar(self.input[self.pos])) self.advance();
        if (self.pos == name_start) return error.InvalidAnchorName;
        const name = self.input[name_start..self.pos];
        const alloc_name = try self.allocator.dupe(u8, name);
        try self.allocated_strings.append(self.allocator, alloc_name);

        const alias_token = Token{ .type = .alias, .start_line = start_line, .start_col = start_col, .start_offset = @intCast(start_pos), .end_offset = @intCast(self.pos), .value = alloc_name };

        // Check if this alias is a map key (alias :)
        // But skip if a block_map_start was already emitted on this line (by anchor/tag)
        const already_started = self.block_map_started_line != null and self.block_map_started_line.? == start_line;
        if (self.flow_level == 0 and !already_started) {
            var look_pos = self.pos;
            // Skip whitespace
            while (look_pos < self.input.len and self.input[look_pos] == ' ') look_pos += 1;
            if (look_pos < self.input.len and self.input[look_pos] == ':') {
                const next_after_colon = look_pos + 1;
                if (next_after_colon >= self.input.len or isWsNl(self.input[next_after_colon])) {
                    // This alias is a map key, emit block_map_start if needed
                    const key_indent: i32 = @intCast(start_col - 1);
                    try self.unwindIndent(key_indent);
                    try self.checkIndent(key_indent, false);
                    if (self.token_queue.items.len > 0) {
                        self.block_map_started_line = start_line;
                        try self.token_queue.append(self.allocator, alias_token);
                        return self.token_queue.orderedRemove(0);
                    }
                }
            }
        }

        return alias_token;
    }

    fn scanTag(self: *Self) ScanError!Token {
        const start_line = self.line;
        const start_col = self.col;
        const start_pos = self.pos;
        self.advance();
        var handle: []const u8 = "!";
        var suffix: []const u8 = "";
        if (self.pos < self.input.len) {
            const ch = self.input[self.pos];
            if (ch == '<') {
                self.advance();
                const uri_start = self.pos;
                while (self.pos < self.input.len and self.input[self.pos] != '>') self.advance();
                suffix = self.input[uri_start..self.pos];
                if (self.pos < self.input.len) self.advance();
                handle = "";
            } else if (ch == '!') {
                self.advance();
                handle = "!!";
                const suffix_start = self.pos;
                while (self.pos < self.input.len and isTagChar(self.input[self.pos])) self.advance();
                suffix = self.input[suffix_start..self.pos];
            } else if (isTagChar(ch)) {
                const name_start = self.pos;
                while (self.pos < self.input.len and isTagChar(self.input[self.pos]) and self.input[self.pos] != '!') self.advance();
                if (self.pos < self.input.len and self.input[self.pos] == '!') {
                    handle = self.input[start_pos .. self.pos + 1];
                    self.advance();
                    const suffix_start = self.pos;
                    while (self.pos < self.input.len and isTagChar(self.input[self.pos])) self.advance();
                    suffix = self.input[suffix_start..self.pos];
                } else {
                    suffix = self.input[name_start..self.pos];
                }
            }
        }
        const alloc_handle = try self.allocator.dupe(u8, handle);
        const alloc_suffix = try self.allocator.dupe(u8, suffix);
        try self.allocated_strings.append(self.allocator, alloc_handle);
        try self.allocated_strings.append(self.allocator, alloc_suffix);
        const tag_token = Token{ .type = .tag, .start_line = start_line, .start_col = start_col, .start_offset = @intCast(start_pos), .end_offset = @intCast(self.pos), .tag_handle = alloc_handle, .tag_suffix = alloc_suffix };

        // Check if this tag starts a map key (tag [content] :)
        if (self.flow_level == 0) {
            const key_indent: i32 = @intCast(start_col - 1);
            var look_pos = self.pos;
            // Skip whitespace
            while (look_pos < self.input.len and self.input[look_pos] == ' ') look_pos += 1;
            // Check for : directly, or skip content then check for :
            var found_colon = false;
            if (look_pos < self.input.len and self.input[look_pos] == ':') {
                const next_after_colon = look_pos + 1;
                if (next_after_colon >= self.input.len or isWsNl(self.input[next_after_colon])) {
                    found_colon = true;
                }
            } else if (look_pos < self.input.len and !isWsNl(self.input[look_pos]) and self.input[look_pos] != ':') {
                // Skip potential content (until we hit ws, newline, or :)
                while (look_pos < self.input.len) {
                    const c = self.input[look_pos];
                    if (c == '\n' or c == '\r') break;
                    if (c == ':' and (look_pos + 1 >= self.input.len or isWsNl(self.input[look_pos + 1]))) {
                        found_colon = true;
                        break;
                    }
                    look_pos += 1;
                }
            }
            if (found_colon) {
                try self.unwindIndent(key_indent);
                try self.checkIndent(key_indent, false);
                if (self.token_queue.items.len > 0) {
                    self.block_map_started_line = start_line;
                    try self.token_queue.append(self.allocator, tag_token);
                    return self.token_queue.orderedRemove(0);
                }
            } else {
                // Tag is NOT a key - it's tagging a value
                // Check: if tag is at or below current indent level and at start of line,
                // it's at invalid indentation (value must be more indented than parent block)
                if (key_indent <= self.indent and self.indent >= 0 and start_col == 1) {
                    return error.UnexpectedCharacter;
                }
            }
        }
        return tag_token;
    }

    fn scanDoubleQuoted(self: *Self) ScanError!Token {
        const start_line = self.line;
        const start_col = self.col;
        const start_pos = self.pos;
        // Record start position for unterminated string errors
        self.error_line = start_line;
        self.error_col = start_col;
        self.error_offset = @intCast(start_pos);
        self.error_context = "in double-quoted string";
        self.advance();
        var result = std.ArrayList(u8){};
        errdefer result.deinit(self.allocator);
        var scalar_has_newline = false; // Track if scalar spans multiple lines
        var seen_space_on_continuation = false; // Track if any continuation line started with space
        while (self.pos < self.input.len) {
            const ch = self.input[self.pos];
            if (ch == '"') {
                self.advance();
                const val = try result.toOwnedSlice(self.allocator);
                try self.allocated_strings.append(self.allocator, val);
                try self.limit_checker.checkScalarSize(val.len);
                const scalar_token = Token{ .type = .scalar, .style = .double_quoted, .start_line = start_line, .start_col = start_col, .start_offset = @intCast(start_pos), .end_offset = @intCast(self.pos), .value = val };

                // Mark that we've seen content (for directive validation)
                self.seen_content = true;

                // Check if this quoted scalar is a map key (followed by ':')
                if (self.flow_level == 0) {
                    const key_indent: i32 = @intCast(start_col - 1);
                    var look_pos = self.pos;
                    while (look_pos < self.input.len and self.input[look_pos] == ' ') look_pos += 1;
                    if (look_pos < self.input.len and self.input[look_pos] == ':') {
                        const next_after_colon = look_pos + 1;
                        if (next_after_colon >= self.input.len or isWsNl(self.input[next_after_colon])) {
                            // Implicit keys cannot span multiple lines
                            if (scalar_has_newline) {
                                return error.UnexpectedCharacter;
                            }
                            // Reject nested implicit keys on the same line (e.g., "a: "b": c")
                            if (self.map_value_line != null and self.map_value_line.? == start_line) {
                                return error.UnexpectedCharacter;
                            }
                            try self.unwindIndent(key_indent);
                            try self.checkIndent(key_indent, false);
                            if (self.token_queue.items.len > 0) {
                                self.block_map_started_line = start_line;
                                try self.token_queue.append(self.allocator, scalar_token);
                                return self.token_queue.orderedRemove(0);
                            }
                        }
                    }
                } else {
                    // In flow context, ':' after quoted scalar is a value indicator
                    // Skip whitespace, comments, and newlines to find ':'
                    var look_pos = self.pos;
                    var crossed_newline = false;
                    while (look_pos < self.input.len) {
                        if (self.input[look_pos] == '\n' or self.input[look_pos] == '\r') {
                            crossed_newline = true;
                            look_pos += 1;
                        } else if (isWs(self.input[look_pos])) {
                            look_pos += 1;
                        } else if (self.input[look_pos] == '#') {
                            // Skip comment to end of line
                            while (look_pos < self.input.len and self.input[look_pos] != '\n' and self.input[look_pos] != '\r') look_pos += 1;
                        } else {
                            break;
                        }
                    }
                    if (look_pos < self.input.len and self.input[look_pos] == ':') {
                        // In flow SEQUENCE, implicit keys cannot span multiple lines
                        const in_flow_seq = self.flow_context_stack.items.len > 0 and
                            self.flow_context_stack.items[self.flow_context_stack.items.len - 1] == .sequence;
                        if (crossed_newline and in_flow_seq) {
                            return error.UnexpectedCharacter;
                        }
                        // Consume whitespace/comments up to and including the ':'
                        while (self.pos < look_pos) {
                            if (self.input[self.pos] == '\n' or self.input[self.pos] == '\r') {
                                self.advanceLine();
                            } else {
                                self.advance();
                            }
                        }
                        self.advance(); // consume the ':'
                        self.flow_after_value = true;
                        const value_token = Token{ .type = .value, .start_line = self.line, .start_col = self.col - 1, .start_offset = @intCast(look_pos), .end_offset = @intCast(self.pos) };
                        try self.token_queue.append(self.allocator, value_token);
                        try self.token_queue.insert(self.allocator, 0, scalar_token);
                        return self.token_queue.orderedRemove(0);
                    }
                }

                // Check for trailing content after quoted value (invalid in block context)
                if (self.flow_level == 0) {
                    const check_pos = skipSpacesFrom(self.input, self.pos);
                    // If there's non-whitespace that's not a valid continuation, it's an error
                    if (check_pos < self.input.len) {
                        const next = self.input[check_pos];
                        if (next != '\n' and next != '\r' and next != '#' and next != ':') {
                            return error.UnexpectedCharacter;
                        }
                    }
                }

                return scalar_token;
            }
            if (ch == '\\') {
                self.advance();
                if (self.pos >= self.input.len) return error.UnterminatedString;
                const esc = self.input[self.pos];
                switch (esc) {
                    '0' => {
                        try result.append(self.allocator, 0);
                        self.advance();
                    },
                    'a' => {
                        try result.append(self.allocator, 0x07); // Bell/Alert
                        self.advance();
                    },
                    'b' => {
                        try result.append(self.allocator, 0x08); // Backspace
                        self.advance();
                    },
                    't', 0x09 => {
                        try result.append(self.allocator, '\t');
                        self.advance();
                    },
                    'n' => {
                        try result.append(self.allocator, '\n');
                        self.advance();
                    },
                    'v' => {
                        try result.append(self.allocator, 0x0B); // Vertical tab
                        self.advance();
                    },
                    'f' => {
                        try result.append(self.allocator, 0x0C); // Form feed
                        self.advance();
                    },
                    'r' => {
                        try result.append(self.allocator, '\r');
                        self.advance();
                    },
                    'e' => {
                        try result.append(self.allocator, 0x1B); // Escape
                        self.advance();
                    },
                    '\\' => {
                        try result.append(self.allocator, '\\');
                        self.advance();
                    },
                    '"' => {
                        try result.append(self.allocator, '"');
                        self.advance();
                    },
                    '/' => {
                        try result.append(self.allocator, '/');
                        self.advance();
                    },
                    ' ' => {
                        try result.append(self.allocator, ' ');
                        self.advance();
                    },
                    'N' => {
                        // Next line (U+0085)
                        try result.appendSlice(self.allocator, "\xC2\x85");
                        self.advance();
                    },
                    '_' => {
                        // Non-breaking space (U+00A0)
                        try result.appendSlice(self.allocator, "\xC2\xA0");
                        self.advance();
                    },
                    'L' => {
                        // Line separator (U+2028)
                        try result.appendSlice(self.allocator, "\xE2\x80\xA8");
                        self.advance();
                    },
                    'P' => {
                        // Paragraph separator (U+2029)
                        try result.appendSlice(self.allocator, "\xE2\x80\xA9");
                        self.advance();
                    },
                    '\n', '\r' => {
                        self.advanceLine();
                        while (self.pos < self.input.len and (self.input[self.pos] == ' ' or self.input[self.pos] == '\t')) self.advance();
                    },
                    'x' => {
                        self.advance();
                        if (self.pos + 2 > self.input.len) return error.InvalidEscapeSequence;
                        const hex = self.input[self.pos .. self.pos + 2];
                        const cp: u21 = std.fmt.parseInt(u8, hex, 16) catch return error.InvalidEscapeSequence;
                        // Encode as UTF-8 (YAML spec: \xNN is equivalent to \u00NN)
                        var buf = std.mem.zeroes([4]u8);
                        const len = std.unicode.utf8Encode(cp, &buf) catch return error.InvalidEscapeSequence;
                        try result.appendSlice(self.allocator, buf[0..len]);
                        self.pos += 2;
                        self.col += 2;
                    },
                    'u' => {
                        self.advance();
                        if (self.pos + 4 > self.input.len) return error.InvalidEscapeSequence;
                        const hex = self.input[self.pos .. self.pos + 4];
                        const cp = std.fmt.parseInt(u21, hex, 16) catch return error.InvalidEscapeSequence;
                        var buf = std.mem.zeroes([4]u8);
                        const len = std.unicode.utf8Encode(cp, &buf) catch return error.InvalidEscapeSequence;
                        try result.appendSlice(self.allocator, buf[0..len]);
                        self.pos += 4;
                        self.col += 4;
                    },
                    'U' => {
                        self.advance();
                        if (self.pos + 8 > self.input.len) return error.InvalidEscapeSequence;
                        const hex = self.input[self.pos .. self.pos + 8];
                        const cp = std.fmt.parseInt(u21, hex, 16) catch return error.InvalidEscapeSequence;
                        var buf = std.mem.zeroes([4]u8);
                        const len = std.unicode.utf8Encode(cp, &buf) catch return error.InvalidEscapeSequence;
                        try result.appendSlice(self.allocator, buf[0..len]);
                        self.pos += 8;
                        self.col += 8;
                    },
                    else => return error.InvalidEscapeSequence,
                }
            } else if (ch == '\n' or ch == '\r') {
                scalar_has_newline = true;
                try result.append(self.allocator, ' ');
                self.advanceLine();
                // Check for document markers at column 1 (forbidden inside quoted strings)
                if (self.col == 1 and self.pos + 3 <= self.input.len) {
                    const marker = self.input[self.pos..][0..3];
                    if (std.mem.eql(u8, marker, "---") or std.mem.eql(u8, marker, "...")) {
                        const after_marker = self.pos + 3;
                        if (after_marker >= self.input.len or isWsNl(self.input[after_marker])) {
                            return error.UnexpectedCharacter;
                        }
                    }
                }
                // DK95-case2: Tab at start of continuation line is only valid if
                // a previous continuation line established leading whitespace with spaces
                if (self.pos < self.input.len and self.input[self.pos] == '\t') {
                    // Check if this tab is followed by content (not just whitespace/closing quote)
                    var look = self.pos + 1;
                    while (look < self.input.len and (self.input[look] == ' ' or self.input[look] == '\t')) look += 1;
                    if (look < self.input.len and self.input[look] != '"' and self.input[look] != '\n' and self.input[look] != '\r') {
                        // Tab before content - only valid if we've seen space on a previous line
                        if (!seen_space_on_continuation) {
                            return error.TabInIndentation;
                        }
                    }
                }
                // Track if this continuation starts with space (for future tab validation)
                if (self.pos < self.input.len and self.input[self.pos] == ' ') {
                    seen_space_on_continuation = true;
                }
                while (self.pos < self.input.len and (self.input[self.pos] == ' ' or self.input[self.pos] == '\t')) self.advance();
                // In block context, continuation lines must be indented beyond the current block level
                // Only check for actual content (not blank lines or closing quote)
                if (self.flow_level == 0 and self.pos < self.input.len) {
                    const next_ch = self.input[self.pos];
                    // Only check indentation for content (not newlines, quotes, or escape sequences)
                    if (next_ch != '\n' and next_ch != '\r' and next_ch != '"' and next_ch != '\\') {
                        const cont_col: i32 = @intCast(self.col);
                        // Continuation line indentation must be greater than current block indent
                        // (self.indent is the current block level)
                        if (cont_col <= self.indent + 1) {
                            return error.UnexpectedCharacter;
                        }
                    }
                }
            } else {
                try result.append(self.allocator, ch);
                self.advance();
            }
        }
        return error.UnterminatedString;
    }

    fn scanSingleQuoted(self: *Self) ScanError!Token {
        const start_line = self.line;
        const start_col = self.col;
        const start_pos = self.pos;
        // Record start position for unterminated string errors
        self.error_line = start_line;
        self.error_col = start_col;
        self.error_offset = @intCast(start_pos);
        self.error_context = "in single-quoted string";
        self.advance();
        var result = std.ArrayList(u8){};
        errdefer result.deinit(self.allocator);
        var scalar_has_newline = false; // Track if scalar spans multiple lines
        while (self.pos < self.input.len) {
            const ch = self.input[self.pos];
            if (ch == '\'') {
                if (self.pos + 1 < self.input.len and self.input[self.pos + 1] == '\'') {
                    try result.append(self.allocator, '\'');
                    self.advance();
                    self.advance();
                } else {
                    self.advance();
                    const val = try result.toOwnedSlice(self.allocator);
                    try self.allocated_strings.append(self.allocator, val);
                    try self.limit_checker.checkScalarSize(val.len);
                    const scalar_token = Token{ .type = .scalar, .style = .single_quoted, .start_line = start_line, .start_col = start_col, .start_offset = @intCast(start_pos), .end_offset = @intCast(self.pos), .value = val };

                    // Mark that we've seen content (for directive validation)
                    self.seen_content = true;

                    // Check if this quoted scalar is a map key (followed by ':')
                    if (self.flow_level == 0) {
                        const key_indent: i32 = @intCast(start_col - 1);
                        var look_pos = self.pos;
                        while (look_pos < self.input.len and self.input[look_pos] == ' ') look_pos += 1;
                        if (look_pos < self.input.len and self.input[look_pos] == ':') {
                            const next_after_colon = look_pos + 1;
                            if (next_after_colon >= self.input.len or isWsNl(self.input[next_after_colon])) {
                                // Implicit keys cannot span multiple lines
                                if (scalar_has_newline) {
                                    return error.UnexpectedCharacter;
                                }
                                // Reject nested implicit keys on the same line (e.g., "a: 'b': c")
                                if (self.map_value_line != null and self.map_value_line.? == start_line) {
                                    return error.UnexpectedCharacter;
                                }
                                try self.unwindIndent(key_indent);
                                try self.checkIndent(key_indent, false);
                                if (self.token_queue.items.len > 0) {
                                    self.block_map_started_line = start_line;
                                    try self.token_queue.append(self.allocator, scalar_token);
                                    return self.token_queue.orderedRemove(0);
                                }
                            }
                        }
                    } else {
                        // In flow context, ':' after quoted scalar is a value indicator
                        // Skip whitespace, comments, and newlines to find ':'
                        var look_pos = self.pos;
                        var crossed_newline = false;
                        while (look_pos < self.input.len) {
                            if (self.input[look_pos] == '\n' or self.input[look_pos] == '\r') {
                                crossed_newline = true;
                                look_pos += 1;
                            } else if (isWs(self.input[look_pos])) {
                                look_pos += 1;
                            } else if (self.input[look_pos] == '#') {
                                // Skip comment to end of line
                                while (look_pos < self.input.len and self.input[look_pos] != '\n' and self.input[look_pos] != '\r') look_pos += 1;
                            } else {
                                break;
                            }
                        }
                        if (look_pos < self.input.len and self.input[look_pos] == ':') {
                            // In flow SEQUENCE, implicit keys cannot span multiple lines
                            const in_flow_seq = self.flow_context_stack.items.len > 0 and
                                self.flow_context_stack.items[self.flow_context_stack.items.len - 1] == .sequence;
                            if (crossed_newline and in_flow_seq) {
                                return error.UnexpectedCharacter;
                            }
                            // Consume whitespace/comments up to and including the ':'
                            while (self.pos < look_pos) {
                                if (self.input[self.pos] == '\n' or self.input[self.pos] == '\r') {
                                    self.advanceLine();
                                } else {
                                    self.advance();
                                }
                            }
                            self.advance(); // consume the ':'
                            self.flow_after_value = true;
                            const value_token = Token{ .type = .value, .start_line = self.line, .start_col = self.col - 1, .start_offset = @intCast(look_pos), .end_offset = @intCast(self.pos) };
                            try self.token_queue.append(self.allocator, value_token);
                            try self.token_queue.insert(self.allocator, 0, scalar_token);
                            return self.token_queue.orderedRemove(0);
                        }
                    }

                    // Check for trailing content after quoted value (invalid in block context)
                    if (self.flow_level == 0) {
                        var check_pos = self.pos;
                        // Skip whitespace on the same line
                        while (check_pos < self.input.len and self.input[check_pos] == ' ') check_pos += 1;
                        // If there's non-whitespace that's not a valid continuation, it's an error
                        if (check_pos < self.input.len) {
                            const next = self.input[check_pos];
                            if (next != '\n' and next != '\r' and next != '#' and next != ':') {
                                return error.UnexpectedCharacter;
                            }
                        }
                    }

                    return scalar_token;
                }
            } else if (ch == '\n' or ch == '\r') {
                scalar_has_newline = true;
                try result.append(self.allocator, ' ');
                self.advanceLine();
                // Check for document markers at column 1 (forbidden inside quoted strings)
                if (self.col == 1 and self.pos + 3 <= self.input.len) {
                    const marker = self.input[self.pos..][0..3];
                    if (std.mem.eql(u8, marker, "---") or std.mem.eql(u8, marker, "...")) {
                        const after_marker = self.pos + 3;
                        if (after_marker >= self.input.len or isWsNl(self.input[after_marker])) {
                            return error.UnexpectedCharacter;
                        }
                    }
                }
                while (self.pos < self.input.len and (self.input[self.pos] == ' ' or self.input[self.pos] == '\t')) self.advance();
                // In block context, continuation lines must be indented beyond the current block level
                // Only check for actual content (not blank lines or closing quote)
                if (self.flow_level == 0 and self.pos < self.input.len) {
                    const next_ch = self.input[self.pos];
                    // Only check indentation for content (not newlines or quotes)
                    if (next_ch != '\n' and next_ch != '\r' and next_ch != '\'') {
                        const cont_col: i32 = @intCast(self.col);
                        // Continuation line indentation must be greater than current block indent
                        // (self.indent is the current block level)
                        if (cont_col <= self.indent + 1) {
                            return error.UnexpectedCharacter;
                        }
                    }
                }
            } else {
                try result.append(self.allocator, ch);
                self.advance();
            }
        }
        return error.UnterminatedString;
    }

    fn scanBlockScalar(self: *Self, is_literal: bool) ScanError!Token {
        const start_line = self.line;
        const start_col = self.col;
        const start_pos = self.pos;
        // Record start position for block scalar errors
        self.error_line = start_line;
        self.error_col = start_col;
        self.error_offset = @intCast(start_pos);
        self.error_context = if (is_literal) "in literal block scalar" else "in folded block scalar";
        self.advance();
        var chomping: Chomping = .clip;
        var explicit_indent: ?u32 = null;
        while (self.pos < self.input.len) {
            const ch = self.input[self.pos];
            if (ch == '-') {
                chomping = .strip;
                self.advance();
            } else if (ch == '+') {
                chomping = .keep;
                self.advance();
            } else if (ch >= '1' and ch <= '9') {
                explicit_indent = ch - '0';
                self.advance();
            } else if (ch == ' ' or ch == '\t') {
                self.advance();
            } else if (ch == '#') {
                // '#' is only a comment if preceded by whitespace
                const preceded_by_ws = (self.pos == 0) or isWsNl(self.input[self.pos - 1]);
                if (!preceded_by_ws) {
                    return error.InvalidBlockScalarHeader;
                }
                while (self.pos < self.input.len and self.input[self.pos] != '\n') self.advance();
                break;
            } else if (ch == '\n' or ch == '\r') {
                break;
            } else {
                return error.InvalidBlockScalarHeader;
            }
        }
        // Calculate header line's indentation (for explicit indent indicator)
        // We need to find how many leading spaces the header line had
        var header_line_indent: u32 = 0;
        if (start_pos > 0) {
            var line_start = start_pos - 1;
            while (line_start > 0 and self.input[line_start] != '\n') line_start -= 1;
            if (self.input[line_start] == '\n') line_start += 1;
            while (line_start < start_pos and self.input[line_start] == ' ') {
                header_line_indent += 1;
                line_start += 1;
            }
        }

        if (self.pos < self.input.len and (self.input[self.pos] == '\n' or self.input[self.pos] == '\r')) self.advanceLine();
        var content_indent: u32 = 0;
        // If explicit indent is given, use header_line_indent + explicit_indent
        // Otherwise, auto-detect from first non-empty content line
        if (explicit_indent) |ei| {
            content_indent = header_line_indent + ei;
        } else {
            // Auto-detect content indent from first non-empty line
            // Also track max whitespace in leading blank lines (must not exceed content indent)
            var temp_pos = self.pos;
            var max_leading_whitespace: u32 = 0;
            while (temp_pos < self.input.len) {
                var line_indent: u32 = 0;
                while (temp_pos < self.input.len and self.input[temp_pos] == ' ') {
                    line_indent += 1;
                    temp_pos += 1;
                }
                if (temp_pos < self.input.len and self.input[temp_pos] != '\n' and self.input[temp_pos] != '\r') {
                    // If the first content character is a tab with no prior spaces, it's an error
                    // (tabs cannot be used to establish indentation in block scalars)
                    if (self.input[temp_pos] == '\t' and line_indent == 0) {
                        return error.TabInIndentation;
                    }
                    content_indent = line_indent;
                    // Check: leading empty lines must not have more spaces than first content line
                    // (YAML spec 8.1.3)
                    if (max_leading_whitespace > content_indent) {
                        return error.UnexpectedCharacter;
                    }
                    break;
                }
                // Track max whitespace in this blank line
                if (line_indent > max_leading_whitespace) {
                    max_leading_whitespace = line_indent;
                }
                while (temp_pos < self.input.len and self.input[temp_pos] != '\n') temp_pos += 1;
                if (temp_pos < self.input.len) temp_pos += 1;
            }
        }
        var result = std.ArrayList(u8){};
        errdefer result.deinit(self.allocator);
        var trailing_newlines: usize = 0;
        while (self.pos < self.input.len) {
            var line_indent: u32 = 0;
            while (self.pos < self.input.len and self.input[self.pos] == ' ') {
                line_indent += 1;
                self.advance();
            }
            if (self.pos >= self.input.len) break;
            const ch = self.input[self.pos];
            if (ch == '\n' or ch == '\r') {
                trailing_newlines += 1;
                self.advanceLine();
                continue;
            }
            if (line_indent < content_indent) {
                self.pos -= line_indent;
                self.col -= line_indent;
                break;
            }
            if (result.items.len > 0) {
                if (is_literal) {
                    for (0..trailing_newlines) |_| try result.append(self.allocator, '\n');
                    if (trailing_newlines == 0) try result.append(self.allocator, '\n');
                } else {
                    if (trailing_newlines <= 1) try result.append(self.allocator, ' ') else for (0..trailing_newlines - 1) |_| try result.append(self.allocator, '\n');
                }
            }
            trailing_newlines = 0;
            if (is_literal and line_indent > content_indent) for (0..line_indent - content_indent) |_| try result.append(self.allocator, ' ');
            while (self.pos < self.input.len) {
                const c = self.input[self.pos];
                if (c == '\n' or c == '\r') break;
                try result.append(self.allocator, c);
                self.advance();
            }
        }
        switch (chomping) {
            .strip => while (result.items.len > 0 and result.items[result.items.len - 1] == '\n') {
                _ = result.pop();
            },
            .clip => {},
            .keep => for (0..trailing_newlines) |_| try result.append(self.allocator, '\n'),
        }
        const val = try result.toOwnedSlice(self.allocator);
        try self.allocated_strings.append(self.allocator, val);
        try self.limit_checker.checkScalarSize(val.len);
        // Mark that we've seen content (for directive validation)
        self.seen_content = true;
        return Token{ .type = .scalar, .style = if (is_literal) .literal else .folded, .start_line = start_line, .start_col = start_col, .start_offset = @intCast(start_pos), .end_offset = @intCast(self.pos), .value = val, .chomping = chomping };
    }

    fn scanPlainScalar(self: *Self) ScanError!Token {
        const start_line = self.line;
        const start_col = self.col;
        const start_pos = self.pos;

        // In flow context, certain indicators followed by space or flow indicators are not valid plain scalars
        // '-' followed by space or flow indicator would look like a block sequence entry
        if (self.flow_level > 0 and self.pos < self.input.len and self.input[self.pos] == '-') {
            const next_pos = self.pos + 1;
            if (next_pos >= self.input.len or isWsNl(self.input[next_pos]) or
                self.input[next_pos] == ',' or self.input[next_pos] == ']' or
                self.input[next_pos] == '}' or self.input[next_pos] == '[' or
                self.input[next_pos] == '{')
            {
                return error.UnexpectedCharacter;
            }
        }

        // For multi-line continuation, use the block's indent level, not scalar's start column
        const continuation_indent = self.indent;
        var result = std.ArrayList(u8){};
        errdefer result.deinit(self.allocator);
        var pending_newline = false;
        var ended_at_newline = false; // Track if scalar ended at reduced indentation
        var ended_with_comment = false; // Track if scalar ended due to comment on content line
        var was_multiline = false; // Track if scalar spanned multiple lines
        outer: while (self.pos < self.input.len) {
            const ch = self.input[self.pos];
            if (self.flow_level > 0 and (ch == ',' or ch == '[' or ch == ']' or ch == '{' or ch == '}')) break;
            if (ch == ':' and (self.pos + 1 >= self.input.len or isWsNl(self.input[self.pos + 1]) or (self.flow_level > 0 and (self.input[self.pos + 1] == ',' or self.input[self.pos + 1] == '[' or self.input[self.pos + 1] == ']' or self.input[self.pos + 1] == '{' or self.input[self.pos + 1] == '}')))) break;
            if (ch == '#' and self.pos > start_pos and isWs(self.input[self.pos - 1])) {
                ended_with_comment = true;
                break;
            }
            if (ch == '\n' or ch == '\r') {
                if (self.flow_level > 0) {
                    pending_newline = true;
                    self.advanceLine();
                    // Skip whitespace
                    while (self.pos < self.input.len and (self.input[self.pos] == ' ' or self.input[self.pos] == '\t')) self.advance();
                    // A comment line in flow context ends the plain scalar
                    // (the next line after the comment is a new entry)
                    if (self.pos < self.input.len and self.input[self.pos] == '#') {
                        break :outer;
                    }
                    // In flow context, if we're after a value indicator (':'),
                    // check if continuation would be a new key-value pair
                    // If so, end the scalar here to prevent consuming the new key
                    if (self.flow_after_value) {
                        // Check if what follows looks like a key (non-indicator followed by :)
                        if (self.pos < self.input.len) {
                            const next_ch = self.input[self.pos];
                            // If next content is a flow indicator or end of input, that's fine
                            if (next_ch != ',' and next_ch != '}' and next_ch != ']' and next_ch != '{' and next_ch != '[') {
                                // Look for : that would make this a key
                                var key_check = self.pos;
                                while (key_check < self.input.len and !isWsNl(self.input[key_check]) and
                                    self.input[key_check] != ':' and self.input[key_check] != ',' and
                                    self.input[key_check] != '{' and self.input[key_check] != '}' and
                                    self.input[key_check] != '[' and self.input[key_check] != ']')
                                {
                                    key_check += 1;
                                }
                                // Skip whitespace after potential key
                                while (key_check < self.input.len and (self.input[key_check] == ' ' or self.input[key_check] == '\t')) key_check += 1;
                                // If we find :, this would be a key-value - end scalar here
                                if (key_check < self.input.len and self.input[key_check] == ':') {
                                    break :outer;
                                }
                            }
                        }
                    }
                    continue;
                } else {
                    self.advanceLine();
                    while (self.pos < self.input.len and (self.input[self.pos] == '\n' or self.input[self.pos] == '\r')) self.advanceLine();
                    var next_indent: i32 = 0;
                    const check_pos = self.pos;
                    while (self.pos < self.input.len and self.input[self.pos] == ' ') {
                        next_indent += 1;
                        self.advance();
                    }
                    // Continuation must be more indented than the block's indent level
                    if (self.pos < self.input.len and next_indent > continuation_indent) {
                        // Check for comment line - comments end the plain scalar
                        if (self.input[self.pos] == '#') {
                            // Comment line at continuation indent - end the scalar here
                            self.pos = check_pos;
                            self.col = 1;
                            ended_at_newline = true;
                            ended_with_comment = true;
                            break :outer;
                        }
                        // Check for document markers (--- or ...) - these end the scalar
                        if (self.pos + 2 < self.input.len) {
                            const potential_marker = self.input[self.pos..][0..3];
                            if ((std.mem.eql(u8, potential_marker, "---") or std.mem.eql(u8, potential_marker, "...")) and
                                (self.pos + 3 >= self.input.len or isWsNl(self.input[self.pos + 3])))
                            {
                                // Document marker found - end the scalar
                                self.pos = check_pos;
                                self.col = 1;
                                ended_at_newline = true;
                                break :outer;
                            }
                        }
                        // Check if this line looks like a mapping entry (word:) - this is invalid in multiline plain scalar
                        var look_ahead = self.pos;
                        // Skip past potential key content
                        while (look_ahead < self.input.len and !isWsNl(self.input[look_ahead]) and self.input[look_ahead] != ':') {
                            look_ahead += 1;
                        }
                        // Skip whitespace after potential key
                        while (look_ahead < self.input.len and self.input[look_ahead] == ' ') look_ahead += 1;
                        // If we find ':' followed by whitespace/newline, this is a mapping entry - invalid in plain scalar
                        if (look_ahead < self.input.len and self.input[look_ahead] == ':') {
                            const after_colon = look_ahead + 1;
                            if (after_colon >= self.input.len or isWsNl(self.input[after_colon])) {
                                // A mapping entry inside a plain scalar continuation is invalid
                                return error.UnexpectedCharacter;
                            }
                        }
                        pending_newline = true;
                        was_multiline = true;
                        continue;
                    } else {
                        self.pos = check_pos;
                        self.col = 1;
                        ended_at_newline = true;
                        break :outer;
                    }
                }
            }
            if (pending_newline) {
                if (result.items.len > 0) try result.append(self.allocator, ' ');
                pending_newline = false;
            }
            try result.append(self.allocator, ch);
            self.advance();
        }
        while (result.items.len > 0 and (result.items[result.items.len - 1] == ' ' or result.items[result.items.len - 1] == '\t')) _ = result.pop();
        const val = try result.toOwnedSlice(self.allocator);
        try self.allocated_strings.append(self.allocator, val);
        try self.limit_checker.checkScalarSize(val.len);

        // If scalar ended with a comment (inline or on a continuation-like line), check for invalid continuation
        // A comment breaks continuation, so content at continuation-like indent after is invalid
        // Also check when scalar ended at newline AND there's a comment line followed by deeper content
        var check_for_invalid_after_comment = ended_with_comment;
        if (self.flow_level == 0 and ended_at_newline and !ended_with_comment) {
            // Check if we're positioned at a comment line - this means the scalar ended
            // because indent dropped, but there's a comment before potential deeper content
            var peek_pos = self.pos;
            while (peek_pos < self.input.len and self.input[peek_pos] == ' ') peek_pos += 1;
            if (peek_pos < self.input.len and self.input[peek_pos] == '#') {
                check_for_invalid_after_comment = true;
            }
        }
        if (self.flow_level == 0 and check_for_invalid_after_comment) {
            // Look ahead past the comment line to see what's next
            var look_pos = self.pos;
            // Skip to end of current line (past comment)
            while (look_pos < self.input.len and self.input[look_pos] != '\n' and self.input[look_pos] != '\r') look_pos += 1;
            // Skip newline(s)
            while (look_pos < self.input.len and (self.input[look_pos] == '\n' or self.input[look_pos] == '\r')) look_pos += 1;
            // Skip blank lines
            while (look_pos < self.input.len) {
                const line_start = look_pos;
                while (look_pos < self.input.len and self.input[look_pos] == ' ') look_pos += 1;
                if (look_pos < self.input.len and (self.input[look_pos] == '\n' or self.input[look_pos] == '\r')) {
                    while (look_pos < self.input.len and (self.input[look_pos] == '\n' or self.input[look_pos] == '\r')) look_pos += 1;
                    continue;
                }
                // Check if this line is a comment line
                if (look_pos < self.input.len and self.input[look_pos] == '#') {
                    // Skip comment line
                    while (look_pos < self.input.len and self.input[look_pos] != '\n' and self.input[look_pos] != '\r') look_pos += 1;
                    while (look_pos < self.input.len and (self.input[look_pos] == '\n' or self.input[look_pos] == '\r')) look_pos += 1;
                    continue;
                }
                // Found a content line - check its indentation
                const next_line_indent: i32 = @intCast(look_pos - line_start);
                if (look_pos < self.input.len and next_line_indent > continuation_indent) {
                    // Check for document markers (--- or ...) - these are valid at column 0
                    if (look_pos + 2 < self.input.len) {
                        const potential_marker = self.input[look_pos..][0..3];
                        if ((std.mem.eql(u8, potential_marker, "---") or std.mem.eql(u8, potential_marker, "...")) and
                            (look_pos + 3 >= self.input.len or isWsNl(self.input[look_pos + 3])))
                        {
                            break; // Document marker is valid
                        }
                    }
                    // Content at continuation indent after comment - this is invalid
                    // Check if it's a mapping entry (which would be valid structure)
                    var key_check = look_pos;
                    while (key_check < self.input.len and self.input[key_check] != ':' and self.input[key_check] != '\n' and self.input[key_check] != '\r') key_check += 1;
                    if (key_check < self.input.len and self.input[key_check] == ':') {
                        const after_colon = key_check + 1;
                        if (after_colon >= self.input.len or isWsNl(self.input[after_colon])) {
                            // It's a mapping entry - valid
                            break;
                        }
                    }
                    // Not a valid structure at continuation indent - error
                    return error.UnexpectedCharacter;
                }
                break;
            }
        }

        const scalar_token = Token{ .type = .scalar, .style = .plain, .start_line = start_line, .start_col = start_col, .start_offset = @intCast(start_pos), .end_offset = @intCast(self.pos), .value = val };

        // Mark that we've seen content (for directive validation)
        self.seen_content = true;

        // Check if this plain scalar is a map key (followed by ':')
        // But skip if scalar ended at newline (position moved back to start of next line)
        var is_map_key = false;
        if (self.flow_level == 0 and !ended_at_newline) {
            const key_indent: i32 = @intCast(start_col - 1);

            // Skip whitespace to check for ':'
            var look_pos = self.pos;
            while (look_pos < self.input.len and self.input[look_pos] == ' ') look_pos += 1;
            if (look_pos < self.input.len and self.input[look_pos] == ':') {
                const next_after_colon = look_pos + 1;
                if (next_after_colon >= self.input.len or isWsNl(self.input[next_after_colon])) {
                    is_map_key = true;
                    // Reject nested implicit keys on the same line (e.g., "a: b: c: d")
                    if (self.map_value_line != null and self.map_value_line.? == start_line) {
                        return error.UnexpectedCharacter;
                    }
                    // Skip block_map_start if already emitted on this line (by anchor/tag)
                    const already_started = self.block_map_started_line != null and self.block_map_started_line.? == start_line;
                    if (!already_started) {
                        // This is a map key - first unwind any higher indentation blocks
                        try self.unwindIndent(key_indent);
                        // Check: if mapping key is at same indent as a sequence block, reject
                        // (invalid mapping after sequence - BD7L)
                        if (key_indent == self.indent and self.is_sequence) {
                            return error.UnexpectedCharacter;
                        }
                        // Then emit block_map_start if needed
                        try self.checkIndent(key_indent, false);
                        // If any tokens were queued (block_ends or block_map_start), queue scalar and return from queue
                        if (self.token_queue.items.len > 0) {
                            self.block_map_started_line = start_line;
                            try self.token_queue.append(self.allocator, scalar_token);
                            return self.token_queue.orderedRemove(0);
                        }
                    }
                }
            }
        }

        // Check if bare scalar (not a key) is at block structure level - this is invalid
        // Skip this check if the scalar is a map key (followed by ':')
        // A bare scalar at the same indent as the current block is only valid after a block entry (-)
        if (self.flow_level == 0 and !is_map_key) {
            const scalar_indent: i32 = @intCast(start_col - 1);
            // First unwind to this indent level (in case we're at a lower indent than current block)
            try self.unwindIndent(scalar_indent);

            // If document already has a root value and we're at root level, this is a second root (invalid)
            if (self.has_root_value and self.indent < 0) {
                return error.UnexpectedCharacter;
            }

            // If scalar is at the current block level
            if (scalar_indent == self.indent and self.indent >= 0) {
                // Check if there was a block entry on this line (sequence item)
                const has_block_entry = self.block_entry_line != null and self.block_entry_line.? == start_line;
                // Check if there was a value indicator on this line (mapping value)
                const has_value_indicator = self.map_value_line != null and self.map_value_line.? == start_line;
                // If neither, this bare scalar at block level is invalid
                if (!has_block_entry and !has_value_indicator) {
                    return error.UnexpectedCharacter;
                }
            }
        }

        return scalar_token;
    }

    fn checkIndent(self: *Self, column: i32, is_seq: bool) ScanError!void {
        if (self.flow_level > 0) return;
        if (column > self.indent) {
            // Reject block mapping on same line as explicit document start (---)
            if (!is_seq and self.doc_start_line != null and self.doc_start_line.? == self.line) {
                return error.UnexpectedCharacter;
            }
            try self.indent_stack.append(self.allocator, self.indent);
            try self.block_type_stack.append(self.allocator, self.is_sequence);
            self.indent = column;
            self.is_sequence = is_seq;
            try self.token_queue.append(self.allocator, Token{ .type = if (is_seq) .block_seq_start else .block_map_start, .start_line = self.line, .start_col = @intCast(@max(0, column) + 1), .start_offset = @intCast(self.pos), .end_offset = @intCast(self.pos) });
        }
    }

    fn unwindIndent(self: *Self, column: i32) ScanError!void {
        if (self.flow_level > 0) return;
        while (self.indent > column) {
            try self.token_queue.append(self.allocator, Token{ .type = .block_end, .start_line = self.line, .start_col = self.col, .start_offset = @intCast(self.pos), .end_offset = @intCast(self.pos) });
            if (self.indent_stack.items.len > 0) {
                self.indent = self.indent_stack.pop().?;
            } else {
                self.indent = -1;
            }
            if (self.block_type_stack.items.len > 0) {
                self.is_sequence = self.block_type_stack.pop().?;
            } else {
                self.is_sequence = false;
            }
        }
    }

    fn checkDocStart(self: *Self) bool {
        if (self.pos + 3 > self.input.len) return false;
        if (!std.mem.eql(u8, self.input[self.pos .. self.pos + 3], "---")) return false;
        return self.pos + 3 >= self.input.len or isWsNl(self.input[self.pos + 3]);
    }

    fn checkDocEnd(self: *Self) bool {
        if (self.pos + 3 > self.input.len) return false;
        if (!std.mem.eql(u8, self.input[self.pos .. self.pos + 3], "...")) return false;
        return self.pos + 3 >= self.input.len or isWsNl(self.input[self.pos + 3]);
    }

    fn advance(self: *Self) void {
        if (self.pos < self.input.len) {
            self.pos += 1;
            self.col += 1;
        }
    }

    fn advanceLine(self: *Self) void {
        if (self.pos < self.input.len) {
            if (self.input[self.pos] == '\r') {
                self.pos += 1;
                if (self.pos < self.input.len and self.input[self.pos] == '\n') self.pos += 1;
            } else if (self.input[self.pos] == '\n') self.pos += 1;
            self.line += 1;
            self.col = 1;
            self.doc_start_line = null; // Clear doc_start_line when moving to new line
            self.map_value_line = null; // Clear map_value_line when moving to new line
            self.block_entry_line = null; // Clear block_entry_line when moving to new line
        }
    }

    pub fn resolveTag(self: *Self, handle: []const u8, suffix: []const u8) ![]const u8 {
        if (handle.len == 0) return suffix;
        if (self.tag_directives.get(handle)) |prefix| {
            const full = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ prefix, suffix });
            try self.allocated_strings.append(self.allocator, full);
            return full;
        }
        // Undefined tag handle is an error (only predefined handles ! and !! are valid without directives)
        return error.InvalidTagHandle;
    }
};

fn isWs(c: u8) bool {
    return c == ' ' or c == '\t';
}
fn isWsNl(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}
fn isNsChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '-' or c == '_';
}
fn isAnchorChar(c: u8) bool {
    // YAML 1.2: anchor names can contain any non-whitespace character except flow indicators
    if (isWsNl(c)) return false;
    return switch (c) {
        ',', '[', ']', '{', '}' => false,
        else => true,
    };
}
fn isTagChar(c: u8) bool {
    if (isWsNl(c)) return false;
    return switch (c) {
        ',', '[', ']', '{', '}', '<', '>' => false,
        else => true,
    };
}

// ============================================================================
// Lookahead Helper Functions
// ============================================================================

/// Result of a value indicator lookahead check
pub const ValueIndicatorResult = struct {
    /// True if a value indicator (colon followed by whitespace/end) was found
    found: bool,
    /// Position after the colon (if found)
    pos_after_colon: usize,
};

/// Skip spaces from a given position, returning the new position
fn skipSpacesFrom(input: []const u8, pos: usize) usize {
    var p = pos;
    while (p < input.len and input[p] == ' ') p += 1;
    return p;
}

/// Skip whitespace and newlines from a given position, returning the new position
fn skipWhitespaceFrom(input: []const u8, pos: usize) usize {
    var p = pos;
    while (p < input.len and isWsNl(input[p])) p += 1;
    return p;
}

/// Skip to end of line from a given position, returning position at newline or end
fn skipToEndOfLine(input: []const u8, pos: usize) usize {
    var p = pos;
    while (p < input.len and input[p] != '\n' and input[p] != '\r') p += 1;
    return p;
}

/// Skip a comment (from current position to end of line)
fn skipComment(input: []const u8, pos: usize) usize {
    if (pos < input.len and input[pos] == '#') {
        return skipToEndOfLine(input, pos);
    }
    return pos;
}

/// Check if position points to a value indicator (colon followed by whitespace or end)
fn isValueIndicatorAt(input: []const u8, pos: usize) ValueIndicatorResult {
    if (pos >= input.len or input[pos] != ':') {
        return .{ .found = false, .pos_after_colon = pos };
    }
    const next = pos + 1;
    if (next >= input.len or isWsNl(input[next])) {
        return .{ .found = true, .pos_after_colon = next };
    }
    return .{ .found = false, .pos_after_colon = pos };
}

/// Skip whitespace, newlines, and comments, returning the new position
fn skipWhitespaceAndComments(input: []const u8, pos: usize) usize {
    var p = pos;
    while (p < input.len) {
        if (input[p] == '\n' or input[p] == '\r') {
            p += 1;
        } else if (isWs(input[p])) {
            p += 1;
        } else if (input[p] == '#') {
            p = skipToEndOfLine(input, p);
        } else {
            break;
        }
    }
    return p;
}
