# BMF Roadmap and TODO

BMF means Brickadia Modding Framework. The project goal is to provide a
server-side Lua framework for Windows Brickadia dedicated servers, backed by
UE4SS and Brickadia-specific reverse engineering.

Direction update: BMF currently supports and depends on a BMF-compatible Omegga
runtime for Windows server launch, UE4SS setup, command transport, server logs,
player identity sync, live helper calls, and unattended canaries. Upstream
Omegga is not assumed sufficient unless it includes the BMF compatibility work.

This file is intentionally broad. Each item should eventually become either a
GitHub issue, a documentation page, a canary, or a tracked research note.

Use the validation levels in `docs/status.md` and the canary contract when
classifying proof for static, headless, live-player, and frame-time work.

## Priority Legend

- `P0`: Required to ship the first usable framework.
- `P1`: High-value public API after the first package works.
- `P2`: Important server administration or gameplay API.
- `P3`: Larger research-heavy feature.
- `P4`: Nice-to-have ecosystem/tooling feature.

## Runtime Dependency Direction

- [ ] `P0` Define the BMF-compatible Omegga runtime.
  - Track the exact Omegga fork/build, Windows requirements, UE4SS bundle,
    bridge mod, helper globals, environment variables, and plugin install
    shape BMF needs.
  - Validation: `L0 Static` manifest and docs, then `L1 Boot`.
- [ ] `P0` Package or reference the supported Omegga runtime.
  - BMF should not depend on an ambiguous upstream checkout.
  - Release docs should explain whether users install a BMF-maintained Omegga
    fork, a patched release artifact, or a future upstream Omegga build.
  - Validation: `L0 Static`, then `L1 Boot`.
- [ ] `P0` Keep `Omegga.Bridge.BMF` command transport supported.
  - This is the current validated route into the BMF command worker.
  - Add canary coverage for every public `bmf.*` command that relies on it.
  - Validation: `L2 Headless`.
- [ ] `P0` Keep BMF chat delivery compatible with the Omegga/UE4SS helper path.
  - Visible chat currently depends on live `PlayerController` fanout plus
    `CallFunctionByNameWithArguments` helper support from the compatible
    Omegga/UE4SS bridge stack.
  - Validation: `L3 Live Player`.
- [ ] `P0` Keep Omegga player sync as a supported adapter.
  - The Brickadia-log adapter is still useful, but Omegga-fed identity records
    should remain a first-class supported source.
  - Progress: after a full Omegga restart on June 4, 2026, the BMF Player Sync
    adapter populated `runtime/players.json` with Ty through
    `source=omegga.players.raw.interval.log-fallback`.
  - Gap: Omegga's native `getPlayers()` list still remains empty on the current
    Windows runtime because its PlayerState/PlayerController matcher does not
    complete; controller/state paths are not proven from Omegga sync yet.
  - Validation: `L2 Headless` for cache parsing and `L3 Live Player` for
    visible summary whisper.
- [ ] `P1` Add dependency health checks.
  - `bmf.health` should report Omegga bridge/helper availability clearly enough
    to explain why command transport, player sync, or chat delivery is down.
  - Validation: `L2 Headless`.
- [ ] `P3` Keep standalone BMF as a future independence track.
  - Replacing Omegga would require BMF-owned server launch, UE4SS install,
    command injection, log watching, player sync, and native helper surfaces.
  - This is not the first package direction.
  - Validation: separate research plan.

## Status Legend

- `Proven`: Existing local evidence shows the underlying route works.
- `Partial`: Some primitives exist, but the public BMF API still needs work.
- `Research`: Needs discovery, hooks, signatures, or runtime proof.
- `Unsafe`: Known to be crash-prone or dependent on stale pointers/context.
- `Blocked`: Cannot be completed without a live player, new evidence, or a new
  reverse-engineering breakthrough.

## Validation Levels

Every feature should have a validation level before a goal-mode task can be
called complete.

- `L0 Static`: Package layout, manifest, hashes, docs, and scripts validate
  without starting Brickadia.
- `L1 Boot`: Brickadia dedicated server starts with UE4SS and BMF loaded.
- `L2 Headless`: A canary passes without a connected player/controller.
- `L3 Live Player`: A canary passes with one connected player.
- `L4 Multiplayer`: A canary passes with two or more players.
- `L5 Negative`: Abuse prevention or failure behavior is tested, not only the
  happy path.
- `L6 Frame Time`: Native frame telemetry is captured before, during, and after
  the feature path. Evidence records average/max frame time, slow-frame
  counters, command/worker attribution, and whether disabling the feature
  returns frame time toward baseline.

Goal-mode completion rule: a feature is not done until the implementation,
public docs, example if relevant, and validation artifact are all updated.
Performance-sensitive features are not complete until they also have `L6 Frame
Time` evidence or an explicit documented reason why frame-time testing is not
applicable.

## Known Starting Evidence

These are the local findings this roadmap assumes.

- `chat.broadcast` has working bridge/demo evidence on CL13530.
- `chat.whisper` is live-proven for a single joined player through
  `ClientPushChatMessage` on a live `PlayerController`. Exact two-player
  targeting still needs safe identity binding from Omegga player sync and/or
  Brickadia saved/log adapters.
- `chat.status_message` shares the private-message route, but status-specific
  UI semantics are not separately proven yet.
- `players.list` has partial bridge support, but player object/property reads
  must be treated carefully because CL13530 notes identify crash-prone object
  access paths.
- `server.status` exists as a bridge route, but public BMF should return
  structured data instead of console text.
- `BR.World.SaveAs` and `BR.World.LoadAdditive` work through the UE4SS
  consolemanager executor for basic command transport.
- `.brz` and `.brdb` archive parsing/writing can be validated headlessly before
  testing in a live server.
- Native prefab replay can depend on live player/controller context and should
  stay experimental until a fully server-side path is proven.

## Phase 0: Project Foundation

Goal: make BMF installable, inspectable, and safe to iterate on before exposing
more Brickadia APIs.

- [ ] `P0` Create repository structure.
  - Proposed folders: `framework/`, `examples/`, `docs/`, `installer/`,
    `scripts/`, `tests/canaries/`, `artifacts/`, `manifests/`.
  - Validation: `L0 Static`.
- [ ] `P0` Define BMF package manifest.
  - Include BMF version, supported Brickadia build IDs, required UE4SS build,
    required custom signatures, and compatibility status.
  - Validation: `L0 Static`.
- [ ] `P0` Package the current CL13530 compatibility bundle.
  - Include `VTableLayout.ini`, `CustomGameConfigs/Brickadia`, signatures, and
    a compatibility manifest.
  - Validation: `L0 Static`, then `L1 Boot`.
- [ ] `P0` Build Windows installer script.
  - Input: Brickadia server Win64 directory.
  - Actions: detect server executable, stop on running process, back up
    overwritten files, install UE4SS/BMF layout, write install log.
  - Progress: `installer/install-bmf.ps1` installs the BMF UE4SS mod folder into
    `<ServerWin64Dir>\ue4ss\main\Mods\BMF`, refuses to run against a matching
    running server process, backs up preexisting `Mods/BMF` when `-Force` is
    used, and writes `runtime/install-manifest.json`.
  - Validation: `L0 Static` with temp directories, then `L1 Boot` on a test
    server.
- [ ] `P0` Build uninstall/rollback script.
  - Restore backups and remove BMF-owned files only.
  - Progress: `installer/uninstall-bmf.ps1` removes BMF with a backup of the
    removed directory or restores a backup created by the installer.
  - Progress: `scripts/validate-windows-installer.ps1` validates install,
    backup replacement, rollback, and remove-only uninstall in a temp fake
    server tree.
  - Validation: `L0 Static`.
- [ ] `P0` Add `bmf.version` and `bmf.health`.
  - Should report BMF version, Brickadia build, UE4SS status, signature bundle,
    bridge status, and loaded plugin count.
  - Progress: `BMF.health()` reports version, target build, compatibility
    status, UE4SS helper availability, paths, audit counts, and plugin counts.
  - Progress: `BMF.version` is a stable runtime version string, `bmf.health`
    aliases the health command output, and `bmf.version` prints version/build
    identity through the command worker.
  - Progress: `scripts/validate-bmf-console-commands.ps1` invokes
    `bmf.health` and `bmf.version` on a disposable headless bridge server, and
    `scripts/validate-bmf-api-labels.ps1` proves the `BMF.version` API label.
  - Validation: `L2 Headless`.
