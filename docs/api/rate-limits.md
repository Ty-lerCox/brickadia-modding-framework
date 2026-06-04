# Rate Limits API

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
Omegga.Bridge.BMF bmf.ratelimits
```

## Validation

- `L0 Static`: package validator checks rate-limit API markers, docs, and
  canary.
- `L2 Headless + L5 Negative`: `scripts/validate-bmf-rate-limits.ps1` loads a
  temporary plugin, proves a custom one-per-window limit denies the second call,
  proves default `chat.whisper` rate limiting denies the 21st plugin call, then
  verifies `bmf.ratelimits`, `bmf.audit.tail`, `audit.jsonl`, and runtime status
  evidence.
