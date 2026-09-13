# Configuration

`PostHogConfig` is a Godot Resource. Exported fields are editable in the Inspector; `before_send` is a runtime Callable. `setup()` validates and copies the config, so subsequent changes to the original resource do not reconfigure the running client. `setup()` returns false and logs a warning on invalid or repeated initialization.

| Option | Default | Meaning |
| --- | --- | --- |
| `api_key` | `""` (required) | PostHog project API key. |
| `host` | `https://us.i.posthog.com` | HTTP(S) ingestion host; EU uses `https://eu.i.posthog.com`. Reverse-proxy path prefixes work. No query/fragment/credentials or redirects. Use HTTPS outside local testing. |
| `skip_auto_init_on_editor_play` | `true` | Skip resource-based automatic initialization in editor builds (including command-line runs). Explicit `setup()` remains allowed. Exports are unaffected. |
| `flush_at` | `20` | Queue threshold for sending (effective threshold cannot exceed queue capacity). |
| `flush_interval_seconds` | `30` | Automatic flush interval; at least 1 second. |
| `max_queue_size` | `1000` | Maximum retained events; oldest evicted on overflow. |
| `max_batch_size` | `50` | Maximum events per request; adapts downward on HTTP 413. |
| `request_timeout_seconds` | `10` | Per-request timeout, including flag requests. |
| `person_profiles` | `IDENTIFIED_ONLY` | `PostHogConfig.PersonProfiles.ALWAYS`, `IDENTIFIED_ONLY`, or `NEVER`. |
| `reuse_anonymous_id` | `false` | Retain the anonymous ID across reset; when true, omit `$anon_distinct_id` from flag requests. |
| `preload_feature_flags` | `true` | Automatically load flags at startup, identify/reset, group changes, and opt-in. |
| `feature_flag_request_max_retries` | `1` | 0–5 retries after HTTP 502/504 and selected transient connection errors; starts at 300 ms exponential backoff. No retries for HTTP 429 or other client errors. |
| `send_feature_flag_event` | `true` | Emit deduplicated `$feature_flag_called` events when known flags are accessed. Required for experiment exposure tracking. |
| `send_default_person_properties_for_flags` | `true` | Send app version/build, OS name/version, device type, and SDK name/version for evaluation. Explicit overrides take precedence. |
| `capture_application_lifecycle_events` | `true` | Installed/updated/opened/backgrounded analytics events. Version history still advances when disabled. |
| `capture_exceptions` | `true` | Automatically capture Godot errors via Logger. Does not disable explicit `capture_exception()`. |
| `capture_exceptions_in_editor` | `true` | Allow automatic errors in editor builds (including games launched from the editor). |
| `exception_debounce_interval_ms` | `1000` | Minimum interval between identical automatic errors (type/message/file/line); 0 disables duplicate suppression. Separate fixed limits allow 5 errors per frame, 20 per rolling 10 seconds, and 20 pending errors. Manual captures are unaffected. |
| `flush_on_quit` | `true` | Best-effort final flush for window-close interception and `PostHog.quit()`. |
| `flush_on_quit_timeout_seconds` | `3` | Maximum final flush wait. |
| `opt_out_by_default` | `false` | Initial consent state when no persisted explicit preference exists. Set before setup. |
| `persistence` | `true` | Store identity, consent, overrides, flags, super properties, lifecycle history, and queued events. False keeps everything in memory. |
| `storage_path` | `user://posthog` | Parent storage directory; project key and normalized host select an isolated subdirectory. Must be under `user://`. |
| `app_version` | `""` | Override version; empty reads `application/config/version`. |
| `app_build` | `""` | Build identifier for metadata and update detection; supply from your build pipeline. |
| `before_send` | unset | Called with an enriched event Dictionary; return a valid Dictionary or null to drop. Not exported in the Inspector. |

## Public state and signals

Treat these fields as read-only:

- `is_initialized`, `is_opted_out`, `distinct_id`
- `session_id` (empty while opted out or with no active background session)
- `queued_event_count`, `feature_flags_are_loaded`

Signals:

- `feature_flags_loaded()` — a valid response or usable disk cache is available; quota-limited responses clear flags.
- `feature_flags_request_finished(success: bool)` — a load attempt completed or was canceled.
- `events_dropped(count: int, reason: String)` — `queue_full`, `event_too_large`, or `http_<status>`.

`PostHogFeatureFlag` exposes `key`, `value`, `payload`, `metadata`, `has_value`, `has_payload`, `is_enabled`, `get_variant(default_value = "")`, and `get_payload(default_value = null)`. A nonempty string variant is enabled; a disabled flag stays false even if the server includes a variant.

## Metadata

Captured events include `$lib`, `$lib_version`, `$os`, `$os_version`, `$device_type`, `$device_model`, `$screen_width`, `$screen_height`, `$app_name`, `$app_version`, `$app_build`, `$godot_version`, `$godot_environment`, `$locale`, `$is_identified`, and `$process_person_profile`. Active sessions add `$session_id`; memberships add `$groups`.

Event properties override super properties. SDK-owned metadata then overrides both; `before_send` runs last. No screenshots, input text, local variables, advertising IDs, or hardware IDs are automatically collected.

`$godot_environment` is detected from engine capabilities: `editor` for editor-tool context, `editor_play` for an editor binary running a game, `dedicated_server` for a server export, otherwise `export_debug` or `export_release`. Headless display does not change the classification. It is included in default flag properties unless `send_default_person_properties_for_flags` is disabled; explicit evaluation overrides still take precedence.
