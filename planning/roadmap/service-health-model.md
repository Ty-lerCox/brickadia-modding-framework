# Service Health Model

The service health model defines when a BMF-managed server is considered
healthy and what the operator can do when it is not.

## Health Goal

BMF Desktop and `bmfctl doctor` should use the same structured checks. The CLI
prints them. The desktop app renders them with health badges, actions, and
logs.

The product bar is that Desktop can move a supported local profile from
unknown/unhealthy to healthy through guided checks and repair actions. When a
maintainer fixes a real local install by running commands during development,
that command sequence should become either a guarded health/repair/service
action or an explicit unsupported edge case.

## Services

| Service or component | Healthy when |
| --- | --- |
| Brickadia dedicated server files | Expected binary exists and version/build matches the selected profile. |
| Omegga runtime | Supported BMF-compatible Omegga package is installed and can start. |
| Brickadia server process | Process is running under the selected profile and expected port is bound. |
| UE4SS | `dwmapi.dll`, `ue4ss`, compatibility bundle, and mod enablement files are staged. |
| OmeggaBridge | Bridge mod is present, enabled, and reports ready/capabilities. |
| BMF Lua runtime | `Mods/BMF` exists, is enabled, and writes fresh `runtime/status.json`. |
| BMFSocket | Optional native socket mod is present, enabled, and connected when socket transport is required. |
| BMFFrameTelemetry | Optional native telemetry mod writes fresh `runtime/frame-telemetry.json` when enabled. |
| Omegga adapters | Generic BMF bridge/player/minigame adapters are installed and enabled as configured. |
| Metrics endpoint | Omegga `/metrics` responds locally and reports fresh BMF status. |
| Grafana Alloy | Alloy is running, ready, scraping the selected Omegga target, and remote-writing successfully. |
| Grafana dashboard | Standard dashboard exists for the selected Grafana stack and server labels. |

## Health Levels

| Level | Meaning |
| --- | --- |
| Healthy | Required files/processes/ports/runtime files are present and fresh. |
| Degraded | Core server can run, but optional paths such as socket or frame telemetry are unavailable. |
| Unhealthy | A required component is missing, failed, stale, or blocked. |
| Unknown | The app cannot inspect the component yet, usually because paths or credentials are missing. |

## Troubleshooting Output

Each failed check should include:

- component id;
- severity;
- human summary;
- relevant path, port, PID, URL, or log file;
- latest error text;
- suggested repair or next action;
- whether the repair is safe to run automatically;
- command/action id for CLI and desktop.

Current seed: `packages/orchestrator-core/src/observations.js` collects the
first shared local observation report for BMF Desktop and `bmfctl`. It reads
configured Brickadia/Omegga paths, `runtime/status.json`, `socket.json`,
`frame-telemetry.json`, `bmf-bridge-status.json`, and local log source paths.
Omegga `/metrics` and Alloy readiness are represented as bounded loopback
probes so the health view can stay observe-only by default.
`packages/orchestrator-core/src/services.js` adds read-only service diagnostics
for configured ports, start-readiness blockers, and owner PID/process details
when Windows exposes them.

## Port Conflicts

Port checks should identify:

- expected port;
- whether it is already listening;
- owning PID and process name when Windows exposes it;
- whether the listener belongs to the selected profile;
- suggested action: reuse, change port, stop process, or inspect logs.

Current implementation:

- `bmfctl health --port-diagnostics` inspects configured ports without sending
  BMF commands;
- `bmfctl health --network-checks` includes port diagnostics with loopback
  readiness probes;
- BMF Desktop requests port diagnostics and bounded Omegga `/metrics`/Alloy
  HTTP probes for startup health and the Services tab, so a healthy selected
  profile does not remain `unknown` in the UI.
- `bmfctl logs` and the BMF Desktop Logs tab use the shared bounded log
  snapshot from `packages/orchestrator-core/src/logs.js`.
