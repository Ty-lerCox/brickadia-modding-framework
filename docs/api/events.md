# Events API

BMF exposes a small event bus for plugins:

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

## Validation

- `L0 Static`: package validator checks event API markers, docs, and canary.
- `L2 Headless`: `scripts/validate-bmf-events.ps1` loads a temporary plugin,
  proves `serverReady` and `pluginLoaded`, emits a custom event with
  registration/removal, saves the world through BMF, proves `worldSaved`, then
  reloads plugins to prove plugin-owned handlers do not duplicate.
