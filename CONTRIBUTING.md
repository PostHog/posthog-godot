# Contributing

## Requirements

- Godot 4.5+ (standard build; .NET is not needed)
- Python 3.10+
- Optional `uv` for isolated lint/format tools

## Run the tests

```sh
python3 scripts/test.py
# Or:
GODOT=/path/to/godot python3 scripts/test.py
```

The runner imports the project, starts a Python HTTP server bound only to loopback on an ephemeral port, and executes the headless GDScript tests. It never contacts PostHog or uses a real API key. Tests cover analytics enrichment, UUIDs, identity, consent, sessions, persistence, flag parsing/payloads/metadata, cancellation races, retries, queue overflow, error capture, lifecycle, and actual HTTP request serialization. A nonzero exit indicates a failure, script error, timeout, or resource leak.

Two `ERROR: Expected ...` log messages are intentional: they exercise the actual Godot Logger integration. The final test summary and HTTP assertions must pass. Temporary test state lives under a unique `user://posthog-tests-*` path and is removed on success. Interrupted runs may leave those directories behind.

```sh
uvx --from gdtoolkit==4.5.0 gdformat --check addons tests examples
uvx --from gdtoolkit==4.5.0 gdlint addons tests examples
uvx --from ruff==0.12.11 ruff check scripts
uvx --from ruff==0.12.11 ruff format --check scripts
```

Remove `--check` from formatter commands to apply formatting. Keep `.gd.uid` files in version control; do not commit `.godot/`.

## Layout

- `addons/posthog/posthog.gd`: public autoload API, lifecycle, identity, enrichment
- `addons/posthog/posthog_config.gd`: Inspector/runtime configuration
- `addons/posthog/posthog_feature_flag.gd`: flag value/payload wrapper
- `addons/posthog/internal/`: queue, transport, storage, sessions, flags, error logger, utilities
- `examples/`: safe-by-default interactive example
- `tests/`: dependency-free Godot tests and deterministic transport fixture
- `scripts/`: headless test runner and addon packaging

Internal classes are not a supported public API. Test fixtures access them intentionally to drive timing/failure paths without waiting for real timeouts.

## Build a distributable addon

```sh
python3 scripts/package.py
```

This creates `dist/posthog-godot-0.1.0.zip`, containing only `addons/posthog/**` plus license/readme/configuration/parity documents under the addon directory. It excludes the sample project's autoload settings, tests, editor cache, and credentials. Extracting it at another project's root must not replace that project's `project.godot`.

Version changes must update `Utils.VERSION` in `internal/utils.gd`, `plugin.cfg`, the example project's `project.godot`, and `CHANGELOG.md`. Packaging checks that all three version declarations agree. CI uploads the ZIP as a build artifact; it does not publish a release or Godot Asset Library listing automatically.

See [Unity parity](docs/unity-parity.md) for current platform gaps and release validation still required.
