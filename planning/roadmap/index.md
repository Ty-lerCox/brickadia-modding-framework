# Roadmap

This roadmap tracks the work to make BMF the single supported place to install,
run, inspect, and maintain a modded Windows Brickadia server.

The target user is an operator on a Windows machine who wants a Brickadia
dedicated server with BMF, Omegga scripting support, UE4SS compatibility files,
socket-backed event traffic, and Grafana Cloud telemetry without manually
assembling every piece.

## Goal

BMF should become a self-contained distribution for Brickadia server modding:

- install and update the supported Brickadia/Omegga/BMF runtime stack;
- stage UE4SS, BMF Lua, native socket, frame telemetry, and Omegga adapters;
- start, stop, restart, and troubleshoot the managed server services;
- configure Grafana Alloy remote write and publish a standard dashboard;
- show local health, logs, and event traffic without becoming a Grafana
  replacement;
- expose a shared orchestration core used by both CLI and desktop UI.
- ship a Windows MSI installer so users can install BMF Desktop without a
  developer checkout.

## Product Shape

The desktop application is an operations control panel, not a metrics
dashboard. It should answer:

- Is the stack installed correctly?
- Which service is unhealthy?
- What command failed, with what log output?
- Is BMF loaded in UE4SS?
- Is Omegga running and connected to the server?
- Is the BMF socket path active?
- Is Alloy scraping and remote-writing?
- Where is the Grafana dashboard for deeper telemetry?
- Which BMF/Omegga event payloads are moving right now?

Real metric exploration, long-range charts, and frame-time analysis stay in
Grafana. BMF Desktop should link to the configured dashboard and report whether
the telemetry path is healthy.

## Roadmap Pages

- [BMF unified runtime goal](goal.md)
- [Monorepo consolidation](monorepo-consolidation.md)
- [Phase plan](phase-plan.md)
- [BMF Desktop control panel](bmf-desktop-control-panel.md)
- [Service health model](service-health-model.md)
- [Grafana onboarding](grafana-onboarding.md)
- [Event traffic inspector](event-traffic-inspector.md)
- [Release artifacts](release-artifacts.md)

## Current Constraint

The current supported runtime still depends on the BMF-supported Omegga Windows
fork. The roadmap keeps Omegga in the stack while moving ownership,
installation, packaging, and diagnostics into the BMF repository.
