# Glossary

Use this page for shared BMF terms. If an API page needs one of these concepts,
link here instead of redefining it.

## Runtime Terms

| Term | Meaning |
| --- | --- |
| BMF | Brickadia Modding Framework, the UE4SS-loaded Lua framework for server-side Brickadia plugins. |
| UE4SS | Unreal Engine 4 scripting/runtime layer BMF uses to load Lua and call selected Brickadia/Unreal surfaces. |
| BMF-supported Omegga fork | The supported Windows Omegga fork used for server launch, UE4SS setup, command transport, player sync, logs, and validation. |
| Stock upstream Omegga | Upstream Omegga builds outside the supported BMF Windows fork. These are not the current supported BMF runtime. |
| BMFSocket | Optional native UE4SS C++ transport used by BMF for loopback command responses and event delivery. |
| Socket broker | The authenticated loopback TCP broker started by the supported Omegga fork for BMF and Omegga plugin clients. |
| File-backed command worker | The durable fallback command path under `Mods/BMF/runtime/commands`. |
| JSONL fallback | Durable event output such as `runtime/events.jsonl`, used for audit and fallback when socket delivery is unavailable. |
| BMFFrameTelemetry | Optional native sampler that writes frame-time metrics to `runtime/frame-telemetry.json`. |

## Gameplay Terms

| Term | Meaning |
| --- | --- |
| ConsoleTag | Brickadia component tag used by gameplay plugins as a stable logical identity, for example `lookup:<uuid>:treecut` or another opaque resource key. It is not a live pointer. |
| Lookup tag | Canonical BMF `ConsoleTag` format `lookup:<uuid>:<purpose>`. BMF treats the purpose as opaque and uses the tag to resolve/cache live runtime brick ids internally. |
| Runtime brick id | Live in-process brick identifier candidate. It must be verified against the active server process before native mutation. |
| Native hook | C++ detour or native function wrapper used when Lua hooks are unsafe or not cancellable. |
| Hook ingress | The path that captures Brickadia runtime data and hands a normalized event to BMF Lua. |
| Event bus | `BMF.events`, the in-process Lua publish/subscribe surface. |
| Capability gate | Plugin manifest requirement that allows access to a BMF API such as `chat.broadcast` or `server.save`. |
| Unsafe opt-in | Explicit config or capability needed before BMF exposes a crash-prone or broad native/console path. |

## Validation Labels

| Label | Meaning |
| --- | --- |
| `stable` | Safe enough for normal plugin use within documented validation limits. |
| `experimental` | Useful, but still tied to reverse-engineering evidence or live validation limits. |
| `scaffold` | Public shape exists, but full live behavior is not proven. |
| `file-backed` | Plans or patches files; live hot-reload behavior is not implied. |
| `restricted` | Internal-leaning or dangerous path; prefer a typed BMF wrapper. |
| `unsafe-native` | Touches raw native, reflected Unreal, or crash-prone console behavior. |
| `live-player` | Requires a connected player/controller to prove real behavior. |

## Validation Levels

| Level | Meaning |
| --- | --- |
| `L0 Static` | Package layout, manifests, docs, scripts, fixtures, and static checks pass without starting Brickadia. |
| `L1 Boot` | Brickadia dedicated server starts with UE4SS and BMF loaded. |
| `L2 Headless` | A canary passes on a dedicated server without a connected player. |
| `L3 Live Player` | A canary passes with one connected player and proves player-visible or player-bound behavior. |
| `L4 Multiplayer` | Two or more players prove targeting, isolation, or multiplayer interaction. |
| `L5 Negative` | Failure, denial, exploit, or abuse-prevention behavior is tested. |
| `L6 Frame Time` | Native frame telemetry is captured before, during, and after the feature path. |
