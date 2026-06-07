# Omegga-Supported Runtime

BMF currently supports a BMF-compatible Omegga runtime through the
BMF-supported Omegga Windows fork for Windows

Brickadia dedicated servers:

<https://github.com/Ty-lerCox/bmf-omegga-fork>

That runtime is more than a convenience wrapper: it is the current server
supervisor and UE4SS bridge environment that BMF canaries and some live-player
APIs depend on.

## Current Contract

The supported runtime is not "any upstream Omegga install." It is the fork
above, including the BMF Windows/UE4SS compatibility work.

Stock upstream Omegga and the global npm package are Linux/WSL-oriented and are
not the supported Windows runtime for BMF. The fork intentionally trails the
latest upstream Omegga builds; treat that version skew as part of the runtime
contract until BMF validates a newer fork or upstream release.

| Runtime Surface | Why BMF Uses It |
| --- | --- |
| Server supervisor | Starts and monitors the Brickadia dedicated server. |
| UE4SS compatibility setup | Installs the pinned UE4SS payload, Brickadia config, signatures, and bridge mod. |
| Command bridge | Routes `Omegga.Bridge.BMF ...` into the BMF command worker for canaries and admin commands. |
| BMF socket broker | Provides an authenticated loopback TCP broker for low-latency BMF command responses and event delivery between UE4SS and Omegga plugins. |
| Console execution helpers | Provides the proven CL13530 console manager and Kismet fallback paths used by world/save APIs. |
| Live call-by-name helper | Enables the validated `ClientPushChatMessage` fanout to live `PlayerController` objects. |
| Player sync adapter | Feeds safe player identity records into `BMF.players` without direct crash-prone `PlayerState` reads. |
| Minigame data/event adapter | Feeds safe Omegga-observed minigame log events into `BMF.minigames.emitEvent` and `BMF.minigames.data()`; snapshot, team, and leaderboard polling stay unsafe opt-ins until replaced by a proven BMF producer. |
| Log context | Gives the supervisor and canaries access to Brickadia and UE4SS logs. |

## Low-Latency Socket Bridge

The supported Omegga fork now starts a local BMF socket broker during UE4SS
server launches. The broker binds to loopback, generates a per-run token, and
passes connection details through `OMEGGA_BMF_SOCKET_*` environment variables.
BMF also writes the same non-public connection metadata to
`Mods/BMF/runtime/socket.json` so plugin processes that start after Omegga can
discover the live broker without inheriting the original launch environment.

The bridge has two authenticated client roles:

- `bmf-native`: the optional `BMFSocket` UE4SS C++ mod loaded inside the
  Brickadia server process. It never calls Lua from its worker thread; it only
  moves newline-delimited JSON messages between UE4SS Lua and the broker.
- `cityrpg` or `plugin`: Omegga plugin clients that subscribe to BMF event
  records and send BMF command requests.

When the socket bridge is available, BMF writes every framework event to
`runtime/events.jsonl` and also sends an event envelope over the broker.
Commands from plugins use the socket first and fall back to the existing
file-backed `runtime/commands` worker when the socket is unavailable. This
keeps older validation and repair workflows working while making latency
sensitive gameplay paths independent of multi-second file polling.

Live validation on June 7, 2026 proved the CityRPG minigame team-assignment
path using the socket bridge: a `joinminigame` event reached CityRPG and the
follow-up `bmf.minigames.live.assign-team` command returned over the socket in
about 51ms. The previous workflow could feel like roughly five seconds because
events and responses were gated by polling intervals and plugin retry loops.

Use `bmf.socket.status` to inspect the active transport. Useful fields include
`started`, `host`, `port`, `poll_interval_ms`, `sent_events`,
`received_commands`, `sent_responses`, `last_error`, and the native
`BMFSocketStatus()` snapshot.

## What Omegga Should Fill

BMF should use Omegga where Omegga already has a safer or more complete server
wrapper view: process lifecycle, plugin command transport, current player
identity, log streaming, and restart/startup orchestration. BMF should still
own the Lua API contracts, capability gates, rate limits, audit records, and
validation labels exposed to server-side mods.

For chat, the current split is:

- Omegga supplies the supported server wrapper and command bridge.
- BMF resolves the Lua API call, rate limit, audit record, and result shape.
- UE4SS helper globals invoke `ClientPushChatMessage` on live
  `PlayerController` objects.
- Omegga player sync and Brickadia saved/log adapters provide identity records
  for named targeting without unsafe live `PlayerState` reads.

Current Windows note: Omegga's own `getPlayers()` list can stay empty when its
`BRPlayerState`/`PlayerController` matcher does not complete. The packaged BMF
Player Sync adapter therefore has a supported log-fallback source under Omegga's
Brickadia data path. It still writes `adapter=omegga-cache`, but the source is
reported as `omegga.players.raw.<reason>.log-fallback`.

## Supported Omegga Assets

BMF packages the current Omegga player sync adapter at
`integrations/omegga/bmf-player-sync/` and the minigame event adapter at
`integrations/omegga/bmf-minigame-events/`. The supported fork is expected to
install or load those adapters when Omegga-fed player identity or BMF-owned
minigame data/event production is needed.

The supported fork must provide or preserve these bridge/helper
surfaces until BMF replaces them with equivalent names:

- `Omegga.Bridge.BMF`
- `OmeggaExecuteConsoleManagerInput`
- `OmeggaExecuteKismetConsoleCommand`
- `OmeggaExecuteCachedConsoleExec`
- `OmeggaCallFunctionByNameWithArguments`
- `RegisterConsoleCommandGlobalHandler`
- `BMFSocketStart`
- `BMFSocketSend`
- `BMFSocketReceive`
- `BMFSocketStatus`

## Packaging Rule

BMF should not vendor Omegga `node_modules` or runtime server data into the BMF
release zip. The supported packaging shape is currently:

- the BMF-supported Omegga Windows fork at
  <https://github.com/Ty-lerCox/bmf-omegga-fork>.

Future packaging can move to a BMF-compatible release artifact or upstream
Omegga only after the Windows/UE4SS compatibility work is accepted and BMF has
validated that route.

The selected route must retain Omegga's license notices.

## Validation

Current BMF goal-mode validation may use Omegga when the target feature depends
on server launch, command transport, logs, player identity sync, or live helper
calls. A feature is not complete merely because Omegga accepted a command; the
feature still needs the correct BMF result contract, docs, and evidence at the
target validation level.

The standalone runtime page tracks the future replacement path if BMF later
stops depending on Omegga.
