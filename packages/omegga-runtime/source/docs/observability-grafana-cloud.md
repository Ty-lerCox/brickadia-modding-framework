# Grafana Cloud Observability

This fork exposes low-cardinality Prometheus metrics for the local Brickadia
dedicated server, the Omegga wrapper, BMF runtime health, BMF command/event
traffic, and optional native frame time. Grafana Alloy scrapes Omegga locally
and remote-writes those samples to Grafana Cloud.

## Data Path

```text
Brickadia server
  -> UE4SS BMF runtime
  -> Mods/BMF/runtime/status.json
  -> Mods/BMF/runtime/telemetry.json
  -> Mods/BMF/runtime/frame-telemetry.json
  -> Omegga http://127.0.0.1:8080/metrics
  -> Grafana Alloy scrape
  -> Grafana Cloud Prometheus remote_write
  -> observability/grafana/brickadia-overview-dashboard.json
```

The frame-time path requires the optional native `BMFFrameTelemetry` UE4SS mod.
Without that DLL and a server restart, the dashboard's native frame panels stay
empty and `brickadia_frame_telemetry_up` is `0`.

## What Was Added

- Omegga now serves a Prometheus-compatible `/metrics` endpoint from the
  webserver backend.
- The endpoint reads BMF `status.json`, BMF `telemetry.json`, and native
  `frame-telemetry.json` when present.
- The exporter includes command-worker metrics so command volume, worker mode,
  poll interval, and files/messages processed are visible next to frame time.
- Native frame telemetry is exported as frame delta, FPS estimate, sample
  counts, slow-frame counters, and spike counters.
- `observability/grafana-cloud.alloy` defines the local scrape and Grafana Cloud
  remote-write pipeline.
- `observability/run-grafana-alloy.ps1` starts Alloy with a repo-local WAL under
  `observability/.alloy-data`.
- `observability/grafana/brickadia-overview-dashboard.json` contains the
  Brickadia/Omegga/BMF overview dashboard.

## Metrics Endpoint

Omegga exposes metrics at:

```text
http://127.0.0.1:<omegga-port>/metrics
```

The default local development target is:

```text
http://127.0.0.1:8080/metrics
```

The endpoint is enabled by default. Set `OMEGGA_METRICS_ENABLED=0` to disable
it.

Access is localhost-only unless `OMEGGA_METRICS_ALLOW_REMOTE=1` is set. If
`OMEGGA_METRICS_TOKEN` is set, callers must send:

```text
Authorization: Bearer <token>
```

The bundled Alloy config assumes localhost scraping without a bearer token. If
you enable `OMEGGA_METRICS_TOKEN`, add matching authorization to the Alloy scrape
config before starting Alloy.

## Exporter Coverage

Current exporter coverage:

- Brickadia server state: up, starting, stopping, player count, brick count,
  component count, uptime, and aggregate player ping.
- Omegga process state: uptime, memory, CPU seconds, and latest server-status
  poll duration.
- BMF runtime state when `Mods/BMF/runtime/status.json` is readable: runtime up,
  status file age, runtime info labels, loaded plugin count, plugin error count,
  plugin tick state, audit records, and watchdog-isolated plugins.
- BMF command-worker state: worker scheduler mode, async poll interval,
  game-thread fallback interval, and max files scheduled per poll.
- BMF telemetry when `Mods/BMF/runtime/telemetry.json` is readable: command
  counts and durations, file/socket transport timings, event emit and handler
  timings, plugin command/hook timings, scheduler callback timings, and worker
  throughput.
- Native frame telemetry when `Mods/BMF/runtime/frame-telemetry.json` is
  readable: Unreal engine tick delta, frame-rate estimate, sample counts,
  idle-sample counts, slow-frame threshold counters, spike counters, and latest
  spike age.

The exporter deliberately avoids player names, UUIDs, addresses, command args,
and other high-cardinality labels. Use BMF audit/log files for per-player
debugging; use Prometheus for aggregate performance and health trends.

## Important Metric Names

Health and freshness:

```text
bmf_runtime_status_up
bmf_runtime_status_age_seconds
bmf_telemetry_up
bmf_telemetry_age_seconds
brickadia_frame_telemetry_up
brickadia_frame_telemetry_age_seconds
brickadia_frame_telemetry_hook_registered
```

Command and worker attribution:

