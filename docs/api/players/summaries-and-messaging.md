# Summaries And Messaging

Player summary helpers resolve cached player identity and format a compact
result for logs, commands, or chat.

**Labels:** `experimental`, `live-player`, `L2 Headless`, `L3 pending`

## Who Should Read This?

Plugin authors should use this page when showing a player identity summary or
whispering a summary back to a player. Maintainers should use it when changing
summary formatting or chat delivery behavior.

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
bmf.players.summary target=OriginalBuilder
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
bmf.players.summary target=OriginalBuilder whisper=true
```

!!! warning
    Whisper delivery requires live-player validation. Cache lookup and summary
    formatting can be proven headlessly; chat delivery cannot.
