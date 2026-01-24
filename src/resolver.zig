// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! YAML 1.2.2 Schema Resolver
//! Resolves tags to values based on schema (failsafe, json, core).

const std = @import("std");
const composer = @import("composer.zig");
const parser = @import("parser.zig");

pub const Schema = parser.Schema;

pub const ValueKVPair = struct { k: Value, v: Value };

pub const Value = union(enum) {
    null,
    bool: bool,
    int: i64,
    big_int: []const u8,
    float: f64,
    inf_pos,
    inf_neg,
    nan,
    str: []const u8,
    seq: []Value,
    map: []ValueKVPair,
};

pub const ResolveError = error{
    UndefinedAnchor,
    AliasCycle,
    OutOfMemory,
};

pub fn resolveToValue(allocator: std.mem.Allocator, doc: *const composer.Document, opts: parser.ParseOptions) ResolveError!Value {
    var resolver = Resolver.init(allocator, doc, opts.schema);
    defer resolver.deinit();
    return try resolver.resolve(doc.root);
}

/// Recursively free all allocations inside a Value
pub fn freeValue(allocator: std.mem.Allocator, value: *const Value) void {
    switch (value.*) {
        .str => |s| allocator.free(s),
        .big_int => |s| allocator.free(s),
        .seq => |items| {
            for (items) |*item| {
                freeValue(allocator, item);
            }
            allocator.free(items);
        },
        .map => |items| {
            for (items) |*pair| {
                freeValue(allocator, &pair.k);
                freeValue(allocator, &pair.v);
            }
            allocator.free(items);
        },
        else => {},
    }
}

