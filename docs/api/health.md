# Health API

## Examples

- [HealthCheck](../examples/index.md#healthcheck): complete plugin that logs
  `BMF.health()`, `BMF.version`, and `BMF.compatibility.check()`.

## `BMF.health()`

Returns the standard BMF result shape:

```lua
{
  ok = true,
  code = "OK",
  message = "BMF runtime is loaded",
  data = {
    version = "0.1.0-dev",
    target_build = "PC-Shipping-CL13530",
    compatibility_status = "ok",
    build_detection = "declared-target-only",
    runtime_required_helper_groups = 2,
    runtime_required_helper_groups_available = 2,
    plugins_loaded = 0,
    plugin_errors = 0,
    status_path = "ue4ss/main/Mods/BMF/runtime/status.json",
    log_path = "ue4ss/main/Mods/BMF/runtime/bmf.log",
  },
}
```

Compatibility fields mirror `BMF.compatibility.check()` and are diagnostic.
Build detection is currently `declared-target-only`; unsupported-build refusal
is not enabled until a reliable runtime build source is proven.

`BMF.version` is the stable runtime version string. It is intentionally a string
field, not a function, so existing plugin code can use it directly:

```lua
BMF.log("BMF " .. tostring(BMF.version))
```

## Console Commands

`bmf.status` and `bmf.health` both print the health fields as deterministic
key/value lines. `bmf.version` prints the narrower package/build identity:

```text
Omegga.Bridge.BMF bmf.health
Omegga.Bridge.BMF bmf.version
```

`bmf.version` includes `version`, `target_build`, `target_name`, `platform`,
`server_executable`, `compatibility_status`, and `build_detection`.

Frame-time health is intentionally not inferred from `bmf.status` alone. Use
the Omegga `/metrics` exporter plus `BMFFrameTelemetry` for `L6 Frame Time`
validation; see [Observability and Performance](../architecture/observability-performance.md).

Validation levels:

- `L0 Static`: package contains the API.
- `L1 Boot`: `status.json` is written.
- `L2 Headless`: health and version commands can be inspected without a
  connected player.
- `L6 Frame Time`: native frame telemetry is readable and tested around the
  feature path when performance risk is part of the status decision.
