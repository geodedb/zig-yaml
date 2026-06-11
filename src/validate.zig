// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! YAML Schema Validation
//! Validates YAML documents against type schemas.

const std = @import("std");
const resolver = @import("resolver.zig");

pub const Value = resolver.Value;

/// Schema definition for validation
pub const Schema = union(enum) {
    /// Accept any value
    any,
    /// Null value only
    null,
    /// Boolean value
    bool,
    /// Integer value
    int,
    /// Float value (includes int, inf, nan)
    float,
    /// String value
    str,
    /// Sequence with item schema
    seq: *const Schema,
    /// Map with key and value schemas
    map: struct {
        key: *const Schema,
        value: *const Schema,
    },
    /// Object with named fields
    object: []const Field,
    /// One of multiple schemas (union type)
    one_of: []const *const Schema,
    /// Optional value (null or schema)
    optional: *const Schema,
    /// Enum of allowed string values
    enum_values: []const []const u8,
    /// Integer in range [min, max]
    int_range: struct {
        min: ?i64 = null,
        max: ?i64 = null,
    },
    /// String matching pattern
    pattern: []const u8,

    pub const Field = struct {
        name: []const u8,
        schema: *const Schema,
        required: bool = true,
    };
};

/// Validation error details
pub const ValidationError = struct {
    path: []const u8,
    message: []const u8,
    expected: []const u8,
    actual: []const u8,
};

/// Validation result
pub const ValidationResult = struct {
    valid: bool,
    errors: []ValidationError,

    pub fn deinit(self: *ValidationResult, allocator: std.mem.Allocator) void {
        for (self.errors) |err| {
            allocator.free(err.path);
            allocator.free(err.message);
            allocator.free(err.expected);
            allocator.free(err.actual);
        }
        allocator.free(self.errors);
    }
};

