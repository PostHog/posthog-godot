# PostHog Godot

> [!WARNING]
> This SDK is experimental and not yet production-ready. APIs and behavior may change without notice. Test thoroughly before using it in a production game.

A native **Godot 4.5+ GDScript addon** for PostHog, based on the [PostHog Unity SDK](https://github.com/PostHog/posthog-unity). No .NET, native libraries, or runtime dependencies required.

SDK usage examples and code snippets live in the official documentation so they stay up to date. The notes below cover additional SDK behavior and repository-specific information.

## Documentation

- [Godot library docs](https://posthog.com/docs/libraries/godot)
- [All configuration options](docs/configuration.md)

## Validation and limitations

**Initial implementation (0.1.0).** Unit tests are verified locally with Godot 4.5 and 4.7.2, plus real macOS and Chromium Web release exports against local HTTP servers. CI includes Windows/macOS/Linux release-export checks and browser tests. Android emulator and iOS simulator release smoke tests also pass against US Cloud (iOS requires a custom ARM64 Godot simulator library). Physical devices, other browsers, and downstream ingestion/error grouping still need validation.

**Session replay is intentionally excluded.**

## Additional SDK behavior

### Initialization and environment

Without the editor plugin, add `res://addons/posthog/posthog.gd` as an autoload named `PostHog` yourself. Use one active client per storage namespace; the SDK does not coordinate concurrent processes writing the same storage directory.

When resource-based initialization is skipped in editor builds, no identity, storage, networking, or error logger is initialized.

Events include `$godot_environment`: `editor_play`, `export_debug`, `export_release`, or `dedicated_server` (`editor` when running in editor-tool context). Headless mode alone does not identify a dedicated server. This metadata is also included in default feature-flag evaluation properties. Disabling `capture_exceptions_in_editor` only affects automatic errors, not other development telemetry.

### Analytics and identity

Sessions have 30-minute inactivity and 24-hour maximum durations.

Use `alias()` to link another ID to the current user:

```gdscript
PostHog.alias("old-player-id")
```

`$set` and `$set_once` properties passed to `identify()` are also used for immediate flag evaluation.

Property strings may also be StringNames; numbers must be finite. Deeply nested/cyclic values are rejected.

### Feature flags

- Pass `false` as `get_feature_flag(key, send_event)` to suppress an individual exposure event, or disable `send_feature_flag_event` globally.
- Concurrent reloads share a request. Context changes cancel obsolete requests so another user cannot see their results.
- Like `identify()`, `reset()` awaits a flag reload when `preload_feature_flags` is enabled, and its boolean return reports the reload result. When preloading is disabled, call `await reload_feature_flags()` explicitly after either method if you need fresh flags.
- Override setters reload by default, independently of preloading.
- Numbers decoded from JSON payloads are Godot floats. There is no custom typed payload deserializer.

### Privacy and event redaction

Corrupt/unreadable persisted consent state fails closed to opted-out. No hardware/device identifier is collected.

Use `before_send` to redact or drop events:

```gdscript
config.before_send = func(event: Dictionary):
    if event.event == "sensitive_event":
        return null
    event.properties.erase("email")
    return event
```

`before_send` sees fully enriched events, including lifecycle, exposure, and error events. Invalid events are dropped, and the SDK keeps its generated UUID as the durable queue key. Do not call SDK control/identity methods from this callback; recursive captures are ignored. It does not intercept feature-flag request bodies: avoid sensitive evaluation properties, or disable `send_default_person_properties_for_flags` as appropriate.

### Error tracking

The optional final parameter of `capture_exception()` overrides whether an error is handled. Frames from `get_stack()` are converted to PostHog's raw stacktrace schema. No local variables are collected.

Automatic error deduplication compares type, message, file, and line. Setting `exception_debounce_interval_ms = 0` disables duplicate suppression, not the safety limits.

Automatic errors use the backtrace whose newest frame matches the reported file/line, or the longest available backtrace when none matches. Engine errors retain their native origin alongside script frames, with at most 50 frames total. SDK-originated errors are excluded, but customer callback errors are not discarded merely because an SDK frame appears farther down the stack. Errors generated on the forwarding thread while processing an automatic error are suppressed to prevent feedback loops; unrelated worker-thread errors remain eligible.

Without release call-stack tracking enabled, automatic errors may contain only an engine source frame.

### Delivery and threading

Delivery is at-least-once with stable UUIDs, not guaranteed exactly-once.

Network/server failures, HTTP 408, and HTTP 429 retain events with bounded exponential backoff; numeric `Retry-After` is honored. HTTP 413 splits batches and drops an individually oversized event. Other 4xx errors discard the rejected batch. `events_dropped(count, reason)` reports overflow/permanent HTTP drops. Concurrent flushes share a request.

Requests set `User-Agent: posthog-godot/<sdk-version>`. Web exports are subject to browser restrictions and may send the browser User-Agent instead.

`flush()` first transfers pending automatic errors through the normal capture pipeline, including `before_send`. Normal shutdown stops the logger and queues its remaining errors before teardown, persisting them when persistence is enabled. `PostHog.quit()` does this before its final delivery attempt. Opt-out discards pending errors instead.

The addon processes networking even while the scene tree is paused. OS background notifications trigger a best-effort flush.

To call public APIs from a worker thread, use `PostHog.call_deferred("capture", "event", properties)`. The internal automatic error logger separately handles engine callbacks from worker threads.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for local setup, examples, tests, and packaging.

## Releasing

See [RELEASING.md](RELEASING.md).

## License

MIT. See [LICENSE](LICENSE).
