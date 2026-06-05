# Archives API

Archive support is currently an offline/headless tooling lane, not an in-game
Lua runtime API. It wraps the BRDB parser from the Brickadia reverse-engineering
workspace so BMF can produce stable evidence about saved worlds.

## `scripts/describe-world-archive.ps1`

Describe one `.brdb` file:

```powershell
.\scripts\describe-world-archive.ps1 `
  -InputPath .\artifacts\overnight\20260603-215931\fixtures\threecars.brdb `
  -OutJson .\artifacts\local\threecars.describe.json
```

The result includes:

- archive size;
- entity count;
- entity type names and counts;
- dynamic actor graph count;
- dynamic actor group count;
- group centers and related entity/grid counts;
- raw parser output path.

## `scripts/validate-archive-fixtures.ps1`

Validate the known vehicle fixtures:

```powershell
.\scripts\validate-archive-fixtures.ps1
```

Current fixture expectations:

- `threecars.brdb`: 60 entities, 6 dynamic actor graphs, 3 dynamic actor groups.
- `couplecars.brdb`: 60 entities, 6 dynamic actor graphs, 3 dynamic actor groups.

## Validation Role

This is useful after headless `BMF.world.loadAdditive()` and
`BMF.world.saveAs()` tests. The saved output can be parsed and compared against
the requested fixture to prove that the expected vehicle graphs survived the
load/save cycle.

Runtime vehicle behavior, such as whether a player can drive the saved cars,
still requires `L3 Live Player` validation.

## `scripts/list-brick-assets.js`

Summarize the brick asset names used by a `.brdb` world or `.brz` prefab:

```powershell
node .\scripts\list-brick-assets.js `
  C:\path\to\BMF_ThreeCarsFixture.brdb `
  --out-json .\artifacts\local\three-cars-brick-assets.json
```

The report includes:

- `basicBrickAssetNames`, such as `B_Joint_Wheel_Micro`, `B_Seat`, and
  `B_1x1_Gate_WheelEngineSlim`;
- `proceduralBrickAssetNames`, such as `PB_DefaultMicroBrick`;
- `assetHistogram`, grouped by normalized asset name;
- `typeHistogram`, including procedural size keys where available;
- `entityTypeNames` and `componentTypeNames` from the archive global data.

This is the offline discovery path for brick-placement policy. It identifies
which names should go into `BrickAssetPlacementGuard` `deniedAssets` or
`allowedAssets` before any live native hook is wired.

## `scripts/summarize-vehicle-graphs.ps1`

Summarize vehicle-like dynamic actor groups from a saved `.brdb`:

```powershell
.\scripts\summarize-vehicle-graphs.ps1 `
  -InputPath .\artifacts\overnight\20260603-215931\fixtures\threecars.brdb `
  -OutJson .\artifacts\local\threecars.vehicle-snapshot.json
```

The result treats resolved `BrickGridDynamicActor` groups with multiple related
grids as `dynamic-actor-vehicle-like` and reports:

- group id and classification;
- center location;
- seed entity ids and types;
- related entity and grid ids;
- brick, component, and wire totals;
- the largest related grid as the likely vehicle body grid.

## `scripts/export-vehicle-inventory.ps1`

Render a vehicle snapshot as JSON, Markdown, CSV, and console-style text:

```powershell
.\scripts\export-vehicle-inventory.ps1 `
  -InputSnapshotJson .\artifacts\local\vehicle-snapshot.json `
  -OutJson .\artifacts\local\vehicle-inventory.json `
  -OutMarkdown .\artifacts\local\vehicle-inventory.md `
  -OutCsv .\artifacts\local\vehicle-inventory.csv `
  -OutText .\artifacts\local\vehicle-inventory.txt
