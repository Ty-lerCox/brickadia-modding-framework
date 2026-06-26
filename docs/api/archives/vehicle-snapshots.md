# Vehicle Snapshots

**Labels:** `offline tooling`, `file-backed`, `L2 Headless`

## Who Should Read This?

Maintainers should use this page to prove vehicle-like graphs exist in saved worlds. Server operators should use it when reviewing snapshot evidence from validation runs.

Vehicle snapshot tooling turns saved-world dynamic actor graphs into evidence
that BMF can load, save, and inventory vehicle-like structures.

See [Vehicles](../vehicles.md) for the runtime facade.

## When To Use

| Need | Script |
| --- | --- |
| Summarize vehicle-like dynamic actor groups | `scripts/summarize-vehicle-graphs.ps1` |
| Render inventory reports | `scripts/export-vehicle-inventory.ps1` |
| Snapshot a bridge-connected server | `scripts/snapshot-server-vehicles.ps1` |
| Snapshot through BMF socket command route | `scripts/snapshot-bmf-server-vehicles.ps1` |
| Validate one or multiple loaded vehicles | `scripts/validate-server-vehicle-snapshot.ps1`, `scripts/validate-server-multi-vehicle-snapshot.ps1` |
| Validate runtime spawn sets | `scripts/validate-bmf-vehicle-spawn-set-runtime.ps1` |

Exact commands live in the
[CLI And Script Reference](../../reference/cli-and-script-reference.md#archive-and-vehicle-tooling).

## Output Shape

Snapshots treat resolved `BrickGridDynamicActor` groups with multiple related
grids as `dynamic-actor-vehicle-like`. Inventory reports include stable labels,
centers, dynamic actor group ids, entity/grid counts, body grid ids, and compact
console-style text. Running-server snapshots save the world first, then parse
the saved BRDB.

## Validation

Vehicle snapshot proof is tracked in
[API Validation Evidence](../../validation/api-validation.md#archives-vehicles-and-prefabs).
