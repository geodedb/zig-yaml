# thread-pool - Zig Library Makefile
# SPDX-License-Identifier: Apache-2.0

ZIG ?= $(if $(wildcard ./zig-0.15.2/zig),./zig-0.15.2/zig,zig)
BASELINE ?= benchmarks/results/baseline.json
CURRENT ?= benchmarks/results/latest.json

.PHONY: all build check fmt test test-unit test-integration test-stress test-all
.PHONY: test-release-safe test-release-fast test-release-small clean dev ci
.PHONY: bench scale-bench bench-save bench-compare bench-runtime-zig bench-runtime-compare tools cross-check example

all: build test-unit

build:
	$(ZIG) build build

check:
	$(ZIG) build check

fmt:
	$(ZIG) fmt src tests benchmarks examples build.zig

test: test-unit test-integration test-stress

test-unit:
	$(ZIG) build test --summary all

test-integration:
	$(ZIG) build test-integration --summary all

test-stress:
	$(ZIG) build test-stress --summary all

test-all:
	$(ZIG) build test-all --summary all

test-release-safe:
	$(ZIG) build test -Doptimize=ReleaseSafe --summary all

test-release-fast:
	$(ZIG) build test -Doptimize=ReleaseFast --summary all

test-release-small:
	$(ZIG) build test -Doptimize=ReleaseSmall --summary all

bench:
	$(ZIG) build bench -- --output $(CURRENT)

scale-bench:
	$(ZIG) build scale-bench -- --output benchmarks/results/scale-latest.json

bench-save:
	mkdir -p benchmarks/results
	$(ZIG) build bench -- --output $(CURRENT)

bench-compare:
	$(ZIG) build compare-bench -- --baseline $(BASELINE) --current $(CURRENT)

bench-runtime-zig:
	$(ZIG) build bench-runtime-zig -- --output benchmarks/results/runtime-zig-latest.json

bench-runtime-compare:
	$(ZIG) build bench-runtime-compare -- --output benchmarks/results/runtime-comparison-latest.json

tools:
	$(ZIG) build tools

cross-check:
	$(ZIG) build cross-check

example:
	$(ZIG) build example

dev: fmt check test-unit

ci: clean check test-all cross-check bench-compare

clean:
	rm -rf .zig-cache zig-cache zig-out
