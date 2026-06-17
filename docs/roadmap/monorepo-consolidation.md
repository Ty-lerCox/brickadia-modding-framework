# Monorepo Consolidation

This page defines how the separate BMF, Omegga fork, native helpers,
observability assets, and generic Omegga adapters should converge into one BMF
repository.

## Who Should Read This?

BMF maintainers should use this page before moving code between repositories.
Server operators should treat it as future packaging direction, not current
install guidance.

## Consolidation Goal

The `brickadia-modding-framework` repository should become the canonical source
for all BMF-managed runtime pieces:

- BMF UE4SS Lua runtime;
- optional native socket and frame telemetry mods;
- BMF-compatible Omegga runtime;
- generic Omegga bridge/player/minigame adapters;
- Grafana Alloy and dashboard assets;
- CLI and desktop orchestration tools;
- compatibility manifests and validation scripts.

CityRPG should not be merged wholesale. It should consume BMF as a game-mode
plugin and keep game-specific policy, economy, resources, commands, and
persistence in its own repository.

## Target Layout

```text
apps/
  bmfctl/
  bmf-desktop/
  release/
packages/
  orchestrator-core/
  bmf-runtime/
  bmf-plugin-sdk/
  bmf-native-socket/
  bmf-frame-telemetry/
  omegga-runtime/
  omegga-plugins/
    bmf-bridge/
    bmf-player-sync/
    bmf-minigame-events/
compat/
  ue4ss/
observability/
  alloy/
  grafana/
docs/
manifests/
scripts/
```

The first migration does not need to land exactly in that final layout. It
should preserve working package boundaries and avoid moving unrelated runtime
state into source control.

Current seed: package-boundary manifests exist for `packages/bmf-runtime`,
`packages/bmf-native-socket`, `packages/bmf-frame-telemetry`, and
`packages/omegga-runtime`, plus `compat/ue4ss`. The BMF and native helper
boundaries point at the current `framework/ue4ss/Mods/*` and `native/*` source
roots so install scripts can keep using proven paths while release validation
starts enforcing package ownership. The Omegga boundary now includes the
synced BMF-compatible fork source in `packages/omegga-runtime/source`, records
the fork/upstream URLs and source commit in sync metadata, and keeps generated
dependency/cache directories out of the repo. The UE4SS boundary keeps
`manifests/compatibility.json` authoritative for the current Brickadia target
until a dedicated compatibility bundle layout is introduced.

## Root Workspace Contract

The root `package.json` is the maintainer entry point for setup, validation,
tests, Desktop builds, and MSI release packaging. It declares only the
first-party packages that can safely participate in npm workspaces today:
`apps/bmf-desktop`, `cli`, and `packages/orchestrator-core`.

The BMF-supported Omegga source and Desktop packaged assets remain dependency islands.
They keep their own lockfiles because they have different packaging and runtime
constraints. Root scripts call those installs explicitly with
`npm --prefix`, so a clean checkout can still run `npm run setup` without
pretending every vendored runtime source is the same package type.

`scripts/validate-workspace.ps1` validates this contract and is called from the
top-level package validator.

## Ownership Rules

| Piece | Future owner | Notes |
| --- | --- | --- |
| BMF Lua runtime | `packages/bmf-runtime` | Current `framework/ue4ss/Mods/BMF` source of truth. |
| BMFSocket | `packages/bmf-native-socket` | Ships with BMF and is installed as an optional native UE4SS mod. |
| BMFFrameTelemetry | `packages/bmf-frame-telemetry` | Optional native sampler used by Grafana/Alloy path. |
| Omegga runtime | `packages/omegga-runtime` | BMF-compatible fork, synced from upstream Omegga deliberately. |
| Generic bridge plugin | `packages/omegga-plugins/bmf-bridge` | Reusable event/command adapter for all BMF-aware game modes. |
| Player sync adapter | `packages/omegga-plugins/bmf-player-sync` | Feeds safe identity records into BMF. |
| Minigame event adapter | `packages/omegga-plugins/bmf-minigame-events` | Keeps unsafe polling opt-in and BMF event contract stable. |
| Orchestration core | `packages/orchestrator-core` | Shared install, doctor, repair, launch, telemetry setup, and event inspection API. |
| CLI | `apps/bmfctl` | Thin command-line wrapper over orchestration core. |
| Desktop UI | `apps/bmf-desktop` | Electron plus Angular and Angular Material 3 wrapper over orchestration core. |
| Release packaging | `apps/bmf-desktop` plus `release/` | Produces MSI installers, checksums, manifests, and optional portable developer artifacts. |

## What Not To Vendor

Do not commit or migrate:

- `node_modules`;
- Brickadia saves and local runtime data;
- server logs except trimmed validation evidence;
- local Grafana API keys or remote-write tokens;
- generated Alloy WAL data;
- personal Omegga configs;
- CityRPG game-mode data stores.
- generated MSI outputs except published release artifacts.

## Migration Rule

Move working source and manifests first, then wire install flows. Do not delete
the current Omegga fork or current BMF installers until the monorepo can build,
package, install, run doctor checks, and stage the same UE4SS/BMF/Omegga stack.
