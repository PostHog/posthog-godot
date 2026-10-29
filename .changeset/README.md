# Change intents

Add one Markdown file per releasable change:

```markdown
---
'posthog-godot': patch
---

Describe the user-visible change.
```

Use `patch`, `minor`, or `major`. The Release workflow applies pending intents on `main`, synchronizes the Godot versions, and publishes after CI and approval. pnpm records consumed intents in `ledger.yaml`; do not delete or edit that ledger manually.

See [RELEASING](../RELEASING.md) for the full process.
