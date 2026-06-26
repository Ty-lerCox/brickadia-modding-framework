# bmfctl

`bmfctl` is the CLI manager and troubleshooting tool for BMF environments.

It is intentionally CLI-first and dependency-free. The first release focuses on
diagnosing existing installs, collecting troubleshooting snapshots, and safely
repairing common UE4SS mod enablement problems.

## Commands

```powershell
node .\cli\bin\bmfctl.js doctor
node .\cli\bin\bmfctl.js doctor --json
node .\cli\bin\bmfctl.js doctor --fix --dry-run
node .\cli\bin\bmfctl.js health
node .\cli\bin\bmfctl.js health --json --network-checks
node .\cli\bin\bmfctl.js health --port-diagnostics
node .\cli\bin\bmfctl.js profiles save --profile local --profile-name "Local Server"
node .\cli\bin\bmfctl.js profiles list
node .\cli\bin\bmfctl.js profiles select local
node .\cli\bin\bmfctl.js plan bootstrap --telemetry
node .\cli\bin\bmfctl.js prerequisites
node .\cli\bin\bmfctl.js plan install-stack --json
node .\cli\bin\bmfctl.js transaction install-stack --json
node .\cli\bin\bmfctl.js transaction install-stack --apply --confirm apply
node .\cli\bin\bmfctl.js transaction repair-stack --json
node .\cli\bin\bmfctl.js transaction repair-stack --apply --confirm apply
node .\cli\bin\bmfctl.js transaction update-stack --release-catalog .\artifacts\local\bmf-desktop-release\release-catalog.json --release-manifest .\artifacts\local\bmf-desktop-release\release-manifest.json --json
node .\cli\bin\bmfctl.js rollback .\artifacts\local\transactions\<journal>.json --json
node .\cli\bin\bmfctl.js rollback .\artifacts\local\transactions\<journal>.json --apply --confirm rollback
node .\cli\bin\bmfctl.js services start-stack --start-script C:\path\to\Start-BrickadiaOmegga.ps1
node .\cli\bin\bmfctl.js services start-stack --start-script C:\path\to\Start-BrickadiaOmegga.ps1 --apply --confirm start
node .\cli\bin\bmfctl.js update check --release-catalog .\artifacts\local\bmf-desktop-release\release-catalog.json
node .\cli\bin\bmfctl.js update plan --release-catalog .\artifacts\local\bmf-desktop-release\release-catalog.json
node .\cli\bin\bmfctl.js update download --release-catalog .\artifacts\local\bmf-desktop-release\release-catalog.json --confirm download
node .\cli\bin\bmfctl.js update install --release-catalog .\artifacts\local\bmf-desktop-release\release-catalog.json
node .\cli\bin\bmfctl.js update install --release-catalog .\artifacts\local\bmf-desktop-release\release-catalog.json --apply --confirm install
node .\cli\bin\bmfctl.js telemetry plan --json
node .\cli\bin\bmfctl.js telemetry alloy --out .\artifacts\local\bmf.alloy --dry-run
node .\cli\bin\bmfctl.js telemetry dashboard --grafana-base-url https://grafana.example --out .\artifacts\local\dashboard-import.json --dry-run
node .\cli\bin\bmfctl.js telemetry dashboard --grafana-base-url https://grafana.example --apply --confirm import
node .\cli\bin\bmfctl.js traffic --json
node .\cli\bin\bmfctl.js logs --json
node .\cli\bin\bmfctl.js repair bmf.enable
node .\cli\bin\bmfctl.js snapshot
node .\cli\bin\bmfctl.js mods list
node .\cli\bin\bmfctl.js mods enable BMF
```

Common path overrides:

```powershell
node .\cli\bin\bmfctl.js doctor `
  --omegga C:\path\to\omegga `
  --game-win64 C:\path\to\Brickadia\Binaries\Win64 `
  --compat-root C:\path\to\brickadia-ue4ss-re
