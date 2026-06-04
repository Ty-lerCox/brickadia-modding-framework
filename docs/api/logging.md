# Logging API

BMF writes framework logs and structured event logs under:

```text
Mods/BMF/runtime/
  bmf.log
  events.jsonl
  audit.jsonl
  logs/plugins/<PluginName>.log
```

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

- `L0 Static`: package validator checks logging API markers, docs, and canary.
- `L2 Headless`: `scripts/validate-bmf-logging.ps1` loads a temporary plugin,
  invokes a BMF command, then verifies the framework log, plugin log, and
  JSONL event records without a connected player.
