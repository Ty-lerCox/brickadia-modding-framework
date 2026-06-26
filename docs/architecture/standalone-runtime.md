# Omegga Requirement

BMF requires the BMF-supported Omegga Windows fork for the supported Windows
Brickadia dedicated-server setup. Omegga is part of the current BMF release
shape.

The fork is part of the runtime contract because it owns process supervision,
UE4SS compatibility setup, launch environment, command bridge transport, log
context, player sync, and helper surfaces used by BMF canaries and live-player
APIs.

## Who Should Read This?

Server operators should use this page to understand that Omegga is required.
BMF maintainers should use it before changing docs, installers, release notes,
or validation plans that describe the supported runtime.

## Required Runtime Layers

| Layer | Current Owner |
| --- | --- |
| Brickadia dedicated server launch | BMF-supported Omegga Windows fork |
| UE4SS/BMF compatibility setup | BMF-supported Omegga Windows fork |
| BMF UE4SS Core | BMF |
| BMF Bridge and command transport | BMF-supported Omegga fork plus BMF Bridge/BMFSocket |
| Player identity and log context | BMF-supported Omegga fork plus packaged BMF adapters |
| Plugin config/data storage | BMF |
| Metrics export | Omegga `/metrics` plus BMF runtime files |
| Windows setup flow | BMF Desktop plus the required Omegga runtime |

## Documentation Rule

Installation, setup, release, and support docs must describe Omegga as a
requirement for BMF. Do not present Omegga as interchangeable with stock
upstream Omegga or removable for the supported Windows path.

When a future implementation proposes replacing an Omegga-owned responsibility,
the replacement must first provide equivalent launch, bridge, log, player-sync,
and validation evidence. Until that replacement is accepted, the documented
operator guidance remains:

```text
Brickadia dedicated server + UE4SS + BMF + BMF-supported Omegga Windows fork
```

## Replacement Criteria

A future release may change the requirement only after all current Omegga-owned
responsibilities have validated BMF-owned or accepted upstream equivalents:

| Current Omegga Responsibility | Required Replacement Evidence |
| --- | --- |
| Server launch, stop, restart, and crash evidence | Windows service/supervisor tests and operator docs |
| UE4SS install and compatibility setup | Clean-server install validation for the current Brickadia target |
| `bmf.*` command bridge | Authenticated transport canaries and CLI/Desktop integration |
| Log tailing and support snapshots | Redacted log collection from the same runtime sources |
| Player identity sync | Live-player validation and saved/log fallback evidence |
| Helper globals and safe console routes | Per-target compatibility validation |
| Metrics export | Equivalent dashboard and scrape contract |

Any page that discusses future replacement work should link here and keep the
current setup instructions Omegga-required.
