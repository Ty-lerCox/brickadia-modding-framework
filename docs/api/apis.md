# API Labels

BMF exposes machine-readable stability, crash-risk, and validation labels for
the public Lua surface.

## Examples

- [InspectApiLabels](../examples/index.md#inspectapilabels): complete plugin
  that lists a namespace and inspects labels for one API.

```lua
local listed = BMF.apis.list({ namespace = "players" })
local whisper = BMF.apis.get("BMF.chat.whisper")
local summary = BMF.apis.summary()
```

Server-console route:

```text
Omegga.Bridge.BMF bmf.apis
Omegga.Bridge.BMF bmf.apis name=BMF.chat.whisper
Omegga.Bridge.BMF bmf.apis risk=live-player
Omegga.Bridge.BMF bmf.apis stability=experimental
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

`BMF.apis` does not make an API safer by itself. It records the current proof
level so automation can choose appropriate work:

- `L0 Static`: no server boot required.
- `L1 Boot`: BMF starts and writes runtime status on a dedicated server.
- `L2 Headless`: proved on a disposable dedicated server without a player.
- `L3 Live Player`: still needs a connected player for meaningful proof.
- `L4 Multiplayer`: needs two or more connected players for meaningful proof.
- `L5 Negative`: failure or abuse behavior is tested.
- `L6 Frame Time`: native frame telemetry is captured around the feature path
  and checked for average/max frame time, slow frames, spikes, and attribution.

## Validation Command

`scripts/validate-bmf-api-labels.ps1` loads a temporary plugin and proves:

- plugin Lua can call `BMF.apis.get`, `BMF.apis.list`, and
  `BMF.apis.summary`;
- `BMF.chat.whisper` is labeled as `experimental`, `live-player`, and
  `requiresPlayer=true`;
- `BMF.version` is labeled as a stable low-risk framework string;
- `BMF.loadPlugins` and `BMF.unloadPlugins` are labeled as stable
  medium-risk plugin lifecycle functions;
- `BMF.storage.readJson` is labeled as stable, low-risk, and storage-capability
  gated;
- `BMF.server.shutdown` is labeled as restricted, high-risk,
  `server.shutdown` capability gated, and currently safe-failure validated on
  CL13530;
- `BMF.permissions.evaluateApplicatorComponentAccess` is labeled stable,
  low-risk, and headless/negative validated for policy decisions;
- `BMF.permissions.evaluateInteractConsolePrefixAccess` is labeled stable,
  medium-risk, and headless/negative validated for Interactable
  Print-to-Console prefix decisions;
- `BMF.permissions.evaluateBrickAssetAccess` is labeled stable, low-risk, and
  headless/negative validated for brick asset placement policy decisions;
- `BMF.permissions.enforceNoSpawnItemApplicator` is labeled file-backed,
  high-risk, and copied-file validated for `RoleSetup2.json` mutation;
- `BMF.tools.onApplicatorComponentApply` is labeled experimental,
  `unsafe-native`, `tools.applicator` capability gated, and player-effect
  validation dependent; the direct Lua hook path is disabled by default on
  CL13530 because it crashes while marshaling a struct parameter;
- `BMF.tools.applicator.status` is labeled experimental and reports the live
  applicator handler/cache state plus the unsafe Lua hook opt-in state;
- `BMF.server.exec` is labeled `restricted` and `unsafe-native`;
- `BMF.world.loadAdditive` and `BMF.vehicles.spawnSet` remain experimental;
- `bmf.apis` can filter by name, risk, stability, and player requirement.
