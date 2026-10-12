#!/usr/bin/env python3
"""Build and test the actual Zig package after applying manifest .paths."""

import argparse
import os
import re
import subprocess
import tarfile
import tempfile
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--jobs", type=int, default=2)
    args = parser.parse_args()
    if args.jobs < 1:
        parser.error("--jobs must be positive")
    root = Path(__file__).resolve().parents[1]
    zig = os.environ.get("ZIG", "zig")
    tracked = subprocess.check_output(["git", "ls-files", "-z"], cwd=root).split(b"\0")
    with tempfile.TemporaryDirectory(prefix="yaml-source-package-") as directory:
        temporary = Path(directory)
        archive = temporary / "source.tar.gz"
        # Use tracked working-tree bytes so this also checks staged local fixes.
        # Generated files and ignored build products cannot hide missing inputs.
        with tarfile.open(archive, "w:gz") as source:
            for name in tracked:
                if name:
                    relative = os.fsdecode(name)
                    source.add(root / relative, arcname=relative, recursive=False)
        cache = temporary / "cache"
        package_hash = subprocess.check_output(
            [zig, "fetch", "--global-cache-dir", str(cache), str(archive)],
            cwd=root,
            text=True,
        ).strip()
        if not re.fullmatch(r"yaml-[A-Za-z0-9_.-]+", package_hash):
            raise RuntimeError("unexpected Zig package identifier")
        package_archive = cache / "p" / (package_hash + ".tar.gz")
        extracted = temporary / "extracted"
        extracted.mkdir()
        with tarfile.open(package_archive) as package:
            package.extractall(extracted, filter="data")
        package_root = extracted / package_hash
        print(f"Checking filtered source package {package_hash}", flush=True)
        for target in [[], ["test"]]:
            subprocess.run(
                [zig, "build", *target, f"-j{args.jobs}", "--summary", "all"],
                cwd=package_root,
                check=True,
            )


if __name__ == "__main__":
    main()
