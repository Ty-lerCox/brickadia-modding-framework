# HelloBroadcast

Broadcasts a chat message as soon as the plugin loads.

**Maturity:** `Runnable folder`
**Required capability:** `chat.broadcast`

Runnable source:
[examples/HelloBroadcast](https://github.com/Ty-lerCox/brickadia-modding-framework/tree/main/examples/HelloBroadcast)

```lua
local Plugin = {
  name = "HelloBroadcast",
}

function Plugin.onLoad(BMF)
  BMF.log("HelloBroadcast loaded")
  BMF.chat.broadcast("[BMF] HelloBroadcast loaded")
end

return Plugin
```
