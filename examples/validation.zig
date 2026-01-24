// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Validation Example
//!
//! Demonstrates validating YAML values against schemas to ensure configuration
//! data matches expected types and constraints.

const std = @import("std");
const yaml = @import("yaml");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== YAML Validation Example ===\n\n", .{});

    // Example 1: Simple type validation
    try simpleValidation(allocator);

    // Example 2: Complex schema validation
    try complexValidation(allocator);

    // Example 3: Validation with errors
    try validationWithErrors(allocator);
}

fn simpleValidation(allocator: std.mem.Allocator) !void {
    std.debug.print("--- Simple Type Validation ---\n", .{});

    const test_cases = [_]struct {
        input: []const u8,
        schema: yaml.ValidationSchema,
        expected: bool,
        name: []const u8,
    }{
        .{
            .input = "42",
            .schema = yaml.schema.int,
            .expected = true,
            .name = "42 is int",
        },
        .{
            .input = "hello",
            .schema = yaml.schema.str,
            .expected = true,
            .name = "hello is str",
        },
        .{
            .input = "true",
            .schema = yaml.schema.@"bool",
            .expected = true,
            .name = "true is bool",
        },
        .{
            .input = "null",
            .schema = yaml.schema.@"null",
            .expected = true,
            .name = "null is null",
        },
        .{
            .input = "3.14",
            .schema = yaml.schema.float,
            .expected = true,
            .name = "3.14 is float",
        },
        .{
            .input = "hello",
            .schema = yaml.schema.int,
            .expected = false,
            .name = "hello is not int",
        },
    };

    for (test_cases) |tc| {
        var docs = try yaml.loadAll(allocator, tc.input, .{});
        defer {
            for (docs) |*d| d.deinit();
            allocator.free(docs);
        }

        if (docs.len > 0) {
            const value = try yaml.resolveToValue(allocator, &docs[0], .{});
            defer yaml.freeValue(allocator, &value);

            var result = try yaml.validateValue(allocator, value, tc.schema);
            defer result.deinit(allocator);

            const status = if (result.valid) "PASS" else "FAIL";
            const expected_str = if (tc.expected) "PASS" else "FAIL";
            const match = if (result.valid == tc.expected) "OK" else "MISMATCH";
            std.debug.print("  {s}: {s} (expected {s}) [{s}]\n", .{ tc.name, status, expected_str, match });
        }
    }

    std.debug.print("\n", .{});
}

fn complexValidation(allocator: std.mem.Allocator) !void {
    std.debug.print("--- Complex Schema Validation ---\n", .{});

    const config_yaml =
        \\server:
        \\  host: localhost
        \\  port: 8080
        \\database:
        \\  url: postgres://localhost/mydb
        \\  pool_size: 10
    ;

    var docs = try yaml.loadAll(allocator, config_yaml, .{});
    defer {
        for (docs) |*d| d.deinit();
        allocator.free(docs);
    }

    if (docs.len > 0) {
        const value = try yaml.resolveToValue(allocator, &docs[0], .{});
        defer yaml.freeValue(allocator, &value);

        // Define schema for config
        const port_schema = yaml.schema.intRange(1, 65535);
        const server_schema = yaml.schema.object(&.{
            .{ .name = "host", .schema = &yaml.schema.str, .required = true },
            .{ .name = "port", .schema = &port_schema, .required = true },
        });
        const pool_schema = yaml.schema.intRange(1, 100);
        const database_schema = yaml.schema.object(&.{
            .{ .name = "url", .schema = &yaml.schema.str, .required = true },
            .{ .name = "pool_size", .schema = &pool_schema, .required = false },
        });
        const config_schema = yaml.schema.object(&.{
            .{ .name = "server", .schema = &server_schema, .required = true },
            .{ .name = "database", .schema = &database_schema, .required = true },
        });

        var result = try yaml.validateValue(allocator, value, config_schema);
        defer result.deinit(allocator);

        std.debug.print("  Config validation: {s}\n", .{if (result.valid) "VALID" else "INVALID"});

        if (!result.valid) {
            for (result.errors) |err| {
                std.debug.print("    Error at '{s}': {s}\n", .{ err.path, err.message });
            }
        }
    }

    std.debug.print("\n", .{});
}

fn validationWithErrors(allocator: std.mem.Allocator) !void {
    std.debug.print("--- Validation Error Examples ---\n", .{});

    // Invalid configuration
    const invalid_yaml =
        \\server:
        \\  host: 12345
        \\  port: 99999
        \\database:
        \\  pool_size: not_a_number
    ;

    var docs = try yaml.loadAll(allocator, invalid_yaml, .{});
    defer {
        for (docs) |*d| d.deinit();
        allocator.free(docs);
    }

    if (docs.len > 0) {
        const value = try yaml.resolveToValue(allocator, &docs[0], .{});
        defer yaml.freeValue(allocator, &value);

        // Define expected schema
        const port_schema = yaml.schema.intRange(1, 65535);
        const server_schema = yaml.schema.object(&.{
            .{ .name = "host", .schema = &yaml.schema.str, .required = true },
            .{ .name = "port", .schema = &port_schema, .required = true },
        });
        const pool_schema = yaml.schema.int;
        const database_schema = yaml.schema.object(&.{
            .{ .name = "url", .schema = &yaml.schema.str, .required = true },
            .{ .name = "pool_size", .schema = &pool_schema, .required = false },
        });
        const config_schema = yaml.schema.object(&.{
            .{ .name = "server", .schema = &server_schema, .required = true },
            .{ .name = "database", .schema = &database_schema, .required = true },
        });

        var result = try yaml.validateValue(allocator, value, config_schema);
        defer result.deinit(allocator);

        std.debug.print("  Validation result: {s}\n", .{if (result.valid) "VALID" else "INVALID"});

        if (!result.valid) {
            std.debug.print("  Errors ({d}):\n", .{result.errors.len});
            for (result.errors) |err| {
                std.debug.print("    - {s}: {s}\n", .{ err.path, err.message });
                std.debug.print("      Expected: {s}, Got: {s}\n", .{ err.expected, err.actual });
            }
        }
    }

    std.debug.print("\n", .{});
}
