# Plugin Storage

`BMF.storage` keeps plugin config and state writes inside the current plugin
folder. Path traversal and absolute paths are rejected.

**Labels:** `stable`, `capability-gated`, `L2 Headless`, `L5 Negative`

## Who Should Read This?

Plugin authors should use this page for plugin-scoped config and state files.
Maintainers should use it when changing storage isolation or JSON error
handling.

## Capability

Storage helpers require `plugins.storage`.

```json
{
  "name": "StorageExample",
  "version": "1.0.0",
  "capabilities": ["plugins.storage"]
}
```

## Helpers

```lua
BMF.storage.writeConfigText([[{"enabled":true}]])
BMF.storage.writeConfig({ enabled = true, maxCount = 5 })
BMF.storage.writeText("state/count.txt", "1")
BMF.storage.writeJson("state/profile.json", {
  name = "LifecycleStorageCanary",
  score = 42,
})

local config = BMF.storage.readConfigText()
local parsedConfig = BMF.storage.readConfig()
local count = BMF.storage.readText("state/count.txt")
local profile = BMF.storage.readJson("state/profile.json")
```

Available helpers:

- `BMF.storage.readConfigText()`
- `BMF.storage.writeConfigText(text)`
- `BMF.storage.readConfig()`
- `BMF.storage.writeConfig(table)`
- `BMF.storage.readText(relativePath)`
- `BMF.storage.writeText(relativePath, text)`
- `BMF.storage.appendText(relativePath, text)`
- `BMF.storage.readJson(relativePath)`
- `BMF.storage.writeJson(relativePath, table)`

The legacy explicit-plugin forms still work when the plugin name matches the
current plugin:

- `BMF.storage.readConfigText(pluginName)`
- `BMF.storage.writeConfigText(pluginName, text)`
- `BMF.storage.readConfig(pluginName)`
- `BMF.storage.writeConfig(pluginName, table)`
- `BMF.storage.readText(pluginName, relativePath)`
- `BMF.storage.writeText(pluginName, relativePath, text)`
- `BMF.storage.appendText(pluginName, relativePath, text)`
- `BMF.storage.readJson(pluginName, relativePath)`
- `BMF.storage.writeJson(pluginName, relativePath, table)`

Malformed JSON returns `JSON_PARSE_FAILED` instead of throwing, so plugins can
recover from a bad config file.
