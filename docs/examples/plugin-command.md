# Plugin Command

Registers a server-console command owned by the plugin. Invoke it through the
BMF Bridge socket route as `bmf.example`.

**Maturity:** `Copy-paste`
**Required capabilities:** None

```lua
local Plugin = {
  name = "CommandExample",
}

function Plugin.onLoad(BMF)
  BMF.commands.register("bmf.example", "Return a small example payload.", function(raw)
    return BMF.result(true, "OK", "Example command handled", {
      lines = {
        "raw=" .. tostring(raw or ""),
        "plugin=" .. Plugin.name,
      },
    })
  end)
end

return Plugin
```
