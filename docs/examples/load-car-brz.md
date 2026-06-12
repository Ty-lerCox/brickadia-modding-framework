# LoadCarBrz

Loads a staged BRZ-derived world bundle and then saves the current world.

**Maturity:** `Runnable folder`
**Required capabilities:** `prefabs.loadBrz`, `world.saveAs`

Runnable source:
[examples/LoadCarBrz](https://github.com/Ty-lerCox/brickadia-modding-framework/tree/main/examples/LoadCarBrz)

```lua
return {
  onLoad = function(BMF)
    BMF.timers.after(8000, function()
      local load = BMF.prefabs.loadBrz({
        source = "Car.brz",
        name = "BMF_CarBrzPrefabStage",
        position = { x = 58000, y = 0, z = 1000 },
        yaw = 0,
      })

      if not load.ok then
        BMF.log("LoadCarBrz load failed: " .. load.code)
        return
      end

      BMF.timers.after(6000, function()
        local save = BMF.world.saveAs("BMF_AfterLoadCarBrz")
        if not save.ok then
          BMF.log("LoadCarBrz save failed: " .. save.code)
        end
      end)
    end)
  end,
}
```
