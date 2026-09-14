"""Verify editor-plugin metadata and autoload state across editor restarts."""

import json
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def run(godot):
    for configured in (False, True):
        with tempfile.TemporaryDirectory(prefix="posthog-editor-test-") as temporary:
            project = Path(temporary)
            shutil.copytree(ROOT / "addons/posthog", project / "addons/posthog")
            shutil.copytree(
                ROOT / "tests/editor",
                project / "addons/probe",
                ignore=shutil.ignore_patterns(".gdignore"),
            )
            settings = """config_version=5
[application]
config/name="PostHog editor integration tests"
[editor_plugins]
enabled=PackedStringArray("res://addons/posthog/plugin.cfg", "res://addons/probe/plugin.cfg")
[rendering]
renderer/rendering_method="gl_compatibility"
"""
            if configured:
                settings += """[posthog]
config="res://saved-config.tres"
[autoload]
PostHog="*res://addons/posthog/posthog.gd"
"""
            (project / "project.godot").write_text(settings, encoding="utf-8")
            for opening in range(2):
                process = subprocess.run(
                    [
                        godot,
                        "--headless",
                        "--path",
                        str(project),
                        "--editor",
                        "--import",
                        "--quit",
                    ],
                    capture_output=True,
                    text=True,
                    encoding="utf-8",
                    errors="replace",
                    timeout=120,
                )
                output = process.stdout + process.stderr
                assert process.returncode == 0 and "ERROR:" not in output, output
                reports = [
                    json.loads(line.removeprefix("POSTHOG_EDITOR_TEST "))
                    for line in output.splitlines()
                    if line.startswith("POSTHOG_EDITOR_TEST ")
                ]
                assert len(reports) == 1, output
                report = reports[0]
                assert report["file_picker"], (configured, opening, report)
                assert report["config"] == (
                    "res://saved-config.tres" if configured else ""
                ), report
                assert report["autoload"] == (
                    "*res://addons/posthog/posthog.gd" if configured else None
                ), report
    print("Editor settings persist across restarts without changing autoloads")
