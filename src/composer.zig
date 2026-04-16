// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! YAML 1.2.2 Composer
//! Builds the document graph from parser events.

const std = @import("std");
const parser = @import("parser.zig");
const limits = @import("limits.zig");

pub const NodeId = u32;

pub const NodeMeta = struct {
    tag: []const u8 = "!",
    anchor: ?[]const u8 = null,
};

pub const ScalarStyle = parser.ScalarStyle;

pub const KVPair = struct { k: NodeId, v: NodeId };

pub const Node = union(enum) {
    s: struct {
        meta: NodeMeta,
        style: ScalarStyle,
        v: []const u8,
    },
    q: struct {
        meta: NodeMeta,
        items: []NodeId,
    },
    m: struct {
        meta: NodeMeta,
        items: []KVPair,
    },
    a: []const u8, // alias target name
};

pub const Document = struct {
    arena: std.heap.ArenaAllocator,
    root: NodeId,
    nodes: std.ArrayList(Node),
    anchors: std.StringHashMap(NodeId),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Document {
        return .{
            .arena = std.heap.ArenaAllocator.init(allocator),
            .root = 0,
            .nodes = .empty,
            .anchors = std.StringHashMap(NodeId).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Document) void {
        self.nodes.deinit(self.allocator);
        self.anchors.deinit();
        self.arena.deinit();
    }

    pub fn node(self: *const Document, id: NodeId) *const Node {
        return &self.nodes.items[id];
    }

    pub fn addNode(self: *Document, n: Node) !NodeId {
        const id: NodeId = @intCast(self.nodes.items.len);
        try self.nodes.append(self.allocator, n);
        return id;
    }

    pub fn registerAnchor(self: *Document, name: []const u8, id: NodeId) !void {
        try self.anchors.put(name, id);
    }

    pub fn resolveAnchor(self: *const Document, name: []const u8) ?NodeId {
        return self.anchors.get(name);
    }
};

pub const ComposerError = error{
    UndefinedAnchor,
    DuplicateKey,
    MaxDepthExceeded,
    MaxNodesExceeded,
    OutOfMemory,
    ParseFailed,
    AliasCycle,
};

pub const Composer = struct {
    allocator: std.mem.Allocator,
    parse: parser.Parser,
    options: parser.ParseOptions,
    limit_checker: limits.LimitChecker,
    documents: std.ArrayList(Document),
    current_doc: ?*Document,

    // Error tracking
    last_error_line: u32,
    last_error_col: u32,
    last_error_name: []const u8,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, input: []const u8, opts: parser.ParseOptions) !Self {
        return Self{
            .allocator = allocator,
            .parse = try parser.Parser.init(allocator, input, opts),
            .options = opts,
            .limit_checker = limits.LimitChecker.initFromParseOptions(opts),
            .documents = .empty,
            .current_doc = null,
            .last_error_line = 0,
            .last_error_col = 0,
            .last_error_name = "",
        };
    }

    pub fn deinit(self: *Self) void {
        self.parse.deinit();
        for (self.documents.items) |*doc| {
            doc.deinit();
        }
        self.documents.deinit(self.allocator);
    }

    fn mapParserError(self: *Self, err: parser.ParserError) ComposerError {
        if (self.parse.getLastError()) |pe| {
            self.last_error_line = pe.line;
            self.last_error_col = pe.col;
        }
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.ParseFailed => error.ParseFailed,
        };
    }

    pub fn composeAll(self: *Self) ComposerError![]Document {
        while (true) {
            const event = self.parse.nextEvent() catch |err| {
                return self.mapParserError(err);
            };

            switch (event) {
                .stream_start => {},
                .stream_end => break,
                .doc_start => {
                    const doc = Document.init(self.allocator);
                    try self.documents.append(self.allocator, doc);
                    self.current_doc = &self.documents.items[self.documents.items.len - 1];
                },
                .doc_end => {
                    self.current_doc = null;
                },
                else => {
                    if (self.current_doc) |doc| {
                        const root_id = try self.composeNode(event, doc);
                        doc.root = root_id;
                    }
                },
            }
        }

        return self.documents.items;
    }

    fn composeNode(self: *Self, event: parser.Event, doc: *Document) ComposerError!NodeId {
        self.limit_checker.addNode() catch return error.MaxNodesExceeded;

        switch (event) {
            .scalar => |s| {
                const node_id = try doc.addNode(.{ .s = .{
                    .meta = .{
                        .tag = try self.dupeInArena(doc, s.meta.tag),
                        .anchor = if (s.meta.anchor) |a| try self.dupeInArena(doc, a) else null,
                    },
                    .style = s.style,
                    .v = try self.dupeInArena(doc, s.value),
                } });
                if (s.meta.anchor) |anchor| {
                    try doc.registerAnchor(try self.dupeInArena(doc, anchor), node_id);
                }
                return node_id;
            },
            .alias => |name| {
                // Store alias as special node type for graph preservation
                const node_id = try doc.addNode(.{ .a = try self.dupeInArena(doc, name) });
                return node_id;
            },
            .seq_start => |meta| {
                self.limit_checker.pushDepth() catch return error.MaxDepthExceeded;
                defer self.limit_checker.popDepth();

                var items: std.ArrayList(NodeId) = .empty;
                defer items.deinit(self.allocator);

                while (true) {
                    const next = self.parse.nextEvent() catch |err| {
                        return self.mapParserError(err);
                    };

                    if (next == .seq_end) break;

                    const item_id = try self.composeNode(next, doc);
                    try items.append(self.allocator, item_id);
                }

                const items_slice = try doc.arena.allocator().dupe(NodeId, items.items);
                const node_id = try doc.addNode(.{ .q = .{
                    .meta = .{
                        .tag = try self.dupeInArena(doc, meta.tag),
                        .anchor = if (meta.anchor) |a| try self.dupeInArena(doc, a) else null,
                    },
                    .items = items_slice,
                } });

                if (meta.anchor) |anchor| {
                    try doc.registerAnchor(try self.dupeInArena(doc, anchor), node_id);
                }
                return node_id;
            },
            .map_start => |meta| {
                self.limit_checker.pushDepth() catch return error.MaxDepthExceeded;
                defer self.limit_checker.popDepth();

                var items: std.ArrayList(KVPair) = .empty;
                defer items.deinit(self.allocator);

                while (true) {
                    const key_event = self.parse.nextEvent() catch |err| {
                        return self.mapParserError(err);
                    };

                    if (key_event == .map_end) break;

                    const key_id = try self.composeNode(key_event, doc);

                    const val_event = self.parse.nextEvent() catch |err| {
                        return self.mapParserError(err);
                    };

                    const val_id = try self.composeNode(val_event, doc);

                    try items.append(self.allocator, KVPair{ .k = key_id, .v = val_id });
                }

                const items_slice = try doc.arena.allocator().dupe(KVPair, items.items);
                const node_id = try doc.addNode(.{ .m = .{
                    .meta = .{
                        .tag = try self.dupeInArena(doc, meta.tag),
                        .anchor = if (meta.anchor) |a| try self.dupeInArena(doc, a) else null,
                    },
                    .items = items_slice,
                } });

                if (meta.anchor) |anchor| {
                    try doc.registerAnchor(try self.dupeInArena(doc, anchor), node_id);
                }
                return node_id;
            },
            else => {
                // Empty scalar fallback
                return try doc.addNode(.{ .s = .{
                    .meta = .{ .tag = "!", .anchor = null },
                    .style = .plain,
                    .v = "",
                } });
            },
        }
    }

    fn dupeInArena(self: *Self, doc: *Document, s: []const u8) ![]const u8 {
        _ = self;
        return doc.arena.allocator().dupe(u8, s);
    }

    pub fn getErrorLine(self: *const Self) u32 {
        return self.last_error_line;
    }

    pub fn getErrorCol(self: *const Self) u32 {
        return self.last_error_col;
    }

    pub fn getErrorName(self: *const Self) []const u8 {
        return self.last_error_name;
    }

    /// Get the parser's last error for more detailed error information
    pub fn getParserError(self: *const Self) ?parser.ParseError {
        return self.parse.getLastError();
    }
};

pub fn loadAll(allocator: std.mem.Allocator, input: []const u8, opts: parser.ParseOptions) ![]Document {
    var comp = try Composer.init(allocator, input, opts);
    defer comp.deinit();

    const docs = try comp.composeAll();

    // Move documents out
    var result = try allocator.alloc(Document, docs.len);
    for (docs, 0..) |doc, i| {
        result[i] = doc;
    }

    // Clear the ArrayList without freeing documents (they're now in result)
    comp.documents.items.len = 0;

    return result;
}
