// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Limits and resource constraints for YAML parsing.
//! Provides protection against resource exhaustion attacks.

const std = @import("std");

/// Default limit constants
pub const defaults = struct {
    pub const max_bytes: usize = 8 * 1024 * 1024; // 8 MiB
    pub const max_depth: u16 = 200;
    pub const max_nodes: u32 = 1_000_000;
    pub const max_aliases: u32 = 5000;
    pub const max_scalar_bytes: usize = 1024 * 1024; // 1 MiB
};

/// Limit checker for tracking resource usage during parsing
pub const LimitChecker = struct {
    max_bytes: usize,
    max_depth: u16,
    max_nodes: u32,
    max_aliases: u32,
    max_scalar_bytes: usize,

    current_depth: u16 = 0,
    node_count: u32 = 0,
    alias_count: u32 = 0,

    pub fn init(opts: anytype) LimitChecker {
        const T = @TypeOf(opts);
        const has_max_bytes = @hasField(T, "max_bytes");
        const has_max_depth = @hasField(T, "max_depth");
        const has_max_nodes = @hasField(T, "max_nodes");
        const has_max_aliases = @hasField(T, "max_aliases");
        const has_max_scalar_bytes = @hasField(T, "max_scalar_bytes");

        return .{
            .max_bytes = if (has_max_bytes) opts.max_bytes else defaults.max_bytes,
            .max_depth = if (has_max_depth) opts.max_depth else defaults.max_depth,
            .max_nodes = if (has_max_nodes) opts.max_nodes else defaults.max_nodes,
            .max_aliases = if (has_max_aliases) opts.max_aliases else defaults.max_aliases,
            .max_scalar_bytes = if (has_max_scalar_bytes) opts.max_scalar_bytes else defaults.max_scalar_bytes,
        };
    }

    pub fn initFromParseOptions(opts: anytype) LimitChecker {
        return .{
            .max_bytes = opts.max_bytes,
            .max_depth = opts.max_depth,
            .max_nodes = opts.max_nodes,
            .max_aliases = opts.max_aliases,
            .max_scalar_bytes = opts.max_scalar_bytes,
        };
    }

    pub fn initWithDefaults() LimitChecker {
        return .{
            .max_bytes = defaults.max_bytes,
            .max_depth = defaults.max_depth,
            .max_nodes = defaults.max_nodes,
            .max_aliases = defaults.max_aliases,
            .max_scalar_bytes = defaults.max_scalar_bytes,
        };
    }

    pub fn checkInputSize(self: *const LimitChecker, size: usize) LimitError!void {
        if (size > self.max_bytes) return error.InputTooLarge;
    }

    pub fn checkScalarSize(self: *const LimitChecker, size: usize) LimitError!void {
        if (size > self.max_scalar_bytes) return error.ScalarTooLarge;
    }

    pub fn pushDepth(self: *LimitChecker) LimitError!void {
        if (self.current_depth >= self.max_depth) return error.MaxDepthExceeded;
        self.current_depth += 1;
    }

    pub fn popDepth(self: *LimitChecker) void {
        if (self.current_depth > 0) self.current_depth -= 1;
    }

    pub fn addNode(self: *LimitChecker) LimitError!void {
        if (self.node_count >= self.max_nodes) return error.MaxNodesExceeded;
        self.node_count += 1;
    }

    pub fn addAlias(self: *LimitChecker) LimitError!void {
        if (self.alias_count >= self.max_aliases) return error.MaxAliasesExceeded;
        self.alias_count += 1;
    }
};

pub const LimitError = error{
    InputTooLarge,
    ScalarTooLarge,
    MaxDepthExceeded,
    MaxNodesExceeded,
    MaxAliasesExceeded,
};

/// Validate UTF-8 encoding of input
pub fn validateUtf8(input: []const u8) error{InvalidUtf8}!void {
    if (!std.unicode.utf8ValidateSlice(input)) {
        return error.InvalidUtf8;
    }
}
