# Tagged releases and Asset Library distribution

The SDK is experimental. The release workflow publishes **prereleases**, never marks them as the latest stable release, and does not submit anything to the Asset Library.

Tags exactly match the SDK version, **without a `v` prefix**: use `0.1.0` or `0.2.0-rc.1`, not `v0.1.0`. Release titles and download URLs use the same unprefixed tag.

## How it works

| Trigger | Result |
| --- | --- |
| Push a branch or open a pull request | Run CI; no release is published. |
| Manually run the Release workflow | Validate, test, and prepare downloadable artifacts; publication is always skipped. |
| Push a matching unprefixed version tag to the canonical repository | Validate, test, prepare artifacts, then publish an experimental prerelease. |
| Submit or update an Asset Library listing | Separate manual action by a registered maintainer, followed by moderation. |

The job sequence is `validate` → `verify` → `prepare` → `publish`. `verify` calls the existing [CI workflow](.github/workflows/ci.yml), so release checks cannot silently diverge from normal CI. The [Release workflow](.github/workflows/release.yml) publishes the ZIP produced by that verified run.

These instructions are for SDK maintainers, not application developers. Run commands from the SDK repository root. You need Git with signing configured, Python, and an authenticated GitHub CLI account with repository push/workflow access. Check authentication with `gh auth status`; see [CONTRIBUTING](CONTRIBUTING.md) for local validation tools.

## Prepare and validate

1. Update these version declarations together:
   - `addons/posthog/plugin.cfg`: `version`
   - `addons/posthog/internal/utils.gd`: `VERSION`
   - `project.godot`: `config/version`
2. Update `CHANGELOG.md` and review the README's experimental warning and platform limitations. Do not claim physical-device or downstream ingestion coverage based only on HTTP acknowledgements.
3. Run the checks in [CONTRIBUTING](CONTRIBUTING.md), including `python3 scripts/test_release.py`.
4. Commit the changes and push to the canonical `PostHog/posthog-godot` repository. Wait for CI to pass.
5. Before the first publication, configure a repository tag ruleset preventing updates/deletion of `[0-9]*.[0-9]*.[0-9]*` tags and enable GitHub release immutability. Do not move or reuse a version tag.

To preview checksums and the submission worksheet locally, without creating a tag or publishing:

```sh
python3 scripts/package.py
python3 scripts/release.py 0.1.0
```

Use the version declared by the checkout. Generate final assets from a clean, committed checkout; local previews can reference commits or release URLs that are not public yet.

For an end-to-end **non-publishing** rehearsal after the workflow is on the default branch:

```sh
gh workflow run release.yml --ref main -f tag=0.1.0
```

Manual runs validate the requested version, run the complete desktop/Web CI suite, and produce a `release-assets` workflow artifact. They never create a tag or GitHub release. The tag need not exist for a dry run.

### Monitor and inspect a rehearsal

Find the run ID in the URL printed by the dispatch command, or list runs:

```sh
gh run list --workflow release.yml --event workflow_dispatch --branch main
```

Replace `RUN_ID` below with that ID:

```sh
gh run watch RUN_ID --exit-status
gh run download RUN_ID --name release-assets --dir dist/release-rehearsal/RUN_ID
```

A successful rehearsal has green `validate`, `verify`, and `prepare` jobs, and a **skipped** `publish` job. The downloaded artifact contains:

- `posthog-godot-<version>.zip`: installable addon, documentation, and license.
- `asset-library.json`: a submission worksheet, including source commit and versioned download/icon URLs.
- `SHA256SUMS`: checksums for the ZIP and worksheet.

Run `sha256sum --check SHA256SUMS` inside the downloaded directory (macOS: `shasum -a 256 --check SHA256SUMS`). A rehearsal does not make its future release URL available; do not submit its worksheet to the Asset Library yet.

## Publish a tagged prerelease

Only do this after confirming the version and experimental release status with the release owner:

```sh
tag=0.1.0
git status --short
git tag -s "$tag" -m "PostHog Godot $tag (Experimental)"
git push origin "$tag"
```

Start from the clean, pushed commit that passed CI. Use the configured signing mechanism; stop if signing authorization fails rather than disabling it.

A tag push matching `[0-9]*.[0-9]*.[0-9]*` triggers `.github/workflows/release.yml`. The filter accepts numeric version tags, including prerelease suffixes; validation then requires an exact match with the SDK version. The workflow:

1. Requires the tag to match all SDK version declarations.
2. Runs the reusable CI workflow: formatting/linting, unit/HTTP/editor/packaging tests, Windows/macOS/Linux release exports, and Chromium Web tests.
3. Downloads the tested addon ZIP instead of rebuilding it during publication.
4. Validates its documentation links against the source commit and generates `SHA256SUMS` plus `asset-library.json`.
5. Verifies the checksums and that the remote tag still points to that source commit.
6. Publishes an experimental GitHub prerelease with the ZIP, checksums, submission worksheet, and generated release notes.

Only the final publication job has `contents: write`; other jobs have read-only repository access. Publication is limited to tag pushes in the canonical repository. No PostHog API key or personal access token is needed.

Download the published files and verify `sha256sum --check SHA256SUMS` (macOS: `shasum -a 256 --check SHA256SUMS`). Install the ZIP into a fresh Godot 4.5 project, enable the plugin, create/select a config resource, and reopen the editor. Check the installed documentation links as well.

If publication fails, inspect the run and any draft release before retrying. Do not replace a published release, overwrite its assets, or move the tag to work around a failed run. Ship a new version for fixes to a published release.

## Submit to the Godot Asset Library

Submission requires a registered maintainer account and manual review. There is no automated submission or stored Asset Library credential in this repository.

Use the published `asset-library.json` as a **form-fill worksheet**, not an API request body. It includes:

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

**Use Custom, not GitHub, as the download provider.** The Asset Library's GitHub provider computes a full repository source ZIP. The Custom provider accepts a direct GitHub release ZIP URL in the Download Commit field, so users get the tested addon-only package, with its README, license, and repaired documentation links. The worksheet's separate `source_commit` field is provenance information, not the Custom download field.

Before submitting:

- Confirm the prerelease and all worksheet URLs are publicly reachable.
- Verify the ZIP contains only `addons/posthog/`, including the license and README, with no application project, credentials, generated exports, or editor state.
- Confirm the PNG is square and at least 128×128; the committed icon is 256×256.
- Test installation from the released ZIP, not just the source checkout.
- Keep the experimental warning and Godot 4.5 minimum in the listing.
- Submit at https://godotengine.org/asset-library/asset and record the approved listing URL in the README only after approval.

For updates, edit the existing listing with the new worksheet. Each update is reviewed again; do not create a duplicate listing for each SDK version. Test installation through the editor's AssetLib tab after approval.

## Future stable releases

Stable publication is deliberately not supported by the current workflow. Before the first stable release, make a separately reviewed change to the experimental warnings and publication policy, including the `--prerelease` and `--latest=false` flags. Do not bypass the policy by manually relabeling an experimental release.

References: [submission requirements](https://docs.godotengine.org/en/stable/community/asset_library/submitting_to_assetlib.html), [Custom provider implementation](https://github.com/godotengine/godot-asset-library/blob/master/src/Helpers/Utils.php), [icon source and regeneration](docs/assets/README.md).
