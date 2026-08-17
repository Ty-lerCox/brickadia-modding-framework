# Generic Game-Command Tunnel

The game-command tunnel is the standard low-latency path for moving an opaque
CityRPG command from an Omegga plugin into Brickadia. It carries the complete
`/cityrpgRemote ...`, `/cityrpgroute ...`, or bounded standalone
`/cityrpgPositionSnapshot bootstrapV1` line without interpreting its
action fields. BMF does
not know about team, whisper, leaderboard, or other CityRPG actions and does not
add one native hook per action.

`/cityrpgRemote` uses one mandatory routing space followed by a colon-delimited
Wire payload: `/cityrpgRemote action:field1:field2`. Spaces are ordinary field
content. Intermediate fields cannot contain colons or line breaks; the final
field is the unsplit remainder and may contain colons. `/cityrpgroute` remains
a separate legacy grammar. `/cityrpgPositionSnapshot` is the narrow exception
used to bootstrap the standalone Wire position sampler after a successful
authenticated join. Its only accepted Wire action is `bootstrapV1`, and the
Wire graph can register only the exact tunnel sender; BMF never reads player
positions.

The tunnel is authenticated by the existing loopback BMF socket. Omegga routes
each request to exactly one writable BMF native client, BMF admits it to a
bounded queue, and the existing guarded
`ServerPushChatMessage_Implementation` adapter injects the complete line on the
game thread.

## Server-Only Command Boundary

`/cityrpgRemote`, `/cityrpgroute`, and `/cityrpgPositionSnapshot` are reserved
server-only command prefixes.
BMF installs a native detour on the validated
`BRPlayerController.ServerPushChatMessage` UFunction exec slot at startup.
Calls arriving through the ordinary player RPC path are inspected there and
matching commands return before Brickadia's Wire command dispatcher. This
applies to every player, including administrators.

Authenticated tunnel delivery remains available because it calls the validated
`ServerPushChatMessage_Implementation` entry directly after socket admission,
bypassing the player-RPC UFunction exec slot. This distinction is the
authorization boundary: knowing a reserved command's text is not enough to
invoke it from a game client.

Use `bmf.chat.reserved.status` to inspect hook installation, denied attempts,
message-inspection failures, and the most recent denied command. If the native
guard cannot install, treat the reserved command path as fail-open and do not
expose privileged Wire actions until the guard is repaired. BMF does not fall
back to the earlier Lua `RegisterHook` approach because that hook does not
intercept this native RPC implementation path.

Validate the boundary against the real network path. Record
`bmf.chat.reserved.status`, submit `/cityrpgRemote guardCanary` once from a
connected game client, and read the status again. The denial count must advance
by exactly one, `inspection_failures` must remain unchanged, and the Wire
command must not execute. A synthetic server-side `ProcessEvent` call is not a
valid substitute for this test because it does not reproduce the client RPC
path.

Then send a harmless `/cityrpgRemote whisper:<player>:<marker>` through an
authenticated `tunnel.request`. The marker must reach the game while the denial
count remains unchanged. This proves both halves of the boundary: player RPCs
are rejected and authenticated tunnel injection remains available.

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
  "line": "/cityrpgRemote whisper:Ty:Your balance is $100",
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

## Owned Game-Thread Pump

The supported live topology runs one shared `EngineTickOneShotChain` for the
socket and tunnel pump. Each link waits two frames, dispatches through the
simple EngineTick queue, performs bounded work, and only then registers its
successor. The effective opportunity is about 33 milliseconds on a
60-frame-per-second server. The pump drains at most 16 inbound socket messages
and injects at most one admitted command on an eligible invocation. A 25 ms
setting is therefore a requested cadence, not a promise of sub-frame or exact
25 ms dispatch.

The pump does not register callbacks per request and retains at most one
outstanding delayed link for the chain. The delayed-to-simple trampoline keeps
successor registration outside delayed-vector traversal, while bounded work per
invocation makes queue pressure visible instead of transferring it into
UE4SS's scheduler.

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