const Resolver = struct {
    allocator: std.mem.Allocator,
    doc: *const composer.Document,
    schema: Schema,
    visiting: std.AutoHashMap(composer.NodeId, void),
    resolved_cache: std.AutoHashMap(composer.NodeId, Value),

    fn init(allocator: std.mem.Allocator, doc: *const composer.Document, schema: Schema) Resolver {
        return .{
            .allocator = allocator,
            .doc = doc,
            .schema = schema,
            .visiting = std.AutoHashMap(composer.NodeId, void).init(allocator),
            .resolved_cache = std.AutoHashMap(composer.NodeId, Value).init(allocator),
        };
    }

    fn deinit(self: *Resolver) void {
        self.visiting.deinit();
        self.resolved_cache.deinit();
    }

    fn resolve(self: *Resolver, node_id: composer.NodeId) ResolveError!Value {
        // Check cycle
        if (self.visiting.contains(node_id)) {
            return error.AliasCycle;
        }

        // Check cache
        if (self.resolved_cache.get(node_id)) |cached| {
            return cached;
        }

        try self.visiting.put(node_id, {});
        defer _ = self.visiting.remove(node_id);

        const n = self.doc.node(node_id);
        const result = switch (n.*) {
            .s => |s| try self.resolveScalar(s.meta.tag, s.v),
            .q => |q| try self.resolveSeq(q),
            .m => |m| try self.resolveMap(m),
            .a => |alias_name| blk: {
                // Resolve alias
                const target_id = self.doc.resolveAnchor(alias_name) orelse return error.UndefinedAnchor;
                break :blk try self.resolve(target_id);
            },
        };

        try self.resolved_cache.put(node_id, result);
        return result;
    }

    fn resolveScalar(self: *Resolver, tag: []const u8, value: []const u8) ResolveError!Value {
        // Explicit tags override schema resolution
        if (!isNonSpecificTag(tag)) {
            return try self.resolveExplicitTag(tag, value);
        }

        // Schema-based resolution for non-specific tags
        return switch (self.schema) {
            .failsafe => Value{ .str = try self.allocator.dupe(u8, value) },
            .json => try self.resolveJsonSchema(value),
            .core => try self.resolveCoreSchema(value),
            .yaml11 => try self.resolveYaml11Schema(value),
        };
    }

    fn isNonSpecificTag(tag: []const u8) bool {
        return std.mem.eql(u8, tag, "!") or std.mem.eql(u8, tag, "?");
    }

    fn resolveExplicitTag(self: *Resolver, tag: []const u8, value: []const u8) ResolveError!Value {
        const full_tag = normalizeTag(tag);

        if (std.mem.eql(u8, full_tag, "tag:yaml.org,2002:null")) {
            return Value.null;
        }
        if (std.mem.eql(u8, full_tag, "tag:yaml.org,2002:bool")) {
            return Value{ .bool = parseBool(value) orelse false };
        }
        if (std.mem.eql(u8, full_tag, "tag:yaml.org,2002:int")) {
            if (parseInt(value)) |v| return Value{ .int = v };
            return Value{ .big_int = try self.allocator.dupe(u8, value) };
        }
        if (std.mem.eql(u8, full_tag, "tag:yaml.org,2002:float")) {
            return try self.parseFloat(value);
        }
        if (std.mem.eql(u8, full_tag, "tag:yaml.org,2002:str")) {
            return Value{ .str = try self.allocator.dupe(u8, value) };
        }

        // Unknown tag - treat as string
        return Value{ .str = try self.allocator.dupe(u8, value) };
    }

    fn normalizeTag(tag: []const u8) []const u8 {
        // Already full URI
        if (std.mem.startsWith(u8, tag, "tag:yaml.org,2002:")) {
            return tag;
        }
        // No normalization needed for non-standard tags
        return tag;
    }

    fn resolveJsonSchema(self: *Resolver, value: []const u8) ResolveError!Value {
        // JSON schema: null, bool, int, float
        if (std.mem.eql(u8, value, "null")) {
            return Value.null;
        }
        if (std.mem.eql(u8, value, "true")) {
            return Value{ .bool = true };
        }
        if (std.mem.eql(u8, value, "false")) {
            return Value{ .bool = false };
        }
        if (parseInt(value)) |v| {
            return Value{ .int = v };
        }
        if (parseStdFloat(value)) |v| {
            return Value{ .float = v };
        }
        return Value{ .str = try self.allocator.dupe(u8, value) };
    }

    fn resolveCoreSchema(self: *Resolver, value: []const u8) ResolveError!Value {
        // Null variants
        if (value.len == 0 or
            std.mem.eql(u8, value, "null") or
            std.mem.eql(u8, value, "Null") or
            std.mem.eql(u8, value, "NULL") or
            std.mem.eql(u8, value, "~"))
        {
            return Value.null;
        }

        // Boolean variants
        if (parseBool(value)) |b| {
            return Value{ .bool = b };
        }

        // Integer (decimal, octal, hex)
        if (parseInt(value)) |v| {
            return Value{ .int = v };
        }

        // Float (including .inf, .nan)
        const float_result = try self.parseFloat(value);
        switch (float_result) {
            .inf_pos, .inf_neg, .nan => return float_result,
            .float => return float_result,
            else => {},
        }

        // String fallback
        return Value{ .str = try self.allocator.dupe(u8, value) };
    }

    /// YAML 1.1 schema resolution
    /// Supports additional boolean literals (yes/no, on/off), 0-prefix octal,
    /// binary numbers, and sexagesimal notation.
    fn resolveYaml11Schema(self: *Resolver, value: []const u8) ResolveError!Value {
        // Null variants (same as core)
        if (value.len == 0 or
            std.mem.eql(u8, value, "null") or
            std.mem.eql(u8, value, "Null") or
            std.mem.eql(u8, value, "NULL") or
            std.mem.eql(u8, value, "~"))
        {
            return Value.null;
        }

        // YAML 1.1 boolean variants (case-insensitive)
        if (parseBool11(value)) |b| {
            return Value{ .bool = b };
        }

        // Integer (decimal, octal with 0 prefix, hex, binary, sexagesimal)
        if (parseInt11(value)) |v| {
            return Value{ .int = v };
        }

        // Float (including .inf, .nan, sexagesimal floats)
        const float_result = try self.parseFloat11(value);
        switch (float_result) {
            .inf_pos, .inf_neg, .nan => return float_result,
            .float => return float_result,
            else => {},
        }

        // String fallback
        return Value{ .str = try self.allocator.dupe(u8, value) };
    }

    fn parseFloat11(self: *Resolver, value: []const u8) ResolveError!Value {
        _ = self;
        // Check for infinity
        if (std.mem.eql(u8, value, ".inf") or
            std.mem.eql(u8, value, ".Inf") or
            std.mem.eql(u8, value, ".INF") or
            std.mem.eql(u8, value, "+.inf") or
            std.mem.eql(u8, value, "+.Inf") or
            std.mem.eql(u8, value, "+.INF"))
        {
            return Value.inf_pos;
        }
        if (std.mem.eql(u8, value, "-.inf") or
            std.mem.eql(u8, value, "-.Inf") or
            std.mem.eql(u8, value, "-.INF"))
        {
            return Value.inf_neg;
        }
        // Check for NaN
        if (std.mem.eql(u8, value, ".nan") or
            std.mem.eql(u8, value, ".NaN") or
            std.mem.eql(u8, value, ".NAN"))
        {
            return Value.nan;
        }

        // Standard float
        if (parseStdFloat(value)) |v| {
            return Value{ .float = v };
        }

        // Sexagesimal float (e.g., 1:30:00.5)
        if (parseSexagesimalFloat(value)) |v| {
            return Value{ .float = v };
        }

        // Not a float
        return Value{ .str = "" };
    }

    fn parseFloat(self: *Resolver, value: []const u8) ResolveError!Value {
        _ = self;
        // Check for infinity
        if (std.mem.eql(u8, value, ".inf") or
            std.mem.eql(u8, value, ".Inf") or
            std.mem.eql(u8, value, ".INF") or
            std.mem.eql(u8, value, "+.inf") or
            std.mem.eql(u8, value, "+.Inf") or
            std.mem.eql(u8, value, "+.INF"))
        {
            return Value.inf_pos;
        }
        if (std.mem.eql(u8, value, "-.inf") or
            std.mem.eql(u8, value, "-.Inf") or
            std.mem.eql(u8, value, "-.INF"))
        {
            return Value.inf_neg;
        }
        // Check for NaN
        if (std.mem.eql(u8, value, ".nan") or
            std.mem.eql(u8, value, ".NaN") or
            std.mem.eql(u8, value, ".NAN"))
        {
            return Value.nan;
        }

        // Standard float
        if (parseStdFloat(value)) |v| {
            return Value{ .float = v };
        }

        // Not a float
        return Value{ .str = "" };
    }

    fn resolveSeq(self: *Resolver, q: anytype) ResolveError!Value {
        var items = try self.allocator.alloc(Value, q.items.len);
        var resolved_count: usize = 0;
        errdefer {
            // Clean up already resolved items on error
            for (items[0..resolved_count]) |*item| {
                freeValue(self.allocator, item);
            }
            self.allocator.free(items);
        }
        for (q.items, 0..) |item_id, i| {
            items[i] = try self.resolve(item_id);
            resolved_count = i + 1;
        }
        return Value{ .seq = items };
    }

    fn resolveMap(self: *Resolver, m: anytype) ResolveError!Value {
        var items = try self.allocator.alloc(ValueKVPair, m.items.len);
        var resolved_count: usize = 0;
        var pending_key: ?Value = null;
        errdefer {
            // Clean up pending key if we failed while resolving value
            if (pending_key) |*k| {
                freeValue(self.allocator, k);
            }
            // Clean up already resolved pairs on error
            for (items[0..resolved_count]) |*pair| {
                freeValue(self.allocator, &pair.k);
                freeValue(self.allocator, &pair.v);
            }
            self.allocator.free(items);
        }
        for (m.items, 0..) |item, i| {
            const key = try self.resolve(item.k);
            pending_key = key;
            const val = try self.resolve(item.v);
            pending_key = null;
            items[i] = ValueKVPair{
                .k = key,
                .v = val,
            };
            resolved_count = i + 1;
        }
        return Value{ .map = items };
    }
};

