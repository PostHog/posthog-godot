# Changelog

## 0.1.0 - Unreleased

- Initial native Godot 4.5+ PostHog addon based on the Unity SDK.
- Analytics, identity, groups, sessions, lifecycle events, consent, and persistent delivery.
- Feature flags, JSON payloads, experiment exposures, cached evaluation context, and request cancellation.
- Manual and automatic Godot error tracking.
- Deduplicate identical automatic errors without suppressing unrelated errors, with bounded per-frame and rolling-window rate limits.
- Preserve pending automatic errors during flush, quit, and normal shutdown, while still discarding them on opt-out.
- Editor plugin, resource configuration, example, headless tests, and addon packaging.
- Session replay intentionally excluded; see `docs/unity-parity.md` for remaining limitations.
