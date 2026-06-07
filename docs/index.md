# Brickadia Modding Framework

BMF is a server-side Lua modding framework for Brickadia dedicated servers.
It runs through UE4SS and exposes Brickadia-specific APIs so server mods can be
written without every plugin author reverse-engineering the game.

Current target: Brickadia EA2 `PC-Shipping-CL13530`.

BMF currently targets the BMF-supported Omegga Windows fork for Windows server
operation, UE4SS setup, command transport, live helper calls, and validation:
<https://github.com/Ty-lerCox/bmf-omegga-fork>. Stock upstream Omegga is not
the supported Windows runtime for BMF.

## What BMF Provides

- A UE4SS-loadable Lua framework package.
- Server-side plugin discovery and lifecycle hooks.
- Capability-gated APIs for chat, storage, commands, world helpers, and more.
- Headless validation scripts and live-player validation notes.
- Markdown API documentation for each public BMF surface.

## Start Here

- [First plugin](getting-started/first-plugin.md)
- [Windows install](install/windows.md)
- [Omegga-supported runtime](architecture/omegga-supported-runtime.md)
- [API overview](api/index.md)
- [Current status](status.md)

## Project State

BMF is experimental. Some APIs are static or headless validated, while a smaller
set has live-player validation. Each API page calls out its current validation
level where known.
