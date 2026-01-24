# Makefile for zig-yaml library
#
# Usage:
#   make              - Build and run all tests
#   make test         - Run unit tests only
#   make clean        - Clean build artifacts
#   make help         - Show this help message

.PHONY: all build test clean check fmt help ci

# Default target - build and run all tests
all: build test
	@echo ""
	@echo "All builds and tests completed successfully!"
	@echo ""

# Build the library
build:
	@echo "Building zig-yaml library..."
	@zig build

# Run unit tests
test:
	@echo "Running unit tests..."
	@zig build test --summary all

# Clean build artifacts
clean:
	@echo "Cleaning build artifacts..."
	@rm -rf zig-cache zig-out .zig-cache
	@echo "Clean complete"

# Check syntax without building
check:
	@echo "Checking for compilation errors..."
	@zig build check
	@echo "Check complete"

# Format all Zig source files
fmt:
	@echo "Formatting source files..."
	@zig fmt src/ build.zig
	@echo "Format complete"

# Run tests with optimization levels
test-release-safe:
	@echo "Running tests with ReleaseSafe optimization..."
	@zig build test -Doptimize=ReleaseSafe --summary all

test-release-fast:
	@echo "Running tests with ReleaseFast optimization..."
	@zig build test -Doptimize=ReleaseFast --summary all

test-release-small:
	@echo "Running tests with ReleaseSmall optimization..."
	@zig build test -Doptimize=ReleaseSmall --summary all

# Run all optimization level tests
test-all-optimizations: test test-release-safe test-release-fast test-release-small
	@echo "All optimization level tests completed"

# Continuous integration target
ci: clean build test
	@echo ""
	@echo "CI pipeline completed successfully!"

# Development workflow - quick iteration
dev: fmt check test
	@echo "Development checks passed"

# Generate documentation
docs:
	@echo "Generating documentation..."
	@zig build docs
	@echo "Documentation generated in zig-out/docs/"

# Show help message
help:
	@echo "zig-yaml - YAML Parser Library for Zig"
	@echo ""
	@echo "Usage:"
	@echo "  make [target]"
	@echo ""
	@echo "Main Targets:"
	@echo "  all              - Build and run all tests (default)"
	@echo "  build            - Build the library"
	@echo "  test             - Run unit tests"
	@echo ""
	@echo "Development Targets:"
	@echo "  clean            - Remove build artifacts"
	@echo "  check            - Check for compilation errors"
	@echo "  fmt              - Format all Zig source files"
	@echo "  dev              - Quick development workflow (fmt + check + test)"
	@echo "  docs             - Generate documentation"
	@echo ""
	@echo "Optimization Testing:"
	@echo "  test-release-safe  - Run tests with ReleaseSafe"
	@echo "  test-release-fast  - Run tests with ReleaseFast"
	@echo "  test-release-small - Run tests with ReleaseSmall"
	@echo "  test-all-optimizations - Run tests with all optimization levels"
	@echo ""
	@echo "CI/CD:"
	@echo "  ci               - Full CI pipeline (clean + build + all tests)"
	@echo ""
	@echo "Requirements:"
	@echo "  - Zig 0.15.1 or compatible"
	@echo ""
	@echo "For more information, see README.md"
