#!/usr/bin/env bash
# SONNY-4778: Git exports repository-steering variables to hooks. A tool
# manager or compiler may initialize/reset a different repository; inherited
# GIT_DIR and friends would redirect that operation into this worktree.
# Pre-commit already runs entries from the repository root. Preserve ordinary
# authentication/configuration environment and the command's arguments/status.
set -euo pipefail
if [ "$#" -eq 0 ]; then
    echo "usage: hook-env.sh COMMAND [ARGS...]" >&2
    exit 2
fi
exec env \
    -u GIT_DIR \
    -u GIT_WORK_TREE \
    -u GIT_INDEX_FILE \
    -u GIT_COMMON_DIR \
    -u GIT_OBJECT_DIRECTORY \
    -u GIT_ALTERNATE_OBJECT_DIRECTORIES \
    -u GIT_PREFIX \
    -u GIT_NAMESPACE \
    -u GIT_IMPLICIT_WORK_TREE \
    -u GIT_GRAFT_FILE \
    -u GIT_SHALLOW_FILE \
    -u GIT_QUARANTINE_PATH \
    "$@"
