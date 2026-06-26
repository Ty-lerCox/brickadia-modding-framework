# Rate Limits API

**Labels:** `stable`, `L2 Headless`, `L5 Negative`

## Who Should Read This?

Plugin authors should use this page before adding spam-prone or dangerous commands. Maintainers should use it when changing default protected actions.

BMF includes lightweight per-subject rate limits for dangerous or spam-prone
actions.

Built-in protected actions currently include:

- `server.exec`
- `server.save`
- `server.shutdown`
- `world.loadAdditive`
- `world.saveAs`
- `chat.broadcast`
- `chat.whisper`
- `chat.statusMessage`

Plugins are counted under `plugin:<PluginName>`. Framework/admin command calls
are counted separately under `framework`.

## Examples

- [RateLimitedCommand](../examples/rate-limited-command.md): complete
  plugin command guarded by `BMF.rateLimits.check`.

Plugins can use custom limits for their own features:

```lua
local first = BMF.rateLimits.check("myplugin.spawn", {
  limit = 1,
  windowSeconds = 60,
})
```

When a limit is exceeded, BMF returns:

```lua
{
  ok = false,
  code = "RATE_LIMITED",
  data = {
    action = "myplugin.spawn",
    subject = "plugin:Example",
    retryAfterSeconds = 42
  }
}
```

Rate-limit denials are written to `runtime/audit.jsonl` as
`rate_limit.denied`.

Server-console command route:

```text
bmf.ratelimits
```

## Validation

Rate-limit proof is tracked in
[API Validation Evidence](../validation/api-validation.md#framework-utilities).
