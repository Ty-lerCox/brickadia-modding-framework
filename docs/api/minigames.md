# Minigames API

BMF minigame support has two surfaces:

- BMF-owned event/data APIs used by Omegga adapters and BMF consumers.
- Legacy Brickadia `Server.Minigames.*` console wrappers.

The legacy console wrappers are disabled by default because
`Server.Minigames.List` can crash Brickadia CL13530 while formatting its console
table output. Prefer the BMF-owned event/data APIs for minigame state.

## `BMF.minigames.list()`

Would run, when explicitly enabled:

```text
Server.Minigames.List
```

```lua
local result = BMF.minigames.list()
if result.ok then
  BMF.log(result.data.command)
end
```

By default this returns `UNSAFE_MINIGAME_COMMAND_DISABLED` and does not execute
Brickadia's console command. Rich parsing of the console table remains an
Omegga-side capability when the underlying Brickadia command is safe.

Server-console command route:

```text
Omegga.Bridge.BMF bmf.minigames.list
```

The command response records `command=Server.Minigames.List` and
`allowUnsafeMinigameConsoleCommands=false` unless the unsafe opt-in is enabled.

## Presets

Load a saved preset:

```lua
BMF.minigames.loadPreset("Arena")
```

Server-console command route:

```text
Omegga.Bridge.BMF bmf.minigames.loadpreset name=Arena
```

Save an active minigame as a preset:

```lua
BMF.minigames.savePreset(0, "Arena")
```

Server-console command route:

```text
Omegga.Bridge.BMF bmf.minigames.savepreset index=0 name=Arena
```

List saved preset files from disk:

```powershell
.\scripts\list-minigame-presets.ps1
```

Preset names are validated to reject path separators and control characters.

## Lifecycle

```lua
BMF.minigames.nextRound(0)
BMF.minigames.reset(0)
BMF.minigames.delete(0)
```

Server-console command routes:

```text
Omegga.Bridge.BMF bmf.minigames.nextround index=0
Omegga.Bridge.BMF bmf.minigames.reset index=0
Omegga.Bridge.BMF bmf.minigames.delete index=0
```

These would wrap, when explicitly enabled:

- `Server.Minigames.NextRound <index>`
- `Server.Minigames.Reset <index>`
- `Server.Minigames.Delete <index>`

Indexes must be zero or greater. By default, valid lifecycle calls return
`UNSAFE_MINIGAME_COMMAND_DISABLED` before reaching Brickadia.

## Desired Definitions

BMF can store desired minigame definitions without calling Brickadia's unsafe
minigame console commands. These records are BMF-owned target state for plugins
such as CityRPG and future BMF minigame producers; they do not create, delete,
or mutate live Brickadia minigames by themselves.

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

Server-console command routes:

```text
Omegga.Bridge.BMF bmf.minigames.definitions.status
Omegga.Bridge.BMF bmf.minigames.definitions.set name=CityRPG index=0 teams=Police,Criminal persistent=true owneronly=false includedbrickmode=all
Omegga.Bridge.BMF bmf.minigames.definitions.list
Omegga.Bridge.BMF bmf.minigames.definitions.get name=CityRPG index=0
Omegga.Bridge.BMF bmf.minigames.definitions.delete name=CityRPG index=0 confirm=DELETE_MINIGAME_DEFINITION
Omegga.Bridge.BMF bmf.minigames.definitions.reconcile name=CityRPG index=0
```

Definitions persist at `ue4ss/main/Mods/BMF/runtime/minigames/definitions.json`
and expose `liveEnforcement="definition-only"` until a validated producer maps
that desired state into live minigame behavior. Supported fields currently
include `name`, `index`, `ruleset`, `owner`, `mode`, `teams`, `persistent`,
`ownerOnly`, `includedBrickMode`, `includedBricks`, and `maxPlayers`.