/// Validator for YAML values
pub const Validator = struct {
    allocator: std.mem.Allocator,
    errors: std.ArrayList(ValidationError),
    path_stack: std.ArrayList([]const u8),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .errors = .empty,
            .path_stack = .empty,
        };
    }

    pub fn deinit(self: *Self) void {
        self.errors.deinit(self.allocator);
        self.path_stack.deinit(self.allocator);
    }

    /// Validate a value against a schema
    pub fn validate(self: *Self, value: Value, s: Schema) !ValidationResult {
        self.errors.clearRetainingCapacity();
        self.path_stack.clearRetainingCapacity();

        try self.validateValue(value, s);

        const errors = try self.errors.toOwnedSlice(self.allocator);
        return ValidationResult{
            .valid = errors.len == 0,
            .errors = errors,
        };
    }

    fn validateValue(self: *Self, value: Value, schema: Schema) !void {
        switch (schema) {
            .any => {},
            .null => {
                if (value != .null) {
                    try self.addError("expected null", "null", self.valueTypeName(value));
                }
            },
            .bool => {
                if (value != .bool) {
                    try self.addError("expected boolean", "bool", self.valueTypeName(value));
                }
            },
            .int => {
                if (value != .int and value != .big_int) {
                    try self.addError("expected integer", "int", self.valueTypeName(value));
                }
            },
            .float => {
                switch (value) {
                    .int, .big_int, .float, .inf_pos, .inf_neg, .nan => {},
                    else => try self.addError("expected number", "float", self.valueTypeName(value)),
                }
            },
            .str => {
                if (value != .str) {
                    try self.addError("expected string", "str", self.valueTypeName(value));
                }
            },
            .seq => |item_schema| {
                if (value != .seq) {
                    try self.addError("expected sequence", "seq", self.valueTypeName(value));
                    return;
                }
                for (value.seq, 0..) |item, i| {
                    const idx_str = try std.fmt.allocPrint(self.allocator, "[{d}]", .{i});
                    defer self.allocator.free(idx_str);
                    try self.path_stack.append(self.allocator, idx_str);
                    defer _ = self.path_stack.pop();
                    try self.validateValue(item, item_schema.*);
                }
            },
            .map => |map_schema| {
                if (value != .map) {
                    try self.addError("expected map", "map", self.valueTypeName(value));
                    return;
                }
                for (value.map) |kv| {
                    // Validate key
                    try self.validateValue(kv.k, map_schema.key.*);
                    // Validate value
                    const key_str = try self.valueToString(kv.k);
                    defer self.allocator.free(key_str);
                    try self.path_stack.append(self.allocator, key_str);
                    defer _ = self.path_stack.pop();
                    try self.validateValue(kv.v, map_schema.value.*);
                }
            },
            .object => |fields| {
                if (value != .map) {
                    try self.addError("expected object", "object", self.valueTypeName(value));
                    return;
                }

                // Check required fields
                for (fields) |field| {
                    var found = false;
                    for (value.map) |kv| {
                        if (kv.k == .str and std.mem.eql(u8, kv.k.str, field.name)) {
                            found = true;
                            try self.path_stack.append(self.allocator, field.name);
                            defer _ = self.path_stack.pop();
                            try self.validateValue(kv.v, field.schema.*);
                            break;
                        }
                    }
                    if (!found and field.required) {
                        const msg = try std.fmt.allocPrint(self.allocator, "missing required field '{s}'", .{field.name});
                        try self.addErrorOwned(msg, "required", "missing");
                    }
                }
            },
            .one_of => |schemas| {
                var any_valid = false;
                for (schemas) |s| {
                    const initial_errors = self.errors.items.len;
                    try self.validateValue(value, s.*);
                    if (self.errors.items.len == initial_errors) {
                        any_valid = true;
                        break;
                    }
                    // Free the owned strings of the errors this failed attempt
                    // produced before dropping them, then reset for the next
                    // alternative (shrinkRetainingCapacity alone would leak them).
                    for (self.errors.items[initial_errors..]) |err| {
                        self.allocator.free(err.path);
                        self.allocator.free(err.message);
                        self.allocator.free(err.expected);
                        self.allocator.free(err.actual);
                    }
                    self.errors.shrinkRetainingCapacity(initial_errors);
                }
                if (!any_valid) {
                    try self.addError("value does not match any schema", "one_of", self.valueTypeName(value));
                }
            },
            .optional => |inner| {
                if (value != .null) {
                    try self.validateValue(value, inner.*);
                }
            },
            .enum_values => |allowed| {
                if (value != .str) {
                    try self.addError("expected string for enum", "enum", self.valueTypeName(value));
                    return;
                }
                var found = false;
                for (allowed) |a| {
                    if (std.mem.eql(u8, value.str, a)) {
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    const msg = try std.fmt.allocPrint(self.allocator, "value not in enum: got '{s}'", .{value.str});
                    try self.addErrorOwned(msg, "enum", value.str);
                }
            },
            .int_range => |range| {
                switch (value) {
                    .int => |iv| {
                        if (range.min) |min| {
                            if (iv < min) {
                                const msg = try std.fmt.allocPrint(self.allocator, "value {d} below minimum {d}", .{ iv, min });
                                try self.addErrorOwned(msg, ">=min", "<min");
                            }
                        }
                        if (range.max) |max| {
                            if (iv > max) {
                                const msg = try std.fmt.allocPrint(self.allocator, "value {d} above maximum {d}", .{ iv, max });
                                try self.addErrorOwned(msg, "<=max", ">max");
                            }
                        }
                    },
                    .big_int => |bv| {
                        // A big_int's magnitude exceeds i64 by construction, so a
                        // positive one is above any i64 max and a negative one is
                        // below any i64 min.
                        const negative = bv.len > 0 and bv[0] == '-';
                        if (negative and range.min != null) {
                            const msg = try std.fmt.allocPrint(self.allocator, "value {s} below minimum {d}", .{ bv, range.min.? });
                            try self.addErrorOwned(msg, ">=min", "<min");
                        } else if (!negative and range.max != null) {
                            const msg = try std.fmt.allocPrint(self.allocator, "value {s} above maximum {d}", .{ bv, range.max.? });
                            try self.addErrorOwned(msg, "<=max", ">max");
                        }
                    },
                    else => try self.addError("expected integer for range check", "int", self.valueTypeName(value)),
                }
            },
            .pattern => |pat| {
                if (value != .str) {
                    try self.addError("expected string for pattern", "string", self.valueTypeName(value));
                    return;
                }
                if (!globMatch(pat, value.str)) {
                    const msg = try std.fmt.allocPrint(self.allocator, "value '{s}' does not match pattern '{s}'", .{ value.str, pat });
                    try self.addErrorOwned(msg, pat, value.str);
                }
            },
        }
    }

    fn addError(self: *Self, message: []const u8, expected: []const u8, actual: []const u8) !void {
        try self.errors.append(self.allocator, .{
            .path = try self.currentPath(),
            .message = try self.allocator.dupe(u8, message),
            .expected = try self.allocator.dupe(u8, expected),
            .actual = try self.allocator.dupe(u8, actual),
        });
    }

    fn addErrorOwned(self: *Self, message: []u8, expected: []const u8, actual: []const u8) !void {
        try self.errors.append(self.allocator, .{
            .path = try self.currentPath(),
            .message = message, // Takes ownership
            .expected = try self.allocator.dupe(u8, expected),
            .actual = try self.allocator.dupe(u8, actual),
        });
    }

    fn currentPath(self: *Self) ![]u8 {
        if (self.path_stack.items.len == 0) {
            return try self.allocator.dupe(u8, "$");
        }
        var len: usize = 1; // for $
        for (self.path_stack.items) |p| {
            len += 1 + p.len; // . + segment
        }
        var buf = try self.allocator.alloc(u8, len);
        buf[0] = '$';
        var pos: usize = 1;
        for (self.path_stack.items) |p| {
            buf[pos] = '.';
            pos += 1;
            @memcpy(buf[pos..][0..p.len], p);
            pos += p.len;
        }
        return buf;
    }

    fn valueTypeName(_: *Self, value: Value) []const u8 {
        return switch (value) {
            .null => "null",
            .bool => "bool",
            .int, .big_int => "int",
            .float, .inf_pos, .inf_neg, .nan => "float",
            .str => "str",
            .seq => "seq",
            .map => "map",
        };
    }

    fn valueToString(self: *Self, value: Value) ![]u8 {
        return switch (value) {
            .str => |s| try self.allocator.dupe(u8, s),
            .int => |i| try std.fmt.allocPrint(self.allocator, "{d}", .{i}),
            .bool => |b| try self.allocator.dupe(u8, if (b) "true" else "false"),
            else => try self.allocator.dupe(u8, "<complex>"),
        };
    }
};

