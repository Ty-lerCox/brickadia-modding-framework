param(
  [string]$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
  [string]$OutJson = ''
)

$ErrorActionPreference = 'Stop'

if (!$OutJson) {
  $OutJson = Join-Path $Root 'artifacts/local/bmf-runtime-packages-validation.json'
}

$errors = New-Object System.Collections.Generic.List[string]
$evidence = New-Object System.Collections.Generic.List[object]
$startedAt = (Get-Date).ToUniversalTime().ToString('o')

function Add-Evidence([string]$Kind, [string]$Path, [string]$Summary) {
  if ($Path -and (Test-Path -LiteralPath $Path)) {
    $script:evidence.Add([ordered]@{
      kind = $Kind
      path = [System.IO.Path]::GetFullPath($Path)
      summary = $Summary
    })
  }
}

function Read-JsonFile([string]$Path) {
  try {
    return Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json
  } catch {
    $script:errors.Add("Invalid JSON in $Path`: $($_.Exception.Message)")
    return $null
  }
}

function Test-TextMarkers([string]$Path, [string[]]$Markers, [string]$Name) {
  if (!(Test-Path -LiteralPath $Path)) {
    $script:errors.Add("$Name marker source is missing: $Path")
    return
  }
  $source = Get-Content -Raw -LiteralPath $Path
  foreach ($needle in $Markers) {
    if ($source -notmatch [regex]::Escape($needle)) {
      $script:errors.Add("$Name marker source does not contain expected marker: $needle")
    }
  }
  Add-Evidence 'source' $Path "$Name marker source"
}

function Test-RuntimePackage(
  [string]$Name,
  [string]$ComponentId,
  [string]$PackageRoot,
  [string[]]$RequiredGuardrails,
  [object]$ManifestComponent
) {
  $packageRootPath = Join-Path $Root $PackageRoot
  $manifestPath = Join-Path $packageRootPath 'package-manifest.json'
  $readmePath = Join-Path $packageRootPath 'README.md'

  foreach ($path in @($manifestPath, $readmePath)) {
    if (!(Test-Path -LiteralPath $path)) {
      $script:errors.Add("Missing $Name package file: $path")
    } else {
      Add-Evidence 'file' $path "$Name package boundary file"
    }
  }

  $packageManifest = $null
  if (Test-Path -LiteralPath $manifestPath) {
    $packageManifest = Read-JsonFile $manifestPath
  }
  if (!$packageManifest) {
    return
  }

  if ([string]$packageManifest.componentId -ne $ComponentId) {
    $script:errors.Add("$Name package componentId must be $ComponentId.")
  }
  if ([string]$packageManifest.owner -ne $PackageRoot) {
    $script:errors.Add("$Name package owner must be $PackageRoot.")
  }
  foreach ($guardrail in $RequiredGuardrails) {
    if ($guardrail -notin @($packageManifest.guardrails)) {
      $script:errors.Add("$Name package guardrails are missing: $guardrail")
    }
  }
  foreach ($relative in @($packageManifest.sourceRoots)) {
    $path = Join-Path $Root ([string]$relative)
    if (!(Test-Path -LiteralPath $path)) {
      $script:errors.Add("$Name source root does not exist: $relative")
    } else {
      Add-Evidence 'source-root' $path "$Name source root"
    }
  }
  foreach ($relative in @($packageManifest.requiredFiles)) {
    $path = Join-Path $Root ([string]$relative)
    if (!(Test-Path -LiteralPath $path)) {
      $script:errors.Add("$Name required file does not exist: $relative")
    } else {
      Add-Evidence 'required-file' $path "$Name required file"
    }
  }

  if ($ManifestComponent) {
    if ([string]$ManifestComponent.owner -ne $PackageRoot) {
      $script:errors.Add("Unified runtime manifest owner for $ComponentId must be $PackageRoot.")
    }
    if ([string]$ManifestComponent.source -ne $PackageRoot) {
      $script:errors.Add("Unified runtime manifest source for $ComponentId must be $PackageRoot.")
    }
  }
}

