# BMF Unified Runtime Goal

This goal is the north star for consolidating BMF, the BMF-supported Omegga
runtime, native helpers, telemetry, adapters, and desktop tooling into one
self-sustaining project.

## Goal Statement

BMF should become the standard Windows distribution for running a fully modded
Brickadia dedicated server.

A Windows user should be able to download an MSI, install BMF Desktop, create a
server profile, install the supported runtime stack, start the server, verify
health, configure Grafana telemetry, inspect BMF/Omegga event traffic, and keep
the stack updated without manually assembling repositories, scripts, native
mods, Omegga plugins, or Grafana assets.

BMF Desktop should be able to get the user to that healthy state without an LLM,
manual shell session, or repository-aware operator. Any recovery step that fixes
an installed profile must become a deterministic Desktop or `bmfctl` action:
profile discovery, profile-store migration, dependency install, asset staging,
launch-script repair, port diagnostics, service start/restart, Alloy setup,
dashboard payload generation, log capture, and troubleshooting snapshots.

## User Outcome

The target operator experience is:

1. Download `BMF-Desktop-<version>-x64.msi`.
2. Install BMF Desktop.
3. Open the app and create a local Brickadia server profile.
4. Install or locate Brickadia dedicated server files.
5. Install the BMF-compatible Omegga runtime.
6. Stage UE4SS, BMF Lua runtime, BMFSocket, optional BMFFrameTelemetry, and
   generic Omegga bridge adapters.
7. Start Omegga and the managed Brickadia server.
8. See health status for every required service.
9. Configure Grafana Cloud and Grafana Alloy.
10. Import the standard BMF dashboard and open it for real telemetry.
11. Inspect live BMF/Omegga command and event payloads in BMF Desktop.
12. Update, repair, snapshot, or roll back components from the same tool.

## Product Boundary

BMF Desktop is a local operations control panel. It installs, runs, diagnoses,
and inspects the stack.

It should show:

- component install state;
- service health;
- start, stop, and restart actions;
- doctor findings and repair actions;
- local logs and action output;
- Grafana setup status and dashboard link;
- live BMF/Omegga socket and fallback event payloads;
- update and release artifact status.

It should not become:

- a replacement for Grafana dashboards;
- a PromQL exploration UI;
- an architecture diagram viewer;
- an unrestricted shell terminal;
- a CityRPG-specific control panel.

## Required Stack

The consolidated BMF repo should own or package:

| Layer | Requirement |
| --- | --- |
| Desktop installer | MSI release artifact for normal Windows users. |
| Desktop app | Electron shell with Angular renderer and Angular Material 3/Material You-style UI. |
| Orchestration core | Shared install, doctor, repair, launch, telemetry, update, and snapshot API. |
| CLI | `bmfctl` as a thin wrapper around orchestration core. |
| BMF runtime | UE4SS Lua framework, plugins, runtime files, telemetry, and audit output. |
| Native helpers | BMFSocket and BMFFrameTelemetry packages. |
| Omegga runtime | BMF-compatible Omegga runtime synced deliberately from upstream Omegga. |
| Omegga adapters | Generic bridge, player sync, and minigame event adapters. |
| UE4SS compatibility | Versioned compatibility bundles and validation manifests. |
| Observability | Alloy config templates and standard Grafana dashboard JSON. |
| Release metadata | Component manifests, checksums, release notes, and update metadata. |

The machine-readable seed for this stack is `manifests/unified-runtime.json`,
and `scripts/validate-unified-runtime-manifest.ps1` keeps the manifest aligned
with this goal and the roadmap docs.

## Root Workspace

The root `package.json` is the maintainer entry point for the self-sustaining
repo. It exposes `npm run setup` for clean-checkout dependency install,
`npm run validate` for the package validation chain, `npm run test` for the
current Node test suites, and `npm run release:desktop` for the MSI release
pipeline.

`scripts/validate-workspace.ps1` keeps the root scripts, workspace boundaries,
and dependency-island lockfiles aligned with this goal.

## CI And Release Automation

