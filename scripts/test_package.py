"""Check documentation links in the actual distributable addon archive."""

import posixpath
from pathlib import Path
import re
import subprocess
import sys
from urllib.parse import unquote, urlsplit
from zipfile import ZipFile

ROOT = Path(__file__).resolve().parents[1]


def run():
    result = subprocess.run(
        [sys.executable, str(ROOT / "scripts/package.py")],
        capture_output=True,
        text=True,
        check=True,
        cwd=ROOT,
    )
    archive = Path(result.stdout.strip())
    revision = subprocess.check_output(
        ["git", "rev-parse", "HEAD"], cwd=ROOT, text=True
    ).strip()
    sample_url = (
        "https://github.com/PostHog/posthog-godot/blob/"
        + revision
        + "/examples/mobile_smoke/README.md"
    )
    with ZipFile(archive) as package:
        names = set(package.namelist())
        for name in sorted(names):
            if not name.endswith(".md"):
                continue
            text = package.read(name).decode("utf-8")
            for link in re.findall(r"\]\(([^\s)]+)\)", text):
                url = urlsplit(link)
                if url.scheme or url.netloc or not url.path:
                    continue
                target = posixpath.normpath(
                    posixpath.join(posixpath.dirname(name), unquote(url.path))
                )
                assert target in names, f"Broken packaged link: {name} -> {link}"
        for name in ("README.md", "CONTRIBUTING.md", "docs/unity-parity.md"):
            text = package.read("addons/posthog/" + name).decode("utf-8")
            assert sample_url in text, f"Sample link is not commit-pinned: {name}"
        assert "[LICENSE](LICENSE)" in package.read("addons/posthog/README.md").decode()
        assert not any("/examples/" in name for name in names)
    print("Packaged documentation links resolve locally or to commit-pinned examples")


if __name__ == "__main__":
    run()
