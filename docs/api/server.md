# Server API

BMF server settings support is currently split between Lua planning and
file-backed patch tooling. It does not hot-change the live server yet.

## `BMF.server.status()`

Returns structured server/runtime status. Fields that are not safely known in a
headless server are represented explicitly with `unknown` status values instead
of guessed data.

```lua
local status = BMF.server.status()
if status.ok then
  BMF.log("players=" .. tostring(status.data.playerCount))
  BMF.log("world=" .. tostring(status.data.worldNameStatus))
end
```

Headless-safe fields include:

- BMF version, startup time, uptime, paths, and config flags.
- Compatibility status, declared target build, build-detection mode, and
  required UE4SS helper availability.
- Loaded plugin count and plugin error count.
- Registered BMF command count and command names.
- Active timer count.
- Empty player adapter result, currently `headless-empty` without a connected
  player.
- Target build metadata for the current reverse-engineering lane.

The compatibility object mirrors `BMF.compatibility.check()`. Build detection is
currently `declared-target-only`, so unsupported future builds are reported but
not refused until a reliable runtime build source is proven.

Unknown until further live-object discovery:

- Server browser name and description.
- Current world/map name.
- Brick count and component count from the live world.

The `bmf.server.status` command prints the same status as stable key/value
lines for automation.

## `BMF.server.save(options)`

Saves the running world through the proven `BMF.world.saveAs` path. Pass a world
name string or an options table:

```lua
BMF.server.save("BMF_AdminSnapshot")
BMF.server.save({ name = "BMF_AdminSnapshot" })
```

If no name is supplied, BMF generates a `BMF_ServerSave_<timestamp>` name.
Plugins must declare `server.save`; otherwise the scoped plugin call returns
`CAPABILITY_REQUIRED`.

The `bmf.server.save` command exposes the same helper for unattended runs:

```text
Omegga.Bridge.BMF bmf.server.save name=BMF_AdminSnapshot
```

## `BMF.server.shutdown(options)`

Attempts a graceful `exit` console command after an explicit confirmation token.
This is intended for disposable validation servers and trusted admin automation,
but the current CL13530 executor path reports `SHUTDOWN_UNAVAILABLE` instead of
stopping the process.

```lua
BMF.server.shutdown({
  confirm = "BMF_SHUTDOWN",
  reason = "nightly-canary-complete",
  delayMs = 1500,
})
```

Without `confirm = "BMF_SHUTDOWN"`, the function returns
`CONFIRMATION_REQUIRED` and does not attempt shutdown. On the current runtime,
the confirmed path records `server.shutdown.executed` with
`CONSOLE_EXEC_FAILED` and returns `SHUTDOWN_UNAVAILABLE`.

Plugins must declare `server.shutdown`, and `Mods/BMF/config.json` must opt in with
`allowPluginServerShutdown: true`; otherwise scoped plugin calls return
`CAPABILITY_REQUIRED` or `CONFIG_OPT_IN_REQUIRED`.

The `bmf.server.shutdown` command exposes the same guarded path:

```text
Omegga.Bridge.BMF bmf.server.shutdown confirm=BMF_SHUTDOWN delayms=1500 reason=maintenance
```

Actual stop/restart is not claimed yet. A true stop/restart still requires an
external supervisor such as Omegga, a service manager, or a future BMF companion
process.

## `BMF.server.exec(command)`

Runs a server console command through the proven UE4SS/Omegga executor path.
Plugins must declare `server.exec` or `server.exec.restricted`; otherwise the
call returns `CAPABILITY_REQUIRED`.
The framework config must also opt in with `allowPluginServerExec: true`;
otherwise the call returns `CONFIG_OPT_IN_REQUIRED`.

```lua
local response = BMF.server.exec([[Chat.Broadcast "Hello from BMF"]])
if not response.ok then
  BMF.log(response.code)
end
```

This is intentionally treated as a restricted internal API. Prefer a typed BMF
wrapper such as `BMF.chat.broadcast`, `BMF.world.saveAs`, or
`BMF.world.loadAdditive` when one exists.

Default `Mods/BMF/config.json`:

```json
{
  "allowPluginServerExec": false,
  "allowPluginServerShutdown": false
}
```

## `BMF.server.planSettingsPatch(options)`

Validates and normalizes requested server settings:

```lua
local planned = BMF.server.planSettingsPatch({
  serverName = "BMF Canary Server",
  serverDescription = "A test server",
  maxPlayers = 42,
  publiclyListed = false,
  welcomeMessage = "Welcome from BMF",
})

if planned.ok then
  BMF.log("settings changes=" .. tostring(#planned.data.changes))
end
```

Supported keys:

- `serverName` or `name`
- `serverDescription` or `description`
- `password`
- `maxPlayers` or `players`
- `publiclyListed` or `public`
- `welcomeMessage`

Validation rejects unsupported control characters, multi-line values, invalid
booleans, and player caps outside `1..255`.

## File Patcher

Patch a copied `GameUserSettings.ini`:

```powershell
.\scripts\patch-server-settings.ps1 `
  -InputPath .\tests\fixtures\server\GameUserSettings.ini `
  -OutputPath .\artifacts\local\GameUserSettings.patched.ini `
  -ServerName "BMF Canary Server" `
  -MaxPlayers 42 `
  -PubliclyListed false `
  -WelcomeMessage "Welcome from BMF"
```

Validate both the fixture and the local Brickadia server config when present:

```powershell
.\scripts\validate-server-settings.ps1
```

The validator writes patched copies under an artifact directory. It does not
modify the live server config.

## Validation

- `L0 Static`: fixture patching and Lua input validation.
- `L2 Headless`: copied live `GameUserSettings.ini` patching, structured
  server status, `BMF.server.save` writing a parseable BRDB, and
  `BMF.server.shutdown` safely reporting the current unsupported executor path
  after confirmation.
- `L5 Negative`: plugin capability denial and config opt-in denial for
  unrestricted console execution, plus missing-confirmation denial for
  shutdown.
- `L3 Live Player`: proving the changed welcome message and player cap in a
  running server.
- Runtime hot-reload is still unknown; these settings may require restart.
