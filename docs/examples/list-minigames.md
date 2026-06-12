# ListMinigames

Runs the safe minigame list command after startup.

**Maturity:** `Runnable folder`
**Required capabilities:** None

Runnable source:
[examples/ListMinigames](https://github.com/Ty-lerCox/brickadia-modding-framework/tree/main/examples/ListMinigames)

```lua
local Plugin = {}

Plugin.name = "ListMinigames"

function Plugin.onLoad(BMF)
  BMF.timers.after(5000, function()
    local result = BMF.minigames.list()
    if result.ok then
      BMF.log("ListMinigames command=" .. result.data.command)
    else
      BMF.log("ListMinigames failed code=" .. result.code)
    end
  end)
end

return Plugin
```
