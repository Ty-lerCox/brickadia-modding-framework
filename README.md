# BMF

BMF is the Brickadia Modding Framework: a server-side Lua framework for
Windows Brickadia dedicated servers, backed by UE4SS and Brickadia-specific
compatibility work.

Current target: Brickadia EA2 `PC-Shipping-CL13530`.

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
manifests/                  Package and compatibility metadata
scripts/                    Local validation helpers
tests/fixtures/             Static fixtures for wrapper tests
artifacts/                  Generated validation evidence
```

## First Validation

Run the static package validator:

```powershell
.\scripts\validate-package.ps1
```

Build and validate a release zip:

```powershell
.\scripts\validate-release-package.ps1
```

Runtime validation is tracked through timestamped artifacts under
`artifacts/overnight/`.
