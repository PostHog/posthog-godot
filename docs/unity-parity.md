# Unity SDK reference and feature parity

Reference: local `posthog-unity`, commit [`3bfd43e0948ee170655ac6a308e29b0da7d8483c`](https://github.com/PostHog/posthog-unity/tree/3bfd43e0948ee170655ac6a308e29b0da7d8483c). The implementation follows its public API and wire formats, adapting Unity components/coroutines to Godot Nodes, signals, Resources, HTTPRequest, and Logger. The Unity working directory was not modified.

| Unity feature | Godot implementation |
| --- | --- |
| Setup/static facade/settings asset | `PostHog` autoload, `PostHogConfig` Resource, editor plugin |
| Capture, screen, SDK metadata | `capture()`, `screen()`, Godot-specific context |
| Anonymous UUIDv7 identity | Cryptographically random UUIDv7 with monotonic timestamp/sequence prefix |
| Identify, alias, set/set-once | `identify()`, `alias()`, anonymous linking and cached flag properties |
| Person profiles | All three modes; `NEVER` blocks identify/alias and always disables profile processing |
| Groups | `group()`, `$groups`, `$groupidentify`, group evaluation overrides |
| Super properties | Persistent `register()` / `unregister()` |
| Sessions | 30-minute inactivity and 24-hour cap; background-aware rotation |
| Lifecycle | Installed, updated, opened, backgrounded; Godot notifications and project/app version |
| Persistent event queue | Atomic per-event JSON files in `user://`, bounded queue, memory-only option |
| Batching, automatic/manual flush | HTTPRequest, periodic/threshold flush, awaitable `flush()` |
| Retry and HTTP 413 handling | Bounded exponential backoff, 408/429 retained, numeric Retry-After, 413 splitting |
| Feature flags and payloads | `/flags/?v=2`, detailed and legacy responses, native JSON payloads |
| Flag cache and experiments | Persistent context-scoped cache, exposure deduplication and metadata |
| Person/group properties for flags | Set/reset overrides, default device/app evaluation properties |
| Feature flag notifications | Godot signals, awaitable reload/identify/reset |
| BeforeSend | `before_send` Callable, redaction/drop support |
| Opt in/out | Persistent consent, canceled requests, cleared queued events/flag cache |
| Error tracking | Manual capture plus thread-safe Godot Logger integration; raw stack frames |
| Graceful quit | Best-effort window-close flush and explicit `PostHog.quit()` |
| Custom storage interface | Not ported as a public extension API; built-in filesystem/memory storage only |
| Log levels | SDK warnings only; no configurable debug log levels |
| Custom typed JSON deserializer | Not applicable; native Godot JSON values and caller-side mapping |
| Unity editor connection tester | Not ported; example and `await reload_feature_flags()` provide basic connectivity testing |
| Session replay, screenshots, replay logs/network telemetry | Intentionally excluded |

## Deliberate behavioral differences

- Minimum **Godot 4.5**, for the supported Logger/ScriptBacktrace APIs. Godot 3 and 4.0–4.4 are not supported.
- Uses idiomatic snake_case APIs and signals rather than C# static methods/Tasks. `get_feature_flag()` returns a wrapper like Unity; do not test the wrapper's truthiness—use `is_enabled` or `is_feature_enabled()`.
- Reset also clears super properties to reduce accidental cross-user attribution.
- Consent survives restarts, applies to feature flags as well as events, and is checked before identity mutation. Corrupt persistent state defaults to opted-out until explicit opt-in.
- Changes to identity/group/flag properties invalidate old flag results and cancel old requests. Groups reload flags when preloading is enabled.
- HTTP 429/408 are retryable for events; a single permanently oversized event is dropped so it cannot block the queue forever. Flags use Unity's narrower retry policy.
- `setup()` returns a success boolean and logs validation failures rather than throwing. Godot GDScript has no catchable exception mechanism.
- Error events use `godot_sdk`/`godot` sources, Godot resource paths, and synthetic mechanisms rather than CLR exception types. Native crash collection, exception cause chains, CLR symbolication, browser global-error hooks, and automatic C# exception handling are not provided.
- Automatic errors are bounded and delivered on the main thread; no variables are captured. Manual captures are not debounced.

## Platform status and requirements

The addon uses Godot's cross-platform HTTPRequest/FileAccess APIs. **Real macOS release exports and Chromium Web release exports have been verified locally**, in addition to headless unit tests. CI is configured to run unit tests and actual release exports on Windows, macOS, and Linux, plus browser tests against Web exports. The [mobile smoke sample](../examples/mobile_smoke/README.md) passed 47 client-side assertions on both an Android 16 ARM64 emulator and an iPhone 17 Pro / iOS 26.4 simulator using US Cloud. The iOS run used a locally compiled Godot 4.5 ARM64 release simulator library because the official template lacks that architecture. Physical devices and other browsers remain unverified.

- **Android:** enable the Internet permission in your export preset. Force-stop may prevent final delivery.
- **iOS/macOS sandboxed exports:** enable outgoing network access as required by the export entitlements. Use HTTPS; plain HTTP can be blocked by platform policy.
- **Web:** use an HTTPS ingestion host with appropriate CORS (including JSON POST preflight) and allow it in CSP `connect-src`. Godot's browser-backed `user://` persistence depends on browser storage availability and synchronization; synchronous FileAccess writes do not guarantee persistence on abrupt tab close. Chromium tests verify opt-in/out, identity, super properties, and queue persistence across reloads after observing the IndexedDB write. Abrupt tab-close durability and other browsers still need validation. No blocking quit flush is possible.
- **Release exports:** enable `debug/settings/gdscript/always_track_call_stacks` for script backtraces. Native crashes are not captured.
- **Threads:** public API and filesystem/network state are main-thread only. Use `call_deferred()` from workers. Only the automatic Logger callback is internally synchronized.
- **Networking:** requests set `User-Agent: posthog-godot/<sdk-version>` for analytics and feature flags. Web exports are subject to browser restrictions and may send the browser User-Agent instead. Requests have a 5 MiB response-size limit and do not follow redirects. Proxies must expose `/batch/` and `/flags/?v=2` under the configured host/prefix.

Before a production release, validate real ingestion/experiment attribution/error grouping against a test PostHog project, run physical-device and additional-browser export smoke tests, and wire up the PostHog SDK compliance harness. The automated tests validate wire format and client behavior. The mobile sample additionally checks live HTTP acknowledgement; it cannot prove downstream processing, error grouping, or full SDK compliance certification.

## Attribution

PostHog event/error schemas and SDK behavior are adapted from PostHog Unity. Unity's error formatting includes work originally derived from Sentry Unity; the corresponding MIT notices are retained in `LICENSE`.
