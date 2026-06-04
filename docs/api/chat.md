# Chat API

## `BMF.chat.broadcast(message)`

Broadcasts a message by finding live player controllers and calling
`ClientPushChatMessage(message)` once per unique controller. This is the
preferred live-player route.

Status: experimental.

Validation levels:

- `L3 Live Player UI confirmed`: visible delivery confirmed on CL13530.
- `L2 Headless`: if no live controllers are available, BMF may fall back to
  legacy console command acceptance. That fallback does not imply visible
  delivery.

Server-console command route:

```text
Omegga.Bridge.BMF bmf.chat.broadcast message=[BMF] Hello from the server
```

The result records `data.deliveryMode`, `data.deliveredCount`,
`data.attemptedCount`, and `data.targets`. A live send uses
`player-controller-client-push-chat-message`.

## `BMF.chat.whisper(player, message)`

Finds one live player controller matching `player` and calls
`ClientPushChatMessage(message)` on that controller. The target can be a name,
display name, player id-like string, or a player-ish table with fields such as
`uuid`, `id`, `name`, `displayName`, or `playerName`.

With a single joined player, visible delivery is live-confirmed. Two-player
negative targeting is still pending.

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
- Two-player negative targeting still needs a second joined player before we
  can claim only the intended recipient sees a whisper.
