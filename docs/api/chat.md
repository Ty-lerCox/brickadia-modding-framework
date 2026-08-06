# Chat API

## Who Should Read This?

Plugin authors should use this page for broadcast, whisper, and status-message behavior. Server operators should read the validation caveats before treating chat delivery as production-ready.

BMF chat APIs are implemented inside BMF. The supported Windows runtime supplies
the server wrapper, bridge, and helper globals BMF uses to reach live Brickadia
`PlayerController` objects; see the
[Supported Runtime Matrix](../reference/supported-runtime.md).

**Labels:** `experimental`, `live-player`, `L3 Live Player`

## Examples

- [HelloBroadcast](../examples/hello-broadcast.md): complete load-time
  broadcast plugin.
- [TimedBroadcast](../examples/timed-broadcast.md): delayed broadcast with
  `BMF.timers.after`.

## `BMF.chat.broadcast(message)`

Broadcasts a message by finding a live player controller and calling
`ClientPushChatMessage(message)`. This is the preferred live-player route for
CL13530.

!!! warning
    This path intentionally avoids `PlayerState` and `PlayerArray` property
    reads. A live test on June 4, 2026 proved those UE4SS property reads can
    crash the server while pushing struct properties into Lua.

Current chat delivery proof is tracked in
[API Validation Evidence](../validation/api-validation.md#chat).

Server-console command route:

```text
bmf.chat.broadcast message=[BMF] Hello from the server
```

The result records `data.deliveryMode`, `data.deliveredCount`,
`data.attemptedCount`, `data.command`, and `data.targets`. A live send uses
`player-controller-client-push-chat-message`.

## `BMF.chat.whisper(player, message)`

Private delivery is fail-closed. The supported route requires a plain immutable
request envelope containing an exact player UUID and current connection
generation. At dispatch time, BMF revalidates the current UUID, generation,
controller, and PlayerState association before calling
`ClientPushChatMessage(message)`.

A name, controller-list position, cached UObject, or the presence of exactly one
live controller is never enough to select a recipient. If the exact association
cannot be proven, BMF drops the message and reports a bounded identity failure.
The supported identity source is the Omegga player sync adapter plus safe
Brickadia saved/log evidence, not crash-prone live `PlayerState` reflection.

Legacy name-only calls return `PRIVATE_IDENTITY_REQUIRED`; they do not fall back
to another player or to global chat.

Server-console command route:

```text
bmf.chat.whisper target=<uuid-or-name> message=<text>
```

The response includes `delivered`, `delivered_count`, `attempted_count`,
`delivery_mode`, and `validation`. A successful live whisper reports
`delivery_mode=player-controller-client-push-chat-message` and
`validation=L3 Live Player UI confirmed`.

## `BMF.chat.statusMessage(player, message)`

Uses the same strict UUID, connection-generation, controller, and PlayerState
validation as `BMF.chat.whisper`. A mismatch drops the private status/UI output.

Server-console command route:

```text
bmf.chat.statusmessage target=<uuid-or-name> message=<text>
```

## Validation

Chat proof and remaining live-player gaps are tracked in
[API Validation Evidence](../validation/api-validation.md#chat). A live
three-player reconnect/reordering canary is still required before the August
2026 cross-player routing incident can be closed.