/// Convenience function to validate a value against a schema
pub fn validate(allocator: std.mem.Allocator, value: Value, schema: Schema) !ValidationResult {
    var validator = Validator.init(allocator);
    defer validator.deinit();
    return try validator.validate(value, schema);
}

// ============================================================================
// Common schema builders
// ============================================================================

/// Create a string enum schema
pub fn stringEnum(values: []const []const u8) Schema {
    return .{ .enum_values = values };
}

/// Create an optional schema
pub fn optional(comptime schema: Schema) Schema {
    const static = struct {
        const s = schema;
    };
    return .{ .optional = &static.s };
}

/// Create a sequence schema with item type
pub fn seqOf(comptime item: Schema) Schema {
    const static = struct {
        const s = item;
    };
    return .{ .seq = &static.s };
}

/// Create a map schema with key and value types
pub fn mapOf(comptime key: Schema, comptime value_schema: Schema) Schema {
    const static = struct {
        const k = key;
        const v = value_schema;
    };
    return .{ .map = .{ .key = &static.k, .value = &static.v } };
}

/// Create a string pattern schema. The pattern is glob-style:
/// `*` matches any (possibly empty) run of characters and `?` matches exactly
/// one character; all other characters match literally.
pub fn pattern(p: []const u8) Schema {
    return .{ .pattern = p };
}

/// Create a one-of (union) schema from a list of alternative schemas.
pub fn oneOf(schemas: []const *const Schema) Schema {
    return .{ .one_of = schemas };
}

/// Glob matcher: `*` = any run (incl. empty), `?` = exactly one char, else
/// literal. Iterative with backtracking — O(len(pat) * len(str)) worst case,
/// no allocation, no recursion.
pub fn globMatch(pat: []const u8, str: []const u8) bool {
    var p: usize = 0;
    var s: usize = 0;
    var star: ?usize = null; // index in pat just after the last '*'
    var star_s: usize = 0; // position in str when that '*' was taken
    while (s < str.len) {
        if (p < pat.len and (pat[p] == '?' or pat[p] == str[s])) {
            p += 1;
            s += 1;
        } else if (p < pat.len and pat[p] == '*') {
            star = p + 1;
            star_s = s;
            p += 1;
        } else if (star) |sp| {
            // Backtrack: let the last '*' absorb one more character.
            p = sp;
            star_s += 1;
            s = star_s;
        } else {
            return false;
        }
    }
    while (p < pat.len and pat[p] == '*') p += 1;
    return p == pat.len;
}

test "validate: globMatch basics" {
    try std.testing.expect(globMatch("*", "anything"));
    try std.testing.expect(globMatch("a*c", "abc"));
    try std.testing.expect(globMatch("a*c", "ac"));
    try std.testing.expect(globMatch("a?c", "abc"));
    try std.testing.expect(!globMatch("a?c", "ac"));
    try std.testing.expect(globMatch("*.txt", "file.txt"));
    try std.testing.expect(!globMatch("*.txt", "file.md"));
    try std.testing.expect(globMatch("v?.?.?", "v1.2.3"));
    try std.testing.expect(!globMatch("abc", "abcd"));
}
