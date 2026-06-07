# Framework Status

BMF is a server-side Lua modding framework for Brickadia, built on UE4SS.

Goal: make modded servers easier to build without every modder needing to
reverse-engineer the game. Long term, BMF should extend Brickadia's existing
mod support with more powerful server-side APIs.

## Runtime Direction

BMF currently supports the BMF-supported Omegga Windows fork:
<https://github.com/Ty-lerCox/bmf-omegga-fork>. In practice that means this
fork is part of the supported Windows server stack for launch, UE4SS
compatibility setup, command transport, player identity sync, live helper calls,
logs, and unattended validation. Stock upstream Omegga and the global npm
package are not the supported Windows runtime for BMF. The fork intentionally
trails the latest upstream Omegga builds because BMF validates against that
fork's Windows/UE4SS bridge surfaces.

## Status Legend

| Status | Meaning |
| --- | --- |
| Planned | Designed but not implemented. |
| Coded, needs validation | Implemented but not proven in a running server. |
| Live tested, experimental | Validated in a live/headless test, but still subject to change. |
| Production ready | Stable API and validation coverage. |

## Current Capabilities

| Status | Capability | Notes |
| --- | --- | --- |
| Live tested, experimental | Server broadcast messages | Send chat messages to connected players. Confirmed visible in-game, but still experimental. |
| Live tested, experimental | Private messages / whispers | `BMF.chat.whisper` can deliver to a live PlayerController with one joined player. Two-player exact targeting still needs safe identity binding validation. |
| Coded, needs validation | Lua plugin loading | Load server-side Lua plugins through BMF. |
| Coded, needs validation | Plugin permissions | Plugins can request access to features like chat, storage, world loading, and server commands. |
| Coded, needs validation | Plugin storage | Plugins can save and read their own config/data files. |
| Coded, needs validation | Timers | Plugins can run delayed or repeating tasks. |
| Coded, needs validation | Audit logs | BMF records framework and plugin actions for debugging. |
| Coded, needs validation | Rate limits | Basic protection against spammy plugin calls. |
| Coded, needs validation | Server status commands | Basic server/framework status reporting. |
| Coded, needs validation | World load/save helpers | Early helpers for loading and saving world/prefab data. |
| Coded, needs validation | Player data API | Safe normalized identity records, summary formatting, and Omegga sync exist. Health, pawn, role effects, and controller identity binding still need validation. |
| Live tested, experimental | BMF socket bridge | Optional `BMFSocket` native UE4SS mod plus Omegga loopback broker deliver BMF event records and command responses to plugins without multi-second file polling. CityRPG minigame team assignment was live-validated at about 51ms command response time with file-backed commands retained as fallback. |
| Planned | Better permission controls | More detailed control over tools, roles, and restricted actions. |
| Live tested, experimental | Applicator SpawnItem restriction | `NoSpawnItemApplicator` keeps the file-backed role policy compliant, but live validation proved `BR.Permission.SpawnItems` does not block Applicator `ItemSpawn`. The working path is an experimental native `ServerAddComponent` `UFunction::Func` blocker that denies the `ItemSpawn` component pointer and emits events consumed by BMF/Omegga chat feedback. The direct UE4SS Lua hook remains disabled after a `push_structproperty` crash. |
| Live tested, experimental | Interactable Print-to-Console prefix policy | `InteractConsolePrefixGuard` lets Owner/Admin use any prefix while everyone else is limited to whitelisted prefixes such as `buyweapon:`. Current enforcement uses an experimental native `ServerModifyComponent` `UFunction::Func` hook to block denied Interactable console tags at save time, with BMF/Omegga player identity and chat feedback where available. Live validation proved Owner allow for `teleport:` and denied-role block feedback for `teleport:deny-sim`. |
| Policy-ready | Brick asset placement policy | `scripts/list-brick-assets.js` inventories `.brdb`/`.brz` brick assets. `BMF.permissions.evaluateBrickAssetAccess` and `BrickAssetPlacementGuard` can deny assets such as `B_Joint_Wheel_Micro`, `B_Seat`, and `B_1x1_Gate_WheelEngineSlim` for non-admin roles. Live placement/paste blocking still needs a cancellable native hook. |
| Live tested, experimental | Minigame event/data API | BMF-owned minigame event emission, event-fed data snapshots, and socket-first CityRPG team assignment are validated. Creating/configuring minigames directly from Lua remains future work. |
| Planned | Avatar/player appearance API | Read or modify player appearance from server-side Lua. |
| Live tested, experimental | Omegga player sync adapter | Feeds safe Omegga player records into `BMF.players` cache after restart. On the current Windows runtime it uses a Brickadia-log fallback when Omegga's PlayerState matcher leaves the live player list empty. |
| Planned | BMF-supported Omegga Windows fork package | Make releases/install shape explicit for the supported fork, UE4SS bridge, helper globals, and BMF adapters. |
| Future research | BMF standalone supervisor | Possible long-term replacement for Omegga launch, logs, command injection, and canary orchestration. |
| Planned | Stable release package | Drag-and-drop BMF install package for UE4SS-powered Brickadia servers. |
