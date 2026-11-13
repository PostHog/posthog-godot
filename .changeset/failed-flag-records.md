---
'posthog-godot': patch
---

Treat failed feature flag records as unavailable, honor caller defaults, and report evaluation errors without exposing failed values or payloads. Retain successful cached flags on response-wide evaluation errors while continuing to replace state on complete successful refreshes.
