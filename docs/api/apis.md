# API Labels

**Labels:** `stable`, `diagnostic`, `L2 Headless`

## Who Should Read This?

Plugin authors should use this page to inspect API stability and risk before calling a helper. Maintainers should use it when changing API label metadata or validation expectations.

BMF exposes machine-readable stability, crash-risk, and validation labels for
the public Lua surface.

## Examples

- [InspectApiLabels](../examples/inspect-api-labels.md): complete plugin
  that lists a namespace and inspects labels for one API.

```lua
local listed = BMF.apis.list({ namespace = "players" })
local whisper = BMF.apis.get("BMF.chat.whisper")
local summary = BMF.apis.summary()
```

Server-console route:

```text
bmf.apis
bmf.apis name=BMF.chat.whisper
bmf.apis risk=live-player
bmf.apis stability=experimental
```

Each API record includes:

- `name`
- `namespace`
- `kind`
- `stability`
- `risk`
- `validation`
- `requiresPlayer`
- `capability`
- `summary`

## Stability Values

- `stable`: safe enough for normal plugin use within the documented validation
  level.
- `experimental`: useful, but still tied to reverse-engineering evidence or
  command-backed behavior.
- `scaffold`: public shape exists, but the full live behavior is not proven.
- `file-backed`: plans or patches copied config files; live hot-reload behavior
  is not implied.
- `restricted`: intentionally dangerous or internal-leaning; use a safer typed
  wrapper when possible.

## Risk Values

- `low`: unlikely to mutate game state or touch unsafe live objects.
- `medium`: mutates BMF state, plugin files, server files, or command state.
- `high`: mutates world/gameplay state or can disrupt a running server.
- `unsafe-native`: raw or broad native/console escape hatch.
- `live-player`: needs a connected player/controller to prove the real behavior.

## Validation

API label canary coverage is tracked in
[API Validation Evidence](../validation/api-validation.md#api-labels).
