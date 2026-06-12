# EventAudit

Subscribes to framework events and writes structured audit records.

**Maturity:** `Copy-paste`
**Required capabilities:** None

```lua
local Plugin = {
  name = "EventAudit",
  listenerId = nil,
}

function Plugin.onLoad(BMF)
  Plugin.listenerId = BMF.events.on("serverReady", function(data)
    BMF.audit.record("example.server_ready", {
      version = data and data.version or "",
    })
    BMF.logInfo("serverReady observed", {
      version = data and data.version or "",
    })
  end)
end

function Plugin.onUnload(BMF)
  if Plugin.listenerId then
    BMF.events.off(Plugin.listenerId)
  end
end

return Plugin
```
