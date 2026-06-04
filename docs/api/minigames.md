# Minigames API

BMF minigame support starts with the console-backed surface already exposed by
Omegga and Brickadia. These wrappers prove transport and command formatting;
they do not yet create full configured minigames from scratch.

## `BMF.minigames.list()`

Runs:

```text
Server.Minigames.List
```

```lua
local result = BMF.minigames.list()
if result.ok then
  BMF.log(result.data.command)
end
```

On a headless empty server, this is expected to return command transport
evidence. Rich parsing of the console table is still an Omegga-side capability.

Server-console command route:

```text
Omegga.Bridge.BMF bmf.minigames.list
```

The command response records `command=Server.Minigames.List` plus the executor
used by the runtime.

## Presets

Load a saved preset:

```lua
BMF.minigames.loadPreset("Arena")
```

Server-console command route:

```text
Omegga.Bridge.BMF bmf.minigames.loadpreset name=Arena
```

Save an active minigame as a preset:

```lua
BMF.minigames.savePreset(0, "Arena")
```

Server-console command route:

```text
Omegga.Bridge.BMF bmf.minigames.savepreset index=0 name=Arena
```

List saved preset files from disk:

```powershell
.\scripts\list-minigame-presets.ps1
```

Preset names are validated to reject path separators and control characters.

## Lifecycle

```lua
BMF.minigames.nextRound(0)
BMF.minigames.reset(0)
BMF.minigames.delete(0)
```

Server-console command routes:

```text
Omegga.Bridge.BMF bmf.minigames.nextround index=0
Omegga.Bridge.BMF bmf.minigames.reset index=0
Omegga.Bridge.BMF bmf.minigames.delete index=0
```

These wrap:

- `Server.Minigames.NextRound <index>`
- `Server.Minigames.Reset <index>`
- `Server.Minigames.Delete <index>`

Indexes must be zero or greater.

## Validation

- `L0 Static`: command formatting and preset directory listing.
- `L1 Boot`: BMF Lua wrappers load and execute on a disposable headless server.
- `L2 Headless`: command transport can be proven for safe commands such as
  `Server.Minigames.List`.
- `L2 Headless + L5 Negative`: `scripts/validate-bmf-minigame-commands.ps1`
  proves command-worker transport for load preset, save preset, next round,
  reset, and delete, plus invalid preset-name and invalid-index rejection.
- `L3 Live Player`: joining, membership, teams, scoring, and gameplay effects.
- `L5 Negative`: permission or policy enforcement around minigame edits.

## Still Open

- Creating a configured minigame without a client UI.
- Mutating included-brick mode, owner-only mode, persistent mode, and teams.
- Discovering the runtime minigame manager/object model.
- Proving whether minigame commands are safe before the default minigame exists.
