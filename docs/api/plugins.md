# Plugins API

BMF plugins are Lua packages loaded from `Mods/BMF/plugins/<PluginName>/`.
This overview points to the focused plugin API pages.

**Labels:** `stable`, `L2 Headless`, `L5 Negative`

## Who Should Read This?

Plugin authors should start here before writing `main.lua` or `bmf.json`.
Maintainers should use the child pages when changing loader behavior,
capability gates, sandbox policy, storage, or watchdog handling.

## Page Map

| Page | Use it for |
| --- | --- |
| [Lifecycle](plugins/lifecycle.md) | Plugin folder shape, `main.lua`, lifecycle hooks, reload, and load/unload commands. |
| [Capabilities](plugins/capabilities.md) | `bmf.json` capability gates and plugin facade permissions. |
| [Sandbox](plugins/sandbox.md) | Unsafe global blocking and the research-only escape hatch. |
| [Storage](plugins/storage.md) | Plugin-scoped config/state reads and writes. |
| [Watchdog](plugins/watchdog.md) | Hook/command failure tracking, isolation, and reload recovery. |

## Examples

- [HelloBroadcast](../examples/hello-broadcast.md): minimal plugin shape with
  `onLoad`.
- [Plugin Storage](../examples/plugin-storage.md): complete plugin using config
  and plugin-scoped state.

## Validation

Plugin behavior is covered by lifecycle, storage, sandbox, watchdog, and
capability-gate canaries. See
[API Validation Evidence](../validation/api-validation.md) for the current
validation split.
