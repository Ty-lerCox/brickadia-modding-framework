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

## `BMF.events.emit(name, data)`

Emits an event and returns the standard BMF result shape. Plugins can emit
custom events for their own coordination.

Each emitted event is also appended to `runtime/events.jsonl` with
`source: "event"`, the event name, payload, handler count, and any handler
errors. When the socket bridge is active, BMF also sends an event envelope to
the Omegga socket broker so external integrations can subscribe without waiting
for file polling. Integrations should use the socket path for latency-sensitive
gameplay and keep the JSONL stream as a durable fallback and audit trail.

## `BMF.events.listenerCount(name)`

Returns the number of currently registered handlers for an event.

## Framework Events

- `serverReady`: emitted after plugins load and the BMF command worker starts.
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

## External Relays

The socket event stream is the preferred live bridge for integrations that need
BMF events outside UE4SS Lua. The JSONL event stream remains the fallback and
audit trail.

Current CityRPG pattern:

- BMF emits namespaced event records such as `minigames.joinminigame`,
  `minigames.kill`, and `minigames.death`.
- CityRPG consumes socket events first and tails `runtime/events.jsonl` only
  when the socket is unavailable.
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