- [ ] `P0` Add structured result contract.
  - Standard shape: `{ ok, code, message, data }`.
  - Reuse the existing draft error-code approach from the Brickadia API notes.
  - Validation: unit tests or static Lua checks.
- [ ] `P0` Add canary artifact format.
  - Every canary writes `artifacts/canaries/<name>.json`.
  - Include `feature`, `build`, `status`, `started_at`, `finished_at`,
    `validation_level`, `evidence`, and `errors`.
  - Validation: `L0 Static`.
- [ ] `P0` Add docs landing page.
  - Explain what BMF is, what it is not, server-side-only scope, UE4SS
    dependency, Windows-only first target, and current compatibility.
  - Validation: docs link checker or static markdown check.

## Phase 1: Core Runtime and Plugin Model

Goal: give Lua mod authors a stable BMF runtime before exposing dangerous game
state mutation.

- [ ] `P0` Create `Mods/BMF/Scripts/main.lua` bootstrap.
  - Load core modules, set global `BMF`, write status, and fail loudly when the
    runtime is incompatible.
  - Validation: `L1 Boot`.
- [ ] `P0` Implement BMF plugin loader.
  - Load plugins from `Mods/BMF/plugins/<PluginName>/main.lua`.
  - Each plugin has `bmf.json` with name, version, author, description, and
    requested capabilities.
  - Progress: loader reads simple `bmf.json` metadata and exposes loaded plugin
    records through `BMF.plugins.list()` and `bmf.plugins`.
  - Validation: `L1 Boot`, `L2 Headless`.
- [ ] `P0` Add plugin lifecycle hooks.
  - `onLoad`, `onUnload`, `onServerReady`, `onTick`, `onError`.
  - Progress: `onLoad` and `onUnload(BMF, reason)` are implemented; reload calls
    `onUnload` before loading plugins again.
  - Progress: `onServerReady(BMF, data)`, `onTick(BMF, data)`, and
    `onError(BMF, context)` are implemented. `onTick` uses a lazy recurring
    timer while at least one loaded plugin defines it.
  - Progress: commands registered through a plugin facade are removed when the
    plugin unloads or disappears before reload.
  - Validation: `L2 Headless` via `scripts/validate-bmf-plugin-lifecycle-storage.ps1`
    and `scripts/validate-bmf-plugin-lifecycle-hooks.ps1`.
- [ ] `P0` Add config and data storage.
  - Per-plugin `config.json` and `data/` directory.
  - Safe JSON read/write helpers.
  - Progress: `BMF.storage.readConfigText`, `writeConfigText`, `readText`,
    `writeText`, and `appendText` provide path-safe per-plugin text storage.
  - Progress: `BMF.storage.readConfig`, `writeConfig`, `readJson`, and
    `writeJson` provide path-safe per-plugin JSON config/data helpers.
    Malformed JSON returns `JSON_PARSE_FAILED` instead of throwing.
  - Progress: `scripts/validate-bmf-plugin-lifecycle-storage.ps1` now proves
    JSON config/data round-trip, malformed JSON failure behavior, traversal
    denial, and persistence across `bmf.reload`.
  - Validation: `L0 Static`, `L2 Headless`.
- [ ] `P1` Add timer helpers.
  - `BMF.timers.after(ms, fn)`, `BMF.timers.every(ms, fn)`, cancellation.
  - Progress: `BMF.timers.after`, `BMF.timers.every`,
    `BMF.timers.cancel`, and `BMF.timers.activeCount` exist.
  - Validation: `L2 Headless` via `scripts/validate-bmf-timers.ps1`.
- [ ] `P1` Add command registration.
  - Server console commands first: `bmf.plugins`, `bmf.load`, `bmf.reload`,
    `bmf.unload`, `bmf.health`.
  - Progress: `BMF.commands.register`, `BMF.commands.dispatch`, and built-in
    console commands `bmf.status`, `bmf.health`, `bmf.version`, `bmf.plugins`,
    `bmf.commands`, `bmf.load`, `bmf.unload`, `bmf.reload`,
    `bmf.chat.broadcast`, `bmf.players.list`,
    `bmf.minigames.list`, `bmf.world.saveas`, and
    `bmf.vehicles.spawnset`, and `bmf.vehicles.snapshot` now exist. Plugin
    commands can register under the `bmf.*` namespace.
  - Progress: `bmf.unload` unloads currently loaded plugins and removes
    plugin-owned commands/events; `bmf.load` loads plugin directories from disk
    again without restarting the dedicated server.
  - Progress: `scripts/validate-bmf-console-commands.ps1` starts a disposable
    bridge server and invokes built-in plus plugin commands through
    `Omegga.Bridge.BMF`.
  - Progress: the console-command canary now proves a temporary plugin command
    works before unload, `bmf.unload` reports `plugins_unloaded=1`,
    `bmf.load` reports `plugins_loaded=1`, and the temporary command works
    again after load.
  - Progress: `scripts/validate-bmf-admin-commands.ps1` proves headless command
    acceptance for broadcast, empty player list safety, and minigame-list
    transport through the same BMF command worker.
  - Chat-command support later, after player chat interception is proven.
  - Validation: console commands are `L2 Headless`; chat commands are
    `L3 Live Player`.
- [ ] `P1` Add logging.
  - Per-plugin logs plus framework log.
  - Include JSONL option for canaries and automation.
  - Progress: `BMF.log`, `BMF.logInfo`, `BMF.logWarn`,
    `BMF.logError`, and plugin-scoped `BMF.logger.*` helpers now write
    `runtime/bmf.log`, `runtime/logs/plugins/<PluginName>.log`, and
    `runtime/events.jsonl`.
  - Progress: `Mods/BMF/config.json` `jsonlLogs` controls JSONL emission and
    defaults to enabled for canaries.
  - Validation: `L2 Headless` via `scripts/validate-bmf-logging.ps1`.
- [ ] `P1` Add capability gates.
  - Plugins must declare dangerous features such as console execution, world
    loading, permissions mutation, player mutation, and file write access.
  - Progress: plugin-scoped BMF facades now gate `BMF.server.exec`,
    `BMF.chat.broadcast`, world load/save, prefab load, vehicle spawn sets,
    and plugin storage. Missing declarations return `CAPABILITY_REQUIRED`.
  - Progress: `server.exec.restricted` is accepted as a restricted alias for
    `server.exec`, matching the package manifest naming.
  - Progress: plugin environments shadow `_G` with the scoped plugin
    environment so `_G.BMF` cannot bypass the facade in normal plugin code.
  - Validation: `L2 Headless + L5 Negative` via
    `scripts/validate-bmf-capability-gates.ps1`.

## Phase 2: Chat, Messaging, and Player Read APIs

Goal: expose the first useful server-side APIs on top of known or partially
known bridge routes.

### Chat

- [ ] `P0` Expose `BMF.chat.broadcast(message)`.
  - Status: `Proven` at the bridge/demo level.
  - Should use the safest proven typed/native route when available, then fall
    back to the known console command route only when configured.
  - Progress: `BMF.chat.broadcast(message)` exists, the `HelloBroadcast` and
    `TimedBroadcast` examples call it, and the `bmf.chat.broadcast` command is
    L2-proven for headless command acceptance.
  - Validation: `L2 Headless` for accepted command, `L3 Live Player` for
    visible delivery.
- [ ] `P1` Expose `BMF.chat.whisper(player, message)`.
  - Status: `Live tested, experimental`.
  - Progress: `BMF.chat.whisper(player, message)` resolves live controllers and
    sends `ClientPushChatMessage` to the matched controller. With exactly one
    live controller, any non-empty target string routes to that controller and
    returns `delivered=true`.
  - Progress: direct/synthetic player records and current-list queries still
    return safe structured errors when no live delivery target is available.
    Empty-server command route returns `PLAYER_NOT_FOUND` safely.
  - Gap: exact UUID/name targeting needs safe identity records from Omegga
    player sync and/or Brickadia saved/log adapters before `L4 Multiplayer`.
  - Validation: `L3 Live Player`, ideally `L4 Multiplayer` with sender and
    receiver separation.
