# Commands API

BMF has a small server-console command registry for headless administration.
Commands are registered through UE4SS `RegisterConsoleCommandGlobalHandler` when
that helper is available. The current headless bridge route is:

```text
Omegga.Bridge.BMF bmf.status
```

That route queues a request under `Mods/BMF/runtime/commands`. The BMF command
worker dispatches the command and writes a matching `.response.txt` file with
console-style output.

## Built-In Commands

- `bmf.status`: prints BMF health, version, loaded plugin count, and runtime
  artifact paths.
- `bmf.health`: alias of `bmf.status` for automation that expects an explicit
  health command.
- `bmf.version`: prints the BMF runtime version, target Brickadia build,
  Windows dedicated-server platform, server executable, compatibility status,
  and build-detection mode.
- `bmf.plugins`: lists loaded BMF plugins and plugin error count.
- `bmf.commands`: lists registered BMF console commands.
- `bmf.load`: loads BMF plugins from disk without restarting the server.
- `bmf.unload`: unloads currently loaded BMF plugins, removing plugin-owned
  commands and event handlers.
- `bmf.reload`: reloads BMF plugins from disk.
- `bmf.server.status`: prints structured BMF server/runtime status as
  key/value lines.
- `bmf.server.save name=<world>`: saves the current running world through
  `BMF.server.save`.
- `bmf.server.shutdown confirm=BMF_SHUTDOWN [delayms=<ms>] [reason=<text>]`:
  attempts a guarded graceful server exit. Without the exact confirmation token
  it returns `CONFIRMATION_REQUIRED`; on CL13530 the confirmed path currently
  returns `SHUTDOWN_UNAVAILABLE` with `executor_code=CONSOLE_EXEC_FAILED`.
- `bmf.chat.broadcast message=<text>`: broadcasts a server chat message through
  `BMF.chat.broadcast`. Live validation proves visible delivery through
  `ClientPushChatMessage`; headless validation proves command acceptance only.
- `bmf.chat.whisper target=<uuid-or-name> message=<text>`: sends a private
  message through `BMF.chat.whisper`. With one live controller this is
  live-confirmed; exact UUID/name targeting depends on safe identity records
  from Omegga player sync or Brickadia saved/log context.
- `bmf.players.list`: prints the current BMF player adapter count. On a
  no-player headless server this should safely report `players_count=0`.
- `bmf.players.sync players=<json>`: syncs safe external/Omegga player identity
  records into `runtime/players.json`.
- `bmf.interact.console message=<percent-encoded-tag> player=<uuid>
  name=<percent-encoded-name>`: forwards an Omegga Interactable
  Print-to-Console event into the BMF `interactConsole` event bus. This is the
  audit/feedback event path used by `examples/InteractConsolePrefixGuard`; the
  live save-time blocker is the experimental native `ServerModifyComponent`
  hook driven by that plugin's control file.
- `bmf.players.summary target=<uuid-or-name> [whisper=true]`: resolves one
  cached player, prints username/display/id plus known-player and live-controller
  counts, and optionally whispers that summary to the target.
- `bmf.permissions.enforce-nospawnitem [path=<RoleSetup2.json>]`: patches
  `RoleSetup2.json` so the applicator permissions stay allowed while
  `BR.Permission.SpawnItems` is forbidden on the default role and named roles
  cannot explicitly allow it. If `path` is omitted, BMF uses
  `brickadiaSavedDir` from config. Changed files require a server restart for
  reliable live enforcement.
- `bmf.tools.applicator.status [refresh=true]`: prints the applicator policy
  handler state, unsafe Lua hook opt-in state, registered handler count, recent
  event counters, denied component cache, trace path, and last error.
- `bmf.tools.applicator.refresh`: refreshes the denied applicator component
  type cache used by applicator policy experiments.
- `bmf.brickassetguard.status`: prints `BrickAssetPlacementGuard` policy
  status, including denied brick assets, bypass roles, and current enforcement
  level.
- `bmf.brickassetguard.check asset=<brick-asset> roles=<role>`: evaluates one
  brick asset against the configured placement policy. This is policy-only until
  a live placement/paste hook calls the evaluator before world mutation.
- `bmf.minigames.list`: reports `UNSAFE_MINIGAME_COMMAND_DISABLED` by default
  because Brickadia CL13530 can crash while formatting `Server.Minigames.List`.
- `bmf.minigames.loadpreset name=<preset> [owner=<name>]`: runs
  `BMF.minigames.loadPreset`.
- `bmf.minigames.savepreset index=<n> name=<preset>`: runs
  `BMF.minigames.savePreset`.
- `bmf.minigames.nextround index=<n>`: runs `BMF.minigames.nextRound`.
- `bmf.minigames.reset index=<n>`: runs `BMF.minigames.reset`.
- `bmf.minigames.delete index=<n>`: runs `BMF.minigames.delete`.
- `bmf.minigames.definitions.status`: prints BMF-owned desired-definition
  registry counts and persistence path.