`BMF.minigames.reconcileDefinitions(query)` compares those desired records with
the current BMF-owned observed minigame data snapshot. A definition is `present`
when an observed minigame matches by key, ruleset, or name/index and all desired
team labels are present. It is `missing` when no observed minigame matches, and
`team-mismatch` when the minigame exists but one or more desired teams are not
in the observed team snapshot. Reconciliation is read-only and does not call
Brickadia `Server.Minigames.*` commands.

## Events

BMF exposes a namespaced minigame event surface for external relays:

```lua
BMF.minigames.emitEvent("kill", {
  player = { id = "11111111-1111-4111-8111-111111111111", name = "Player" },
  minigame = { name = "CityRPG", index = 0, ruleset = "BP_Ruleset_C_1" },
  leaderboard = { 0, 1, 0 },
  oldLeaderboard = { 0, 0, 0 },
})
```

The emitted BMF event name is `minigames.<event>`, for example
`minigames.kill`. Supported legacy event names are:

- `joinminigame`
- `leaveminigame`
- `roundchange`
- `roundend`
- `leaderboardchange`
- `score`
- `kill`
- `death`

BMF-native data event names are:

- `snapshot`
- `created`
- `deleted`
- `teamchange`

Event subscription aliases are accepted by `BMF.minigames.on`,
`BMF.minigames.listenerCount`, `BMF.minigames.recentEvents`, and
`BMF.minigames.emitEvent`:

- `join` -> `joinminigame`
- `leave` -> `leaveminigame`
- `team` -> `teamchange`
- `leaderboard` -> `leaderboardchange`
- `round` or `roundstart` -> `roundchange`
- `create` -> `created`
- `delete` -> `deleted`

BMF plugins should prefer the minigame wrapper over raw `BMF.events.on`:

```lua
local id = BMF.minigames.on("join", function(payload, legacyEvent, eventName)
  local meta = payload._bmf or {}
  BMF.logInfo("player joined minigame", {
    event = eventName,
    legacy = legacyEvent,
    eventId = meta.eventId,
    playerKey = meta.playerKey,
    minigameKey = meta.minigameKey,
  })
end)

local listeners = BMF.minigames.listenerCount("join")
BMF.minigames.off(id)
```

Every emitted payload receives normalized metadata under `_bmf` before
subscribers run:

```lua
{
  event = "minigames.joinminigame",
  legacyEvent = "joinminigame",
  legacy_event = "joinminigame",
  eventId = "1",
  event_id = "1",
  emittedAt = "2026-06-07T15:16:31Z",
  emitted_at = "2026-06-07T15:16:31Z",
  source = "omegga.bmf-minigame-events",
  playerKey = "<uuid-or-state>",
  player_key = "<uuid-or-state>",
  minigameKey = "name:GLOBAL#0",
  minigame_key = "name:GLOBAL#0",
}
```

Server-console command routes:

```text
Omegga.Bridge.BMF bmf.minigames.events.emit event=kill player=Player playerid=11111111-1111-4111-8111-111111111111 minigame=CityRPG index=0 leaderboard=0,1,0 oldleaderboard=0,0,0
Omegga.Bridge.BMF bmf.minigames.events.status
Omegga.Bridge.BMF bmf.minigames.events.recent event=kill limit=10
Omegga.Bridge.BMF bmf.minigames.events.canary event=join
Omegga.Bridge.BMF bmf.minigames.events.synthetic-flow
```

`bmf.minigames.events.canary` restores the minigame data cache after emitting
its test event by default, so it does not leave `MinigameApiCanary` in live
membership data. Pass `persist=true` only when intentionally testing reducer
side effects.

`bmf.minigames.events.synthetic-flow` emits a BMF-owned lifecycle canary:
`created`, `joinminigame`, `teamchange`, `roundchange`,
`leaderboardchange`, `kill`, `leaveminigame`, and `deleted`. It subscribes to
each event, verifies the reducer checkpoints, and restores the previous data
cache by default. Pass `persist=true` only when intentionally leaving the
synthetic records in the current process.

