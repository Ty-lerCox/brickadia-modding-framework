# Roadmap

BMF is moving toward a single Windows-friendly distribution for running a
modded Brickadia dedicated server with BMF, Omegga scripting support, UE4SS
compatibility files, and optional Grafana telemetry.

The current public roadmap is intentionally high level:

- keep the supported Windows server path stable;
- package the BMF runtime, native helpers, Omegga runtime, and adapters from
  this repository;
- provide BMF Desktop as the normal install, health, service, telemetry, and
  troubleshooting control panel;
- keep Grafana as the place for real telemetry dashboards;
- ship release artifacts that can be validated, updated, and repaired safely.

Detailed implementation plans, internal goal documents, UI guardrails, and
phase-tracking notes are kept outside the rendered documentation site.
