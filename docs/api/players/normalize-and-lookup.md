# Normalize And Lookup

Use the normalization and lookup helpers to work with safe player records
instead of raw live game objects.

**Labels:** `experimental`, `safe-cache`, `L2 Headless`

## Who Should Read This?

Plugin authors should use this page when converting external player data into
the BMF shape or resolving a player by UUID/name. Maintainers should use it when
changing the normalized player record contract.

## `BMF.players.normalize(record)`

Normalizes one raw or synthetic player record into the BMF player shape.

```lua
local normalized = BMF.players.normalize(rawPlayer)
if normalized.ok then
  BMF.log(normalized.data.player.displayName)
end
```

Normalized player records use this shape where data is available:

```json
{
  "id": "11111111-1111-4111-8111-111111111111",
  "uuid": "11111111-1111-4111-8111-111111111111",
  "username": "OriginalBuilder",
  "playerName": "OriginalBuilder",
  "displayName": "Build Lead",
  "originalName": "OriginalBuilder",
  "roles": ["Admin"],
  "permissions": {
    "BR.Permission.Building.Applicator": true,
    "BR.Permission.SpawnItems": false
  },
  "pingMs": 32,
  "onlineTimeMs": 125000,
  "address": "127.0.0.1:7777",
  "health": 100,
  "position": { "x": 128.0, "y": -64.0, "z": 320.0 },
  "playerStatePath": "BP_PlayerState_C_2147483648",
  "controllerPath": "BP_PlayerController_C_1073741824",
  "controllerAvailable": true
}
```

## `BMF.players.normalizeList(records)`

Normalizes an array of records and separates invalid entries:

```lua
local normalized = BMF.players.normalizeList(rawPlayers)
BMF.log("valid players=" .. tostring(#normalized.data.players))
BMF.log("invalid players=" .. tostring(#normalized.data.invalid))
```

## `BMF.players.find(records, query)`

Searches normalized records by UUID, username, player name, or display name.

```lua
local found = BMF.players.find(rawPlayers, "OriginalBuilder")
```

The current implementation also matches `originalName`, `playerStatePath`, and
`controllerPath`, with partial name matching for username, player name, display
name, and original name.

## `BMF.players.find(query)`

When called with one argument, searches the current `BMF.players.list()` output:

```lua
local found = BMF.players.find("OriginalBuilder")
```

On a no-player headless server this safely returns `PLAYER_NOT_FOUND` with
`adapter = "headless-empty"`.

Server-console command route:

```text
bmf.players.find query=<uuid-or-name>
```

## `BMF.players.resolve(player)`

Accepts either a direct player-like table or a query string. Direct tables are
normalized without reading live game objects; strings search the current player
list.

## `BMF.players.getName(player)`

Returns the stable identity fields BMF can derive from a direct record or lookup
result:

```lua
local names = BMF.players.getName(rawPlayer)
if names.ok then
  BMF.log(names.data.displayName .. " / " .. names.data.originalName)
end
```

Server-console command route:

```text
bmf.players.getname query=<uuid-or-name>
```
