# WelcomeMessage

Plans server settings changes without directly mutating the live server.

**Maturity:** `Runnable folder`
**Required capabilities:** None

Runnable source:
[examples/WelcomeMessage](https://github.com/Ty-lerCox/brickadia-modding-framework/tree/main/examples/WelcomeMessage)

```lua
local Plugin = {}

Plugin.name = "WelcomeMessage"

function Plugin.onLoad(BMF)
  local planned = BMF.server.planSettingsPatch({
    serverName = "BMF Canary Server",
    welcomeMessage = "Welcome from BMF",
    publiclyListed = false,
  })

  if planned.ok then
    BMF.log("WelcomeMessage planned changes=" .. tostring(#planned.data.changes))
  else
    BMF.log("WelcomeMessage failed code=" .. planned.code)
  end
end

return Plugin
```
