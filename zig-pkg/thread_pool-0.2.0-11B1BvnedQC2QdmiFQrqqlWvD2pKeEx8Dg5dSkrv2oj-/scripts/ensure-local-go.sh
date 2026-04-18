#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUBMODULE_DIR="${ROOT_DIR}/third_party/go"

if [[ ! -e "${SUBMODULE_DIR}/.git" ]]; then
  echo "missing Go submodule at ${SUBMODULE_DIR}" >&2
  exit 1
fi

GO_COMMIT="$(git -C "${SUBMODULE_DIR}" rev-parse HEAD)"
CACHE_ROOT="${ROOT_DIR}/.cache/go-toolchains/${GO_COMMIT}"
GO_BIN="${CACHE_ROOT}/bin/go"

if [[ -x "${GO_BIN}" ]]; then
  printf '%s\n' "${GO_BIN}"
  exit 0
fi

BOOTSTRAP_GO="${BOOTSTRAP_GO:-$(command -v go || true)}"
if [[ -z "${BOOTSTRAP_GO}" ]]; then
  echo "unable to find bootstrap go binary in PATH" >&2
  exit 1
fi
BOOTSTRAP_GOROOT="$("${BOOTSTRAP_GO}" env GOROOT)"

mkdir -p "$(dirname "${CACHE_ROOT}")"
if [[ ! -d "${CACHE_ROOT}/.git" ]]; then
  git clone "${SUBMODULE_DIR}" "${CACHE_ROOT}" >&2
fi

git -C "${CACHE_ROOT}" checkout --quiet "${GO_COMMIT}"

(
  cd "${CACHE_ROOT}/src"
  unset GOROOT
  unset GOTOOLDIR
  GOROOT_BOOTSTRAP="${BOOTSTRAP_GOROOT}" ./make.bash >&2
)

printf '%s\n' "${GO_BIN}"
