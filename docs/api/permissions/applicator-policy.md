# Applicator Policy

**Labels:** `experimental hooks`, `unsafe-native`, `L2 Headless`, `L5 Negative`

Applicator policy controls component placement attempts such as `SpawnItem` and
Brickadia's reflected `ItemSpawn` naming.

For hook flow, see
[Hooked Brickadia Events Into Lua](../../architecture/architecture-patterns.md#8-hooked-brickadia-events-into-lua).

## Who Should Read This?

Plugin authors should use this when building component restrictions. Server
operators should use it to understand why role-file policy alone is not enough.
BMF maintainers should use it when updating Applicator hook or native blocker
behavior.

## When To Use

Use this API when a plugin or native handoff path has an Applicator component
name and needs a Lua policy decision.

## Lua API

`BMF.permissions.evaluateApplicatorComponentAccess(options)` denies configured
component names while allowing known safe components:

```lua
local checked = BMF.permissions.evaluateApplicatorComponentAccess({
  component = "ItemSpawn",
  deniedComponents = { "SpawnItem", "ItemSpawn" },
})
```

Returned fields include `allowed`, `decision`, `component`, `componentKey`,
`matchedComponent`, `actorUuid`, and `actorName`. Class-like names are
normalized by suffix, so `/Script/Brickadia.BRSpawnItemComponent` still matches
a `SpawnItem` deny entry.

`BMF.tools.onApplicatorComponentApply(handler, options)` registers a Lua handler
for a future safe Applicator component event source:

```lua
local hook = BMF.tools.onApplicatorComponentApply(function(event)
  return BMF.permissions.evaluateApplicatorComponentAccess({
    component = event.component,
    deniedComponents = { "SpawnItem", "ItemSpawn" },
  })
end)
```

The event table can include `component`, `componentAddress`,
`componentFullName`, `componentClassName`, `componentCandidates`,
`contextAddress`, and `contextFullName`.

## Hook State

Inspect current hook and cache state:

```lua
local status = BMF.tools.applicator.status({ refresh = true })
```

Server-console routes:

```text
bmf.tools.applicator.status refresh=true
bmf.tools.applicator.refresh
```

After a server restart, refresh the native Applicator blocker for the new
process:

```powershell
.\scripts\sync-applicator-blocker-native-hook.ps1
```

`framework/ue4ss/Mods/BMF/plugins/NoSpawnItemApplicator` owns player/role feedback and writes allowed
contexts back into the native control file when policy permits a retry.

!!! warning
    The direct UE4SS Lua hook for `ABRTool_Applicator.ServerAddComponent` is
    disabled by default on `PC-Shipping-CL13530` because struct marshaling
    crashed before the BMF callback could run. The working live path is the
    experimental native Applicator blocker plus Lua policy feedback.
