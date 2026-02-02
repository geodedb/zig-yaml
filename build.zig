// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Spice disabled by default due to Zig 0.15.2 compatibility issues
    const enable_spice = b.option(bool, "spice", "Enable spice-based parallelism") orelse false;
    _ = enable_spice; // Reserved for future use when spice compatibility is fixed

    // Library module (for use as dependency)
    const yaml_mod = b.addModule("yaml", .{
        .root_source_file = b.path("src/yaml.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Unit tests (tests in src/yaml.zig)
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/yaml.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);

    // Acceptance tests (tests/accept.zig)
    const accept_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/accept.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    accept_tests.root_module.addImport("yaml", yaml_mod);

    const run_accept_tests = b.addRunArtifact(accept_tests);

    // Scanner tests (tests/scanner_test.zig)
    const scanner_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/scanner_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    scanner_tests.root_module.addImport("yaml", yaml_mod);

    const run_scanner_tests = b.addRunArtifact(scanner_tests);

    // Emitter tests (tests/emitter_test.zig)
    const emitter_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/emitter_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    emitter_tests.root_module.addImport("yaml", yaml_mod);

    const run_emitter_tests = b.addRunArtifact(emitter_tests);

    // Round-trip tests (tests/roundtrip_test.zig)
    const roundtrip_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/roundtrip_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    roundtrip_tests.root_module.addImport("yaml", yaml_mod);

    const run_roundtrip_tests = b.addRunArtifact(roundtrip_tests);

    // Test step runs all tests
    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&run_accept_tests.step);
    test_step.dependOn(&run_scanner_tests.step);
    test_step.dependOn(&run_emitter_tests.step);
    test_step.dependOn(&run_roundtrip_tests.step);

    // Separate step for just unit tests
    const unit_test_step = b.step("test-unit", "Run unit tests");
    unit_test_step.dependOn(&run_unit_tests.step);

    // Separate step for just acceptance tests
    const accept_test_step = b.step("test-accept", "Run acceptance tests");
    accept_test_step.dependOn(&run_accept_tests.step);

    // Separate step for scanner tests
    const scanner_test_step = b.step("test-scanner", "Run scanner tests");
    scanner_test_step.dependOn(&run_scanner_tests.step);

    // Separate step for emitter tests
    const emitter_test_step = b.step("test-emitter", "Run emitter tests");
    emitter_test_step.dependOn(&run_emitter_tests.step);

    // Separate step for round-trip tests
    const roundtrip_test_step = b.step("test-roundtrip", "Run round-trip tests");
    roundtrip_test_step.dependOn(&run_roundtrip_tests.step);

    // YAML Test Suite runner executable
    const suite_runner = b.addExecutable(.{
        .name = "yaml-test-suite",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/yaml_test_suite.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    suite_runner.root_module.addImport("yaml", yaml_mod);

    const run_suite = b.addRunArtifact(suite_runner);
    const suite_step = b.step("test-suite", "Run YAML test suite");
    suite_step.dependOn(&run_suite.step);

    // YAML Test Suite tests (for zig build test)
    const suite_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/yaml_test_suite.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    suite_tests.root_module.addImport("yaml", yaml_mod);
    const run_suite_tests = b.addRunArtifact(suite_tests);

    // Add suite tests to main test step
    test_step.dependOn(&run_suite_tests.step);

    // Check step (compile without running)
    const check = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/yaml.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const check_step = b.step("check", "Check for compilation errors");
    check_step.dependOn(&check.step);

    // Debug runner executable
    const debug_runner = b.addExecutable(.{
        .name = "debug-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/debug_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    debug_runner.root_module.addImport("yaml", yaml_mod);

    const run_debug = b.addRunArtifact(debug_runner);
    const debug_step = b.step("debug-test", "Run debug tests");
    debug_step.dependOn(&run_debug.step);

    // Benchmarks executable
    const bench_runner = b.addExecutable(.{
        .name = "yaml-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/benchmarks.zig"),
            .target = target,
            .optimize = .ReleaseFast,
        }),
    });
    bench_runner.root_module.addImport("yaml", yaml_mod);

    const run_bench = b.addRunArtifact(bench_runner);
    const bench_step = b.step("bench", "Run performance benchmarks");
    bench_step.dependOn(&run_bench.step);

    // Fuzz tests
    const fuzz_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/fuzz_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    fuzz_tests.root_module.addImport("yaml", yaml_mod);

    const run_fuzz_tests = b.addRunArtifact(fuzz_tests);
    const fuzz_test_step = b.step("test-fuzz", "Run fuzz tests (use --fuzz for continuous fuzzing)");
    fuzz_test_step.dependOn(&run_fuzz_tests.step);
}
