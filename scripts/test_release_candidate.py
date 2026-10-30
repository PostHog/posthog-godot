"""Exercise candidate verification and approved commits without contacting GitHub."""

import base64
import copy
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch
from zipfile import ZipFile

import bump_version
import commit_release
import package
import release
import release_candidate

ROOT = Path(__file__).resolve().parents[1]


class ReleaseCandidateTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="posthog-candidate-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        paths = (
            subprocess.check_output(["git", "ls-files", "-z"], cwd=ROOT)
            .decode()
            .split("\0")
        )
        for name in filter(None, paths):
            source = ROOT / name
            if source.is_file():
                target = self.root / name
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(source, target)
        metadata = json.loads((self.root / "package.json").read_text())
        metadata["version"] = "0.1.2"
        (self.root / "package.json").write_text(json.dumps(metadata) + "\n")
        bump_version.bump_version(self.root)
        (self.root / ".changeset/ready.md").write_text("Pending release\n")
        self.git("init", "-q")
        self.git("config", "core.autocrlf", "false")
        self.git("config", "user.name", "Release test")
        self.git("config", "user.email", "release@example.com")
        self.git("add", ".")
        self.git("-c", "commit.gpgsign=false", "commit", "-qm", "source")
        self.source = self.git("rev-parse", "HEAD")
        metadata = json.loads((self.root / "package.json").read_text())
        metadata["version"] = "0.1.3"
        (self.root / "package.json").write_text(json.dumps(metadata) + "\n")
        bump_version.bump_version(self.root)
        (self.root / ".changeset/ready.md").unlink()
        (self.root / ".changeset/ledger.yaml").write_text("consumed: ready\n")
        self.git("add", "package.json", "addons", "project.godot", ".changeset")
        self.tree = self.git("write-tree")
        self.patch = self.root / "dist/release-candidate/release.patch"
        self.patch.parent.mkdir(parents=True)
        self.patch.write_bytes(
            subprocess.check_output(
                ["git", "diff", "--cached", "--binary"], cwd=self.root
            )
        )
        self.digest = hashlib.sha256(self.patch.read_bytes()).hexdigest()
        self.output = self.root / "dist/outputs"
        self.original_cwd = Path.cwd()
        os.chdir(self.root)
        self.addCleanup(os.chdir, self.original_cwd)
        environment = patch.dict(
            os.environ,
            {
                "GH_REPO": "PostHog/posthog-godot",
                "NEW_VERSION": "0.1.3",
                "EXPECTED_TREE_SHA": self.tree,
                "GITHUB_OUTPUT": str(self.output),
            },
        )
        environment.start()
        self.addCleanup(environment.stop)
        self.remote = {
            "sha": self.source,
            "parents": [],
            "commit": {"tree": {"sha": "0" * 40}, "message": "source"},
        }
        self.requests = []
        self.real_run = subprocess.run

    def git(self, *args):
        return subprocess.check_output(["git", *args], cwd=self.root, text=True).strip()

    def github(self, command, **kwargs):
        if command[0] != "gh":
            return self.real_run(command, **kwargs)
        self.requests.append((command, kwargs))
        if command == ["gh", "api", "repos/PostHog/posthog-godot/commits/main"]:
            response = self.remote
        elif command == ["gh", "api", "graphql", "--input", "-"]:
            if self.remote["sha"] != self.source:
                raise subprocess.CalledProcessError(1, command, stderr="main moved")
            response = {"data": {"createCommitOnBranch": {"commit": {"oid": "a" * 40}}}}
        else:
            self.fail(f"Unexpected GitHub command: {command}")
        return subprocess.CompletedProcess(command, 0, stdout=json.dumps(response))

    def commit(self):
        with patch("commit_release.subprocess.run", side_effect=self.github):
            commit_release.main()

    def existing_release(self):
        return {
            "sha": "b" * 40,
            "parents": [{"sha": self.source}],
            "commit": {
                "tree": {"sha": self.tree},
                "message": "chore: release 0.1.3 [version bump]",
                "verification": {"verified": True},
            },
        }

    def apply(self, **overrides):
        arguments = dict(
            patch=self.patch,
            source=self.source,
            digest=self.digest,
            tree=self.tree,
            version="0.1.3",
        )
        arguments.update(overrides)
        with (
            patch("package.ROOT", self.root),
            patch("package.ADDON", self.root / "addons/posthog"),
        ):
            release_candidate.apply_candidate(**arguments)

    def restore_source(self):
        self.git("restore", "--source=HEAD", "--staged", "--worktree", "--", ".")

    def test_apply_preserves_source_commit_and_reproduces_candidate_tree(self):
        self.restore_source()
        self.apply()
        self.assertEqual(self.git("rev-parse", "HEAD"), self.source)
        self.assertEqual(self.git("write-tree"), self.tree)
        self.assertEqual(
            json.loads((self.root / "package.json").read_text())["version"], "0.1.3"
        )
        self.assertFalse((self.root / ".changeset/ready.md").exists())
        self.assertTrue((self.root / ".changeset/ledger.yaml").exists())

    def test_source_and_checksum_are_checked_before_applying(self):
        self.restore_source()
        for arguments in ({"source": "0" * 40}, {"digest": "0" * 64}):
            with (
                self.subTest(arguments=arguments),
                self.assertRaisesRegex(ValueError, "source|checksum"),
            ):
                self.apply(**arguments)
            self.assertEqual(self.git("status", "--porcelain"), "")

    def test_applied_tree_and_version_must_match_candidate(self):
        for arguments in ({"tree": "0" * 40}, {"version": "0.1.4"}):
            with self.subTest(arguments=arguments):
                self.restore_source()
                with self.assertRaisesRegex(ValueError, "tree|version"):
                    self.apply(**arguments)

    def test_final_assets_use_the_approved_commit_not_the_candidate_parent(self):
        self.git("-c", "commit.gpgsign=false", "commit", "-qm", "approved release")
        revision = self.git("rev-parse", "HEAD")
        self.assertNotEqual(revision, self.source)
        self.assertEqual(self.git("rev-parse", "HEAD^{tree}"), self.tree)
        with (
            patch("package.ROOT", self.root),
            patch("package.ADDON", self.root / "addons/posthog"),
            patch("release.ROOT", self.root),
        ):
            package.main()
            release.prepare_release("0.1.3", self.root / "dist")
        metadata = json.loads((self.root / "dist/asset-library.json").read_text())
        self.assertEqual(metadata["source_commit"], revision)
        with ZipFile(self.root / "dist/posthog-godot-0.1.3.zip") as archive:
            contributing = archive.read("addons/posthog/CONTRIBUTING.md").decode()
        self.assertIn(f"/blob/{revision}/examples/mobile_smoke/README.md", contributing)
        self.assertNotIn(
            f"/blob/{self.source}/examples/mobile_smoke/README.md", contributing
        )
        for entry in (self.root / "dist/SHA256SUMS").read_text().splitlines():
            digest, name = entry.split("  ")
            self.assertEqual(
                digest,
                hashlib.sha256((self.root / "dist" / name).read_bytes()).hexdigest(),
            )

    def test_commit_uses_verified_tree_and_expected_parent(self):
        self.commit()
        mutations = [
            request for command, request in self.requests if command[2] == "graphql"
        ]
        self.assertEqual(len(mutations), 1)
        request = json.loads(mutations[0]["input"])["variables"]["input"]
        self.assertEqual(request["expectedHeadOid"], self.source)
        self.assertEqual(
            request["branch"],
            {"repositoryNameWithOwner": "PostHog/posthog-godot", "branchName": "main"},
        )
        changes = request["fileChanges"]
        self.assertEqual(changes["deletions"], [{"path": ".changeset/ready.md"}])
        additions = {
            entry["path"]: base64.b64decode(entry["contents"])
            for entry in changes["additions"]
        }
        self.assertEqual(
            additions["package.json"], (self.root / "package.json").read_bytes()
        )
        self.assertEqual(self.output.read_text(), "sha=" + "a" * 40 + "\n")

    def test_unverified_tree_is_rejected_before_contacting_github(self):
        with patch.dict(os.environ, EXPECTED_TREE_SHA="0" * 40):
            with self.assertRaisesRegex(ValueError, "tree"):
                self.commit()
        self.assertEqual(self.requests, [])
        self.assertFalse(self.output.exists())

    def test_stale_main_is_rejected_without_a_mutation(self):
        self.remote["sha"] = "c" * 40
        with self.assertRaisesRegex(ValueError, "main moved"):
            self.commit()
        self.assertFalse(any(command[2] == "graphql" for command, _ in self.requests))
        self.assertFalse(self.output.exists())

    def test_retry_reuses_the_signed_release_commit(self):
        self.remote = self.existing_release()
        self.commit()
        self.assertFalse(any(command[2] == "graphql" for command, _ in self.requests))
        self.assertEqual(self.output.read_text(), "sha=" + "b" * 40 + "\n")

    def test_retry_rejects_a_different_or_unsigned_commit(self):
        for field in ("parent", "tree", "message", "signature"):
            with self.subTest(field=field):
                self.remote = copy.deepcopy(self.existing_release())
                if field == "parent":
                    self.remote["parents"][0]["sha"] = "c" * 40
                elif field == "tree":
                    self.remote["commit"]["tree"]["sha"] = "c" * 40
                elif field == "message":
                    self.remote["commit"]["message"] = "other release"
                else:
                    self.remote["commit"]["verification"]["verified"] = False
                with self.assertRaisesRegex(ValueError, "main moved"):
                    self.commit()
                self.assertFalse(self.output.exists())


if __name__ == "__main__":
    unittest.main()
