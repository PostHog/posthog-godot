# Contributing

## Requirements

- Godot 4.5+ (standard build; .NET is not needed)
- Python 3.10+
- Optional `uv` for isolated lint/format tools
- Node.js 22 and the pinned Godot 4.5 export templates for browser/export testing

## Run the tests

```sh
python3 scripts/test.py
# Or:
GODOT=/path/to/godot python3 scripts/test.py
```

The runner imports the project, starts a Python HTTP server bound only to loopback on an ephemeral port, and executes the headless GDScript tests plus an isolated quit/flush subprocess. It never contacts PostHog or uses a real API key. Tests cover analytics enrichment, UUIDs, identity, consent, sessions, persistence, flag parsing/payloads/metadata, cancellation races, retries, queue overflow, error capture, lifecycle, and actual HTTP request serialization. A nonzero exit indicates a failure, script error, timeout, or resource leak.

The `ERROR: Expected ...` log messages are intentional: they exercise the actual Godot Logger integration and feedback-loop protection. The final test summary and HTTP assertions must pass. Temporary test state lives under a unique `user://posthog-tests-*` path and is removed on success. Interrupted runs may leave those directories behind.

```sh
uvx --from gdtoolkit==4.5.0 gdformat --check addons tests examples
uvx --from gdtoolkit==4.5.0 gdlint addons tests examples
uvx --from ruff==0.12.11 ruff check scripts
uvx --from ruff==0.12.11 ruff format --check scripts
```

Remove `--check` from formatter commands to apply formatting. Keep `.gd.uid` files in version control; do not commit `.godot/`.

## Test real release exports

```sh
python3 scripts/install_godot.py --templates
python3 scripts/test_exports.py
python3 scripts/test_exports.py --target web
cd tests/web
npm ci --ignore-scripts
npx playwright install --with-deps --only-shell chromium
npm test
```

The installer verifies SHA-256 checksums and keeps the editor/templates in `.cache/godot`. Its template download is about 1.3 GB; subsequent runs reuse the archive. `GODOT_TEMPLATE_ARCHIVE` can point to an already downloaded official archive (still checksum-verified). Export tests use the cached editor by default, or `GODOT`/`GODOT_TEMPLATES` overrides. They require the pinned **4.5-stable** editor/templates, rather than an arbitrary installed Godot version. The installer also sets these variables automatically in GitHub Actions.

Desktop tests create isolated temporary projects using the actual addon and a resource-based autoload config, build release exports, execute the resulting application, and inspect events received by a loopback HTTP server. They test automatic initialization, environment metadata, delivery, and error frames with `always_track_call_stacks` both enabled and disabled. CI runs them on Windows x86_64, Linux x86_64, and macOS.

Browser tests run the exported WebAssembly game in Chromium, not an editor build or a mocked SDK. They cover cross-origin JSON requests and preflight, rejected CORS requests retaining events, identity/super-property/queue persistence, consent across reloads, and release-build error frames. Persistence checks wait for the real IndexedDB record before reloading; they do not assert durability on an abrupt browser kill. Servers bind only to `127.0.0.1` on ports **47835** and **47836**, and use only a test API key. Stop any conflicting server before running. Test commands live only in the test project, never in the distributable addon.

The Web exports are written to `dist/export-tests/web`; desktop artifacts go under `dist/export-tests/desktop`. Playwright reports and failure traces go under `tests/web/playwright-report` and `tests/web/test-results`. CI uploads browser reports. To diagnose a local browser-install issue, `PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH` can select an existing Chromium executable; CI uses Playwright's pinned headless shell. Node.js 22 is recommended for both installation and execution.

## Layout

- `addons/posthog/posthog.gd`: public autoload API, lifecycle, identity, enrichment
- `addons/posthog/posthog_config.gd`: Inspector/runtime configuration
- `addons/posthog/posthog_feature_flag.gd`: flag value/payload wrapper
- `addons/posthog/internal/`: queue, transport, storage, sessions, flags, error logger, utilities
- `examples/`: safe-by-default interactive example
- `tests/`: dependency-free Godot unit tests and deterministic transport fixture
- `tests/exports/`: release-export project fixture
- `tests/web/`: Playwright tests and loopback Web/API servers
- `scripts/`: headless test runner and addon packaging

Internal classes are not a supported public API. Test fixtures access them intentionally to drive timing/failure paths without waiting for real timeouts.

## Build a distributable addon

```sh
python3 scripts/package.py
```

This creates `dist/posthog-godot-0.1.0.zip`, containing only `addons/posthog/**` plus license/readme/configuration/parity documents under the addon directory. It excludes the sample project's autoload settings, tests, editor cache, and credentials. Extracting it at another project's root must not replace that project's `project.godot`.

Version changes must update `Utils.VERSION` in `internal/utils.gd`, `plugin.cfg`, the example project's `project.godot`, and `CHANGELOG.md`. Packaging checks that all three version declarations agree. CI uploads the ZIP as a build artifact; it does not publish a release or Godot Asset Library listing automatically.

See [Unity parity](docs/unity-parity.md) for current platform gaps and release validation still required.
