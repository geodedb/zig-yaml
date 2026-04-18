#!/usr/bin/env python3
"""Validate fenced ``` mermaid ``` blocks in markdown files using mermaid-cli.

Usage:
    scripts/check-mermaid.py [FILE ...]

If FILE list is empty, validates every tracked ``*.md`` under ``docs/``.
Intended for use as a pre-commit hook; pre-commit passes the staged files
as positional arguments.

Exit codes:
    0 - all blocks valid (or no blocks in inputs)
    1 - at least one block failed to parse / render
    2 - mermaid-cli (``mmdc``) not found

Resolving ``mmdc``:
    1. ``$MERMAID_CLI`` environment variable (absolute path), if set
    2. ``./node_modules/.bin/mmdc`` (local install)
    3. ``mmdc`` on ``$PATH``
    4. ``npx --no-install mmdc`` (uses locally cached install only)

Install locally with:
    npm install --no-save @mermaid-js/mermaid-cli
or globally with:
    npm install -g @mermaid-js/mermaid-cli
"""
from __future__ import annotations

import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


REPO = Path(__file__).resolve().parent.parent


def resolve_mmdc() -> list[str] | None:
    """Return the command-list for invoking mmdc, or None if unavailable."""
    env = os.environ.get("MERMAID_CLI")
    if env and Path(env).is_file() and os.access(env, os.X_OK):
        return [env]

    local = REPO / "node_modules" / ".bin" / "mmdc"
    if local.is_file() and os.access(local, os.X_OK):
        return [str(local)]

    which = shutil.which("mmdc")
    if which:
        return [which]

    npx = shutil.which("npx")
    if npx:
        # --no-install guarantees we don't accidentally download chromium
        # inside a commit hook. Only succeeds if mmdc is already cached.
        return [npx, "--no-install", "mmdc"]

    return None


def extract_blocks(md_path: Path) -> list[tuple[int, str]]:
    """Return list of (start_line, content) for each ```mermaid block."""
    blocks: list[tuple[int, str]] = []
    in_block = False
    start = 0
    buf: list[str] = []
    for i, line in enumerate(md_path.read_text().splitlines(), 1):
        stripped = line.strip()
        if not in_block and stripped == "```mermaid":
            in_block = True
            start = i
            buf = []
        elif in_block and stripped == "```":
            blocks.append((start, "\n".join(buf)))
            in_block = False
        elif in_block:
            buf.append(line)
    return blocks


def validate_block(
    mmdc: list[str], src: Path, line: int, idx: int, content: str
) -> tuple[bool, str]:
    """Render a single block to a temp svg; return (ok, stderr_tail)."""
    with tempfile.TemporaryDirectory() as td:
        inp = Path(td) / f"{src.stem}-{idx}.mmd"
        out = Path(td) / f"{src.stem}-{idx}.svg"
        inp.write_text(content)
        try:
            r = subprocess.run(
                [*mmdc, "-i", str(inp), "-o", str(out), "-q"],
                capture_output=True,
                text=True,
                timeout=120,
            )
        except subprocess.TimeoutExpired:
            return False, "timed out after 120s"
        if r.returncode == 0:
            return True, ""
        # Prefer the first parse-error line; fall back to last lines of stderr.
        lines = (r.stderr or r.stdout).strip().splitlines()
        tail: list[str] = []
        for ln in lines:
            if "at async" in ln or ln.startswith("    at "):
                break
            tail.append(ln)
        if not tail:
            tail = lines[-4:]
        return False, "\n".join(tail).strip()


def main(argv: list[str]) -> int:
    mmdc = resolve_mmdc()
    if mmdc is None:
        sys.stderr.write(
            "mermaid-cli (mmdc) not found. Install with:\n"
            "    npm install -g @mermaid-js/mermaid-cli\n"
            "or set MERMAID_CLI=/abs/path/to/mmdc\n"
        )
        return 2

    if argv:
        md_files = [Path(a) for a in argv if a.endswith(".md") and Path(a).is_file()]
    else:
        md_files = sorted((REPO / "docs").rglob("*.md"))

    total = 0
    fails: list[tuple[Path, int, int, str]] = []
    for md in md_files:
        blocks = extract_blocks(md)
        for idx, (line, content) in enumerate(blocks, 1):
            total += 1
            ok, err = validate_block(mmdc, md, line, idx, content)
            if not ok:
                fails.append((md, line, idx, err))
                try:
                    rel = md.relative_to(REPO)
                except ValueError:
                    rel = md
                sys.stderr.write(
                    f"FAIL  {rel}:{line}  (mermaid block #{idx})\n{err}\n\n"
                )

    if fails:
        sys.stderr.write(
            f"{len(fails)} of {total} mermaid block(s) failed to render.\n"
        )
        return 1
    if total:
        sys.stdout.write(f"ok  {total} mermaid block(s) rendered\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