- [ ] `P1` Expose `BMF.chat.statusMessage(player, message)`.
  - Status: `Partial`.
  - Useful for private UI/status feedback without public chat noise.
  - Progress: `BMF.chat.statusMessage(player, message)` mirrors whisper target
    resolution and headless-safe failure behavior.
  - Validation: `L3 Live Player`.
- [ ] `P2` Add chat command interception.
  - `BMF.chat.onCommand("/foo", fn)`.
  - Requires reliable player-chat stimulus and sender identity.
  - Validation: `L3 Live Player`, `L5 Negative` for blocked/unknown commands.
- [ ] `P2` Add chat filters.
  - Allow plugins to inspect, rewrite, or block player chat.
  - Requires a safe pre-send or process-chat hook.
  - Validation: `L3 Live Player`, `L5 Negative`.

### Player Read APIs

- [ ] `P1` Expose `BMF.players.list()`.
  - Status: `Partial`.
  - Omegga player sync and Brickadia saved/log parsing are the supported safe
    identity paths. Direct GameState/PlayerArray or PlayerState reflection stays
    avoided because CL13530 notes identify crash-prone object access paths.
  - Progress: `BMF.players.list()` safely reports known identity records when
    cache/log adapters provide them, reports live controller count, and is
    L2-proven to return `players_count=0` without a player controller.
  - Progress: Omegga player sync now has a Windows log-fallback path that
    populated `runtime/players.json` with a live player after restart.
  - Validation: `L2 Headless` returns an empty list safely; `L3 Live Player`
    returns at least one player.
- [ ] `P1` Expose `BMF.players.find(query)`.
  - Query by UUID, player ID, username, display name, exact name, partial name,
    or player state object path.
  - Progress: `BMF.players.find(records, query)` supports exact UUID/name/path
    matching and partial name matching against provided records.
    `BMF.players.find(query)` searches the current player list and returns
    `PLAYER_NOT_FOUND` safely on empty headless servers.
  - Validation: `L3 Live Player`.
- [ ] `P1` Normalize player identity fields.
  - Fields: `id`, `uuid`, `username`, `displayName`, `playerName`,
    `originalName`, `roles`, `ping`, `onlineTime`, `address`,
    `playerStatePath`, `controllerPath`.
  - Validation: `L3 Live Player`; no field should crash if unavailable.
- [ ] `P1` Expose `BMF.players.getName(player)`.
  - Return both stable/original account name and mutable display name when
    discoverable.
  - Progress: `BMF.players.getName(player)` returns normalized `username`,
    `playerName`, `displayName`, and `originalName` for direct/synthetic records
    and current-list lookups.
  - Validation: `L3 Live Player`.
- [ ] `P2` Expose `BMF.players.getHealth(player)`.
  - Status: `Research`.
  - Need to discover health component/property source and whether it lives on
    pawn, character, controller, or player state.
  - Validation: `L3 Live Player`; include damage/heal stimulus later.
- [ ] `P2` Expose `BMF.players.getPosition(player)`.
  - Status: `Research`.
  - Need safe pawn/root-component location reads.
  - Validation: `L3 Live Player`.
- [ ] `P2` Expose player connection events.
  - `onPlayerJoin`, `onPlayerLeave`, `onPlayerReady`.
  - Validation: `L3 Live Player`.
- [ ] `P3` Expose player death/spawn events.
  - Validation: `L3 Live Player`.

## Phase 3: Server Settings and Admin APIs

Goal: provide safer Lua wrappers for server administration operations that are
already console-backed or file-backed.

- [ ] `P1` Expose `BMF.server.status()`.
  - Status: `Partial`.
  - Should return structured server status, not console text.
  - Fields: server name, description, uptime, map/world, player count,
    brick count, component count, build ID, BMF status.
  - Progress: `BMF.server.status()` and `bmf.server.status` return structured
    BMF/runtime status, plugin count, command count, timer count, build target,
    empty player adapter status, and explicit `unknown` markers for live
    server/world fields not yet safely discovered.
  - Still needed: safe live-object adapters for server browser name,
    description, current world/map, brick count, and component count.
  - Validation: `L2 Headless` via `scripts/validate-bmf-server-status.ps1`.
- [ ] `P1` Expose `BMF.server.exec(command)` as restricted internal API.
  - Must require explicit capability and config opt-in.
  - Progress: plugin calls now require `server.exec` or
    `server.exec.restricted`; denied calls return `CAPABILITY_REQUIRED`.
  - Progress: direct plugin calls now also require
    `Mods/BMF/config.json` `allowPluginServerExec: true`; denied calls return
    `CONFIG_OPT_IN_REQUIRED`.
  - Validation: capability denial and config opt-in are
    `L2 Headless + L5 Negative`.
- [ ] `P2` Expose `BMF.server.setName(name)`.
  - Status: `File-backed partial`.
  - Determine whether runtime console command, GameSession property, or config
    file update is authoritative.
  - Progress: `BMF.server.planSettingsPatch()` and
    `scripts/patch-server-settings.ps1` can patch copied
    `GameUserSettings.ini` values without touching live config.
  - Validation: `L2 Headless` if log/config observable; `L3 Live Player` if
    server browser/client-visible verification is needed.
- [ ] `P2` Expose `BMF.server.setDescription(description)`.
  - Validation: same as server name.
- [ ] `P2` Expose `BMF.server.setPassword(password)`.
  - Must include redacted logging.
  - Partial: file-backed patching can set `ServerPassword`, but secret redaction
    and live effect are not proven.
  - Validation: `L5 Negative` for secret leakage in logs.
- [ ] `P2` Expose `BMF.server.setWelcomeMessage(message)`.
  - Status: `File-backed partial`.
  - Determine source of the built-in welcome message and whether hot reload is
    possible.
  - Progress: `WelcomeMessage` example plans the setting and
    `scripts/validate-server-settings.ps1` patches copied fixture/live config.
  - Validation: `L3 Live Player`.
- [ ] `P2` Expose `BMF.server.save()`.
  - Wrap known world save commands such as `BR.World.SaveAs` where appropriate.
  - Progress: `BMF.server.save(options)` delegates to `BMF.world.saveAs`,
    generates a BMF-owned name when none is provided, and is exposed as
    `bmf.server.save name=<world>`.
  - Progress: plugin calls require the `server.save` capability.
  - Validation: `L2 Headless` via `scripts/validate-bmf-server-save.ps1`,
    observing the saved `.brdb` file and parsing it with
    `describe-world-archive.ps1`.
- [ ] `P2` Expose graceful shutdown/restart helpers.
  - Must protect against accidental remote shutdown by requiring capability.
  - Progress: `BMF.server.shutdown(options)` attempts `exit` only after
    `confirm="BMF_SHUTDOWN"`, writes `server.shutdown` and
    `server.shutdown.executed` audit records, and is exposed as
    `bmf.server.shutdown confirm=BMF_SHUTDOWN`.
  - Progress: CL13530 currently returns `SHUTDOWN_UNAVAILABLE` with
    `executor_code=CONSOLE_EXEC_FAILED`; the validator force-stops its
    disposable server after proving the safe failure.
  - Progress: plugin calls require `server.shutdown` plus framework config
    `allowPluginServerShutdown: true`; missing opt-in returns
    `CONFIG_OPT_IN_REQUIRED`.
  - Actual stop/restart remains external-supervisor work; BMF does not claim a
    working restart API.
  - Validation: `L2 Headless + L5 Negative` via
    `scripts/validate-bmf-server-shutdown.ps1`.
- [ ] `P3` Expose server ban/kick/mute helpers.
  - Validation: `L3 Live Player`, `L5 Negative`.
- [ ] `P3` Expose server browser/session visibility settings.
  - Validation: research-dependent.

## Phase 4: World, BRDB, BRZ, and Prefab APIs

Goal: support world loading and prefab workflows without making plugin authors
deal with raw console commands, archive details, or unsafe native calls.

- [ ] `P1` Expose `BMF.world.load(name)`.
  - Full world load/replacement. Confirm exact command and side effects.
  - Validation: `L2 Headless`, with disposable test world.
- [ ] `P1` Expose `BMF.world.loadAdditive(options)`.
  - Status: `Proven` for command transport with `BR.World.LoadAdditive`.
  - Progress: BMF Lua wrapper, docs, and `LoadThreeCars` example exist.
    Headless command proof passed in
    `artifacts/validation/20260603-215931/threecars-additive-canary.json`.
    BMF runtime boot validation is still pending.
  - Options: bundle name, position, orientation, verification timeout.
  - Validation: `L2 Headless`; verify success log.
