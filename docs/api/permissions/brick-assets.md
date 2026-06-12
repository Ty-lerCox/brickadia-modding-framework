# Brick Asset Policy

**Labels:** `policy`, `experimental hooks`, `L2 Headless`, `L5 Negative`

Brick asset policy evaluates role-aware access to placeable Brickadia assets
such as wheel joints, vehicle engines, and seats.

## Who Should Read This?

Plugin authors should use this when building placement restrictions. Server
operators should use it to review denied assets and bypass roles. BMF
maintainers should use it when adding a future cancellable placement/paste hook.

## When To Use

Use this API when an adapter, canary, or future native hook can identify the
incoming brick asset before Brickadia mutates the world.

## Lua API

`BMF.permissions.evaluateBrickAssetAccess(options)` evaluates role-aware policy
for Brickadia brick asset names:

```lua
local checked = BMF.permissions.evaluateBrickAssetAccess({
  asset = "B_Joint_Wheel_Micro",
  actor = { uuid = playerUuid, roles = { "Default" } },
  deniedAssets = {
    "B_Joint_Wheel_Micro",
    "B_1x1_Gate_WheelEngineSlim",
    "B_Seat",
  },
  adminRoles = { "Owner", "Admin" },
})
```

Returned fields include `allowed`, `decision`, `asset`, `assetKey`,
`matchedAsset`, `roles`, and `matchedRole`.

`deniedAssets` and `allowedAssets` accept comma/pipe-delimited strings or Lua
arrays. Matching is case-insensitive and supports `*` at the start or end of a
rule.

## Example Commands

`examples/BrickAssetPlacementGuard` exposes:

```text
bmf.brickassetguard.status
bmf.brickassetguard.check asset=B_Joint_Wheel_Micro roles=Default
```

Run the policy and plugin command canary:

```powershell
.\scripts\validate-bmf-brick-asset-policy.ps1
```

!!! note
    Brick asset enforcement is policy-ready, not live-enforced. The missing
    layer is a cancellable placement/paste hook that can resolve the incoming
    asset or uploaded prefab hash before Brickadia mutates the world.
