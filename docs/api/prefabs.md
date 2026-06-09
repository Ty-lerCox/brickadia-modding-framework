# Prefabs API

Prefab support is currently a tooling lane that feeds the world API. The goal is
to turn `.brz` prefab archives into `.brdb` world bundles that a server can load
with `BR.World.LoadAdditive`, then later wrap that path with Lua helpers such as
`BMF.prefabs.loadBrz(options)`.

## Examples

- [LoadCarBrz](../examples/index.md#loadcarbrz): complete plugin that loads a
  staged BRZ-derived world bundle and saves the running world.

## Current Shape

`scripts/stage-brz-prefab.ps1` is the safe staging entry point:

```powershell
.\scripts\stage-brz-prefab.ps1 `
  -InputBrz ..\Brickadia\Car.brz `
  -OutputBrdb .\artifacts\local\Car.world.brdb `
  -StageToServerWorlds `
  -WorldName BMF_CarPrefab `
  -Force
```

It produces:

- a prefab diagnosis report;
- a hash report with the inferred Brickadia prefab hash candidate;
- a `.brdb` world bundle;
- a static archive parse report;
- an optional copy in Brickadia `Saved/Worlds`.

`scripts/validate-brz-prefab-staging.ps1` proves the staged bundle can be loaded
and saved by a disposable headless server.

## Safe Defaults

The normal path does not patch `Meta/Prefab.json` physics metadata. Local
evidence for `Car.brz` shows the source prefab has dynamic entity/joint data
while `bIsPhysicsGrid=false`; forcing that field to true is useful for diagnosis
but can crash the dedicated server at `TVariant.h:148`.

The current safe staging path leaves coordinates unbaked. Placement belongs to
`BR.World.LoadAdditive`, which is the shape BMF should eventually expose to Lua.

Duplicate raw `Car.brz` staging has an extra caveat: the BRZ-derived world has
19 saved entities and body grid `1` without the grid-id companion entity found
in graph-closure dynamic-actor slices. Loading the same raw staged BRDB twice
can coalesce into one graph, and remapping that raw bundle can disconnect the
second car's dynamic actors from the body grid. For duplicate spawned-car tests,
use the dynamic-actor slice plus `scripts/remap-staged-vehicle-brdb.js`.
`scripts/validate-server-vehicle-spawn-set.ps1` is the current headless canary
for turning that slice into several isolated staged car copies.

## Lua API

`BMF.prefabs.loadBrz(options)` loads a BRZ-derived world bundle after it has
already been staged by `scripts/stage-brz-prefab.ps1` or a future trusted
companion process:

```lua
BMF.prefabs.loadBrz({
  source = "Car.brz",
  name = "BMF_CarPrefab",
  position = { x = 58000, y = 0, z = 1000 },
  yaw = 0
})
```

If only `source` is supplied, the wrapper returns `PREFAB_STAGING_REQUIRED`
instead of trying to run unsafe native prefab code from Lua.

The same staged-load path is available through the BMF command worker:

```text
Omegga.Bridge.BMF bmf.prefabs.loadbrz source=Car.brz name=BMF_CarPrefab x=58000 y=0 z=1000 yaw=0
```

The command does not convert `.brz` archives inside UE4SS Lua. Stage the archive
first with `scripts/stage-brz-prefab.ps1 -StageToServerWorlds`, then call the
command and save the result with `bmf.world.saveas`.

`BMF.prefabs.loadBrdb(options)` loads an already staged `.brdb` world bundle via
the same `BR.World.LoadAdditive` path:

```lua
BMF.prefabs.loadBrdb({
  name = "BMF_CarPrefab",
  position = { x = 58000, y = 0, z = 1000 },
  yaw = 0
})
```

Server-console command route:

```text
Omegga.Bridge.BMF bmf.prefabs.loadbrdb name=BMF_ThreeCarsPrefab x=66000 y=0 z=1000 yaw=0
```

Copy the source `.brdb` into Brickadia `Saved/Worlds` first. The runtime command
only loads the staged world name.

Both functions return the standard BMF result shape and include the exact
console command in `result.data.command` when command execution is attempted.

Validation:

- `L2 Headless`: `validate-bmf-prefab-runtime.ps1` stages `Car.brz`, loads it
  through `BMF.prefabs.loadBrz`, saves the world, and parses the saved BRDB.
- `L2 Headless`: `validate-bmf-prefab-command.ps1` stages `Car.brz`, invokes
  `bmf.prefabs.loadbrz` through `Omegga.Bridge.BMF`, saves the loaded map,
  parses the saved BRDB, and exports `vehicle-inventory.txt` proving one
  vehicle-like group.
- `L2 Headless`: `validate-bmf-prefab-brdb-command.ps1` stages the known
  `threecars.brdb` fixture, invokes `bmf.prefabs.loadbrdb` through
  `Omegga.Bridge.BMF`, saves the loaded map, parses the saved BRDB, and exports
  `vehicle-inventory.txt` proving three vehicle-like groups.
- `L3 Live Player`: still required before claiming the staged dynamic vehicle is
  visually correct or drivable.
