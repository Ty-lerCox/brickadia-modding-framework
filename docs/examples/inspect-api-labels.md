# InspectApiLabels

Lists BMF API records and logs the risk labels for one API.

**Maturity:** `Validation pattern`
**Required capabilities:** None

```lua
local Plugin = {
  name = "InspectApiLabels",
}

function Plugin.onLoad(BMF)
  local listed = BMF.apis.list({ namespace = "chat" })
  if listed.ok then
    BMF.log("chat API count=" .. tostring(#listed.data.apis))
  end

  local whisper = BMF.apis.get("BMF.chat.whisper")
  if whisper.ok then
    BMF.log("whisper stability=" .. tostring(whisper.data.api.stability) ..
      " risk=" .. tostring(whisper.data.api.risk))
  end
end

return Plugin
```
