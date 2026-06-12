# RateLimitedCommand

Protects a plugin command from repeated use.

**Maturity:** `Copy-paste`
**Required capabilities:** None

```lua
local Plugin = {
  name = "RateLimitedCommand",
}

function Plugin.onLoad(BMF)
  BMF.commands.register("bmf.example.ratelimited", "Run a rate-limited example.", function()
    local allowed = BMF.rateLimits.check("example.ratelimited", {
      limit = 1,
      windowMs = 10000,
      subject = "server-console",
    })

    if not allowed.ok then
      return allowed
    end

    return BMF.result(true, "OK", "Rate-limited command accepted")
  end)
end

return Plugin
```
