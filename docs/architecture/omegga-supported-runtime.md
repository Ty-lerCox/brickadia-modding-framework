# Omegga-Supported Runtime

BMF currently supports the BMF-supported Omegga Windows fork for Windows
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
| Console execution helpers | Provides the proven CL13530 console manager and Kismet fallback paths used by world/save APIs. |
| Live call-by-name helper | Enables the validated `ClientPushChatMessage` fanout to live `PlayerController` objects. |
| Player sync adapter | Feeds safe player identity records into `BMF.players` without direct crash-prone `PlayerState` reads. |
| Minigame data/event adapter | Feeds safe Omegga-observed minigame log events into `BMF.minigames.emitEvent` and `BMF.minigames.data()`; snapshot, team, and leaderboard polling stay unsafe opt-ins until replaced by a proven BMF producer. |
| Log context | Gives the supervisor and canaries access to Brickadia and UE4SS logs. |

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
