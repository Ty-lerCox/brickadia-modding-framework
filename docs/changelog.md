# BMF Changelog

Latest updates are listed first. Each update gets a version heading and a short
set of category sections underneath it.

## BMF v0.1.0-ea2.cl13530 - Portable Desktop Setup (June 26, 2026)

Desktop
- Added Easy mode as the default portable app surface for selecting a Windows
  Brickadia Dedicated Server folder and reviewing core BMF health.
- Added Easy-mode install, repair, start, and restart action buttons for rows
  that report a remediation action.
- Fixed packaged portable health checks so stale temporary extraction paths do
  not keep the UI stuck on placeholder unknown rows.

Release
- Added portable exe output to the BMF Desktop release shape alongside MSI,
  release manifest, catalog, checksums, and notes.
- Labeled the release target as Brickadia EA2 `PC-Shipping-CL13530`.

Docs
- Reworked the examples navigation into grouped sections.
- Added a portable-first Windows setup flow and documented that Linux/WSL are
  not supported for the UE4SS/BMF dedicated-server runtime.
- Refocused first-install documentation on BMF Desktop Easy mode: download the
  portable exe, target the Brickadia Dedicated Server folder, then use
  install/repair/start/restart health actions.

## BMF v0.1.0 - Foundation Update (June 13, 2026)

Project Direction
- BMF is being built as a safer server-side Lua framework for Brickadia dedicated servers.
- The BMF-supported Omegga Windows fork is the main supported runtime for launching, bridging, validation, player sync, events, and metrics.
- Typed Lua APIs, capability gates, and safe defaults are preferred over broad raw console execution.
- Socket transport is the live path for latency-sensitive gameplay messaging; JSONL logs are kept as diagnostics and audit evidence.
- Native hooks, live object scans, and runtime brick mutation remain guarded surfaces that need validation before regular gameplay use.

Framework
- Added a UE4SS-loadable BMF runtime package.
- Added plugin discovery, plugin metadata, lifecycle hooks, reload support, and plugin-owned command cleanup.
- Added scoped plugin APIs so plugins can use BMF helpers without receiving unrestricted framework access.
- Added plugin storage helpers for config files and plugin-owned state.
- Added capability checks for sensitive APIs such as chat, server saves, server exec, world loading, prefab loading, vehicle spawning, and storage.
- Added a plugin watchdog that isolates repeatedly failing plugins instead of letting one plugin keep breaking framework hooks or commands.
- Added sandbox rules that block dangerous UE4SS and native globals from normal plugin code.

Commands
- Added the `bmf.*` command registry for server-console and bridge automation.
- Added command output that is stable enough for scripts and validation runs to parse.
- Added socket-backed command transport for faster Omegga-to-BMF calls.
- Added access-checked command dispatch for routes that already have trustworthy actor identity.
- Added command validation for success paths, denied paths, unknown commands, reload behavior, and plugin-owned commands.

Omegga
- Added support for the BMF-supported Omegga Windows fork as the primary operating model.
- Added Omegga bridge support for BMF commands, player sync, minigame event feeds, chat helper delivery, and validation.
- Added socket relay support so Omegga plugins can receive BMF events without waiting on file polling.
- Improved socket polling and team-assignment flows so CityRPG-style plugins can respond faster.
- Report socket transport outages as unhealthy instead of silently falling back to files.

Players
- Added normalized player records for safer player identity handling.
- Added player listing, lookup, name resolution, summary, and whisper-summary helpers.
- Added Omegga-fed player cache syncing through `runtime/players.json`.
- Added Brickadia log and saved-data identity support for safer fallback player records.
- Avoided direct live `PlayerState` identity reads where current evidence shows crash risk.
- Added player fixture validation and headless messaging checks.

Chat
- Added BMF chat broadcast support.
- Added private whisper and status-message APIs.
- Added live-player delivery through the currently validated player-controller chat path.
- Kept two-player targeting and broader multiplayer chat validation marked as pending until the identity path is safer.

Permissions
- Added role-file planning for `RoleSetup2.json`.
- Added player role assignment planning for `RoleAssignments.json`.
- Added role and permission helpers for policy plugins.
- Added command access policy helpers for actor-aware command routes.
- Added validation for copied role files, duplicated permissions, denied command paths, and fail-closed policy behavior.

Tool Policy
- Added applicator component policy helpers for blocking unsafe components while preserving normal applicator access.
- Added Interactable ConsoleTag prefix policy for restricting Print-to-Console usage.
- Added brick asset placement policy for denying configured assets such as vehicle parts or other restricted bricks.
- Added native-policy validation paths where Brickadia role files alone do not stop the live tool behavior.
- Kept placement and paste blocking marked as experimental until a cancellable hook is proven.

