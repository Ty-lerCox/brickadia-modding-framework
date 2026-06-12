# API Overview

**Labels:** `reference`, `doc-map`

This section documents the public BMF Lua and server-console surfaces.

API pages follow the same reader path:

1. What the API is for.
2. When to use it.
3. Lua usage.
4. Server-console routes when they exist.
5. Result shape, gates, and capability requirements.
6. Validation links.

The central [Lua examples](../examples/index.md) page collects complete plugin
examples and links to runnable `examples/` folders.

## Who Should Read This?

Plugin authors should use this page to find the right API. Omegga integrators
should use it to find command and event surfaces. BMF maintainers should use it
to keep reference pages consistent.

Status terms:

- `Planned`: designed but not implemented.
- `Coded, needs validation`: implemented but not proven in a running server.
- `Live tested, experimental`: proven in a live or headless validation pass, but
  not stable enough for production promises.
- `Production ready`: stable API and validation coverage. BMF does not claim any
  production-ready APIs yet.

Compact labels use the terms defined in the [Glossary](../reference/glossary.md).

## Core APIs

| Area | Labels | Page | Example | Notes |
| --- | --- | --- | --- | --- |
| API registry | `stable`, `L2` | [API Registry](apis.md) | [InspectApiLabels](../examples/inspect-api-labels.md) | Runtime API listing and labels. |
| Chat | `experimental`, `live-player`, `L3` | [Chat](chat.md) | [HelloBroadcast](../examples/hello-broadcast.md) | Broadcast and private-message surfaces. |
| Commands | `experimental`, `L2`, `L5` | [Commands](commands.md) | [Plugin Command](../examples/plugin-command.md) | Server-console command registry. |
| Runtime brick state | `experimental`, `unsafe-native`, `L6 required` | [Runtime Brick State](runtime-bricks.md) | CityRPG tree lifecycle | Runtime brick inspect/set controls. |
| Plugins | `stable`, `L2`, `L5` | [Plugins](plugins.md) | [Plugin Storage](../examples/plugin-storage.md) | Plugin metadata, lifecycle, sandbox, and capability gates. |
| Players | `experimental`, `live-player`, `L2/L3` | [Players](players.md) | [PlayerSummary](../examples/player-summary.md) | Player normalization and planned live-player data APIs. |
| Permissions | `file-backed`, `experimental hooks`, `L2/L5` | [Permissions](permissions.md) | [AssignRole](../examples/assign-role.md) | Role files, tool guards, and command access. |
| Server | `experimental`, `restricted`, `L2/L5` | [Server](server.md) | [WelcomeMessage](../examples/welcome-message.md) | Server status, save, shutdown, and settings helpers. |
| World | `experimental`, `L2` | [World](world.md) | [LoadThreeCars](../examples/load-three-cars.md) | World load/save wrappers. |

## Gameplay and Content APIs

| Area | Labels | Page | Example | Notes |
| --- | --- | --- | --- | --- |
| Prefabs | `experimental`, `L2`, `L3 pending` | [Prefabs](prefabs.md) | [LoadCarBrz](../examples/load-car-brz.md) | BRZ/BRDB staging and load helpers. |
| Vehicles | `experimental`, `L2`, `L3 pending` | [Vehicles](vehicles.md) | [SpawnVehicleSet](../examples/spawn-vehicle-set.md) | Vehicle snapshot and spawn-set helpers. |
| Minigames | `experimental`, `L2`, `unsafe opt-ins` | [Minigames](minigames.md) | [ListMinigames](../examples/list-minigames.md) | Desired definitions, events, data cache, and guarded wrappers. |
| Archives | `offline`, `file-backed`, `L0/L2` | [Archives](archives.md) | [LoadCarBrz](../examples/load-car-brz.md) | Offline saved-world/archive inspection helpers. |

## Framework Utilities

| Area | Labels | Page | Example | Notes |
| --- | --- | --- | --- | --- |
| Timers | `stable`, `L2` | [Timers](timers.md) | [TimedBroadcast](../examples/timed-broadcast.md) | Delayed and repeating plugin tasks. |
| Events | `stable`, `L2` | [Events](events.md) | [EventAudit](../examples/event-audit.md) | Framework event subscription and emission. |
| Audit | `stable`, `L2` | [Audit](audit.md) | [EventAudit](../examples/event-audit.md) | Structured audit records. |
| Logging | `stable`, `L2` | [Logging](logging.md) | [EventAudit](../examples/event-audit.md) | Framework and plugin logs. |
| Health | `stable`, `L1/L2` | [Health](health.md) | [HealthCheck](../examples/health-check.md) | Health/version/status output. |
| Rate limits | `stable`, `L2/L5` | [Rate Limits](rate-limits.md) | [RateLimitedCommand](../examples/rate-limited-command.md) | Built-in call throttling. |
| Compatibility | `diagnostic`, `L0/L1` | [Compatibility](compatibility.md) | [HealthCheck](../examples/health-check.md) | Brickadia build targeting and compatibility checks. |
