#!/usr/bin/env python3
"""Build real release exports and validate desktop delivery or prepare browser tests."""

import argparse
from http.server import ThreadingHTTPServer
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import threading
from zipfile import ZipFile

from install_godot import RELEASES, VERSION, validate_editor_version
from test import Handler, requests

ROOT = Path(__file__).resolve().parents[1]
WEB_HOST = "http://127.0.0.1:47836/allowed"


def run(command, **kwargs):
    result = subprocess.run(
        command,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        timeout=180,
        **kwargs,
    )
    output = result.stdout + result.stderr
    print(output)
    if result.returncode or "SCRIPT ERROR:" in output:
        raise RuntimeError(f"Command failed: {command}")
    return output


def build(godot, templates, destination, target, track_stacks, host):
    destination.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="posthog-export-project-") as temporary:
        project = Path(temporary)
        shutil.copytree(
            ROOT / "tests/exports",
            project,
            dirs_exist_ok=True,
            ignore=shutil.ignore_patterns(".godot", ".gdignore"),
        )
        shutil.copytree(ROOT / "addons/posthog", project / "addons/posthog")
        config = project / "config.tres"
        config.write_text(config.read_text().replace(WEB_HOST, host), encoding="utf-8")
        settings = project / "project.godot"
        text = settings.read_text().replace(
            "always_track_call_stacks=true",
            f"always_track_call_stacks={str(track_stacks).lower()}",
        )
        if target != "web":
            config.write_text(
                config.read_text() + "persistence = false\n", encoding="utf-8"
            )
        settings.write_text(text, encoding="utf-8")
        if target == "web":
            platform, template, filename = (
                "Web",
                "web_nothreads_release.zip",
                "index.html",
            )
            options = "variant/thread_support=false\nvariant/extensions_support=false\n"
        else:
            platform, template, filename = {
                "linux": ("Linux", "linux_release.x86_64", "export-test.x86_64"),
                "darwin": ("macOS", "macos.zip", "export-test.zip"),
                "win32": (
                    "Windows Desktop",
                    "windows_release_x86_64.exe",
                    "export-test.exe",
                ),
            }[sys.platform]
            options = 'application/bundle_identifier="com.posthog.exporttests"\ncodesign/codesign=0\napplication/modify_resources=false\n'
        template_path = templates / template
        if not template_path.is_file():
            raise RuntimeError(
                f"Missing {template_path}; run scripts/install_godot.py --templates"
            )
        preset = f'''[preset.0]
name="SDK Tests"
platform="{platform}"
runnable=true
export_filter="all_resources"
include_filter=""
exclude_filter=""
export_path=""
script_export_mode=2

[preset.0.options]
custom_template/release="{template_path.as_posix()}"
{options}'''
        (project / "export_presets.cfg").write_text(preset, encoding="utf-8")
        imported = run(
            [
                godot,
                "--headless",
                "--path",
                str(project),
                "--editor",
                "--import",
                "--quit",
            ]
        )
        if "ERROR:" in imported:
            raise RuntimeError("Export project import failed")
        artifact = destination / filename
        exported = run(
            [
                godot,
                "--headless",
                "--path",
                str(project),
                "--export-release",
                "SDK Tests",
                str(artifact),
            ]
        )
        if "ERROR:" in exported or not artifact.is_file():
            raise RuntimeError("Release export failed")
    if target != "web" and sys.platform == "darwin":
        with ZipFile(artifact) as archive:
            archive.extractall(destination)
        artifact = next(destination.glob("*.app/Contents/MacOS/*"))
    if target != "web":
        artifact.chmod(0o755)
    return artifact


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--target", choices=["desktop", "web"], default="desktop")
    args = parser.parse_args()
    expected = os.environ.get("GODOT_VERSION", VERSION)
    if expected not in RELEASES:
        raise SystemExit(f"Unsupported pinned Godot version: {expected}")
    editors, _ = RELEASES[expected]
    godot = os.environ.get("GODOT") or str(
        ROOT / ".cache/godot/editor" / editors[sys.platform][1]
    )
    templates = Path(
        os.environ.get("GODOT_TEMPLATES", ROOT / ".cache/godot/templates")
    ).resolve()
    version = subprocess.check_output([godot, "--version"], text=True)
    validate_editor_version(version, expected)
    destination = ROOT / "dist/export-tests" / args.target
    if args.target == "web":
        for enabled in [True, False]:
            build(
                godot,
                templates,
                destination / ("stack-on" if enabled else "stack-off"),
                "web",
                enabled,
                WEB_HOST,
            )
        print(f"Browser release exports ready: {destination}")
        return
    with ThreadingHTTPServer(("127.0.0.1", 0), Handler) as server:
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            host = f"http://127.0.0.1:{server.server_port}"
            for enabled in [True, False]:
                requests.clear()
                artifact = build(
                    godot,
                    templates,
                    destination / ("stack-on" if enabled else "stack-off"),
                    "desktop",
                    enabled,
                    host,
                )
                output = run([str(artifact), "--headless"])
                errors = [
                    line for line in output.splitlines() if line.startswith("ERROR:")
                ]
                assert all(line == "ERROR: Expected export error" for line in errors), (
                    errors
                )
                events = [
                    event
                    for path, body, _ in requests
                    if path == "/batch/"
                    for event in body["batch"]
                ]
                assert [event["event"] for event in events] == [
                    "export_smoke",
                    "$exception",
                ], events
                assert all(
                    event["properties"]["$godot_environment"] == "export_release"
                    for event in events
                )
                frames = events[1]["properties"]["$exception_list"][0]["stacktrace"][
                    "frames"
                ]
                assert all(
                    frame.get("platform") == "custom"
                    and frame.get("lang") == "godot"
                    and frame.get("resolved") is True
                    for frame in frames
                ), frames
                script_frames = [
                    frame for frame in frames if frame["filename"] == "res://main.gd"
                ]
                assert bool(script_frames) == enabled, frames
                if enabled:
                    assert any(
                        frame["function"] == "_export_error" and frame["lineno"] > 0
                        for frame in script_frames
                    )
                print(f"Desktop release export passed (call stacks: {enabled})")
        finally:
            server.shutdown()
            thread.join()


if __name__ == "__main__":
    main()
