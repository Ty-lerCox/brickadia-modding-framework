# Phase Plan

This plan updates the consolidation roadmap around the BMF Desktop operations
model, Grafana onboarding, and event traffic inspection.

## Phase 0: Stabilize Current Inputs

Goal: protect current work before moving repositories.

Deliverables:

- finish the Omegga `1.7.0` sync in the separate sandbox;
- preserve local BMF, Omegga, and CityRPG dirty work as commits, patches, or
  explicit exclusions;
- identify which Omegga fork changes are BMF-owned versus upstream Omegga;
- record the supported Brickadia build, UE4SS bundle, and BMF package version.

Exit criteria:

- current Omegga fork builds and passes backend tests;
- BMF release validation still passes;
- no runtime logs, saves, or secrets are staged for migration.

## Phase 1: Create The Monorepo Skeleton

Goal: make BMF the canonical source tree without changing runtime behavior.

Deliverables:

- add workspace layout for apps, packages, compatibility bundles, and
  observability assets;
- import the synced BMF-compatible Omegga runtime under the BMF repo;
- move generic Omegga adapters under `packages/omegga-plugins`;
- keep BMF Lua runtime and native mods available at their current install paths
  or provide compatibility aliases.

Current seed: `packages/bmf-runtime`, `packages/bmf-native-socket`, and
`packages/bmf-frame-telemetry` now define package-boundary manifests for the
current `framework/ue4ss/Mods/*` and `native/*` source roots, validated by
`scripts/validate-bmf-runtime-packages.ps1`.
The root `package.json` now declares the maintainable first-party workspaces
for BMF Desktop, `bmfctl`, and `orchestrator-core`, while keeping the Desktop
and BMF-supported Omegga dependency installs on their existing lockfiles. The
root setup command is `npm run setup`, and `scripts/validate-workspace.ps1`
keeps that clean-checkout contract aligned with the roadmap.
`packages/omegga-runtime` now contains the synced BMF-compatible Omegga source
under `source/`, including sync metadata for the BMF-supported fork URL,
upstream repository, fork commit, copied roots, required helper surfaces, and
do-not-vendor rules, validated by
`scripts/validate-omegga-runtime-package.ps1`.
`compat/ue4ss` now defines the UE4SS compatibility boundary for the current
Brickadia `PC-Shipping-CL13530` target, validated by
`scripts/validate-ue4ss-compat-package.ps1`.

Exit criteria:

- workspace install succeeds from a clean checkout;
- `scripts/validate-workspace.ps1` validates root `package.json` scripts,
  workspace boundaries, and dependency-island lockfiles;
- existing validation scripts can locate BMF runtime files;
- Omegga packaging still includes BMF, OmeggaBridge, BMFSocket, and optional
  frame telemetry files.

## Phase 2: Extract Orchestration Core

Goal: put install, doctor, repair, launch, and telemetry setup behind one
shared API.

