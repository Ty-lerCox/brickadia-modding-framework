# Dynamic Actors

**Labels:** `offline tooling`, `experimental`, `L0 Static`, `L2 Headless`

## Who Should Read This?

Maintainers should use this page for vehicle-like graph capture, slicing, and remapping. Plugin authors should treat this as staging evidence, not a runtime Lua API.

Dynamic actor tooling captures, slices, and remaps vehicle-like graph closures
from saved worlds. This is the research and staging layer behind isolated
multi-vehicle load tests.

## When To Use

| Need | Script |
| --- | --- |
| Capture one vehicle-like graph | `scripts/capture-dynamic-actor-graph.ps1` |
| Validate captured fixture graphs | `scripts/validate-dynamic-actor-graphs.ps1` |
| Build a single dynamic actor BRDB | `scripts/slice-dynamic-actor-brdb.js` |
| Validate static slices | `scripts/validate-dynamic-actor-slices.ps1` |
| Validate additive load/save of a slice | `scripts/validate-dynamic-actor-slice-additive.ps1` |
| Remap ids for duplicate staged copies | `scripts/remap-staged-vehicle-brdb.js` |
| Stage a multi-copy vehicle set | `scripts/stage-vehicle-spawn-set.ps1` |

Exact commands live in the
[CLI And Script Reference](../../reference/cli-and-script-reference.md#prefab-and-dynamic-actor-staging).

## Capture A Graph

You can select by `-GroupId` or by a known `BrickGridDynamicActor` entity id
with `-EntityId`. The capture records selected actor ids, related entities and
grids, brick/component/wire chunks, aggregate counts, and whether entity chunk
rows must be rewritten.

## Slice A Graph

The slicer resolves the selected dynamic actor graph, copies the source BRDB,
rewrites mixed entity chunk rows, updates `World/0/Entities/ChunkIndex.mps`,
and prunes unrelated grid file rows.

!!! note
    Passing static validation means the sliced BRDB parses and retains one
    coherent dynamic actor group. It does not prove runtime gameplay behavior.

## Validate Slices

The headless additive canary builds the slice, copies it into the saved-world
directory, starts a bridge-enabled server, loads the staged world, saves the
map, and asserts that the vehicle graph survived.

## Remap And Stage Spawn Sets

The remapper offsets saved persistent entity ids, brick grid folder ids,
component joint references, microchip grid references, and remote wire grid
references. It intentionally leaves owner-array indices unchanged because those
are Brickadia owner-array indices.

Vehicle spawn-set staging writes a manifest with staged world names and load
positions. Runtime Lua consumes that staged output through
`BMF.vehicles.spawnSet`.

## Slice History

The useful historical checkpoints are:

- initial slice: rejected because `PhysicsLockedFlags` was too short;
- fixed bitflags: rejected because type-specific dynamic property bytes were
  missing;
- tail-preserving slice: loaded and saved, but initially lost the large body
  grid;
- graph-closure v2: includes the companion entity whose persistent id matches
  the selected body grid id and passes the headless additive load/save canary.
