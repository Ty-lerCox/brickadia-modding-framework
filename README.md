# BMF

BMF is the Brickadia Modding Framework: a server-side Lua framework for
Windows Brickadia dedicated servers, backed by UE4SS and Brickadia-specific
runtime compatibility work.

Current target: Brickadia EA2 `PC-Shipping-CL13530`.

## Start Here

Use the published documentation for the readable version of the project:

<https://ty-lercox.github.io/brickadia-modding-framework/>

Key entry points:

- [Supported Runtime Matrix](docs/reference/supported-runtime.md): what runtime
  BMF supports today and what is experimental.
- [Architecture Patterns](docs/architecture/architecture-patterns.md):
  high-level sequence diagrams for BMF, Lua plugins, the event bus, Omegga, and
  ConsoleTag lookup.
- [Resource Lookup Tags](docs/guides/resource-lookup-tags.md): the
  `lookup:<uuid>:<purpose>` in-game tag format and Lua visibility/collision
  examples.
- [API Overview](docs/api/index.md): current Lua API surfaces and their status
  labels.
- [Lua Examples](docs/examples/index.md): copyable and runnable plugin
  examples.
- [Status Dashboard](docs/status.md): current capability status, blockers, and
  validation stages.

## Runtime Model

BMF currently targets the BMF-supported Omegga Windows fork for server
operation. The supported fork owns launch coordination, player sync, minigame
event feeding, live chat helper delivery, metrics export, and validation
workflows.

The framework can also run as a UE4SS Lua mod with file-backed command/event
transport. The optional `BMFSocket` transport gives the Omegga bridge a
lower-latency loopback path, while file-backed transport remains the fallback.

## Build The Docs

```powershell
python -m pip install -r requirements-docs.txt
python -m mkdocs build --strict
```

## Root Workspace

The repository now has a root workspace entry point for the consolidated BMF
runtime program. It keeps Desktop and Omegga dependency installs on their
existing lockfiles while giving maintainers one place to set up, validate, test,
and build release artifacts.

```powershell
npm run setup
npm run validate
npm run validate:ci
npm run test
npm run release:desktop
```

Use Node `22.22.3+`, `24.15.0+`, or `26+` so the Angular Desktop build and the
BMF-supported Omegga runtime agree on the same runtime floor.

For an operator machine, `bmfctl prerequisites` reports the local setup state
for BMF assets, Brickadia server files, the Omegga install target, Node/npm,
PowerShell, and optional Grafana Alloy before mutating install/start actions.

GitHub Actions workflow `.github/workflows/unified-runtime.yml` runs workspace
validation, CLI/core tests, Desktop renderer build, Omegga runtime tests,
native helper validation, release package validation, docs build, and
manual/tagged MSI artifact creation.

## Validate Locally

```powershell
.\scripts\validate-package.ps1
.\scripts\validate-bmfctl.ps1
node .\cli\bin\bmfctl.js doctor
.\scripts\validate-release-package.ps1
```

Runtime validation evidence is written under `artifacts/overnight/`.

## Repository Layout

```text
framework/ue4ss/Mods/BMF/          UE4SS Lua mod package
framework/ue4ss/Mods/BMFSocket/    Optional native socket transport package
framework/ue4ss/Mods/BMFFrameTelemetry/
                                    Optional native frame-time sampler package
installer/                         Windows install and rollback scripts
examples/                          Runnable example BMF plugins
docs/                              Install, API, architecture, and validation docs
integrations/                      Supported external adapters, currently Omegga
manifests/                         Package and compatibility metadata
scripts/                           Local validation helpers
native/                            Native transport and telemetry sources
cli/                               bmfctl manager/troubleshooting CLI
apps/bmf-desktop/                  Electron and Angular Material desktop app
packages/orchestrator-core/         Shared install, health, update, and telemetry API
packages/omegga-runtime/            BMF-supported Omegga runtime package boundary
packages/omegga-plugins/            Generic Omegga adapters for BMF-aware game modes
compat/                             UE4SS and Brickadia compatibility package boundaries
observability/                      Grafana Alloy and dashboard assets
tests/fixtures/                    Static fixtures for wrapper tests
artifacts/                         Generated validation evidence
```

## Maintainer Notes

Native hook refresh and pointer-sensitive maintenance notes live in
[Native Hook Notes](docs/maintainers/native-hooks.md).
