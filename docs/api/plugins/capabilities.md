# Plugin Capabilities

Plugin capabilities are declared in `bmf.json` and enforced by the scoped BMF
facade passed to each plugin.

**Labels:** `stable`, `capability-gated`, `L5 Negative`

## Who Should Read This?

Plugin authors should use this page before calling APIs that can affect chat,
server lifecycle, world state, or plugin files. Maintainers should use it when
adding a new gated helper.

## Manifest Shape

```json
{
  "name": "Example",
  "version": "1.0.0",
  "capabilities": ["chat.broadcast", "plugins.storage"]
}
```

`*` allows every gated helper, but example plugins should declare only the
smallest needed set.

## Current Gates

| Capability | Enables |
| --- | --- |
| `server.exec` or `server.exec.restricted` | `BMF.server.exec(command)`, also requiring `allowPluginServerExec: true` |
| `server.save` | `BMF.server.save(options)` |
| `server.shutdown` | `BMF.server.shutdown(options)`, also requiring `allowPluginServerShutdown: true` |
| `chat.broadcast` | `BMF.chat.broadcast(message)` |
| `chat.whisper` | `BMF.chat.whisper(player, message)` |
| `chat.statusMessage` | `BMF.chat.statusMessage(player, message)` |
| `world.loadAdditive` | `BMF.world.loadAdditive(options)` |
| `world.saveAs` | `BMF.world.saveAs(name)` |
| `prefabs.loadBrdb` | `BMF.prefabs.loadBrdb(options)` |
| `prefabs.loadBrz` | `BMF.prefabs.loadBrz(options)` |
| `vehicles.spawnSet` | `BMF.vehicles.spawnSet(options)` |
| `plugins.storage` | `BMF.storage.*` |

## Runtime Checks

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

Helpers return `CAPABILITY_REQUIRED` when the plugin lacks the matching
capability.
