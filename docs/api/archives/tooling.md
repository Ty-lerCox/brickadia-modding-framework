# Archive Offline Tooling

**Labels:** `offline tooling`, `file-backed`, `L0 Static`

## Who Should Read This?

Maintainers should use this page to inspect saved-world and prefab archives outside the running server. Plugin authors usually only need the runtime API pages that consume staged output.

These tools inspect `.brdb` worlds and `.brz` prefabs outside the running
Brickadia process. Use them to build evidence before a BMF runtime canary loads
or mutates a world.

## When To Use

| Need | Script |
| --- | --- |
| Describe entity and dynamic actor counts | `scripts/describe-world-archive.ps1` |
| Validate known archive fixtures | `scripts/validate-archive-fixtures.ps1` |
| List brick asset names for placement policy | `scripts/list-brick-assets.js` |

Exact commands live in the
[CLI And Script Reference](../../reference/cli-and-script-reference.md#archive-and-vehicle-tooling).

## Output Shape

Archive reports include archive size, entity counts, entity type names, dynamic
actor graph counts, dynamic actor group counts, group centers, related entity
and grid counts, asset histograms, and parser output. Brick asset reports feed
[brick asset policy](../permissions/brick-assets.md).

## Canary Usage

Use archive inspection after headless `BMF.world.loadAdditive()` and
`BMF.world.saveAs()` tests. The saved output can be parsed and compared against
the requested fixture to prove that expected vehicle graphs survived the
load/save cycle. Current proof is tracked in
[API Validation Evidence](../../validation/api-validation.md#archives-vehicles-and-prefabs).
