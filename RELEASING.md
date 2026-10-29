# Automated releases and Asset Library distribution

The SDK is experimental. The release workflow publishes **prereleases**, never marks them as the latest stable release, and does not submit anything to the Asset Library.

Tags exactly match the SDK version, **without a `v` prefix**: use `0.1.3`, not `v0.1.3`.

## How it works

| Trigger | Result |
| --- | --- |
| Push a branch or open a pull request | Run CI; no release is published. |
| Merge a releasable `.changeset/*.md` intent into `main` | Prepare and verify an uncommitted version/changelog patch, then request approval to commit and publish it. |
| Manually run Release on `main` | Process any pending change intents through the same publishing pipeline; **not a dry run**. |
| Push a version tag | No release workflow; tags are created by the pipeline. |
| Submit or update an Asset Library listing | Separate manual action by a registered maintainer, followed by moderation. |

The [Release workflow](.github/workflows/release.yml) serializes releases. Queued runs check out the latest `main` and consume only still-pending change intents; runs with none skip publication. pnpm's ledger prevents already-consumed intents from being released again.

The job sequence is `prepare-candidate` → `verify` → `notify-approval-needed` → `publish`, following the PHP SDK's prepare, verify, approve, then commit/publish flow:

1. In a read-only job, pnpm 11.13.1 applies pending change intents locally, updates `package.json` and `CHANGELOG.md`, and records consumed intents in `.changeset/ledger.yaml`. `scripts/bump_version.py` synchronizes the three Godot declarations. The job uploads a patch and records its SHA-256 checksum, source commit, and resulting Git tree SHA. **No version commit or remote change is made.**
2. The reusable [CI workflow](.github/workflows/ci.yml) checks out the source commit and applies the exact patch in every desktop and Web job. `scripts/release_candidate.py` verifies the patch checksum, resulting tree, and versions. CI runs formatting/linting, unit/HTTP/editor/packaging tests, Windows/macOS/Linux exports, and Chromium Web tests. macOS uses Godot 4.5.1; other platforms retain the 4.5 baseline.
3. Slack receives an approval request. Review the candidate patch, workflow summary, and CI results, then approve the **single `Release` deployment** in GitHub.
4. Only after approval does `publish` obtain the environment-protected App key. It reapplies the verified patch and creates a GitHub-signed version commit on `main`. The expected-parent check rejects concurrent changes to `main`. A retry can reuse an already-created signed commit only when its parent, tree, and release message match this candidate exactly.
5. The same approved job checks out the signed commit and requires its Git tree to match the tested candidate. It then builds and validates the final addon ZIP and generates `SHA256SUMS` and `asset-library.json`. Packaging happens after the commit so repository documentation links, the icon URL, and source metadata contain the **final commit SHA**, not the candidate's parent. No source changes are made after verification.
6. The job verifies checksums, version, and source SHA, creates the unprefixed tag at that commit, and publishes the experimental prerelease. An existing tag is accepted only if it resolves to the same commit. Release creation does not overwrite an existing release.

No other job has the App credentials, and there is no second environment or approval. The Slack approval thread receives messages and reactions for approval (✅), successful publication (🚀), failure/cancellation (❌), or rejection (🚫). Rejected approvals do not send a PostHog failure event; workflow failures still do.

## One-time repository setup

Configure these before enabling releases:

- Create a **`Release` environment** with required reviewers and a selected deployment branch policy allowing only the `main` branch, not tags. Both controls matter: reviewers enforce approval, and the branch policy prevents modified branch workflows from accessing the key. Do not rely on the workflow's editable `if:` condition alone.
- Install a dedicated releaser GitHub App on `PostHog/posthog-godot` with **Contents: write**. Store its client ID as `GH_APP_POSTHOG_GODOT_RELEASER_APP_ID` and private key as `GH_APP_POSTHOG_GODOT_RELEASER_PRIVATE_KEY` as **environment secrets only in `Release`**. Do not make these credentials available as repository or organization secrets. Remove any such copies: adding environment secrets does not prevent a branch workflow from reading a repository/organization copy. App tokens are short-lived; no personal access token is needed.
- Allow that App to bypass the `main` rules requiring a pull request and status checks for its automated version commit. Keep the signed-commit requirement: the GitHub commit API signs the App's commits. The current repository rules otherwise reject the version commit.
- Provide `SLACK_CLIENT_LIBRARIES_BOT_TOKEN` and `POSTHOG_PROJECT_API_KEY` as repository/organization secrets, and `SLACK_APPROVALS_CLIENT_LIBRARIES_CHANNEL_ID` and `GROUP_CLIENT_LIBRARIES_SLACK_GROUP_ID` as repository/organization variables, matching the PHP SDK pipeline. The Slack bot needs `chat:write` and `reactions:write` scopes.
- Configure a tag ruleset preventing updates/deletion of `[0-9]*.[0-9]*.[0-9]*` tags and enable GitHub release immutability. Allow the releaser App to create tags, but never move or reuse one.

The workflow's default token has read-only repository access. Preparation and verification cannot commit or publish. Only the approved `publish` job obtains a scoped App token. Configure the `Release` environment, its protection rules, and its secrets before running the workflow; the YAML does not create those rules.

## Ship a change

Do **not** edit versions or the changelog manually. Add a change intent in the feature/fix PR:

```markdown
---
'posthog-godot': patch
---

Describe the user-visible change.
```

