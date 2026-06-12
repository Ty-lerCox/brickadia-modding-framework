# Server Settings Patching

BMF server settings support is currently split between Lua planning and
file-backed patch tooling. It does not hot-change the live server yet.

**Labels:** `experimental`, `file-backed`, `L0 Static`, `L2 Headless`

## Who Should Read This?

Server operators should use this page to stage copied `GameUserSettings.ini`
changes. Plugin authors should use it when planning settings changes without
mutating live server state.

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

Settings patch proof is tracked in
[API Validation Evidence](../../validation/api-validation.md#server).
