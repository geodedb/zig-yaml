#!/usr/bin/env python3
"""
detect_diamond_deps.py — fail loudly when a Zig project's transitive
dependency graph contains the same package name pinned to two different
hashes (a "diamond dep").

Geode + the DevNW Zig stack hit this whenever a transitive dep (e.g.
`thread_pool`) is bumped in one place but not another, or when one lib
opts into the new `--save` URL while a sibling lib still pins the old
SHA.  Zig 0.16 is supposed to reject overlapping module *paths* at
link time but lets distinct package *hashes* coexist, so the binary
silently links both versions and produces hard-to-diagnose runtime
faults (see `~/src/devnw/zig/otel/docs/BUG_BSP_SPAN_REUSE_UAF.md`
for the geode crash that motivated this guard).

Usage
-----
    detect_diamond_deps.py [PROJECT_ROOT]

If `PROJECT_ROOT` is omitted, the current working directory is used.
The project must contain a `build.zig.zon` at its root.

Exit codes
----------
    0   no diamonds; safe to commit/build
    1   one or more diamonds detected (printed to stderr)
    2   tooling/IO failure (e.g. `build.zig.zon` not found, cache
        directory missing).  Treat as soft-fail in pre-commit; the
        diamond check is skipped, not enforced as green.

How it works
------------
1.  Parse the project's `build.zig.zon` (a non-strict subset of Zig
    syntax — anonymous-struct + optional fields).
2.  For each `.dependencies.<name> = .{ .url = ..., .hash = "<H>" }`
    entry, look up `<H>` in the Zig package cache
    (`$ZIG_GLOBAL_CACHE_DIR/p/<H>` or `~/.cache/zig/p/<H>`) — if the
    cached source has its own `build.zig.zon`, recurse into it.
3.  Collect every `(name, hash)` tuple seen across the transitive
    walk, including the root project's own direct deps.
4.  Group by `name`.  Any name observed with more than one distinct
    hash is a diamond.  Print the offending tuples and exit 1.

Deliberately NOT in scope
-------------------------
*   Resolving the diamond.  Auto-bumping every transitive consumer to
    the same SHA requires multi-repo coordination (push to each
    dependent's main, then bump our pin).  Out of scope for a
    pre-commit hook.  See `scripts/sync_diamond_deps.sh` for the
    recommended manual fix workflow.
*   Validating the package-hash format itself.  We trust whatever
    `build.zig.zon` records; the check is only "two hashes for the
    same name == bad".
"""

from __future__ import annotations

import os
import re
import sys
from pathlib import Path
from collections import defaultdict
from typing import Dict, List, Set, Tuple

# build.zig.zon parsing — Zig anonymous-struct literals.
#
#   .dependencies = .{
#       .quic = .{
#           .url = "git+https://...#sha",
#           .hash = "quic-0.1.14-gBIqUb...",
#       },
#       .other = .{
#           .url = "...",
#           .hash = "...",
#       },
#   },
#
# We parse with a hand-rolled tokenizer rather than dragging in a Zig-
# parser dep.  The grammar we accept is intentionally narrow:
#   * `.<name> = .{ ... }` blocks
#   * `.url = "..."` / `.hash = "..."` string entries
#   * line/block comments (`// ...` and `// ...\n`)
# Anything else inside the dep block is ignored.
DEP_BLOCK_RE = re.compile(
    r"\.(?P<name>[A-Za-z_][A-Za-z0-9_]*)\s*=\s*\.\{"
    r"(?P<body>(?:[^{}]|\{[^{}]*\})*)"
    r"\}",
    re.DOTALL,
)
URL_RE = re.compile(r'\.url\s*=\s*"(?P<url>[^"]+)"')
HASH_RE = re.compile(r'\.hash\s*=\s*"(?P<hash>[^"]+)"')
# Strip `// ...` line comments BUT NOT when the `//` sits inside a
# string literal (e.g. inside a `.url = "git+https://..."`).  We walk
# the text and only strip after we've confirmed we're outside an
# unescaped double-quoted string.
def _strip_comments(text: str) -> str:
    out: list[str] = []
    i = 0
    n = len(text)
    in_str = False
    while i < n:
        c = text[i]
        if c == '"' and (i == 0 or text[i - 1] != "\\"):
            in_str = not in_str
            out.append(c)
            i += 1
            continue
        if not in_str and c == "/" and i + 1 < n and text[i + 1] == "/":
            # Comment runs to end of line.
            j = text.find("\n", i)
            if j < 0:
                break
            i = j  # leave the newline in so brace counting stays happy
            continue
        out.append(c)
        i += 1
    return "".join(out)


def _find_dependencies_block(text: str) -> str | None:
    """Return the raw text inside the top-level `.dependencies = .{ ... }`
    block, or None if absent.  Handles nested anonymous structs."""
    text = _strip_comments(text)
    needle = ".dependencies"
    idx = text.find(needle)
    if idx < 0:
        return None
    # Find the next `.{` after `.dependencies`.
    open_idx = text.find(".{", idx)
    if open_idx < 0:
        return None
    # Walk forward, tracking brace depth, until we close the matching `}`.
    depth = 0
    i = open_idx + 1  # start past the leading `.` so the `{` is at i
    n = len(text)
    body_start = -1
    while i < n:
        c = text[i]
        if c == "{":
            if depth == 0:
                body_start = i + 1
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                return text[body_start:i]
        i += 1
    return None


