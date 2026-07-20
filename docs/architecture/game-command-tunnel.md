# Generic Game-Command Tunnel

The game-command tunnel is the standard low-latency path for moving an opaque
CityRPG command from an Omegga plugin into Brickadia. It keeps the existing
`/cityrpgRemote ...` and `/cityrpgroute ...` command grammars intact. BMF does
not know about team, whisper, leaderboard, or other CityRPG actions and does not
add one native hook per action.

The tunnel is authenticated by the existing loopback BMF socket. Omegga routes
each request to exactly one writable BMF native client, BMF admits it to a
bounded queue, and the existing guarded
`ServerPushChatMessage_Implementation` adapter injects the complete line on the
game thread.

## Protocol v1

The advertised capability is `bmf-tunnel/1`. BMF writes it to
`Mods/BMF/runtime/socket.json` with `tunnelEnabled`, `maxTunnelLineBytes`, and
the socket connection metadata.

Request:

```json
{
  "type": "tunnel.request",
  "v": 1,
  "id": "cityrpg_tunnel_...",
  "channel": "cityrpg.command.v1",
  "line": "/cityrpgRemote whisper ...",
  "deadlineMs": 1784523000000,
  "serviceClass": "interactive",
  "issuedAtMs": 1784522992500
}
```

`deadlineMs` is an absolute Unix epoch deadline in milliseconds, not a
duration. `serviceClass` is either `interactive` or `bulk`. The optional
`idempotencyKey` is limited to 128 bytes and identifies one logical attempt;
it must not be a reusable target-state key.

Admission acknowledgment:

```json
{
  "type": "tunnel.ack",
  "v": 1,
  "id": "cityrpg_tunnel_...",
  "state": "accepted",
  "queueDepth": 3
}
```

Terminal result:

```json
{
  "type": "tunnel.result",
  "v": 1,
  "id": "cityrpg_tunnel_...",
  "state": "injected",
  "code": "OK",
  "response": "implementation_called=true\nok=true\n",
  "dispatchMs": 16,
  "queueDepth": 2
}
```

Terminal states are `injected`, `rejected`, `expired`, and
`outcome_unknown`. A result received before its acknowledgment is treated as
implicit admission.

## Persistent Game-Thread Pump

The supported live topology registers exactly one persistent
`LoopInGameThreadAfterFrames` handle for the socket and tunnel pump. At the
validated 25-millisecond socket setting, UE4SS rounds the loop to two frames,
so the effective game-thread opportunity is about 33 milliseconds on a
60-frame-per-second server. The pump drains at most 16 inbound socket messages
and injects at most one admitted command on an eligible invocation. A 25 ms
setting is therefore a requested cadence, not a promise of sub-frame or exact
25 ms dispatch.

The pump does not register delayed or simple callbacks per request. An earlier
implementation scheduled a game-thread callback for each inbound request and
another callback for its delayed continuation. Live testing exposed a UE4SS
Lua function-registry race in that design and crashed the server. Keeping one
long-lived callback and bounded work per invocation removes that callback churn
and makes queue pressure visible instead of transferring it into UE4SS's
scheduler.

Readiness is fail closed. BMF writes `tunnelEnabled: true` and advertises
`bmf-tunnel/1` only after the persistent callback has executed its first real
tick and both the socket and tunnel workers report the supported game-thread
mode. A registered handle that never fires is not treated as ready. A pump
error disables the worker, rejects remaining queued work with a terminal
result, and requires a process restart instead of registering a replacement
callback in the same process.

## Delivery Safety

Omegga keeps a bounded request-ID-to-origin route and selects one native BMF
connection. This prevents reconnect overlap from executing one request on two
native clients and prevents one plugin from consuming another plugin's result.

BMF deduplicates active and recently completed request IDs. Non-empty
idempotency keys are also deduplicated independently for the current BMF
session. The completed cache is bounded and resets with BMF, so it is not a
durable cross-restart transaction journal.

CityRPG may use the legacy path only when the tunnel is known to be unsupported
or unavailable before BMF admission. It must not retry through the legacy path
after an acknowledgment, timeout, connection loss, or `outcome_unknown`; those
states may follow a command that already executed.

## Bounds and Scheduling

The built-in limits and the values validated in the managed local launch are:

| Setting | Built-in | Validated managed value |
| --- | ---: | ---: |
| Socket poll | 25 ms | 25 ms |
| Dispatch interval | 50 ms | 25 ms |
| Persistent pump | enabled | enabled |
| Inbound messages per pump | 16 | 16 |
| Total queued requests | 64 | 64 |
| Interactive queue | 48 | 48 |
| Bulk queue | 32 | 32 |
| Retained queue bytes | 131,072 | 131,072 |
| Command line bytes | 4,096 | 4,096 |
| Completed request IDs | 1,024 | 1,024 |
| Interactive burst before bulk fairness | 4 | 4 |

The first accepted request is eligible later in the same persistent-pump
invocation, after bounded socket ingress completes. Additional requests are
dispatched one at a time at the configured interval, quantized to pump
invocations; the scheduler does not catch up by running a burst on one frame.
Interactive traffic has reserved capacity, while the fairness burst prevents
indefinite bulk starvation. Absolute deadlines reject work that is already
stale or cannot fit its estimated queue wait. Full queues reject explicitly and
never drop an accepted command silently.

Configuration variables use the `BMF_GAME_COMMAND_TUNNEL_` prefix:

- `ENABLED`
- `PERSISTENT_PUMP`
- `INGRESS_PER_TICK`
- `INTERVAL_MS`
- `MAX_QUEUE`
- `MAX_INTERACTIVE_QUEUE`
- `MAX_BULK_QUEUE`
- `MAX_BYTES`
- `MAX_LINE_BYTES`
- `INTERACTIVE_BURST`
- `COMPLETED_RETENTION`

`OMEGGA_BMF_SOCKET_POLL_MS` controls the requested socket pump cadence. In the
supported persistent mode, socket receive and command injection occur in the
same bounded game-thread pump; the frame scheduler still determines the actual
invocation interval.

## Observability and Rollback

`bmf.tunnel.status`, BMF status JSON, and BMF telemetry expose queue depth,
peak depth and bytes, admission and terminal counts, controller-cache use,
dispatch duration, scheduler failures, and the last result/error. CityRPG
exports tunnel outcome counters and separate socket/legacy queue wait and
operation durations. Use the [command tunnel benchmark](../validation/command-tunnel-benchmark.md)
with frame telemetry before promoting a cadence change.

Set `CITYRPG_BMF_TUNNEL_ENABLED=0` to force the existing bounded legacy queue
without changing CityRPG action code. Set `BMF_GAME_COMMAND_TUNNEL_ENABLED=0`
to disable BMF admission. Restoring `OMEGGA_BMF_SOCKET_POLL_MS=200` reverts the
polling cadence if frame telemetry regresses.

## Brickadia-to-Omegga Output

This tunnel changes only Omegga-to-Brickadia command injection. The measured
Brickadia console path was already p50 1 ms and at most 20 ms for matched
gameplay lines, with no sustained player-position spam. PrintToConsole therefore
remains on the stable stdout parser. A native interception hook would add crash
surface while making this already-fast direction slower or no more useful.
