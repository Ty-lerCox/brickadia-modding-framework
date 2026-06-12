# Minigames API

BMF minigame support is centered on BMF-owned event and data surfaces. Legacy
Brickadia `Server.Minigames.*` wrappers still exist, but they fail closed by
default.

!!! warning
    Some legacy minigame console commands can crash the current
    dedicated-server build. Prefer BMF-owned events and data snapshots for
    gameplay systems.

For event-bus architecture, see
[BMF And Omegga Event Bus Messaging](../architecture/architecture-patterns.md#6-bmf-and-omegga-event-bus-messaging).
For canary coverage, see
[API Validation Evidence](../validation/api-validation.md#minigames).

**Labels:** `experimental`, `L2 Headless`, `L5 Negative`, `unsafe opt-ins`

## Who Should Read This?

Plugin authors should use this page to pick between minigame definitions,
events, and cache queries. Omegga integrators should use it when adapting
observed minigame state into BMF. BMF maintainers should use it to keep unsafe
legacy probes away from normal gameplay paths.

## When To Use

| Goal | Start here |
| --- | --- |
| Store target minigame definitions | [Desired Definitions](minigames/definitions.md) |
| Emit or subscribe to minigame events | [Events](minigames/events.md) |
| Query event-fed minigame state | [Data Snapshot](minigames/data.md) |
| Inspect disabled legacy wrappers or object probes | [Unsafe Commands](minigames/unsafe-commands.md) |

## Examples

- [ListMinigames](../examples/list-minigames.md): complete plugin that
  exercises the guarded list wrapper.
- [EventAudit](../examples/event-audit.md): event subscription pattern
  shared by BMF-owned minigame event adapters.

## API Pages

- [Desired Definitions](minigames/definitions.md): BMF-owned desired minigame
  registry and reconciliation against observed state.
- [Events](minigames/events.md): namespaced event emission, subscription,
  metadata normalization, and Omegga relay behavior.
- [Data Snapshot](minigames/data.md): in-memory observed minigame data cache and
  query APIs.
- [Unsafe Commands](minigames/unsafe-commands.md): legacy console wrappers and
  raw object snapshot probes that require explicit unsafe opt-ins.

## Result Shape

Minigame APIs return the standard BMF result shape. Event APIs also attach
normalized `_bmf` metadata to accepted payloads before subscribers run. Data APIs
read BMF-owned cache state and do not call Brickadia `Server.Minigames.*`
commands.

!!! warning
    Prefer the BMF-owned event/data APIs for gameplay systems. Legacy minigame
    console wrappers and direct object probes remain unsafe opt-ins.