`.github/workflows/unified-runtime.yml` is the first unified GitHub Actions
workflow for the self-sustaining repo. It runs the root workspace/package
validators, CLI and orchestration-core tests, Desktop renderer build and
release metadata validation, BMF-supported Omegga runtime install/tests, native
helper validation with optional UE4SS-source builds, release package
validation, docs build, and manual/tagged MSI artifact generation.

`scripts/validate-ci-workflows.ps1` keeps that workflow aligned with the root
workspace and Phase 7 release requirements.

The first shared code scaffold now lives in `packages/orchestrator-core`, with
`scripts/validate-orchestrator-core.ps1` covering its manifest, profile,
release-artifact, health-model, prerequisite audit, dry-run
operation-planning, and shared troubleshooting snapshot helpers.

The first desktop scaffold now lives in `apps/bmf-desktop`, with
`scripts/validate-bmf-desktop.ps1` checking the Electron shell, Angular
renderer, Angular Material 3 theme, MSI packaging metadata, and the shared
profile, setup readiness, telemetry, update, service, traffic, log, and
snapshot control surfaces.

The first repeatable desktop release path now lives in
`scripts/build-bmf-desktop-release.ps1`. With `-BuildMsi`, it validates the
selected Angular-supported Node runtime, compiles the Angular renderer, invokes
electron-builder's MSI target, and emits the checksum, release manifest,
release catalog, and release notes for the produced installer.
Managed stack update transactions now consume that same release catalog and
manifest evidence, verify the MSI checksum before component staging, and write
`component-update-snapshot.json` for pre-update rollback/troubleshooting state.
Managed repair transactions now collect pre/post health snapshots, snapshot
mutable UE4SS/Omegga files before repair, restore missing BMF runtime and
generic adapter assets, repair the generated Omegga launch script, and rewrite
UE4SS enablement files so BMF remains enabled after repair.

The MSI packaging seed now bundles the BMF-owned runtime asset tree under
Electron `resources/bmf`: manifests, `bmfctl`, orchestrator-core package
boundary files, UE4SS BMF/BMFSocket/BMFFrameTelemetry mod assets,
package-boundary metadata, the synced BMF-compatible Omegga runtime source,
generic Omegga adapters, UE4SS compatibility metadata, and Grafana/Alloy
observability assets. Installed Desktop instances default reads to that
bundled tree and default local writes to Electron `userData`.

The first installed `bmfctl` shim now lives in the Desktop packaged asset
boundary. It uses the installed Electron executable in Node mode, points
`BMF_ROOT` at the bundled asset tree, and shares the Desktop app-data defaults
for profiles, transactions, service logs, updates, and troubleshooting
snapshots.
Packaged Electron now also pins its app name and user-data path to
`BMF Desktop`, matching the installed `bmfctl` shim, and migrates the accidental
legacy `%APPDATA%\@bmf\desktop` profile store into the canonical
`%APPDATA%\BMF Desktop` store when the canonical file does not exist.

The first observability scaffold now lives in `observability`, with
`scripts/validate-observability-assets.ps1` checking the Alloy scrape and
remote-write template, the standard Grafana dashboard JSON, and the dashboard
import payload contract.
BMF Desktop now writes generated profile-specific Alloy config through the
shared telemetry renderer and Electron IPC, using the configured profile path
or an Electron user-data default while keeping Grafana secrets as environment
variable references.
BMF Desktop and `bmfctl` now expose shared `start-alloy`, `stop-alloy`, and
`restart-alloy` service actions with configured Alloy executable/config paths,
BMF-scoped storage, and separate `grafana-alloy` PID/log/journal evidence.
BMF Desktop now adopts dashboard URLs returned by confirmed Grafana dashboard
uploads into the active profile draft and opens the configured dashboard
through Electron's guarded HTTP(S)-only external link path.

The first BMF runtime and native helper package boundaries now live in
`packages/bmf-runtime`, `packages/bmf-native-socket`, and
`packages/bmf-frame-telemetry`, with
`scripts/validate-bmf-runtime-packages.ps1` checking their package manifests,
current source roots, install roots, build scripts, and stable runtime markers.