fn parseBool(value: []const u8) ?bool {
    if (std.mem.eql(u8, value, "true") or
        std.mem.eql(u8, value, "True") or
        std.mem.eql(u8, value, "TRUE"))
    {
        return true;
    }
    if (std.mem.eql(u8, value, "false") or
        std.mem.eql(u8, value, "False") or
        std.mem.eql(u8, value, "FALSE"))
    {
        return false;
    }
    return null;
}

fn parseInt(value: []const u8) ?i64 {
    if (value.len == 0) return null;

    var s = value;
    var negative = false;

    if (s[0] == '+') {
        s = s[1..];
    } else if (s[0] == '-') {
        negative = true;
        s = s[1..];
    }

    if (s.len == 0) return null;

    // Octal: 0o...
    if (s.len > 2 and s[0] == '0' and (s[1] == 'o' or s[1] == 'O')) {
        const v = std.fmt.parseInt(i64, s[2..], 8) catch return null;
        return if (negative) -v else v;
    }

    // Hex: 0x...
    if (s.len > 2 and s[0] == '0' and (s[1] == 'x' or s[1] == 'X')) {
        const v = std.fmt.parseInt(i64, s[2..], 16) catch return null;
        return if (negative) -v else v;
    }

    // Decimal
    const v = std.fmt.parseInt(i64, s, 10) catch return null;
    return if (negative) -v else v;
}

