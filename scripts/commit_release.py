#!/usr/bin/env python3
"""Create a signed release commit using GitHub's expected-parent check."""

import base64
import json
import os
from pathlib import Path
import subprocess


def main():
    paths = (
        subprocess.check_output(["git", "diff", "--cached", "--name-only", "-z"])
        .decode()
        .split("\0")
    )
    allowed = {
        "CHANGELOG.md",
        "package.json",
        ".changeset/ledger.yaml",
        "addons/posthog/plugin.cfg",
        "addons/posthog/internal/utils.gd",
        "project.godot",
    }
    additions, deletions = [], []
    for path in filter(None, paths):
        file = Path(path)
        consumed_intent = (
            file.parent == Path(".changeset")
            and file.suffix == ".md"
            and not file.exists()
        )
        if path not in allowed and not consumed_intent:
            raise ValueError(f"Unexpected release change: {path}")
        if file.exists():
            additions.append(
                {"path": path, "contents": base64.b64encode(file.read_bytes()).decode()}
            )
        else:
            deletions.append({"path": path})
    source = subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip()
    request = {
        "query": "mutation($input: CreateCommitOnBranchInput!) { createCommitOnBranch(input: $input) { commit { oid } } }",
        "variables": {
            "input": {
                "branch": {
                    "repositoryNameWithOwner": os.environ["GH_REPO"],
                    "branchName": "main",
                },
                "expectedHeadOid": source,
                "message": {
                    "headline": f"chore: release {os.environ['NEW_VERSION']} [version bump]"
                },
                "fileChanges": {"additions": additions, "deletions": deletions},
            }
        },
    }
    result = subprocess.run(
        ["gh", "api", "graphql", "--input", "-"],
        input=json.dumps(request),
        text=True,
        stdout=subprocess.PIPE,
        check=True,
    )
    response = json.loads(result.stdout)
    if response.get("errors"):
        raise RuntimeError(response["errors"])
    sha = response["data"]["createCommitOnBranch"]["commit"]["oid"]
    with open(os.environ["GITHUB_OUTPUT"], "a") as output:
        output.write(f"sha={sha}\n")
    print(f"Created release commit {sha}")


if __name__ == "__main__":
    main()