def _parse_dep_entries(deps_block: str) -> List[Tuple[str, str, str | None]]:
    """Yield (name, hash, url) for each `.name = .{ .url=, .hash= }`
    entry inside `deps_block`.  Skips entries that lack a `hash`
    (path-pinned deps, malformed entries) — they cannot diamond."""
    out: List[Tuple[str, str, str | None]] = []
    for m in DEP_BLOCK_RE.finditer(deps_block):
        name = m.group("name")
        body = m.group("body")
        h = HASH_RE.search(body)
        if not h:
            continue
        u = URL_RE.search(body)
        out.append((name, h.group("hash"), u.group("url") if u else None))
    return out


def _zon_path_for_hash(project_root: Path, zig_global_cache: Path, pkg_hash: str) -> Path | None:
    """Return the cached `build.zig.zon` path for a given package hash,
    or None if neither cache has it.  Zig extracts dependencies into
    `<project>/zig-pkg/<pkg_hash>/` (project-local) and stores tarballs
    in `$ZIG_GLOBAL_CACHE_DIR/p/<pkg_hash>.tar.gz` (global).  Only the
    project-local extraction has a usable `build.zig.zon` on disk —
    we don't want to untar the global cache here."""
    candidate = project_root / "zig-pkg" / pkg_hash / "build.zig.zon"
    if candidate.exists():
        return candidate
    candidate = zig_global_cache / "p" / pkg_hash / "build.zig.zon"
    if candidate.exists():
        return candidate
    return None


def collect_transitive(root_zon: Path, zig_global_cache: Path) -> Dict[str, Set[Tuple[str, str | None]]]:
    """Walk the project's dependency graph.  Returns a map
    name -> set of (hash, url) seen across the transitive closure."""
    project_root = root_zon.parent
    result: Dict[str, Set[Tuple[str, str | None]]] = defaultdict(set)
    seen_hashes: Set[str] = set()
    queue: List[Path] = [root_zon]
    while queue:
        zon_path = queue.pop(0)
        try:
            text = zon_path.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        deps_block = _find_dependencies_block(text)
        if deps_block is None:
            continue
        for name, h, url in _parse_dep_entries(deps_block):
            result[name].add((h, url))
            if h in seen_hashes:
                continue
            seen_hashes.add(h)
            child_zon = _zon_path_for_hash(project_root, zig_global_cache, h)
            if child_zon is not None:
                queue.append(child_zon)
    return result


def find_diamonds(graph: Dict[str, Set[Tuple[str, str | None]]]) -> List[Tuple[str, List[Tuple[str, str | None]]]]:
    """Return [(name, [(hash, url), ...]), ...] for every package name
    that appears with more than one distinct hash."""
    diamonds: List[Tuple[str, List[Tuple[str, str | None]]]] = []
    for name, pinned in graph.items():
        if len({h for (h, _u) in pinned}) > 1:
            diamonds.append((name, sorted(pinned)))
    return sorted(diamonds, key=lambda x: x[0])


def main(argv: List[str]) -> int:
    project_root = Path(argv[1]).resolve() if len(argv) >= 2 else Path.cwd()
    zon = project_root / "build.zig.zon"
    if not zon.exists():
        print(f"detect-diamond-deps: no build.zig.zon at {project_root}", file=sys.stderr)
        return 2

    cache_env = os.environ.get("ZIG_GLOBAL_CACHE_DIR")
    if cache_env:
        cache_root = Path(cache_env)
    else:
        cache_root = Path.home() / ".cache" / "zig"
    if not (cache_root / "p").is_dir():
        print(
            f"detect-diamond-deps: zig package cache not found at {cache_root}/p — "
            "run `zig build --fetch` first or skip this hook",
            file=sys.stderr,
        )
        return 2

    graph = collect_transitive(zon, cache_root)
    diamonds = find_diamonds(graph)
    if not diamonds:
        n_total = sum(len(v) for v in graph.values())
        print(
            f"detect-diamond-deps: clean — {len(graph)} unique package names, "
            f"{n_total} (name, hash) tuples, 0 diamonds.",
            file=sys.stderr,
        )
        return 0

    print("detect-diamond-deps: DIAMOND DEPS DETECTED", file=sys.stderr)
    print("", file=sys.stderr)
    for name, pinned in diamonds:
        print(f"  {name}:", file=sys.stderr)
        for h, url in pinned:
            tail = f"  ({url})" if url else ""
            print(f"    - {h}{tail}", file=sys.stderr)
    print("", file=sys.stderr)
    print(
        "Resolve by bumping every transitive consumer to the same hash.\n"
        "See scripts/sync_diamond_deps.sh for the recommended workflow.",
        file=sys.stderr,
    )
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