fn parseStdFloat(value: []const u8) ?f64 {
    // Must contain . or e/E to be a float (not just an integer)
    var has_dot = false;
    var has_exp = false;
    for (value) |c| {
        if (c == '.') has_dot = true;
        if (c == 'e' or c == 'E') has_exp = true;
    }
    if (!has_dot and !has_exp) return null;

    return std.fmt.parseFloat(f64, value) catch null;
}

// ============================================================================
// YAML 1.1 Compatibility Functions
// ============================================================================

/// Parse YAML 1.1 boolean literals (case-insensitive)
/// Accepts: true/false, yes/no, on/off, y/n
fn parseBool11(value: []const u8) ?bool {
    // True variants
    if (std.ascii.eqlIgnoreCase(value, "true") or
        std.ascii.eqlIgnoreCase(value, "yes") or
        std.ascii.eqlIgnoreCase(value, "on") or
        std.ascii.eqlIgnoreCase(value, "y"))
    {
        return true;
    }
    // False variants
    if (std.ascii.eqlIgnoreCase(value, "false") or
        std.ascii.eqlIgnoreCase(value, "no") or
        std.ascii.eqlIgnoreCase(value, "off") or
        std.ascii.eqlIgnoreCase(value, "n"))
    {
        return false;
    }
    return null;
}

