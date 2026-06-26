# BMF Desktop Control Panel

BMF Desktop is a local Windows operations app for installing, running, and
inspecting a BMF-backed Brickadia server.

It should use Electron for the desktop shell, Angular for the renderer, and
Angular Material 3 components with Material You-style design tokens. The
renderer should call a local orchestration API exposed by the Electron main
process. It should not run shell commands directly.

## Product Goal

A user should be able to open BMF Desktop and answer:

- what server profile is selected;
- what components are installed;
- whether Omegga, Brickadia, UE4SS, BMF, socket transport, frame telemetry, and
  Alloy are healthy;
- what failed when a service could not start;
- where to click to open Grafana for real telemetry;
- what BMF/Omegga event payloads are moving right now.

The app should answer those questions and offer the repair/start/setup actions
without requiring a repository checkout or manual shell diagnosis. Any manual
recovery used during development is product debt until it is represented as a
Desktop/`bmfctl` operation with logs, guardrails, and rollback or snapshot
evidence where appropriate.

## First-Run Flow

1. Choose or create a server profile.
2. Locate or install Brickadia dedicated server files.
3. Install the BMF-compatible Omegga runtime.
4. Stage UE4SS compatibility files.
5. Stage BMF Lua runtime, BMFSocket, and optional BMFFrameTelemetry.
6. Install generic Omegga bridge adapters.
7. Configure ports and saved-dir paths.
8. Configure Grafana Cloud and Alloy, or skip telemetry setup.
9. Run doctor checks.
10. Start Omegga and the managed Brickadia server.

Startup should also run a no-surprises reconciliation pass:

- pin and read the canonical `%APPDATA%\BMF Desktop` profile store;
- migrate known legacy Desktop profile stores only when the canonical store is
  absent;
- load the selected profile before any health, service, traffic, telemetry, or
  log calls;
- run bounded network readiness probes and configured-port diagnostics;
- show the exact next safe action when setup is incomplete or a service is not
  healthy.

## Main Views

| View | Purpose |
| --- | --- |
| Profiles | Select local server profile, Windows paths, ports, and launcher settings. |
| Components | Install/update/repair BMF, Omegga, UE4SS, native mods, adapters, and Alloy. |
| Services | Start, stop, restart, and inspect Brickadia/Omegga/Alloy state. |
| Health | Show doctor checks, unhealthy reasons, and repair actions. |
| Logs | Render recent structured logs and terminal output by service/action. |
| Telemetry Setup | Configure Grafana Cloud, Alloy, labels, dashboard import, and dashboard link. |
| Event Traffic | Inspect live BMF/Omegga socket and fallback event/command payloads. |
| Snapshots | Collect troubleshooting bundles for support and regression evidence. |

## Design System

BMF Desktop should use Angular Material 3 as the component system. Custom UI
should be built on top of Material primitives instead of one-off controls.

Required UI standards:

- Material 3 theme tokens for color, typography, density, elevation, and shape;
- Angular Material buttons, icons, form fields, lists, tabs, dialogs, snackbars,
  tooltips, menus, steppers, tables, progress indicators, and expansion panels;
- clear healthy, degraded, unhealthy, and unknown status color semantics;
- compact operations layouts for repeated server administration;
- accessible focus states, keyboard navigation, contrast, and screen-reader
  labels;
- no architecture diagrams in the app UI.

The design should feel like a local operations console. It should be clean,
scannable, and useful under failure, with logs and actions close to the health
state they explain.

Current seed: the Logs tab is backed by the shared
`packages/orchestrator-core/src/logs.js` snapshot. It renders bounded,
redacted runtime and operation-journal lines through Electron IPC instead of
opening an unrestricted terminal.

The Profiles tab now uses the shared profile registry to save, refresh, and
select local server profiles through Electron IPC. The profile draft includes
Brickadia/Omegga/BMF paths, the Omegga start script, configured ports, telemetry
labels, the Alloy config path, frame telemetry state, and the Grafana dashboard
URL. Path fields use narrow Electron open/save dialogs for known profile fields.
The renderer keeps using Material controls and never writes registry files
directly.
Packaged Desktop now pins Electron `userData` to `%APPDATA%\BMF Desktop`, the
same location used by the installed `bmfctl` shim, and migrates the accidental
legacy `%APPDATA%\@bmf\desktop` profile store into the canonical location when
needed.

