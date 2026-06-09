# API Overview

This section documents the public BMF Lua and server-console surfaces.

Every API page should include Lua usage. The central [Lua examples](../examples/index.md)
page collects complete plugin examples and links to runnable `examples/`
folders, following the same reference-plus-example model used by component
documentation.

Status terms:

- `Planned`: designed but not implemented.
- `Coded, needs validation`: implemented but not proven in a running server.
- `Live tested, experimental`: proven in a live or headless validation pass, but
  not stable enough for production promises.
- `Production ready`: stable API and validation coverage. BMF does not claim any
  production-ready APIs yet.

## Core APIs

| Area | Page | Example | Notes |
| --- | --- | --- | --- |
| API registry | [API Registry](apis.md) | [InspectApiLabels](../examples/index.md#inspectapilabels) | Runtime API listing and labels. |
| Chat | [Chat](chat.md) | [HelloBroadcast](../examples/index.md#hellobroadcast) | Broadcast and private-message surfaces. |
| Commands | [Commands](commands.md) | [Plugin Command](../examples/index.md#plugin-command) | Server-console command registry. |
| Plugins | [Plugins](plugins.md) | [Plugin Storage](../examples/index.md#plugin-storage) | Plugin metadata, lifecycle, sandbox, and capability gates. |
| Players | [Players](players.md) | [PlayerSummary](../examples/index.md#playersummary) | Player normalization and planned live-player data APIs. |
| Permissions | [Permissions](permissions.md) | [AssignRole](../examples/index.md#assignrole) | Role and permission planning helpers. |
| Server | [Server](server.md) | [WelcomeMessage](../examples/index.md#welcomemessage) | Server status, save, shutdown, and settings helpers. |
| World | [World](world.md) | [LoadThreeCars](../examples/index.md#loadthreecars) | World load/save wrappers. |

## Gameplay and Content APIs

| Area | Page | Example | Notes |
| --- | --- | --- | --- |
| Prefabs | [Prefabs](prefabs.md) | [LoadCarBrz](../examples/index.md#loadcarbrz) | BRZ/BRDB staging and load helpers. |
| Vehicles | [Vehicles](vehicles.md) | [SpawnVehicleSet](../examples/index.md#spawnvehicleset) | Vehicle snapshot and spawn-set helpers. |
| Minigames | [Minigames](minigames.md) | [ListMinigames](../examples/index.md#listminigames) | Minigame listing and lifecycle wrappers. |
| Archives | [Archives](archives.md) | [LoadCarBrz](../examples/index.md#loadcarbrz) | Saved-world/archive inspection helpers. |

## Framework Utilities

| Area | Page | Example | Notes |
| --- | --- | --- | --- |
| Timers | [Timers](timers.md) | [TimedBroadcast](../examples/index.md#timedbroadcast) | Delayed and repeating plugin tasks. |
| Events | [Events](events.md) | [EventAudit](../examples/index.md#eventaudit) | Framework event subscription and emission. |
| Audit | [Audit](audit.md) | [EventAudit](../examples/index.md#eventaudit) | Structured audit records. |
| Logging | [Logging](logging.md) | [EventAudit](../examples/index.md#eventaudit) | Framework and plugin logs. |
| Health | [Health](health.md) | [HealthCheck](../examples/index.md#healthcheck) | Health/version/status output. |
| Rate limits | [Rate Limits](rate-limits.md) | [RateLimitedCommand](../examples/index.md#ratelimitedcommand) | Built-in call throttling. |
| Compatibility | [Compatibility](compatibility.md) | [HealthCheck](../examples/index.md#healthcheck) | Brickadia build targeting and compatibility checks. |
