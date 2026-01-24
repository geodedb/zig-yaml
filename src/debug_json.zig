// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Debug JSON helpers for deterministic test output.
//! Provides compact JSON representations of YAML documents and values.

const std = @import("std");
const resolver = @import("resolver.zig");
const composer = @import("composer.zig");

/// Serialize resolved values to compact JSON: {"d":[ ... ]}
/// Maps are encoded as {"@":[[k,v],...]}
pub fn debugJsonValue(allocator: std.mem.Allocator, vals: []const resolver.Value) ![]u8 {
    var buffer = std.ArrayList(u8){};
    errdefer buffer.deinit(allocator);

    try buffer.appendSlice(allocator, "{\"d\":[");

    for (vals, 0..) |val, i| {
        if (i > 0) try buffer.append(allocator, ',');
        try writeValue(allocator, &buffer, val);
    }

    try buffer.appendSlice(allocator, "]}");

    return buffer.toOwnedSlice(allocator);
}

/// Serialize document graph to compact JSON with node details.
/// scalar: {"k":"s","t":"!!str","v":"x","a":"ANCHOR"?}
/// seq: {"k":"q","i":[...]}
/// map: {"k":"m","i":[[K,V],...]}
/// alias: {"k":"*","r":"ANCHOR"}
pub fn debugJsonGraph(allocator: std.mem.Allocator, docs: []const composer.Document) ![]u8 {
    var buffer = std.ArrayList(u8){};
    errdefer buffer.deinit(allocator);

    try buffer.appendSlice(allocator, "{\"d\":[");

    for (docs, 0..) |doc, i| {
        if (i > 0) try buffer.append(allocator, ',');
        try writeGraphNode(allocator, &buffer, &doc, doc.root);
    }

    try buffer.appendSlice(allocator, "]}");

    return buffer.toOwnedSlice(allocator);
}

fn writeValue(allocator: std.mem.Allocator, buffer: *std.ArrayList(u8), val: resolver.Value) !void {
    switch (val) {
        .null => try buffer.appendSlice(allocator, "null"),
        .bool => |b| try buffer.appendSlice(allocator, if (b) "true" else "false"),
        .int => |n| {
            var buf: [32]u8 = undefined;
            const str = std.fmt.bufPrint(&buf, "{d}", .{n}) catch unreachable;
            try buffer.appendSlice(allocator, str);
        },
        .big_int => |s| {
            try buffer.append(allocator, '"');
            try buffer.appendSlice(allocator, s);
            try buffer.append(allocator, '"');
        },
        .float => |f| {
            var buf: [64]u8 = undefined;
            const str = std.fmt.bufPrint(&buf, "{d}", .{f}) catch unreachable;
            try buffer.appendSlice(allocator, str);
        },
        .inf_pos => try buffer.appendSlice(allocator, "\".inf\""),
        .inf_neg => try buffer.appendSlice(allocator, "\"-.inf\""),
        .nan => try buffer.appendSlice(allocator, "\".nan\""),
        .str => |s| try writeJsonString(allocator, buffer, s),
        .seq => |items| {
            try buffer.append(allocator, '[');
            for (items, 0..) |item, i| {
                if (i > 0) try buffer.append(allocator, ',');
                try writeValue(allocator, buffer, item);
            }
            try buffer.append(allocator, ']');
        },
        .map => |items| {
            try buffer.appendSlice(allocator, "{\"@\":[");
            for (items, 0..) |item, i| {
                if (i > 0) try buffer.append(allocator, ',');
                try buffer.append(allocator, '[');
                try writeValue(allocator, buffer, item.k);
                try buffer.append(allocator, ',');
                try writeValue(allocator, buffer, item.v);
                try buffer.append(allocator, ']');
            }
            try buffer.appendSlice(allocator, "]}");
        },
    }
}

fn writeGraphNode(allocator: std.mem.Allocator, buffer: *std.ArrayList(u8), doc: *const composer.Document, node_id: composer.NodeId) !void {
    const node = doc.node(node_id);

    switch (node.*) {
        .s => |s| {
            try buffer.appendSlice(allocator, "{\"k\":\"s\",\"t\":\"");
            // For non-specific tags, infer the canonical tag from the value
            const tag = if (isNonSpecificTag(s.meta.tag))
                inferScalarTag(s.v, .core)
            else
                compressTag(s.meta.tag);
            try buffer.appendSlice(allocator, tag);
            try buffer.appendSlice(allocator, "\",\"v\":");
            try writeJsonString(allocator, buffer, s.v);
            if (s.meta.anchor) |anchor| {
                try buffer.appendSlice(allocator, ",\"a\":\"");
                try buffer.appendSlice(allocator, anchor);
                try buffer.append(allocator, '"');
            }
            try buffer.append(allocator, '}');
        },
        .q => |q| {
            try buffer.appendSlice(allocator, "{\"k\":\"q\"");
            if (q.meta.anchor) |anchor| {
                try buffer.appendSlice(allocator, ",\"a\":\"");
                try buffer.appendSlice(allocator, anchor);
                try buffer.append(allocator, '"');
            }
            try buffer.appendSlice(allocator, ",\"i\":[");
            for (q.items, 0..) |item_id, i| {
                if (i > 0) try buffer.append(allocator, ',');
                try writeGraphNode(allocator, buffer, doc, item_id);
            }
            try buffer.appendSlice(allocator, "]}");
        },
        .m => |m| {
            try buffer.appendSlice(allocator, "{\"k\":\"m\"");
            if (m.meta.anchor) |anchor| {
                try buffer.appendSlice(allocator, ",\"a\":\"");
                try buffer.appendSlice(allocator, anchor);
                try buffer.append(allocator, '"');
            }
            try buffer.appendSlice(allocator, ",\"i\":[");
            for (m.items, 0..) |item, i| {
                if (i > 0) try buffer.append(allocator, ',');
                try buffer.append(allocator, '[');
                try writeGraphNode(allocator, buffer, doc, item.k);
                try buffer.append(allocator, ',');
                try writeGraphNode(allocator, buffer, doc, item.v);
                try buffer.append(allocator, ']');
            }
            try buffer.appendSlice(allocator, "]}");
        },
        .a => |alias_name| {
            try buffer.appendSlice(allocator, "{\"k\":\"*\",\"r\":\"");
            try buffer.appendSlice(allocator, alias_name);
            try buffer.appendSlice(allocator, "\"}");
        },
    }
}