- `bmfctl services start-stack` and the BMF Desktop Services tab use the shared
  launch-control contract from
  `packages/orchestrator-core/src/service-actions.js`.
- BMF Desktop can apply the same confirmed `start-stack`, `stop-stack`,
  `restart-stack`, `start-alloy`, `stop-alloy`, and `restart-alloy` actions and
  renders PID, log, journal, and error evidence from the service action result.

## Launch Control

Launch control is intentionally separate from health checks. Health can explain
whether the stack appears ready, while service actions explain what would run,
where stdout/stderr are logged, where the action journal is written, and why an
action is blocked.

Current implementation:

- service actions are dry-run by default;
- install transactions write `Start-BrickadiaOmegga.ps1` into the selected
  Omegga runtime path;
- profile normalization infers that generated script from
  `paths.omeggaRuntime` when no explicit start script is configured;
- `start-stack` requires that generated/configured Omegga start script or an
  explicit command;
- applying `start-stack` requires explicit `--confirm start` or the equivalent
  BMF Desktop confirmation path;
- the generated start script installs Omegga dependencies only when
  `node_modules` is missing or forced, builds only when `dist/main.js` is
  missing or forced, and then runs `npm start`;
- launch logs append under `artifacts/local/services`;
- every attempted start writes PID metadata and a service action journal;
- `stop-stack` requires explicit `--confirm stop`, reads only BMF-owned PID
  metadata, verifies the process before shutdown, and cleans stale owned PID
  metadata without killing unrelated processes;
- `restart-stack` requires explicit `--confirm restart`, runs the same
  owned-process stop/cleanup path, then starts the configured launch command
  and writes fresh PID metadata;
- launcher profiles normalize to the supported local Windows process path;
- containerized and Linux launchers are out of scope for the local UE4SS/BMF
  server path;
- `start-alloy` requires a configured/existing Grafana Alloy executable and a
  rendered Alloy config, runs `alloy run <config>` with BMF-scoped storage and
  the profile readiness port, and writes separate `*-alloy` PID/log/journal
  evidence;
- `stop-alloy` and `restart-alloy` use the same BMF-owned PID verification and
  explicit confirmation model as stack stop/restart, but only for
  `grafana-alloy` PID metadata;
- no BMF commands, UI-driven game-server probes, or hidden traffic generators
  are used for service launch control.

Desktop startup must also reconcile its own control-plane state before showing
health:

- use `%APPDATA%\BMF Desktop` as the canonical mutable store;
- migrate known legacy profile stores only when the canonical profile file is
  absent;
- load the selected profile before service, health, traffic, telemetry, log,
  or snapshot calls;
- preserve the stored profile id so service logs, PID files, dashboards, and
  traffic snapshots are profile-scoped consistently with `bmfctl`.

Common ports and targets:

| Port or target | Purpose |
| --- | --- |
| Brickadia game port | Server join traffic. |
| Omegga web port | Web UI and `/metrics`. |
| BMF socket broker port | Loopback event/command traffic. |
| Alloy ready port | Local Alloy health endpoint. |

## Logs

The app should render recent logs in a read-only log panel. Logs should be
grouped by component and action:

- install;
- doctor;
- repair;
- Omegga launch;
- Brickadia stdout/stderr or log tail;
- UE4SS log;
- BMF runtime log/audit excerpts;
- Alloy stdout/stderr;
- dashboard import calls.

Log rendering should support copy, save snapshot, and filter by severity. It
should avoid showing secrets.

Current seed: the shared log snapshot reads existing BMF runtime logs,
`events.jsonl`, `audit.jsonl`, status files, configured Omegga log candidates,
and recent operation transaction journals. It caps bytes, sources, and retained
lines, and redacts secret-looking values before CLI or Desktop rendering.

## Guardrails

Health checks must not create expensive server work. They should prefer local
process state, existing runtime files, existing metrics, and log tails. If a
check needs to send a BMF command, it must be low frequency, bounded, and
visible in telemetry.
