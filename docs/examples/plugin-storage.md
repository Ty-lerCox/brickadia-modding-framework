# Plugin Storage

Reads and writes plugin-scoped config and state files.

**Maturity:** `Copy-paste`
**Required capability:** `plugins.storage`

```lua
local Plugin = {
  name = "StorageExample",
}

function Plugin.onLoad(BMF)
  local loaded = BMF.storage.readConfig()
  local config = loaded.ok and loaded.data.value or {}
  local countResult = BMF.storage.readJson("state/count.json")
  local count = 0

  if countResult.ok and type(countResult.data.value) == "table" then
    count = tonumber(countResult.data.value.count) or 0
  end

  count = count + 1
  BMF.storage.writeJson("state/count.json", {
    count = count,
    lastLoadUtc = os.date("!%Y-%m-%dT%H:%M:%SZ"),
  })

  if config.announce ~= false then
    BMF.log("StorageExample load count=" .. tostring(count))
  end
end

return Plugin
```
