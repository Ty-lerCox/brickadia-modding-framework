# BMF

BMF is the Brickadia Modding Framework: a server-side Lua framework for
Windows Brickadia dedicated servers, backed by UE4SS and Brickadia-specific
compatibility work.

Current target: Brickadia EA2 `PC-Shipping-CL13530`.

BMF currently targets the BMF-supported Omegga Windows fork for Windows server
launch, UE4SS compatibility setup, command transport, validation, and some live
player helper surfaces:

<https://github.com/Ty-lerCox/bmf-omegga-fork>

Stock upstream Omegga and the global npm package are Linux/WSL-oriented and are
not the supported Windows runtime for BMF. The supported fork intentionally
trails the latest upstream Omegga builds because BMF validates against that
fork's Windows/UE4SS bridge surfaces.

## Status

This repository is in early framework bring-up. The current package focuses on:

- UE4SS-loadable BMF bootstrap.
- Plugin discovery, metadata, lifecycle hooks, and basic text storage.
- Structured health/status output.
- Server-console `bmf.*` command registry for headless administration.
- First chat API shape.
- Player record normalization helpers.
- First world load/save API wrappers.
- First minigame list/lifecycle command wrappers.
- Server settings planning and file-backed `GameUserSettings.ini` patching.
- Role permission patch planning and headless file-backed patch validation.
- Player role assignment planning and copied `RoleAssignments.json` patching.
- No-spawn-item applicator enforcement that preserves applicator access while
  denying `SpawnItem`/`ItemSpawn`. The file-backed role policy is maintained,
  but live testing proved Brickadia does not use `BR.Permission.SpawnItems` for
  Applicator component placement; the working experimental path is a native
  `ServerAddComponent` `UFunction::Func` blocker plus Omegga-backed feedback.
  `scripts/sync-applicator-blocker-native-hook.ps1` refreshes the per-process
  native pointers and injects the blocker after a server restart.
- Interactable Print-to-Console prefix policy: Owner/Admin roles can use any
  prefix, while other roles must match a configured whitelist. The current live
  path wraps the native `ServerModifyComponent` `UFunction::Func`, blocks
  denied Interactable console tags at save time, and uses BMF/Omegga player
  identity plus chat feedback where available.
  `scripts/sync-interact-prefix-guard-native-hook.ps1` refreshes the
  per-process native pointer and injects/verifies the guard after restart.
- Brick asset placement policy: `scripts/list-brick-assets.js` inventories
  `.brdb`/`.brz` brick asset names, and `BrickAssetPlacementGuard` can evaluate
  Owner/Admin bypass plus role-aware denial for assets such as
  `B_Joint_Wheel_Micro`, `B_Seat`, and `B_1x1_Gate_WheelEngineSlim`. Live
  placement/paste blocking still needs a cancellable native hook.
- Offline BRDB archive description for saved-world vehicle/entity evidence.
- Vehicle-like dynamic actor graph snapshots from saved `.brdb` worlds.
- Vehicle inventory reports for saved-world or snapshot evidence.
- Headless server vehicle snapshots by SaveAs plus archive inspection.
- Multi-vehicle headless snapshot canary for staged worlds with several cars.
- Offline BRZ-to-BRDB prefab staging for server-side additive loading.
- Offline dynamic actor graph capture for vehicle-like saved-world groups.
- Experimental BRDB slicing for one captured dynamic actor graph, with a
  repeatable headless additive-load/save canary.
- Experimental staged vehicle BRDB id remapping for duplicate additive loads,
  with a headless two-car isolation canary.
- Headless remapped vehicle spawn-set canary for generating several isolated
  staged car copies from one captured single-car slice.
- First Lua prefab facade for loading BRZ-derived staged world bundles.
- First Lua vehicle spawn-set facade for loading staged remapped vehicle copies.
- BMF-supported Omegga Windows fork direction for server launch, command
  transport, player-sync, minigame event feeding, live chat helper delivery,
  and validation.
- Static package validation.
- Headless validation artifacts for world/archive research.

See [TODO.md](TODO.md) for the long-term roadmap and
[OVERNIGHT_STRATEGY.md](OVERNIGHT_STRATEGY.md) for unattended validation work.

## Documentation

API documentation is published with GitHub Pages after pushes to `main`:

<https://ty-lercox.github.io/brickadia-modding-framework/>

Build the docs locally with MkDocs:

```powershell
python -m pip install -r requirements-docs.txt
python -m mkdocs build --strict
```

## Layout

```text
framework/ue4ss/Mods/BMF/   UE4SS Lua mod package
installer/                  Windows install and rollback scripts
examples/                   Example BMF plugins
docs/                       Install, API, and validation docs
integrations/               Supported external adapters, currently Omegga
manifests/                  Package and compatibility metadata
scripts/                    Local validation helpers
cli/                        bmfctl manager/troubleshooting CLI
tests/fixtures/             Static fixtures for wrapper tests
artifacts/                  Generated validation evidence
```

## First Validation

Run the static package validator:

```powershell
.\scripts\validate-package.ps1
```

Validate the `bmfctl` manager CLI:

```powershell
.\scripts\validate-bmfctl.ps1
```

Run the BMF doctor against the local environment:

```powershell
node .\cli\bin\bmfctl.js doctor
```

Build and validate a release zip:

```powershell
.\scripts\validate-release-package.ps1
```

Runtime validation is tracked through timestamped artifacts under
`artifacts/overnight/`.

## Native Applicator Hook Sync

The experimental `NoSpawnItemApplicator` live blocker depends on Brickadia
runtime pointers that move on every server restart. With the BMF-supported
Omegga Windows fork already running, refresh and install the blocker with:

```powershell
.\scripts\sync-applicator-blocker-native-hook.ps1
```

The script queries BMF for the current `ItemSpawn` component pointer, scans the
running server for `BRTool_Applicator.ServerAddComponent`, updates
`artifacts/local/applicator-func-blocker-control.txt`, builds/injects the native
DLL if needed, and skips reinjection when the hook is already installed in that
process. Player/role based `allowed_context` entries are still managed by the
`NoSpawnItemApplicator` plugin.
