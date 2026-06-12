# Plugin Lifecycle

BMF plugins live under:

```text
Mods/BMF/plugins/<PluginName>/
  bmf.json
  main.lua
  config.json
  data/
```

**Labels:** `stable`, `L2 Headless`

## Who Should Read This?

Plugin authors should use this page to understand how BMF loads, starts,
reloads, and unloads a plugin. Maintainers should use it when changing loader
ordering or lifecycle hook data.

## Entry Point

`main.lua` returns a plugin table. The loader supports:

- `onLoad(BMF, data)`: called after the plugin script loads.
- `onServerReady(BMF, data)`: called after BMF starts its command worker and
  emits `serverReady`. Plugins loaded by `bmf.reload` after the server is ready
  receive this hook during reload.
- `onTick(BMF, data)`: called by a lazy recurring lifecycle timer while at
  least one loaded plugin defines `onTick`.
- `onUnload(BMF, reason)`: called before `bmf.reload` clears loaded plugins.
- `onError(BMF, context)`: called when BMF catches a plugin hook failure or a
  plugin-owned command handler failure.

Lifecycle data is intentionally small and stable. `onServerReady` receives
`version`, `pluginsLoaded`, and `commandsRegistered`. `onTick` receives
`tick`, `intervalMs`, and `serverReady`. `onError` receives `plugin`, `hook`,
`error`, and `data`.

## Metadata

`bmf.json` is read as plugin metadata. BMF currently extracts simple string
fields such as `name`, `version`, `description`, and the string-array
`capabilities`.

## Listing And Reload

`BMF.plugins.list()` returns loaded plugin metadata:

```lua
local listed = BMF.plugins.list()
for _, plugin in ipairs(listed.data.plugins) do
  BMF.log(plugin.name .. " " .. plugin.version)
end
```

The `bmf.plugins` server command prints the same loaded plugin count plus
per-plugin version, capability count, error count, and isolation state.

`bmf.unload` unloads currently loaded plugins and removes plugin-owned commands
and event handlers. `bmf.load` loads plugin directories from disk again without
restarting the Brickadia server:

```text
Omegga.Bridge.BMF bmf.unload
Omegga.Bridge.BMF bmf.load
```

The console-command canary proves a temporary plugin command works before
unload, is unloaded, and works again after `bmf.load`.
