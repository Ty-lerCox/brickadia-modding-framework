# BMFFrameTelemetry

BMFFrameTelemetry is the optional UE4SS C++ server frame-pacing and frame-time
helper for BMF. It applies a guarded startup pacing policy, uses UE4SS engine
tick callbacks to aggregate Unreal `DeltaSeconds` values, and writes low-rate
JSON telemetry to:

```text
Mods/BMF/runtime/frame-telemetry.json
```

Build it with:

```powershell
.\scripts\build-bmf-frame-telemetry-native-mod.ps1 -Deploy
```

The deployed runtime DLL must exist at
`framework/ue4ss/Mods/BMFFrameTelemetry/dlls/main.dll` before Omegga enables
this mod in a managed server install.

## Frame pacing policy

Frame pacing is enabled by default. At startup, the helper makes a one-time
Windows process policy change so timer-resolution requests continue to be
honored, requests a `1 ms` timer period, and applies the configured Unreal frame
target once after the engine is available. It does not add a pacing poll loop.

Before calling the Unreal target setter, the helper calibrates the installed
named engine layout against UE4SS's independently scanned live `Tick` function,
requires exactly one matching vtable slot, and validates the native `t.MaxFPS`
getter/setter signatures. It fails closed without calling a candidate setter if
an update changes that structure; the independent Windows timer policy remains
active so the default 60 FPS background/minimized fix is preserved.

Configuration is intentionally restricted:

- `BMF_FRAME_PACING_ENABLED` defaults to enabled. Set it to `0`, `false`, `off`,
  or `no` to skip both the Windows timer policy and the Unreal target override.
- `BMF_FRAME_PACING_TARGET_FPS` defaults to `60` and accepts only `60` or `120`.
  An invalid value falls back to `60` and is reported as invalid in telemetry.

These variables are read only when the native process starts. Set them in the
Omegga launch environment or `.env` before starting Omegga, then perform a full
Omegga/server restart for a change to take effect.

The `120` setting is a target, not a guarantee. It can nearly double tick,
game-thread, CPU, and networking work compared with `60`; use the observed FPS,
frame-time, and slow-frame metrics to confirm that the server workload can
sustain it. The default `60` target is the conservative production setting.

Frame-time sampling is configured independently. The sampler can be disabled
with `BMF_FRAME_TELEMETRY_ENABLED=0`, and its output path can be overridden with
`BMF_FRAME_TELEMETRY_PATH`.

## Output

The JSON uses schema version `2` and contains:

- `hook_registered`: whether the engine tick callback registered.
- `pacing`: the configured target and one-time policy state, including
  `enabled`, `config_valid`, `target_fps`, `target_override_attempted`,
  `target_override_applied`, `target_override_result`, `target_exception_code`,
  `layout_calibrated`, `layout_adjustment_bytes`, `entry_signatures_valid`,
  `previous_max_fps`, `previous_max_tick_rate`, `observed_max_fps`,
  `observed_max_tick_rate`, `timer_policy_attempted`, `timer_policy_applied`,
  `timer_policy_error`, `timer_resolution_ms`,
  `timer_resolution_request_succeeded`, and `timer_resolution_result`.
- `window`: low-rate rolling-window samples, idle samples, average/max/last
  frame delta, FPS estimate, and slow-frame counts.
- `lifetime`: lifetime samples, idle samples, average/max/last frame delta, and
  slow-frame totals.
- `spikes`: recent frames over the `100 ms` spike threshold.

The supported Omegga fork exports this file to Prometheus metrics:

```text
brickadia_frame_telemetry_up
brickadia_frame_telemetry_hook_registered
brickadia_frame_telemetry_schema_version
brickadia_frame_pacing_enabled
brickadia_frame_pacing_config_valid
brickadia_frame_pacing_target_fps
brickadia_frame_pacing_target_override_attempted
brickadia_frame_pacing_target_override_applied
brickadia_frame_pacing_layout_calibrated
brickadia_frame_pacing_layout_adjustment_bytes
brickadia_frame_pacing_entry_signatures_valid
brickadia_frame_pacing_observed_max_fps
brickadia_frame_pacing_observed_max_tick_rate
brickadia_frame_pacing_timer_policy_applied
brickadia_frame_pacing_timer_resolution_request_succeeded
brickadia_frame_delta_milliseconds{scope="window",statistic="avg"}
brickadia_frame_delta_milliseconds{scope="window",statistic="max"}
brickadia_frame_fps{scope="window",statistic="avg"}
brickadia_frame_slow_total{threshold_ms}
brickadia_frame_spikes_total{threshold_ms="100"}
brickadia_frame_spike_last_delta_milliseconds
brickadia_frame_spike_last_age_seconds
```

Treat `brickadia_frame_pacing_target_fps` as the requested target and
`brickadia_frame_fps` as the measured result. Use max frame delta and slow-frame
counters to diagnose visible hitches. Average frame time can look acceptable
while repeated `100+ ms` spikes are still player-visible.
