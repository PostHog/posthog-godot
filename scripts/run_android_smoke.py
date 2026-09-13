#!/usr/bin/env python3
"""Export and run the mobile sample through four Android app launches."""

import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time

from install_godot import EDITORS
from test_exports import run

ROOT = Path(__file__).resolve().parents[1]


def collect(device, bundle, phase, destination):
    deadline = time.monotonic() + 75
    while time.monotonic() < deadline:
        pid = subprocess.run(
            ["adb", "-s", device, "shell", "pidof", bundle],
            capture_output=True,
            text=True,
            check=False,
        ).stdout.strip()
        if pid:
            result = subprocess.run(
                ["adb", "-s", device, "logcat", "-d", "--pid=" + pid],
                capture_output=True,
                text=True,
                encoding="utf-8",
                errors="replace",
                check=True,
            )
            log = result.stdout
            (destination / f"phase-{phase}.log").write_text(log, encoding="utf-8")
            for line in log.splitlines():
                if "SMOKE_REPORT " not in line:
                    continue
                summary = json.loads(line.split("SMOKE_REPORT ", 1)[1])
                checks = [
                    json.loads(line.split("SMOKE_CHECK ", 1)[1])
                    for line in log.splitlines()
                    if "SMOKE_CHECK " in line
                ]
                http = [
                    json.loads(line.split("SMOKE_HTTP ", 1)[1])
                    for line in log.splitlines()
                    if "SMOKE_HTTP " in line
                ]
                events = [
                    json.loads(line.split("SMOKE_EVENT ", 1)[1])
                    for line in log.splitlines()
                    if "SMOKE_EVENT " in line
                ]
                report = {
                    "summary": summary,
                    "checks": checks,
                    "http": http,
                    "events": events,
                }
                (destination / f"report-{phase}.json").write_text(
                    json.dumps(report, indent=2), encoding="utf-8"
                )
                if summary["phase"] != phase:
                    raise RuntimeError(
                        "Sample has existing progress; prepare a new run for a fresh suite"
                    )
                if (
                    not summary["passed"]
                    or not checks
                    or not all(check["passed"] for check in checks)
                ):
                    raise RuntimeError(f"Smoke checks failed: {summary}")
                if len(checks) != summary["check_count"]:
                    raise RuntimeError("Incomplete logcat assertions")
                print(json.dumps(summary))
                return
        time.sleep(0.5)
    raise RuntimeError(f"No smoke report for phase {phase}; inspect {destination}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "run_file", type=Path, help="run.json emitted by prepare_mobile_smoke.py"
    )
    parser.add_argument(
        "--device", required=True, help="Explicit adb device serial, e.g. emulator-5554"
    )
    parser.add_argument(
        "--godot",
        default=os.environ.get("GODOT")
        or str(ROOT / ".cache/godot/editor" / EDITORS[sys.platform][1]),
    )
    args = parser.parse_args()
    metadata = json.loads(args.run_file.read_text(encoding="utf-8"))
    bundle = metadata["bundle_id"]
    if not re.fullmatch(r"[A-Za-z][A-Za-z0-9_]*(?:\.[A-Za-z][A-Za-z0-9_]*)+", bundle):
        parser.error("Invalid bundle ID")
    project = Path(metadata["project"])
    destination = Path(metadata["output"]) / "android"
    destination.mkdir(parents=True, exist_ok=True)
    version = run([args.godot, "--version"]).strip()
    if not version.startswith("4.5.stable"):
        parser.error("This sample uses matching Godot 4.5-stable templates/editor")
    run(
        [
            args.godot,
            "--headless",
            "--path",
            str(project),
            "--editor",
            "--import",
            "--quit",
        ]
    )
    apk = destination / "smoke.apk"
    run(
        [
            args.godot,
            "--headless",
            "--path",
            str(project),
            "--export-release",
            "Android Smoke",
            str(apk),
        ]
    )
    adb = ["adb", "-s", args.device]
    run(adb + ["install", "--no-incremental", "-r", str(apk)])
    for phase in range(4):
        run(adb + ["shell", "am", "force-stop", bundle])
        run(adb + ["shell", "am", "start", "-n", bundle + "/com.godot.game.GodotApp"])
        collect(args.device, bundle, phase, destination)
    print(f"Android smoke checks passed; reports: {destination}")


if __name__ == "__main__":
    main()
