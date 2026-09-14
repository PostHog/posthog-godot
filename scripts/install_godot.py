#!/usr/bin/env python3
"""Install matching, checksum-pinned Godot editors and export templates for SDK tests."""

import argparse
import hashlib
import os
from pathlib import Path
import shutil
import sys
from urllib.request import urlopen
from zipfile import ZipFile

VERSION = "4.5-stable"
BASE = "https://github.com/godotengine/godot/releases/download/"
EDITORS = {
    "linux": (
        "linux.x86_64.zip",
        "Godot_v4.5-stable_linux.x86_64",
        "c7316e1fd782ad276a4d985a7673b5976eaaa8d90561a2bea5289210dc53e9ba",
    ),
    "darwin": (
        "macos.universal.zip",
        "Godot.app/Contents/MacOS/Godot",
        "abb7cabe99fead0bd63ce03bd8c611734b2941f9b90051e8e3b5c6691527954d",
    ),
    "win32": (
        "win64.exe.zip",
        "Godot_v4.5-stable_win64_console.exe",
        "303206071cb8be502cfa5b1e2b37b848c280347c03f78dcc2eb8a630857f7d10",
    ),
}
TEMPLATE_SHA = "375d83b661794f91746d2dec9b569a99d4d24f85a70c4ec0068aafb18b551d53"

RELEASES = {
    VERSION: (EDITORS, TEMPLATE_SHA),
    "4.5.1-stable": (
        {
            "linux": (
                "linux.x86_64.zip",
                "Godot_v4.5.1-stable_linux.x86_64",
                "02ec53d1cc7dbb9cc6355393c61b9ab43d1244751a124f10248a4802830788cd",
            ),
            "darwin": (
                "macos.universal.zip",
                "Godot.app/Contents/MacOS/Godot",
                "65c27959d02aaacfc131ec7ecb90179ba8045200cb02982bf2be96d117010b8a",
            ),
            "win32": (
                "win64.exe.zip",
                "Godot_v4.5.1-stable_win64_console.exe",
                "defccc78669e644861b4247626b01ae362cd9f23975edf19c8bfd2eb1f6a1783",
            ),
        },
        "1998af37f1387684e2c211cdb483daf492fc64dc6b12096bddcdca25b6910c86",
    ),
}


def validate_editor_version(output, expected):
    if expected not in RELEASES or not output.startswith(
        expected.replace("-stable", ".stable.")
    ):
        raise SystemExit(
            f"Export tests require the pinned {expected} editor and matching templates"
        )


def verified_archive(path, name, expected, version=VERSION):
    if not path.exists():
        temporary = path.with_suffix(".part")
        with (
            urlopen(BASE + version + "/" + name, timeout=120) as response,
            temporary.open("wb") as output,
        ):
            shutil.copyfileobj(response, output)
        temporary.replace(path)
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    if digest.hexdigest() != expected:
        raise SystemExit(f"Checksum mismatch: {path}; remove it before retrying")
    return ZipFile(path)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", choices=RELEASES, default=VERSION)
    parser.add_argument("--templates", action="store_true")
    parser.add_argument("--mobile-templates", action="store_true")
    parser.add_argument("--directory", type=Path, default=Path(".cache/godot"))
    args = parser.parse_args()
    directory = args.directory.resolve()
    directory.mkdir(parents=True, exist_ok=True)
    editors, template_sha = RELEASES[args.version]
    suffix, executable, sha = editors[sys.platform]
    name = f"Godot_v{args.version}_{suffix}"
    with verified_archive(directory / name, name, sha, args.version) as archive:
        archive.extractall(directory / "editor")
    godot = directory / "editor" / executable
    godot.chmod(0o755)
    values = {"GODOT": str(godot), "GODOT_VERSION": args.version}
    if args.templates or args.mobile_templates:
        name = f"Godot_v{args.version}_export_templates.tpz"
        source = Path(os.environ.get("GODOT_TEMPLATE_ARCHIVE", directory / name))
        with verified_archive(source, name, template_sha, args.version) as archive:
            names = set()
            if args.templates:
                names.add("templates/web_nothreads_release.zip")
                names.add(
                    {
                        "linux": "templates/linux_release.x86_64",
                        "darwin": "templates/macos.zip",
                        "win32": "templates/windows_release_x86_64.exe",
                    }[sys.platform]
                )
            if args.mobile_templates:
                names.update(
                    {
                        "templates/android_debug.apk",
                        "templates/android_release.apk",
                        "templates/ios.zip",
                    }
                )
            for member in names:
                archive.extract(member, directory)
        values["GODOT_TEMPLATES"] = str(directory / "templates")
    for key, value in values.items():
        print(f"{key}={value}")
    if os.environ.get("GITHUB_ENV"):
        with open(os.environ["GITHUB_ENV"], "a", encoding="utf-8") as output:
            for key, value in values.items():
                output.write(f"{key}={value}\n")


if __name__ == "__main__":
    main()
