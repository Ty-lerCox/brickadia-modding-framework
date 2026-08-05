# Events API

**Labels:** `stable`, `event-bus`, `L2 Headless`

## Who Should Read This?

Plugin authors should use this page for in-process BMF events. Omegga integrators should use it to understand the socket and JSONL relay contract.

BMF exposes a small event bus for plugins:

For the high-level in-process and Omegga socket event flows, see
[Architecture Patterns](../architecture/architecture-patterns.md).

## Examples

- [EventAudit](../examples/event-audit.md): complete plugin that
  subscribes to `serverReady` and records an audit event.

```lua
local id = BMF.events.on("serverReady", function(data, event)
  BMF.log("ready version=" .. tostring(data.version))
end)

BMF.events.off(id)
```

## `BMF.events.on(name, handler)`

Registers a handler and returns a numeric handler id. Handlers receive
`data, eventName`.

Handlers registered through a plugin's scoped `BMF` facade are owned by that
plugin and are automatically removed when the plugin unloads or reloads.

## `BMF.events.off(id)`

Unregisters a handler id. Returns `true` when a handler was removed.
The scoped plugin facade can remove only a handler registered by that same
plugin; an id owned by the framework or another plugin returns `false` and is
left intact.

## `BMF.events.emit(name, data)`

Emits an event and returns the standard BMF result shape. Plugins can emit
custom events for their own coordination.

Each emitted event is appended to `runtime/events.jsonl` as diagnostic evidence
with `source: "event"`, the event name, payload, handler count, and any handler
errors. BMF also sends an event envelope to the Omegga socket broker so external
integrations can subscribe without waiting for file polling. Integrations should
use the socket path for live gameplay traffic.

## `BMF.events.listenerCount(name)`

Returns the number of currently registered handlers for an event.

## Framework Events

- `serverReady`: emitted after plugins load and the BMF runtime starts.
- `pluginLoaded`: emitted after a plugin `onLoad` succeeds.
- `pluginUnloaded`: emitted after a plugin unload succeeds.
- `worldLoaded`: emitted after `BMF.world.loadAdditive` succeeds.
- `worldSaved`: emitted after `BMF.world.saveAs` succeeds.
- `interactConsole`: emitted by `BMF.interact.handleConsoleMessage()` and the
  `bmf.interact.console` command when Omegga forwards an Interactable
  Print-to-Console event. The payload includes `message`, `player`,
  `brickName`, `brickAsset`, and `position`.
- `shutdownRequested`: reserved for a future proven shutdown executor; the
  current CL13530 `BMF.server.shutdown` path reports `SHUTDOWN_UNAVAILABLE`
  before emitting lifecycle shutdown events.

## Native Zone Events

BMF can run an experimental native overlap trace for Brickadia
character/projection zones:

- `zones.character.entered`: emitted when a traced overlap candidate indicates a
  character entered a zone-like actor or component.
- `zones.character.left`: emitted when a traced overlap candidate indicates a
  character left a zone-like actor or component.

Start the trace with `bmf.tools.zone.native.start`. For discovery sessions, pass
`captureAll=true scanLocalObjects=true` and then review emitted payloads before
tightening the hook. The event payload includes the native hook label, action,
match reason, context object, and reflected/local UObject references that were
captured from the overlap parameters.

## Zone Console Trace Events

BMF can also run a marker-filtered console/log stack trace while discovering the
real Brickadia projection-zone dispatcher:

- `zones.console.trace`: emitted when `bmf.tools.zone.console.start` has patched
  the process WriteFile/WriteConsole import entries and a printed line contains
  the configured marker.

Use a unique in-game Print-to-Console marker such as `BMF_ZONE_TRACE_ENTER`.
The payload includes the matched message, API path, thread id, Brickadia module
base, and captured stack frames with module RVAs and Brickadia RVAs. This is a
diagnostic bridge for reverse engineering, not the final gameplay event API.

## Zone Wire PrintTo Console Events

BMF can run a bounded native trace on the Brickadia wire `PrintToConsole`
callsite that emits `[Wire Graph]` messages:

- `zones.wire.print_console`: emitted when `bmf.tools.zone.wire.start` has
  patched the wire print callsite and a wire graph prints to the server log.

This is the current proven hook for projection-zone wire output. The payload
includes the printed `value`, full `[Wire Graph]` message, callsite/formatter
addresses, Brickadia module base, thread id, and captured stack frames. Use a
small `limit` during discovery and stop the trace when finished.

## External Relays

The socket event stream is the live bridge for integrations that need BMF events
outside UE4SS Lua. JSONL remains diagnostic evidence and should not be treated
as the normal live event transport.

Current CityRPG pattern:

- BMF emits namespaced event records such as `minigames.joinminigame`,
  `minigames.kill`, and `minigames.death`.
- CityRPG consumes socket events and treats socket disconnects as unhealthy
  integration state.
- External relays map BMF event names back to CityRPG's legacy application
  event names at the boundary.
- The packaged Omegga adapter lives at
  `packages/omegga-plugins/bmf-minigame-events/`.

Snapshot, team, and leaderboard polling remain unsafe opt-ins until BMF has a
proven native hook or another safe Brickadia data source.

Live validation on June 7, 2026 proved this bridge with CityRPG: a
`minigames.joinminigame` event reached the plugin over the socket path, and the
follow-up team assignment command returned with `bmf_command_transport=socket`
in about 51ms.

## Validation

Event-bus proof is tracked in
[API Validation Evidence](../validation/api-validation.md#framework-utilities).
