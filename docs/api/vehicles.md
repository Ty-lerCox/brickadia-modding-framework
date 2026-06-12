# Vehicles

**Labels:** `experimental`, `file-backed`, `L2 Headless`, `L3 pending`

## Who Should Read This?

Plugin authors should use this page for staged vehicle spawn sets. Maintainers should use it when changing vehicle staging, snapshots, or inventory evidence.

Vehicle APIs are experimental and server-side only.

The current safe path is split in two:

1. Build staged vehicle world bundles outside Lua.
2. Load those staged worlds from BMF Lua through `BR.World.LoadAdditive`.

Runtime Lua does not rewrite `.brdb` archives. Stage vehicle spawn sets first
with the scripts listed in the
[CLI And Script Reference](../reference/cli-and-script-reference.md#prefab-and-dynamic-actor-staging).
The runtime API consumes those staged world names and positions.

## Examples

- [SpawnVehicleSet](../examples/spawn-vehicle-set.md): complete plugin that
  loads multiple staged vehicle worlds with separated positions.

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
commands. Snapshot and inventory scripts can prove that the saved map contains
the expected vehicle-like dynamic actor graphs; see the
[CLI And Script Reference](../reference/cli-and-script-reference.md#archive-and-vehicle-tooling).

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
vehicle graph/inventory parsers.

Validation proof is tracked in
[API Validation Evidence](../validation/api-validation.md#archives-vehicles-and-prefabs).
