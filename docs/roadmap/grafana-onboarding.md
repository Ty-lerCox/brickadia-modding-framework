# Grafana Onboarding

BMF Desktop should help operators configure Grafana Cloud telemetry, but
Grafana remains the place to view real time-series dashboards.

## Goal

The app should make this path reliable:

```text
BMF runtime files -> Omegga /metrics -> Grafana Alloy -> Grafana Cloud -> BMF dashboard
```

BMF Desktop should show whether each hop is healthy and provide a link to the
dashboard for deeper inspection.

## Setup Inputs

The operator needs:

- Grafana Cloud Prometheus remote-write URL;
- Grafana Cloud Prometheus username;
- Grafana Cloud access policy token with metrics remote-write access;
- optional Grafana API token for dashboard import;
- stack URL or dashboard folder target;
- server label values such as environment, instance, and profile id.

Secrets must be stored outside the repo and must not be written into generated
support snapshots.

## App Responsibilities

BMF Desktop should:

- validate Grafana Cloud fields before starting Alloy;
- write or update an Alloy config for the selected server profile;
- start, stop, and health-check the local Alloy process or service;
- confirm Omegga `/metrics` is reachable before remote-write setup;
- upload or update the standard BMF dashboard when credentials allow it;
- store the resulting dashboard URL in the server profile;
- open the dashboard in the user's browser.

## Health Checks

| Check | Healthy when |
| --- | --- |
| Omegga metrics | `http://127.0.0.1:<port>/metrics` responds. |
| BMF status metric | `bmf_runtime_status_up` is present and fresh. |
| Frame telemetry metric | Present when BMFFrameTelemetry is enabled; otherwise reported as optional. |
| Alloy ready | Alloy readiness endpoint returns ready. |
| Remote write | Alloy reports no remote-write authentication or queue errors. |
| Dashboard | Dashboard uid/url is stored and opens in Grafana. |

## Dashboard Import

The standard dashboard should be versioned in the repo. Import should be
idempotent:

- create if missing;
- update if the dashboard version changed;
- preserve the configured folder when possible;
- write the dashboard uid and URL back to the profile.

The dashboard should filter by labels that BMF Desktop controls, such as:

```text
environment
instance
server_profile
brickadia_build
```

Current seed assets:

- `observability/alloy/bmf.alloy.template`
- `observability/grafana/bmf-dashboard.json`
- `observability/grafana/dashboard-import.json`
- `observability/observability-manifest.json`
- `packages/orchestrator-core/src/telemetry.js`

The shared telemetry renderer builds a profile-specific Alloy config from the
template while keeping remote-write secrets as environment-variable references.
It also builds the standard Grafana dashboard import payload, redacted endpoint
metadata, API-token environment references, payload checksums, and dashboard
URLs for BMF Desktop and `bmfctl`. Local JSON generation remains the default
path. Dashboard upload is available through the same shared contract only after
an explicit user action and `confirm: import`; API tokens stay in environment
variables and upload results are redacted. BMF Desktop writes generated payloads
through Electron IPC into app user-data storage by default, keeping MSI install
directories read-only.

BMF Desktop now also writes the generated Alloy config through Electron IPC
with an explicit `confirm: write-alloy` action. The app uses the configured
profile Alloy path when present and otherwise writes a profile-scoped
`*-bmf.alloy` file under Electron user data, keeping remote-write secrets as
environment-variable references instead of file contents.

The same shared service-action contract now exposes `start-alloy`,
`stop-alloy`, and `restart-alloy`. Alloy launch requires a configured Grafana
Alloy executable and rendered config, writes BMF-owned `*-alloy` PID/log/journal
evidence, and starts the collector as a foreground local process with
profile-scoped storage. BMF Desktop reports health from the readiness endpoint;
full telemetry exploration remains in Grafana.

BMF Desktop now adopts the dashboard URL returned by a confirmed dashboard
upload into the active profile draft, displays the active dashboard URL in the
Telemetry tab, and opens that configured URL through Electron's guarded
external-link IPC path. The app does not embed Grafana dashboards or fall back
to an unrelated URL when a profile has not configured one.

These assets and the renderer are validated by
`scripts/validate-observability-assets.ps1`.

## What The App Shows

The desktop UI should show:

- telemetry setup status;
- current scrape target;
- Alloy readiness;
- dashboard import status;
- dashboard URL;
- recent setup/log errors.

It should not embed the full Grafana dashboard or reimplement PromQL
exploration. For frame-time investigation, the app should open Grafana with the
configured dashboard or useful Explore links.
