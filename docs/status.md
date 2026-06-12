# Framework Status

BMF is a server-side Lua modding framework for Brickadia, built on UE4SS.

Goal: make modded servers easier to build without every modder needing to
reverse-engineer the game.

## Who Should Read This?

Server operators should use this page to understand what is safe to rely on
today. Plugin authors should use it to avoid depending on unvalidated behavior.
BMF maintainers should use it as the public capability dashboard.

## Executive Summary

| Area | Current state |
| --- | --- |
| Supported runtime | Windows Brickadia dedicated server through the BMF-supported Omegga fork. |
| Stability | Experimental framework bring-up; no production-ready API claim yet. |
| Best-supported plugin path | Lua plugins, capability gates, storage, events, timers, audit/logging, and command registration. |
| Best-supported integration path | Omegga bridge plus BMFSocket when available, with file-backed command/event fallback. |
| Highest-risk lane | Native hooks, runtime brick mutation, unsafe console/object probes, and live-player identity paths. |
| Required performance gate | `L6 Frame Time` for polling, native mutation, bursty events, live scans, or frequent commands. |

See the [Supported Runtime Matrix](reference/supported-runtime.md) for runtime
ownership and [API Validation Evidence](validation/api-validation.md) for proof
history.

## Capability Dashboard

| Capability | Status | Validation | Primary docs |
| --- | --- | --- | --- |
| Plugin loading, lifecycle, storage | Coded, needs validation | `L2`, `L5` for sandbox/watchdog | [Plugins](api/plugins.md) |
| Events, audit, logging, timers, rate limits | Coded, needs validation | `L2`, selected `L5` | [Events](api/events.md), [Audit](api/audit.md), [Logging](api/logging.md), [Timers](api/timers.md), [Rate Limits](api/rate-limits.md) |
| Server-console command registry | Live tested, experimental | `L2`, `L5` | [Commands](api/commands.md) |
| Broadcast and whisper delivery | Live tested, experimental | `L3` single-player | [Chat](api/chat.md) |
| Player identity cache | Live tested, experimental | `L2`; targeted live identity still needs `L3+` | [Players](api/players.md) |
| World save/load helpers | Coded, needs validation | `L2` | [World](api/world.md) |
| Prefab and vehicle staging/loading | Live tested, experimental | `L2`; drivable/visual proof still needs `L3` | [Prefabs](api/prefabs.md), [Vehicles](api/vehicles.md), [Archives](api/archives.md) |
| Minigame events and data cache | Live tested, experimental | `L2`, `L5`; gameplay effects need `L3+` | [Minigames](api/minigames.md) |
| BMF socket bridge | Live tested, experimental | `L2`, CityRPG live integration evidence | [Supported Runtime Matrix](reference/supported-runtime.md) |
| Observability and frame telemetry | Live tested, experimental | `L6` required for performance-sensitive features | [Observability and Performance](architecture/observability-performance.md) |
| Role files and command access policy | Coded, needs validation | `L2`, `L5` | [Permissions](api/permissions.md) |
| Applicator and Interactable live guards | Live tested, experimental | `L3`, selected `L5`; native hook lane | [Applicator Policy](api/permissions/applicator-policy.md), [Interactable Tags](api/permissions/interactable-tags.md) |
| Brick asset placement policy | Policy-ready | `L2`, `L5`; live hook still pending | [Brick Assets](api/permissions/brick-assets.md) |
| Runtime brick state API | Live tested, experimental | `L2`; broader gameplay needs `L6` | [Runtime Brick State](api/runtime-bricks.md) |

## Current Blockers

| Blocker | Impact | Owner path |
| --- | --- | --- |
| Two-player identity targeting | Whisper and player-bound policy cannot claim isolation yet. | Player identity adapter and `L4 Multiplayer` validation. |
| Native hook pointer refresh | Applicator/Interactable hooks are per-process and restart-sensitive. | [Native Hook Notes](maintainers/native-hooks.md). |
| Runtime brick mutation frame-time proof | Tagged tree physical hide/restore cannot be promoted broadly without frame evidence. | [Observability and Performance](architecture/observability-performance.md). |
| Live placement/paste cancellation | Brick asset policy is not live-enforced before world mutation. | Future cancellable native hook. |
| Unsafe minigame console/object probes | Some legacy routes can crash the server. | Prefer [Minigame Events](api/minigames/events.md) and [Data Snapshot](api/minigames/data.md). |

## Validation Stages

Validation labels are defined in the [Glossary](reference/glossary.md). Use
[Canary Contract](validation/canary-contract.md) when adding new evidence.

Run `L6 Frame Time` for any feature that polls, loops over players, sends
frequent BMF commands, reads live player positions, scans UObjects, mutates
Brickadia state, or handles bursty minigame traffic.

## Near-Term Documentation Direction

- Keep API pages focused on contracts, parameters, labels, and examples.
- Keep validation history in [API Validation Evidence](validation/api-validation.md).
- Keep native hook implementation notes in [Native Hook Notes](maintainers/native-hooks.md).
- Keep architecture explanations in [Architecture Patterns](architecture/architecture-patterns.md).