```

The script can also start from a saved `.brdb` with `-InputBrdb`, in which case
it runs `summarize-vehicle-graphs.ps1` first. The output includes stable labels,
centers, dynamic actor group ids, entity/grid counts, brick/component/wire
totals, body grid ids, and a compact console-style listing in
`vehicle-inventory.txt`.

## `scripts/validate-vehicle-snapshot.ps1`

Validate vehicle snapshots for the known car fixtures:

```powershell
.\scripts\validate-vehicle-snapshot.ps1
```

Current fixture expectations:

- `threecars.brdb`: 3 vehicle-like groups and 4,584 vehicle bricks.
- `couplecars.brdb`: 3 vehicle-like groups and 4,584 vehicle bricks.
- each vehicle-like group has 16 related grids, 1,528 bricks, and a 1,254-brick
  body grid.

## `scripts/snapshot-server-vehicles.ps1`

Capture the current state of a bridge-connected server and identify vehicle-like
dynamic actor groups:

```powershell
.\scripts\snapshot-server-vehicles.ps1 `
  -BridgeDir .\artifacts\local\bridge-7821 `
  -SaveName BMF_ServerVehicleSnapshot `
  -ExportInventory `
  -InventoryLabelPrefix car
```

The script issues `BR.World.SaveAs` through the bridge, waits for the `.brdb`,
then runs `summarize-vehicle-graphs.ps1` against the saved world. This is the
headless inspection path for "what cars are currently on the map" after any
world-load or prefab-load canary. With `-ExportInventory`, the same pass also
writes `vehicle-inventory.json`, `vehicle-inventory.md`,
`vehicle-inventory.csv`, and `vehicle-inventory.txt` beside the snapshot.
Passing `-SpawnManifestJson` adds `spawnMatches` and per-vehicle planned-copy
fields so the report can say which staged world became each observed car label.
The current spawn-set canary uses `-SpawnMatchMode X` because the X lane remains
the stable identifier after server-side dynamic actor settlement.

## `scripts/snapshot-bmf-server-vehicles.ps1`

This variant uses the BMF command worker instead of directly issuing
`BR.World.SaveAs`:

```powershell
.\scripts\snapshot-bmf-server-vehicles.ps1 `
  -BridgeDir C:\path\to\bridge `
  -SaveName BMF_VehicleSnapshot `
  -InventoryLabelPrefix car
```

It invokes:

```text
Omegga.Bridge.BMF bmf.vehicles.snapshot name=<SaveName>
```

Then it parses the saved BRDB with `summarize-vehicle-graphs.ps1` and renders
the readable inventory with `export-vehicle-inventory.ps1`, including the
standalone `vehicle-inventory.txt` report. Use `-SpawnManifestJson` when the
snapshot should match observed car labels back to planned staged world names.

## `scripts/validate-server-vehicle-snapshot.ps1`

Validate the full headless server snapshot path:

```powershell
.\scripts\validate-server-vehicle-snapshot.ps1 `
  -Port 7821 `
  -OutJson .\artifacts\local\server-vehicle-snapshot-canary.json
```

The canary stages `Car.brz`, starts a disposable bridge server, loads the staged
world additively, snapshots the running server with `SaveAs`, and asserts the
saved map contains one vehicle-like group with 1,528 bricks and a 1,254-brick
body grid.

## `scripts/validate-server-multi-vehicle-snapshot.ps1`

Validate a running-server snapshot containing multiple cars:

```powershell
.\scripts\validate-server-multi-vehicle-snapshot.ps1 `
  -Port 7822 `
  -OutJson .\artifacts\local\server-multi-vehicle-snapshot-canary.json
```

The canary stages the known `threecars.brdb` fixture, loads it additively into a
disposable bridge server, snapshots the running map, and asserts three
vehicle-like groups with 4,584 total vehicle bricks.

Current duplicate-load caveat: loading the exact same staged single-car BRDB
twice is not isolated. Local evidence in
`server-duplicate-car-load-coalescence.json` shows both `LoadAdditive` calls can
succeed while the saved map coalesces the two loads into one dynamic actor graph
with doubled brick/component/wire totals.