Use `patch`, `minor`, or `major`; pnpm combines pending intents and applies the highest required bump. With the pinned pnpm installed, `pnpm change posthog-godot --bump patch --summary "Describe the change"` can generate the file. pnpm removes consumed intent files and records their entries in the ledger.

Run the checks in [CONTRIBUTING](CONTRIBUTING.md), including `python3 -m unittest discover -s scripts -p 'test_release*.py'`, then merge the PR. Follow the Release run and Slack approval thread. Before approving, review the candidate patch, proposed version/changelog, CI results, and experimental/platform limitations. The candidate CI ZIP is a preview; final assets are packaged from the matching signed commit after approval. Do not claim physical-device or downstream ingestion coverage based only on HTTP acknowledgements.

To process pending intents without a new push:

```sh
gh workflow run release.yml --ref main
```

There is no publishing dry-run dispatch. To preview assets locally without committing a bump, creating a tag, or publishing:

```sh
python3 scripts/package.py
version=$(python3 -c 'import json; print(json.load(open("package.json"))["version"])')
python3 scripts/release.py "$version"
```

Generate final assets from a clean, committed checkout. Local previews may reference commits or URLs that are not public yet.

## Inspect assets and recover failures

```sh
gh run list --workflow release.yml --branch main
gh run watch RUN_ID --exit-status
gh run download RUN_ID --name release-assets --dir dist/release-review/RUN_ID
```

Before approval, download `release-candidate-SOURCE_SHA` to inspect `release.patch`; the workflow summary gives its checksum and resulting tree SHA. CI's `posthog-godot` artifact is a candidate ZIP, whose documentation still points at the source commit. Do not distribute it as the final release.

After approval, `release-assets` contains `posthog-godot-<version>.zip`, `asset-library.json`, and `SHA256SUMS`. Check them with `sha256sum --check SHA256SUMS` inside the downloaded directory (macOS: `shasum -a 256 --check SHA256SUMS`). Its release download URL is unavailable until publication.

A failed candidate check or rejected approval leaves `main`, versions, and remote intents unchanged. If `main` moves before committing the approved patch, the workflow fails safely. Dispatch a fresh run on `main` to prepare and verify a new candidate before approving again.

If publication fails **after the version commit**, fix the underlying infrastructure issue and **re-run failed jobs in the original run**, preserving the verified patch and metadata. The job recognizes and reuses its already-created signed commit if it is still the tip of `main` and its parent, tree, and message match. It does not create another version commit. A fresh dispatch sees consumed intents and will not republish that version. If `main` has advanced again or a code fix is needed, release a new version rather than overwriting history.

Inspect any existing tag/release before retrying publication. Never replace a published release, overwrite its assets, move a tag, or disable signing to work around a failure. Candidate patches are retained for five days. If an artifact expires before any commit, dispatch a fresh candidate; if the version commit already exists, ship a new version rather than synthesizing an unverified patch.

After publication, download and verify the release files. Install the ZIP into a fresh Godot 4.5+ project (4.5.1+ on macOS), enable the plugin, create/select a config resource, and reopen the editor. Check the installed documentation links too.

## Submit to the Godot Asset Library

Submission requires a registered maintainer account and manual review. There is no automated submission or stored Asset Library credential in this repository.

Use the published `asset-library.json` as a **form-fill worksheet**, not an API request body:

| Form field | Value |
| --- | --- |
| Asset Name | PostHog SDK (Experimental) |
| Category | Tools (Addons) |
| Godot version | 4.5 |
| Version | Released SDK version |
| Repository host | **Custom** |
| Repository URL | `https://github.com/PostHog/posthog-godot` |
| Issues URL | `https://github.com/PostHog/posthog-godot/issues` |
| Download Commit / download URL | The versioned `posthog-godot-<version>.zip` release asset URL from the worksheet |
| Icon URL | The commit-pinned `raw.githubusercontent.com` PNG URL from the worksheet |
| License | MIT |
| Description | The worksheet's plain-text description |

**Use Custom, not GitHub, as the download provider.** The GitHub provider downloads the full repository source ZIP. Custom accepts the tested addon-only ZIP URL in the Download Commit field. The worksheet's `source_commit` field is provenance information, not the Custom download field.

Before submitting:

- Confirm the prerelease and all worksheet URLs are publicly reachable.
- Verify the ZIP contains only `addons/posthog/`, including license and README, without application projects, credentials, exports, or editor state.
- Confirm the PNG is square and at least 128×128; the committed icon is 256×256.
- Test installation from the released ZIP, not the source checkout.
- Keep the experimental warning and Godot 4.5 minimum in the listing.
- Submit at https://godotengine.org/asset-library/asset and record the approved listing URL in the README only after approval.

For updates, edit the existing listing with the new worksheet. Each update is reviewed again; do not create duplicate listings. Test installation through the editor's AssetLib tab after approval.

## Future stable releases

Stable publication is deliberately unsupported. Before the first stable release, make a separately reviewed change to the experimental warnings and publication policy, including the `--prerelease` and `--latest=false` flags. Do not manually relabel an experimental release.

References: [submission requirements](https://docs.godotengine.org/en/stable/community/asset_library/submitting_to_assetlib.html), [Custom provider implementation](https://github.com/godotengine/godot-asset-library/blob/master/src/Helpers/Utils.php), [icon source and regeneration](docs/assets/README.md).
