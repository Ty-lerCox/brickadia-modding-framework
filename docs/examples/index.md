# Lua Examples

BMF API docs should include a Lua example for every public surface. Use this
page as the example catalog and link to it from API reference pages.

Each example shows a complete `main.lua` plugin unless the repository already
has a larger runnable example. For runnable examples, copy the matching folder
from `examples/` into `Mods/BMF/plugins/` and keep its `bmf.json` capabilities
with the plugin.

## Documentation Standard

Every new API page should include:

- a minimal Lua snippet close to the function reference;
- a complete plugin example on this page or in `examples/<Name>`;
- the required `bmf.json` capabilities when the API is capability-gated;
- the validation command or built-in BMF command that proves the example works.

## Example Coverage

| API area | Lua example | Runnable repository example |
| --- | --- | --- |
| Chat | [HelloBroadcast](#hellobroadcast) | [examples/HelloBroadcast](https://github.com/Ty-lerCox/brickadia-modding-framework/tree/main/examples/HelloBroadcast) |
| Timers | [TimedBroadcast](#timedbroadcast) | [examples/TimedBroadcast](https://github.com/Ty-lerCox/brickadia-modding-framework/tree/main/examples/TimedBroadcast) |
| Commands | [Plugin Command](#plugin-command) | Inline example |
| Plugins and storage | [Plugin Storage](#plugin-storage) | Inline example |
| Server settings | [WelcomeMessage](#welcomemessage) | [examples/WelcomeMessage](https://github.com/Ty-lerCox/brickadia-modding-framework/tree/main/examples/WelcomeMessage) |
| World loading | [LoadThreeCars](#loadthreecars) | [examples/LoadThreeCars](https://github.com/Ty-lerCox/brickadia-modding-framework/tree/main/examples/LoadThreeCars) |
| Prefabs | [LoadCarBrz](#loadcarbrz) | [examples/LoadCarBrz](https://github.com/Ty-lerCox/brickadia-modding-framework/tree/main/examples/LoadCarBrz) |
| Vehicles | [SpawnVehicleSet](#spawnvehicleset) | [examples/SpawnVehicleSet](https://github.com/Ty-lerCox/brickadia-modding-framework/tree/main/examples/SpawnVehicleSet) |
| Minigames | [ListMinigames](#listminigames) | [examples/ListMinigames](https://github.com/Ty-lerCox/brickadia-modding-framework/tree/main/examples/ListMinigames) |
| Permissions | [AssignRole](#assignrole) | [examples/AssignRole](https://github.com/Ty-lerCox/brickadia-modding-framework/tree/main/examples/AssignRole) |
| Placement policy | [Placement Guards](#placement-guards) | [examples/NoSpawnItemApplicator](https://github.com/Ty-lerCox/brickadia-modding-framework/tree/main/examples/NoSpawnItemApplicator), [examples/InteractConsolePrefixGuard](https://github.com/Ty-lerCox/brickadia-modding-framework/tree/main/examples/InteractConsolePrefixGuard), [examples/BrickAssetPlacementGuard](https://github.com/Ty-lerCox/brickadia-modding-framework/tree/main/examples/BrickAssetPlacementGuard) |
| API labels | [InspectApiLabels](#inspectapilabels) | Inline example |
| Players | [PlayerSummary](#playersummary) | Inline example |
| Health and compatibility | [HealthCheck](#healthcheck) | Inline example |
| Events and audit | [EventAudit](#eventaudit) | Inline example |
| Rate limits | [RateLimitedCommand](#ratelimitedcommand) | Inline example |

## HelloBroadcast

Broadcasts a chat message as soon as the plugin loads.

Required capability: `chat.broadcast`.

```lua
local Plugin = {
  name = "HelloBroadcast",
}

function Plugin.onLoad(BMF)
  BMF.log("HelloBroadcast loaded")
  BMF.chat.broadcast("[BMF] HelloBroadcast loaded")
end

return Plugin
```

## TimedBroadcast

Schedules one chat broadcast ten seconds after startup.

Required capabilities: `chat.broadcast`, `timers.basic`.

```lua
local Plugin = {
  name = "TimedBroadcast",
}

function Plugin.onLoad(BMF)
  BMF.timers.after(10000, function()
    BMF.chat.broadcast("[BMF] TimedBroadcast fired after startup")
  end)
end

return Plugin
```

## Plugin Command

Registers a server-console command owned by the plugin. Invoke it through the
BMF command worker as `bmf.example`.

```lua
local Plugin = {
  name = "CommandExample",
}

function Plugin.onLoad(BMF)
  BMF.commands.register("bmf.example", "Return a small example payload.", function(raw)
    return BMF.result(true, "OK", "Example command handled", {
      lines = {
        "raw=" .. tostring(raw or ""),
        "plugin=" .. Plugin.name,
      },
    })
  end)
end

return Plugin
```

## Plugin Storage

Reads and writes plugin-scoped config and state files. The plugin needs the
`plugins.storage` capability.

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

## WelcomeMessage

Plans server settings changes without directly mutating the live server.

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

## LoadThreeCars

Loads a staged `.brdb` world bundle and then saves the current world.

Required capabilities: `world.loadAdditive`, `world.saveAs`.

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

## LoadCarBrz

Loads a staged BRZ-derived world bundle and then saves the current world.

Required capabilities: `prefabs.loadBrz`, `world.saveAs`.

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

## SpawnVehicleSet

Loads a planned set of staged vehicle worlds at separated positions.

Required capability: `vehicles.spawnSet`.

```lua
return {
  onLoad = function(BMF)
    local spawn = BMF.vehicles.spawnSet({
      copies = {
        { name = "BMF_VehicleSpawnSet_01", position = { x = 70000, y = 0, z = 1000 } },
        { name = "BMF_VehicleSpawnSet_02", position = { x = 72000, y = 0, z = 1000 } },
        { name = "BMF_VehicleSpawnSet_03", position = { x = 74000, y = 0, z = 1000 } },
      },
    })

    BMF.log("SpawnVehicleSet ok=" .. tostring(spawn.ok) .. " code=" .. tostring(spawn.code))
  end,
}
```

## ListMinigames

Runs the safe minigame list command after startup.

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

## AssignRole

Plans a player role assignment patch against a copied `RoleAssignments` shape.

```lua
local Plugin = {}

Plugin.name = "AssignRole"

function Plugin.onLoad(BMF)
  local assignments = {
    savedPlayerRoles = {
      ["11111111-1111-4111-8111-111111111111"] = {
        roles = { "Admin" },
      },
    },
  }

  local planned = BMF.permissions.planPlayerRoleAssignment(assignments, {
    uuid = "11111111-1111-4111-8111-111111111111",
    add = { "Moderator" },
    remove = { "Admin" },
  })

  if planned.ok then
    local resolved = BMF.permissions.getPlayerRoles(planned.data.assignments, planned.data.uuid)
    BMF.log("AssignRole planned roles=" .. tostring(#planned.data.roles) ..
      " resolved=" .. tostring(resolved.data and resolved.data.roleCount or 0))
  else
    BMF.log("AssignRole failed code=" .. planned.code)
  end
end

return Plugin
```

## Placement Guards

The placement guard examples are full policy plugins and are too large to inline
comfortably on one reference page. Use the runnable plugin folders:

- [NoSpawnItemApplicator](https://github.com/Ty-lerCox/brickadia-modding-framework/tree/main/examples/NoSpawnItemApplicator): blocks configured applicator components.
- [InteractConsolePrefixGuard](https://github.com/Ty-lerCox/brickadia-modding-framework/tree/main/examples/InteractConsolePrefixGuard): restricts Interactable console tag prefixes.
- [BrickAssetPlacementGuard](https://github.com/Ty-lerCox/brickadia-modding-framework/tree/main/examples/BrickAssetPlacementGuard): blocks configured placement assets and indexed prefab hashes.

The common command pattern for these policy examples is:

```lua
BMF.commands.register("bmf.guard.status", "Show guard status.", function()
  return BMF.result(true, "OK", "Guard status", {
    lines = {
      "policy=example",
      "enforcement=policy-ready",
    },
  })
end)
```

## InspectApiLabels

Lists BMF API records and logs the risk labels for one API.

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

## PlayerSummary

Finds known players through the safe player cache and logs a compact summary.

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

## HealthCheck

Logs framework health and compatibility details on load.

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

## EventAudit

Subscribes to framework events and writes structured audit records.

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

## RateLimitedCommand

Protects a plugin command from repeated use.

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