For dynamic-actor slice sources, duplicate staging now has an experimental
remap path. Use `scripts/remap-staged-vehicle-brdb.js` on the second copy, then
load the original and remapped bundle. The remapper offsets saved persistent
entity ids, brick grid folder ids, component joint references, microchip grid
references, and remote wire grid references. It intentionally leaves
`OwnerIndices` and `OriginalOwnerIndices` unchanged because those are
Brickadia owner-array indices; remapping them can crash the loader.

`scripts/validate-server-remapped-duplicate-vehicle-snapshot.ps1` proves the
current graph-closure single-car slice plus a remapped copy can be loaded into a
disposable server and saved back as two isolated vehicle-like groups:

- `40` saved entities;
- `33` brick grids;
- `2` dynamic actor groups;
- `2` vehicle-like groups;
- `3,056` vehicle bricks;
- `246` components;
- `206` wires.

`scripts/validate-server-vehicle-spawn-set.ps1` generalizes that proof for a
small spawn set. It builds `VehicleCount` staged copies from the graph-closure
single-car slice, leaves copy `1` unchanged, remaps later copies by a stable id
stride, loads each copy at a different coordinate, saves the running map, and
asserts isolated vehicle-like groups. The current L2 canary with
`-VehicleCount 3` reports:

- `60` saved entities;
- `49` brick grids;
- `3` dynamic actor groups;
- `3` vehicle-like groups;
- `4,584` vehicle bricks;
- `369` components;
- `309` wires.

The reusable staging half is `scripts/stage-vehicle-spawn-set.ps1`. It writes a
manifest with staged world names, positions, remap reports, and per-copy static
vehicle snapshots. `BMF.vehicles.spawnSet` consumes that manifest shape from Lua
and is covered by `scripts/validate-bmf-vehicle-spawn-set-runtime.ps1`.

Vehicle inventory can consume that same stage manifest. When
`scripts/snapshot-server-vehicles.ps1 -ExportInventory` is given
`-SpawnManifestJson`, the report adds `spawnMatches` plus per-vehicle
`plannedWorldName`, `plannedCopyIndex`, and coordinate deltas.

Raw `Car.brz`-derived staged worlds are different: they have 19 entities and a
body grid `1` without the companion entity that the graph-closure slice
preserves. A remapped duplicate of that raw BRZ-derived bundle can leave the
remapped dynamic actors disconnected from the body grid, so use the
dynamic-actor slice source for duplicate spawned-car tests.

## `scripts/stage-brz-prefab.ps1`

Stage one `.brz` prefab as a server-loadable `.brdb` world bundle:

```powershell
.\scripts\stage-brz-prefab.ps1 `
  -InputBrz ..\Brickadia\Car.brz `
  -OutputBrdb .\artifacts\local\Car.world.brdb `
  -StageToServerWorlds `
  -WorldName BMF_CarPrefab `
  -Force
```

The wrapper runs the Brickadia reverse-engineering helpers for prefab diagnosis,
hash reporting, BRZ-to-BRDB conversion, and static archive description. By
default it leaves prefab coordinates unbaked so `BR.World.LoadAdditive` can
choose placement later.

`-PatchPhysicsMetadata` is diagnostic-only. Local probes against `Car.brz`
showed that forcing `Meta/Prefab.json` to `bIsPhysicsGrid=true` can crash the
dedicated server while loading dynamic prefab metadata at `TVariant.h:148`.

## `scripts/validate-brz-prefab-staging.ps1`

Run the staged BRZ prefab through a disposable headless server:

```powershell
.\scripts\validate-brz-prefab-staging.ps1 `
  -Port 7818 `
  -OutJson .\artifacts\local\brz-prefab-staging-canary.json
