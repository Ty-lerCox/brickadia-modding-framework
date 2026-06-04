# Chat API

## `BMF.chat.broadcast(message)`

Broadcasts a message by finding a live player controller and calling
`ClientPushChatMessage(message)`. This is the preferred live-player route for
CL13530.

Important: this path intentionally avoids `PlayerState` and `PlayerArray`
property reads. A live test on June 4, 2026 proved those UE4SS property reads
can crash the server while pushing struct properties into Lua.

Status: experimental.

Validation levels:

- `L3 Live Player UI confirmed`: visible delivery confirmed on CL13530 with
  one joined player.
- `L2 Headless`: if no live controllers are available, BMF may fall back to
  legacy console command acceptance. That fallback does not imply visible
  delivery.

Server-console command route:

```text
Omegga.Bridge.BMF bmf.chat.broadcast message=[BMF] Hello from the server
```

The result records `data.deliveryMode`, `data.deliveredCount`,
`data.attemptedCount`, `data.command`, and `data.targets`. A live send uses
`player-controller-client-push-chat-message`.

## `BMF.chat.whisper(player, message)`

Finds one live player controller and calls `ClientPushChatMessage(message)` on
that controller. With exactly one live controller, any non-empty target string
routes to that controller. Name/UUID matching remains pending because the
validated route deliberately does not read `PlayerState` identity fields yet.

With a single joined player, visible delivery is live-confirmed. Two-player
negative targeting and live identity matching are still pending.

If no live target is matched, BMF falls back to `BMF.players.resolve(player)`
for the older structured errors (`PLAYER_NOT_FOUND` or
`PLAYER_DELIVERY_UNAVAILABLE`).

Server-console command route:

```text
Omegga.Bridge.BMF bmf.chat.whisper target=<uuid-or-name> message=<text>
```

## `BMF.chat.statusMessage(player, message)`

Same target resolution behavior as `BMF.chat.whisper`, but for private
status/UI feedback. Live visible delivery still requires `L3 Live Player`
validation.

Server-console command route:

```text
Omegga.Bridge.BMF bmf.chat.statusmessage target=<uuid-or-name> message=<text>
```

## Validation

- `L3 Live Player`: `ClientPushChatMessage` visible UI delivery is confirmed
  for broadcast and one-target whisper-style delivery.
- The validated route avoids live `PlayerState` reflection. Player names and
  UUIDs can come from Omegga/log context externally, but BMF does not yet expose
  them from a safe live adapter.
- Two-player negative targeting still needs a safe identity adapter and a
  second joined player before we can claim only the intended recipient sees a
  whisper.
