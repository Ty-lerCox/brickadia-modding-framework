# Commands API

BMF exposes a server-console command registry for headless administration,
canaries, and Omegga bridge calls. Commands are registered through UE4SS
`RegisterConsoleCommandGlobalHandler` when that helper is available.

For high-level command and socket flow, see
[Architecture Patterns](../architecture/architecture-patterns.md). For canary coverage,
see [API Validation Evidence](../validation/api-validation.md#commands).

**Labels:** `experimental`, `L2 Headless`, `L5 Negative`

## Who Should Read This?

Plugin authors should use this page when registering or calling BMF commands.
Omegga integrators should use it for bridge command routes. Server operators
should use it for admin and validation commands.

## When To Use

Use command routes for admin actions, validation, and external integrations that
need a console-shaped result. Use direct Lua APIs inside BMF plugins when the
caller is already in-process.

## Transport

The current bridge route is:

```text
Omegga.Bridge.BMF bmf.status
```

The file-backed worker queues requests under `Mods/BMF/runtime/commands`,
dispatches them in BMF, and writes matching `.response.txt` files.

Latency-sensitive Omegga plugins should prefer the socket bridge when available;
see the [Supported Runtime Matrix](../reference/supported-runtime.md) for the
transport contract. The command result shape is the same; socket responses
include `bmf_command_transport=socket`.

Current bounded worker defaults:

```text
BMF_COMMAND_WORKER_POLL_MS=250
BMF_COMMAND_WORKER_FALLBACK_POLL_MS=1000
BMF_COMMAND_WORKER_MAX_FILES_PER_POLL=1
BMF_COMMAND_WORKER_ASYNC=1
```

For high-frequency traffic, prefer the socket bridge or an event-fed cache over
repeated command-file requests.

## Examples

- [Plugin Command](../examples/plugin-command.md): complete Lua plugin
  that registers a server-console command.
- [RateLimitedCommand](../examples/rate-limited-command.md): command
  handler with `BMF.rateLimits.check`.

## Built-In Command Reference

| Area | Command | Purpose | More |
| --- | --- | --- | --- |
| Health | `bmf.status` | Prints health, version, loaded plugin count, and runtime paths. | [Health](health.md) |
| Health | `bmf.health` | Alias of `bmf.status` for automation. | [Health](health.md) |
| Health | `bmf.version` | Prints runtime version, target build, server executable, and compatibility status. | [Compatibility](compatibility.md) |
| Framework | `bmf.plugins` | Lists loaded plugins and plugin error count. | [Plugin Lifecycle](plugins/lifecycle.md) |
| Framework | `bmf.commands` | Lists registered BMF console commands. | This page |
| Socket | `bmf.socket.status` | Prints socket transport configuration, counters, native status, and last error. | [Omegga runtime](../architecture/omegga-supported-runtime.md) |
| Plugin lifecycle | `bmf.load` | Loads BMF plugins from disk without restarting the server. | [Plugin Lifecycle](plugins/lifecycle.md) |
| Plugin lifecycle | `bmf.unload` | Unloads plugins and removes plugin-owned commands and event handlers. | [Plugin Lifecycle](plugins/lifecycle.md) |
| Plugin lifecycle | `bmf.reload` | Reloads BMF plugins from disk. | [Plugin Lifecycle](plugins/lifecycle.md) |
| Server | `bmf.server.status` | Prints structured server/runtime status as key/value lines. | [Server](server.md) |
| Server | `bmf.server.save name=<world>` | Saves the running world through `BMF.server.save`. | [Server](server.md) |
| Server | `bmf.server.shutdown confirm=BMF_SHUTDOWN [delayms=<ms>] [reason=<text>]` | Attempts a guarded graceful server exit. | [Server](server.md) |
| Chat | `bmf.chat.broadcast message=<text>` | Broadcasts a server chat message. | [Chat](chat.md) |
| Chat | `bmf.chat.whisper target=<uuid-or-name> message=<text>` | Sends a private message to a resolved live target. | [Chat](chat.md) |
| Players | `bmf.players.list` | Prints the current BMF player adapter count. | [Player Identity Sources](players/identity-sources.md) |
| Players | `bmf.players.sync players=<json>` | Syncs safe external/Omegga player identity records. | [Player Identity Sources](players/identity-sources.md) |
| Players | `bmf.players.summary target=<uuid-or-name> [whisper=true]` | Resolves one cached player and optionally whispers a summary. | [Summaries And Messaging](players/summaries-and-messaging.md) |
| Interactable | `bmf.interact.console message=<tag> player=<uuid> name=<name>` | Forwards an Omegga Interactable Print-to-Console event into BMF. | [Interactable tags](permissions/interactable-tags.md) |
| Permissions | `bmf.permissions.enforce-nospawnitem [path=<RoleSetup2.json>]` | Patches role setup so `BR.Permission.SpawnItems` is forbidden. | [Role files](permissions/role-files.md) |
| Permissions | `bmf.tools.applicator.status [refresh=true]` | Prints Applicator hook/cache/policy state. | [Applicator policy](permissions/applicator-policy.md) |
| Permissions | `bmf.tools.applicator.refresh` | Refreshes denied Applicator component type cache. | [Applicator policy](permissions/applicator-policy.md) |
| Permissions | `bmf.brickassetguard.status` | Prints brick asset guard policy status. | [Brick assets](permissions/brick-assets.md) |
| Permissions | `bmf.brickassetguard.check asset=<asset> roles=<role>` | Evaluates one brick asset against configured policy. | [Brick assets](permissions/brick-assets.md) |
| Runtime bricks | `bmf.bricks.runtime.inspect ...` | Inspects one explicit live runtime brick id. | [Runtime Brick State](runtime-bricks.md) |
| Runtime bricks | `bmf.bricks.runtime.resolve ...` | Resolves a nearby live runtime brick id under explicit gates. | [Runtime Brick State](runtime-bricks.md) |
| Runtime bricks | `bmf.bricks.runtime.set ...` | Mutates visibility/collision for one explicit live runtime brick id. | [Runtime Brick State](runtime-bricks.md) |
| Runtime bricks | `bmf.bricks.runtime.bind ...` | Binds explicit runtime brick ids to one opaque GUID. | [Runtime Brick State](runtime-bricks.md) |
| Runtime bricks | `bmf.bricks.runtime.set-guid ...` | Mutates visibility/collision for bricks previously bound to one opaque GUID. | [Runtime Brick State](runtime-bricks.md) |
| Runtime bricks | `bmf.bricks.runtime.guid-status ...` | Prints opaque GUID binding state. | [Runtime Brick State](runtime-bricks.md) |
| Runtime bricks | `bmf.bricks.runtime.status` | Prints the last queued runtime brick result. | [Runtime Brick State](runtime-bricks.md) |
| Minigames | `bmf.minigames.*` | Desired definitions, events, data cache, and guarded unsafe wrappers. | [Minigames](minigames.md) |
| World | `bmf.world.saveas name=<world>` | Saves the current running world as a named `.brdb`. | [World](world.md) |
| Prefabs | `bmf.prefabs.loadbrz source=<file.brz> name=<world> x=<x> y=<y> z=<z> yaw=<yaw>` | Loads a staged BRZ-derived world. | [Prefabs](prefabs.md) |
| Prefabs | `bmf.prefabs.loadbrdb name=<world> x=<x> y=<y> z=<z> yaw=<yaw>` | Loads an already staged `.brdb` world bundle. | [Prefabs](prefabs.md) |
| Vehicles | `bmf.vehicles.spawnset prefix=<prefix> count=<n> ...` | Loads a pre-staged vehicle spawn set. | [Vehicles](vehicles.md) |
| Vehicles | `bmf.vehicles.snapshot name=<world>` | Saves the running world for external vehicle inventory tooling. | [Vehicles](vehicles.md) |

These commands are intended for server console or bridge `console.exec` use, not
player chat. Chat-command routing still requires authenticated player identity
and chat interception validation.

## Plugin Command Registration

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

The handler receives raw argument text when UE4SS provides it. Return the
standard BMF result shape and include optional `data.lines` for console output.
The worker writes those lines to the response file and to `runtime/bmf.log`.

When writing request files directly from Windows PowerShell, use a no-BOM
encoding. Omegga's bridge and bundled adapters already write no-BOM request
files.

Commands registered through a plugin's scoped `BMF` facade are owned by that
plugin and are automatically removed when the plugin unloads or reloads.

## Access-Checked Dispatch

`BMF.commands.dispatchWithAccess(policy, actor, name, args, ar)` dispatches a
registered command only if the command access policy allows the actor:

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
It is intended for future chat/staff command routing once authenticated player
identity is available. See
[Command Access Policy](permissions/command-access.md).

## Result Shape

Command handlers should return a standard BMF result table. Console output comes
from `data.lines`; automation should rely on machine-readable key/value fields
where available.
