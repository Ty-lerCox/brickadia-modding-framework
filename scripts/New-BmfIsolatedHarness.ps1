[CmdletBinding()]
param(
  [string]$Root = '',
  [string]$BmfRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
  [string]$OmeggaSourceRoot = '',
  [string]$BrickadiaSourceRoot = '',
  [int]$UdpPort = 7799,
  [int]$MetricsPort = 28189,
  [string]$World = 'Plate'
)

$ErrorActionPreference = 'Stop'

function FullPath([string]$Value) {
  return [System.IO.Path]::GetFullPath($Value)
}

function Assert-UnboundPort([int]$Port) {
  $owner = Get-NetUDPEndpoint -LocalPort $Port -ErrorAction SilentlyContinue
  if ($owner) {
    throw "Refusing to create isolated harness: UDP port $Port is already owned by PID $($owner.OwningProcess)."
  }
}

if (!$Root) {
  $Root = Join-Path $env:TEMP ("bmf-phase0d-{0}" -f ([guid]::NewGuid().ToString('N').Substring(0, 12)))
}
if (!$OmeggaSourceRoot) {
  $OmeggaSourceRoot = Join-Path $BmfRoot 'packages\omegga-runtime\source'
}
if (!$BrickadiaSourceRoot) {
  $BrickadiaSourceRoot = Join-Path $env:APPDATA 'omegga\steam_installs\main'
}

$rootFull = FullPath $Root
$bmfFull = FullPath $BmfRoot
$omeggaSourceFull = FullPath $OmeggaSourceRoot
$brickadiaSourceFull = FullPath $BrickadiaSourceRoot
$installRoot = Join-Path $rootFull 'brickadia-isolated-install'
$gameRoot = Join-Path $installRoot 'Brickadia'
$win64Root = Join-Path $gameRoot 'Binaries\Win64'
$runtimeAlias = Split-Path $installRoot -Leaf
$ue4ssRoot = Join-Path $win64Root 'ue4ss'
$runtimeRoot = Join-Path $ue4ssRoot "$runtimeAlias\Mods\BMF\runtime"
$omeggaRoot = Join-Path $rootFull 'omegga-work'
$savedRoot = Join-Path $omeggaRoot 'data\Saved'
$pluginRoot = Join-Path $omeggaRoot 'plugins'
$logRoot = Join-Path $rootFull 'logs'
$telemetryRoot = Join-Path $rootFull 'telemetry'
$queueRoot = Join-Path $rootFull 'queues'
$manifestPath = Join-Path $rootFull 'isolated-harness-manifest.json'
$identityPath = Join-Path $rootFull 'isolated-runtime-identity.json'

Assert-UnboundPort $UdpPort
if (Test-Path -LiteralPath $rootFull) {
  throw "Harness destination already exists; refusing to overwrite it: $rootFull"
}
if (!(Test-Path -LiteralPath (Join-Path $brickadiaSourceFull 'Brickadia\Binaries\Win64\BrickadiaServer-Win64-Shipping.exe'))) {
  throw "Immutable Brickadia source is incomplete: $brickadiaSourceFull"
}
if (!(Test-Path -LiteralPath (Join-Path $omeggaSourceFull 'index.js'))) {
  throw "Omegga source root is incomplete: $omeggaSourceFull"
}

New-Item -ItemType Directory -Path $rootFull,$omeggaRoot,$savedRoot,$pluginRoot,$logRoot,$telemetryRoot,$queueRoot | Out-Null

# Copy only packaged Brickadia inputs. Generated UE4SS/runtime state and Omegga
# data are deliberately excluded. The destination is new, so no mirror/delete
# operation can affect an existing install.
$excludedDirs = @(
  (Join-Path $brickadiaSourceFull 'Brickadia\Binaries\Win64\ue4ss'),
  (Join-Path $brickadiaSourceFull 'Brickadia\Binaries\Win64\ue4ss-disabled'),
  (Join-Path $brickadiaSourceFull 'Brickadia\Binaries\Win64\Mods'),
  (Join-Path $brickadiaSourceFull 'Brickadia\Binaries\Win64\BMF-Backups'),
  (Join-Path $brickadiaSourceFull 'data')
)
$robocopyArgs = @(
  $brickadiaSourceFull,
  $installRoot,
  '/E',
  '/COPY:DAT',
  '/DCOPY:DAT',
  '/R:2',
  '/W:1',
  '/NFL',
  '/NDL',
  '/NJH',
  '/NJS',
  '/NP',
  '/XD'
) + $excludedDirs + @('/XF', 'dwmapi.dll', 'dwmapi.ue4ss-disabled.dll', '*.log', '*.pid')
& robocopy @robocopyArgs | Out-Null
if ($LASTEXITCODE -gt 7) {
  throw "Brickadia immutable-input copy failed with robocopy exit code $LASTEXITCODE."
}

$configText = @"
omegga:
  webui: false
  port: $MetricsPort
  https: false
server:
  port: $UdpPort
  map: $World
  savedDir: Saved
"@
[System.IO.File]::WriteAllText((Join-Path $omeggaRoot 'omegga-config.yml'), $configText, [System.Text.UTF8Encoding]::new($false))