```text
bmf_command_processed_total{command,status}
bmf_command_duration_milliseconds{command,statistic}
bmf_command_transport_total{transport,status}
bmf_command_transport_duration_milliseconds{transport,statistic}
bmf_command_worker_info{mode}
bmf_command_worker_poll_interval_milliseconds
bmf_command_worker_fallback_poll_interval_milliseconds
bmf_command_worker_max_files_per_poll
bmf_worker_poll_total{worker,status}
bmf_worker_poll_duration_milliseconds{worker,statistic}
bmf_worker_items_total{worker,item}
```

Native frame time:

```text
brickadia_frame_delta_milliseconds{scope,statistic}
brickadia_frame_fps{scope,statistic}
brickadia_frame_samples_total
brickadia_frame_idle_samples_total
brickadia_frame_slow_total{threshold_ms}
brickadia_frame_spikes_total{threshold_ms}
brickadia_frame_spike_last_delta_milliseconds
brickadia_frame_spike_last_age_seconds
```

`brickadia_frame_delta_milliseconds{scope="window",statistic="max"}` is the
main "how bad was the worst recent frame" signal. Do not rely only on average
frame time; the local investigation showed command volume can improve while max
frame time still exposes player-visible hitches.

## Grafana Alloy Setup

Install Alloy on Windows:

```powershell
winget install GrafanaLabs.Alloy
```

Create or use a Grafana Cloud access policy/token with metrics remote-write
access. In Grafana Cloud this is under:

```text
Administration -> Users and access -> Cloud access policies
```

The Alloy policy created by Grafana Cloud for a stack commonly has a scope like
`set:alloy-data-write`. Use the token value as the remote-write password. Do not
commit that token.

Set the required environment variables in the PowerShell session that will run
Alloy:

```powershell
$env:GRAFANA_CLOUD_PROMETHEUS_RW_URL = "https://<stack-prometheus-url>/api/prom/push"
$env:GRAFANA_CLOUD_PROMETHEUS_USERNAME = "<prometheus-user-id>"
$env:GRAFANA_CLOUD_API_KEY = "<grafana-cloud-access-policy-token>"
```

Grafana Cloud shows the remote-write URL and username in the Prometheus data
source or stack details. The token comes from the Cloud access policy token you
created.

Optional local labels and paths:

```powershell
$env:OMEGGA_METRICS_TARGET = "127.0.0.1:8080"
$env:BRICKADIA_METRICS_ENVIRONMENT = "local"
$env:BRICKADIA_METRICS_INSTANCE = $env:COMPUTERNAME
$env:OMEGGA_BMF_STATUS_PATH = "C:\path\to\Mods\BMF\runtime\status.json"
$env:OMEGGA_BMF_TELEMETRY_PATH = "C:\path\to\Mods\BMF\runtime\telemetry.json"
$env:OMEGGA_BMF_FRAME_TELEMETRY_PATH = "C:\path\to\Mods\BMF\runtime\frame-telemetry.json"
```

The BMF path overrides are only needed when Omegga cannot infer the managed
UE4SS runtime paths.

Start Alloy in the foreground:

```powershell
cd .\omegga-master\omegga-master
.\observability\run-grafana-alloy.ps1
```

If `alloy.exe` is not on `PATH`, the runner checks the standard
`%ProgramFiles%\GrafanaLabs\Alloy` install locations. You can also pass the path
explicitly:

```powershell
.\observability\run-grafana-alloy.ps1 -AlloyPath "C:\Program Files\GrafanaLabs\Alloy\alloy.exe"
```

The Windows installer also creates an auto-started `Alloy` service. That
service uses `%ProgramFiles%\GrafanaLabs\Alloy\config.alloy` by default, not this
repo's `observability/grafana-cloud.alloy`. If that service already owns
`127.0.0.1:12345`, the repo runner automatically chooses the next free port and
prints the exact readiness URL to use for this foreground instance.

If the same repo config is already running, the runner prints the existing PID
and readiness URL instead of starting a duplicate remote-write pipeline.

The runner sets these defaults when they are absent:

```powershell
$env:OMEGGA_METRICS_TARGET = "127.0.0.1:8080"
$env:BRICKADIA_METRICS_ENVIRONMENT = "local"
$env:BRICKADIA_METRICS_INSTANCE = $env:COMPUTERNAME
```

The Alloy config is tuned for a single local server: it scrapes every 15
seconds, disables metadata sends, and caps remote-write at one shard. This keeps
the collector quiet enough for a local development server while preserving the
signals needed to spot regressions.

Quick local checks:

```powershell
Invoke-WebRequest http://127.0.0.1:8080/metrics
Invoke-WebRequest http://127.0.0.1:12345/-/ready
```

If the runner printed a different `ready:` URL, use that URL instead of
`127.0.0.1:12345`.