The first Omegga runtime package boundary now lives in
`packages/omegga-runtime`, with
`scripts/validate-omegga-runtime-package.ps1` checking the BMF fork URL,
upstream Omegga URL, synced fork commit, `source/` tree, required helper
surfaces, dependency manifest alignment, and packaging guardrails.

The first self-starting Omegga install path now lives in the shared
transaction runner. Installing the stack copies the synced Omegga source into a
writable runtime path, writes `Start-BrickadiaOmegga.ps1`, and then stages the
generic bridge and adapter plugins. Service actions infer that generated script
from the selected runtime path, require explicit start confirmation, and log
dependency install/build/start output through the existing service journal
path.
Profiles now carry launcher metadata for the supported local Windows process
path. Containerized and Linux launchers are intentionally out of scope for the
local server path because the UE4SS/BMF-managed stack requires Windows. Any
future remote Windows launcher must keep the same explicit confirmation,
service logs, and journal evidence model.

The first UE4SS compatibility package boundary now lives in `compat/ue4ss`,
with `scripts/validate-ue4ss-compat-package.ps1` checking the compatibility
manifest, target Brickadia build, current UE4SS mod source roots, required
runtime surfaces, and release packaging guardrails.

The first generic bridge scaffold now lives in
`packages/omegga-plugins/bmf-bridge`, with
`scripts/validate-bmf-bridge-plugin.ps1` checking socket, JSONL, file-command,
redaction, bounded-retention, and pause/backpressure behavior.

The first devtool-style event inspector seed is now in BMF Desktop. It uses the
shared observe-only traffic snapshot, adds Material filters and selected
payload rendering, exposes copy actions, shows source/socket state, and writes
confirmed anonymized redacted trace exports through the shared
`traffic.trace.export` contract.
BMF Desktop now also runs a bounded live-refresh loop over that shared snapshot,
with explicit pause/resume, in-flight suppression, and last-refresh status so
operators can watch existing BMF/Omegga traffic without generating server
traffic.

The first canonical Omegga adapter packages now live in
`packages/omegga-plugins/bmf-player-sync` and
`packages/omegga-plugins/bmf-minigame-events`, with
`scripts/validate-bmf-omegga-adapters.ps1` checking package files, JSON
metadata, adapter guardrail markers, and Node test coverage.

## Desktop UI Requirements

BMF Desktop should use Angular Material 3 components as the default UI system.
The renderer should use Material 3 theme tokens for color, typography, density,
elevation, and shape. It should use Material controls for forms, buttons,
dialogs, steppers, tabs, tables, snackbars, tooltips, menus, progress, and
status surfaces.

The UI should feel like a serious local operations console:

- compact and scannable;
- clear status colors for healthy, degraded, unhealthy, and unknown;
- logs and actions close to the failing health checks;
- accessible focus, contrast, labels, and keyboard behavior;
- no decorative diagrams or visual noise.

The UI must also be self-reconciling. On startup it should load the selected
stored profile, run bounded health probes and port diagnostics, hydrate setup
readiness, service contracts, logs, and traffic, and render the next safe action
without requiring a human to know which CLI command or PowerShell repair to run.

## Health Definition

A server profile is healthy when:

- Brickadia dedicated server files match the selected supported build;
- Omegga is installed and running for the selected profile;
- UE4SS is staged and enabled;
- OmeggaBridge is present, enabled, and reporting capabilities;
- BMF is loaded and writes fresh `runtime/status.json`;
- socket transport is connected when required;
- file-backed command and JSONL fallback paths are available;
- Omegga `/metrics` is reachable;
- Alloy is scraping and remote-writing when telemetry is configured;
- the standard Grafana dashboard exists and opens for the profile.

Optional components such as BMFFrameTelemetry can be degraded instead of
unhealthy when the selected profile does not require them.

## Event Traffic Goal

BMF Desktop should include an event traffic inspector for live operational
debugging. It should show a timeline of BMF/Omegga events, commands, responses,
payloads, transports, statuses, sources, and consumers.

The inspector should behave like a local event devtool:

- socket first for live events;
- JSONL and file-backed records as durable fallback;
- filters by event, command, source, transport, status, and plugin;
- structured JSON payload viewer;
- redaction before display and export;
- bounded memory and backpressure when paused.

