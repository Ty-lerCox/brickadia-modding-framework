# First Plugin

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
