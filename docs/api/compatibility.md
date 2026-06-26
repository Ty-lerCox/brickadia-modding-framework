# Compatibility API

**Labels:** `diagnostic`, `L0 Static`, `L2 Headless`

## Who Should Read This?

Server operators should use this page to confirm the supported Brickadia build and UE4SS helper assumptions. Maintainers should use it when changing build gates.

BMF currently targets Windows dedicated servers for Brickadia EA2
`PC-Shipping-CL13530` with the patched UE4SS runtime from the Brickadia
reverse-engineering workspace.

## Examples

- [HealthCheck](../examples/health-check.md): complete plugin that logs
  compatibility status with runtime health.

## `BMF.compatibility.check()`

Returns the standard BMF result shape with build target metadata and runtime
helper diagnostics:

```lua
local compatibility = BMF.compatibility.check()
if compatibility.ok then
  BMF.log("target=" .. compatibility.data.targetBuild)
end
```

Important fields:

- `targetBuild`: `PC-Shipping-CL13530`
- `platform`: `windows-dedicated-server`
- `serverExecutable`: `BrickadiaServer-Win64-Shipping.exe`
- `buildDetection`: `declared-target-only`
- `unsupportedBuildPolicy`: `report-only`
- `ue4ss.helperGroups`: required and optional helper groups

Required helper groups:

- `consoleExecutor`: at least one supported Omegga/UE4SS console executor.
- `timerScheduler`: `ExecuteWithDelay` or `ExecuteInGameThreadWithDelay`, used
  by BMF timers and legacy opt-in validation workers.

Optional helper groups:

- `consoleCommandRegistration`: direct registration for `bmf.*` commands.
- `gameThread`: game-thread callback helpers.
- `objectLookup`: live-object lookup helpers for future discovery lanes.

## `BMF.compatibility.helpers()`

Returns only the helper diagnostics from `BMF.compatibility.check()`.

## `bmf.compatibility`

The console command prints stable key/value lines for automation:

```text
bmf.compatibility
```

Example lines:

```text
compatibility_status=ok
target_build=PC-Shipping-CL13530
build_detection=declared-target-only
unsupported_build_policy=report-only
required_helper_groups=2
required_helper_groups_available=2
helper_consoleExecutor_available=true
helper_timerScheduler_available=true
```

## Limitations

BMF does not yet prove a reliable in-runtime Brickadia build ID source, so it
does not refuse unknown future builds. Unsupported-build handling is currently
diagnostic/report-only. A later compatibility gate should switch this to
refuse-by-default once runtime build detection is proven.

Validation proof is tracked in
[API Validation Evidence](../validation/api-validation.md#framework-utilities).