Current seed: `packages/orchestrator-core` contains the first dependency-free
manifest, profile, release-artifact, health-model, and dry-run
operation-planning helpers. It also contains a local profile registry for
Desktop and `bmfctl` selected-profile persistence, plus a local profile observation
collector that reads existing runtime files, socket/bridge status, log sources,
and optional bounded loopback health probes for Desktop and CLI health views.
The core now also includes a local service diagnostics model for configured
ports, start readiness, and owner details when the OS exposes them.
It now includes an inspect-only prerequisite audit for BMF assets, Brickadia
server files, Omegga install target, Node/npm, PowerShell, and optional
Grafana Alloy so Desktop and `bmfctl prerequisites` can show setup blockers
before install or start operations.
It also includes the shared event-traffic snapshot that reads bounded,
redacted runtime envelopes from existing event, audit, socket, bridge-status,
and command files for Desktop and `bmfctl traffic`.
It now includes the shared log snapshot that reads bounded, redacted BMF
runtime logs, JSONL files, status files, Omegga log candidates, and transaction
journals for Desktop and `bmfctl logs`.
It now includes the shared troubleshooting snapshot that combines profile,
health, log, traffic, manifest, doctor, copied diagnostics, and tailed logs for
Desktop and `bmfctl snapshot`, with `confirm: snapshot` required before writes.
The first filesystem transaction runner now materializes supported install,
repair, update, and telemetry operations into dry-run/default steps with
target-scope validation, backups before overwrite, journals, rollback previews,
and journal-driven rollback execution. Update transactions now verify the BMF
Desktop release catalog, release manifest, and MSI checksum evidence before
component staging, then write `component-update-snapshot.json` with the
pre-update component state. The transaction runner also stages the synced
BMF-compatible Omegga source into the selected writable Omegga runtime path
and writes `Start-BrickadiaOmegga.ps1`, a first-run dependency bootstrap and
start script, before adding bundled generic bridge and adapter plugins.
Repair transactions now use the same runner to capture pre/post health
snapshots, write a mutable-file repair snapshot, restore missing BMF runtime
and Omegga adapter files, repair the generated launch script, and rewrite
`enabled.txt`, `mods.txt`, and `mods.json` so BMF is enabled after repair.
`bmfctl transaction`, `bmfctl rollback`, and BMF Desktop's Components tab use
this same contract.
The first service action contract now previews start/stop/restart in Desktop
and `bmfctl services`, with confirmed `start-stack`, `stop-stack`, and
`restart-stack` execution enabled for configured local launch commands from
both surfaces. Profiles now infer the transaction-generated
`Start-BrickadiaOmegga.ps1` from the selected Omegga runtime path when no
explicit start script is configured. Stop and restart are restricted to
BMF-owned PID metadata and require explicit action-specific confirmation.
It is validated by
`scripts/validate-orchestrator-core.ps1`.

Deliverables:

- promote `bmfctl` logic into `packages/orchestrator-core`;
- model server profiles, installed components, service states, ports, log
  paths, runtime files, and telemetry settings;
- expose dry-run operations for install, repair, update, start, stop, restart,
  and snapshot;
- return structured diagnostic events for UI and CLI rendering.

Exit criteria:

- CLI and tests call orchestration core instead of duplicating file logic;
- failed operations include actionable messages, relevant paths, and logs;
- safe repairs still create backups before mutating installed files.
- any manual LLM/operator repair needed to make a local profile healthy is
  converted into an orchestrator-core action or explicit documented non-goal.

## Phase 3: Build Service Health And Launch Control

Goal: give operators a clear local health model for the full stack.

Current seed: shared Desktop/CLI health reports include start-readiness and
configured-port diagnostics. The port path is read-only, bounded, and can
identify Windows owning PID/process details when available. Shared log
snapshots now provide the terminal-style evidence stream for runtime files and
operation journals without sending BMF commands.

Deliverables:

- detect Brickadia server, Omegga, UE4SS, BMF, BMFSocket, BMFFrameTelemetry,
  Alloy, and port state;
- add start/stop/restart actions for the supported Omegga-managed path;
- keep launch control scoped to Windows-compatible Omegga paths, with any
  future remote Windows launcher preserving the same guardrails;
- surface terminal-style logs for launch failures, port conflicts, missing
  files, auth failures, and crash exits.

Exit criteria:

- a user can see why the stack is unhealthy without opening source files;
- port-in-use errors identify the port and owning process when available;
- doctor output and launch logs use the same structured status model.
- the user can move from unhealthy to healthy through Desktop-rendered actions
  for supported setup gaps, without knowing the equivalent CLI or PowerShell
  commands.

## Phase 4: Ship Grafana Onboarding

Goal: configure telemetry without turning BMF Desktop into the telemetry
dashboard.

Current seed: `observability` contains the first Alloy config template,
standard Grafana dashboard JSON, dashboard import contract, and asset manifest.
`packages/orchestrator-core/src/telemetry.js` now renders profile-specific
Alloy config, dashboard import payloads, label values, redacted import
commands, confirmed Grafana dashboard uploads, and redacted secret status for
BMF Desktop and `bmfctl`.
Desktop writes the generated Alloy config through Electron IPC with
`confirm: write-alloy`, using the selected profile path or an Electron
user-data default while keeping remote-write secrets as environment-variable
references.
It is validated by `scripts/validate-observability-assets.ps1`.