fn writeJsonString(allocator: std.mem.Allocator, buffer: *std.ArrayList(u8), s: []const u8) !void {
    try buffer.append(allocator, '"');
    for (s) |c| {
        switch (c) {
            '"' => try buffer.appendSlice(allocator, "\\\""),
            '\\' => try buffer.appendSlice(allocator, "\\\\"),
            '\n' => try buffer.appendSlice(allocator, "\\n"),
            '\r' => try buffer.appendSlice(allocator, "\\r"),
            '\t' => try buffer.appendSlice(allocator, "\\t"),
            0x00...0x08, 0x0B, 0x0C, 0x0E...0x1F => {
                var buf: [6]u8 = undefined;
                const hex = std.fmt.bufPrint(&buf, "\\u{X:0>4}", .{c}) catch unreachable;
                try buffer.appendSlice(allocator, hex);
            },
            else => try buffer.append(allocator, c),
        }
    }
    try buffer.append(allocator, '"');
}

/// Compress standard YAML tags to short form
fn compressTag(tag: []const u8) []const u8 {
    if (std.mem.eql(u8, tag, "tag:yaml.org,2002:null") or std.mem.eql(u8, tag, "!")) {
        // For non-specific tag, determine type from context (done elsewhere)
        // Return as-is for now
    }
    if (std.mem.eql(u8, tag, "tag:yaml.org,2002:null")) return "!!null";
    if (std.mem.eql(u8, tag, "tag:yaml.org,2002:bool")) return "!!bool";
    if (std.mem.eql(u8, tag, "tag:yaml.org,2002:int")) return "!!int";
    if (std.mem.eql(u8, tag, "tag:yaml.org,2002:float")) return "!!float";
    if (std.mem.eql(u8, tag, "tag:yaml.org,2002:str")) return "!!str";
    if (std.mem.eql(u8, tag, "tag:yaml.org,2002:seq")) return "!!seq";
    if (std.mem.eql(u8, tag, "tag:yaml.org,2002:map")) return "!!map";
    return tag;
}

/// Get resolved tag for a graph node (inferring type for non-specific tags)
pub fn getResolvedTag(doc: *const composer.Document, node_id: composer.NodeId, schema: resolver.Schema) []const u8 {
    const node = doc.node(node_id);

    switch (node.*) {
        .s => |s| {
            // If explicit tag, use it
            if (!isNonSpecificTag(s.meta.tag)) {
                return compressTag(s.meta.tag);
            }
            // Infer tag from value based on schema
            return inferScalarTag(s.v, schema);
        },
        .q => return "!!seq",
        .m => return "!!map",
        .a => return "!!alias", // Not a real tag, just for debug
    }
}

fn isNonSpecificTag(tag: []const u8) bool {
    return std.mem.eql(u8, tag, "!") or std.mem.eql(u8, tag, "?") or tag.len == 0;
}

