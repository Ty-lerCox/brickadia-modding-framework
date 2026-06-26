# BMF Orchestrator Core

`@bmf/orchestrator-core` is the shared operations library for future BMF
Desktop and `bmfctl` work.

The first version is intentionally dependency-free CommonJS. It provides:

- unified runtime manifest loading and validation;
- server profile defaults and normalization;
- local profile registry persistence with selected-profile tracking and
  redacted profile storage;
- service health model helpers;
- local profile observation collection from existing runtime files, socket
  metadata, bridge status, log sources, and optional bounded loopback probes;
- read-only service diagnostics for configured ports, start readiness, and
  owner PID/process details when available;
- service launch-control plans for stack and Alloy start/stop/restart, with
  dry-run defaults, explicit start/stop/restart confirmation,
  configured-command-only launch, verified owned-PID shutdown, append-only
  logs, and service action journals;
- Grafana/Alloy onboarding plans that render profile-specific Alloy config
  with environment-variable secret references;
- Grafana dashboard import plans and payload writers that use the checked-in
  dashboard JSON, API-token environment refs, redacted commands, and no
  automatic Grafana API calls;
- confirmed Grafana dashboard uploads that require `confirm: import`, read API
  tokens from environment refs, and redact response/error data;
- bounded redacted traffic snapshots from a single live BMFSocket loopback
  subscriber plus socket and bridge status diagnostics;
- confirmed redacted traffic trace exports for support bundles, with optional
  player anonymization and private-IP redaction;
- bounded redacted log snapshots from existing runtime logs, JSONL files,
  status files, Omegga log candidates, and transaction journals;
- shared troubleshooting snapshots that combine profile, health, log,
  traffic, manifest, doctor, and redacted copied-file evidence behind
  explicit `confirm: snapshot`;
- dry-run/default filesystem transactions with target-scope validation,
  backups, journals, rollback previews, and journal-driven rollback execution
  for supported install, repair, update, and telemetry configuration steps,
  with update transactions verifying the release catalog, release manifest,
  MSI checksums, and a component snapshot before staging updated files,
  including the generated `Start-BrickadiaOmegga.ps1` bootstrap script for
  the staged Omegga runtime;
- dry-run operation plans for install, repair, update, launch, telemetry, and
  event inspection flows;
- inspect-only prerequisite audits for BMF assets, Brickadia paths, Omegga
  install targets, Node/npm, PowerShell, and optional Grafana Alloy;
- release artifact expectation helpers plus desktop release catalog validation
  and latest-release selection;
- read-only desktop update checks that validate `release-catalog.json`, compare
  versions, and verify a local MSI SHA256 when the artifact is present;
- download-only desktop update plans and confirmed MSI downloads that verify
  SHA256 without launching installers or stopping services;
- verified desktop update installer handoff plans that require explicit
  `confirm: install` before launching Windows Installer.

The package must stay safe to call from local desktop/CLI code. It should read
existing files, manifests, and status inputs. It must not probe the game server
or generate UI-driven server traffic.

Profile registry writes are local JSON writes under `artifacts/local` by
default. They use normalized profile ids, atomic file replacement, and avoid
storing raw secret-looking dashboard URL values.

Port diagnostics are local OS/process inspection only. They are bounded, do not
send BMF commands, and are used to explain start blockers such as port conflicts
before launch.

Service actions are dry-run by default. `start-stack` requires `confirm: start`
and a configured Omegga start script or explicit launch command. Install
transactions generate `Start-BrickadiaOmegga.ps1` inside the selected Omegga
runtime path, and profile normalization infers that path when no explicit
script is configured. The script installs Omegga dependencies only when
`node_modules` is missing or `-ForceInstallDependencies` is passed, builds only
when `dist/main.js` is missing or `-ForceBuild` is passed, then runs
`npm start`. Service actions write local logs, PID metadata, and a journal
under `artifacts/local/services`.
`stop-stack` requires `confirm: stop` and can terminate only a process verified
from BMF-owned PID metadata. `restart-stack` requires `confirm: restart`,
performs the same owned-process stop or stale PID cleanup, then writes fresh
launch metadata. These actions do not send BMF commands or probe the game
server.
The service action root is caller-configured: source checkouts default to
`artifacts/local/services`, while installed Desktop uses its writable user-data
service directory. Logs, journals, PID files, and Alloy storage must remain
inside that configured service root.
Profiles normalize to the supported `local-process` launcher. Containerized
and Linux launchers are intentionally out of scope because UE4SS/BMF-managed
Brickadia servers must run on Windows. Future launch modes should preserve the
same explicit confirmation, scoped logging, and owned-process evidence model.
`start-alloy` requires `confirm: start`, a configured Grafana Alloy executable,
and a rendered Alloy config. It launches `alloy run <config>` with BMF-scoped
storage and the profile readiness port, writing separate `*-alloy` log, PID,
and journal evidence. `stop-alloy` and `restart-alloy` use the same explicit
confirmation and BMF-owned PID verification model as stack actions.

Telemetry plans render local config and dashboard import payloads only. The
dashboard upload helper can call Grafana only when the caller passes explicit
`confirm: import`; it does not push metrics or expose Grafana token values.

Traffic snapshots subscribe to the local BMFSocket broker in read-only mode and
retain a bounded in-memory ring. They do not send BMF commands, tail JSONL as a
live event source, or create server-side probes.

Traffic trace exports reuse the same snapshot path and require
`confirm: export` before writing a JSON support artifact. Desktop calls this
with player anonymization and private-IP redaction enabled by default.

Log snapshots read bounded file tails and recent transaction journals only.
They do not start services, send BMF commands, subscribe to sockets, or create
new server-side probes.

Troubleshooting snapshots reuse the traffic and log collectors, copy only a
bounded set of known diagnostic files, redact secret-looking values, and write
only after explicit `confirm: snapshot`. They still produce fallback health
evidence when the unified runtime manifest is missing so broken or partial
installs can be diagnosed.

Transactions apply local file staging and config writes only after explicit
confirmation. `update-stack` first reads `release-catalog.json` and
`release-manifest.json`, verifies the catalog's manifest and MSI SHA256
records, and writes `component-update-snapshot.json` in the selected BMF
runtime directory before replacing staged components. Transactions do not start
processes, call Grafana APIs, or send BMF commands.

`repair-stack` collects a preflight health snapshot, writes a
`repair.mutable-files.snapshot` artifact for the mutable UE4SS/Omegga files,
repairs the generated Omegga start script, restores missing BMF/BMFSocket/
BMFFrameTelemetry and generic Omegga plugin files, rewrites `enabled.txt`,
`mods.txt`, and `mods.json` so BMF is enabled, then captures post-repair health
evidence in the transaction journal.

Desktop update checks are read-only. Desktop update downloads require
`confirm: download`, write only to the local update cache, and verify SHA256.
Desktop update installer handoffs require `confirm: install` and launch only a
verified MSI through Windows Installer. They do not stop managed services or
update managed server components.

Rollback execution reads a transaction journal, validates targets against the
recorded transaction scope, restores only from the recorded backup root, runs in
reverse applied-step order, and writes a separate rollback journal. Applying a
rollback also preserves the current target state before overwriting or removing
it.

## Current Scope

This is a scaffold package. It can start the explicitly configured local
Windows Omegga launch path and start the explicitly configured Grafana Alloy
foreground collector. It does not stop arbitrary processes, manage container
lifetimes, or manage remote host service lifetimes yet. Those operations should
move behind this package in later phases so the desktop app and CLI share the
same behavior.
