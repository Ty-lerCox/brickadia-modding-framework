# Unsafe Minigame Commands

**Labels:** `unsafe opt-ins`, `restricted`, `L2 Headless`, `L5 Negative`

## Who Should Read This?

Maintainers should use this page for isolated tracing and validation only. Gameplay plugins should prefer minigame events and data snapshots.

Legacy Brickadia minigame console wrappers and raw object probes are documented
here because they are not the preferred gameplay path. They are disabled by
default and should be used only during isolated tracing or validation.

## When To Use

Use these commands only when a canary or reverse-engineering task specifically
needs the legacy Brickadia minigame surface. For gameplay systems, prefer
[Events](events.md) and [Data Snapshot](data.md).

## Legacy Console Wrappers

`BMF.minigames.list()` would run, when explicitly enabled:

```text
Server.Minigames.List
```

```lua
local result = BMF.minigames.list()
if result.ok then
  BMF.log(result.data.command)
end
```

By default this returns `UNSAFE_MINIGAME_COMMAND_DISABLED` and does not execute
Brickadia's console command.

Server-console route:

```text
Omegga.Bridge.BMF bmf.minigames.list
```

## Presets

```lua
BMF.minigames.loadPreset("Arena")
BMF.minigames.savePreset(0, "Arena")
```

Server-console routes:

```text
Omegga.Bridge.BMF bmf.minigames.loadpreset name=Arena
Omegga.Bridge.BMF bmf.minigames.savepreset index=0 name=Arena
```

List saved preset files from disk:

```powershell
.\scripts\list-minigame-presets.ps1
```

Preset names reject path separators and control characters.

## Lifecycle Wrappers

```lua
BMF.minigames.nextRound(0)
BMF.minigames.reset(0)
BMF.minigames.delete(0)
```

Server-console routes:

```text
Omegga.Bridge.BMF bmf.minigames.nextround index=0
Omegga.Bridge.BMF bmf.minigames.reset index=0
Omegga.Bridge.BMF bmf.minigames.delete index=0
```

These would wrap, when explicitly enabled:

- `Server.Minigames.NextRound <index>`
- `Server.Minigames.Reset <index>`
- `Server.Minigames.Delete <index>`

Indexes must be zero or greater. By default, valid lifecycle calls fail closed
before reaching Brickadia.

## Object Snapshot

`BMF.minigames.objectSnapshot({ limit = 64 })` probes live `BP_Ruleset_C` and
`BP_Team_C` objects through UE4SS. It is disabled by default because raw object
enumeration is high risk on the current dedicated-server runtime.

Server-console routes:

```text
Omegga.Bridge.BMF bmf.minigames.objects.snapshot limit=64
Omegga.Bridge.BMF bmf.minigames.objects.snapshot limit=64 includeProperties=true
```

By default the command returns `UNSAFE_MINIGAME_OBJECT_SNAPSHOT_DISABLED` with
`allowUnsafeMinigameObjectSnapshot=false`. Direct Unreal property reads such as
`MemberStates` and `TeamColor` require `includeProperties=true`.

!!! danger
    Only enable `allowUnsafeMinigameConsoleCommands` or
    `allowUnsafeMinigameObjectSnapshot` when a crash is acceptable and the
    server can be restarted.

## Still Open

- Creating a configured minigame without a client UI.
- Mutating included-brick mode, owner-only mode, persistent mode, and teams.
- Discovering the runtime minigame manager/object model safely.
- Proving whether minigame commands are safe before the default minigame exists.
