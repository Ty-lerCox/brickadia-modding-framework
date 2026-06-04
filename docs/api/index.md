# API Overview

This section documents the public BMF Lua and server-console surfaces.

Status terms:

- `Planned`: designed but not implemented.
- `Coded, needs validation`: implemented but not proven in a running server.
- `Live tested, experimental`: proven in a live or headless validation pass, but
  not stable enough for production promises.
- `Production ready`: stable API and validation coverage. BMF does not claim any
  production-ready APIs yet.

## Core APIs

| Area | Page | Notes |
| --- | --- | --- |
| API registry | [API Registry](apis.md) | Runtime API listing and labels. |
| Chat | [Chat](chat.md) | Broadcast and private-message surfaces. |
| Commands | [Commands](commands.md) | Server-console command registry. |
| Plugins | [Plugins](plugins.md) | Plugin metadata, lifecycle, sandbox, and capability gates. |
| Players | [Players](players.md) | Player normalization and planned live-player data APIs. |
| Permissions | [Permissions](permissions.md) | Role and permission planning helpers. |
| Server | [Server](server.md) | Server status, save, shutdown, and settings helpers. |
| World | [World](world.md) | World load/save wrappers. |

## Gameplay and Content APIs

| Area | Page | Notes |
| --- | --- | --- |
| Prefabs | [Prefabs](prefabs.md) | BRZ/BRDB staging and load helpers. |
| Vehicles | [Vehicles](vehicles.md) | Vehicle snapshot and spawn-set helpers. |
| Minigames | [Minigames](minigames.md) | Minigame listing and lifecycle wrappers. |
| Archives | [Archives](archives.md) | Saved-world/archive inspection helpers. |

## Framework Utilities

| Area | Page | Notes |
| --- | --- | --- |
| Timers | [Timers](timers.md) | Delayed and repeating plugin tasks. |
| Events | [Events](events.md) | Framework event subscription and emission. |
| Audit | [Audit](audit.md) | Structured audit records. |
| Logging | [Logging](logging.md) | Framework and plugin logs. |
| Health | [Health](health.md) | Health/version/status output. |
| Rate limits | [Rate Limits](rate-limits.md) | Built-in call throttling. |
| Compatibility | [Compatibility](compatibility.md) | Brickadia build targeting and compatibility checks. |
