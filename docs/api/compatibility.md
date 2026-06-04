# Compatibility API

BMF currently targets Windows dedicated servers for Brickadia EA2
`PC-Shipping-CL13530` with the patched UE4SS runtime from the Brickadia
reverse-engineering workspace.

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
  by BMF timers and the file command worker.

Optional helper groups:

- `consoleCommandRegistration`: direct registration for `bmf.*` commands.
- `gameThread`: game-thread callback helpers.
- `objectLookup`: live-object lookup helpers for future discovery lanes.

## `BMF.compatibility.helpers()`

Returns only the helper diagnostics from `BMF.compatibility.check()`.

## `bmf.compatibility`

The console command prints stable key/value lines for automation:

```text
Omegga.Bridge.BMF bmf.compatibility
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

Validation:

- `L0 Static`: package contains the API, docs, and canary.
- `L2 Headless`: `scripts/validate-bmf-compatibility.ps1` checks API labels,
  command output, status JSON, health output, and helper availability without a
  connected player.
