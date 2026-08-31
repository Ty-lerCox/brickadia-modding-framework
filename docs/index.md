# Brickadia Modding Framework

BMF is a server-side Lua modding framework for Brickadia dedicated servers.
It runs through UE4SS and exposes Brickadia-specific APIs so server mods can be
written without every plugin author reverse-engineering the game.

Current target: Brickadia EA3.1 `PC-Shipping-CL15714`.

BMF currently targets the BMF-vendored Omegga Windows runtime for Windows server
operation, UE4SS setup, command transport, live helper calls, and validation.

See the [Supported Runtime Matrix](reference/supported-runtime.md) for what the
fork owns, why Omegga is required for BMF, and which native paths are still
experimental.

BMF also writes runtime telemetry for health, command/event/plugin timings,
command-worker throughput, and optional native frame-time samples. See
[Observability and Performance](architecture/observability-performance.md) for
the exporter path and metric details.

## Who Should Read This?

Plugin authors should start here before writing Lua against BMF. Server
operators should use it to find install, status, and validation pages.
Architects and maintainers should jump from here into the architecture and API
sections.

## What BMF Provides

- A UE4SS-loadable Lua framework package.
- Server-side plugin discovery and lifecycle hooks.
- Capability-gated APIs for chat, storage, commands, world helpers, and more.
- Headless validation scripts and live-player validation notes.
- Markdown API documentation for each public BMF surface.

## Start Here

- [First install with BMF Desktop](install/windows.md)
- [First plugin](getting-started/first-plugin.md)
- [Common workflows](guides/common-workflows.md)
- [Lua examples](examples/index.md)
- [Supported runtime matrix](reference/supported-runtime.md)
- [Glossary](reference/glossary.md)
- [Architecture patterns](architecture/architecture-patterns.md)
- [Omegga-supported runtime](architecture/omegga-supported-runtime.md)
- [Observability and performance](architecture/observability-performance.md)
- [API overview](api/index.md)
- [Current status](status.md)
- [Project changelog](changelog.md)

## Project State

BMF is experimental. Some APIs are static or headless validated, while a smaller
set has live-player validation. Each API page calls out its current validation
level where known.
