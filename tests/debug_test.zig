const std = @import("std");
const yaml = @import("yaml");
const Scanner = yaml.scanner.Scanner;
const Parser = yaml.parser_mod.Parser;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Debug test for YAML parsing issues
    const test_input = "key: value";

    std.debug.print("Input: {s}\n\n", .{test_input});

    // First show tokens
    std.debug.print("Tokens:\n", .{});
    var scanner = Scanner.init(allocator, test_input, .{}) catch |err| {
        std.debug.print("Scanner init ERROR: {}\n", .{err});
        return;
    };
    defer scanner.deinit();

    var token_count: usize = 0;
    while (true) : (token_count += 1) {
        const maybe_tok = scanner.nextToken() catch |err| {
            std.debug.print("  Token {} ERROR: {}\n", .{ token_count, err });
            break;
        };
        const tok = maybe_tok orelse break;
        std.debug.print("  {}: {s}", .{ token_count, @tagName(tok.type) });
        if (tok.type == .scalar or tok.type == .anchor or tok.type == .alias) {
            std.debug.print(" = '{s}'", .{tok.value});
        }
        std.debug.print("\n", .{});
        if (tok.type == .stream_end) break;
    }

    std.debug.print("\nEvents:\n", .{});
    var parser = yaml.Parser.init(allocator, test_input, .{}) catch |err| {
        std.debug.print("Parser init ERROR: {}\n", .{err});
        return;
    };
    defer parser.deinit();

    var event_count: usize = 0;
    while (event_count < 30) : (event_count += 1) {
        const event = parser.nextEvent() catch |err| {
            std.debug.print("  Event {} ERROR: {}\n", .{ event_count, err });
            break;
        };
        std.debug.print("  {}: {s}", .{ event_count, @tagName(event) });
        switch (event) {
            .scalar => |s| {
                std.debug.print(" = '{s}'", .{s.value});
                if (s.meta.anchor) |a| std.debug.print(" anchor={s}", .{a});
            },
            .map_start => |m| {
                if (m.anchor) |a| std.debug.print(" anchor={s}", .{a});
            },
            .seq_start => |s| {
                if (s.anchor) |a| std.debug.print(" anchor={s}", .{a});
            },
            .alias => |a| std.debug.print(" = *{s}", .{a}),
            else => {},
        }
        std.debug.print("\n", .{});
        if (event == .stream_end) break;
    }
}
