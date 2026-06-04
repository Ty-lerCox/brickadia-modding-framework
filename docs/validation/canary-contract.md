# Canary Contract

Each BMF canary writes a JSON artifact with enough evidence to decide whether a
feature is complete, blocked, or unsafe to promote.

Required fields:

- `feature`
- `status`
- `validationLevel`
- `startedAt`
- `finishedAt`
- `evidence`

Recommended artifact path:

```text
artifacts/overnight/<timestamp>/<feature>.json
```

Validation levels are defined in `TODO.md`.
