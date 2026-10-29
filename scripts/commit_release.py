#!/usr/bin/env python3
"""Create a signed release commit using GitHub's expected-parent check."""

import base64
import json
import os
from pathlib import Path
import subprocess


def main():
    expected_tree = os.environ["EXPECTED_TREE_SHA"]
    tree = subprocess.check_output(["git", "write-tree"], text=True).strip()
    if tree != expected_tree:
        raise ValueError("Staged tree does not match the verified release candidate")
    subprocess.run(["git", "diff", "--exit-code"], check=True)
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
    message = f"chore: release {os.environ['NEW_VERSION']} [version bump]"
    remote = json.loads(
        subprocess.run(
            ["gh", "api", f"repos/{os.environ['GH_REPO']}/commits/main"],
            text=True,
            stdout=subprocess.PIPE,
            check=True,
        ).stdout
    )
    request = {
        "query": "mutation($input: CreateCommitOnBranchInput!) { createCommitOnBranch(input: $input) { commit { oid } } }",
        "variables": {
            "input": {
                "branch": {
                    "repositoryNameWithOwner": os.environ["GH_REPO"],
                    "branchName": "main",
                },
                "expectedHeadOid": source,
                "message": {"headline": message},
                "fileChanges": {"additions": additions, "deletions": deletions},
            }
        },
    }
    if remote["sha"] == source:
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
    elif (
        [parent["sha"] for parent in remote["parents"]] == [source]
        and remote["commit"]["tree"]["sha"] == expected_tree
        and remote["commit"]["message"] == message
        and remote["commit"]["verification"]["verified"]
    ):
        sha = remote["sha"]
    else:
        raise ValueError(
            "main moved since candidate preparation; prepare a new candidate"
        )
    with open(os.environ["GITHUB_OUTPUT"], "a") as output:
        output.write(f"sha={sha}\n")
    print(f"Created release commit {sha}")


if __name__ == "__main__":
    main()
