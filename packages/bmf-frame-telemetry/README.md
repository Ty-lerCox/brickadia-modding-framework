# BMFFrameTelemetry Package Boundary

This package owns the optional frame telemetry native helper in the unified
runtime manifest. The current source remains split between the C++ helper source
and the deployable UE4SS mod folder:

```text
native/bmf_frame_telemetry
framework/ue4ss/Mods/BMFFrameTelemetry
```

The helper writes low-rate frame-time data to
`Mods/BMF/runtime/frame-telemetry.json`; BMF Desktop only configures and checks
the path, while Grafana remains the dashboard for frame-time analysis.

Validation: `scripts/validate-bmf-runtime-packages.ps1`.
