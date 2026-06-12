# HealthCheck

Logs framework health and compatibility details on load.

**Maturity:** `Copy-paste`
**Required capabilities:** None

```lua
local Plugin = {
  name = "HealthCheck",
}

function Plugin.onLoad(BMF)
  local health = BMF.health()
  if health.ok then
    BMF.log("BMF version=" .. tostring(BMF.version))
    BMF.log("target=" .. tostring(health.data.target_build))
    BMF.log("plugins=" .. tostring(health.data.plugins_loaded))
  else
    BMF.log("HealthCheck failed code=" .. tostring(health.code))
  end

  local compatibility = BMF.compatibility.check()
  BMF.log("compatibility=" .. tostring(compatibility.code))
end

return Plugin
```