- [ ] `P1` Expose `BMF.world.saveAs(name)`.
  - Status: `Headless-proven`.
  - Progress: BMF Lua wrapper, docs, and `LoadThreeCars` example exist.
    SaveAs proof passed in
    `artifacts/validation/20260603-215931/threecars-additive-canary.json`.
    BMF runtime world-wrapper validation passed in
    `artifacts/validation/20260603-215931/bmf-world-runtime-timerhop-canary.json`.
  - Wrap `BR.World.SaveAs`.
  - Validation: `L2 Headless`; verify output `.brdb`.
- [ ] `P1` Expose `BMF.archives.describe(path)`.
  - Status: `Offline tooling partial`.
  - Progress: `scripts/describe-world-archive.ps1` and
    `scripts/validate-archive-fixtures.ps1` wrap the BRDB parser and summarize
    entity/dynamic-actor evidence for `.brdb` files.
  - Progress: `scripts/summarize-vehicle-graphs.ps1` produces a vehicle-like
    dynamic actor snapshot with centers, related entity/grid ids, counts, and
    likely body grids. `scripts/validate-vehicle-snapshot.ps1` proves the known
    three-car fixtures each expose three 1,528-brick vehicle-like groups.
  - Progress: `scripts/export-vehicle-inventory.ps1` formats those snapshots or
    saved BRDBs into JSON, Markdown, CSV, and console-style lines so unattended
    runs can report "what cars are on the map" without reading raw parser dumps.
  - Progress: `scripts/snapshot-server-vehicles.ps1` can issue `BR.World.SaveAs`
    against a bridge-connected server and summarize vehicle-like groups from the
    saved map. `scripts/validate-server-vehicle-snapshot.ps1` proves this against
    a staged `Car.brz` load on a disposable headless server.
  - Progress: `scripts/snapshot-server-vehicles.ps1 -ExportInventory` now emits
    the readable vehicle inventory in the same running-server SaveAs pass. The
    spawn-set L2 canary asserts the inventory count and preserves the Markdown,
    CSV, and JSON evidence beside the raw snapshot.
  - Progress: inventory export can now take `-SpawnManifestJson` and match each
    staged world name back to an observed vehicle label with planned coordinates,
    deltas, and match distance. The spawn-set L2 canary asserts all three staged
    copies are matched.
  - Progress: `scripts/snapshot-bmf-server-vehicles.ps1` invokes
    `bmf.vehicles.snapshot` through the BMF command worker, then parses the saved
    BRDB and exports the readable vehicle inventory. This is the BMF-native
    command path for unattended "what cars are on the map" evidence.
  - Progress: `scripts/export-vehicle-inventory.ps1` now writes a standalone
    `vehicle-inventory.txt` console-style report alongside JSON, Markdown, and
    CSV so unattended runs have a compact text artifact for map car evidence.
  - Progress: BMF command-driven vehicle save-and-parse canaries now wait for a
    non-empty stable saved `.brdb` before stopping the server. This prevents the
    observed race where `SaveAs` created a zero-byte archive before the parser
    ran.
  - Progress: `scripts/validate-server-multi-vehicle-snapshot.ps1` proves the
    same running-server snapshot path can identify three vehicle-like groups
    after loading the known `threecars.brdb` fixture.
  - Progress: `scripts/remap-staged-vehicle-brdb.js` can rewrite a staged
    single-car dynamic-actor slice by offsetting persistent entity ids, brick
    grid folder ids, component joint refs, microchip grid refs, and remote wire
    grid refs while leaving owner-array indices untouched.
  - Progress:
    `scripts/validate-server-remapped-duplicate-vehicle-snapshot.ps1` proves an
    original single-car dynamic-actor slice plus a remapped copy load into a
    disposable server as two isolated vehicle-like groups: 40 entities, 33 brick
    grids, 3,056 bricks, 246 components, and 206 wires.
  - Progress: `scripts/validate-server-vehicle-spawn-set.ps1` generalizes the
    remapped-slice path into a small spawn-set canary. With `VehicleCount=3`, it
    loads three staged car copies at separate coordinates and saves three
    isolated vehicle-like groups: 60 entities, 49 brick grids, 4,584 bricks, 369
    components, and 309 wires.
  - Progress: `scripts/stage-vehicle-spawn-set.ps1` splits the staging/remap
    step into reusable tooling that writes a manifest of staged world names,
    positions, remap reports, and per-copy static vehicle snapshots.
  - Progress: `BMF.vehicles.planSpawnSet()` and `BMF.vehicles.spawnSet()` now
    consume those staged world names from Lua. The runtime canary
    `scripts/validate-bmf-vehicle-spawn-set-runtime.ps1` loads three staged
    copies through BMF, saves the map, and parses the same 60-entity,
    4,584-brick, 3-vehicle result.
  - Current caveat: loading the exact same staged single-car BRDB twice still
    coalesces into one combined dynamic actor graph. A raw `Car.brz`-derived
    single-car BRDB also lacks the body-grid companion entity needed for safe
    duplicate remapping; use the graph-closure dynamic-actor slice source for
    duplicate spawned-car tests.
  - Support `.brz` and `.brdb` metadata: files, folders, hashes, brick count,
    component count, entity summary.
  - Validation: `L0 Static`.
- [ ] `P2` Expose `BMF.archives.brzToBrdb(source, target, options)`.
  - Convert `.brz` prefab archive to server-loadable `.brdb` bundle.
  - Progress: `scripts/stage-brz-prefab.ps1` wraps the current
    reverse-engineering helpers for prefab diagnosis, hash reporting,
    BRZ-to-BRDB world staging, optional Saved/Worlds copy, and static archive
    parsing.
  - Current caveat: forced physics metadata patching is diagnostic-only; local
    L2 probes can crash the server at `TVariant.h:148` when loading dynamic
    prefab metadata. The default safe path keeps `bIsPhysicsGrid=false`.
  - Validation: `L0 Static` conversion plus `L2 Headless` additive load.
- [ ] `P2` Expose `BMF.prefabs.loadBrz(options)`.
  - Build/stage BRDB from BRZ, then load additively.
  - Progress: `scripts/validate-brz-prefab-staging.ps1` stages `Car.brz`,
    loads it additively through a bridge-enabled dedicated server, saves the
    result, and parses the saved BRDB. The current L2 target is 19 entities,
    one resolved dynamic actor group, 16 related grids, 1,528 bricks, 123
    components, 103 wires, and body grid 1 retaining 1,254 bricks.
  - Progress: `BMF.prefabs.loadBrz(options)` now exists as a Lua facade. It
    returns `PREFAB_STAGING_REQUIRED` when only a `.brz` source is supplied and
    delegates to `BMF.world.loadAdditive()` when a staged world name is present.
    `scripts/validate-bmf-prefab-runtime.ps1` is the L2 runtime canary for this
    path.
  - Progress: `bmf.prefabs.loadbrz source=<file.brz> name=<staged-world>` now
    exposes the same staged-load path through the BMF command worker.
    `scripts/validate-bmf-prefab-command.ps1` stages `Car.brz`, invokes the
    command, saves the map, parses the saved BRDB, and exports a one-car
    `vehicle-inventory.txt` report.
  - Validation: `L2 Headless` for archive/load/save survival; mark drivable
    vehicle behavior unproven until a live player can enter and operate it.
- [ ] `P2` Expose `BMF.prefabs.loadBrdb(options)`.
  - Copy/stage existing BRDB, then load additively.
  - Progress: `BMF.prefabs.loadBrdb(options)` delegates staged BRDB world loads
    to `BMF.world.loadAdditive()`.
  - Progress: `bmf.prefabs.loadbrdb name=<staged-world>` exposes the same
    staged-load path through the BMF command worker.
    `scripts/validate-bmf-prefab-brdb-command.ps1` stages the known
    `threecars.brdb` fixture, invokes the command, saves the map, parses the
    saved BRDB, and exports a three-car `vehicle-inventory.txt` report.
  - Validation: `L2 Headless`.
- [ ] `P2` Expose `BMF.prefabs.saveRegion(options)`.
  - Save bounded brick region to reusable archive.
  - Status: `Research`.
  - Validation: `L2 Headless` for brick-only region if no player context is
    needed; `L3 Live Player` if a selection/controller is required.
