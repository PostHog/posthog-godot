"""Test pinned toolchain selection and archive verification without downloads."""

import hashlib
import io
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from zipfile import ZipFile

import install_godot


def archive_bytes(files):
    output = io.BytesIO()
    with ZipFile(output, "w") as archive:
        for name, content in files.items():
            archive.writestr(name, content)
    return output.getvalue()


class InstallerTests(unittest.TestCase):
    def test_default_keeps_original_mobile_toolchain(self):
        self.assertEqual(install_godot.VERSION, "4.5-stable")
        self.assertEqual(install_godot.RELEASES["4.5-stable"][0], install_godot.EDITORS)

    def test_editor_version_must_match_selected_pin(self):
        for version in ("4.5-stable", "4.5.1-stable"):
            output = version.replace("-stable", ".stable.official.test") + "\n"
            install_godot.validate_editor_version(output, version)
        for output, expected in (
            ("4.5.stable.official.test", "4.5.1-stable"),
            ("4.5.1.stable.official.test", "4.5-stable"),
            ("4.7.stable.official.test", "4.7-stable"),
            ("4.5.10.stable.official.test", "4.5.1-stable"),
        ):
            with (
                self.subTest(output=output, expected=expected),
                self.assertRaises(SystemExit),
            ):
                install_godot.validate_editor_version(output, expected)

    def test_corrupt_archive_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "archive.zip"
            path.write_bytes(b"corrupt archive")
            with self.assertRaises(SystemExit):
                install_godot.verified_archive(
                    path, path.name, "0" * 64, "4.5.1-stable"
                )

    def test_fixed_macos_editor_and_templates_use_same_release(self):
        version = "4.5.1-stable"
        executable = "Godot.app/Contents/MacOS/Godot"
        editor = archive_bytes({executable: b"test editor"})
        templates = archive_bytes(
            {
                "templates/macos.zip": b"test template",
                "templates/web_nothreads_release.zip": b"web template",
            }
        )
        manifest = (
            {
                "darwin": (
                    "macos.universal.zip",
                    executable,
                    hashlib.sha256(editor).hexdigest(),
                )
            },
            hashlib.sha256(templates).hexdigest(),
        )
        urls = []

        def download(url, **_kwargs):
            urls.append(url)
            return io.BytesIO(templates if url.endswith(".tpz") else editor)

        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary).resolve()
            environment = directory / "github-env"
            with (
                patch.dict(install_godot.RELEASES, {version: manifest}),
                patch("install_godot.sys.platform", "darwin"),
                patch(
                    "install_godot.sys.argv",
                    [
                        "install_godot.py",
                        "--version",
                        version,
                        "--templates",
                        "--directory",
                        temporary,
                    ],
                ),
                patch.dict(os.environ, {"GITHUB_ENV": str(environment)}, clear=True),
                patch("install_godot.urlopen", side_effect=download),
            ):
                install_godot.main()
            self.assertEqual(
                urls,
                [
                    f"https://github.com/godotengine/godot/releases/download/{version}/Godot_v{version}_macos.universal.zip",
                    f"https://github.com/godotengine/godot/releases/download/{version}/Godot_v{version}_export_templates.tpz",
                ],
            )
            self.assertEqual(
                (directory / "editor" / executable).read_bytes(), b"test editor"
            )
            self.assertEqual(
                (directory / "templates/macos.zip").read_bytes(), b"test template"
            )
            values = dict(
                line.split("=", 1) for line in environment.read_text().splitlines()
            )
            self.assertEqual(values["GODOT_VERSION"], version)
            self.assertEqual(Path(values["GODOT"]), directory / "editor" / executable)
            self.assertEqual(Path(values["GODOT_TEMPLATES"]), directory / "templates")


if __name__ == "__main__":
    unittest.main()
