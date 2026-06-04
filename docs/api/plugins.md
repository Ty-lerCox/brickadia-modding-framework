# Plugins API

BMF plugins live under:

```text
Mods/BMF/plugins/<PluginName>/
  bmf.json
  main.lua
  config.json
  data/
```

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

`bmf.json` is read as plugin metadata. BMF currently extracts simple string
fields such as `name`, `version`, `description`, and the string-array
`capabilities`.

## Capability Gates

Plugins receive a scoped BMF facade. Dangerous helpers return
`CAPABILITY_REQUIRED` unless the plugin declares the matching capability in
`bmf.json`.

Current gated capabilities:

- `server.exec` or `server.exec.restricted`: `BMF.server.exec(command)`;
  also requires framework `config.json` option `allowPluginServerExec: true`
- `server.save`: `BMF.server.save(options)`
- `server.shutdown`: `BMF.server.shutdown(options)`; also requires framework
  `config.json` option `allowPluginServerShutdown: true`
- `chat.broadcast`: `BMF.chat.broadcast(message)`
- `chat.whisper`: `BMF.chat.whisper(player, message)`
- `chat.statusMessage`: `BMF.chat.statusMessage(player, message)`
- `world.loadAdditive`: `BMF.world.loadAdditive(options)`
- `world.saveAs`: `BMF.world.saveAs(name)`
- `prefabs.loadBrdb`: `BMF.prefabs.loadBrdb(options)`
- `prefabs.loadBrz`: `BMF.prefabs.loadBrz(options)`
- `vehicles.spawnSet`: `BMF.vehicles.spawnSet(options)`
- `plugins.storage`: `BMF.storage.*`

`*` allows every gated helper, but example plugins should declare only the
smallest needed set.

```json
{
  "name": "Example",
  "version": "1.0.0",
  "capabilities": ["chat.broadcast", "plugins.storage"]
}
```

Plugins can inspect their own manifest capabilities:

```lua
if BMF.capabilities.has("chat.broadcast") then
  BMF.chat.broadcast("Example loaded")
end

local required = BMF.capabilities.require("plugins.storage")
if not required.ok then
  BMF.log(required.code)
end
```

## Unsafe Global Policy

Plugin code receives normal Lua globals through a scoped environment, but BMF
blocks known dangerous UE4SS/native globals by default. This keeps plugins on
the public BMF wrappers instead of bypassing capability gates, audit records,
rate limits, and watchdog handling.

Examples of blocked globals include:

- `OmeggaExecuteConsoleManagerInput`
- `OmeggaExecuteCachedConsoleExec`
- `OmeggaExecuteKismetConsoleCommand`
- `RegisterConsoleCommandGlobalHandler`
- `RegisterHook`
- `StaticFindObject`
- `ExecuteInGameThread`
- `ExecuteWithDelay`

Use BMF wrappers instead:

- `BMF.server.exec`, with capability and config opt-in, for restricted console
  execution.
- `BMF.world.loadAdditive` and `BMF.world.saveAs` for world commands.
- `BMF.timers.after` and `BMF.timers.every` for scheduling.

Runtime policy route:

```text
Omegga.Bridge.BMF bmf.sandbox
```

Lua inspection:

```lua
local policy = BMF.sandbox.policy()
local denials = BMF.sandbox.denials()
```

Experimental escape hatch:

```json
{
  "allowPluginUnsafeGlobals": true
}
```

A plugin must also declare `unsafe.globals`. This is intentionally not used by
examples and should stay research-only.

## `BMF.plugins.list()`

Returns loaded plugin metadata:

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

## Watchdog and Last Errors

BMF records plugin-owned hook and command failures per plugin. The default
watchdog policy is enabled and isolates a loaded plugin after three failures in
the current loaded plugin instance.

Config fields:

```json
{
  "pluginWatchdogEnabled": true,
  "pluginWatchdogMaxErrors": 3
}
```

When a plugin is isolated:

- future plugin hooks are skipped;
- plugin-owned console commands return `PLUGIN_ISOLATED` before the handler
  runs;