- [ ] `P3` Expose `BMF.prefabs.saveEntityGraph(options)`.
  - Vehicle-capable save path must preserve entity graph, components, wires,
    grid references, and metadata.
  - Progress: `scripts/capture-dynamic-actor-graph.ps1` can select a saved
    dynamic actor group by group id or actor entity id and record the related
    entity/grid/chunk closure. `scripts/validate-dynamic-actor-graphs.ps1`
    proves the current vehicle fixtures each expose one-car graph captures
    with 20 related entities and 16 related grids. The 20th entity is the
    saved entity whose persistent id matches the selected body grid id; pruning
    it causes Brickadia to drop the large body grid during additive load.
  - Current slicer finding: the three-car fixtures keep all entities in one
    `World/0/Entities/Chunks/0_0_0.mps` structure-of-arrays chunk, so a real
    single-car BRDB/BRZ slice requires row-level entity chunk rewriting.
  - Progress: `scripts/slice-dynamic-actor-brdb.js` performs an experimental
    static BRDB slice for a selected dynamic actor graph by rewriting entity
    chunk rows, preserving the dynamic-property tail, and pruning unrelated
    grid files. It is parse-validated.
  - Progress: `scripts/validate-dynamic-actor-slice-additive.ps1` runs the
    slice through a bridge-enabled dedicated server, `BR.World.LoadAdditive`,
    `BR.World.SaveAs`, and saved-world parsing. The current L2 canary passes
    with 20 entities, one resolved dynamic actor group, 16 related grids,
    1,528 bricks, 123 components, 103 wires, and the 1,254-brick body grid
    retained.
  - Progress: the sliced single-car bundle can now be duplicated by first
    running `scripts/remap-staged-vehicle-brdb.js` on one copy. The duplicate
    L2 canary proves Brickadia saves the result as two isolated dynamic actor
    vehicle graphs instead of one coalesced graph.
  - Progress: `scripts/validate-server-vehicle-spawn-set.ps1` extends the same
    id-remap approach to three staged copies and proves the saved map retains
    three isolated vehicle-like groups.
  - Progress: `scripts/stage-vehicle-spawn-set.ps1` now provides the reusable
    stage manifest for this path, and `BMF.vehicles.spawnSet()` provides the Lua
    load facade over the staged copies.
  - Progress: the server spawn-set canary now correlates the stage manifest to
    the saved-world vehicle inventory, so unattended output can say which staged
    world became `car-001`, `car-002`, and `car-003`.
  - Current caveat: vehicle correctness and drivable behavior remain unproven
    until a player/controller validation can enter and operate the saved car.
  - Validation: `L2 Headless` if world snapshot parsing is enough; dynamic
    vehicle correctness requires `L3 Live Player`.
- [ ] `P3` Expose native paste/replay only behind experimental namespace.
  - `BMF.experimental.prefabs.replayLastCapture(...)`.
  - Must stay clearly separate from stable public APIs.
  - Validation: `L3 Live Player`, `L5 Negative` for stale capture/context.
- [ ] `P3` Resolve dynamic vehicle additive-load gate.
  - Prove whether Brickadia's own additive world loader can preserve drivable
    dynamic vehicles from a saved world bundle.
  - Validation: `L3 Live Player`.

## Phase 5: Roles, Permissions, and Tool Policy

Goal: provide the higher-value moderation and server-design controls that the
base game currently does not expose at the desired granularity.

This is a high-impact area, but it is research-heavy. Most items require
discovering Brickadia role/minigame/tool permission data structures and finding
safe mutation points.

### Roles and Permissions

- [x] `P1` Read role definitions.
  - Include default role, role names, inherited permissions, and tool
    permissions if discoverable.
  - Validation: `L2 Headless` if roles are config/file-backed; otherwise
    `L3 Live Player`.
  - Current evidence: `RoleSetup2.json` is file-backed and parsed by
    `scripts/validate-role-permissions.ps1`.
  - Progress: `BMF.permissions.describeRole()` normalizes RoleSetup2-style role
    permission entries, permission maps, invalid entries, and duplicate entries
    from Lua.
- [ ] `P1` Read player roles.
  - Tie roles to `BMF.players` identity records.
  - Validation: `L3 Live Player`.
  - Partial: `RoleAssignments.json` is file-backed and can be parsed/patched in
    copied outputs. Live `BMF.players.list()` role effect still requires a
    player.
  - Progress: `BMF.permissions.describeRoleAssignments()`,
    `BMF.permissions.getPlayerRoles()`, and
    `BMF.permissions.playerHasRole()` now read RoleAssignments-style data from
    Lua, detect duplicate/invalid role entries, reject invalid player UUIDs, and
    read back planned assignment patches.
  - Validation: `L2 Headless + L5 Negative` via
    `scripts/validate-bmf-role-assignments.ps1` for file-shaped data; live
    player role binding remains `L3 Live Player`.
- [ ] `P2` Modify default role.
  - Enable/disable base permissions for new players.
  - Validation: `L5 Negative` with a live player attempting an action.
  - Partial: `scripts/patch-role-permissions.ps1` can safely patch a copied
    `RoleSetup2.json` and set `BR.Permission.SpawnItems` to `Forbidden` while
    keeping applicator permissions allowed.
  - Progress: `BMF.permissions.evaluateNoSpawnItemApplicator()` proves whether
    a role expresses the intended no-spawn-item applicator policy after planning
    or patching.
- [ ] `P2` Create/update/delete roles.
  - Role name, display name, color, inheritance, permissions.
  - Validation: `L2 Headless` for persistence if config-backed; `L3 Live
    Player` for runtime effect.
- [ ] `P2` Assign/remove player role.
  - By UUID, username, display name, or player object.
  - Validation: `L3 Live Player`.
  - Partial: `BMF.permissions.planPlayerRoleAssignment()` and
    `scripts/patch-role-assignments.ps1` can plan and patch UUID-based
    assignments in copied `RoleAssignments.json` files.
- [ ] `P2` Hot-reload permissions without server restart.
  - Determine whether runtime mutation is possible or whether a reload command
    is required.
  - Validation: `L3 Live Player`, `L5 Negative`.
- [ ] `P3` Add temporary permissions.
  - Grant for duration, until death, until disconnect, or while in a zone.
  - Validation: `L3 Live Player`, `L5 Negative`.

### Fine-Grained Tool Policy

- [ ] `P1` Discover applicator permission surface.
  - Identify tool classes, component application methods, and permission checks.
  - Validation: discovery report with class/function/property names.
  - Progress: live ProcessEvent tracing identified
    `ABRTool_Applicator.ServerAddComponent` as the server RPC for adding
    components through the applicator. The RPC has two parameters: an 8-byte
    brick handle and an object pointer for component type.
