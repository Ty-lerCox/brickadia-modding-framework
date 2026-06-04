# Players API

BMF player APIs are split between wrapper behavior that can be validated with
static fixtures and runtime behavior that requires a connected Brickadia player.

## `BMF.players.list()`

```lua
local result = BMF.players.list()
if result.ok then
  for _, player in ipairs(result.data.players) do
    BMF.log(player.displayName .. " " .. player.uuid)
  end
end
```

The current live adapter only proves an empty list on a headless server. Real
identity fields still require a connected player.

Server-console command route:

```text
Omegga.Bridge.BMF bmf.players.list
```

On a headless no-player server, the current command canary expects
`players_count=0`. This is a safety proof that the API does not require a
persisting player controller for the empty-list case.

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
Omegga.Bridge.BMF bmf.players.find query=<uuid-or-name>
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
Omegga.Bridge.BMF bmf.players.getname query=<uuid-or-name>
```

## Validation Split

- Empty player listing can be proven at `L2 Headless`.
- Name normalization, query matching, missing-field handling, and permission map
  interpretation can be tested with `L0 Static` fixtures.
- `scripts/validate-bmf-player-messaging.ps1` proves direct-record name
  resolution, exact lookup, UUID lookup, partial display-name lookup, and
  empty-server `PLAYER_NOT_FOUND` command behavior.
- Real UUID, username, display name, health, position, pawn, controller, and
  role-effect reads require `L3 Live Player`.
- Whisper delivery, join/leave events, health mutation, avatar mutation, and
  tool policy require `L3 Live Player` or higher.

## Fixtures

Source fixtures live in `tests/fixtures/players/`.

- `empty.json`: expected output for a headless server with no players.
- `one-player.json`: synthetic complete record for wrapper tests.
- `malformed.json`: invalid and partial records for hardening tests.

Run:

```powershell
.\scripts\validate-player-fixtures.ps1
```

The validator writes a canary JSON when `-OutJson` is supplied.
