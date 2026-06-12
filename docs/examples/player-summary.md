# PlayerSummary

Finds known players through the safe player cache and logs a compact summary.

**Maturity:** `Copy-paste`
**Required capabilities:** None

```lua
local Plugin = {
  name = "PlayerSummary",
}

function Plugin.onLoad(BMF)
  local listed = BMF.players.list()
  if not listed.ok then
    BMF.log("PlayerSummary list failed code=" .. tostring(listed.code))
    return
  end

  BMF.log("known players=" .. tostring(#listed.data.players) ..
    " live controllers=" .. tostring(listed.data.liveControllerCount or 0))

  for _, player in ipairs(listed.data.players) do
    local names = BMF.players.getName(player)
    if names.ok then
      BMF.log("player=" .. tostring(names.data.displayName) ..
        " uuid=" .. tostring(player.uuid))
    end
  end
end

return Plugin
```
