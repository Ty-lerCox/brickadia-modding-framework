# Minigame Data Snapshot

**Labels:** `experimental`, `event-fed`, `L2 Headless`

## Who Should Read This?

Plugin authors should use this page when reading observed minigame state from BMF-owned snapshots. Maintainers should use it when changing reducers or query shape.

BMF keeps an in-memory minigame data snapshot from accepted minigame events and
explicit BMF-owned snapshot imports. This cache is the preferred query path for
plugins and adapters.

## When To Use

Use the data APIs when a plugin needs observed minigame state without calling
Brickadia `Server.Minigames.*` commands.

## Lua API

```lua
local snapshot = BMF.minigames.data()
local status = BMF.minigames.dataStatus()
local applied = BMF.minigames.applySnapshot({
  source = "adapter",
  minigames = {
    { name = "CityRPG", index = 0, teams = { { name = "Police" } } },
  },
})
local minigames = BMF.minigames.dataList({ limit = 25 })
local city = BMF.minigames.get({ name = "CityRPG", index = 0 })
local player = BMF.minigames.getPlayer({ player = "EventKiller" })
local state = BMF.minigames.playerState({ player = "EventKiller" })
local membership = BMF.minigames.membership({ player = "EventKiller" })
local players = BMF.minigames.players({ minigame = "CityRPG", index = 0 })
local teams = BMF.minigames.teams({ minigame = "CityRPG", index = 0 })
local leaderboard = BMF.minigames.leaderboard({ minigame = "CityRPG", index = 0 })
local events = BMF.minigames.recentEvents({ event = "kill", limit = 10 })
```

## Server-Console Routes

```text
bmf.minigames.data.status
bmf.minigames.data.snapshot
bmf.minigames.data.apply-snapshot name=CityRPG index=0 teams=Police,Criminal
bmf.minigames.data.list
bmf.minigames.data.get name=CityRPG index=0
bmf.minigames.data.players minigame=CityRPG index=0
bmf.minigames.data.teams minigame=CityRPG index=0
bmf.minigames.data.leaderboard minigame=CityRPG index=0
bmf.minigames.data.player player=EventKiller
bmf.minigames.data.playerstate player=EventKiller
bmf.minigames.data.membership player=EventKiller
bmf.minigames.events.recent event=kill limit=10
```

The status command prints compact counts:

```text
total_updates=6
minigames=2
players=1
memberships=1
teams=2
team_memberships=1
leaderboards=0
rounds=0
```

## Query Behavior

`BMF.minigames.applySnapshot(payload)` and
`bmf.minigames.data.apply-snapshot` apply an observed snapshot shape without
emitting a framework event. Later membership, team, round, and leaderboard
events can keep that state current.

`BMF.minigames.get(query)` accepts `key`, `ruleset`, `name`, `minigame`, or
`index` and returns one matched minigame plus members, teams, team memberships,
leaderboard records, and round state.

`BMF.minigames.getPlayer` accepts `player`, `playerid`, `uuid`, `id`, `name`,
`state`, or `controller`. `BMF.minigames.playerState` answers whether a known
player is currently in a minigame; historical leaderboard context can remain
after a leave event.

`BMF.minigames.recentEvents(filter)` reads BMF's recent minigame event ring
buffer. Use `event`, `player`, `minigame`, and `limit` filters for
troubleshooting producers without reading full JSONL logs.

For validation and troubleshooting only, clear the cache explicitly:

```text
bmf.minigames.data.clear confirm=CLEAR_MINIGAME_DATA
```