- `runtime/audit.jsonl` receives a `plugin.isolated` record;
- `BMF.plugins.list()` includes `errorCount`, `isolated`, `isolatedAt`,
  `isolatedReason`, and `lastError`.

Server-console watchdog route:

```text
Omegga.Bridge.BMF bmf.plugins.watchdog
```

`bmf.reload` resets watchdog state so a fixed plugin can load cleanly.

## `BMF.storage`

Storage helpers keep plugin writes inside the plugin folder. Path traversal and
absolute paths are rejected.

```lua
BMF.storage.writeConfigText([[{"enabled":true}]])
BMF.storage.writeConfig({ enabled = true, maxCount = 5 })
BMF.storage.writeText("state/count.txt", "1")
BMF.storage.writeJson("state/profile.json", {
  name = "LifecycleStorageCanary",
  score = 42,
})

local config = BMF.storage.readConfigText()
local parsedConfig = BMF.storage.readConfig()
local count = BMF.storage.readText("state/count.txt")
local profile = BMF.storage.readJson("state/profile.json")
```

Available helpers:

- `BMF.storage.readConfigText()`
- `BMF.storage.writeConfigText(text)`
- `BMF.storage.readConfig()`
- `BMF.storage.writeConfig(table)`
- `BMF.storage.readText(relativePath)`
- `BMF.storage.writeText(relativePath, text)`
- `BMF.storage.appendText(relativePath, text)`
- `BMF.storage.readJson(relativePath)`
- `BMF.storage.writeJson(relativePath, table)`

The legacy explicit-plugin forms still work when the plugin name matches the
current plugin:

- `BMF.storage.readConfigText(pluginName)`
- `BMF.storage.writeConfigText(pluginName, text)`
- `BMF.storage.readConfig(pluginName)`
- `BMF.storage.writeConfig(pluginName, table)`
- `BMF.storage.readText(pluginName, relativePath)`
- `BMF.storage.writeText(pluginName, relativePath, text)`
- `BMF.storage.appendText(pluginName, relativePath, text)`
- `BMF.storage.readJson(pluginName, relativePath)`
- `BMF.storage.writeJson(pluginName, relativePath, table)`

Malformed JSON returns `JSON_PARSE_FAILED` instead of throwing, so plugins can
recover from a bad config file.

## Validation

- `L0 Static`: package validator checks plugin/storage API markers and docs.
- `L2 Headless`: `scripts/validate-bmf-plugin-lifecycle-storage.ps1` loads a
  temporary plugin, verifies metadata through `bmf.plugins`, persists storage,
  reads/writes text and JSON config/data, proves malformed JSON is reported as
  `JSON_PARSE_FAILED`, calls `bmf.reload`, verifies `onUnload`, and confirms
  storage survived reload.
- `L2 Headless`: `scripts/validate-bmf-plugin-lifecycle-hooks.ps1` proves
  `onServerReady`, recurring `onTick`, `onError` from an `onTick` failure, and
  `onError` from a plugin-owned command failure.
- `L2 Headless + L5 Negative`: `scripts/validate-bmf-unsafe-globals.ps1`
  proves plugins cannot access known raw UE4SS/native globals by default, while
  ordinary Lua globals and BMF wrappers remain available.
- `L2 Headless + L5 Negative`: `scripts/validate-bmf-plugin-watchdog.ps1`
  forces a temporary plugin command to fail three times, proves the plugin is
  isolated, proves the fourth command is blocked as `PLUGIN_ISOLATED`, verifies
  `bmf.plugins.watchdog`, `bmf.audit.tail`, runtime status, and then proves
  `bmf.reload` clears watchdog state.
- `L2 Headless + L5 Negative`:
  `scripts/validate-bmf-capability-gates.ps1` loads temporary deny/allow
  plugins, verifies missing capabilities return `CAPABILITY_REQUIRED`, proves
  `server.exec.restricted` satisfies `server.exec`, confirms direct server exec
  still needs `allowPluginServerExec`, and confirms cross-plugin storage writes
  stay blocked.
