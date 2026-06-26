# Player Identity Sources

BMF combines safe identity records from Brickadia saved/log context and
`runtime/players.json` when available. It also reports live controller counts
through the safe controller discovery route.

**Labels:** `experimental`, `live-player`, `L2 Headless`, `L3 pending`

## Who Should Read This?

Plugin authors should use this page to understand where player records come
from. Maintainers should use it when changing the Omegga sync adapter, saved/log
reader, or player cache format.

## `BMF.players.list()`

```lua
local result = BMF.players.list()
if result.ok then
  for _, player in ipairs(result.data.players) do
    BMF.log(player.displayName .. " " .. player.uuid)
  end
end
```

With no safe identity source, `BMF.players.list()` returns an empty player list
instead of reading crash-prone live player properties.

Server-console command route:

```text
bmf.players.list
```

On a headless no-player server, the current command canary expects
`players_count=0`. With an identity cache, the command also prints
`known_players_count`, `live_controllers_count`, and one `player_<n>=...` line
per known player.

## `BMF.players.sync(records, options)`

Syncs safe external records into `runtime/players.json`. In the supported
Omegga runtime this is the main launcher-side adapter path for usernames,
display names, UUIDs, controller paths, and player-state paths without reading
live UE4SS properties. The Brickadia saved/log adapter complements this cache
and can recover identity fields when Omegga sync is stale or unavailable.

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
bmf.players.sync players=[["OriginalBuilder","Build Lead","11111111-1111-4111-8111-111111111111","BP_PlayerController_C_1073741824","BP_PlayerState_C_2147483648"]]
```

The supported Omegga feeder lives at
`packages/omegga-plugins/bmf-player-sync/`. In direct cache mode, configure
`runtimeDir` or set `OMEGGA_BMF_RUNTIME_DIR` so it can write `players.json`.
When command bridge mode is enabled, it sends `bmf.players.sync` through the
loaded `BMF Bridge` socket path. It queues syncs on Omegga player-list changes
and also runs a periodic fallback sync.

On the current Windows UE4SS runtime, Omegga's live player list can stay empty
when its PlayerState/PlayerController matcher cannot complete. The adapter then
falls back to Omegga's Brickadia log path and syncs online `UserName`,
`DisplayName`, and `UserId` records as
`source=omegga.players.raw.<reason>.log-fallback`.
