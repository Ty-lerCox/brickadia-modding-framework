# Prefab Staging

**Labels:** `offline tooling`, `file-backed`, `L2 Headless`

## Who Should Read This?

Maintainers should use this page when preparing prefab archives for server-loadable staged worlds. Plugin authors should use the Prefabs API after staging is complete.

Prefab staging prepares `.brz` files as server-loadable `.brdb` world bundles.
The runtime Lua path loads staged worlds; it does not rewrite archives inside
UE4SS.

See [Prefabs](../prefabs.md) for the runtime API.

## When To Use

| Need | Script |
| --- | --- |
| Convert one `.brz` into a staged world | `scripts/stage-brz-prefab.ps1` |
| Prove the staged prefab loads and saves | `scripts/validate-brz-prefab-staging.ps1` |

Exact commands live in the
[CLI And Script Reference](../../reference/cli-and-script-reference.md#prefab-and-dynamic-actor-staging).

The wrapper runs Brickadia reverse-engineering helpers for prefab diagnosis,
hash reporting, BRZ-to-BRDB conversion, and static archive description. By
default it leaves prefab coordinates unbaked so `BR.World.LoadAdditive` can
choose placement later.

!!! warning
    `-PatchPhysicsMetadata` is diagnostic-only. Local probes against `Car.brz`
    showed that forcing `Meta/Prefab.json` to `bIsPhysicsGrid=true` can crash
    the dedicated server while loading dynamic prefab metadata.

## Validation

Prefab staging proof is tracked in
[API Validation Evidence](../../validation/api-validation.md#archives-vehicles-and-prefabs).
