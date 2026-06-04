# Players API

BMF player APIs use safe normalized records. The primary live identity path is
BMF-native: configure `brickadiaSavedDir` and BMF will read Brickadia's own
`Saved/Logs/Brickadia.log` plus `Saved/Server/PlayerNameCache.json`. The
external `runtime/players.json` cache remains as an optional adapter path for
Omegga or another launcher/test harness.

## `BMF.players.list()`

```lua
local result = BMF.players.list()
if result.ok then
  for _, player in ipairs(result.data.players) do
    BMF.log(player.displayName .. " " .. player.uuid)
  end
end
```

`BMF.players.list()` prefers native Brickadia saved/log identity when
`brickadiaSavedDir` is configured. If no native players are found, it falls back
to `runtime/players.json` when present. It also reports the live controller
count discovered through the safe `FindFirstOf` controller route. With no native
identity or cache, it safely returns an empty player list.

Server-console command route:

```text
Omegga.Bridge.BMF bmf.players.list
```

On a headless no-player server, the current command canary expects
`players_count=0`. With an identity cache, the command also prints
`known_players_count`, `live_controllers_count`, and one `player_<n>=...` line
per known player.

## `BMF.players.sync(records, options)`

Syncs safe external records into `runtime/players.json`. This is an optional
fallback/integration route for Omegga or another launcher-side adapter to feed
BMF usernames, display names, UUIDs, controller paths, and player-state paths
without reading live UE4SS properties. BMF core does not require this cache when
the native Brickadia saved/log adapter is configured.

Omegga raw player arrays are accepted:

```lua
BMF.players.sync({
  { "OriginalBuilder", "Build Lead", "11111111-1111-4111-8111-111111111111", "BP_PlayerController_C_1073741824", "BP_PlayerState_C_2147483648" }
}, {
  source = "omegga.players.raw",
  adapter = "omegga-cache"
})
```

Server-console command route:

```text
Omegga.Bridge.BMF bmf.players.sync players=[["OriginalBuilder","Build Lead","11111111-1111-4111-8111-111111111111","BP_PlayerController_C_1073741824","BP_PlayerState_C_2147483648"]]
```

The optional Omegga feeder lives at
`integrations/omegga/bmf-player-sync/`. Configure its `commandDir` to the active
`Mods/BMF/runtime/commands` directory, or set `OMEGGA_BMF_COMMAND_DIR`, and it
will queue this sync automatically on Omegga player-list changes.

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

## `BMF.players.summary(player)`

Resolves one cached player and includes lobby counts:

```lua
local summary = BMF.players.summary("OriginalBuilder")
if summary.ok then
  BMF.log("username=" .. summary.data.username)
  BMF.log("known players=" .. tostring(summary.data.knownPlayerCount))
  BMF.log("live controllers=" .. tostring(summary.data.liveControllerCount))
end
```

If the cache contains exactly one player, an empty query resolves that one
record. Otherwise a query is required.

Server-console command route:

```text
Omegga.Bridge.BMF bmf.players.summary target=OriginalBuilder
```

## `BMF.players.whisperSummary(player)`

Builds a compact summary and sends it through `BMF.chat.whisper`:

```lua
BMF.players.whisperSummary("OriginalBuilder")
```

The whispered text is intentionally simple:

```text
BMF player summary: username=OriginalBuilder displayName=Build Lead id=11111111-1111-4111-8111-111111111111 knownPlayers=1 liveControllers=1
```

Server-console command route:

```text
Omegga.Bridge.BMF bmf.players.summary target=OriginalBuilder whisper=true
```

## Validation Split

- Empty player listing can be proven at `L2 Headless`.
- Native Brickadia saved/log identity discovery is BMF core behavior and does
  not require Omegga. It should be validated against `Brickadia.log` plus
  `PlayerNameCache.json` fixtures and then confirmed with `L3 Live Player`.
- Cache sync, normalization, summary formatting, and lookup can be proven from
  `L0 Static` and `L2 Headless` command-worker tests.
- Name normalization, query matching, missing-field handling, and permission map
  interpretation can be tested with `L0 Static` fixtures.
- `scripts/validate-bmf-player-messaging.ps1` proves direct-record name
  resolution, exact lookup, UUID lookup, partial display-name lookup, and
  empty-server `PLAYER_NOT_FOUND` command behavior.
- Real UUID, username, and display name can be supplied by native Brickadia logs
  when `brickadiaSavedDir` is configured. Controller path and player-state path
  mapping can still be supplied by optional adapters until BMF has native
  controller-to-identity binding. Health, position, pawn, and role-effect reads
  still require separate `L3 Live Player` validation.
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