Every emitted event is also appended to `runtime/events.jsonl` through
`BMF.events.emit`. When the BMF socket bridge is active, the same event record
is also sent to Omegga plugin clients over loopback TCP. CityRPG should consume
the socket stream first and map `minigames.kill`, `minigames.joinminigame`, and
other namespaced records back to its existing handlers without enabling the
legacy `omegga-minigameevents` polling plugin. The JSONL stream remains the
fallback and audit trail.

The socket path is important for gameplay feel. Live validation on June 7,
2026 proved a CityRPG `joinminigame` event followed by
`bmf.minigames.live.assign-team` returned over the socket with
`bmf_command_transport=socket` and about 51ms command response time. The older
file-polling path could make team assignment feel delayed by several seconds.

The supported Omegga producer is packaged at
`integrations/omegga/bmf-minigame-events/`. Its safe default is log-events-only:
it observes Brickadia/Omegga log evidence such as join-minigame messages and
writes BMF command files for `BMF.minigames.emitEvent`. Snapshot/team and
leaderboard polling are disabled by default because direct object/console
enumeration has crashed CL13530 dedicated servers. Those producers remain unsafe
opt-ins until BMF has a proven native hook or a safer Brickadia data source.
In safe mode, the adapter can still seed its local join/leave cache from
`bmf.minigames.data.snapshot` at startup and from `/bmfminigamesync`; that seed
reads BMF-owned data only and does not poll Brickadia objects.

## Data Snapshot

BMF keeps an in-memory minigame data snapshot from accepted minigame events:

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

Server-console command routes:

