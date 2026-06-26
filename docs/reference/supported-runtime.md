# Supported Runtime Matrix

This page answers what works with the supported Omegga fork, what works in BMF
alone, and what is still experimental.

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
Brickadia dedicated server + UE4SS + BMF + BMF-supported Omegga Windows fork
```

Current target: Brickadia EA2 PC-Shipping-CL13530.

Stock upstream Omegga and the global npm package are not the current supported
BMF runtime.

Linux and WSL are not supported for the UE4SS/BMF dedicated-server runtime. Use
Windows for the dedicated server process and UE4SS mod loading.

## Runtime Matrix

| Capability | Supported Omegga fork | BMF without Omegga | Experimental/native lane |
| --- | --- | --- | --- |
| Server launch/restart | Supported owner | Not owned by BMF core | Future BMF supervisor |
| UE4SS/BMF staging | Supported owner | Manual install possible | Installer work continues |
| `bmf.*` bridge commands | Supported through BMF Bridge and BMFSocket transport | Requires an explicit external transport; legacy file worker is disabled by default | Future BMF supervisor transport |
| Lua plugin loading | Supported | Supported after UE4SS loads BMF | N/A |
| Plugin storage/config | Supported | Supported | N/A |
| Event bus inside Lua | Supported | Supported | N/A |
| Events to Omegga plugins | Supported through BMFSocket | Not available without external consumer | Socket protocol remains experimental |
| Player identity | Omegga adapter plus Brickadia saved/log fallback | Saved/log fallback only | Native identity mapping still research |
| Chat broadcast/whisper | Supported through safe live controller helper path | Possible only if helper path is available | Live targeting still needs more validation |
| World save/load wrappers | Supported | Possible when console/helper route exists | Some paths remain experimental |
| Runtime brick state | Supported only behind explicit gates | Not a standalone default | `unsafe-native`, needs `L6 Frame Time` before gameplay promotion |
| Native hook policies | Supported where hook sync scripts and adapters are deployed | Not standalone by default | Experimental, per-build pointer refresh required |
| Metrics export | Omegga `/metrics` exports BMF telemetry | BMF writes runtime JSON files | Native frame telemetry optional |

## Practical Rule

Use the supported Omegga fork for normal Windows server operation today. Treat
standalone BMF as a future independence track unless the target feature only
needs in-process Lua, plugin loading, storage, or runtime files.

!!! warning
    Do not replace the supported fork with arbitrary upstream Omegga until BMF
    has validated that release against command transport, helper globals, socket
    behavior, player sync, and canaries.
