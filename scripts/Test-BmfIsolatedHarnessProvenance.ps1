[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$ManifestPath,
  [string[]]$DocumentPath = @(),
  [int]$ProductionBrickadiaPid = 0,
  [int]$ProductionUdpPort = 7777,
  [string]$ProductionRuntimeRoot = '',
  [string]$ProductionRuntimeHash = ''
)

$ErrorActionPreference = 'Stop'
$errors = [System.Collections.Generic.List[string]]::new()
$manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
$identity = Get-Content -LiteralPath $manifest.identityPath -Raw | ConvertFrom-Json

function EqualPath([string]$Left, [string]$Right) {
  return [System.IO.Path]::GetFullPath($Left).TrimEnd('\') -eq [System.IO.Path]::GetFullPath($Right).TrimEnd('\')
}

if ($identity.environment -ne 'isolated_test') { $errors.Add('identity environment is not isolated_test') }
if ([int]$identity.udpPort -ne [int]$manifest.expectedUdpPort) { $errors.Add('identity UDP port differs from manifest') }
if (!(EqualPath $identity.installationRoot $manifest.expectedBrickadiaRoot)) { $errors.Add('identity installation root differs from manifest') }
if (!(EqualPath $identity.runtimeRoot $manifest.expectedBMFRuntimeRoot)) { $errors.Add('identity runtime root differs from manifest') }
if ($identity.runtimeHash -ne $manifest.expectedRuntimeHash) { $errors.Add('identity runtime hash differs from manifest') }
$endpoint = Get-NetUDPEndpoint -LocalPort ([int]$manifest.expectedUdpPort) -ErrorAction SilentlyContinue
if (!$endpoint -or [int]$endpoint.OwningProcess -ne [int]$identity.brickadiaPid) { $errors.Add('live isolated UDP owner differs from identity') }
$brickadia = Get-Process -Id ([int]$identity.brickadiaPid) -ErrorAction SilentlyContinue
$omegga = Get-Process -Id ([int]$identity.omeggaPid) -ErrorAction SilentlyContinue
if (!$brickadia) { $errors.Add('identity Brickadia PID is not live') }
if (!$omegga) { $errors.Add('identity Omegga PID is not live') }

$documentsChecked = 0
foreach ($rawPath in $DocumentPath) {
  $path = [System.IO.Path]::GetFullPath($rawPath)
  if (!(Test-Path -LiteralPath $path)) {
    $errors.Add("status document missing: $path")
    continue
  }
  $records = @()
  if ([System.IO.Path]::GetExtension($path) -eq '.ndjson') {
    $records = @(Get-Content -LiteralPath $path | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json })
  } else {
    $records = @(Get-Content -LiteralPath $path -Raw | ConvertFrom-Json)
  }
  foreach ($record in $records) {
    $documentsChecked += 1
    $provenance = $record.provenance
    if (!$provenance) {
      $errors.Add("missing provenance: $path")
      continue
    }
    if ($provenance.environment -ne 'isolated_test') { $errors.Add("wrong environment: $path") }
    if ([int]$provenance.brickadiaPid -ne [int]$identity.brickadiaPid) { $errors.Add("wrong Brickadia PID: $path") }
    if ([int]$provenance.omeggaPid -ne [int]$identity.omeggaPid) { $errors.Add("wrong Omegga PID: $path") }
    if ([int]$provenance.udpPort -ne [int]$manifest.expectedUdpPort) { $errors.Add("wrong UDP port: $path") }
    if (!(EqualPath $provenance.installationRoot $manifest.expectedBrickadiaRoot)) { $errors.Add("wrong installation root: $path") }
    if (!(EqualPath $provenance.runtimeRoot $manifest.expectedBMFRuntimeRoot)) { $errors.Add("wrong runtime root: $path") }
    if ($provenance.runtimeHash -ne $manifest.expectedRuntimeHash) { $errors.Add("wrong runtime hash: $path") }
    if ([double]$provenance.telemetryGenerationTimestamp -lt [double]$identity.processStartTimestamp) { $errors.Add("pre-start telemetry timestamp: $path") }
    if ([string]::IsNullOrWhiteSpace([string]$provenance.telemetryWriterIdentity)) { $errors.Add("missing writer identity: $path") }
    if ($ProductionBrickadiaPid -gt 0 -and [int]$provenance.brickadiaPid -eq $ProductionBrickadiaPid) { $errors.Add("production PID appeared in isolated provenance: $path") }
    if ([int]$provenance.udpPort -eq $ProductionUdpPort) { $errors.Add("production port appeared in isolated provenance: $path") }
    if ($ProductionRuntimeRoot -and (EqualPath $provenance.runtimeRoot $ProductionRuntimeRoot)) { $errors.Add("production runtime root appeared in isolated provenance: $path") }
    if ($ProductionRuntimeHash -and $provenance.runtimeHash -eq $ProductionRuntimeHash) { $errors.Add("production runtime hash appeared in isolated provenance: $path") }
  }
  $lastWriteMs = ([DateTimeOffset](Get-Item -LiteralPath $path).LastWriteTimeUtc).ToUnixTimeMilliseconds()
  if ($lastWriteMs -lt [double]$identity.processStartTimestamp) { $errors.Add("status document predates isolated startup: $path") }
}

$result = [ordered]@{
  status = if ($errors.Count -eq 0) { 'VALID' } else { 'HARNESS INVALID' }
  documentsChecked = $documentsChecked
  brickadiaPid = [int]$identity.brickadiaPid
  omeggaPid = [int]$identity.omeggaPid
  udpPort = [int]$identity.udpPort
  runtimeHash = [string]$identity.runtimeHash
  errors = @($errors)
}
$result | ConvertTo-Json -Depth 5
if ($errors.Count -gt 0) { exit 1 }
