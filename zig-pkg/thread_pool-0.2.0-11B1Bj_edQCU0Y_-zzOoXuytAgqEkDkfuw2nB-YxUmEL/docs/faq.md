# FAQ

## Which scheduler should I use?

Use `global_queue` for the simplest behavior and `work_stealing` for most
performance-sensitive work. Use `lane_extension` only when you need an
explicit blocking lane.

## How many workers can I configure?

The current hard cap is `64` workers because the non-empty-worker bitmap uses a
single `u64`.

## How do I run the full test suite?

See [TESTING.md](TESTING.md). The shortest full gate is:

```bash
zig build test-all --summary all
```

## How do I reproduce the Tokio and Go comparisons?

Run:

```bash
git submodule update --init --recursive
zig build bench-runtime-compare -Doptimize=ReleaseFast -- --output benchmarks/results/runtime-comparison-latest.json
```

The scripts bootstrap a pinned local Go toolchain from `third_party/go` so the
results come from the vendored runtime source tree rather than the host Go
installation.

## Where do the benchmark artifacts live?

- CI-safe suite: `benchmarks/results/latest.json`
- scale suite: `benchmarks/results/scale-latest.json`
- direct runtime comparison:
  `benchmarks/results/runtime-comparison-latest.json`

## Why are the direct runtime numbers different from older docs?

Older notes often compared this pool to Tokio or Go indirectly or used a
different host state. The current direct snapshot in
[RUNTIME_COMPARISON.md](RUNTIME_COMPARISON.md) comes from a same-host,
same-command run against vendored Tokio and Go source trees.