- `bmf.minigames.definitions.set name=<name> [index=<n>] [teams=A,B]
  [persistent=true|false] [owneronly=true|false] [includedbrickmode=<mode>]`:
  upserts a BMF-owned desired minigame definition without mutating Brickadia.
- `bmf.minigames.definitions.list [name=<name>] [index=<n>]`: lists desired
  minigame definitions.
- `bmf.minigames.definitions.get key=<key>|name=<name> [index=<n>]`: returns
  one desired minigame definition.
- `bmf.minigames.definitions.delete key=<key>|name=<name> [index=<n>]
  confirm=DELETE_MINIGAME_DEFINITION`: deletes one desired definition.
- `bmf.minigames.definitions.reconcile [name=<name>] [index=<n>]`: compares
  desired definitions with the BMF-owned observed minigame data snapshot and
  reports `present`, `missing`, and team mismatch counts.
- `bmf.minigames.events.emit event=<name> ...`: emits one namespaced
  `minigames.<name>` event into the BMF event bus and event-fed data cache.
- `bmf.minigames.events.status`: prints event relay counters and last-event
  metadata.
- `bmf.minigames.events.recent [event=<name>] [player=<id-or-name>]
  [minigame=<name>] [limit=<n>]`: prints recent accepted minigame events.
- `bmf.minigames.events.canary [event=<name>]`: registers a temporary
  minigame event subscription, emits one event, verifies normalized metadata,
  and unsubscribes.
- `bmf.minigames.events.synthetic-flow`: emits a BMF-owned create, join, team,
  round, leaderboard, kill, leave, and delete flow, verifies reducer
  checkpoints, and restores the previous minigame data cache by default.
- `bmf.minigames.data.status`: prints compact BMF-owned minigame cache counts.
- `bmf.minigames.data.snapshot`: prints the full BMF-owned minigame cache as
  `snapshot_json=<json>`.
- `bmf.minigames.data.apply-snapshot payload=<json>|name=<name> [index=<n>]
  [teams=A,B]`: applies a BMF-owned observed minigame snapshot without emitting
  a framework event.
- `bmf.minigames.data.list [key=<key>|name=<name>] [index=<n>]`: lists
  BMF-owned event-fed minigame records.
- `bmf.minigames.data.get key=<key>|name=<name> [index=<n>]`: returns one
  minigame plus known members, teams, team memberships, leaderboard records, and
  round state.
- `bmf.minigames.data.players [player=<id-or-name>] [minigame=<name>]`:
  lists known minigame player contexts.
- `bmf.minigames.data.teams [team=<id-or-name>] [minigame=<name>]`: lists
  known minigame teams.
- `bmf.minigames.data.leaderboard [player=<id-or-name>] [minigame=<name>]`:
  lists known event-fed leaderboard rows with derived rank/score and raw
  leaderboard JSON values.
- `bmf.minigames.data.player player=<id-or-name>`: returns one player's known
  minigame membership, team, leaderboard, and minigame context.
- `bmf.minigames.data.playerstate player=<id-or-name>`: resolves whether one
  known player is currently in a minigame. `minigame_key` is current
  membership; `activity_minigame_key` can reflect historical leaderboard
  context after the player leaves.
- `bmf.minigames.data.membership player=<id-or-name>`: returns one player's
  current known minigame membership or `MINIGAME_MEMBERSHIP_NOT_FOUND`.
- `bmf.minigames.data.clear confirm=CLEAR_MINIGAME_DATA`: clears the in-memory
  minigame data cache for validation and troubleshooting.
- `bmf.minigames.objects.snapshot [limit=<n>] [includeProperties=true]`:
  fail-closed live `BP_Ruleset_C`/`BP_Team_C` object probe. It returns
  metadata/counts by default when the explicit unsafe object snapshot opt-in is
  enabled; direct Unreal property reads require `includeProperties=true`.
- `bmf.world.saveas name=<world>`: saves the current running world as a named
  `.brdb`.
- `bmf.prefabs.loadbrz source=<file.brz> name=<staged-world> x=<x> y=<y>
  z=<z> yaw=<yaw>`: loads a BRZ-derived world that has already been staged into
  Brickadia `Saved/Worlds` by `scripts/stage-brz-prefab.ps1`.
- `bmf.prefabs.loadbrdb name=<staged-world> x=<x> y=<y> z=<z> yaw=<yaw>`:
  loads an already staged `.brdb` world bundle through `BMF.prefabs.loadBrdb`.
- `bmf.vehicles.spawnset prefix=<world-prefix> count=<n> startX=<x> stepX=<x>
  y=<y> z=<z> yaw=<yaw>`: loads a pre-staged vehicle spawn set through
  `BMF.vehicles.spawnSet`.
- `bmf.vehicles.snapshot name=<world>`: saves the current running world through
  BMF so external tooling can parse and render vehicle inventory.

These commands are intended for server console or bridge `console.exec` use, not
player chat. Chat-command routing still requires player identity and chat
interception validation.

Role-based command access can be evaluated with
`BMF.permissions.evaluateCommandAccess(policy, actor, command)`. That helper is
documented in `docs/api/permissions.md` and is intentionally evaluator-only for
now; `BMF.commands.dispatch` does not enforce player permissions until a live
authenticated player command route is proven.