- [x] `P1` Block applicator `SpawnItem` component.
  - Highest-value policy item after chat/player basics.
  - Desired behavior: players may use applicator for allowed components while
    `SpawnItem` is denied.
  - Validation: `L3 Live Player`, `L5 Negative`.
  - Baseline path: keep `BR.Permission.Building.Applicator*` allowed and set
    `BR.Permission.SpawnItems` to `Forbidden` for the default role.
  - Progress: the policy-shape canary
    `scripts/validate-bmf-permission-policy.ps1` proves an unsafe role is
    detected, the planned no-spawn-item patch evaluates as compliant, and
    duplicate permission entries fail the evaluator.
  - Progress: `BMF.permissions.evaluateApplicatorComponentAccess()` now denies
    `SpawnItem` and Brickadia's reflected `ItemSpawn` component names,
    including class-like suffixes such as `BRSpawnItemComponent`, while
    allowing other component names by default.
  - Progress: `BMF.permissions.enforceNoSpawnItemApplicator()` and
    `bmf.permissions.enforce-nospawnitem` now patch a `RoleSetup2.json` copy,
    keeping applicator permissions allowed while setting
    `BR.Permission.SpawnItems` to `Forbidden` on `defaultRole` and preventing
    named roles from explicitly allowing it. Missing `SpawnItems` on named roles
    is treated as inherited denial because Brickadia normalizes redundant
    forbids after restart. `framework/ue4ss/Mods/BMF/plugins/NoSpawnItemApplicator` calls this enforcer
    on load when `brickadiaSavedDir` is configured.
  - Progress: `BMF.tools.onApplicatorComponentApply()` can register
    `NoSpawnItemApplicator` policy handlers and cache reflected `ItemSpawn`
    component objects, but the direct UE4SS Lua `ServerAddComponent` hook is
    disabled by default. Live testing proved this hook crashes on
    `UE4SS.dll!RC::LuaType::push_structproperty` while marshaling a struct
    parameter before BMF's callback runs.
  - Progress: live validation proved the role-backed
    `BR.Permission.SpawnItems=Forbidden` path does not block Applicator
    `ItemSpawn` placement.
  - Progress: `native/applicator_blocker/applicator_func_blocker.cpp` blocks
    `ItemSpawn` by wrapping `ServerAddComponent` at `UFunction::Func`
    (`function + 0xD8`) and reading the component pointer from
    `FFrame.Locals + 8`. A connected-player negative test blocked `ItemSpawn`
    without crashing while allowing a non-denied component through.
  - Progress: the native blocker emits TSV block events and
    `NoSpawnItemApplicator` consumes them to send Omegga-backed feedback. Live
    status showed `feedback_delivered=2` and
    `feedback_last_delivery=whisper:<player uuid>`.
  - Progress: the native blocker now accepts hot-reloaded `allowed_context=0x...`
    lines in `applicator-func-blocker-control.txt`. `NoSpawnItemApplicator`
    reads `RoleAssignments.json` through
    `BMF.permissions.loadRoleAssignments()`, supports `allowedRoles`,
    `allowedPlayers`, and explicit `allowedContexts` in plugin config, and
    feeds allowed Applicator contexts back to the native hook. Default allowed
    role is `Admin`.
  - Remaining: package startup/auto-discovery for the native blocker instead of
    manual control-file injection, and map native Applicator context back to the
    exact player for multi-player allow decisions and whisper targeting. Current
    role/player context learning is conservative and exact for a one-live-player
    Omegga/BMF list.
- [x] `P1` Whitelist Interactable Print-to-Console prefixes.
  - Desired behavior: Owner/Admin roles may save any Interactable console tag,
    while everyone else may only save configured prefixes such as `buyweapon:`.
  - Validation: `L3 Live Player`, `L5 Negative`.
  - Progress: `BMF.permissions.evaluateInteractConsolePrefixAccess()` denies
    non-whitelisted prefixes such as `teleport:` for non-admin roles while
    allowing Owner/Admin bypass and whitelisted prefixes.
  - Progress: `framework/ue4ss/Mods/BMF/plugins/InteractConsolePrefixGuard` writes the native policy
    control file, reads Brickadia/Omegga role assignments, primes one-player
    Owner/Admin Applicator contexts, polls native TSV events, and sends
    Omegga-backed whisper feedback on denied attempts.
  - Progress: `native/interact_prefix_guard/interact_prefix_guard.cpp` wraps
    `ABRTool_Applicator.ServerModifyComponent` at `UFunction::Func`
    (`function + 0xD8`), reads `FFrame.Locals + 8` for the Interactable
    component pointer, scans component data for the console tag, blocks denied
    tags before save, and allows whitelisted prefixes or Owner/Admin contexts.
  - Progress: live validation on June 5, 2026 proved Owner allow with
    `teleport:context-allow-verify` (`reason=ContextAllowlisted`) and denied-role
    simulation with `teleport:deny-sim` (`reason=prefix-denied`). BMF status
    reported `native_blocked=2`, `feedback_delivered=2`, and
    `feedback_missed=0` for the denied simulation.
  - Progress: `scripts/sync-interact-prefix-guard-native-hook.ps1` refreshes
    the per-process `ServerModifyComponent` pointer, writes prefixes/allowed
    contexts to the control file, builds the native guard, and injects or
    verifies the hook after restart.
  - Remaining: validate with a real second non-admin player instead of the
    one-player Owner-denied simulation, and avoid relying on one-player context
    inference for exact multi-player allow decisions.
- [ ] `P2` Implement component-level allow/deny lists.
  - Example: allow lights, signs, interactors; deny spawn item, weapon spawns,
    vehicle spawns, or expensive components.
  - Validation: `L3 Live Player`, `L5 Negative`.
  - Partial: the framework has a headless policy evaluator with
    `deniedComponents` and `allowedComponents`, plus an experimental live hook
    path pending negative validation.
- [ ] `P2` Audit component attempts.
  - Log player, component type, brick/entity target, allowed/denied, reason.
  - Validation: `L3 Live Player`.
  - Partial: applicator hook attempts are recorded in
    `runtime/logs/applicator.jsonl` with component candidates, addresses, hook
    decision, and block mode.
  - Partial: the native `UFunction::Func` blocker writes denied `ItemSpawn`
    and allowed-context `ItemSpawn` events to
    `artifacts/local/applicator-func-blocker-events.tsv`; player identity is
    currently inferred by Omegga/BMF live player count or previously learned
    context ownership rather than exact native ownership.
- [ ] `P2` Add rollback for denied component changes.
  - If pre-hook prevention is impossible, detect and revert unauthorized
    component changes.
  - Validation: `L5 Negative`.
- [ ] `P2` Add manipulator tool policy.
  - Restrict move/delete/paint/resize by role, zone, minigame, owner, or brick
    tag.
  - Validation: `L3 Live Player`, `L5 Negative`.
- [ ] `P2` Add connector tool policy.
  - Restrict wires/connections by role, zone, owner, or component type.
  - Validation: `L3 Live Player`, `L5 Negative`.
- [ ] `P3` Add placement/build policy.
  - Control brick placement, deletion, paint, collision settings, component
    costs, and physics toggles.
  - Validation: `L3 Live Player`, `L5 Negative`.
  - Partial: `scripts/list-brick-assets.js` can inventory `.brdb`/`.brz`
    brick asset names and histograms. `BMF.permissions.evaluateBrickAssetAccess`
    and the deprecated `deprecated/plugins/BrickAssetPlacementGuard` provide role-aware allow/deny
    policy for names such as `B_Joint_Wheel_Micro`, `B_Seat`, and
    `B_1x1_Gate_WheelEngineSlim`.
  - Remaining: wire a cancellable placement/paste hook that resolves the
    incoming brick asset or uploaded prefab hash before Brickadia mutates the
    world.
- [ ] `P3` Add region/zone policy.
  - Protected spawn, arenas, plots, staff-only zones, temporary event zones.
  - Validation: `L3 Live Player`, `L5 Negative`.

## Phase 6: Minigame APIs

Goal: let Lua create and manage Brickadia minigames without manual setup.

- [ ] `P2` Discover minigame runtime classes and config storage.
  - Find minigame manager, minigame objects, teams, spawn points, rules, and
    persistence model.
  - Validation: discovery report.
- [ ] `P2` Expose `BMF.minigames.list()`.
  - Validation: `L2 Headless` if existing minigames can be read without
    players.
  - Progress: `BMF.minigames.list()` command wrapper and `ListMinigames`
    example exist; runtime plugin transport and the `bmf.minigames.list`
    command route are L2-proven on disposable headless servers.
- [ ] `P2` Expose `BMF.minigames.create(options)`.
  - Fields: name, type, persistent flag, included brick mode, owner, teams,
    rounds, spawn behavior.
  - Validation: `L2 Headless` for object/config creation; `L3 Live Player` for
    joining and playing.
- [ ] `P2` Expose minigame settings update.
  - Included bricks: owner-only, all bricks, selected bricks, zone.
  - Validation: `L3 Live Player` if runtime effect matters.
- [ ] `P2` Expose team creation/update.
  - Team name, color, max players, spawn points, score rules, inventory/loadout.
  - Validation: `L3 Live Player`, `L4 Multiplayer`.
- [ ] `P2` Expose minigame membership.
  - Add/remove player, assign team, switch team, spectator mode.
  - Validation: `L3 Live Player`, `L4 Multiplayer`.
- [ ] `P2` Expose minigame lifecycle.
  - Start, stop, reset, pause, next round, end round.
  - Validation: `L2 Headless + L5 Negative` for command-worker transport and
    argument validation; `L3 Live Player` for gameplay effects.
  - Partial: `BMF.minigames.loadPreset`, `savePreset`, `nextRound`, `reset`,
    and `delete` format the known Omegga/Brickadia console commands. Live
    gameplay effects are not proven.
  - Progress: `bmf.minigames.loadpreset`, `savepreset`, `nextround`, `reset`,
    and `delete` expose those wrappers through the BMF command worker.
    `scripts/validate-bmf-minigame-commands.ps1` invokes the lifecycle routes
    on a disposable headless server and also proves invalid preset-name and
    invalid-index rejection.
