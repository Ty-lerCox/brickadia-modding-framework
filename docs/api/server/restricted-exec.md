# Restricted Server Exec

`BMF.server.exec(command)` runs a server console command through the proven
UE4SS/Omegga executor path.

**Labels:** `restricted`, `unsafe-native`, `capability-gated`, `L5 Negative`

## Who Should Read This?

Plugin authors should use this page only when no typed BMF wrapper exists.
Maintainers should use it when reviewing dangerous command execution paths or
capability/config gates.

## Contract

Plugins must declare `server.exec` or `server.exec.restricted`; otherwise the
call returns `CAPABILITY_REQUIRED`. The framework config must also opt in with
`allowPluginServerExec: true`; otherwise the call returns
`CONFIG_OPT_IN_REQUIRED`.

```lua
local response = BMF.server.exec([[Chat.Broadcast "Hello from BMF"]])
if not response.ok then
  BMF.log(response.code)
end
```

!!! danger
    `BMF.server.exec` is a restricted escape hatch. Prefer a typed BMF wrapper
    such as `BMF.chat.broadcast`, `BMF.world.saveAs`, or
    `BMF.world.loadAdditive` when one exists.

Default `Mods/BMF/config.json`:

```json
{
  "allowPluginServerExec": false,
  "allowPluginServerShutdown": false
}
```

## Validation

Capability denial and config opt-in denial are tracked in
[API Validation Evidence](../../validation/api-validation.md#server).