/// Parse YAML 1.1 integers (decimal, 0-prefix octal, 0x hex, 0b binary, sexagesimal)
fn parseInt11(value: []const u8) ?i64 {
    if (value.len == 0) return null;

    var s = value;
    var negative = false;

    if (s[0] == '+') {
        s = s[1..];
    } else if (s[0] == '-') {
        negative = true;
        s = s[1..];
    }

    if (s.len == 0) return null;

    // Check for sexagesimal (contains colons with digits, e.g., 1:30:00)
    if (std.mem.indexOfScalar(u8, s, ':') != null) {
        const v = parseSexagesimal(s) orelse return null;
        return if (negative) -v else v;
    }

    // Binary: 0b...
    if (s.len > 2 and s[0] == '0' and (s[1] == 'b' or s[1] == 'B')) {
        const v = std.fmt.parseInt(i64, s[2..], 2) catch return null;
        return if (negative) -v else v;
    }

    // Octal: 0o... (YAML 1.2 style)
    if (s.len > 2 and s[0] == '0' and (s[1] == 'o' or s[1] == 'O')) {
        const v = std.fmt.parseInt(i64, s[2..], 8) catch return null;
        return if (negative) -v else v;
    }

    // Hex: 0x...
    if (s.len > 2 and s[0] == '0' and (s[1] == 'x' or s[1] == 'X')) {
        const v = std.fmt.parseInt(i64, s[2..], 16) catch return null;
        return if (negative) -v else v;
    }

    // Octal: 0... (YAML 1.1 style - leading zero)
    if (s.len > 1 and s[0] == '0' and std.ascii.isDigit(s[1])) {
        // Check all remaining chars are octal digits
        for (s[1..]) |c| {
            if (c < '0' or c > '7') return null; // Not valid octal
        }
        const v = std.fmt.parseInt(i64, s, 8) catch return null;
        return if (negative) -v else v;
    }

    // Decimal (may contain underscores for readability in YAML 1.1)
    var buf: [64]u8 = undefined;
    var buf_len: usize = 0;
    for (s) |c| {
        if (c == '_') continue; // Skip underscores
        if (buf_len >= buf.len) return null;
        buf[buf_len] = c;
        buf_len += 1;
    }
    const v = std.fmt.parseInt(i64, buf[0..buf_len], 10) catch return null;
    return if (negative) -v else v;
}

/// Parse sexagesimal integer (base 60): 1:30:00 = 1*3600 + 30*60 + 0 = 5400
fn parseSexagesimal(value: []const u8) ?i64 {
    var result: i64 = 0;
    var current: i64 = 0;
    var has_digit = false;

    for (value) |c| {
        if (c == ':') {
            if (!has_digit) return null; // Empty segment
            result = result * 60 + current;
            current = 0;
            has_digit = false;
        } else if (std.ascii.isDigit(c)) {
            current = current * 10 + @as(i64, c - '0');
            has_digit = true;
        } else {
            return null; // Invalid character
        }
    }

    if (!has_digit) return null; // Trailing colon or empty
    return result * 60 + current;
}

/// Parse sexagesimal float (base 60 with decimal part): 1:30:00.5
fn parseSexagesimalFloat(value: []const u8) ?f64 {
    // Must contain a colon to be sexagesimal
    const colon_pos = std.mem.indexOfScalar(u8, value, ':') orelse return null;
    _ = colon_pos;

    // Find the decimal point if present
    const dot_pos = std.mem.indexOfScalar(u8, value, '.');

    var int_part: []const u8 = undefined;
    var frac_part: ?[]const u8 = null;

    if (dot_pos) |dp| {
        int_part = value[0..dp];
        frac_part = value[dp + 1 ..];
    } else {
        int_part = value;
    }

    // Parse the integer part as sexagesimal
    const int_val = parseSexagesimal(int_part) orelse return null;
    var result = @as(f64, @floatFromInt(int_val));

    // Add fractional part if present
    if (frac_part) |fp| {
        const frac = std.fmt.parseFloat(f64, fp) catch return null;
        var divisor: f64 = 1.0;
        for (0..fp.len) |_| {
            divisor *= 10.0;
        }
        result += frac / divisor;
    }

    return result;
}

/// Get canonical tag for a resolved value (for debug output)
pub fn getCanonicalTag(value: Value) []const u8 {
    return switch (value) {
        .null => "!!null",
        .bool => "!!bool",
        .int, .big_int => "!!int",
        .float, .inf_pos, .inf_neg, .nan => "!!float",
        .str => "!!str",
        .seq => "!!seq",
        .map => "!!map",
    };
}

// ============================================================================
// Tests
// ============================================================================

test "resolver: YAML 1.1 boolean yes/no" {
    try std.testing.expect(parseBool11("yes").? == true);
    try std.testing.expect(parseBool11("Yes").? == true);
    try std.testing.expect(parseBool11("YES").? == true);
    try std.testing.expect(parseBool11("no").? == false);
    try std.testing.expect(parseBool11("No").? == false);
    try std.testing.expect(parseBool11("NO").? == false);
}

