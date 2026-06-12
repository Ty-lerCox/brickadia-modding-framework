# Minigame Events

**Labels:** `experimental`, `event-bus`, `L2 Headless`

## Who Should Read This?

Plugin authors and Omegga integrators should use this page when emitting, subscribing to, or relaying normalized minigame events.

BMF exposes a namespaced minigame event surface for Lua plugins, BMF adapters,
and external Omegga relays.

For high-level socket flow, see
[BMF And Omegga Event Bus Messaging](../../architecture/architecture-patterns.md#6-bmf-and-omegga-event-bus-messaging).

## When To Use

Use minigame events when an adapter observes gameplay state and needs to feed
BMF-owned reducers or when a Lua plugin wants to subscribe to minigame changes
without polling files.

## Emit Events

```lua
BMF.minigames.emitEvent("kill", {
  player = { id = "11111111-1111-4111-8111-111111111111", name = "Player" },
  minigame = { name = "CityRPG", index = 0, ruleset = "BP_Ruleset_C_1" },
  leaderboard = { 0, 1, 0 },
  oldLeaderboard = { 0, 0, 0 },
})
```

The emitted BMF event name is `minigames.<event>`, for example
`minigames.kill`.

Supported legacy names:

- `joinminigame`
- `leaveminigame`
- `roundchange`
- `roundend`
- `leaderboardchange`
- `score`
- `kill`
- `death`

BMF-native data names:

- `snapshot`
- `created`
- `deleted`
- `teamchange`

## Subscribe

BMF plugins should prefer `BMF.minigames.on` over raw `BMF.events.on`:

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

Accepted aliases include:

| Alias | Event |
| --- | --- |
| `join` | `joinminigame` |
| `leave` | `leaveminigame` |
| `team` | `teamchange` |
| `leaderboard` | `leaderboardchange` |
| `round`, `roundstart` | `roundchange` |
| `create` | `created` |
| `delete` | `deleted` |

## Metadata

Every emitted payload receives normalized metadata under `_bmf` before
subscribers run:

```lua
{
  event = "minigames.joinminigame",
  legacyEvent = "joinminigame",
  eventId = "1",
  emittedAt = "2026-06-07T15:16:31Z",
  source = "omegga.bmf-minigame-events",
  playerKey = "<uuid-or-state>",
  minigameKey = "name:GLOBAL#0",
}
```

Snake-case aliases are also present for compatibility.

## Server-Console Routes

```text
Omegga.Bridge.BMF bmf.minigames.events.emit event=kill player=Player playerid=11111111-1111-4111-8111-111111111111 minigame=CityRPG index=0 leaderboard=0,1,0 oldleaderboard=0,0,0
Omegga.Bridge.BMF bmf.minigames.events.status
Omegga.Bridge.BMF bmf.minigames.events.recent event=kill limit=10
Omegga.Bridge.BMF bmf.minigames.events.canary event=join
Omegga.Bridge.BMF bmf.minigames.events.synthetic-flow
```

`bmf.minigames.events.canary` and `bmf.minigames.events.synthetic-flow` restore
the minigame data cache by default. Pass `persist=true` only when intentionally
testing reducer side effects.

## External Relays

Every emitted event is appended to `runtime/events.jsonl`. When the BMF socket
bridge is active, the same event record is sent to Omegga plugin clients. See
the [Supported Runtime Matrix](../../reference/supported-runtime.md) for socket
versus JSONL fallback behavior.

The packaged Omegga producer lives at:

```text
integrations/omegga/bmf-minigame-events/
```

Its safe default is log-events-only. Snapshot, team, and leaderboard polling are
unsafe opt-ins until BMF has a proven native hook or safer Brickadia data source.
