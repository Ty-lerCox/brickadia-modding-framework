---
name: bmf-start-server
description: Start and validate the local BMF/Brickadia server stack. Use when the user says "start server", "start BMF", "start Brickadia", "start Omegga", "start our services", "check BMF Desktop health", "make sure metrics/Grafana/Alloy are working", or asks whether the local BMF socket, telemetry, frame metrics, CityRPG metrics, Omegga metrics, or Brickadia server are healthy.
---

# BMF Start Server

## Overview

Start the local Windows BMF stack and prove it is healthy across the same surfaces BMF Desktop cares about: Omegga, Brickadia dedicated server, BMF runtime status, BMF native socket traffic, CityRPG metrics, frame telemetry, Alloy, and Grafana remote-write.

This skill is for the local machine. Prefer concrete evidence from processes, ports, HTTP metrics, BMF runtime JSON, socket commands, and Alloy remote-write counters.

## Quick Start

Run the bundled helper first:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Users\tycox\.codex\skills\bmf-start-server\scripts\Start-BmfLocalStack.ps1" -Mode StartOrCheck -Json
```

Use `-Mode CheckOnly` when the user only wants status and no missing service should be launched.

Treat the helper's JSON as the primary health report. If any check is `unhealthy` or `degraded`, inspect the evidence paths and logs named in that check before taking extra action.

## Workflow

1. Start or verify Omegga/Brickadia.
   - Prefer `C:\Users\tycox\OneDrive\Documents\GitHub\Brickadia\run-omegga.cmd` for the local live server.
   - Do not start a duplicate server if `127.0.0.1:8080/metrics`, `127.0.0.1:3000/metrics`, and UDP `7777` are already healthy.
   - Use hidden background windows and log files under `artifacts/service-start`.

2. Verify BMF runtime health.
   - Read `%APPDATA%\omegga\steam_installs\main\Brickadia\Binaries\Win64\ue4ss\main\Mods\BMF\runtime\status.json`.
   - Require `state=running`, `server_ready=true`, `compatibility_status=ok`, and `plugin_errors=0`.
   - Query `bmf.status` over the BMF socket from `runtime\socket.json`; do not trust file freshness alone.

3. Verify socket traffic.
   - Use `runtime\socket.json` and `runtime\bmf-bridge-status.json`.
   - Healthy evidence includes fresh metadata, a configured loopback broker, no socket errors, and command/response or event counters moving.
   - A connected bridge with no native client, stale metadata, or no activity is degraded and usually points to restart-stack/restart-BMF work.

4. Verify metrics producers.
   - Omegga metrics: `http://127.0.0.1:8080/metrics`, expected to include `bmf_runtime_status_up`, `brickadia_frame_*`, and Brickadia server metrics.
   - CityRPG metrics: `http://127.0.0.1:3000/metrics`, expected to include `cityrpg_metrics_up`.
   - Frame telemetry: `runtime\frame-telemetry.json`, expected fresh and hook-registered.
   - BMF telemetry: `runtime\telemetry.json`, expected fresh with bounded command/socket counters.

5. Verify Alloy and Grafana remote-write.
   - The installed Windows Alloy service may be running on `127.0.0.1:12345` with no BMF scrape components. Do not assume "Alloy is ready" means data is flowing.
   - Prefer an Alloy endpoint whose `/api/v0/web/components` includes `prometheus.remote_write.grafana_cloud` and `prometheus.scrape.omegga`.
   - Require remote-write samples sent, no failed samples, and no sustained pending backlog.
   - The helper may start a user-level Alloy process on `127.0.0.1:12346` using a generated config if the service on `12345` is empty or unusable.

6. Report a compact health summary.
   - Include overall status, started actions, server PID/ports, BMF version/compatibility, socket command result, metrics endpoints, Alloy port, and remote-write counters.
   - Call out non-fatal degraded checks separately from hard unhealthy checks.

## Local Paths

Read `references/local-stack.md` when you need exact BMF Desktop paths, profile locations, CLI equivalents, or the telemetry configuration notes.

## Guardrails

- Do not print Grafana tokens or BMF socket tokens.
- Do not add new high-frequency probes or dashboard-driven server commands. Observe existing metrics and socket traffic.
- Do not stop or restart processes unless the user asked for restart/stop or a stale owned BMF Desktop PID file makes the action safe.
- Do not hand-edit live UE4SS/BMF files as a durable fix; use the existing Omegga/BMF provisioning path.
- If a connected Brickadia client is needed after startup, use the `brickadia-client-join` skill.
- If live gameplay proof is needed, use the `bmf-live-server-validation` skill after this stack is healthy.

## Evidence To Report

```text
Overall status:
Started actions:
Brickadia server PID/UDP 7777:
Omegga metrics:
CityRPG metrics:
BMF status:
BMF socket command:
BMF bridge/socket traffic:
Frame telemetry:
Alloy admin endpoint:
Grafana remote-write samples:
Remaining degraded/unhealthy checks:
```
