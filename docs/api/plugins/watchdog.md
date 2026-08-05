# Plugin Watchdog

BMF records plugin-owned hook and command failures per plugin. The default
watchdog policy isolates a loaded plugin after three failures in the current
loaded plugin instance.

**Labels:** `stable`, `watchdog`, `L5 Negative`

## Who Should Read This?

Plugin authors should use this page to understand what happens after repeated
plugin failures. Maintainers should use it when changing isolation thresholds,
audit records, or reload recovery.

## Configuration

```json
{
  "pluginWatchdogEnabled": true,
  "pluginWatchdogMaxErrors": 3
}
```

## Isolation Behavior

When a plugin is isolated:

- future plugin hooks are skipped;
- plugin-owned event and tool registrations are removed, and owned timers are
  cancelled;
- plugin-owned command handlers are released while a small command tombstone is
  retained to report `PLUGIN_ISOLATED`;
- an already-snapshotted plugin event or tool handler is skipped before it can
  run;
- plugin-owned console commands that race with isolation return
  `PLUGIN_ISOLATED` before the handler runs;
- `runtime/audit.jsonl` receives a `plugin.isolated` record;
- `BMF.plugins.list()` includes `errorCount`, `isolated`, `isolatedAt`,
  `isolatedReason`, and `lastError`.

Failures from plugin-owned event handlers are routed through the same
`onError` and watchdog path as lifecycle hooks and plugin commands.

Server-console watchdog route:

```text
bmf.plugins.watchdog
```

`bmf.reload` resets watchdog state so a fixed plugin can load cleanly.

## Validation

Watchdog proof is tracked in
[API Validation Evidence](../../validation/api-validation.md#plugins).
