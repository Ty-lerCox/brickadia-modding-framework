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
- `ExecuteAsync`
- `ExecuteInGameThread`
- `ExecuteInGameThreadAfterFrames`
- `ExecuteInGameThreadWithDelay`
- `ExecuteWithDelay`
- `LoopAsync`
- `LoopInGameThreadAfterFrames`
- `LoopInGameThreadWithDelay`
- `MakeActionHandle`
- `CancelDelayedAction`

This keeps plugins on public BMF wrappers instead of bypassing capability
gates, audit records, rate limits, watchdog handling, timer ownership, and the
single game-thread Lua execution domain. In particular, `ExecuteWithDelay`,
`ExecuteAsync`, and `LoopAsync` are unsupported for all plugin Lua; moving only
the final UObject call onto the game thread does not make an async Lua producer
safe.

## Preferred Wrappers

- `BMF.server.exec`, with capability and config opt-in, for restricted console
  execution.
- `BMF.world.loadAdditive` and `BMF.world.saveAs` for world commands.
- `BMF.timers.after` and `BMF.timers.every` for bounded, game-thread-only,
  owner-scoped scheduling. BMF removes a plugin instance's timers during
  unload/reload.

Runtime policy route:

```text
bmf.sandbox
```

Lua inspection:

```lua
local policy = BMF.sandbox.policy()
local denials = BMF.sandbox.denials()
```

## Environment Containment

Each plugin receives its own shallow copy of `bit32`, `coroutine`, `math`,
`string`, `table`, and `utf8` when available. Replacing a library entry therefore
does not mutate the framework's library table or another plugin's copy. The
plugin `os` table is an explicit time-only subset: `clock`, `date`, `difftime`,
and `time`. Process and filesystem functions such as `os.execute`, `remove`, and
`rename` are not exposed.

`io` is absent by default. A plugin that must interoperate with an external
native-helper control or event file can declare `filesystem.raw`, which exposes
only `io.open` and `io.type`. This is a high-trust capability: `io.open` accepts
arbitrary paths, so normal plugin config and data must continue to use the
owner-scoped `BMF.storage` facade.

The scoped environment does not expose `getmetatable`, and the plugin BMF facade
does not expose the framework-wide `BMF.loadPlugins` or `BMF.unloadPlugins`
lifecycle functions or unrestricted `BMF.commands.dispatch`. The
access-checked dispatcher requires an explicit plugin capability. Operators and
the authenticated bridge retain unrestricted dispatch through the
framework-level BMF table and server commands.

The plugin BMF facade is assembled from an explicit top-level allowlist.
Allowed namespaces such as `permissions`, `minigames`, and `interact` are copied
recursively before owner- and capability-scoped wrappers are installed, so a
plugin cannot mutate the framework's namespace tables or another plugin's
facade by assigning fields.

Denied unsafe-global lookups update in-memory counters immediately. Runtime
status persistence is rate-limited so a plugin cannot turn a repeated denied
lookup into an unbounded synchronous status-file write loop.

## Unsafe Escape Hatch

```json
{
  "allowPluginUnsafeGlobals": true
}
```

!!! danger
    A plugin must also declare `unsafe.globals`. This is intentionally not used
    by examples and should stay research-only. The escape hatch does not make
    async Lua schedulers supported or safe; production plugins must not use
    `ExecuteWithDelay`, `ExecuteAsync`, or `LoopAsync` even when the hatch is
    enabled.
