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
audit trail. For CityRPG minigame work, this replaces the legacy
`omegga-minigameevents` polling plugin: BMF should produce minigame
lifecycle/combat events, and CityRPG should consume socket event records first,
tailing `runtime/events.jsonl` only when the socket is unavailable. The first
supported producer is the Omegga adapter at
`integrations/omegga/bmf-minigame-events/`, which writes BMF command files for
`BMF.minigames.emitEvent`. The event surface uses namespaced BMF event names
such as `minigames.joinminigame`, `minigames.kill`, and `minigames.death`;
relays map those back to CityRPG's legacy event names at the application
boundary. BMF-native data events such as `minigames.snapshot`,
`minigames.created`, `minigames.deleted`, and `minigames.teamchange` update
`BMF.minigames.data()` and do not require CityRPG to depend on Omegga's legacy
minigame event plugin. The packaged adapter defaults to log-events-only;
snapshot, team, and leaderboard polling remain unsafe opt-ins until BMF has a
proven native hook or another safe Brickadia data source.

Live validation on June 7, 2026 proved this bridge with CityRPG: a
`minigames.joinminigame` event reached the plugin over the socket path, and the
follow-up team assignment command returned with `bmf_command_transport=socket`
in about 51ms.

## Validation

- `L0 Static`: package validator checks event API markers, docs, and canary.
- `L2 Headless`: `scripts/validate-bmf-events.ps1` loads a temporary plugin,
  proves `serverReady` and `pluginLoaded`, emits a custom event with
  registration/removal, verifies emitted records in `runtime/events.jsonl`,
  saves the world through BMF, proves `worldSaved`, then reloads plugins to
  prove plugin-owned handlers do not duplicate.
  The validator stages an `EventCanary` plugin into the UE4SS BMF runtime and
  refuses to mutate the shared Omegga runtime while another Brickadia server is
  active unless `-AllowSharedRuntimeMutation` is explicitly supplied.