foreach ($pluginName in @('bmf-bridge', 'bmf-player-sync')) {
  $source = Join-Path $bmfFull "packages\omegga-plugins\$pluginName"
  if (!(Test-Path -LiteralPath $source)) {
    throw "Required clean plugin source is missing: $source"
  }
  Copy-Item -LiteralPath $source -Destination (Join-Path $pluginRoot $pluginName) -Recurse
}

$prior = @{}
foreach ($name in @('BRICKADIA_DIR','OMEGGA_BMF_SOURCE_DIR','OMEGGA_UE4SS_SOURCE','OMEGGA_UE4SS_RE_ROOT','PACKAGE_NOTIFIER')) {
  $prior[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}
try {
  $env:BRICKADIA_DIR = $gameRoot
  $env:OMEGGA_BMF_SOURCE_DIR = $bmfFull
  $brickadiaRepoRoot = Join-Path (Split-Path $bmfFull -Parent) 'Brickadia'
  $env:OMEGGA_UE4SS_SOURCE = Join-Path $brickadiaRepoRoot 'zDEV-UE4SS_v3.0.1-940-g01e0a584'
  $env:OMEGGA_UE4SS_RE_ROOT = Join-Path $brickadiaRepoRoot 'brickadia-ue4ss-re'
  $env:PACKAGE_NOTIFIER = 'false'
  Push-Location $omeggaRoot
  try {
    & node (Join-Path $omeggaSourceFull 'index.js') ue4ss install
    if ($LASTEXITCODE -ne 0) {
      throw "Managed UE4SS provisioning failed with exit code $LASTEXITCODE."
    }
  } finally {
    Pop-Location
  }
} finally {
  foreach ($name in $prior.Keys) {
    [Environment]::SetEnvironmentVariable($name, $prior[$name], 'Process')
  }
}

if (!(Test-Path -LiteralPath (Join-Path $runtimeRoot '..\Scripts\bmf\runtime.lua'))) {
  throw "Provisioned runtime alias is not the expected isolated alias: $runtimeAlias"
}

# A provisioned runtime must still be clean before the first process starts.
New-Item -ItemType Directory -Force -Path $runtimeRoot | Out-Null
$generatedNames = @(
  'telemetry.json','frame-telemetry.json','status.json','bmf-player-sync-status.json',
  'bmf-bridge-status.json','socket.json','players.json','player-positions.json',
  'join-correlation.ndjson','frame-spike-context.ndjson'
)
foreach ($name in $generatedNames) {
  $candidate = Join-Path $runtimeRoot $name
  if (Test-Path -LiteralPath $candidate) {
    Remove-Item -LiteralPath $candidate -Force
  }
}
if (Get-ChildItem -LiteralPath $runtimeRoot -File -Filter '*.json' -ErrorAction SilentlyContinue) {
  throw "Generated JSON remained in the isolated BMF runtime before startup: $runtimeRoot"
}

$runtimeLua = Join-Path $runtimeRoot '..\Scripts\bmf\runtime.lua'
$runtimeHash = (Get-FileHash -LiteralPath $runtimeLua -Algorithm SHA256).Hash
$sourceExecutable = Join-Path $brickadiaSourceFull 'Brickadia\Binaries\Win64\BrickadiaServer-Win64-Shipping.exe'
$isolatedExecutable = Join-Path $win64Root 'BrickadiaServer-Win64-Shipping.exe'
$manifest = [ordered]@{
  schemaVersion = 1
  environment = 'isolated_test'
  createdAt = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  expectedBrickadiaRoot = $gameRoot
  expectedOmeggaRoot = $omeggaRoot
  expectedOmeggaSourceRoot = $omeggaSourceFull
  expectedUE4SSRoot = $ue4ssRoot
  expectedBMFRuntimeRoot = $runtimeRoot
  expectedSavedRoot = $savedRoot
  expectedPluginDataRoot = $pluginRoot
  expectedLogRoot = $logRoot
  expectedTelemetryRoot = $telemetryRoot
  expectedQueueRoot = $queueRoot
  expectedUdpPort = $UdpPort
  expectedMetricsPort = $MetricsPort
  expectedRuntimeHash = $runtimeHash
  expectedWorld = $World
  identityPath = $identityPath
  runtimeAlias = $runtimeAlias
  immutableInputs = [ordered]@{
    brickadiaSourceRoot = $brickadiaSourceFull
    sourceExecutableSha256 = (Get-FileHash -LiteralPath $sourceExecutable -Algorithm SHA256).Hash
    isolatedExecutableSha256 = (Get-FileHash -LiteralPath $isolatedExecutable -Algorithm SHA256).Hash
    bmfSourceRoot = $bmfFull
    omeggaSourceRoot = $omeggaSourceFull
  }
}
[System.IO.File]::WriteAllText(
  $manifestPath,
  (($manifest | ConvertTo-Json -Depth 6) + "`n"),
  [System.Text.UTF8Encoding]::new($false)
)

[pscustomobject]@{
  status = 'HARNESS_CREATED_NOT_STARTED'
  root = $rootFull
  manifestPath = $manifestPath
  identityPath = $identityPath
  brickadiaRoot = $gameRoot
  omeggaRoot = $omeggaRoot
  runtimeRoot = $runtimeRoot
  udpPort = $UdpPort
  metricsPort = $MetricsPort
  runtimeHash = $runtimeHash
  world = $World
} | ConvertTo-Json -Depth 4
