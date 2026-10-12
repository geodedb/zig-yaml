#!/usr/bin/env python3
"""SONNY-4778: hook tool caches must not change the enclosing Git worktree."""

import hashlib
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WRAPPER = ROOT / "scripts/hook-env.sh"


class HookEnvironmentTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="zig-hook-env-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.clean_env = {
            key: value
            for key, value in os.environ.items()
            if not key.startswith("GIT_")
        }
        self.clean_env.update(GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1")
        self.parent = self.make_repo("enclosing")
        self.linked = self.root / "protected worktree"
        self.git(self.parent, "worktree", "add", "--detach", str(self.linked), "HEAD")
        self.foreign = self.make_repo("tool cache")
        gitdir = Path(self.git(self.linked, "rev-parse", "--absolute-git-dir"))
        self.gitdir = gitdir
        self.poisoned_env = dict(self.clean_env)
        self.poisoned_env.update(
            GIT_DIR=str(gitdir),
            GIT_WORK_TREE=str(self.linked),
            GIT_COMMON_DIR=str(self.parent / ".git"),
            GIT_INDEX_FILE=str(gitdir / "index"),
            GIT_OBJECT_DIRECTORY=str(self.parent / ".git/objects"),
            GIT_PREFIX="nested/",
        )

    def git(self, cwd, *args):
        return subprocess.check_output(
            [
                "git",
                "-c",
                "user.name=Hook Test",
                "-c",
                "user.email=hook@example.invalid",
                *args,
            ],
            cwd=cwd,
            env=self.clean_env,
            text=True,
            stderr=subprocess.PIPE,
        ).strip()

    def make_repo(self, name):
        repo = self.root / name
        repo.mkdir()
        self.git(repo, "init", "-q", "--initial-branch=main")
        (repo / "source").write_text(name + " base\n")
        self.git(repo, "add", "source")
        self.git(repo, "commit", "-qm", "base")
        self.git(repo, "update-ref", "refs/remotes/origin/main", "HEAD")
        (repo / "source").write_text(name + " candidate\n")
        self.git(repo, "commit", "-qam", "candidate")
        return repo

    def snapshot(self):
        files = [
            self.gitdir / "index",
            self.parent / ".git/config",
            self.linked / "source",
        ]
        return self.git(self.linked, "rev-parse", "HEAD"), {
            str(path): hashlib.sha256(path.read_bytes()).hexdigest() for path in files
        }

    def run_wrapped(self, command):
        # The raw mode is used only to demonstrate RED in disposable fixtures.
        prefix = (
            []
            if os.environ.get("HOOK_ENV_RED_CONTROL") == "1"
            else ["bash", str(WRAPPER)]
        )
        return subprocess.run(
            [*prefix, *command],
            cwd=self.linked,
            env=self.poisoned_env,
            text=True,
            capture_output=True,
            check=False,
        )

    def test_foreign_reset_preserves_enclosing_head_index_config_and_source(self):
        before = self.snapshot()
        result = self.run_wrapped(
            [
                "git",
                "-C",
                str(self.foreign),
                "reset",
                "--mixed",
                "refs/remotes/origin/main",
            ]
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.snapshot(), before)
        self.assertEqual(
            self.git(self.foreign, "rev-parse", "HEAD"),
            self.git(self.foreign, "rev-parse", "refs/remotes/origin/main"),
        )

    def test_foreign_bare_init_preserves_enclosing_config_and_worktree(self):
        before = self.snapshot()
        cache = self.root / "new tool cache"
        result = self.run_wrapped(["git", "init", "--bare", str(cache)])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.snapshot(), before)
        self.assertTrue((cache / "HEAD").is_file())
        self.assertEqual(
            self.git(self.linked, "rev-parse", "--is-bare-repository"), "false"
        )

    def test_arguments_exit_status_and_nonrepository_environment_are_preserved(self):
        self.poisoned_env["GIT_SSH_COMMAND"] = "preserved-auth-command"
        self.poisoned_env["HOOK_ENV_SENTINEL"] = "preserved-value"
        result = self.run_wrapped(
            [
                sys.executable,
                "-c",
                "import json,os,sys; print(json.dumps([sys.argv[1:], os.getenv('GIT_SSH_COMMAND'), os.getenv('HOOK_ENV_SENTINEL')])); sys.exit(23)",
                "with spaces",
                "literal$()",
            ]
        )
        self.assertEqual(result.returncode, 23)
        self.assertEqual(
            json.loads(result.stdout),
            [
                ["with spaces", "literal$()"],
                "preserved-auth-command",
                "preserved-value",
            ],
        )

    def test_missing_command_fails_without_printing_environment(self):
        result = subprocess.run(
            ["bash", str(WRAPPER)],
            cwd=self.linked,
            env={"PATH": os.defpath, "HOOK_TEST_SECRET": "do-not-print-sentinel"},
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(result.returncode, 2)
        self.assertEqual(result.stdout, "")
        self.assertIn("usage:", result.stderr)
        self.assertNotIn("do-not-print-sentinel", result.stderr)

    def test_repository_local_todo_hook_reads_temporary_commit_index(self):
        alternate_index = self.root / "temporary commit index"
        shutil.copyfile(self.gitdir / "index", alternate_index)
        marker = self.linked / "temporary-index-file"
        marker.write_text("TODO: visible only in the temporary commit index\n")
        env = dict(self.poisoned_env, GIT_INDEX_FILE=str(alternate_index))
        subprocess.run(
            ["git", "add", marker.name],
            cwd=self.linked,
            env=env,
            check=True,
            capture_output=True,
        )
        self.assertEqual(self.git(self.linked, "diff", "--cached", "--name-only"), "")
        before = self.snapshot()
        alternate_before = alternate_index.read_bytes()
        # Run the actual configured hook, including its entry and shell body.
        block = (
            (ROOT / ".pre-commit-config.yaml")
            .read_text()
            .split("  - id: check-todos\n", 1)[1]
            .split("\n- repo:", 1)[0]
        )
        entry = re.search(r"(?m)^    entry: (.+)$", block)
        body = re.search(r"(?m)^    - \|\n((?:      .*\n)+)", block)
        self.assertIsNotNone(entry)
        self.assertIsNotNone(body)
        (self.linked / "scripts").mkdir()
        shutil.copyfile(WRAPPER, self.linked / "scripts/hook-env.sh")
        result = subprocess.run(
            [*shlex.split(entry[1]), "-c", textwrap.dedent(body[1])],
            cwd=self.linked,
            env=env,
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(marker.name, result.stdout)
        self.assertIn("Warning: Found TODO/FIXME markers", result.stdout)
        self.assertEqual(self.snapshot(), before)
        self.assertEqual(alternate_index.read_bytes(), alternate_before)

    def test_external_tool_hooks_use_the_environment_boundary(self):
        local = False
        entries = []
        hook_id = None
        for line in (ROOT / ".pre-commit-config.yaml").read_text().splitlines():
            if line.startswith("- repo:"):
                local = line.strip() == "- repo: local"
            if local and line.strip().startswith("- id:"):
                hook_id = line.strip().removeprefix("- id: ")
            if local and line.strip().startswith("entry:"):
                if hook_id == "check-todos":
                    continue  # This hook reads the enclosing repository's index.
                entries.append(line.strip())
                self.assertTrue(
                    line.strip().startswith("entry: bash scripts/hook-env.sh "), line
                )
        self.assertGreaterEqual(len(entries), 6)


if __name__ == "__main__":
    unittest.main()
