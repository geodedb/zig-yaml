#!/usr/bin/env bash
# scripts/perf-gate.sh
# Usage: ./scripts/perf-gate.sh <step-name> <before|after>
# Captures bench + bench-realistic JSON, and when called with "after"
# emits a markdown diff vs the matching "before" file.

set -euo pipefail

# Pin zig to the project's required version. The project's minimum_zig_version
# is 0.16.0 (see build.zig.zon). The ambient `zig` on the host may differ
# (e.g. 0.16.0), which would produce noisy "compiler ABI drift" numbers when
# comparing before/after. We resolve zig via mise so every perf-gate run is
# reproducible regardless of the caller's shell state.
#
# If you don't have mise, install it (https://mise.jdx.dev) or override with:
#     ZIG=/path/to/zig/0.16.0 ./scripts/perf-gate.sh ...
ZIG="${ZIG:-}"
if [[ -z "$ZIG" ]]; then
    if command -v mise >/dev/null 2>&1; then
        ZIG_RUNNER=(mise x zig@0.16.0 -- zig)
    elif command -v zig >/dev/null 2>&1; then
        ZIG_RUNNER=(zig)
        actual_ver="$(zig version 2>/dev/null || echo unknown)"
        if [[ "$actual_ver" != "0.16.0" ]]; then
            echo "[perf-gate] WARNING: ambient zig is $actual_ver, project needs 0.16.0. Numbers may not compare cleanly." >&2
        fi
    else
        echo "[perf-gate] ERROR: no zig found. Install mise + zig@0.16.0, or set ZIG=/path/to/zig." >&2
        exit 4
    fi
else
    ZIG_RUNNER=("$ZIG")
fi

STEP="${1:?step name required (e.g. step-1-f001)}"
PHASE="${2:?phase required: before | after}"
ART_DIR="docs/performance/appsec-fixes-2026-04-15"

if [[ "$PHASE" != "before" && "$PHASE" != "after" ]]; then
    echo "phase must be 'before' or 'after'" >&2
    exit 2
fi

mkdir -p "$ART_DIR"

BENCH_OUT="$ART_DIR/${STEP}-${PHASE}-bench.json"
REAL_OUT="$ART_DIR/${STEP}-${PHASE}-realistic.json"

echo "[perf-gate] $STEP $PHASE: running zig build bench ..."
"${ZIG_RUNNER[@]}" build bench -- --output "$BENCH_OUT"

echo "[perf-gate] $STEP $PHASE: running zig build bench-realistic ..."
"${ZIG_RUNNER[@]}" build bench-realistic -Doptimize=ReleaseFast -- --output "$REAL_OUT"

if [[ "$PHASE" == "after" ]]; then
    DIFF_OUT="$ART_DIR/${STEP}-diff.md"
    BEFORE_BENCH="$ART_DIR/${STEP}-before-bench.json"
    BEFORE_REAL="$ART_DIR/${STEP}-before-realistic.json"

    if [[ ! -f "$BEFORE_BENCH" || ! -f "$BEFORE_REAL" ]]; then
        echo "[perf-gate] ERROR: missing before-files. Run '$STEP before' first." >&2
        exit 3
    fi

    {
        echo "# Perf diff — $STEP"
        echo
        echo "Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo
        echo "## bench (zig build bench)"
        echo
        echo "| scenario | variant | ops/s before | ops/s after | Δ % | p95 submit before (ns) | p95 submit after (ns) | Δ p95 % |"
        echo "|---|---|---:|---:|---:|---:|---:|---:|"
        jq -r --slurpfile bef "$BEFORE_BENCH" '
          .rows as $aft
          | $bef[0].rows as $bfr
          | $aft
          | map({
              scenario_name, scheduler_variant,
              ops_after: .throughput_ops_per_sec,
              p95_after: .submit_latency_p95_ns,
              key: (.scenario_name + "|" + .scheduler_variant)
            })
          | .[] as $a
          | $bfr
          | map(select((.scenario_name + "|" + .scheduler_variant) == $a.key))
          | if length == 0 then
              [$a.scenario_name, $a.scheduler_variant, "n/a", $a.ops_after, "n/a", "n/a", $a.p95_after, "n/a"]
            else
              . [0] as $b
              | [
                  $a.scenario_name, $a.scheduler_variant,
                  ($b.throughput_ops_per_sec | tostring),
                  ($a.ops_after | tostring),
                  (if $b.throughput_ops_per_sec == 0 then "div/0" else ((($a.ops_after - $b.throughput_ops_per_sec) / $b.throughput_ops_per_sec * 100) | tostring + "%") end),
                  ($b.submit_latency_p95_ns | tostring),
                  ($a.p95_after | tostring),
                  (if $b.submit_latency_p95_ns == 0 then "div/0" else ((($a.p95_after - $b.submit_latency_p95_ns) / $b.submit_latency_p95_ns * 100) | tostring + "%") end)
                ]
            end
          | "| " + join(" | ") + " |"
        ' "$BENCH_OUT"
        echo
        echo "## bench-realistic (zig_thread_pool rows)"
        echo
        echo "| scenario | variant | ops/s before | ops/s after | Δ % | p95 submit before (ns) | p95 submit after (ns) | Δ p95 % |"
        echo "|---|---|---:|---:|---:|---:|---:|---:|"
        jq -r --slurpfile bef "$BEFORE_REAL" '
          .rows as $aft
          | $bef[0].rows as $bfr
          | $aft
          | map({
              scenario_name, scheduler_variant,
              ops_after: .throughput_ops_per_sec,
              p95_after: .submit_latency_p95_ns,
              key: (.scenario_name + "|" + .scheduler_variant)
            })
          | .[] as $a
          | $bfr
          | map(select((.scenario_name + "|" + .scheduler_variant) == $a.key))
          | if length == 0 then
              [$a.scenario_name, $a.scheduler_variant, "n/a", ($a.ops_after | tostring), "n/a", "n/a", ($a.p95_after | tostring), "n/a"]
            else
              .[0] as $b
              | [
                  $a.scenario_name, $a.scheduler_variant,
                  ($b.throughput_ops_per_sec | tostring),
                  ($a.ops_after | tostring),
                  (if $b.throughput_ops_per_sec == 0 then "div/0" else ((($a.ops_after - $b.throughput_ops_per_sec) / $b.throughput_ops_per_sec * 100) | tostring + "%") end),
                  ($b.submit_latency_p95_ns | tostring),
                  ($a.p95_after | tostring),
                  (if $b.submit_latency_p95_ns == 0 then "div/0" else ((($a.p95_after - $b.submit_latency_p95_ns) / $b.submit_latency_p95_ns * 100) | tostring + "%") end)
                ]
            end
          | "| " + join(" | ") + " |"
        ' "$REAL_OUT"
        echo
        echo "## Review checklist"
        echo
        echo "Apply the Performance-Regression Review Rule from the plan:"
        echo "- Throughput regression ≥ 5% on any scenario → BLOCK, escalate to user."
        echo "- p95 latency regression ≥ 10% on any scenario → BLOCK, escalate to user."
        echo "- 3–5% throughput / 7–10% p95 → WARN, note in commit body."
    } > "$DIFF_OUT"

    echo "[perf-gate] diff written to $DIFF_OUT"
fi

echo "[perf-gate] done."
