# Tagged releases and Asset Library distribution

The SDK is experimental. The release workflow publishes **prereleases**, never marks them as the latest stable release, and does not submit anything to the Asset Library.

## Prepare and validate

1. Update these version declarations together:
   - `addons/posthog/plugin.cfg`: `version`
   - `addons/posthog/internal/utils.gd`: `VERSION`
   - `project.godot`: `config/version`
2. Update `CHANGELOG.md` and review the README's experimental warning and platform limitations. Do not claim physical-device or downstream ingestion coverage based only on HTTP acknowledgements.
3. Run the checks in [CONTRIBUTING](../CONTRIBUTING.md), including `python3 scripts/test_release.py`.
4. Commit the changes and push to the canonical `PostHog/posthog-godot` repository. Wait for CI to pass.
5. Before the first publication, configure a repository tag ruleset preventing updates/deletion of `v*` tags and enable GitHub release immutability. Do not move or reuse a version tag.

To preview checksums and the submission worksheet locally, without creating a tag or publishing:

```sh
python3 scripts/package.py
python3 scripts/release.py v0.1.0
```

Use the version declared by the checkout. Generate final assets from a clean, committed checkout; local previews can reference commits or release URLs that are not public yet.

For an end-to-end **non-publishing** rehearsal after the workflow is on the default branch:

```sh
gh workflow run release.yml --ref main -f tag=v0.1.0
```

Manual runs validate the requested version, run the complete desktop/Web CI suite, and produce a `release-assets` workflow artifact. They never create a tag or GitHub release. The tag need not exist for a dry run.

## Publish a tagged prerelease

Only do this after confirming the version and experimental release status with the release owner:

```sh
tag=v0.1.0
git status --short
git tag -s "$tag" -m "PostHog Godot $tag (Experimental)"
git push origin "$tag"
```

Start from the clean, pushed commit that passed CI. Use the configured signing mechanism; stop if signing authorization fails rather than disabling it.

A `v*` tag push triggers `.github/workflows/release.yml`. The workflow:

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

References: [submission requirements](https://docs.godotengine.org/en/stable/community/asset_library/submitting_to_assetlib.html), [Custom provider implementation](https://github.com/godotengine/godot-asset-library/blob/master/src/Helpers/Utils.php), [icon source and regeneration](assets/README.md).
