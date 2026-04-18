#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
unset GOROOT
unset GOTOOLDIR

OUTPUT_PATH="${ROOT_DIR}/benchmarks/results/runtime-comparison-latest.json"
SAMPLES=7
WARMUP_DISCARD=1
ZIG_BIN=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output)
      OUTPUT_PATH="$2"
      shift 2
      ;;
    --samples)
      SAMPLES="$2"
      shift 2
      ;;
    --warmup-discard)
      WARMUP_DISCARD="$2"
      shift 2
      ;;
    --zig-bin)
      ZIG_BIN="$2"
      shift 2
      ;;
    *)
      echo "unrecognized argument: $1" >&2
      exit 2
      ;;
  esac
done

if [[ -z "${ZIG_BIN}" ]]; then
  if [[ -x "${ROOT_DIR}/zig-0.15.2/zig" ]]; then
    ZIG_CMD="${ROOT_DIR}/zig-0.15.2/zig"
  else
    ZIG_CMD="$(command -v zig)"
  fi
  (
    cd "${ROOT_DIR}"
    "${ZIG_CMD}" build bench-runtime-zig -Doptimize=ReleaseFast
  )
  ZIG_BIN="${ROOT_DIR}/zig-out/bin/thread-pool-runtime-compare-zig"
fi

mkdir -p "$(dirname "${OUTPUT_PATH}")" "${ROOT_DIR}/.cache"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

ROOT_COMMIT="$(git -C "${ROOT_DIR}" rev-parse HEAD)"
TOKIO_COMMIT="$(git -C "${ROOT_DIR}/third_party/tokio" rev-parse HEAD)"
GO_COMMIT="$(git -C "${ROOT_DIR}/third_party/go" rev-parse HEAD)"
TOKIO_VERSION="$(sed -n 's/^version = "\(.*\)"/\1/p' "${ROOT_DIR}/third_party/tokio/tokio/Cargo.toml" | head -n 1)"

if [[ -x "${ROOT_DIR}/zig-0.15.2/zig" ]]; then
  ZIG_VERSION="$("${ROOT_DIR}/zig-0.15.2/zig" version)"
else
  ZIG_VERSION="$(zig version)"
fi

GO_BIN="$("${ROOT_DIR}/scripts/ensure-local-go.sh")"
GO_ROOT="$(cd "$(dirname "${GO_BIN}")/.." && pwd)"
GO_VERSION="$(GOROOT="${GO_ROOT}" "${GO_BIN}" version | sed 's/^go version //')"
GO_CACHE_DIR="${ROOT_DIR}/.cache/go-build/${GO_COMMIT}"
mkdir -p "${GO_CACHE_DIR}"

"${ZIG_BIN}" \
  --output "${TMP_DIR}/zig.json" \
  --samples "${SAMPLES}" \
  --warmup-discard "${WARMUP_DISCARD}" \
  --runtime-version "zig ${ZIG_VERSION}" \
  --source-commit "${ROOT_COMMIT}"

CARGO_TARGET_DIR="${ROOT_DIR}/.cache/cargo-target" \
  cargo run --quiet --release \
  --manifest-path "${ROOT_DIR}/benchmarks/external/tokio_runtime_bench/Cargo.toml" \
  -- \
  --output "${TMP_DIR}/tokio.json" \
  --samples "${SAMPLES}" \
  --warmup-discard "${WARMUP_DISCARD}" \
  --runtime-version "tokio ${TOKIO_VERSION}" \
  --source-commit "${TOKIO_COMMIT}"

(
  cd "${ROOT_DIR}/benchmarks/external/go_runtime_bench"
  GOROOT="${GO_ROOT}" \
    GOCACHE="${GO_CACHE_DIR}" \
    "${GO_BIN}" run . \
    --output "${TMP_DIR}/go.json" \
    --samples "${SAMPLES}" \
    --warmup-discard "${WARMUP_DISCARD}" \
    --runtime-version "${GO_VERSION}" \
    --source-commit "${GO_COMMIT}"
)

HOST_OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
HOST_ARCH="$(uname -m)"

{
  printf '{\n'
  printf '  "generated_at_unix_s": %s,\n' "$(date +%s)"
  printf '  "host_os": "%s",\n' "${HOST_OS}"
  printf '  "host_arch": "%s",\n' "${HOST_ARCH}"
  printf '  "runtimes": [\n'
  sed 's/^/    /' "${TMP_DIR}/zig.json"
  printf ',\n'
  sed 's/^/    /' "${TMP_DIR}/tokio.json"
  printf ',\n'
  sed 's/^/    /' "${TMP_DIR}/go.json"
  printf '\n  ]\n'
  printf '}\n'
} > "${OUTPUT_PATH}"

printf 'wrote %s\n' "${OUTPUT_PATH}"
