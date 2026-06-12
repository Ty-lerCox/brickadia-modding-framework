# Logging API

**Labels:** `stable`, `L2 Headless`

## Who Should Read This?

Plugin authors should use this page for text logs and structured JSONL event records. Maintainers should use it when changing log paths or plugin log routing.

BMF writes framework logs and structured event logs under:

```text
Mods/BMF/runtime/
  bmf.log
  events.jsonl
  audit.jsonl
  logs/plugins/<PluginName>.log
```

## Examples

- [EventAudit](../examples/event-audit.md): complete plugin that combines
  `BMF.logInfo` with `BMF.audit.record`.
- [HelloBroadcast](../examples/hello-broadcast.md): minimal plugin logging
  during `onLoad`.

Framework code can use:

```lua
BMF.log("Framework message")
BMF.log("warn", "Framework warning", { code = "EXAMPLE" })
BMF.logInfo("Info message")
BMF.logWarn("Warning message")
BMF.logError("Error message")
```

Plugins receive scoped logging helpers. Their log calls are mirrored to the
framework log, written to their own plugin log, and emitted as JSONL events with
`source="plugin"` and `plugin="<PluginName>"`.

```lua
return {
  onLoad = function(BMF)
    BMF.log("Plugin loaded")
    BMF.logger.info("Structured event", { phase = "load" })
  end,
}
```

`Mods/BMF/config.json` controls whether JSONL events are written:

```json
{
  "allowPluginServerExec": false,
  "jsonlLogs": true
}
```

Text logs are intended for humans. `events.jsonl` is intended for canaries,
automation, and later dashboard tooling. `audit.jsonl` is intended for admin
actions, security denials, and mutation history; see `docs/api/audit.md`.

## Validation

Logging proof is tracked in
[API Validation Evidence](../validation/api-validation.md#framework-utilities).