test "resolver: YAML 1.1 boolean on/off" {
    try std.testing.expect(parseBool11("on").? == true);
    try std.testing.expect(parseBool11("On").? == true);
    try std.testing.expect(parseBool11("ON").? == true);
    try std.testing.expect(parseBool11("off").? == false);
    try std.testing.expect(parseBool11("Off").? == false);
    try std.testing.expect(parseBool11("OFF").? == false);
}

test "resolver: YAML 1.1 boolean y/n" {
    try std.testing.expect(parseBool11("y").? == true);
    try std.testing.expect(parseBool11("Y").? == true);
    try std.testing.expect(parseBool11("n").? == false);
    try std.testing.expect(parseBool11("N").? == false);
}

test "resolver: YAML 1.1 boolean true/false" {
    try std.testing.expect(parseBool11("true").? == true);
    try std.testing.expect(parseBool11("True").? == true);
    try std.testing.expect(parseBool11("TRUE").? == true);
    try std.testing.expect(parseBool11("false").? == false);
    try std.testing.expect(parseBool11("False").? == false);
    try std.testing.expect(parseBool11("FALSE").? == false);
}

test "resolver: YAML 1.1 octal with leading zero" {
    // 0755 = 493 in decimal
    try std.testing.expectEqual(@as(?i64, 493), parseInt11("0755"));
    // 010 = 8 in decimal
    try std.testing.expectEqual(@as(?i64, 8), parseInt11("010"));
    // Negative
    try std.testing.expectEqual(@as(?i64, -493), parseInt11("-0755"));
}

test "resolver: YAML 1.1 binary integers" {
    try std.testing.expectEqual(@as(?i64, 5), parseInt11("0b101"));
    try std.testing.expectEqual(@as(?i64, 255), parseInt11("0b11111111"));
    try std.testing.expectEqual(@as(?i64, 15), parseInt11("0B1111"));
    try std.testing.expectEqual(@as(?i64, -5), parseInt11("-0b101"));
}

test "resolver: YAML 1.1 sexagesimal integers" {
    // 1:30:00 = 1*3600 + 30*60 + 0 = 5400
    try std.testing.expectEqual(@as(?i64, 5400), parseInt11("1:30:00"));
    // 1:30 = 1*60 + 30 = 90
    try std.testing.expectEqual(@as(?i64, 90), parseInt11("1:30"));
    // 10:20:30 = 10*3600 + 20*60 + 30 = 37230
    try std.testing.expectEqual(@as(?i64, 37230), parseInt11("10:20:30"));
    // Negative
    try std.testing.expectEqual(@as(?i64, -90), parseInt11("-1:30"));
}

test "resolver: YAML 1.1 underscores in integers" {
    try std.testing.expectEqual(@as(?i64, 1000000), parseInt11("1_000_000"));
    try std.testing.expectEqual(@as(?i64, -1000), parseInt11("-1_000"));
}

test "resolver: YAML 1.1 sexagesimal floats" {
    // 1:30 as float = 90.0
    try std.testing.expectApproxEqAbs(@as(f64, 90.0), parseSexagesimalFloat("1:30").?, 0.001);
    // 1:30.5 = 90.5
    try std.testing.expectApproxEqAbs(@as(f64, 90.5), parseSexagesimalFloat("1:30.5").?, 0.001);
}

test "resolver: YAML 1.2 core integers still work" {
    // YAML 1.2 octal with 0o prefix
    try std.testing.expectEqual(@as(?i64, 493), parseInt("0o755"));
    try std.testing.expectEqual(@as(?i64, 255), parseInt("0xff"));
    try std.testing.expectEqual(@as(?i64, 42), parseInt("42"));
}

test "resolver: parseInt11 handles hex" {
    try std.testing.expectEqual(@as(?i64, 255), parseInt11("0xff"));
    try std.testing.expectEqual(@as(?i64, 16), parseInt11("0x10"));
    try std.testing.expectEqual(@as(?i64, -255), parseInt11("-0xFF"));
}
