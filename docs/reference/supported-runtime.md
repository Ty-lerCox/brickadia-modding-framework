# Supported Runtime Matrix

This page answers what works in the supported Omegga-backed BMF runtime and
what is still experimental.

For sequence diagrams, see [Architecture Patterns](../architecture/architecture-patterns.md).
For the detailed fork contract, see
[Omegga-Supported Runtime](../architecture/omegga-supported-runtime.md).

## Who Should Read This?

Server operators should use this page to choose the supported launch path.
Plugin authors should use it to understand which APIs depend on Omegga-fed
state. Architects and maintainers should use it before moving responsibilities
between BMF and Omegga.

## Current Supported Path

The supported Windows runtime is:

```text
Brickadia dedicated server + UE4SS + BMF + BMF-vendored Omegga Windows runtime
```

Current target: Brickadia EA3.1 PC-Shipping-CL15501.

Stock upstream Omegga and the global npm package are not the current supported
BMF runtime.

Linux and WSL are not supported for the UE4SS/BMF dedicated-server runtime. Use
Windows for the dedicated server process and UE4SS mod loading.

## Runtime Matrix

| Capability | Supported Omegga-backed runtime | Experimental/native constraints |
| --- | --- | --- |
| Server launch/restart | Omegga fork is the supported owner. | Future supervisor work must replace this before Omegga can be removed. |
| UE4SS/BMF staging | Omegga fork installs the pinned UE4SS/BMF payload and launch environment. | Installer work continues behind the same Omegga requirement. |
| `bmf.*` bridge commands | Supported through BMF Bridge and BMFSocket transport. | Any replacement transport must pass the same canaries first. |
| Lua plugin loading | Supported after UE4SS loads BMF under the Omegga-managed launch. | N/A |
| Plugin storage/config | Supported. | N/A |
| Event bus inside Lua | Supported. | N/A |
| Events to Omegga plugins | Supported through BMFSocket. | Socket protocol remains experimental. |
| Player identity | Omegga adapter plus Brickadia saved/log fallback. | Native identity mapping remains research. |
| Chat broadcast/whisper | Supported through safe live controller helper path. | Live targeting still needs more validation. |
| World save/load wrappers | Supported through the Omegga/UE4SS helper route. | Some paths remain experimental. |
| Runtime brick state | Supported only behind explicit gates. | `unsafe-native`, needs `L6 Frame Time` before gameplay promotion. |
| Native hook policies | Supported where hook sync scripts and adapters are deployed. | Experimental, per-build pointer refresh required. |
| Metrics export | Omegga `/metrics` exports BMF telemetry. | Native frame telemetry can be enabled separately. |

## Practical Rule

Use the supported Omegga fork for normal Windows server operation. BMF releases
and setup docs should present Omegga as a requirement until every Omegga-owned
runtime responsibility has an accepted and validated replacement.

!!! warning
    Do not replace the supported BMF-vendored runtime with arbitrary upstream Omegga until BMF
    has validated that release against command transport, helper globals, socket
    behavior, player sync, and canaries.
