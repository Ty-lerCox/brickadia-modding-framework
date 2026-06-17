# BMFFrameTelemetry

BMFFrameTelemetry is the optional UE4SS C++ frame-time sampler for BMF. It uses
UE4SS engine tick callbacks to aggregate Unreal `DeltaSeconds` values and writes
low-rate JSON telemetry to:

```text
Mods/BMF/runtime/frame-telemetry.json
```

Build it with:

```powershell
.\scripts\build-bmf-frame-telemetry-native-mod.ps1 -Deploy
```

The deployed runtime DLL must exist at
`framework/ue4ss/Mods/BMFFrameTelemetry/dlls/main.dll` before Omegga enables
this mod in a managed server install. The sampler can be disabled with
`BMF_FRAME_TELEMETRY_ENABLED=0`, and the output path can be overridden with
`BMF_FRAME_TELEMETRY_PATH`.

## Output

The JSON contains:

- `hook_registered`: whether the engine tick callback registered.
- `window`: low-rate rolling-window samples, idle samples, average/max/last
  frame delta, FPS estimate, and slow-frame counts.
- `lifetime`: lifetime samples, idle samples, average/max/last frame delta, and
  slow-frame totals.
- `spikes`: recent frames over the `100 ms` spike threshold.

The supported Omegga fork exports this file to Prometheus metrics:

```text
brickadia_frame_telemetry_up
brickadia_frame_telemetry_hook_registered
brickadia_frame_delta_milliseconds{scope="window",statistic="avg"}
brickadia_frame_delta_milliseconds{scope="window",statistic="max"}
brickadia_frame_fps{scope="window",statistic="avg"}
brickadia_frame_slow_total{threshold_ms}
brickadia_frame_spikes_total{threshold_ms="100"}
brickadia_frame_spike_last_delta_milliseconds
brickadia_frame_spike_last_age_seconds
```

Use max frame delta and slow-frame counters to diagnose visible hitches. Average
frame time can look acceptable while repeated `100+ ms` spikes are still
player-visible.
