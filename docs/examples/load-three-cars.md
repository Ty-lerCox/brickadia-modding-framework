# LoadThreeCars

Loads a staged `.brdb` world bundle and then saves the current world.

**Maturity:** `Runnable folder`
**Required capabilities:** `world.loadAdditive`, `world.saveAs`

Runnable source:
[examples/LoadThreeCars](https://github.com/Ty-lerCox/brickadia-modding-framework/tree/main/examples/LoadThreeCars)

```lua
return {
  onLoad = function(BMF)
    BMF.timers.after(8000, function()
      local load = BMF.world.loadAdditive({
        name = "BMF_ThreeCarsFixture",
        position = { x = 20000, y = 0, z = 1000 },
        yaw = 0,
      })

      if not load.ok then
        BMF.log("LoadThreeCars load failed: " .. load.code)
        return
      end

      BMF.timers.after(6000, function()
        local save = BMF.world.saveAs("BMF_AfterThreeCarsAdditive")
        if not save.ok then
          BMF.log("LoadThreeCars save failed: " .. save.code)
        end
      end)
    end)
  end,
}
```
