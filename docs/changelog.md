# BMF Project Changelog

This page summarizes BMF progress in plain language. It is based on the commit
history from the initial framework setup on June 4, 2026 through the latest BMF
work on June 13, 2026.

## Where BMF Is Headed

BMF is moving toward a safer server-side Lua framework for Brickadia dedicated
servers. The project is focused on giving plugin authors useful APIs without
requiring every plugin to touch raw UE4SS helpers, unsafe console commands, or
native hooks directly.

The current direction is:

- Keep the BMF-supported Omegga Windows fork as the primary server runtime,
  bridge, validation, and metrics path.
- Prefer typed Lua APIs, capability gates, and safe defaults over broad console
  execution.
- Use socket transport for latency-sensitive gameplay events while keeping
  file-backed commands and JSONL events as durable fallback paths.
- Treat native hooks, live object scans, and runtime brick mutation as guarded
  surfaces that need clear validation and frame-time evidence.
- Keep documentation readable enough that plugin authors, server operators, and
  architects can review the system without reading every implementation file.

## Latest Focus

Runtime Brick Controls
- Added guarded runtime brick state controls for visibility and collision.
- Improved runtime brick resolution so BMF can use explicit ids, cached context,
  and Brickadia setter paths instead of relying on blind mutation.
- Added GUID-oriented runtime brick controls so higher-level systems can move
  toward safer lookup flows.

Documentation And Architecture
- Reworked the documentation into smaller pages with clearer labels, examples,
  validation links, and reader guidance.
- Added architecture diagrams for BMF alone, the Omegga fork, Lua plugin hooks,
  the event bus, ConsoleTag lookup, and CityRPG tree cutting.
- Added reference pages for dangerous surfaces, safe defaults, runtime files,
  scripts, glossary terms, and the supported runtime contract.

## Milestones So Far

Framework Foundation
- Set up the UE4SS-loadable BMF runtime and plugin package.
- Added plugin discovery, lifecycle hooks, plugin metadata, storage helpers,
  sandboxing, watchdog isolation, and capability gates.
- Added a server-console command registry so BMF can be driven from automation
  and validation runs.

Player And Chat Support
- Added normalized player records, player lookup, player summaries, and safe
  player cache syncing.
- Added chat broadcast, whisper, and status-message APIs around the currently
  validated live-player delivery route.
- Kept direct live player identity reads behind caution because some reflected
  player-state paths are still crash-prone.

Permissions And Tool Policy
- Added role-file planning for Brickadia role setup and role assignments.
- Added policy helpers for applicator components, Interactable ConsoleTag
  prefixes, brick asset placement, and command access.
- Added native-policy validation paths where file-backed permission rules alone
  are not enough to stop live tool behavior.

Minigames And CityRPG Integration
- Added minigame command wrappers, desired definition storage, data snapshots,
  event subscriptions, and synthetic flow validation.
- Added event feeds that let BMF normalize minigame activity for Lua plugins and
  Omegga integrations.
- Improved team and membership tracking so CityRPG-style plugins can consume
  BMF events instead of polling slow file paths.

Omegga Bridge And Socket Transport
- Clarified the supported Omegga fork as the main launch, bridge, player sync,
  event relay, and validation runtime.
- Added socket transport for low-latency command and event messaging.
- Hardened socket polling and command handling so latency-sensitive gameplay
  flows can avoid multi-second file-polling delays.

World, Prefab, And Vehicle Tooling
- Added world load/save wrappers for staged Brickadia worlds.
- Added prefab staging and vehicle spawn-set workflows that prepare `.brdb`
  bundles outside Lua, then load them through safe runtime wrappers.
- Added archive and vehicle snapshot tools so saved worlds can be parsed,
  checked, and turned into readable evidence.

Telemetry And Performance
- Added runtime telemetry for status, commands, events, plugin timings, worker
  throughput, socket activity, and optional native frame-time samples.
- Added frame-time validation guidance so risky polling, native work, or bursty
  traffic can be measured before it becomes a gameplay path.

## Timeline

| Date | Community-facing summary |
| --- | --- |
| June 4, 2026 | BMF started as a UE4SS Lua framework with early plugin, player, health, and command foundations. |
| June 5, 2026 | Permission and tool policy work began, including validation around role files and native guard paths. |
| June 7, 2026 | Minigame APIs, BMF manager tooling, supported Omegga runtime docs, and socket transport landed. |
| June 8, 2026 | Socket player-position work and minigame team assignment paths were hardened for faster integration traffic. |
| June 9, 2026 | Lua examples, telemetry, frame sampling, and frame-time validation docs were added. |
| June 11, 2026 | Tree-cut event support, runtime brick state APIs, and architecture diagrams were added for review. |
| June 12, 2026 | Documentation was reorganized into smaller pages, and runtime brick visibility/collision work moved forward. |
| June 13, 2026 | Runtime brick context caching, Brickadia setter usage, and GUID-oriented controls were improved. |

## Still Experimental

- Runtime brick mutation is powerful and still needs tight gates, explicit ids,
  and performance validation.
- Unsafe minigame console commands and raw object snapshots remain disabled by
  default.
- Native hooks are maintainer-owned and should stay tied to validation evidence.
- Multiplayer chat targeting and some live-player behavior still need broader
  live validation.
- Vehicle and prefab gameplay behavior is proven through saved-world evidence
  first; visual correctness and drivable behavior still need live-player checks.

## Useful Links

- [Supported Runtime Matrix](reference/supported-runtime.md)
- [Architecture Patterns](architecture/architecture-patterns.md)
- [Common Workflows](guides/common-workflows.md)
- [Current Safe Defaults](reference/current-safe-defaults.md)
- [Dangerous Surfaces](reference/dangerous-surfaces.md)
- [API Overview](api/index.md)
