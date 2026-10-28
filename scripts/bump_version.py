#!/usr/bin/env python3
"""Copy the pnpm release version to the Godot version declarations."""

import json
from pathlib import Path
import re

import package

ROOT = Path(__file__).resolve().parents[1]


def bump_version(root=ROOT):
    version = json.loads((root / "package.json").read_text())["version"]
    if not re.fullmatch(r"\d+\.\d+\.\d+(?:-[\w.-]+)?", version):
        raise ValueError(f"Invalid release version: {version!r}")
    declarations = {
        "addons/posthog/plugin.cfg": r'^version="[^"\n]+"$',
        "addons/posthog/internal/utils.gd": r'^const VERSION = "[^"\n]+"$',
        "project.godot": r'^config/version="[^"\n]+"$',
    }
    updates = {}
    for name, pattern in declarations.items():
        path = root / name
        original = path.read_text(encoding="utf-8")
        matches = re.findall(pattern, original, flags=re.MULTILINE)
        if len(matches) != 1:
            raise ValueError(f"Expected one version declaration in {name}")
        replacement = re.sub(r'"[^"]+"', f'"{version}"', matches[0])
        updates[path] = original.replace(matches[0], replacement)
    for path, content in updates.items():
        path.write_text(content, encoding="utf-8")
    return version


if __name__ == "__main__":
    version = bump_version()
    assert package.get_version() == version
    print(version)
