# Dangerous Surfaces

Use this page as the index for BMF surfaces that can crash a server, mutate
live gameplay, bypass normal plugin policy, or need explicit operator opt-in.

## Who Should Read This?

Architects should use this page when reviewing BMF risk boundaries. Server
operators should use it before enabling unsafe options. Maintainers should keep
new native hooks, raw console wrappers, and broad object scans listed here.

## Risk Index

| Surface | Default | Risk | Safer path |
| --- | --- | --- | --- |
| [Restricted server exec](../api/server/restricted-exec.md) | Disabled by `allowPluginServerExec=false` | Runs arbitrary server console commands. | Prefer typed BMF wrappers such as chat, world save, and world load. |
| [Server shutdown](../api/server/shutdown.md) | Disabled by capability and config opt-in | Can stop validation servers when a future executor works. | Let Omegga or a service manager own process lifecycle. |
| [Plugin unsafe globals](../api/plugins/sandbox.md) | Disabled by `allowPluginUnsafeGlobals=false` and missing `unsafe.globals` | Lets plugins call raw UE4SS/native helpers. | Use scoped BMF facades and capability gates. |
| [Unsafe minigame commands](../api/minigames/unsafe-commands.md) | Disabled by unsafe opt-ins | Touches legacy Brickadia minigame console/object surfaces. | Use minigame events and data snapshots. |
| [Runtime brick state](../api/runtime-bricks.md) | Disabled by environment gates | Mutates live brick visibility/collision by runtime id. | Prefer UUID/purpose lookup tags, bounded canaries, and `L6 Frame Time` evidence. |
| [Applicator native policy](../api/permissions/applicator-policy.md) | Experimental native path | Blocks native component placement. | Keep role-file planning and policy evaluation as the first layer. |
| [Interactable tag guard](../api/permissions/interactable-tags.md) | Experimental native path | Blocks save-time Interactable ConsoleTag changes. | Keep allowed prefixes narrow and role-aware. |
| [Brick asset placement policy](../api/permissions/brick-assets.md) | Policy-ready, hook incomplete | Future placement/paste hook can block live building. | Use policy-only evaluation until a cancellable hook is proven. |
| Native hook maintenance | Maintainer-only | Pointer-sensitive and restart-sensitive native injection. | Follow [Native Hook Notes](../maintainers/native-hooks.md). |
| Live player position reads | Explicit opt-in only | Live pawn/player reflection can affect frame time or crash. | Use Omegga player sync and saved/log identity first. |

## Review Rule

Any new feature that uses polling, live UObject scans, native mutation,
per-player live reads, or bursty command/event traffic needs a validation plan
before it is treated as an operator-facing feature.

Use [Current Safe Defaults](current-safe-defaults.md) for the default gates and
[Observability and Performance](../architecture/observability-performance.md)
for `L6 Frame Time` expectations.
