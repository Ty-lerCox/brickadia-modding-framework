# Minigame Desired Definitions

**Labels:** `experimental`, `file-backed`, `L2 Headless`, `L5 Negative`

## Who Should Read This?

Plugin authors should use this page for BMF-owned desired minigame state. Maintainers should use it when changing persistence or fail-closed validation.

Desired definitions are BMF-owned target state for plugins such as CityRPG and
future BMF minigame producers. They do not create, delete, or mutate live
Brickadia minigames by themselves.

## When To Use

Use definitions when a plugin needs persistent desired minigame shape without
calling unsafe Brickadia minigame console commands.

## Lua API

```lua
BMF.minigames.define({
  name = "CityRPG",
  index = 0,
  teams = { "Police", "Criminal" },
  persistent = true,
  ownerOnly = false,
  includedBrickMode = "all",
})

local definitions = BMF.minigames.definitions()
local cityDefinition = BMF.minigames.definition({ name = "CityRPG", index = 0 })
local status = BMF.minigames.definitionStatus()
local reconcile = BMF.minigames.reconcileDefinitions({ name = "CityRPG", index = 0 })
```

Supported fields currently include `name`, `index`, `ruleset`, `owner`, `mode`,
`teams`, `persistent`, `ownerOnly`, `includedBrickMode`, `includedBricks`, and
`maxPlayers`.

Definitions persist at:

```text
ue4ss/main/Mods/BMF/runtime/minigames/definitions.json
```

## Server-Console Routes

```text
bmf.minigames.definitions.status
bmf.minigames.definitions.set name=CityRPG index=0 teams=Police,Criminal persistent=true owneronly=false includedbrickmode=all
bmf.minigames.definitions.list
bmf.minigames.definitions.get name=CityRPG index=0
bmf.minigames.definitions.delete name=CityRPG index=0 confirm=DELETE_MINIGAME_DEFINITION
bmf.minigames.definitions.reconcile name=CityRPG index=0
```

## Reconciliation

`BMF.minigames.reconcileDefinitions(query)` compares desired records with the
current BMF-owned observed minigame snapshot.

| Status | Meaning |
| --- | --- |
| `present` | Observed minigame matches by key, ruleset, or name/index and contains desired teams. |
| `missing` | No observed minigame matches. |
| `team-mismatch` | A minigame exists, but one or more desired teams are absent. |

Reconciliation is read-only and does not call Brickadia `Server.Minigames.*`
commands.
