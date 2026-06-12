# TimedBroadcast

Schedules one chat broadcast ten seconds after startup.

**Maturity:** `Runnable folder`
**Required capabilities:** `chat.broadcast`, `timers.basic`

Runnable source:
[examples/TimedBroadcast](https://github.com/Ty-lerCox/brickadia-modding-framework/tree/main/examples/TimedBroadcast)

```lua
local Plugin = {
  name = "TimedBroadcast",
}

function Plugin.onLoad(BMF)
  BMF.timers.after(10000, function()
    BMF.chat.broadcast("[BMF] TimedBroadcast fired after startup")
  end)
end

return Plugin
```
