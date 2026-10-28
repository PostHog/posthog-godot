"""Validate release metadata and checksums without publishing anything."""

import hashlib
import json
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import bump_version
import release

ROOT = Path(__file__).resolve().parents[1]


class ReleaseTests(unittest.TestCase):
    def version_fixture(self, directory, version):
        for name in (
            "package.json",
            "addons/posthog/plugin.cfg",
            "addons/posthog/internal/utils.gd",
            "project.godot",
        ):
            path = directory / name
            path.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / name, path)
        metadata = json.loads((directory / "package.json").read_text())
        metadata["version"] = version
        (directory / "package.json").write_text(json.dumps(metadata))

    def test_bump_updates_all_declarations_and_preserves_other_content(self):
        old_version = release.package.get_version()
        for version in ("0.1.3", "0.2.0", "1.0.0", "0.2.0-rc.1"):
            with self.subTest(version=version), tempfile.TemporaryDirectory() as temp:
                directory = Path(temp)
                self.version_fixture(directory, version)
                paths = [
                    directory / name
                    for name in (
                        "addons/posthog/plugin.cfg",
                        "addons/posthog/internal/utils.gd",
                        "project.godot",
                    )
                ]
                originals = {path: path.read_text() for path in paths}
                self.assertEqual(bump_version.bump_version(directory), version)
                for path in paths:
                    self.assertEqual(
                        path.read_text(), originals[path].replace(old_version, version)
                    )
                with (
                    patch("package.ROOT", directory),
                    patch("package.ADDON", directory / "addons/posthog"),
                ):
                    self.assertEqual(release.package.get_version(), version)

    def test_invalid_release_version_does_not_modify_declarations(self):
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            self.version_fixture(directory, "v0.2.0")
            plugin = directory / "addons/posthog/plugin.cfg"
            original = plugin.read_bytes()
            with self.assertRaises(ValueError):
                bump_version.bump_version(directory)
            self.assertEqual(plugin.read_bytes(), original)

    def test_missing_declaration_does_not_partially_bump(self):
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            self.version_fixture(directory, "0.2.0")
            (directory / "project.godot").write_text("[application]\n")
            plugin = directory / "addons/posthog/plugin.cfg"
            original = plugin.read_bytes()
            with self.assertRaisesRegex(ValueError, "project.godot"):
                bump_version.bump_version(directory)
            self.assertEqual(plugin.read_bytes(), original)

    def test_package_rejects_mismatched_release_metadata(self):
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            self.version_fixture(directory, "99.0.0")
            with (
                patch("package.ROOT", directory),
                patch("package.ADDON", directory / "addons/posthog"),
                self.assertRaises(AssertionError),
            ):
                release.package.get_version()

    def test_tag_must_match_package_version(self):
        with patch("release.package.get_version", return_value="0.1.0"):
            self.assertEqual(release.validate_tag("0.1.0"), "0.1.0")
            for tag in ("v0.1.0", "0.1.1", "main", "0.1.0/extra", "0.1.0\n"):
                with self.subTest(tag=tag), self.assertRaises(ValueError):
                    release.validate_tag(tag)

    def test_prerelease_version(self):
        with patch("release.package.get_version", return_value="0.2.0-rc.1"):
            self.assertEqual(release.validate_tag("0.2.0-rc.1"), "0.2.0-rc.1")
            with self.assertRaises(ValueError):
                release.validate_tag("v0.2.0-rc.1")

    def test_missing_archive(self):
        version = release.package.get_version()
        with tempfile.TemporaryDirectory(
            prefix="posthog-release-missing-"
        ) as temporary:
            directory = Path(temporary)
            with self.assertRaises(FileNotFoundError):
                release.prepare_release(version, directory)
            self.assertFalse((directory / "asset-library.json").exists())
            self.assertFalse((directory / "SHA256SUMS").exists())

    def test_asset_library_icon(self):
        icon = (ROOT / "docs/assets/icon.png").read_bytes()
        self.assertEqual(icon[:8], b"\x89PNG\r\n\x1a\n")
        width, height = struct.unpack(">II", icon[16:24])
        self.assertEqual(width, height)
        self.assertGreaterEqual(width, 128)

    def test_release_assets(self):
        version = release.package.get_version()
        subprocess.run(
            [sys.executable, str(ROOT / "scripts/package.py")],
            check=True,
            capture_output=True,
        )
        revision = subprocess.check_output(
            ["git", "rev-parse", "HEAD"], cwd=ROOT, text=True
        ).strip()
        with tempfile.TemporaryDirectory(prefix="posthog-release-test-") as temporary:
            directory = Path(temporary)
            archive = directory / f"posthog-godot-{version}.zip"
            shutil.copyfile(ROOT / "dist" / archive.name, archive)
            release.prepare_release(version, directory)
            metadata = json.loads((directory / "asset-library.json").read_text())
            self.assertEqual(metadata["repository_host"], "Custom")
            self.assertEqual(metadata["source_commit"], revision)
            self.assertEqual(metadata["version"], version)
            self.assertEqual(metadata["godot_version"], "4.5")
            self.assertEqual(metadata["license"], "MIT")
            self.assertEqual(
                metadata["download_commit"],
                f"https://github.com/PostHog/posthog-godot/releases/download/{version}/{archive.name}",
            )
            self.assertEqual(
                metadata["icon_url"],
                f"https://raw.githubusercontent.com/PostHog/posthog-godot/{revision}/docs/assets/icon.png",
            )
            self.assertIn("Experimental", metadata["description"])
            with patch("release.subprocess.check_output", return_value="0" * 40):
                with self.assertRaises(AssertionError):
                    release.prepare_release(version, directory)
            self.assertEqual(
                json.loads((directory / "asset-library.json").read_text()), metadata
            )
            entries = (directory / "SHA256SUMS").read_text().splitlines()
            self.assertEqual(len(entries), 2)
            for entry in entries:
                digest, name = entry.split("  ")
                self.assertEqual(
                    digest, hashlib.sha256((directory / name).read_bytes()).hexdigest()
                )


if __name__ == "__main__":
    unittest.main()
