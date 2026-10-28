# PostHog Godot

> [!WARNING]
> This SDK is experimental and not yet production-ready. APIs and behavior may change without notice. Test thoroughly before using it in a production game.

A native **Godot 4.5+ GDScript addon** for PostHog, based on the [PostHog Unity SDK](https://github.com/PostHog/posthog-unity). No .NET, native libraries, or runtime dependencies required.

**Initial implementation (0.1.0).** Unit tests are verified locally with Godot 4.5 and 4.7.2, plus real macOS and Chromium Web release exports against local HTTP servers. CI includes Windows/macOS/Linux release-export checks and browser tests. Android emulator and iOS simulator release smoke tests also pass against US Cloud (iOS requires a custom ARM64 Godot simulator library). Physical devices, other browsers, and downstream ingestion/error grouping still need validation.

## Features

- Custom events, screen events, and persistent super properties
- Anonymous/identified users, aliases, person properties, and groups
- Sessions with 30-minute inactivity and 24-hour maximum durations
- Boolean/multivariate feature flags, JSON payloads, and experiment exposure events
- Cached flags, person/group evaluation overrides, and awaitable reloads
- Persistent bounded event queue, batching, retries, and payload splitting
- Persistent opt-in/out, person-profile controls, and `before_send` redaction
- Application installed/updated/opened/backgrounded events
- Manual error capture and automatic Godot/GDScript error capture
- Editor plugin, resource-based configuration, and graceful quit

**Session replay is intentionally excluded.**

A reusable [mobile smoke-test sample](examples/mobile_smoke/README.md) covers identity, persistence, consent, flags, and automatic errors without committing project keys.

## Install

For tagged builds, use the `posthog-godot-<version>.zip` addon asset from [GitHub Releases](https://github.com/PostHog/posthog-godot/releases), not the automatically generated source archives.

1. Copy `addons/posthog` into your project's `addons` directory (or extract an addon ZIP at your project root).
2. Enable **PostHog** in **Project → Project Settings → Plugins**. This adds the `PostHog` autoload.
3. Initialize it once, from your startup scene:

```gdscript
func _ready() -> void:
    var config := PostHogConfig.new()
    config.api_key = "phc_your_project_api_key"
    config.host = "https://us.i.posthog.com" # Use https://eu.i.posthog.com for EU.
    PostHog.setup(config)
    PostHog.capture("game_started", {"mode": "single_player"})
```

Use your **project API key**, never a personal API key. Initialization immediately captures lifecycle events and starts a flag request by default. For consent-first setup, set `config.opt_out_by_default = true` **before** calling `setup()`.

Alternatively, create a **PostHogConfig** resource in the Inspector, save it as a `.tres`, and set the advanced Project Setting **Posthog → Config** (`posthog/config`) to its path. In exports, the autoload initializes from it before your scenes run. By default, `skip_auto_init_on_editor_play = true` skips this automatic initialization in editor builds, including games run with the editor executable from the command line. No identity, storage, networking, or error logger is initialized in that case. Set the option to `false` in the resource to intentionally enable development tracking. Explicit `setup()` calls always remain available; do not combine manual and automatic initialization.

Without the editor plugin, add `res://addons/posthog/posthog.gd` as an autoload named `PostHog` yourself. Use one active client per storage namespace; the SDK does not coordinate concurrent processes writing the same storage directory.

Events include `$godot_environment`: `editor_play`, `export_debug`, `export_release`, or `dedicated_server` (`editor` when running in editor-tool context). Headless mode alone does not identify a dedicated server. This metadata is also included in default feature-flag evaluation properties. Disabling `capture_exceptions_in_editor` only affects automatic errors; use the auto-initialization safeguard to avoid other development telemetry, and use a separate test project when calling `setup()` explicitly.

## Analytics and identity

```gdscript
PostHog.capture("level_completed", {"level": 3, "score": 4200})
PostHog.screen("Shop", {"category": "weapons"})

PostHog.register("game_mode", "ranked") # Included in future events; persisted.
PostHog.unregister("game_mode")

await PostHog.identify("player-123", {"plan": "premium"}, {"first_version": "1.0"})
PostHog.alias("old-player-id")
PostHog.group("guild", "guild-123", {"name": "Hedgehogs", "members": 12})

# On logout: new anonymous identity/session, cleared groups, properties, and flags.
await PostHog.reset()
```

The first `identify()` links the anonymous identity with `$anon_distinct_id`. `$set` and `$set_once` properties are also used for immediate flag evaluation. Call `reset()` before switching accounts to avoid carrying account-specific group memberships forward. Previously queued events retain their original identity.

Properties must be JSON-compatible: dictionaries, arrays, strings/StringNames, finite numbers, booleans, and null. Convert `Vector2`, `Color`, Resources, Nodes, etc. yourself. Deeply nested/cyclic values are rejected. The SDK copies properties, so later mutations do not change queued events.

## Feature flags and experiments

```gdscript
# Connect before setup if you need the initial notification.
PostHog.feature_flags_loaded.connect(_on_flags_loaded)

var success := await PostHog.reload_feature_flags()
if success and PostHog.is_feature_enabled("new-game-mode"):
    enable_new_mode()

var flag := PostHog.get_feature_flag("shop-layout")
if flag.has_value:
    print(flag.value)                   # bool or variant String
    print(flag.is_enabled)
    print(flag.get_variant("control"))
    print(flag.get_payload({}))         # Parsed JSON value, or fallback

var payload = PostHog.get_feature_flag_payload("shop-layout", {})

PostHog.set_person_properties_for_flags({"level": 10})
PostHog.set_group_properties_for_flags("guild", {"members": 12})
PostHog.reset_person_properties_for_flags()
PostHog.reset_group_properties_for_flags("guild") # Omit group_type to clear all.
```

- Getters are synchronous and read the cache. Unknown flags have `value == null`; `is_feature_enabled(key, default_value)` uses the fallback only for unknown flags, not `false` flags.
- Accessing a known flag sends `$feature_flag_called`, once per key/value per successful reload or identity context. These events enable experiment tracking. Pass `false` as `get_feature_flag(key, send_event)` to suppress an individual exposure, or disable `send_feature_flag_event` globally.
- `feature_flags_loaded` fires after a valid server response or a usable disk cache. `feature_flags_request_finished(success)` also reports failures/cancellation. Subscribe before initialization for startup notifications.
- Concurrent reloads share a request. Identity, group, and evaluation-property changes cancel obsolete requests and clear cached flags so another user cannot see them. Failed reloads without a context change retain the previous cache.
- `identify()` and `reset()` await flag reloads when `preload_feature_flags` is enabled. Their boolean return reports the reload result; a failed reload does **not** undo the identity change. When preloading is disabled, call `await reload_feature_flags()` explicitly.
- Override setters reload by default, independently of preloading. Pass `false` for their final argument to batch changes, then reload once. Overrides affect evaluation only; they do not update server profiles.
- Numbers decoded from JSON payloads are Godot floats. There is no custom typed payload deserializer; use Godot's native JSON values.

## Consent and privacy

```gdscript
var config := PostHogConfig.new()
config.api_key = "phc_your_project_api_key"
config.opt_out_by_default = true
PostHog.setup(config)

PostHog.opt_in()  # After consent.
PostHog.opt_out() # Stop tracking and clear pending events/cached flags.
```

Opt-out is persisted and blocks events, flag requests, identity/group mutations, and automatic error capture. It cancels active requests, but cannot retract requests already received by the server. Existing identity and registered properties remain locally stored; `reset()` clears user context without changing consent. A stored explicit opt-in/out takes precedence over `opt_out_by_default` on later launches. Corrupt/unreadable state fails closed to opted-out.

`person_profiles` defaults to `PostHogConfig.PersonProfiles.IDENTIFIED_ONLY`. `ALWAYS` processes anonymous profiles too. `NEVER` marks every event with `$process_person_profile = false` and disables `identify()`/`alias()`; it is **not** an opt-out from analytics.

```gdscript
config.before_send = func(event: Dictionary):
    if event.event == "sensitive_event":
        return null
    event.properties.erase("email")
    return event
```

`before_send` sees fully enriched events, including lifecycle, exposure, and error events. It may redact/change them or return null to drop them. Invalid events are dropped, and the SDK keeps its generated UUID as the durable queue key. Do not call SDK control/identity methods from this callback; recursive captures are ignored. It does not intercept feature-flag request bodies: avoid sensitive evaluation properties, or disable `send_default_person_properties_for_flags` as appropriate.

Persistent state/events are **unencrypted JSON under `user://posthog/<project-and-host-hash>`**. No hardware/device identifier is collected. Set `persistence = false` for memory-only operation (including identity and consent; these then reset on restart).

## Error tracking

```gdscript
PostHog.capture_exception("Inventory save failed", {"slot": 2}, "SaveError", get_stack())
```

Manual errors default to `handled = true`; the optional final parameter overrides it. Frames from `get_stack()` are converted to PostHog's raw stacktrace schema. Automatic capture uses Godot 4.5's `Logger` API for script/engine/shader errors, including `push_error()`. Warnings and ordinary console messages are not captured. Automatic events are marked unhandled. Identical errors (same type, message, file, and line) are deduplicated for one second by default; unrelated errors are retained. Separate safety limits allow up to 5 automatic errors per frame and 20 per rolling 10-second window, with at most 20 pending errors. Setting `exception_debounce_interval_ms = 0` disables duplicate suppression, not these safety limits. Manual captures are not rate-limited.

Automatic errors use the backtrace whose newest frame matches the reported file/line, or the longest available backtrace when none matches. Engine errors retain their native origin alongside script frames, with at most 50 frames total. SDK-originated errors are excluded, but customer callback errors are not discarded merely because an SDK frame appears farther down the stack. Errors generated on the forwarding thread while processing an automatic error are suppressed to prevent feedback loops; unrelated worker-thread errors remain eligible.

Set `capture_exceptions = false` to disable automatic capture, or `capture_exceptions_in_editor = false` to disable it when running from editor builds. No local variables are collected. To retain GDScript stack frames in release exports, enable **Debug → Settings → GDScript → Always Track Call Stacks** (`debug/settings/gdscript/always_track_call_stacks`). Without it, automatic errors may contain only an engine source frame. Native crashes and errors before initialization are not captured.

## Delivery and shutdown

```gdscript
var delivered := await PostHog.flush()
PostHog.shutdown() # Queues pending errors and retains undelivered disk events; no network wait.

# Instead of get_tree().quit(), to attempt delivery before exiting:
PostHog.quit()
```

Events are persisted at capture time and sent to `/batch/` after 20 events or 30 seconds by default, in batches of 50. Up to 1,000 events are retained; overflow evicts the oldest. Delivery is at-least-once with stable UUIDs, not guaranteed exactly-once.

Network/server failures, HTTP 408, and HTTP 429 retain events with bounded exponential backoff; numeric `Retry-After` is honored. HTTP 413 splits batches and drops an individually oversized event. Other 4xx errors discard the rejected batch. `events_dropped(count, reason)` reports overflow/permanent HTTP drops. `flush()` returns false on failures, opt-out, or active backoff, and coalesces concurrent flushes. Redirects are not followed: configure the ingestion host directly. Requests set `User-Agent: posthog-godot/<sdk-version>`. Web exports are subject to browser restrictions and may send the browser User-Agent instead.

`flush()` first transfers pending automatic errors through the normal capture pipeline, including `before_send`. Normal shutdown stops the logger and queues its remaining errors before teardown, persisting them when persistence is enabled. `PostHog.quit()` does this before its final delivery attempt. Opt-out discards pending errors instead.

The addon processes networking even while the scene tree is paused. OS background notifications trigger a best-effort flush. Window close is intercepted for up to `flush_on_quit_timeout_seconds` (3 seconds) only if the game has not already disabled `SceneTree.auto_accept_quit`. `SceneTree.quit()` bypasses this interception; call `PostHog.quit()` or flush explicitly. Mobile force-kill and browser tab close cannot guarantee a final request. Persistent events are retried on a later launch.

**Call public APIs on the main thread.** Use `PostHog.call_deferred("capture", "event", properties)` from a worker. The internal automatic error logger separately handles engine callbacks from worker threads.

## Configuration, platform notes, and development

**Android:** enable the Internet permission (`permissions/internet=true`) in your Android export preset so analytics and feature flag requests can reach PostHog.

- [All configuration options](docs/configuration.md)
- [Contributing, tests, and packaging](CONTRIBUTING.md)
- [Tagged releases and Asset Library distribution](RELEASING.md)

Run this repository as a Godot project for an interactive example. It sends nothing unless `POSTHOG_API_KEY` is set in the launching environment (`POSTHOG_HOST` is optional).

```sh
python3 scripts/test.py       # Godot 4.5+; GODOT can specify the executable.
python3 scripts/package.py   # Produces dist/posthog-godot-0.1.1.zip.
# See CONTRIBUTING.md for real desktop/Web export tests.
```

## License

MIT. See [LICENSE](LICENSE).
