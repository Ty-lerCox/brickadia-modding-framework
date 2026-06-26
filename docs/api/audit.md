# Audit API

**Labels:** `stable`, `L2 Headless`

## Who Should Read This?

Plugin authors should use this page for structured mutation and security records. Server operators should use it when tracing admin actions and denials.

BMF writes an admin-oriented audit stream under:

```text
Mods/BMF/runtime/audit.jsonl
```

## Examples

- [EventAudit](../examples/event-audit.md): complete plugin that records
  structured audit data from an event handler.

Each line is a JSON object with stable fields:

```json
{
  "ts": "2026-06-04T08:00:00Z",
  "action": "command.dispatch",
  "source": "command",
  "severity": "info",
  "ok": true,
  "code": "OK",
  "data": {}
}
```

Framework code can call:

```lua
BMF.audit.record("example.action", { value = 42 })
local recent = BMF.audit.recent(10)
```

Plugins receive a scoped audit facade. `BMF.audit.record(...)` automatically
adds the plugin name when called from a plugin.

Server-console command route:

```text
bmf.audit.tail limit=20
```

Current built-in audit records include framework/plugin load and unload,
command dispatch, command access grants/denials, unknown commands, command
errors, plugin errors, capability denials, config opt-in denials, server exec,
world load/save, server save, server shutdown, chat broadcast, private-message
delivery, and private-message target/delivery failures.

## Validation

Audit proof is tracked in
[API Validation Evidence](../validation/api-validation.md#framework-utilities).