Deliverables:

- configure Grafana Cloud remote-write URL, username, and token;
- store secrets outside source control;
- generate or update the local Alloy config for the selected server profile;
- start/stop/check Alloy health;
- upload or import the standard BMF dashboard into Grafana;
- store and open the dashboard URL from BMF Desktop.

Exit criteria:

- BMF Desktop shows telemetry path healthy/unhealthy;
- Grafana dashboard has server-specific labels for the selected server;
- real time-series charts are viewed in Grafana, not duplicated in BMF Desktop.

## Phase 5: Build The Generic BMF Bridge Plugin

Goal: make socket/file BMF event and command traffic reusable across game modes.

Current seed: `packages/omegga-plugins/bmf-bridge` contains the first generic
Omegga bridge scaffold. It normalizes socket, JSONL, and file command/response
records into the event-inspector envelope, exposes subscribe/unsubscribe and
command invocation helpers, retains a bounded redacted buffer, and is validated
by `scripts/validate-bmf-bridge-plugin.ps1`.
The canonical bundled adapter packages now live in
`packages/omegga-plugins/bmf-player-sync` and
`packages/omegga-plugins/bmf-minigame-events`; they are staged by the shared
filesystem transaction runner and validated by
`scripts/validate-bmf-omegga-adapters.ps1`.

Deliverables:

- harden the generic Omegga plugin for BMF command/event traffic;
- discover socket settings from `runtime/socket.json`, inherited env vars, or
  configured command/event paths;
- prefer socket transport and fall back to file-backed command/event paths;
- expose subscribe/unsubscribe and command invocation helpers;
- keep CityRPG-specific event mapping out of the generic bridge.

Exit criteria:

- CityRPG can consume the generic bridge and keep only gameplay-specific
  mapping/policy;
- another Omegga plugin can subscribe to BMF events without copying CityRPG
  relay code;
- socket health, command counts, drops, retries, and fallback state are visible.

## Phase 6: Build BMF Desktop

Goal: ship the Windows operations control panel.