```

## Doctor

`doctor` checks the layers that usually break BMF installs:

- BMF repo/package files.
- BMF-compatible Omegga runtime and Windows UE4SS template.
- Brickadia UE4SS compatibility bundle manifests.
- Live `dwmapi.dll`/UE4SS `Mods` directories.
- `BMF` and `OmeggaBridge` folders plus `mods.txt`/`mods.json` enablement.
- UE4SS log failure signals.
- Omegga bridge runtime status files.

Findings include severity, evidence, next action, and repair command when a safe
repair is available.

## Health

`health` renders the shared `@bmf/orchestrator-core` service health report used
by BMF Desktop. By default it reads existing local files only: Brickadia/Omegga
paths, `runtime/status.json`, `socket.json`, `frame-telemetry.json`,
`bmf-bridge-status.json`, and log source paths.

Use `--port-diagnostics` to inspect configured local ports before launch and
report owning PID/process details when Windows exposes them. Use
`--network-checks` to add bounded loopback checks for Omegga `/metrics`,
Grafana Alloy readiness, and port diagnostics. The command does not send BMF
commands or create server-side probes.

## Profiles

`profiles` manages the local server profile registry used by BMF Desktop and
`bmfctl`. The default registry path is
`artifacts/local/profiles/profiles.json`; pass `--profile-store <file>` to
override it. Stored profiles include selected paths, ports, local Windows
launcher settings, and telemetry flags. Secret-looking dashboard URL query
values are redacted before storage.

Use `--profile <id>` with health, plan, transaction, traffic, and logs commands
to resolve a stored profile. Explicit path and port flags still override stored
values for that command.

Pass `--start-script <file>` when saving or using a profile to configure the
Omegga PowerShell launch script used by the shared service action contract.

## Plans

`plan` renders the shared `@bmf/orchestrator-core` dry-run operation contract
that BMF Desktop will use. It does not install, launch, probe, or mutate the
server.

Available plan IDs:

- `bootstrap`
- `install-stack`
- `repair-stack`
- `update-stack`
- `start-stack`
- `stop-stack`
- `restart-stack`
- `snapshot-stack`
- `configure-telemetry`
- `inspect-event-traffic`

## Transactions

`transaction <operation>` materializes supported operation plans into concrete
filesystem steps with target-scope validation, backup requirements, journal
paths, and rollback instructions. It is dry-run by default.

Use `--apply --confirm apply` to run the supported file staging/config writes.
The first transaction runner covers local BMF runtime, BMFSocket,
BMFFrameTelemetry, generic Omegga plugin/adapters, managed profile metadata,
and Alloy config files. It does not start processes, call Grafana APIs, or send
BMF commands.

`transaction update-stack` also reads the BMF Desktop release catalog and
release manifest before component staging. It verifies the catalog's release
manifest and MSI SHA256 records, then writes
`component-update-snapshot.json` so rollback and troubleshooting evidence has
the pre-update component state. Pass `--release-catalog <file>` and
`--release-manifest <file>` to override the default
`artifacts/local/bmf-desktop-release` paths.

`transaction repair-stack` collects pre/post health snapshots, writes a
mutable-file snapshot before repair, repairs the generated Omegga start script,
restores missing BMF/BMFSocket/BMFFrameTelemetry and generic Omegga plugin
files, and rewrites `enabled.txt`, `mods.txt`, and `mods.json` so BMF is
enabled. The post-repair health snapshot is stored in the transaction journal.

`rollback <journal.json>` reads an applied transaction journal and previews the
reverse-order restore/removal steps. Use `--apply --confirm rollback` to restore
recorded backups and remove paths that were created by the original
transaction. Rollbacks write their own journal and preserve the current target
state before overwriting or removing it.

## Services

`services <start-stack|stop-stack|restart-stack|start-alloy|stop-alloy|restart-alloy>`
renders the shared Desktop service launch-control contract. It shows the
selected backend, command, CWD, log path, journal path, PID metadata path,
readiness summary, blockers, and warnings.

Service actions are dry-run by default. `start-stack` can launch only the
configured Omegga start script or explicit command, and it requires
`--apply --confirm start`. It writes append-only launch logs, PID metadata, and
a service journal under the configured service root. Source checkouts default
to `artifacts/local/services`; installed BMF Desktop uses its writable
user-data service directory. `stop-stack` requires
`--apply --confirm stop` and only stops a process proven from the BMF-owned PID
metadata. `restart-stack` requires `--apply --confirm restart`, stops the
verified owned process or cleans up stale owned PID metadata, then writes fresh
launch metadata.

Containerized and Linux launchers are not supported for the UE4SS/BMF-managed
local server path. Unsupported backend input is normalized to the local Windows
process launcher so CLI and Desktop behavior stay aligned.

`start-alloy` uses `--alloy-executable <file>` or
`paths.grafanaAlloyExecutable` plus `--alloy-config <file>` or
`paths.grafanaAlloyConfig`. It launches `alloy run <config>` with BMF-scoped
storage and the profile Alloy readiness port, writing separate `*-alloy`
PID/log/journal evidence. `stop-alloy` and `restart-alloy` use the same explicit
confirmation and BMF-owned PID verification model as stack actions.

## Updates

`update check` reads a BMF Desktop `release-catalog.json`, validates its latest
MSI metadata, compares it with the current desktop version, and verifies the
local MSI SHA256 when the artifact is present beside the catalog.

`update plan` converts that check into a download-only plan. `update download`
requires `--confirm download`, downloads the MSI to the local update cache, and
verifies its SHA256. `update install` previews the Windows Installer handoff
for the verified MSI; `--apply --confirm install` launches that installer
handoff. These commands do not stop managed services or update managed server
components. Those remain separate explicit actions behind the shared update
guardrails.

## Telemetry

`telemetry plan` renders the shared Grafana/Alloy onboarding contract. It
returns profile labels, the Omegga metrics target, Alloy readiness URL,
dashboard import payload metadata, and required environment-variable secret
refs.

`telemetry alloy --out <file>` writes the generated Alloy config. The config
uses `sys.env(...)` for Grafana remote-write values, so raw tokens are not
written into the file. Add `--dry-run` to preview the write result without
creating the file.

`telemetry dashboard` prepares the standard Grafana dashboard import request.
Without `--out` it returns the redacted import contract, endpoint, token env
ref, and payload checksum. With `--out <file>` it writes the dashboard import
payload unless `--dry-run` is set. The command does not call Grafana APIs or
print token values; it references `BMF_GRAFANA_API_TOKEN` by default.

Use `telemetry dashboard --apply --confirm import` to submit the dashboard to
Grafana. Upload reads the token from `BMF_GRAFANA_API_TOKEN` or the env var
named by `--grafana-api-token-env`; the token is not stored or printed.

## Traffic

`traffic` renders the shared event-inspector snapshot used by BMF Desktop. It
subscribes to the authenticated BMF socket stream described by
`runtime/socket.json` and includes `runtime/bmf-bridge-status.json` as
diagnostic source metadata. Payloads are redacted before CLI output, and the
command does not send BMF commands or create server-side probes.

## Logs

`logs` renders the shared log snapshot used by BMF Desktop. It reads bounded
tails from existing BMF runtime logs, JSONL event/audit files, status files,
configured Omegga log candidates, and recent transaction journals. Log lines are
redacted before CLI output. The command does not start services, send BMF
commands, or subscribe to live sockets.

## Repairs

Repairs support `--dry-run` and create backups before changing files.

Available repair IDs:

- `bmf.enable`
- `bmf.copy`
- `bridge.enable`
- `bridge.copy`
- `all`

Repair logs and backups are written under `artifacts/bmfctl/`.

## Snapshots

`snapshot` uses the shared `@bmf/orchestrator-core` troubleshooting snapshot
contract and writes a redacted support folder containing:

- `doctor.json`
- `snapshot.json`
- `health.json`, `logs.json`, and `traffic.json`
- selected BMF/Omegga/UE4SS config and manifest files
- tailed logs, not full logs

The default output path is `artifacts/bmfctl/snapshots/<timestamp>/`. Copied
files are bounded and redacted before export, and the command does not send
BMF commands or create game-server probes.
