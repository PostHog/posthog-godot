# Changelog

## 0.1.0 - Unreleased

- Initial native Godot 4.5+ PostHog addon based on the Unity SDK.
- Analytics, identity, groups, sessions, lifecycle events, consent, and persistent delivery.
- Feature flags, JSON payloads, experiment exposures, cached evaluation context, and request cancellation.
- Manual and automatic Godot error tracking.
- Deduplicate identical automatic errors without suppressing unrelated errors, with bounded per-frame and rolling-window rate limits.
- Preserve pending automatic errors during flush, quit, and normal shutdown, while still discarding them on opt-out.
- Select relevant error backtraces, retain native origins, and preserve customer callback errors with thread-scoped feedback-loop protection.
- Editor plugin, resource configuration, example, headless tests, and addon packaging.
- Skip automatic initialization during editor play by default, with an explicit opt-in and runtime-environment metadata.
- Add real desktop/Web release-export tests, a Windows/macOS/Linux CI matrix, and Chromium coverage for persistence, consent, CORS, and release stacktraces.
- Fix error-tracking frames missing the backend's required custom platform/language tags.
- Add a reusable portrait mobile smoke sample, key-safe local configuration, Android automation, and iOS ARM64 simulator instructions.
- Restore the config resource file picker on every editor startup without changing autoload registration.
- Fix documentation links in addon ZIPs by pinning repository-only targets to the source commit.
- Session replay intentionally excluded; see `docs/unity-parity.md` for remaining limitations.
