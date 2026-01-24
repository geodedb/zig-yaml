# Makefile for zig-yaml library
#
# Usage:
#   make              - Build and run all tests
#   make test         - Run unit tests only
#   make clean        - Clean build artifacts
#   make help         - Show this help message

.PHONY: all build test clean check fmt help ci release

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

# Release - create and push a new version tag
# Usage: make release VERSION=0.1.0
release:
ifndef VERSION
	$(error VERSION is required. Usage: make release VERSION=x.y.z)
endif
	@echo "Creating release v$(VERSION)..."
	@# Update version in build.zig.zon
	@sed -i 's/\.version = "[^"]*"/.version = "$(VERSION)"/' build.zig.zon
	@echo "Updated build.zig.zon to version $(VERSION)"
	@# Commit the version change
	@git add build.zig.zon
	@git commit -m "Release v$(VERSION)" || echo "No changes to commit"
	@# Create and push the tag
	@git tag -a "v$(VERSION)" -m "Release v$(VERSION)"
	@git push origin main
	@git push origin "v$(VERSION)"
	@echo ""
	@echo "Release v$(VERSION) created and pushed!"
	@echo "CI/CD will create the GitLab release with package hash."

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
	@echo "Release:"
	@echo "  release VERSION=x.y.z - Create and push a new release tag"
	@echo ""
	@echo "Requirements:
	@echo "  - Zig 0.15.1 or compatible"
	@echo ""
	@echo "For more information, see README.md"
