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