```

The script:

- converts `Car.brz` to a `.brdb` world bundle without patching physics
  metadata;
- copies the staged world into Brickadia `Saved/Worlds`;
- starts a bridge-enabled dedicated server;
- runs `BR.World.LoadAdditive` at the requested coordinates;
- runs `BR.World.SaveAs`;
- stops the server in a `finally` block;
- parses the saved BRDB and asserts the vehicle graph survived.

Current L2 expectations:

- `19` saved entities;
- `1` resolved dynamic actor group;
- `16` brick grids;
- `16` related brick grids;
- `1,528` bricks;
- `123` components;
- `103` wires;
- body grid `1` retains `1,254` bricks.

## `scripts/capture-dynamic-actor-graph.ps1`

Capture one vehicle-like dynamic actor group from a saved `.brdb`:

```powershell
.\scripts\capture-dynamic-actor-graph.ps1 `
  -InputPath .\artifacts\overnight\20260603-215931\fixtures\threecars.brdb `
  -GroupId 1 `
  -OutJson .\artifacts\local\threecars.group1.capture.json
```

You can select by `-GroupId` or by a known `BrickGridDynamicActor` entity id
with `-EntityId`.

The result includes:

- selected dynamic actor group id;
- seed actor entity ids;
- related entity ids and grid ids;
- brick, component, and wire chunk paths;
- aggregate brick/component/wire counts for the selected graph;
- entity chunk analysis showing whether a standalone slice can copy files or
  must rewrite structure-of-arrays rows.

For the current three-car fixture, each car's grid directories are isolated, but
all entities live in `World/0/Entities/Chunks/0_0_0.mps`. That means a real
single-car BRDB/BRZ slicer cannot just delete files; it must rewrite the entity
chunk rows and indexes while preserving the selected dynamic actor graph.

## `scripts/validate-dynamic-actor-graphs.ps1`

Validate the known vehicle fixtures at graph-capture level:

```powershell
.\scripts\validate-dynamic-actor-graphs.ps1
```

Current fixture expectations for group `1`:

- `20` related entities, including the saved entity whose persistent id matches
  the selected body grid id;
- `16` related brick grids;
- `16` brick chunks;
- `12` component chunks;
- `2` wire chunks;
- entity chunk row rewrite is required for a true single-car archive slice.

## `scripts/slice-dynamic-actor-brdb.js`

Build an experimental single dynamic-actor BRDB from a saved world:

```powershell
node .\scripts\slice-dynamic-actor-brdb.js `
  .\artifacts\overnight\20260603-215931\fixtures\threecars.brdb `
  .\artifacts\local\threecars.entity20.slice.brdb `
  --entity-id 20 `
  --force
```

The slicer currently:

- resolves the selected dynamic actor graph;
- copies the source `.brdb`;
- rewrites mixed entity chunk rows down to the selected graph;
- updates `World/0/Entities/ChunkIndex.mps`;
- prunes unrelated grid file rows from the BRDB file table.

This is still experimental. Passing static validation means the sliced BRDB can
be parsed and retains one coherent dynamic actor group. The graph closure must
include the saved entity whose persistent id matches the selected body grid id;
without that companion entity Brickadia loads only the small child grids and the
dynamic actors no longer resolve back to the body graph after save.

## `scripts/validate-dynamic-actor-slices.ps1`

Validate the current static slicer against the three-car fixture:

```powershell
.\scripts\validate-dynamic-actor-slices.ps1
```

Current fixture expectation:

- selecting entity `20` from `threecars.brdb` produces a parseable single-group
  BRDB with `20` entities, `2` raw dynamic actor graphs, and `1` dynamic actor
  group.

## `scripts/validate-dynamic-actor-slice-additive.ps1`

Run the current dynamic-actor slice through a disposable headless server:

```powershell
.\scripts\validate-dynamic-actor-slice-additive.ps1 `
  -Port 7815 `
  -OutJson .\artifacts\local\dynamic-actor-slice-additive-canary.json
```

The script:

- builds the static single-car slice;
- copies it into the Brickadia saved-world directory;
- starts a bridge-enabled dedicated server;
- runs `BR.World.LoadAdditive`;
- runs `BR.World.SaveAs`;
- stops the server in a `finally` block;
- parses the saved BRDB and asserts the vehicle graph survived.

Current L2 expectations:

- `20` saved entities;
- `1` resolved dynamic actor group;
- `16` related brick grids;
- `1,528` bricks;
- `123` components;
- `103` wires;
- body grid `2` retains `1,254` bricks.

