# API Validation Evidence

This page keeps canary coverage and validation history out of API reference
pages. API pages should state the current contract and link here for proof
level.

Validation levels are defined in [Framework Status](../status.md).

## Who Should Read This?

BMF maintainers should use this page to update proof history without bloating
API references. Plugin authors and server operators should use it when an API's
current safety level matters.

## Commands

- `L0 Static`: package validator checks command API markers and docs.
- `L2 Headless`: `scripts/validate-bmf-console-commands.ps1` starts a
  disposable bridge server and invokes `bmf.status`, `bmf.health`,
  `bmf.version`, `bmf.plugins`, `bmf.commands`, `bmf.canary`, `bmf.unload`,
  `bmf.load`, and `bmf.reload` through `BMF Bridge socket`.
- `L2 Headless`: `scripts/validate-bmf-admin-commands.ps1` invokes
  `bmf.players.list`, `bmf.chat.broadcast`, and the fail-closed
  `bmf.minigames.list` command.
- `L2 Headless`: prefab, vehicle, world-save, and snapshot command canaries
  prove staged loads can be saved and parsed.
- `L2 Headless + L5 Negative`: shutdown, unsafe minigame, invalid preset/index,
  command access, and dispatch-access canaries prove fail-closed behavior.
- `L3 Live Player`: still required before mapping these commands into chat
  commands or player-authenticated staff commands.

## Server

- `L0 Static`: fixture patching and Lua input validation.
- `L2 Headless`: copied live `GameUserSettings.ini` patching, structured server
  status, `BMF.server.save` writing a parseable BRDB, and
  `BMF.server.shutdown` safely reporting the current unsupported executor path
  after confirmation.
- `L5 Negative`: plugin capability denial and config opt-in denial for
  unrestricted console execution, plus missing-confirmation denial for
  shutdown.
- `L3 Live Player`: still required before proving changed welcome messages and
  player caps in a running server.
- Runtime hot-reload is still unknown; these settings may require restart.

## Chat

- `L3 Live Player`: `ClientPushChatMessage` visible UI delivery is confirmed
  for broadcast and one-target whisper-style delivery.
- `L2 Headless`: if no live controllers are available, BMF may fall back to
  legacy console command acceptance. That fallback does not imply visible
  delivery.
- The validated route avoids live `PlayerState` reflection. Player names and
  UUIDs should come from Omegga player sync and/or Brickadia saved/log context.
- Two-player negative targeting still needs a safe identity adapter and a
  second joined player before BMF can claim only the intended recipient sees a
  whisper.

## Plugins

- `L0 Static`: package validator checks plugin/storage API markers and docs.
- `L2 Headless`: lifecycle and storage canaries load temporary plugins, verify
  metadata, persist storage, prove malformed JSON returns `JSON_PARSE_FAILED`,
  exercise reload/unload, and prove lifecycle hooks.
- `L2 Headless + L5 Negative`: unsafe-global, watchdog, and capability-gate
  canaries prove plugins fail closed without required gates or after repeated
  plugin failures.

## API Labels

- `L2 Headless`: `scripts/validate-bmf-api-labels.ps1` loads a temporary plugin
  and proves `BMF.apis.get`, `BMF.apis.list`, and `BMF.apis.summary`.
- The canary verifies representative labels across chat, lifecycle, storage,
  shutdown, permissions, runtime brick state, restricted exec, world, vehicles,
  and filters.

## Framework Utilities

- `L0 Static`: package validators check health, compatibility, timers, events,
  audit, logging, and rate-limit API markers.
- `L1 Boot`: BMF writes runtime status and health data during server boot.
- `L2 Headless`: utility canaries cover timers, events, audit tail, framework
  logs, plugin logs, compatibility helpers, health/version commands, and
  rate-limit status.
- `L5 Negative`: rate-limit canaries prove repeated calls are denied and
  recorded in audit/status evidence.
- `L6 Frame Time`: native frame telemetry is handled through the observability
  workflow when performance risk is part of the status decision.

## Runtime Brick State

- Clean-restart canary hid and restored one UUID/purpose lookup target, with
  explicit runtime ids reserved for diagnostics and verified cache entries.
- GUID/tag-only mutation is accepted through the queued GUID path; without an
  existing binding, explicit position, or cached exact tag candidate, the final
  status returns `BRICK_RUNTIME_GUID_LOOKUP_MISS`.
- Native validation checks the returned brick's internal runtime id before using
  Brickadia visibility/collision setters.
- Broader gameplay use still needs conservative gates and `L6 Frame Time`
  evidence.

## Minigames

- `L0 Static`: command formatting and preset directory listing.
- `L1 Boot`: BMF Lua wrappers load and execute on a disposable headless server.
- `L2 Headless`: unsafe minigame console wrappers fail closed without reaching
  Brickadia.
- `L2 Headless event-log`: `scripts/validate-bmf-events.ps1` emits a
  namespaced `minigames.kill` canary and verifies it reaches
  `runtime/events.jsonl`.
- `L2 Headless data-status/data-query`: minigame event canaries update
  `bmf.minigames.data.status` and prove data snapshot/list/get/player/team/
  leaderboard/membership queries return stable JSON context.
- `L2 Headless leave-reducer`: `leaveminigame` removes current membership.
- `L2 Headless synthetic-flow`: create, join, team, round, leaderboard, kill,
  leave, and delete reducer checkpoints pass with data restoration.
- `L2 Headless event-subscribe`: `BMF.minigames.on`, `off`, listener counts,
  event aliases, and normalized `_bmf` metadata are covered.
- `L2 Headless + L5 Negative`: minigame command canaries cover fail-closed
  unsafe wrappers, desired-definition set/list/get/delete, and invalid
  preset/index rejection.
- `L3 Live Player`: joining, membership, teams, scoring, and gameplay effects.
- `L5 Negative`: permission or policy enforcement around minigame edits.

## Permissions

- `L0 Static`: role fixture patching.
- `L2 Headless`: local `RoleSetup2.json` and `RoleAssignments.json` copy
  patching, runtime Lua policy evaluation, runtime Lua role-assignment
  read/query helpers, and command access policy evaluation.
- `L5 Negative`: duplicate permission entries are rejected by the policy
  evaluator, and command policy denies/default denies are exercised headlessly.
- Applicator SpawnItem role policy is file-compliant, but live testing proved
  `BR.Permission.SpawnItems` does not block Applicator `ItemSpawn` placement by
  itself.
- The working live Applicator path is the experimental native
  `ServerAddComponent` blocker plus BMF/Omegga feedback.
- The direct UE4SS Lua Applicator hook remains disabled after a struct
  marshaling crash on `PC-Shipping-CL13530`.
- Interactable Print-to-Console prefix policy has live validation for Owner
  allow and denied-role block feedback.
- Brick asset placement is policy-ready; live placement/paste blocking still
  needs a cancellable native hook.

## Archives, Vehicles, And Prefabs

- `validate-archive-fixtures.ps1` covers known `.brdb` fixture entity and
  dynamic actor counts.
- `validate-vehicle-snapshot.ps1` covers known vehicle-like graph expectations
  for car fixtures.
- Server snapshot canaries save running worlds and parse saved BRDB output.
- Prefab staging canaries convert `Car.brz`, stage it to `Saved/Worlds`, load it
  additively, save the world, and assert the vehicle graph survived.
- Dynamic actor slice canaries prove graph-closure slices can load additively
  and save back with the expected vehicle-like graph.
- Vehicle spawn-set canaries prove remapped staged copies can load as isolated
  vehicle-like groups.
- `L3 Live Player` is still required before claiming staged vehicles are
  visually correct or drivable.