try {
  $unifiedManifestPath = Join-Path $Root 'manifests/unified-runtime.json'
  $unifiedManifest = $null
  if (Test-Path -LiteralPath $unifiedManifestPath) {
    $unifiedManifest = Read-JsonFile $unifiedManifestPath
    Add-Evidence 'json' $unifiedManifestPath 'Unified runtime manifest'
  } else {
    $errors.Add('Unified runtime manifest is missing.')
  }

  function Get-Component([string]$Id) {
    foreach ($component in @($unifiedManifest.components)) {
      if ([string]$component.id -eq $Id) {
        return $component
      }
    }
    return $null
  }

  Test-RuntimePackage `
    -Name 'BMF runtime' `
    -ComponentId 'bmf-runtime' `
    -PackageRoot 'packages/bmf-runtime' `
    -RequiredGuardrails @('keep-current-install-path', 'stage-through-orchestrator-core', 'keep-omegga-template-byte-identical', 'no-async-lua-scheduler-callbacks', 'no-global-delayed-action-clears', 'detect-forbidden-scheduler-aliases', 'lua-5.3-compile-before-package') `
    -ManifestComponent (Get-Component 'bmf-runtime')

  Test-RuntimePackage `
    -Name 'BMFSocket' `
    -ComponentId 'bmf-native-socket' `
    -PackageRoot 'packages/bmf-native-socket' `
    -RequiredGuardrails @('required-live-transport', 'report-socket-unavailable-instead-of-file-fallback') `
    -ManifestComponent (Get-Component 'bmf-native-socket')

  Test-RuntimePackage `
    -Name 'BMFFrameTelemetry' `
    -ComponentId 'bmf-frame-telemetry' `
    -PackageRoot 'packages/bmf-frame-telemetry' `
    -RequiredGuardrails @('optional-native-telemetry', 'low-rate-json-output', 'one-time-process-timer-policy', 'target-fps-allowlist', '120-fps-explicit-opt-in', 'calibrated-layout-fail-closed', 'no-pacing-poll-loop') `
    -ManifestComponent (Get-Component 'bmf-frame-telemetry')

  Test-TextMarkers `
    -Path (Join-Path $Root 'framework/ue4ss/Mods/BMF/Scripts/main.lua') `
    -Name 'BMF runtime loader' `
    -Markers @('runtime_candidates', 'Scripts/bmf/runtime.lua', 'loadfile')

  Test-TextMarkers `
    -Path (Join-Path $Root 'framework/ue4ss/Mods/BMF/Scripts/bmf/runtime.lua') `
    -Name 'BMF runtime implementation' `
    -Markers @('local STATUS_PATH = RUNTIME_DIR .. "/status.json"', 'local EVENT_LOG_PATH = RUNTIME_DIR .. "/events.jsonl"', 'BMF_command_worker_enabled', 'BMF.commands.register')

  Test-TextMarkers `
    -Path (Join-Path $Root 'native/bmf_socket/CMakeLists.txt') `
    -Name 'BMFSocket CMake' `
    -Markers @('set(TARGET BMFSocket)', 'add_library(${TARGET} SHARED bmf_socket.cpp)', 'ws2_32')

  Test-TextMarkers `
    -Path (Join-Path $Root 'native/bmf_socket/bmf_socket.cpp') `
    -Name 'BMFSocket transport-only fail-closed policy' `
    -Markers @('socket_transport_only_enabled', 'BMF_SOCKET_TRANSPORT_ONLY', 'BMF_SOCKET_NATIVE_HELPERS_ENABLED', 'BMF_SOCKET_GAME_COMMAND_TUNNEL_HELPERS_ENABLED', 'validate_game_command_tunnel_native_target', 'kGameCommandTunnelCl15648ExecRva', 'lua_socket_describe_uobject_identity', 'lua_socket_describe_player_controller_binding', 'transport-only mode enabled; bounded UObject identity and exact player-controller binding are available; native scanners, writers, and hooks are unavailable')

  Test-TextMarkers `
    -Path (Join-Path $Root 'framework/ue4ss/Mods/BMFSocket/README.md') `
    -Name 'BMFSocket README' `
    -Markers @('BMFSocket is the optional UE4SS C++ transport mod', 'report the socket path as unavailable', 'defaults to transport-only mode', 'BMF_SOCKET_GAME_COMMAND_TUNNEL_HELPERS_ENABLED=1', 'BMF_SOCKET_NATIVE_HELPERS_ENABLED=1')

  Test-TextMarkers `
    -Path (Join-Path $Root 'native/bmf_frame_telemetry/CMakeLists.txt') `
    -Name 'BMFFrameTelemetry CMake' `
    -Markers @('set(TARGET BMFFrameTelemetry)', 'add_library(${TARGET} SHARED bmf_frame_telemetry.cpp)', 'winmm')

  Test-TextMarkers `
    -Path (Join-Path $Root 'native/bmf_frame_telemetry/bmf_frame_telemetry.cpp') `
    -Name 'BMFFrameTelemetry pacing policy' `
    -Markers @('BMF_FRAME_PACING_ENABLED', 'BMF_FRAME_PACING_TARGET_FPS', '(parsed == 60 || parsed == 120)', 'SetProcessInformation', 'PROCESS_POWER_THROTTLING_IGNORE_TIMER_RESOLUTION', 'timeBeginPeriod', 'timeEndPeriod', 'RegisterEngineTickPreCallback', 'apply_target_once', 'TickInternal.get_function_address', 'matches_current_get_max_tick_rate', 'matches_current_get_max_fps', 'matches_current_set_max_fps', 'layout_calibrated', 'SetMaxFPS', 'schema_version\":2', '\"pacing\":')

  Test-TextMarkers `
    -Path (Join-Path $Root 'framework/ue4ss/Mods/BMFFrameTelemetry/README.md') `
    -Name 'BMFFrameTelemetry README' `
    -Markers @('DeltaSeconds', 'Mods/BMF/runtime/frame-telemetry.json', 'BMF_FRAME_PACING_ENABLED', 'BMF_FRAME_PACING_TARGET_FPS', 'schema version `2`', 'Omegga/server restart', 'brickadia_frame_pacing_target_fps', 'brickadia_frame_pacing_layout_calibrated', 'brickadia_frame_pacing_layout_adjustment_bytes', 'brickadia_frame_pacing_entry_signatures_valid', 'brickadia_frame_pacing_timer_policy_applied', 'brickadia_frame_pacing_timer_resolution_request_succeeded', 'brickadia_frame_delta_milliseconds')
} catch {
  $errors.Add($_.Exception.Message)
}

$result = [ordered]@{
  feature = 'bmf.runtime-packages'
  status = if ($errors.Count -eq 0) { 'passed' } else { 'failed' }
  validationLevel = 'L0 Static'
  startedAt = $startedAt
  finishedAt = (Get-Date).ToUniversalTime().ToString('o')
  data = [ordered]@{
    packageRoots = @(
      [System.IO.Path]::GetFullPath((Join-Path $Root 'packages/bmf-runtime')),
      [System.IO.Path]::GetFullPath((Join-Path $Root 'packages/bmf-native-socket')),
      [System.IO.Path]::GetFullPath((Join-Path $Root 'packages/bmf-frame-telemetry'))
    )
  }
  evidence = $evidence.ToArray()
  errors = $errors.ToArray()
}

$json = $result | ConvertTo-Json -Depth 10
$outPath = [System.IO.Path]::GetFullPath($OutJson)
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $outPath) | Out-Null
Set-Content -LiteralPath $outPath -Value $json -Encoding UTF8
Write-Output $json

if ($errors.Count -ne 0) {
  exit 1
}
