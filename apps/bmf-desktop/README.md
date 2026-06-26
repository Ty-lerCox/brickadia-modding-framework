# BMF Desktop

BMF Desktop is the Electron and Angular operations console for the unified BMF
runtime program.

Current scope:

- Electron shell with context-isolated preload API.
- Angular standalone renderer using Angular Material 3 components.
- Easy mode as the default portable app surface, showing a compact service and
  health-state list backed by the shared health model and configured-port
  diagnostics.
- Easy mode first-run Brickadia Dedicated Server folder setup that detects
  `BrickadiaServer-Win64-Shipping.exe`, saves the local profile, and selects it.
- Easy mode action buttons for unhealthy or degraded rows, using the same
  guarded install, repair, start, restart, and telemetry contracts as Advanced
  mode.
- Advanced mode preserving the full existing operations console for profiles,
  components, services, telemetry, traffic, snapshots, logs, and updates.
- Material 3 theme tokens in `src/styles.scss`.
- MSI and portable Windows packaging metadata through `electron-builder`.
- MSI resource bundling for BMF manifests, `bmfctl`, orchestrator-core package
  boundary files, UE4SS mod assets, native helper package boundaries, Omegga
  adapter packages, UE4SS compatibility metadata, and Grafana/Alloy
  observability assets.
- Guarded bridge to `@bmf/orchestrator-core` dry-run plans and confirmed
  filesystem transactions.
- Components tab setup readiness for BMF assets, Brickadia server files,
  required Omegga install target, Node/npm, PowerShell, and Grafana Alloy when
  telemetry is enabled.
- Profile setup form with native path pickers for Brickadia/Omegga/BMF paths,
  the Omegga start script, telemetry labels, Alloy executable/config paths, and
  Grafana dashboard URL.
- Telemetry tab preview for the shared Grafana dashboard import contract,
  including endpoint, payload path, token env ref, checksum, and redacted
  PowerShell command.
- Telemetry tab Alloy config writes through Electron IPC and
  `@bmf/orchestrator-core`, using `confirm: write-alloy`, keeping remote-write
  secrets as environment-variable references, and defaulting to Electron
  user-data storage when the profile does not select a config path.
- Telemetry dashboard payload writes through Electron IPC and
  `@bmf/orchestrator-core`, defaulting to the app user-data directory so MSI
  installs do not require write access to the install folder.
- Explicit Grafana dashboard upload through Electron IPC with the shared
  `confirm: import` guardrail, env-token lookup, redacted upload results,
  active-profile dashboard URL adoption, and guarded external dashboard open.
- Read-only desktop update status through the shared release catalog contract,
  including latest version, MSI hash metadata, and local artifact verification.
- Download-only desktop update plan and MSI acquisition through Electron IPC,
  with explicit confirmation and SHA256 verification.
- Verified desktop update installer handoff through Electron IPC, requiring
  explicit confirmation before Windows Installer is launched.
- Components tab transaction preview and apply flow through Electron IPC,
  requiring the shared `confirm: apply` guardrail and rendering applied steps,
  errors, journals, backups, and rollback metadata.
- Components tab rollback preview and apply flow through Electron IPC, requiring
  the shared `confirm: rollback` guardrail and rendering restore/removal steps,
  rollback journals, backup roots, and rollback errors from transaction
  journals.
- Traffic tab bounded live auto-refresh over the shared observe-only traffic
  snapshot, with pause/resume, last-refresh state, filters, selected payload
  rendering, copy actions, and confirmed redacted trace export.
- Services tab launch-control preview and confirmed `start-stack`,
  `stop-stack`, `restart-stack`, `start-alloy`, `stop-alloy`, and
  `restart-alloy` execution through Electron IPC, requiring the shared
  `confirm: start`, `confirm: stop`, and `confirm: restart` guardrails and
  rendering PID, owned PID, stop result, service log, and action journal
  evidence.
- Profiles tab local Windows launcher setup for the Omegga start script and
  service evidence. BMF Desktop intentionally avoids container launchers because
  the supported UE4SS/BMF server stack must run on Windows.
- Snapshots tab preview and confirmed troubleshooting bundle writes through
  Electron IPC, using the shared `confirm: snapshot` guardrail and rendering
  redacted health, log, traffic, copied-file, and output-path evidence.

The scaffold can save profile registry data, preview launch/install contracts,
apply supported filesystem transactions for selected stack operations, roll
back applied transaction journals, and start, stop, or restart the configured
Omegga-managed Windows stack and Grafana Alloy collector through owned PID
metadata. It can also write bounded support snapshots through
`packages/orchestrator-core`. It does not run unrestricted shell commands or
containerized game-server launchers. Mutating operations must move through
`packages/orchestrator-core` and stay behind explicit user actions.

When running from an installed MSI, Desktop reads BMF-owned source assets from
the bundled `resources/bmf` tree. When running as a portable exe, Desktop uses
the same bundled resources and stores profile data next to the executable under
`BMF Desktop Data`. It writes local profile registries, transaction journals,
service logs, update downloads, generated Grafana import payloads, and
troubleshooting snapshots under Electron `userData` unless the operator
explicitly chooses another path.

The MSI bundle also includes `resources/bmf/bin/bmfctl.cmd`. The shim runs the
bundled CLI through the installed Electron executable with
`ELECTRON_RUN_AS_NODE=1`, sets `BMF_ROOT` to `resources/bmf`, and keeps default
CLI state under `%APPDATA%\BMF Desktop`.

## Build and release

BMF Desktop is pinned to Angular 22, Electron 42, and electron-builder 26. Use
Node `22.22.3+`, `24.15.0+`, or `26+`; older Node 24 builds are rejected by the
Angular CLI.

Install dependencies from the repo root. The root script delegates to the
Desktop package lockfile:

```powershell
npm run install:desktop
```

Build the Angular renderer only:

```powershell
npm run build:desktop
```

Build the MSI directly:

```powershell
npm --prefix apps/bmf-desktop run dist:msi
```

Build the portable Windows executable:

```powershell
npm --prefix apps/bmf-desktop run dist:portable
```

Build the MSI, portable exe, release manifest, release catalog, checksums, and
release notes in `artifacts/local/bmf-desktop-release`:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/build-bmf-desktop-release.ps1 -BuildMsi -BuildPortable -Force
```

From the desktop package, the same local release path is exposed as:

```powershell
npm --prefix apps/bmf-desktop run release:local
```

When the default `node` on `PATH` is not an Angular-supported version, pass a
specific executable or set `BMF_DESKTOP_NODE_EXE`:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/build-bmf-desktop-release.ps1 -BuildMsi -BuildPortable -NodeExe C:\Tools\node-v24.15.0-win-x64\node.exe -Force
```
