# Archives API

Archive support is an offline/headless tooling lane, not an in-game Lua runtime
API. It wraps Brickadia saved-world and prefab parsers so BMF can produce stable
evidence about loaded worlds, vehicles, brick assets, and staged prefabs.

For validation coverage, see
[API Validation Evidence](../validation/api-validation.md#archives-vehicles-and-prefabs).

**Labels:** `offline tooling`, `file-backed`, `L0 Static`, `L2 Headless`

## Who Should Read This?

Plugin authors should use this page only after a staged world or prefab has
already been prepared. Server operators and maintainers should use it for
offline evidence, snapshots, and validation artifacts.

## When To Use

| Goal | Start here |
| --- | --- |
| Describe `.brdb` files or list brick assets | [Offline Tooling](archives/tooling.md) |
| Snapshot vehicles from a saved or running world | [Vehicle Snapshots](archives/vehicle-snapshots.md) |
| Convert and stage `.brz` prefabs | [Prefab Staging](archives/prefab-staging.md) |
| Slice or remap dynamic actor graphs | [Dynamic Actors](archives/dynamic-actors.md) |

## Examples

- [LoadCarBrz](../examples/load-car-brz.md): consumes a staged archive after
  offline tools have prepared it.
- [LoadThreeCars](../examples/load-three-cars.md): saves a loaded staged
  world so archive validators can inspect the result.

## API Pages

- [Offline Tooling](archives/tooling.md): archive description, fixture checks,
  and brick asset inventory.
- [Vehicle Snapshots](archives/vehicle-snapshots.md): dynamic actor vehicle
  summaries, server snapshots, inventory export, and vehicle spawn-set evidence.
- [Prefab Staging](archives/prefab-staging.md): BRZ-to-BRDB staging and headless
  load/save checks.
- [Dynamic Actors](archives/dynamic-actors.md): graph capture, slicing, remap,
  and duplicate-vehicle isolation.

## Result Shape

Archive scripts write JSON evidence first and optional Markdown, CSV, or text
reports when a human-readable inventory is useful. Runtime Lua should consume
the staged worlds through [World](world.md), [Prefabs](prefabs.md), or
[Vehicles](vehicles.md), not parse archives inside UE4SS.

!!! note
    Runtime vehicle behavior, such as whether a player can enter and drive a
    saved car, still requires connected-player validation after the archive
    evidence passes.