The inspector must observe existing traffic. It must not add expensive server
polling just to make the UI interesting.

## Grafana Goal

BMF Desktop should make the telemetry path easy to set up, but Grafana remains
the telemetry dashboard.

The app should:

- collect Grafana Cloud remote-write settings;
- store secrets outside source control;
- generate or update Alloy config for a profile;
- check Omegga `/metrics`;
- start or inspect Alloy;
- prepare, import, or update the standard BMF dashboard;
- store and open the dashboard URL.

Long-range charts, frame-time analysis, and PromQL exploration stay in Grafana.

## Release Goal

The normal user release path is an MSI installer.

Each release should publish:

- `BMF-Desktop-<version>-x64.msi`;
- SHA256 checksum;
- release manifest;
- release catalog for desktop and CLI update checks;
- release notes;
- supported Brickadia build;
- supported UE4SS bundle;
- BMF-compatible Omegga runtime version or commit;
- native helper versions and hashes;
- standard dashboard version.

The MSI installs BMF Desktop and its bundled orchestration tooling. The app
then installs or updates the managed server stack through explicit user
actions.

## Related Roadmap Documents

This goal is the umbrella document for the roadmap set. Use these pages for
the detailed breakdown:

- [Roadmap overview](index.md): entry point for the roadmap section.
- [Monorepo consolidation](monorepo-consolidation.md): target repository
  layout, ownership rules, and migration boundaries.
- [Phase plan](phase-plan.md): staged execution plan from current repos to
  released desktop installer.
- [BMF Desktop control panel](bmf-desktop-control-panel.md): Electron,
  Angular, Angular Material 3, and operator UI requirements.
- [Service health model](service-health-model.md): shared CLI and desktop
  health checks, status levels, logs, and troubleshooting output.
- [Grafana onboarding](grafana-onboarding.md): Alloy, Grafana Cloud, dashboard
  import, and telemetry setup boundaries.
- [Event traffic inspector](event-traffic-inspector.md): live socket, JSONL,
  command, response, and payload inspection requirements.
- [Release artifacts](release-artifacts.md): MSI, checksums, release manifest,
  signing, and update flow.

## Phase Alignment

| Phase | Contribution to goal |
| --- | --- |
| Stabilize inputs | Protect current BMF/Omegga/CityRPG work and finish the Omegga sync. |
| Monorepo skeleton | Put all BMF-owned runtime, Omegga, native, adapter, and observability source under one repo. |
| Orchestration core | Create one API for CLI, desktop, installer, doctor, repair, launch, telemetry, and update work. |
| Service health | Define the shared health model and failure output for CLI and desktop. |
| Grafana onboarding | Make telemetry setup repeatable while keeping Grafana as the dashboard. |
| Generic bridge plugin | Make BMF socket/file command and event traffic reusable outside CityRPG. |
| BMF Desktop | Deliver the Angular Material 3 operations console. |
| Release pipeline | Publish MSI artifacts, manifests, checksums, and update-safe component packages. |

## Success Criteria

This program is successful when a clean Windows machine can:

- install BMF Desktop from an MSI;
- deploy a supported Brickadia/Omegga/BMF server profile;
- start the server from the app;
- see actionable health for every required component;
- configure Grafana Alloy and import the standard dashboard;
- open Grafana for real telemetry;
- inspect live BMF/Omegga event and command payloads;
- update or repair the stack through safe, logged operations;
- produce a redacted troubleshooting snapshot.

The same scenario must pass with no LLM intervention: after MSI install, the
operator should stay inside BMF Desktop except for normal OS file pickers,
Windows install prompts, Grafana Cloud credential entry, and opening Grafana for
the actual telemetry dashboard.

## Non-Goals

The first complete version does not need to:

- eliminate Omegga from the runtime stack;
- merge CityRPG into BMF;
- support every upstream Omegga deployment mode;
- embed Grafana charts inside BMF Desktop;
- launch the UE4SS/BMF-managed server through containerized Linux runtimes;
- support remote Linux servers;
- provide a general-purpose shell;
- promote experimental native gameplay paths without frame-time evidence.
