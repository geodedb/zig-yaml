#!/usr/bin/env bash
set -euo pipefail

ZIG_VERSION="${1:?usage: install-zig.sh <version>}"
ARCH="$(uname -m)"
OS="$(uname -s)"

case "${ARCH}" in
  x86_64|amd64) ZIG_ARCH="x86_64" ;;
  aarch64|arm64) ZIG_ARCH="aarch64" ;;
  *)
    echo "unsupported architecture: ${ARCH}" >&2
    exit 1
    ;;
esac

case "${OS}" in
  Linux)   ZIG_OS="linux" ;;
  Darwin)  ZIG_OS="macos" ;;
  *)
    echo "unsupported OS: ${OS}" >&2
    exit 1
    ;;
esac

TARGET_KEY="${ZIG_ARCH}-${ZIG_OS}"
ARCHIVE="zig-${ZIG_ARCH}-${ZIG_OS}-${ZIG_VERSION}"
TARBALL="${ARCHIVE}.tar.xz"
export ZIG_VERSION TARGET_KEY

if [ ! -x "zig-${ZIG_VERSION}/zig" ]; then
  curl -fsSL https://ziglang.org/download/index.json -o /tmp/zig-index.json
  mapfile -t VALUES < <(python3 - <<'PY'
import json, os
version = os.environ["ZIG_VERSION"]
target = os.environ["TARGET_KEY"]
idx = json.load(open("/tmp/zig-index.json"))
pkg = idx[version][target]
print(pkg["tarball"])
print(pkg["shasum"])
PY
  )

  curl -fsSL "${VALUES[0]}" -o "/tmp/${TARBALL}"
  if command -v sha256sum >/dev/null 2>&1; then
    echo "${VALUES[1]}  /tmp/${TARBALL}" | sha256sum --check --strict
  else
    echo "${VALUES[1]}  /tmp/${TARBALL}" | shasum -a 256 -c -
  fi
  tar -xJf "/tmp/${TARBALL}"
  mv "${ARCHIVE}" "zig-${ZIG_VERSION}"
fi
