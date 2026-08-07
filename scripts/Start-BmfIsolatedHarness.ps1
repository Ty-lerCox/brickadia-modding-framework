[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$ManifestPath,
  [string]$BmfRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
)

$ErrorActionPreference = 'Stop'
$manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
$endpoint = Get-NetUDPEndpoint -LocalPort ([int]$manifest.expectedUdpPort) -ErrorAction SilentlyContinue
if ($endpoint) { throw "Isolated UDP port is already owned by PID $($endpoint.OwningProcess)." }
if (Test-Path -LiteralPath $manifest.identityPath) { throw 'Identity already exists; create a new harness instead of reusing process identity.' }
$omeggaIndex = Join-Path $manifest.expectedOmeggaSourceRoot 'index.js'
if (!(Test-Path -LiteralPath $omeggaIndex)) { throw "Omegga index is missing: $omeggaIndex" }

$statusPath = Join-Path $manifest.expectedBMFRuntimeRoot 'status.json'
$telemetryPath = Join-Path $manifest.expectedBMFRuntimeRoot 'telemetry.json'
$framePath = Join-Path $manifest.expectedBMFRuntimeRoot 'frame-telemetry.json'
$dataRoot = Join-Path $manifest.expectedOmeggaRoot 'data'
$brickadiaRepoRoot = Join-Path (Split-Path ([System.IO.Path]::GetFullPath($BmfRoot)) -Parent) 'Brickadia'
$environment = [ordered]@{
  BRICKADIA_DIR = [string]$manifest.expectedBrickadiaRoot
  OMEGGA_BMF_SOURCE_DIR = [System.IO.Path]::GetFullPath($BmfRoot)
  OMEGGA_UE4SS_SOURCE = Join-Path $brickadiaRepoRoot 'zDEV-UE4SS_v3.0.1-940-g01e0a584'
  OMEGGA_UE4SS_RE_ROOT = Join-Path $brickadiaRepoRoot 'brickadia-ue4ss-re'
  OMEGGA_WINDOWS_BACKEND = 'ue4ss'
  OMEGGA_UE4SS_ALLOW_STAGED_OBJECT_CONTROL = '1'
  OMEGGA_UE4SS_NOOP_UNSAFE_CONSOLE_COMMANDS = '1'
  OMEGGA_UE4SS_ALLOW_UNSAFE_PLAYERS_LIST = '0'
  OMEGGA_UE4SS_PLAYER_COMPAT_USE_GAME_OBJECTS = '0'
  OMEGGA_UE4SS_PLAYER_COMPAT_USE_FINDALL = '0'
  OMEGGA_UE4SS_ALLOW_UNSAFE_PLAYER_LOCATION = '0'
  OMEGGA_UE4SS_PLAYER_LOCATION_USE_LUA_UOBJECTS = '0'
  OMEGGA_RAW_STDIN_COMMAND_FILE = Join-Path $dataRoot 'isolated-raw-stdin-command.txt'
  OMEGGA_RAW_STDIN_RESULT_FILE = Join-Path $dataRoot 'isolated-raw-stdin-result.json'
  OMEGGA_CONTROL_COMMAND_FILE = Join-Path $dataRoot 'isolated-control-command.txt'
  OMEGGA_CONTROL_RESULT_FILE = Join-Path $dataRoot 'isolated-control-result.json'
  OMEGGA_BMF_SOCKET_ENABLED = '1'
  OMEGGA_BMF_SOCKET_POLL_MS = '25'
  OMEGGA_BMF_SOCKET_BOUNDED_ADMISSION_ENABLED = '1'
  OMEGGA_BMF_SOCKET_MAX_PENDING_COMMANDS = '64'
  OMEGGA_BMF_SOCKET_MAX_CLIENT_BUFFER_BYTES = '262144'
  OMEGGA_BMF_BRIDGE_MAX_PENDING_COMMANDS = '64'
  OMEGGA_BMF_BRIDGE_MAX_BUFFER_BYTES = '262144'
  OMEGGA_BMF_BRIDGE_MAX_COMMAND_BYTES = '65536'
  OMEGGA_BMF_RUNTIME_DIR = [string]$manifest.expectedBMFRuntimeRoot
  OMEGGA_BMF_STATUS_PATH = $statusPath
  OMEGGA_BMF_TELEMETRY_PATH = $telemetryPath
  OMEGGA_BMF_FRAME_TELEMETRY_PATH = $framePath
  OMEGGA_BMF_JOIN_CORRELATION_DIR = [string]$manifest.expectedTelemetryRoot
  OMEGGA_BMF_JOIN_HITCH_ATTRIBUTION_ENABLED = '1'
  OMEGGA_BMF_JOIN_RECONCILIATION_ENABLED = '1'
  OMEGGA_BMF_PLAYER_CONNECTION_GENERATION_ENABLED = '1'
  OMEGGA_BMF_PLAYER_CACHE_PATH = Join-Path $manifest.expectedBMFRuntimeRoot 'players.json'
  OMEGGA_BMF_PLAYER_SYNC_COMMAND_BRIDGE = '1'
  OMEGGA_BMF_PLAYER_SYNC_INTERVAL_MS = '0'
  OMEGGA_BMF_PLAYER_SYNC_POSITIONS = '0'
  OMEGGA_BMF_PLAYER_SYNC_MAX_COMMAND_BYTES = '65536'
  BMF_PROVENANCE_IDENTITY_PATH = [string]$manifest.identityPath
  BMF_BRICKADIA_SAVED_DIR = [string]$manifest.expectedSavedRoot
  BMF_FRAME_TELEMETRY_PATH = $framePath
  BMF_FRAME_TELEMETRY_ENABLED = '1'
  BMF_FRAME_HITCH_ATTRIBUTION_ENABLED = '1'
  BMF_FRAME_RECENT_SAMPLES_ENABLED = '1'
  BMF_FRAME_PACING_TARGET_FPS = '60'
  BMF_COMMAND_WORKER_ENABLED = '0'
  BMF_COMMAND_WORKER_ASYNC = '0'
  BMF_ALLOW_LOOPASYNC = '0'
  BMF_ALLOW_GAME_THREAD_LOOP = '0'
  BMF_ALLOW_DELAYED_WORKER_FALLBACK = '1'
  BMF_SOCKET_WORKER_WATCHDOG = '0'
  BMF_GAME_COMMAND_TUNNEL_ENABLED = '1'
  BMF_GAME_COMMAND_TUNNEL_PERSISTENT_PUMP = '1'
  BMF_GAME_COMMAND_TUNNEL_INTERVAL_MS = '25'
  BMF_GAME_COMMAND_TUNNEL_INGRESS_PER_TICK = '2'
  BMF_DIRECT_SOCKET_INGRESS_CAP_ENABLED = '1'
  BMF_DIRECT_SOCKET_INGRESS_PER_PUMP = '2'
  BMF_GAME_THREAD_PUMP_BUDGET_ENFORCED = '1'
  BMF_GAME_THREAD_PUMP_BUDGET_MS = '3'
  BMF_UNIFIED_SOCKET_ADMISSION_ENABLED = '0'
  BMF_PLAYER_REGISTRY_CACHE_FIRST_ENABLED = '1'
  BMF_PLAYER_REGISTRY_REPAIR_ENABLED = '1'
  BMF_PLAYER_REGISTRY_LEGACY_DISCOVERY_ENABLED = '0'
  PACKAGE_NOTIFIER = 'false'
}

