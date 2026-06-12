# First Plugin

## Who Should Read This?

Plugin authors should use this page for the smallest working BMF plugin shape.
Server operators can use it as a quick smoke test after install.

Create a plugin folder under `Mods/BMF/plugins`.

```text
Mods/BMF/plugins/HelloBroadcast/
  bmf.json
  main.lua
```

`main.lua`:

```lua
local Plugin = {
  name = "HelloBroadcast",
}

function Plugin.onLoad(BMF)
  BMF.chat.broadcast("[BMF] Hello from Lua")
end

return Plugin
```

Optional `config.json` and `data/` files can be read through `BMF.storage`:

```lua
BMF.storage.writeText("HelloBroadcast", "state/last-load.txt", os.date("!%Y-%m-%dT%H:%M:%SZ"))
```

The first public example is intentionally small. It validates the BMF plugin
loader, lifecycle hook, and broadcast API without introducing unsafe game-state
mutation.

For more complete examples, see the [Lua Examples](../examples/index.md)
catalog. It links to focused examples for chat, timers, commands, storage, world
loading, prefab loading, vehicles, minigames, permissions, events, audit,
health, and rate limits.
