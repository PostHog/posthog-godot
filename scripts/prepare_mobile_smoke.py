#!/usr/bin/env python3
"""Prepare an isolated mobile smoke-test project without storing keys in source."""

import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import shutil
import uuid

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="https://us.i.posthog.com")
    parser.add_argument("--output", type=Path, default=ROOT / "dist/mobile-smoke")
    parser.add_argument(
        "--templates", type=Path, default=ROOT / ".cache/godot/templates"
    )
    parser.add_argument(
        "--android-keystore",
        type=Path,
        default=ROOT / "dist/mobile-smoke/test.keystore",
    )
    args = parser.parse_args()
    key = os.environ.get("POSTHOG_API_KEY", "").strip()
    if not key.startswith("phc_"):
        parser.error("Set POSTHOG_API_KEY to the project token; it is never printed")
    suffix = uuid.uuid4().hex[:8]
    run_id = (
        "godot-mobile-"
        + datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        + "-"
        + suffix
    )
    bundle = "com.posthog.godotsmoke.r" + suffix
    destination = args.output.resolve() / run_id
    project = destination / "project"
    source = ROOT / "examples/mobile_smoke"
    shutil.copytree(
        source,
        project,
        ignore=shutil.ignore_patterns(
            ".gdignore",
            ".gitignore",
            ".godot",
            "addons",
            "README.md",
            "config.tres",
            "export_presets.cfg",
            "export_credentials.cfg",
        ),
    )
    shutil.copytree(ROOT / "addons/posthog", project / "addons/posthog")
    config = (source / "config.example.tres").read_text(encoding="utf-8")
    config = config.replace('api_key = ""', "api_key = " + json.dumps(key))
    config = config.replace(
        'host = "https://us.i.posthog.com"', "host = " + json.dumps(args.host)
    )
    (destination / ".gitignore").write_text("*\n", encoding="utf-8")
    (project / "config.tres").write_text(config, encoding="utf-8")
    (project / "config.tres").chmod(0o600)
    with (project / "project.godot").open("a", encoding="utf-8") as output:
        output.write("\n[mobile_smoke]\nrun_id=" + json.dumps(run_id) + "\n")
    templates = args.templates.resolve()
    presets = []
    for index, platform in enumerate(("Android", "iOS")):
        presets.append(f'''[preset.{index}]
name="{platform} Smoke"
platform="{platform}"
runnable=true
export_filter="all_resources"
include_filter=""
exclude_filter=""
export_path=""
script_export_mode=2

[preset.{index}.options]
''')
        if platform == "Android":
            presets.append(f'''custom_template/debug={json.dumps((templates / "android_debug.apk").as_posix())}
custom_template/release={json.dumps((templates / "android_release.apk").as_posix())}
gradle_build/use_gradle_build=false
architectures/armeabi-v7a=false
architectures/arm64-v8a=true
architectures/x86=false
architectures/x86_64=false
package/unique_name="{bundle}"
package/name="PostHog SDK Smoke"
package/signed=true
keystore/release={json.dumps(args.android_keystore.resolve().as_posix())}
keystore/release_user="androiddebugkey"
keystore/release_password="android"
permissions/internet=true
''')
        else:
            presets.append(f'''custom_template/debug={json.dumps((templates / "ios.zip").as_posix())}
custom_template/release={json.dumps((templates / "ios.zip").as_posix())}
application/bundle_identifier="{bundle}"
application/app_store_team_id="0000000000"
application/export_project_only=true
application/delete_old_export_files_unconditionally=true
application/min_ios_version="15.0"
''')
    (project / "export_presets.cfg").write_text("\n".join(presets), encoding="utf-8")
    metadata = {
        "run_id": run_id,
        "bundle_id": bundle,
        "project": str(project),
        "output": str(destination),
    }
    (destination / "run.json").write_text(
        json.dumps(metadata, indent=2), encoding="utf-8"
    )
    print(json.dumps(metadata, indent=2))


if __name__ == "__main__":
    main()