$prior = @{}
foreach ($entry in $environment.GetEnumerator()) {
  $prior[$entry.Key] = [Environment]::GetEnvironmentVariable($entry.Key, 'Process')
  [Environment]::SetEnvironmentVariable($entry.Key, [string]$entry.Value, 'Process')
}
try {
  $stdoutPath = Join-Path $manifest.expectedLogRoot 'omegga.stdout.log'
  $stderrPath = Join-Path $manifest.expectedLogRoot 'omegga.stderr.log'
  $process = Start-Process -FilePath 'node' -ArgumentList @('--enable-source-maps', $omeggaIndex, '--verbose') -WorkingDirectory $manifest.expectedOmeggaRoot -WindowStyle Hidden -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath -PassThru
} finally {
  foreach ($entry in $environment.GetEnumerator()) {
    [Environment]::SetEnvironmentVariable($entry.Key, $prior[$entry.Key], 'Process')
  }
}
$pidPath = Join-Path (Split-Path $ManifestPath -Parent) 'omegga.pid'
[System.IO.File]::WriteAllText($pidPath, "$($process.Id)`n", [System.Text.UTF8Encoding]::new($false))
$deadline = (Get-Date).AddSeconds(20)
$endpoint = $null
do {
  Start-Sleep -Milliseconds 250
  if ($process.HasExited) {
    throw "Isolated Omegga exited during startup with code $($process.ExitCode). See $stderrPath"
  }
  $endpoint = Get-NetUDPEndpoint -LocalPort ([int]$manifest.expectedUdpPort) -ErrorAction SilentlyContinue
} while (!$endpoint -and (Get-Date) -lt $deadline)
if (!$endpoint) {
  throw "Isolated Brickadia did not bind UDP port $($manifest.expectedUdpPort) within 20 seconds."
}
& (Join-Path $PSScriptRoot 'Write-BmfIsolatedRuntimeIdentity.ps1') -ManifestPath $ManifestPath -OmeggaPid $process.Id | Out-Null
[pscustomobject]@{
  status = 'ISOLATED_OMEGGA_STARTED'
  omeggaPid = $process.Id
  brickadiaPid = [int]$endpoint.OwningProcess
  udpPort = [int]$manifest.expectedUdpPort
  stdoutPath = $stdoutPath
  stderrPath = $stderrPath
  pidPath = $pidPath
} | ConvertTo-Json -Depth 4
