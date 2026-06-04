# Vehicles

Vehicle APIs are experimental and server-side only.

The current safe path is split in two:

1. Build staged vehicle world bundles outside Lua.
2. Load those staged worlds from BMF Lua through `BR.World.LoadAdditive`.

Runtime Lua does not rewrite `.brdb` archives. Use
`scripts/stage-vehicle-spawn-set.ps1` first:

```powershell
.\scripts\stage-vehicle-spawn-set.ps1 `
  -VehicleCount 3 `
  -WorldNamePrefix BMF_VehicleSpawnSet `
  -StartX 70000 `
  -StepX 2000 `
  -LoadZ 1000 `
  -StageToServerWorlds
```

The staging script uses the graph-closure single-car dynamic-actor slice by
default, copies the first vehicle unchanged, remaps later copies by persistent
entity/grid id offsets, validates each copy as one vehicle-like graph, and writes
a manifest with world names and positions.

## `BMF.vehicles.planSpawnSet(options)`

Plan staged vehicle loads without executing them:

```lua
local plan = BMF.vehicles.planSpawnSet({
  copies = {
    { name = "BMF_VehicleSpawnSet_01", position = { x = 70000, y = 0, z = 1000 } },
    { name = "BMF_VehicleSpawnSet_02", position = { x = 72000, y = 0, z = 1000 } },
    { name = "BMF_VehicleSpawnSet_03", position = { x = 74000, y = 0, z = 1000 } },
  },
})
```

`copies` may contain world-name strings or tables with `name`, `worldName`,
`stagedWorld`, `world`, or `bundle`.

The planner can also generate names from a prefix and count:

```lua
BMF.vehicles.planSpawnSet({
  worldNamePrefix = "BMF_VehicleSpawnSet",
  vehicleCount = 3,
  start = { x = 70000, y = 0, z = 1000 },
  step = { x = 2000 },
})
```

## `BMF.vehicles.spawnSet(options)`

Load each planned staged world through `BMF.world.loadAdditive`:

```lua
local spawned = BMF.vehicles.spawnSet({
  worldNamePrefix = "BMF_VehicleSpawnSet",
  vehicleCount = 3,
  start = { x = 70000, y = 0, z = 1000 },
  step = { x = 2000 },
})
```

The return value includes per-copy load responses and the exact world-load
commands. Use `scripts/snapshot-server-vehicles.ps1` or
`scripts/validate-bmf-vehicle-spawn-set-runtime.ps1` to prove the saved map
contains the expected vehicle-like dynamic actor graphs. Use
`scripts/export-vehicle-inventory.ps1` on the resulting saved BRDB or snapshot
JSON to render a readable list of cars on the map. The running-server snapshot
tool can also do this in the same SaveAs pass with `-ExportInventory`,
including a standalone `vehicle-inventory.txt` console-style report. When a
stage manifest is supplied with `-SpawnManifestJson`, the inventory correlates
planned staged world names back to observed labels such as `car-001` and records
the measured `deltaX`, `deltaY`, `deltaZ`, and match distance. Current canaries
use `-SpawnMatchMode X` because the saved vehicle center preserves enough X
separation for staged copies while Y/Z can drift after physics settlement.

## Command Route

Headless automation can drive the same API through the BMF command worker:

```text
Omegga.Bridge.BMF bmf.vehicles.spawnset prefix=BMF_VehicleSpawnSet count=3 startX=70000 stepX=2000 y=0 z=1000 yaw=0
Omegga.Bridge.BMF bmf.world.saveas name=BMF_AfterVehicleSpawnSet
Omegga.Bridge.BMF bmf.vehicles.snapshot name=BMF_VehicleSnapshot
```

`bmf.vehicles.spawnset` assumes the staged worlds already exist under
Brickadia's `Saved/Worlds` directory with names like
`BMF_VehicleSpawnSet_01`, `BMF_VehicleSpawnSet_02`, and
`BMF_VehicleSpawnSet_03`. It prints the requested count, loaded count, and one
line per staged world response.

`bmf.vehicles.snapshot` is the BMF-native command hook for "what cars are on the
map" automation. It saves the running world and tells the caller to run the
vehicle graph/inventory parsers. Use `scripts/snapshot-bmf-server-vehicles.ps1`
against a running bridge server to issue the command and produce
`vehicle-snapshot.json`, `vehicle-inventory.md`, `vehicle-inventory.csv`, and
`vehicle-inventory.txt`.

Validation:

- `L0 Static`: `stage-vehicle-spawn-set.ps1` validates each staged copy as a
  single vehicle-like graph.
- `L2 Headless Server`: `validate-server-vehicle-spawn-set.ps1` loads staged
  copies through bridge RPC, saves the map, parses the saved BRDB, and exports a
  Markdown/CSV/console-style vehicle inventory with staged-copy matches.
- `L2 Headless Server`: `validate-bmf-vehicle-spawn-set-runtime.ps1` loads the
  same staged copies through `BMF.vehicles.spawnSet`, saves the map, and parses
  the saved BRDB.
- `L2 Headless Server`: `validate-bmf-vehicle-spawn-set-command.ps1` loads the
  same staged copies through `Omegga.Bridge.BMF bmf.vehicles.spawnset`, saves the
  map through `bmf.world.saveas`, parses the saved BRDB, and exports a matched
  vehicle inventory.
- `L2 Headless Server`: `validate-bmf-vehicle-snapshot-command.ps1` uses
  `bmf.vehicles.snapshot` as the save trigger before parsing the saved BRDB and
  exporting the matched vehicle inventory.
- `L0 Static`: `export-vehicle-inventory.ps1` turns the saved BRDB or vehicle
  snapshot JSON into Markdown, CSV, and console-style vehicle inventory output.
- `L3 Live Player`: still required before claiming the cars are visually correct
  or drivable.