The Services tab now uses the shared service action contract to preview and
execute start/stop/restart behavior through Electron IPC. It renders the launch
command, log path, journal path, PID metadata path, readiness status, and
blockers. Confirmed local-process actions use owned PID metadata for safe
stop/restart.
Desktop startup now requests the same bounded loopback health probes and
configured-port diagnostics that made the CLI report a fully healthy local
profile, so the status band should not remain `unknown` when the selected stack
is actually healthy.

The Components tab now previews and applies the shared filesystem transaction
contract through Electron IPC. The apply path requires the shared
`confirm: apply` guardrail, writes transaction journals, preserves backup and
rollback evidence from orchestrator-core, and renders applied steps and errors
without giving the renderer shell access. It also previews and applies rollback
from existing transaction journals with the shared `confirm: rollback`
guardrail, rendering restore/removal steps, rollback journals, backup roots,
and rollback errors.

The Telemetry tab now uses the shared dashboard import contract through
Electron IPC. It renders import status, Grafana endpoint, payload path, token
environment reference, checksum, and a redacted PowerShell command without
submitting the request or embedding Grafana dashboards. It can also write the
dashboard import payload through the same core contract, using Electron
user-data storage by default for MSI-installed desktop builds. Dashboard upload
is exposed as a separate explicit action that passes the shared
`confirm: import` guardrail and renders only redacted upload results.
Uploaded dashboard URLs are adopted into the active profile draft, rendered in
the Telemetry tab, and opened through Electron's guarded HTTP(S)-only external
link handoff.
The tab can also write the generated Grafana Alloy config through the shared
telemetry renderer with `confirm: write-alloy`, showing output path, bytes, and
SHA256 while keeping Grafana remote-write secrets as environment-variable
references.
The Services tab now uses the same service-action IPC contract for Grafana
Alloy start/stop/restart as it uses for the Omegga stack. The profile editor
captures the Alloy executable path, the action plan renders the exact
`alloy run` command, and applied actions write separate BMF-owned Alloy
PID/log/journal evidence.

The Snapshots tab now previews and writes the shared troubleshooting snapshot
contract through Electron IPC. Preview is dry-run. Writing requires the shared
`confirm: snapshot` guardrail and renders the output root, snapshot JSON,
health/log/traffic files, copied diagnostic files, and tailed logs. The
snapshot collector reuses the shared traffic and log snapshots, redacts copied
files, and still produces fallback health evidence when a partial install is
missing the unified runtime manifest.

The Traffic tab now behaves more like a local event devtool: it filters by
event, command, source, transport, status, and consumer/plugin; shows selected
payload JSON; copies selected payloads or the current redacted trace to the
clipboard; renders source/socket state; auto-refreshes the bounded shared
snapshot while live mode is enabled; pauses without accumulating overlapping
reads; and exports anonymized redacted support traces through the shared
Electron IPC contract with `confirm: export`.

## UI Boundaries

BMF Desktop should show local operational state. It should not become a full
Grafana or tracing product.

Allowed in BMF Desktop:

- health badges;
- service controls;
- install and repair actions;
- recent log rendering;
- event payload inspection;
- Grafana setup status;
- button/link to open the configured Grafana dashboard.

Not in BMF Desktop:

- embedded long-range metric dashboards;
- architecture diagrams;
- duplicated Grafana panels;
- raw secret display after setup;
- unrestricted shell terminal.

## Launcher Scope

The executable launcher is the current Omegga-managed Windows runtime. BMF
Desktop profiles capture the Omegga start script, Windows paths, ports, and
service evidence needed to start, stop, restart, and inspect the stack through
orchestrator-core.

Containerized and Linux launchers are out of scope for the supported local
server path because UE4SS/BMF-managed Brickadia servers require Windows. A
future remote-host launcher can share the same health model only if it preserves
explicit confirmation, scoped logs, owned-process evidence, and the existing
BMF/Omegga/BMF socket contracts.
