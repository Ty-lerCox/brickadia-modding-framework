# Standalone Runtime Future Track

This is a future independence track, not the current first-package direction.
BMF currently supports the BMF-supported Omegga Windows fork because that fork
is acting as the Windows server supervisor, UE4SS installer/compatibility
manager, command bridge, log source, player-sync source, and helper surface for
some live player calls.

Standalone BMF remains possible, but it would mean replacing those Omegga-owned
responsibilities with BMF-owned runtime surfaces.

## Who Should Read This?

Architects and BMF maintainers should use this page when reviewing a future
non-Omegga runtime. Server operators should treat it as future direction, not
current install guidance.

## Target Shape

BMF has four runtime layers:

| Layer | Responsibility |
| --- | --- |
| BMF UE4SS Core | Lua framework, plugin loader, public APIs, capability gates, audit logs, and in-game Brickadia calls. |
| BMF Native Helpers | Small UE4SS-facing helpers for safe console execution, client RPC delivery, player/controller discovery, and command-worker wakeups. |
| BMF Supervisor | Windows-side process launcher for starting, stopping, restarting, log tailing, command injection, and unattended canaries. |
| BMF Installer | Installs UE4SS, BMF, compatibility files, examples, and optional adapters into a Brickadia dedicated server. |

The UE4SS core should remain usable without the supervisor when the server is
already running. The supervisor exists for operations that cannot live inside
Brickadia safely, such as process lifecycle, crash recovery, and package update
work.

## Omegga Replacement Map

| Need | Standalone BMF owner |
| --- | --- |
| Server launch and restart | BMF Supervisor |
| Server log tailing and crash evidence | BMF Supervisor |
| `bmf.*` command injection | BMF Supervisor socket transport |
| Console command execution inside Brickadia | BMF Native Helpers with provider-neutral names |
| Broadcasts and whispers | `BMF.chat` through safe PlayerController client RPC calls |
| Player username, display name, UUID, and counts | `BMF.players` through Brickadia logs, saved caches, and safe live-controller adapters |
| Plugin runtime | BMF UE4SS Core |
| Plugin config/data storage | BMF UE4SS Core |
| Permissions, roles, and tool restrictions | `BMF.permissions` plus file-backed and live adapters |
| World load/save and prefab staging | `BMF.world`, `BMF.prefabs`, and archive tooling |
| Web UI and metrics | Future optional BMF admin service |

## Future Migration Rules

- Do not start standalone replacement work by deleting current Omegga
  integration files.
- Treat `packages/omegga-plugins/` as the canonical supported adapter source.
  Legacy `integrations/omegga/` copies are compatibility inputs only until the
  old layout is removed.
- Prefer provider-neutral helper names in new Lua, scripts, and docs.
- Keep existing Omegga-backed canaries as active proof until replacement BMF
  canaries exist.
- Standalone validation goals should explicitly state that they are replacing a
  current Omegga responsibility.

## Immediate Work Queue

1. Add a BMF Supervisor socket client that can replace Omegga-owned BMF Bridge
   canaries.
2. Rename the runtime executor abstraction around provider-neutral helper names,
   while keeping compatibility shims for older helper globals when present.
3. Promote the Brickadia-log player identity adapter as the default
   no-Omegga player list source.
4. Replace chat delivery helper names with BMF-owned native helper names while
   preserving the confirmed `ClientPushChatMessage` route.
5. Move scripts away from `omegga-master/omegga-master/data` defaults and into
   explicit Brickadia server data paths.
6. Build the BMF Supervisor for launch, stop, restart, log watching, command
   injection, and canary orchestration.
7. Add a standalone live-player validation target: join server, run
   `BMF.players.summary(..., whisper=true)`, confirm visible output, and record
   evidence without Omegga.

## Done Criteria

The standalone track is complete only if a clean Windows Brickadia dedicated
server can be installed, started, commanded, validated, and live-player tested
with only Brickadia, UE4SS, and BMF-owned files. That is not required for the
first BMF package.