## L2 Slice History

The headless slice probe produced these stages:

- initial slice: rejected by Brickadia because `PhysicsLockedFlags` was too
  short;
- fixed bitflags: rejected because type-specific dynamic property bytes were
  missing;
- tail-preserving slice: loaded additively and saved, but initially lost the
  large body grid because the parser/slicer pruned the grid-id companion entity;
- graph-closure v2: includes that companion entity and passes the headless
  additive load/save canary.

Runtime vehicle behavior, such as whether a player can enter and drive the
saved car, still requires `L3 Live Player` validation.

## `scripts/remap-staged-vehicle-brdb.js`

Build an experimental id-remapped copy of a staged single-car BRDB:

```powershell
node .\scripts\remap-staged-vehicle-brdb.js `
  .\artifacts\overnight\20260603-215931\dynamic-actor-slice-additive\dynamic-actor-slices\threecars.entity20.slice.brdb `
  .\artifacts\local\threecars.entity20.remapped.brdb `
  --entity-offset 100000 `
  --grid-offset 100000 `
  --force
```

The output should still parse as one vehicle-like graph, but with shifted
persistent entity ids and grid ids.

## `scripts/stage-vehicle-spawn-set.ps1`

Build a staged multi-copy vehicle spawn set without starting a server:

```powershell
.\scripts\stage-vehicle-spawn-set.ps1 `
  -VehicleCount 3 `
  -WorldNamePrefix BMF_VehicleSpawnSet `
  -StartX 70000 `
  -StepX 2000 `
  -LoadZ 1000 `
  -StageToServerWorlds `
  -OutJson .\artifacts\local\vehicle-spawn-set-stage.json
```

The script uses the graph-closure single-car dynamic-actor slice when available,
copies vehicle `1` unchanged, remaps later copies with non-overlapping
persistent entity and grid ids, validates each copy as one vehicle-like graph,
and optionally copies the generated BRDBs into Brickadia `Saved/Worlds`.

## `scripts/validate-server-remapped-duplicate-vehicle-snapshot.ps1`

Validate duplicate staged-car isolation in a disposable server:

```powershell
.\scripts\validate-server-remapped-duplicate-vehicle-snapshot.ps1 `
  -Port 7824 `
  -OutJson .\artifacts\local\server-remapped-duplicate-vehicle-snapshot-canary.json
```

The canary uses the graph-closure single-car dynamic-actor slice when available,
remaps a second copy, loads both bundles, saves the running map, and asserts
that the saved BRDB contains two isolated vehicle-like groups.

## `scripts/validate-server-vehicle-spawn-set.ps1`

Validate a multi-copy remapped vehicle spawn set in a disposable server:

```powershell
.\scripts\validate-server-vehicle-spawn-set.ps1 `
  -VehicleCount 3 `
  -Port 7825 `
  -OutJson .\artifacts\local\server-vehicle-spawn-set-canary.json
```

The canary uses the graph-closure single-car dynamic-actor slice when available,
creates multiple staged copies with non-overlapping persistent entity and grid
ids, loads each copy at a different coordinate, saves the running map, and
asserts that the saved BRDB contains the requested number of isolated
vehicle-like groups. It also passes the stage manifest into the integrated
inventory exporter and asserts every staged world is matched back to one
observed vehicle label.

## `scripts/validate-bmf-vehicle-spawn-set-runtime.ps1`

Validate the BMF Lua vehicle spawn-set facade in a disposable server:

```powershell
.\scripts\validate-bmf-vehicle-spawn-set-runtime.ps1 `
  -VehicleCount 3 `
  -Port 7826 `
  -OutJson .\artifacts\local\bmf-vehicle-spawn-set-runtime-canary.json
```

The canary stages the vehicle copies, installs a temporary BMF plugin that calls
`BMF.vehicles.spawnSet({ copies = ... })`, saves the running map, and asserts
that the saved BRDB contains the requested number of isolated vehicle-like
groups.