```text
Omegga.Bridge.BMF bmf.minigames.data.status
Omegga.Bridge.BMF bmf.minigames.data.snapshot
Omegga.Bridge.BMF bmf.minigames.data.apply-snapshot name=CityRPG index=0 teams=Police,Criminal
Omegga.Bridge.BMF bmf.minigames.data.list
Omegga.Bridge.BMF bmf.minigames.data.get name=CityRPG index=0
Omegga.Bridge.BMF bmf.minigames.data.players minigame=CityRPG index=0
Omegga.Bridge.BMF bmf.minigames.data.teams minigame=CityRPG index=0
Omegga.Bridge.BMF bmf.minigames.data.leaderboard minigame=CityRPG index=0
Omegga.Bridge.BMF bmf.minigames.data.player player=EventKiller
Omegga.Bridge.BMF bmf.minigames.data.playerstate player=EventKiller
Omegga.Bridge.BMF bmf.minigames.data.membership player=EventKiller
Omegga.Bridge.BMF bmf.minigames.events.recent event=kill limit=10
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

This cache is fed by accepted minigame events and by explicit BMF-owned snapshot
imports. `BMF.minigames.applySnapshot(payload)` and
`bmf.minigames.data.apply-snapshot` apply the same observed snapshot shape as a
`snapshot` event without emitting a framework event. That gives Omegga adapters
and validators a direct import path for known minigames and teams; later
membership, team, round, and leaderboard events can keep it current. It does not
require CityRPG to subscribe to `omegga-minigameevents`.

`BMF.minigames.dataList(query)` lists known minigames with member/team counts.
`BMF.minigames.get(query)` accepts `key`, `ruleset`, `name`, `minigame`, or
`index` and returns one matched minigame plus its known members, teams, team
memberships, leaderboard records, and round state. `BMF.minigames.players`,
`BMF.minigames.teams`, `BMF.minigames.leaderboard`, and
`BMF.minigames.membership` expose player/team/scoreboard views over the same
cache. Leaderboard rows are sorted by their first numeric value as `score` and
also include the raw `leaderboard` values for game-specific scoring.
`BMF.minigames.getPlayer` accepts `player`, `playerid`, `uuid`, `id`, `name`,
`state`, or `controller` and returns the player's known membership, team,
leaderboard, and minigame context.
`BMF.minigames.playerState` answers the current-membership question directly:
`inMinigame=true` only when a membership exists. Its `minigameKey` is the
current membership key, while `activityMinigameKey` can still point at historical
leaderboard context after a leave event.

`BMF.minigames.recentEvents(filter)` returns accepted events from BMF's recent
minigame event ring buffer. Use `event`, `player`, `minigame`, and `limit`
filters for troubleshooting producers without reading the full JSONL log.
These are read-only BMF cache lookups; they do not call Brickadia
`Server.Minigames.*` commands.

For validation and troubleshooting only, the cache can be cleared explicitly:

```text
Omegga.Bridge.BMF bmf.minigames.data.clear confirm=CLEAR_MINIGAME_DATA
```

## Object Snapshot

`BMF.minigames.objectSnapshot({ limit = 64 })` is a direct UE4SS object probe
for live `BP_Ruleset_C` and `BP_Team_C` objects. It does not use Brickadia
console `GetAll`, but it is still disabled by default because raw UE4SS object
enumeration is high risk on the current dedicated-server runtime. When enabled,
the default command only returns object metadata and counts; direct Unreal
property reads such as `MemberStates` and `TeamColor` require the additional
`includeProperties=true` opt-in.

Server-console command route:

```text
Omegga.Bridge.BMF bmf.minigames.objects.snapshot limit=64
Omegga.Bridge.BMF bmf.minigames.objects.snapshot limit=64 includeProperties=true
```

By default the command returns `UNSAFE_MINIGAME_OBJECT_SNAPSHOT_DISABLED` with
`allowUnsafeMinigameObjectSnapshot=false`. Only enable
`allowUnsafeMinigameObjectSnapshot` during isolated live tracing when a crash is
acceptable and the server can be restarted.

## Validation

- `L0 Static`: command formatting and preset directory listing.
- `L1 Boot`: BMF Lua wrappers load and execute on a disposable headless server.
- `L2 Headless`: command transport can prove that unsafe minigame console
  wrappers fail closed without reaching Brickadia.
- `L2 Headless event-log`: `scripts/validate-bmf-events.ps1` emits a
  namespaced `minigames.kill` canary and verifies it reaches
  `runtime/events.jsonl`.
- `L2 Headless data-status`: minigame event canaries update
  `bmf.minigames.data.status` counts.
- `L2 Headless data-query`: the same canaries prove
  `bmf.minigames.data.snapshot`, `bmf.minigames.data.list`,
  `bmf.minigames.data.get`, `bmf.minigames.data.players`,
  `bmf.minigames.data.teams`, `bmf.minigames.data.leaderboard`,
  `bmf.minigames.data.player`, `bmf.minigames.data.playerstate`,
  `bmf.minigames.data.membership`, and `bmf.minigames.events.recent` return
  stable JSON context without unsafe
  Brickadia minigame console calls.
- `L2 Headless leave-reducer`: `scripts/validate-bmf-events.ps1` emits
  `leaveminigame` after a join and proves the player's membership is removed.
- `L2 Headless synthetic-flow`: `scripts/validate-bmf-events.ps1` runs
  `bmf.minigames.events.synthetic-flow` to prove create, join, team, round,
  leaderboard, kill, leave, and delete reducer checkpoints with data restoration.
- `L2 Headless event-subscribe`: `bmf.minigames.events.canary` proves
  `BMF.minigames.on`, `BMF.minigames.off`, listener counts, event aliases, and
  normalized `_bmf` metadata.
- `L2 Headless + L5 Negative`: `scripts/validate-bmf-minigame-commands.ps1`
  proves command-worker transport, fail-closed behavior for unsafe minigame
  console wrappers, fail-closed behavior for the unsafe object snapshot probe,
  desired-definition set/list/get/delete, and invalid preset-name/index
  rejection.
- `L3 Live Player`: joining, membership, teams, scoring, and gameplay effects.
- `L5 Negative`: permission or policy enforcement around minigame edits.

## Still Open

- Creating a configured minigame without a client UI.
- Mutating included-brick mode, owner-only mode, persistent mode, and teams.
- Discovering the runtime minigame manager/object model.
- Proving whether minigame commands are safe before the default minigame exists.