For a persistent Windows service install, copy
`observability/grafana-cloud.alloy` to the Alloy service config path, set the
same environment variables in the service environment, and restart the service.
Remember that the service runs outside your current PowerShell session, so user
session environment variables may not be visible to it. The repo-local runner is
preferred for development because it keeps the WAL and logs next to the
checked-in config.

## Dashboard

Import `observability/grafana/brickadia-overview-dashboard.json` into Grafana
Cloud and select the Grafana Cloud Prometheus data source.

The dashboard includes:

- Server and Omegga health panels.
- BMF runtime status and freshness panels.
- BMF command totals, command duration, command rate, and transport duration.
- BMF worker throughput and poll duration panels.
- BMF event, plugin command, plugin hook, and scheduler callback timing panels.
- Native frame-time panels for average/max/last frame delta, FPS, slow-frame
  rate, sample rate, freshness, and latest spike.

Expected first-run behavior:

- Base server and Omegga panels should populate as soon as Omegga is running and
  Alloy is scraping.
- `bmf_runtime_status_up` and `bmf_telemetry_up` require BMF runtime files.
- Native frame panels remain `No data` until `BMFFrameTelemetry` is deployed and
  the server has restarted with the mod enabled.
- Grafana range changes can make new series look empty for a moment. Check
  Explore with the metric names above when debugging.

## Performance Investigation Workflow

Use the dashboard to answer two separate questions:

1. Is the server hitching?
2. Which subsystem got busier when the hitches appeared?

Start with:

```promql
brickadia_frame_delta_milliseconds{scope="window",statistic="max"}
sum by (threshold_ms) (rate(brickadia_frame_slow_total[$__rate_interval]))
sum by (command, status) (rate(bmf_command_processed_total[$__rate_interval]))
bmf_command_duration_milliseconds{statistic=~"avg|max|last"}
bmf_worker_items_total
```

If max frame time spikes but command volume looks normal, inspect BMF audit logs,
plugin logs, and recent feature flags. The current metrics identify aggregate
cost and command attribution; they do not yet provide per-Unreal-function CPU
profiles.

The player-position regression found during setup is the current warning case:
frequent live position reads can create high max frame times even with one
player. Future player-location features should prefer a shared bulk snapshot,
event stream, or cached provider over repeated per-player polling.

## L6 Frame Time Status Stage

BMF documentation defines `L6 Frame Time` as the validation stage for
performance-sensitive features. This Grafana/Alloy stack is the expected data
source for that stage.

An `L6 Frame Time` status update should include:

- baseline, active, and recovery time ranges;
- average and max `brickadia_frame_delta_milliseconds`;
- slow-frame and spike counters;
- command and worker attribution from BMF metrics;
- the feature flags/config values used during the run;
- whether disabling or stopping the feature returned frame time toward
  baseline.

Run this stage for features that poll player state, read live positions, send
frequent BMF commands, scan Unreal objects, mutate gameplay state, or process
bursty minigame traffic.

## Troubleshooting

No data in Grafana:

- Confirm Omegga is serving `http://127.0.0.1:8080/metrics`.
- Confirm the repo-local Alloy instance is ready at the `ready:` URL printed by
  `observability/run-grafana-alloy.ps1`.
- If only `http://127.0.0.1:12345/-/ready` responds, check whether that is the
  installed Windows service running `%ProgramFiles%\GrafanaLabs\Alloy\config.alloy`
  instead of the repo config.
- Confirm the Grafana Cloud remote-write URL, username, and token are set in the
  same shell that launched Alloy.
- Check `observability/.alloy-logs` if Alloy was started by a wrapper that
  captures stdout/stderr.

BMF panels are empty:

- Confirm `Mods/BMF/runtime/status.json` exists and is fresh.
- Confirm `Mods/BMF/runtime/telemetry.json` exists and is fresh.
- Set `OMEGGA_BMF_STATUS_PATH` or `OMEGGA_BMF_TELEMETRY_PATH` if the managed
  runtime path cannot be inferred.

Frame panels are empty:

- Build and deploy `BMFFrameTelemetry`.
- Restart the server so Omegga can enable the optional native mod.
- Confirm `Mods/BMF/runtime/frame-telemetry.json` exists.
- Check `brickadia_frame_telemetry_hook_registered`; it should be `1`.

Frame max is high:

- Check whether command rate or command duration changed at the same time.
- Disable the suspected feature flag or consumer and watch whether frame time
  returns toward baseline.
- Look for repeated per-player reads, broad UObject scans, filesystem polling,
  or console commands running on tight intervals.
- Reduce duplicate work first, then batch/cache/coalesce, then consider socket
  or native transport changes.
