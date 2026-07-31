# BMFFrameTelemetry Package Boundary

This package owns the optional native server frame-pacing and frame-time helper
in the unified runtime manifest. The current source remains split between the
C++ helper source and the deployable UE4SS mod folder:

```text
native/bmf_frame_telemetry
framework/ue4ss/Mods/BMFFrameTelemetry
```

The helper applies its Windows timer policy and Unreal frame target once at
startup; it does not poll for configuration. `BMF_FRAME_PACING_ENABLED` defaults
to enabled, while `BMF_FRAME_PACING_TARGET_FPS` defaults to `60` and is strictly
limited to `60` or `120`. The `120` target is explicit opt-in and must be
validated against live CPU and frame-time telemetry. Configuration changes need
a full Omegga/server restart.

Before calling the Unreal target setter, the helper calibrates the installed
named engine layout against UE4SS's independently scanned live `Tick` function,
requires exactly one matching vtable slot, and validates the native `t.MaxFPS`
getter/setter signatures. It fails closed without calling a candidate setter if
an update changes that structure; the independent Windows timer policy remains
active so the default 60 FPS background/minimized fix is preserved.

The helper writes low-rate schema-v2 pacing and frame-time data to
`Mods/BMF/runtime/frame-telemetry.json`. BMF Desktop observes the path, while
Grafana remains the dashboard for frame-time analysis. Pacing telemetry includes
the calibrated layout adjustment and native entry-signature result.

Validation: `scripts/validate-bmf-runtime-packages.ps1`.
