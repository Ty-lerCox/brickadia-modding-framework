# Plugin Sandbox

Plugin code receives normal Lua globals through a scoped environment, but BMF
blocks known dangerous UE4SS/native globals by default.

**Labels:** `stable`, `sandbox`, `L5 Negative`

## Who Should Read This?

Plugin authors should use this page to understand which low-level globals are
intentionally unavailable. Maintainers should use it when adding or reviewing
native escape hatches.

## Blocked By Default

Blocked globals include:

- `OmeggaExecuteConsoleManagerInput`
- `OmeggaExecuteCachedConsoleExec`
- `OmeggaExecuteKismetConsoleCommand`
- `RegisterConsoleCommandGlobalHandler`
- `RegisterHook`
- `StaticFindObject`
- `ExecuteInGameThread`
- `ExecuteWithDelay`

This keeps plugins on public BMF wrappers instead of bypassing capability
gates, audit records, rate limits, and watchdog handling.

## Preferred Wrappers

- `BMF.server.exec`, with capability and config opt-in, for restricted console
  execution.
- `BMF.world.loadAdditive` and `BMF.world.saveAs` for world commands.
- `BMF.timers.after` and `BMF.timers.every` for scheduling.

Runtime policy route:

```text
Omegga.Bridge.BMF bmf.sandbox
```

Lua inspection:

```lua
local policy = BMF.sandbox.policy()
local denials = BMF.sandbox.denials()
```

## Unsafe Escape Hatch

```json
{
  "allowPluginUnsafeGlobals": true
}
```

!!! danger
    A plugin must also declare `unsafe.globals`. This is intentionally not used
    by examples and should stay research-only.
