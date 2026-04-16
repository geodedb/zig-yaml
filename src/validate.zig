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
                    // Reset errors for this schema attempt
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
                if (value != .int) {
                    try self.addError("expected integer for range check", "int", self.valueTypeName(value));
                    return;
                }
                if (range.min) |min| {
                    if (value.int < min) {
                        const msg = try std.fmt.allocPrint(self.allocator, "value {d} below minimum {d}", .{ value.int, min });
                        try self.addErrorOwned(msg, ">=min", "<min");
                    }
                }
                if (range.max) |max| {
                    if (value.int > max) {
                        const msg = try std.fmt.allocPrint(self.allocator, "value {d} above maximum {d}", .{ value.int, max });
                        try self.addErrorOwned(msg, "<=max", ">max");
                    }
                }
            },
            .pattern => {
                // Pattern matching would require regex support
                // For now, just validate it's a string
                if (value != .str) {
                    try self.addError("expected string for pattern", "string", self.valueTypeName(value));
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