- [ ] `P3` Expose scoring/objectives.
  - Score events, scoreboard read/write, win conditions, timers.
  - Validation: `L4 Multiplayer`.
- [ ] `P3` Expose per-minigame permissions.
  - Temporarily allow tools inside a minigame while restricting them globally.
  - Validation: `L3 Live Player`, `L5 Negative`.

## Phase 7: Player Mutation and Gameplay Control

Goal: add controlled APIs for changing player state. These should land after
identity, permissions, and safety gates are in place.

- [ ] `P2` Expose `BMF.players.teleport(player, position)`.
  - Validation: `L3 Live Player`.
- [ ] `P2` Expose `BMF.players.heal(player, amount)` and
  `BMF.players.damage(player, amount)`.
  - Validation: `L3 Live Player`.
- [ ] `P2` Expose `BMF.players.kill(player)`.
  - Validation: `L3 Live Player`.
- [ ] `P3` Expose avatar read API.
  - Read current avatar/body colors/clothing/cosmetics if available.
  - Validation: `L3 Live Player`.
- [ ] `P3` Expose avatar mutation API.
  - Change look, outfit, colors, or forced appearance for events/minigames.
  - Validation: `L3 Live Player`.
- [ ] `P3` Expose inventory/tool APIs.
  - Give/remove tool, item, weapon, or loadout.
  - Validation: `L3 Live Player`, `L5 Negative`.
- [ ] `P3` Expose player input/tool mode events.
  - Useful for custom tools and minigames.
  - Validation: `L3 Live Player`.
- [ ] `P4` Expose camera/spectator helpers.
  - Validation: `L3 Live Player`.

## Phase 8: Event System

Goal: make BMF useful for mods without each plugin doing raw hooks.

- [ ] `P1` Add server lifecycle events.
  - `serverReady`, `worldLoaded`, `worldSaved`, `shutdownRequested`.
  - Progress: `BMF.events.on/off/emit/listenerCount` is implemented.
    `serverReady`, `worldLoaded`, and `worldSaved` are emitted by the
    framework; `shutdownRequested` is reserved for a future proven shutdown
    executor. `serverReady` and `worldSaved` are covered by the event canary.
    Plugin-owned event handlers are removed on plugin unload/reload.
  - Validation: `L2 Headless`.
- [ ] `P1` Add plugin lifecycle events.
  - Progress: `pluginLoaded` and `pluginUnloaded` are emitted by the framework;
    both are covered by the event canary, including reload cleanup.
  - Validation: `L2 Headless`.
- [ ] `P2` Add player events.
  - Join, leave, spawn, death, damage, team change, role change.
  - Validation: `L3 Live Player`.
- [ ] `P2` Add chat events.
  - Message received, command received, message blocked.
  - Validation: `L3 Live Player`.
- [ ] `P2` Add world/build events.
  - Brick placed, brick deleted, component added, component removed, wire
    connected, entity spawned.
  - Validation: `L3 Live Player`.
- [ ] `P3` Add minigame events.
  - Created, started, stopped, round started, score changed, player joined.
  - Validation: `L3 Live Player`, `L4 Multiplayer`.
- [ ] `P3` Add zone events.
  - Enter, leave, inside tick.
  - Validation: `L3 Live Player`.

## Phase 9: Security, Stability, and Abuse Prevention

Goal: BMF should make modded servers safer to run, not just easier to mutate.

- [ ] `P0` Version-gate Brickadia builds.
  - Refuse unsupported builds by default.
  - Progress: `BMF.compatibility.check()` and `bmf.compatibility` now report the
    declared target build `PC-Shipping-CL13530`, platform, executable, and
    `declared-target-only` build-detection mode.
  - Progress: unsupported-build handling is intentionally `report-only` until a
    reliable runtime Brickadia build source is proven.
  - Validation: `L0 Static`, `L1 Boot`.
- [ ] `P0` Version-gate UE4SS runtime.
  - Detect wrong/missing UE4SS files and report actionable error.
  - Progress: `BMF.compatibility.helpers()` reports required runtime helper
    groups for console execution and timers plus optional command-registration,
    game-thread, and object-lookup helpers.
  - Validation: `L2 Headless` via `scripts/validate-bmf-compatibility.ps1` for
    diagnostics; `L0 Static` and boot-time refusal remain pending for the final
    hard gate.
- [ ] `P1` Centralize unsafe native calls.
  - No plugin should call raw native helpers directly unless experimental mode
    is enabled.
  - Progress: plugin environments now deny known unsafe UE4SS/native globals by
    default, including raw Omegga console executors, UE4SS hooks, object lookup,
    and direct game-thread helpers.
  - Progress: `BMF.sandbox.policy`, `BMF.sandbox.denials`, and `bmf.sandbox`
    expose the active policy and denied lookups. Experimental access requires
    both framework `allowPluginUnsafeGlobals: true` and plugin capability
    `unsafe.globals`.
  - Validation: `L2 Headless + L5 Negative` via
    `scripts/validate-bmf-unsafe-globals.ps1`.
- [ ] `P1` Add crash-risk labels to APIs.
  - Stable, experimental, unsafe, deprecated.
  - Progress: `BMF.apis.list`, `BMF.apis.get`, `BMF.apis.summary`, and
    `bmf.apis` expose machine-readable stability, risk, validation,
    live-player requirement, and capability labels for the public Lua surface.
  - Progress: labels explicitly mark `BMF.server.exec` as `restricted` and
    `unsafe-native`, live-player surfaces as `live-player`, `BMF.chat.whisper`
    as `experimental`, file-backed settings/permission planners as
    `file-backed`, and world/prefab/vehicle mutation helpers as
    `experimental`.
  - Validation: `L2 Headless` via `scripts/validate-bmf-api-labels.ps1`.
- [ ] `P1` Add watchdog and last-error reporting.
  - If plugin crashes, isolate it and keep BMF alive where possible.
  - Progress: BMF tracks per-plugin error counts, last error hook/message,
    isolation state, and `plugin.isolated` audit records. Isolated plugins have
    future hooks skipped and plugin-owned commands blocked with
    `PLUGIN_ISOLATED`. `bmf.reload` resets watchdog state for fixed plugins.
  - Progress: `BMF.plugins.list()` includes watchdog fields and
    `bmf.plugins.watchdog` prints runtime watchdog status.
  - Validation: `L2 Headless + L5 Negative` via
    `scripts/validate-bmf-plugin-watchdog.ps1`.
- [ ] `P2` Add rate limiting.
  - Chat broadcast, whisper, console exec, world load, save, shutdown, player
    mutation.
  - Progress: `BMF.rateLimits.check`, `BMF.rateLimits.recent`, and
    `bmf.ratelimits` exist. Built-in limits cover `server.exec`, `server.save`,
    `server.shutdown`, `world.loadAdditive`, `world.saveAs`,
    `chat.broadcast`, `chat.whisper`, and `chat.statusMessage`. Plugin calls
    are counted under `plugin:<PluginName>` and denials are audited as
    `rate_limit.denied`.
  - Validation: `L2 Headless + L5 Negative` via
    `scripts/validate-bmf-rate-limits.ps1`.
- [ ] `P2` Add permission checks for BMF commands.
  - Staff-only commands should not be callable by normal players.
  - Validation: `L3 Live Player`, `L5 Negative`.
  - Progress: `BMF.permissions.evaluateCommandAccess()` evaluates a command
    policy table against direct actor roles or file-shaped
    `RoleAssignments.json` data, with explicit allow/deny rules, console
    policy, default deny, denied roles, and invalid command rejection.
  - Progress: `BMF.commands.dispatchWithAccess()` gives future
    player-authenticated command routes an opt-in enforcement wrapper that
    audits `command.access_granted` and `command.denied` records without
    changing the current server-console dispatcher.
  - Validation: `L2 Headless + L5 Negative` via
    `scripts/validate-bmf-command-access-policy.ps1` for the evaluator and
    `scripts/validate-bmf-command-dispatch-access.ps1` for the opt-in wrapper.
    Live player command routing remains blocked on authenticated player command
    identity.
