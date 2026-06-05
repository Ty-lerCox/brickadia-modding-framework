# Audit API

BMF writes an admin-oriented audit stream under:

```text
Mods/BMF/runtime/audit.jsonl
```

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
Omegga.Bridge.BMF bmf.audit.tail limit=20
```

Current built-in audit records include framework/plugin load and unload,
command dispatch, command access grants/denials, unknown commands, command
errors, plugin errors, capability denials, config opt-in denials, server exec,
world load/save, server save, server shutdown, chat broadcast, private-message
delivery, and private-message target/delivery failures.

## Validation

- `L0 Static`: package validator checks audit API markers, docs, and canary.
- `L2 Headless`: `scripts/validate-bmf-audit-log.ps1` loads a temporary plugin,
  writes a custom plugin audit record, triggers capability denial, triggers
  private-message target-not-found behavior, invokes `bmf.audit.tail`, and
  parses `runtime/audit.jsonl`.
