# Server Status And Save

`BMF.server.status()` reports BMF runtime state. `BMF.server.save()` saves the
running world through the proven `BMF.world.saveAs` path.

**Labels:** `experimental`, `L2 Headless`

## Who Should Read This?

Plugin authors should use this page for status reporting and admin snapshots.
Server operators should use it to understand what BMF can prove headlessly
without connected players.

## `BMF.server.status()`

Returns structured server/runtime status. Fields that are not safely known in a
headless server are represented explicitly with `unknown` status values instead
of guessed data.

```lua
local status = BMF.server.status()
if status.ok then
  BMF.log("players=" .. tostring(status.data.playerCount))
  BMF.log("world=" .. tostring(status.data.worldNameStatus))
end
```

Headless-safe fields include:

- BMF version, startup time, uptime, paths, and config flags.
- Compatibility status, declared target build, build-detection mode, and
  required UE4SS helper availability.
- Loaded plugin count and plugin error count.
- Registered BMF command count and command names.
- Active timer count.
- Empty player adapter result, currently `headless-empty` without a connected
  player.
- Target build metadata for the current reverse-engineering lane.

The compatibility object mirrors `BMF.compatibility.check()`. Build detection is
currently `declared-target-only`, so unsupported future builds are reported but
not refused until a reliable runtime build source is proven.

Unknown until further live-object discovery:

- Server browser name and description.
- Current world/map name.
- Brick count and component count from the live world.

The `bmf.server.status` command prints the same status as stable key/value
lines for automation.

## `BMF.server.save(options)`

Saves the running world through the proven `BMF.world.saveAs` path. Pass a world
name string or an options table:

```lua
BMF.server.save("BMF_AdminSnapshot")
BMF.server.save({ name = "BMF_AdminSnapshot" })
```

If no name is supplied, BMF generates a `BMF_ServerSave_<timestamp>` name.
Plugins must declare `server.save`; otherwise the scoped plugin call returns
`CAPABILITY_REQUIRED`.

The `bmf.server.save` command exposes the same helper for unattended runs:

```text
Omegga.Bridge.BMF bmf.server.save name=BMF_AdminSnapshot
```

## Validation

Current server status and save proof is tracked in
[API Validation Evidence](../../validation/api-validation.md#server).
