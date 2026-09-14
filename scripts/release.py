#!/usr/bin/env python3
"""Validate a version tag and prepare release assets locally; never publish."""

import argparse
import hashlib
import json
from pathlib import Path
import subprocess

import package
import test_package

ROOT = Path(__file__).resolve().parents[1]
REPOSITORY = "https://github.com/PostHog/posthog-godot"


def validate_tag(tag):
    version = package.get_version()
    if tag != f"v{version}":
        raise ValueError(f"Tag {tag!r} must match the package version: v{version}")
    return version


def prepare_release(tag, directory):
    version = validate_tag(tag)
    revision = subprocess.check_output(
        ["git", "rev-parse", "HEAD"], cwd=ROOT, text=True
    ).strip()
    archive = directory / f"posthog-godot-{version}.zip"
    test_package.validate(archive, revision)
    metadata = {
        "asset_name": "PostHog SDK (Experimental)",
        "category": "Tools (Addons)",
        "godot_version": "4.5",
        "version": version,
        "repository_host": "Custom",
        "repository_url": REPOSITORY,
        "issues_url": REPOSITORY + "/issues",
        "download_commit": f"{REPOSITORY}/releases/download/{tag}/{archive.name}",
        "source_commit": revision,
        "icon_url": (
            "https://raw.githubusercontent.com/PostHog/posthog-godot/"
            + revision
            + "/docs/assets/icon.png"
        ),
        "license": "MIT",
        "description": (ROOT / "docs/asset-library-description.txt")
        .read_text(encoding="utf-8")
        .strip(),
    }
    worksheet = directory / "asset-library.json"
    worksheet.write_text(json.dumps(metadata, indent=2) + "\n", encoding="utf-8")
    checksums = "".join(
        f"{hashlib.sha256(path.read_bytes()).hexdigest()}  {path.name}\n"
        for path in (archive, worksheet)
    )
    (directory / "SHA256SUMS").write_text(checksums, encoding="utf-8")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("tag", help="Version tag, e.g. v0.1.0")
    parser.add_argument(
        "--check", action="store_true", help="Only validate the tag/version"
    )
    parser.add_argument("--directory", type=Path, default=ROOT / "dist")
    args = parser.parse_args()
    validate_tag(args.tag)
    if not args.check:
        prepare_release(args.tag, args.directory)
        print(f"Prepared release assets in {args.directory}")


if __name__ == "__main__":
    main()