fn inferScalarTag(value: []const u8, schema: resolver.Schema) []const u8 {
    switch (schema) {
        .failsafe => return "!!str",
        .json, .core => {
            // Null
            if (value.len == 0 or
                std.mem.eql(u8, value, "null") or
                std.mem.eql(u8, value, "Null") or
                std.mem.eql(u8, value, "NULL") or
                std.mem.eql(u8, value, "~"))
            {
                return "!!null";
            }
            // Bool
            if (std.mem.eql(u8, value, "true") or
                std.mem.eql(u8, value, "True") or
                std.mem.eql(u8, value, "TRUE") or
                std.mem.eql(u8, value, "false") or
                std.mem.eql(u8, value, "False") or
                std.mem.eql(u8, value, "FALSE"))
            {
                return "!!bool";
            }
            // Int
            if (looksLikeInt(value)) {
                return "!!int";
            }
            // Float
            if (looksLikeFloat(value)) {
                return "!!float";
            }
            return "!!str";
        },
        .yaml11 => {
            // YAML 1.1 null
            if (value.len == 0 or
                std.mem.eql(u8, value, "null") or
                std.mem.eql(u8, value, "Null") or
                std.mem.eql(u8, value, "NULL") or
                std.mem.eql(u8, value, "~"))
            {
                return "!!null";
            }
            // YAML 1.1 Bool (yes/no, on/off, y/n in addition to true/false)
            if (std.ascii.eqlIgnoreCase(value, "true") or
                std.ascii.eqlIgnoreCase(value, "false") or
                std.ascii.eqlIgnoreCase(value, "yes") or
                std.ascii.eqlIgnoreCase(value, "no") or
                std.ascii.eqlIgnoreCase(value, "on") or
                std.ascii.eqlIgnoreCase(value, "off") or
                std.ascii.eqlIgnoreCase(value, "y") or
                std.ascii.eqlIgnoreCase(value, "n"))
            {
                return "!!bool";
            }
            // Int (includes 0-prefix octal, binary, sexagesimal)
            if (looksLikeInt11(value)) {
                return "!!int";
            }
            // Float
            if (looksLikeFloat(value)) {
                return "!!float";
            }
            return "!!str";
        },
    }
}

fn looksLikeInt(value: []const u8) bool {
    if (value.len == 0) return false;

    var i: usize = 0;
    if (value[0] == '+' or value[0] == '-') {
        i = 1;
        if (i >= value.len) return false;
    }

    // Hex
    if (value.len > i + 2 and value[i] == '0' and (value[i + 1] == 'x' or value[i + 1] == 'X')) {
        for (value[i + 2 ..]) |c| {
            if (!((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F'))) {
                return false;
            }
        }
        return true;
    }

    // Octal
    if (value.len > i + 2 and value[i] == '0' and (value[i + 1] == 'o' or value[i + 1] == 'O')) {
        for (value[i + 2 ..]) |c| {
            if (c < '0' or c > '7') return false;
        }
        return true;
    }

    // Decimal
    for (value[i..]) |c| {
        if (c < '0' or c > '9') return false;
    }
    return value.len > i;
}

fn looksLikeInt11(value: []const u8) bool {
    if (value.len == 0) return false;

    var i: usize = 0;
    if (value[0] == '+' or value[0] == '-') {
        i = 1;
        if (i >= value.len) return false;
    }

    // Hex: 0x...
    if (value.len > i + 2 and value[i] == '0' and (value[i + 1] == 'x' or value[i + 1] == 'X')) {
        for (value[i + 2 ..]) |c| {
            if (!((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F'))) {
                return false;
            }
        }
        return true;
    }

    // Binary: 0b...
    if (value.len > i + 2 and value[i] == '0' and (value[i + 1] == 'b' or value[i + 1] == 'B')) {
        for (value[i + 2 ..]) |c| {
            if (c != '0' and c != '1') return false;
        }
        return true;
    }

    // Octal: 0o... (YAML 1.2 style)
    if (value.len > i + 2 and value[i] == '0' and (value[i + 1] == 'o' or value[i + 1] == 'O')) {
        for (value[i + 2 ..]) |c| {
            if (c < '0' or c > '7') return false;
        }
        return true;
    }

    // Octal: 0... (YAML 1.1 style - leading zero with digits)
    if (value.len > i + 1 and value[i] == '0' and value[i + 1] >= '0' and value[i + 1] <= '9') {
        for (value[i + 1 ..]) |c| {
            if (c < '0' or c > '7') return false;
        }
        return true;
    }

    // Sexagesimal: contains colons (e.g., 1:30:00)
    if (std.mem.indexOfScalar(u8, value[i..], ':') != null) {
        for (value[i..]) |c| {
            if (c != ':' and (c < '0' or c > '9')) return false;
        }
        return true;
    }

    // Decimal (may contain underscores)
    for (value[i..]) |c| {
        if (c != '_' and (c < '0' or c > '9')) return false;
    }
    return value.len > i;
}

fn looksLikeFloat(value: []const u8) bool {
    // Special values
    if (std.mem.eql(u8, value, ".inf") or
        std.mem.eql(u8, value, ".Inf") or
        std.mem.eql(u8, value, ".INF") or
        std.mem.eql(u8, value, "+.inf") or
        std.mem.eql(u8, value, "+.Inf") or
        std.mem.eql(u8, value, "+.INF") or
        std.mem.eql(u8, value, "-.inf") or
        std.mem.eql(u8, value, "-.Inf") or
        std.mem.eql(u8, value, "-.INF") or
        std.mem.eql(u8, value, ".nan") or
        std.mem.eql(u8, value, ".NaN") or
        std.mem.eql(u8, value, ".NAN"))
    {
        return true;
    }

    // Standard float: must have . or e/E
    var has_dot = false;
    var has_exp = false;
    for (value) |c| {
        if (c == '.') has_dot = true;
        if (c == 'e' or c == 'E') has_exp = true;
    }
    if (!has_dot and !has_exp) return false;

    // Validate it parses as float
    _ = std.fmt.parseFloat(f64, value) catch return false;
    return true;
}
