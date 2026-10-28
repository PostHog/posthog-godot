#!/usr/bin/env python3
"""Build an installable addon archive without shipping project/editor state."""

from configparser import ConfigParser
import json
from pathlib import Path, PurePosixPath
import posixpath
import re
import subprocess
from urllib.parse import quote, unquote, urlsplit
from zipfile import ZIP_DEFLATED, ZipFile

ROOT = Path(__file__).resolve().parents[1]
ADDON = ROOT / "addons" / "posthog"


def package_markdown(source, destination, files, revision):
    def rewrite(match):
        url = urlsplit(match[2])
        if url.scheme or url.netloc or not url.path:
            return match[0]
        target = (source.parent / unquote(url.path)).resolve()
        relative = target.relative_to(ROOT).as_posix()
        if not target.exists():
            raise ValueError(f"Broken documentation link: {source} -> {match[2]}")
        if target in files:
            address = quote(
                posixpath.relpath(
                    files[target].as_posix(), destination.parent.as_posix()
                )
            )
        else:
            kind = "tree" if target.is_dir() else "blob"
            address = f"https://github.com/PostHog/posthog-godot/{kind}/{revision}/{quote(relative)}"
        if url.query:
            address += "?" + url.query
        if url.fragment:
            address += "#" + url.fragment
        return match[1] + address + match[3]

    return re.sub(
        r"(!?\[[^\]]*\]\()([^\s)]+)(\))", rewrite, source.read_text(encoding="utf-8")
    )


def get_version():
    plugin = ConfigParser()
    plugin.read(ADDON / "plugin.cfg")
    version = plugin["plugin"]["version"].strip('"')
    assert re.fullmatch(r"\d+\.\d+\.\d+(?:-[\w.-]+)?", version), (
        "Invalid plugin version"
    )
    assert f'const VERSION = "{version}"' in (ADDON / "internal/utils.gd").read_text()
    assert f'config/version="{version}"' in (ROOT / "project.godot").read_text()
    assert json.loads((ROOT / "package.json").read_text())["version"] == version
    return version


def main():
    version = get_version()
    destination = ROOT / "dist" / f"posthog-godot-{version}.zip"
    destination.parent.mkdir(exist_ok=True)
    files = {
        path: PurePosixPath(path.relative_to(ROOT).as_posix())
        for path in sorted(ADDON.rglob("*"))
        if path.is_file() and path.suffix in {".gd", ".uid", ".cfg"}
    }
    for name in [
        "README.md",
        "LICENSE",
        "CHANGELOG.md",
        "CONTRIBUTING.md",
        "RELEASING.md",
    ]:
        files[ROOT / name] = PurePosixPath("addons/posthog") / name
    for path in sorted((ROOT / "docs").glob("*.md")):
        files[path] = PurePosixPath("addons/posthog/docs") / path.name
    revision = subprocess.check_output(
        ["git", "rev-parse", "HEAD"], cwd=ROOT, text=True
    ).strip()
    with ZipFile(destination, "w", ZIP_DEFLATED) as archive:
        for source, target in files.items():
            if source.suffix == ".md":
                archive.writestr(
                    target.as_posix(), package_markdown(source, target, files, revision)
                )
            else:
                archive.write(source, target.as_posix())
    print(destination)


if __name__ == "__main__":
    main()
