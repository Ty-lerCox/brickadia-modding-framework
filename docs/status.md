# Framework Status

BMF is a server-side Lua modding framework for Brickadia, built on UE4SS.

Goal: make modded servers easier to build without every modder needing to
reverse-engineer the game. Long term, BMF should extend Brickadia's existing
mod support with more powerful server-side APIs.

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
| Coded, needs validation | Lua plugin loading | Load server-side Lua plugins through BMF. |
| Coded, needs validation | Plugin permissions | Plugins can request access to features like chat, storage, world loading, and server commands. |
| Coded, needs validation | Plugin storage | Plugins can save and read their own config/data files. |
| Coded, needs validation | Timers | Plugins can run delayed or repeating tasks. |
| Coded, needs validation | Audit logs | BMF records framework and plugin actions for debugging. |
| Coded, needs validation | Rate limits | Basic protection against spammy plugin calls. |
| Coded, needs validation | Server status commands | Basic server/framework status reporting. |
| Coded, needs validation | World load/save helpers | Early helpers for loading and saving world/prefab data. |
| Planned | Player data API | Expose username, display name, UUID, controller, pawn, health, and roles. |
| Planned | Private messages / whispers | Send a message to one specific player. |
| Planned | Better permission controls | More detailed control over tools, roles, and restricted actions. |
| Planned | Applicator component restrictions | Block risky components like spawn-item while still allowing safer applicator use. |
| Planned | Minigame API | Create, configure, reset, and manage minigames from Lua. |
| Planned | Avatar/player appearance API | Read or modify player appearance from server-side Lua. |
| Planned | Stable release package | Drag-and-drop BMF install package for UE4SS-powered Brickadia servers. |
