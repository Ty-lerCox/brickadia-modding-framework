# BMF Observability Assets

This directory contains the repo-owned Grafana and Grafana Alloy assets for
BMF Desktop telemetry onboarding.

Current assets:

- `alloy/bmf.alloy.template`: Alloy config template that scrapes Omegga
  `/metrics` and remote-writes to Grafana Cloud or another Prometheus remote
  write endpoint.
- `grafana/bmf-dashboard.json`: Standard dashboard JSON model for a single BMF
  server profile.
- `grafana/dashboard-import.json`: Import contract BMF Desktop can use to wrap
  the dashboard model for Grafana API upload payloads.
- `observability-manifest.json`: Versioned index for the assets.

Secrets are intentionally referenced through environment variables or desktop
profile storage. The shared renderer prepares import JSON and redacted commands
only; it does not store Grafana API tokens or call Grafana automatically.