`BMF.commands.dispatchWithAccess(policy, actor, name, args, ar)` is the opt-in
wrapper for routes that do have actor identity. It evaluates policy first,
prints/audits `ACCESS_DENIED` when blocked, and delegates to
`BMF.commands.dispatch` only when allowed. Existing console dispatch behavior is
unchanged.

## `BMF.commands.register(name, description, handler)`

Plugins can register additional `bmf.*` console commands:

```lua
return {
  onLoad = function(BMF)
    BMF.commands.register("bmf.example", "Example command.", function(args)
      return BMF.result(true, "OK", "Example handled", {
        lines = {
          "args=" .. tostring(args or ""),
        },
      })
    end)
  end,
}
```

The handler receives the raw argument text when UE4SS provides it. Return the
standard BMF result shape and include optional `data.lines` for console output.
The BMF command worker writes those lines to the response file and to
`runtime/bmf.log`.

When writing request files directly from Windows PowerShell, use a no-BOM
encoding. Omegga's bridge and the bundled Omegga adapter already write no-BOM
request files.

Commands registered through a plugin's scoped `BMF` facade are owned by that
plugin and are automatically removed when the plugin unloads or reloads.

## `BMF.commands.dispatchWithAccess(policy, actor, name, args, ar)`

Dispatch a registered command only if the command access policy allows the
actor:

```lua
local handled = BMF.commands.dispatchWithAccess(
  policy,
  "11111111-1111-4111-8111-111111111111",
  "bmf.server.save",
  "name=NightlyBackup",
  ar
)
```

Denied commands are considered handled and produce console-style lines:

```text
BMF bmf.server.save ACCESS_DENIED role-missing
actor_source=player
actor_uuid=11111111-1111-4111-8111-111111111111
matched_roles=
```

The wrapper writes `command.access_granted` and `command.denied` audit records.
It is intended for future chat/staff command routing once an authenticated
player actor is available.

## Validation

- `L0 Static`: package validator checks command API markers and docs.
- `L2 Headless`: `scripts/validate-bmf-console-commands.ps1` starts a disposable
  bridge server and invokes `bmf.status`, `bmf.health`, `bmf.version`,
  `bmf.plugins`, `bmf.commands`, `bmf.canary`, `bmf.unload`, `bmf.load`, the
  reloaded `bmf.canary`, and `bmf.reload` through `Omegga.Bridge.BMF`, then
  verifies the BMF response files.
- `L2 Headless`: `scripts/validate-bmf-admin-commands.ps1` invokes
  `bmf.players.list`, `bmf.chat.broadcast`, and the fail-closed
  `bmf.minigames.list` command through the same command worker.
- `L2 Headless + L5 Negative`:
  `scripts/validate-bmf-minigame-commands.ps1` invokes minigame lifecycle
  command routes, proves they fail closed by default, proves BMF-owned
  desired-definition set/list/get/delete, and proves invalid preset/index
  rejection.
- `L2 Headless`: `scripts/validate-bmf-vehicle-spawn-set-command.ps1` stages
  vehicle worlds, invokes `bmf.vehicles.spawnset`, invokes `bmf.world.saveas`,
  then parses the saved world and exports a matched vehicle inventory.
- `L2 Headless`: `scripts/validate-bmf-vehicle-snapshot-command.ps1` stages and
  spawns vehicles, invokes `bmf.vehicles.snapshot`, then parses the saved world
  and exports the matched car inventory.
- `L2 Headless`: `scripts/validate-bmf-prefab-command.ps1` stages `Car.brz`,
  invokes `bmf.prefabs.loadbrz`, invokes `bmf.world.saveas`, then parses the
  saved world and exports a one-car inventory text report.
- `L2 Headless`: `scripts/validate-bmf-prefab-brdb-command.ps1` stages the
  known `threecars.brdb` fixture, invokes `bmf.prefabs.loadbrdb`, invokes
  `bmf.world.saveas`, then parses the saved world and exports a three-car
  inventory text report.
- `L2 Headless + L5 Negative`:
  `scripts/validate-bmf-server-shutdown.ps1` proves
  `bmf.server.shutdown` refuses to run without `confirm=BMF_SHUTDOWN`, then
  proves the confirmed CL13530 console-manager exit path fails safely with
  `SHUTDOWN_UNAVAILABLE` and an audit record.
- `L2 Headless`: `scripts/validate-bmf-plugin-command-cleanup.ps1` proves a
  plugin command works before reload and returns `UNKNOWN_COMMAND` after the
  plugin directory is removed and BMF reloads.
- `L2 Headless + L5 Negative`:
  `scripts/validate-bmf-command-access-policy.ps1` proves role/default/console
  command access decisions from file-shaped assignment data.
- `L2 Headless + L5 Negative`:
  `scripts/validate-bmf-command-dispatch-access.ps1` proves opt-in
  access-checked dispatch, denial output, console allow, invalid command
  rejection, and grant/deny audit records.
- `L3 Live Player`: required before mapping these commands into chat commands
  or player-authenticated staff commands.