- [ ] `P2` Add audit log.
  - Record admin actions, permission denials, world loads, role changes,
    minigame changes, and unsafe API calls.
  - Progress: `runtime/audit.jsonl`, `BMF.audit.record`,
    `BMF.audit.recent`, scoped plugin audit records, and `bmf.audit.tail`
    exist. Audit records cover framework/plugin lifecycle, command dispatch,
    unknown commands, command errors, plugin errors, capability/config denials,
    server exec, world load/save, server save, server shutdown, chat broadcast,
    and private messaging scaffold failures. Role/minigame mutation-specific
    audit coverage should be extended when those runtime effects are proven.
  - Validation: `L2 Headless` via `scripts/validate-bmf-audit-log.ps1`.
  - Validation: `L2 Headless`, `L3 Live Player`.
- [ ] `P3` Add plugin sandbox policy.
  - Restrict file access, dangerous APIs, and cross-plugin calls if feasible in
    UE4SS Lua.
  - Validation: `L5 Negative`.

## Phase 10: Developer Experience and Ecosystem

Goal: make BMF usable by other mod authors.

- [ ] `P0` Write install docs.
  - Windows dedicated server, UE4SS requirement, BMF package, verification.
  - Validation: docs review.
- [ ] `P0` Write first plugin tutorial.
  - `HelloBroadcast` or `TimedBroadcast`.
  - Validation: `L2 Headless`, `L3 Live Player` for visible chat.
- [ ] `P1` Write API reference pages.
  - Chat, commands, players, server, world, permissions, minigames, events.
  - Validation: docs review.
- [ ] `P1` Add examples.
  - `HelloBroadcast`, `TimedBroadcast`, `WelcomeMessage`,
    `PlayerListCommand`, `NoSpawnItemApplicator`, `SimpleArena`.
  - Validation: each example has a canary or manual test checklist.
- [ ] `P1` Add Lua type annotations.
  - EmmyLua or LuaLS annotations for `BMF`.
  - Validation: Lua language server check if available.
- [ ] `P1` Add package release script.
  - Build zip with manifest, hashes, changelog, docs link, compatibility
    matrix.
  - Progress: `scripts/build-release-package.ps1` builds `bmf-<version>.zip`
    from framework, installer, docs, examples, manifests, scripts, tests, and
    top-level docs while excluding generated `artifacts/`.
  - Progress: `scripts/validate-release-package.ps1` expands the zip and runs
    `scripts/validate-package.ps1` against the expanded package.
  - Validation: `L0 Static`.
- [ ] `P2` Add compatibility matrix.
  - Track Brickadia build, Steam build, UE4SS version, bundle status, canary
    status.
  - Validation: docs/generated artifact.
- [ ] `P2` Add GitHub issue templates.
  - Bug report, feature request, compatibility report, plugin API request.
  - Validation: static.
- [ ] `P3` Add BMF CLI helper.
  - Install, validate, package, send test command, tail logs, run canaries.
  - Validation: `L0 Static`, `L2 Headless`.
- [ ] `P4` Add docs site.
  - GitHub Pages or similar. Keep docs in repo first.
  - Validation: static site build.

## Phase 11: Future Plugin Ideas and Nice-to-Haves

These are not first-package requirements, but they are useful examples and
future issue candidates.

- [ ] `P4` Region claim/protection plugin.
  - Player plots, staff zones, build-deny zones, event arenas.
  - Depends on zone policy and build/tool events.
- [ ] `P4` Moderation helper plugin.
  - Mute, freeze, jail, kick, warn, audit history, staff notes.
  - Depends on player identity and permission checks.
- [ ] `P4` Scheduled announcements plugin.
  - Rotating chat messages, restart warnings, event reminders.
  - Depends on broadcast and timers.
- [ ] `P4` Welcome and onboarding plugin.
  - First-join message, rules prompt, starter role, starter location.
  - Depends on player join events and whisper/status messages.
- [ ] `P4` Simple economy/store plugin.
  - Currency balance, rewards, purchases, role-gated items.
  - Depends on persistence and player identity.
- [ ] `P4` Discord/webhook bridge.
  - Send server events to Discord or another webhook endpoint.
  - Depends on HTTP support or an external companion process.
- [ ] `P4` Metrics exporter.
  - Player count, uptime, chat volume, world loads, plugin errors.
  - Useful for dashboards and server health monitors.
- [ ] `P4` Automatic backup plugin.
  - Scheduled world saves, archive rotation, restore checklist.
  - Depends on world save APIs.
- [ ] `P4` Admin web panel.
  - Local-only first: health, loaded plugins, logs, players, roles, canaries.
  - Depends on CLI/helper and structured status APIs.

## Validation Without a Player Controller

Prefer headless validation when possible. It is faster, less brittle, and gives
goal-mode work a clear end condition.

Good candidates for `L2 Headless`:

- BMF package install and rollback.
- UE4SS/BMF boot.
- `bmf.version`, `bmf.health`, `bridge.ping`.
- Plugin load/reload/unload lifecycle.
- Config and data persistence.
- Timer execution.
- Server status that does not read unsafe PlayerState properties.
- World save/load/additive command transport.
- BRZ/BRDB parsing and conversion.
- Static archive hash validation.
- Empty `players.list` behavior.
- Error handling and capability-denial tests.

Requires live player/controller validation:

- Whisper visible delivery.
- Player identity fields beyond empty-list safety.
- Health, position, avatar, inventory, and tools.
- Role assignment effects.
- Welcome message visible delivery.
- Chat command interception and filtering.
- Applicator/manipulator/connector policy.
- Minigame membership, teams, scoring, and round flow.
- Dynamic vehicle placement or replay.

## Goal-Mode Work Template

Each future implementation goal should start by filling this out:

```text
Feature:
Priority:
Target validation level:
Requires live player: yes/no
Requires unsafe native call: yes/no
Public API:
Example plugin:
Canary command:
Expected artifact:
Docs page:
Rollback plan:
```

The goal can be marked complete only when:

- [ ] The API exists or the research report explains why it cannot exist yet.
- [ ] The canary passes at the selected validation level.
- [ ] The canary artifact is written.
- [ ] The docs and compatibility notes are updated.
- [ ] Unsafe behavior, missing player state, and unsupported build behavior are
  handled explicitly.

## Suggested First Goals

1. Package skeleton and runtime health canary.
   - Outcome: BMF can be installed, booted, and queried.
   - Validation: `L1 Boot`, `L2 Headless`.
2. Public `BMF.chat.broadcast`.
   - Outcome: first useful Lua API and `HelloBroadcast` example.
   - Validation: `L2 Headless`, then `L3 Live Player`.
3. Public `BMF.players.list`.
   - Outcome: stable player records without crashing on empty/no-player server.
   - Validation: `L2 Headless`, then `L3 Live Player`.
4. Public `BMF.chat.whisper`.
   - Outcome: private message API.
   - Status: single-player live delivery is proven; exact multi-player
     recipient isolation remains.
   - Validation: `L3 Live Player`, preferably `L4 Multiplayer`.
5. Permission discovery report for applicator component policy.
   - Outcome: identify where to block `SpawnItem` without disabling the whole
     applicator.
   - Validation: discovery artifact plus live negative test plan.
6. Experimental `NoSpawnItemApplicator` guard.
   - Outcome: the highest-value anti-abuse feature starts as an opt-in plugin.
   - Validation: `L3 Live Player`, `L5 Negative`.

## Open Research Questions

- Where is the authoritative player UUID stored, and how does it differ from
  mutable display name/player name fields?
- Where is current health stored: player state, pawn, character, component, or
  replicated attribute object?
- Can player state and controller references be read safely on CL13530 without
  hitting known object/property crash paths?
- What command or object owns live server name, description, password, and
  welcome message updates?
- Are role and permission definitions file-backed, object-backed, or both?
- Can role changes be applied live without a server restart or minigame reload?
- Where does the applicator validate component type permission?
- Can `SpawnItem` be blocked before mutation, or does BMF need to detect and
  roll back after the component is added?
- How are manipulator and connector permissions checked?
- What is the runtime model for minigame objects, teams, included bricks, and
  persistence?
- Can a headless save-region flow produce a complete `.brz` without player
  controller state?
- Can Brickadia's own additive loader preserve drivable dynamic vehicles from a
  saved world bundle?
- How much sandboxing is realistically possible inside UE4SS Lua?