Current seed: `apps/bmf-desktop` contains the first Electron shell, Angular
standalone renderer, Angular Material 3 theme, preload API, and
electron-builder MSI metadata. The top-level desktop release builder can now
validate an Angular-supported Node executable, compile the renderer, invoke
electron-builder's MSI target, and emit the release manifest, catalog,
checksum, and release notes from the produced installer. The packaged app now
bundles BMF manifests, `bmfctl`, orchestrator-core package boundary files,
UE4SS mod assets, native helper package boundaries, generic Omegga adapters,
compatibility metadata, Grafana/Alloy assets, and the synced Omegga runtime
source plus sync metadata under `resources/bmf`, with local mutable state
defaulting to Electron `userData`. It also includes an
installed `resources/bmf/bin/bmfctl.cmd` shim that runs through Electron's Node
mode and shares the same bundled root plus app-data write defaults. It is
validated by
`scripts/validate-bmf-desktop.ps1`. The Traffic tab is now backed by the
shared observe-only orchestrator-core snapshot instead of static sample rows.
Packaged Desktop now pins Electron `userData` to `%APPDATA%\BMF Desktop`,
matching the installed CLI shim, and migrates the accidental legacy
`%APPDATA%\@bmf\desktop` profile store when the canonical store is absent.
The renderer now hydrates the selected profile on startup, preserves the stored
profile id in health/service/traffic calls, suppresses live traffic refresh
until startup finishes, and requests bounded network plus port diagnostics so
the UI can show the same healthy state as `bmfctl`.
The Services tab previews start/stop/restart launch contracts and can execute
confirmed `start-stack`, `stop-stack`, and `restart-stack` actions through
Electron IPC, rendering PID, owned PID, stop result, service log, journal, and
launch-error evidence from orchestrator-core.
The Components tab also previews the selected operation transaction, including
ready/blocked steps, backup count, rollback count, and unsupported action
count. It can apply supported filesystem transactions through Electron IPC with
the shared `confirm: apply` guardrail and then render applied steps, errors,
journal path, backups, and rollback evidence. It can also preview and apply
rollback from an existing transaction journal with the shared
`confirm: rollback` guardrail. The Components tab now starts with setup
readiness from the shared prerequisite audit. The Logs tab reads the same bounded, redacted log
snapshot exposed by `bmfctl logs`. The Profiles tab can save, refresh, and
select stored local
server profiles through Electron IPC, including Brickadia/Omegga/BMF paths,
ports, the local Windows launcher, the Omegga start script, telemetry labels,
Alloy config path, frame telemetry state, and Grafana dashboard URL. Path
fields now use constrained Electron open/save dialogs for known profile fields
instead of requiring manual typing. Containerized and Linux launchers are out
of scope for this local UE4SS/BMF stack. The Telemetry tab now previews the
shared Grafana dashboard import
contract, including endpoint, payload path, API-token environment ref, checksum,
and redacted command output.
The upload action is separate from payload generation and requires the shared
`confirm: import` guardrail.
The Telemetry tab can also write the generated Grafana Alloy config through
Electron IPC with `confirm: write-alloy`, rendering output path, bytes, and
SHA256 evidence without exposing remote-write secrets.
Confirmed dashboard uploads now feed the returned dashboard URL back into the
active profile draft, render the active URL in the Telemetry tab, and open it
through Electron's guarded HTTP(S)-only external handoff.
The Services tab now also previews and applies shared `start-alloy`,
`stop-alloy`, and `restart-alloy` actions. Profiles capture the Alloy
executable path, service plans render the exact `alloy run` command, and
applied actions write BMF-owned Alloy PID/log/journal evidence.
The Traffic tab now runs bounded live auto-refresh over the shared observe-only
traffic snapshot. The renderer exposes live/manual state, pause/resume,
last-refresh evidence, selected payload inspection, copy actions, and confirmed
redacted trace export without reading runtime files directly or creating server
traffic.

Deliverables:

- Electron main process hosts orchestration core;
- Angular renderer uses Angular Material 3 components and Material You-style
  design tokens for profile setup, component install state, service health,
  actions, logs, Grafana setup, and event traffic;
- renderer never shells out directly;
- UI avoids embedded architecture diagrams and avoids duplicating Grafana
  metric dashboards.

Exit criteria:

- a clean Windows user can follow the app from install to running server;
- unhealthy services show next actions and logs;
- a healthy server can open the configured Grafana dashboard;
- event traffic inspector displays live BMF/Omegga payloads.
- no LLM or repository-aware shell session is required for the supported local
  install/start/health path.

## Phase 7: Release, Validate, And Update

Goal: make the monorepo self-sustaining.

Current seed: `.github/workflows/unified-runtime.yml` defines the first unified
CI workflow for workspace validation, CLI/core tests, Desktop build and release
metadata validation, BMF-supported Omegga runtime tests, native helper
validation with optional UE4SS-source builds, release package validation, docs
builds, and manual/tagged MSI artifact creation. It is validated by
`scripts/validate-ci-workflows.ps1`.

Deliverables:

- CI for BMF Lua validation, native builds, Omegga tests, bridge plugin tests,
  CLI tests, docs, and packaging;
- MSI installers as the primary user-facing BMF Desktop release artifact;
- signed or hash-verified release artifacts, including MSI checksums and an
  update-safe release manifest and release catalog;
- component manifests that drive updates;
- rollback and repair coverage for failed updates;
- release notes that call out supported Brickadia and UE4SS builds.

Exit criteria:

- a Windows user can download an MSI, install BMF Desktop, and use it to deploy
  the rest of the stack;
- release automation can build the MSI and publish matching checksum, manifest,
  catalog, and release notes from one command;
- new releases can install or update the full supported stack;
- the app can identify stale components and apply safe updates;
- validation evidence records functional and frame-time status for risky paths.
