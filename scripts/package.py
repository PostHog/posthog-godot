#!/usr/bin/env python3
"""Build an installable addon archive without shipping project/editor state."""

from configparser import ConfigParser
from pathlib import Path
import re
from zipfile import ZIP_DEFLATED, ZipFile

ROOT = Path(__file__).resolve().parents[1]
ADDON = ROOT / "addons" / "posthog"


def main():
    plugin = ConfigParser()
    plugin.read(ADDON / "plugin.cfg")
    version = plugin["plugin"]["version"].strip('"')
    assert re.fullmatch(r"\d+\.\d+\.\d+(?:-[\w.-]+)?", version), (
        "Invalid plugin version"
    )
    assert f'const VERSION = "{version}"' in (ADDON / "internal/utils.gd").read_text()
    assert f'config/version="{version}"' in (ROOT / "project.godot").read_text()
    destination = ROOT / "dist" / f"posthog-godot-{version}.zip"
    destination.parent.mkdir(exist_ok=True)
    with ZipFile(destination, "w", ZIP_DEFLATED) as archive:
        for path in sorted(ADDON.rglob("*")):
            if path.is_file() and path.suffix in {".gd", ".uid", ".cfg"}:
                archive.write(path, path.relative_to(ROOT))
        for name in ["README.md", "LICENSE", "CHANGELOG.md", "CONTRIBUTING.md"]:
            archive.write(ROOT / name, f"addons/posthog/{name}")
        for path in sorted((ROOT / "docs").glob("*.md")):
            archive.write(path, f"addons/posthog/docs/{path.name}")
    print(destination)


if __name__ == "__main__":
    main()