Minigames
- Added minigame list and lifecycle wrappers with unsafe console paths disabled by default.
- Added BMF-owned desired minigame definitions.
- Added minigame definition listing, lookup, delete, and reconciliation helpers.
- Added direct minigame snapshot import into BMF-owned data.
- Added minigame data queries for players, teams, membership, leaderboards, and player state.
- Added minigame event subscriptions and normalized event names for Lua plugins and Omegga relays.
- Improved team and membership tracking for CityRPG-style workflows.
- Added synthetic minigame flow validation for create, join, team, round, leaderboard, kill, leave, and delete checkpoints.

Worlds
- Added world SaveAs support through BMF.
- Added additive world-load wrappers for staged Brickadia worlds.
- Added command routes for headless world save and load validation.
- Added validation that saved worlds can be parsed after BMF-driven load and save flows.

Prefabs
- Added prefab staging support for converting `.brz` prefabs into server-loadable `.brdb` world bundles.
- Added Lua and command-worker wrappers for loading staged prefab worlds.
- Kept prefab conversion outside the Lua runtime so BMF does not rewrite archive files inside UE4SS.
- Added validation that staged prefab worlds can load, save, and preserve vehicle-like dynamic actor evidence.

Vehicles
- Added vehicle spawn-set planning for loading several staged vehicle worlds at separated positions.
- Added vehicle spawn-set runtime helpers.
- Added vehicle snapshot commands for saving a running world and producing vehicle evidence.
- Added vehicle inventory reports for saved worlds and snapshot evidence.
- Added staged vehicle id remapping so duplicate vehicle copies can load as separate groups.
- Kept visual correctness and drivable behavior marked for live-player validation.

Runtime Bricks
- Added runtime brick inspection, resolution, and state APIs.
- Added guarded visibility and collision mutation for explicit runtime brick ids.
- Added runtime brick context caching so repeated lookups can reuse safer context.
- Added Brickadia setter usage for runtime brick state instead of relying only on lower-level mutation.
- Added generic runtime brick GUID controls for higher-level lookup flows.
- Added UUID-first runtime brick lookup with canonical `lookup:<uuid>:<purpose>` tags and cache-only native tag lookup fallback.
- Added a runnable Lua example for changing runtime brick visibility and collision directly or through a bound GUID.
- Kept runtime brick mutation behind environment gates and validation requirements.

Tree Cutting
- Added tree-cut event support for CityRPG-style workflows.
- Added resource-native command/API aliases for shared handaxe and pickaxe hit capture; old treecut command names remain compatibility aliases.
- Added diagrams explaining how native resource events flow into BMF and Lua.
- Added runtime brick state patterns for hiding and restoring physical tree bricks.
- Added ConsoleTag lookup patterns for connecting gameplay ids to runtime brick operations.

Telemetry
- Added runtime health output.
- Added command, event, plugin, worker, and socket telemetry.
- Added optional native frame-time sampling through `BMFFrameTelemetry`.
- Added frame-time validation guidance for polling, native mutation, live scans, and bursty event traffic.
- Added Omegga metrics export expectations for Grafana-style monitoring.

Documentation
- Added Lua examples for chat, timers, commands, storage, server settings, world loading, prefabs, vehicles, minigames, permissions, events, audit, health, and rate limits.
- Split large API pages into smaller pages for permissions, archives, minigames, plugins, players, and server APIs.
- Renamed proposed architecture diagrams into Architecture Patterns.
- Added architecture diagrams for the required BMF/Omegga runtime stack, Omegga-owned supervision, Lua plugins, event bus messaging, ConsoleTag lookup, Lua hook ingress, and tree cutting.
- Added common workflows, glossary, supported runtime, safe defaults, dangerous surfaces, runtime files, script reference, and maintainer notes.
- Added documentation style checks and MkDocs strict build validation.

Bugs
- Fixed unsafe plugin globals being reachable from normal plugin code.
- Fixed plugin-owned commands and event handlers surviving plugin reloads.
- Fixed plugin failures repeatedly running after watchdog isolation should stop them.
- Fixed malformed plugin JSON storage throwing instead of returning a structured error.
- Fixed missing capability paths so sensitive plugin APIs fail closed.
- Fixed unsafe minigame command paths so they fail closed unless explicitly enabled.
- Fixed command access policy paths so denied commands return handled denial output.
- Fixed player lookup and summary behavior for empty headless servers.
- Fixed socket command polling paths that could make gameplay integrations wait too long.
- Fixed runtime brick lookup paths to require explicit ids or validated context before mutation.
