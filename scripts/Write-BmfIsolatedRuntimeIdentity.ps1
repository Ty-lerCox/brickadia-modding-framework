[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$ManifestPath,
  [Parameter(Mandatory = $true)]
  [int]$OmeggaPid
)

$ErrorActionPreference = 'Stop'
$manifestPathFull = [System.IO.Path]::GetFullPath($ManifestPath)
$manifest = Get-Content -LiteralPath $manifestPathFull -Raw | ConvertFrom-Json
$omegga = Get-Process -Id $OmeggaPid -ErrorAction Stop
$endpoint = Get-NetUDPEndpoint -LocalPort ([int]$manifest.expectedUdpPort) -ErrorAction Stop
if (@($endpoint).Count -ne 1) {
  throw "Expected exactly one isolated UDP owner on port $($manifest.expectedUdpPort)."
}
$brickadiaPid = [int]$endpoint.OwningProcess
$brickadia = Get-Process -Id $brickadiaPid -ErrorAction Stop
if ($brickadia.ProcessName -notlike 'BrickadiaServer*') {
  throw "Isolated UDP owner is not Brickadia: PID $brickadiaPid ($($brickadia.ProcessName))."
}
if (![System.IO.Path]::GetFullPath($brickadia.Path).StartsWith([System.IO.Path]::GetFullPath($manifest.expectedBrickadiaRoot), [System.StringComparison]::OrdinalIgnoreCase)) {
  throw "Isolated Brickadia PID path does not belong to the manifest install."
}
$runtimeLua = Join-Path $manifest.expectedBMFRuntimeRoot '..\Scripts\bmf\runtime.lua'
$runtimeHash = (Get-FileHash -LiteralPath $runtimeLua -Algorithm SHA256).Hash
if ($runtimeHash -ne $manifest.expectedRuntimeHash) {
  throw "Runtime hash changed between manifest creation and identity capture."
}
$brickadiaStart = [DateTimeOffset]$brickadia.StartTime.ToUniversalTime()
$omeggaStart = [DateTimeOffset]$omegga.StartTime.ToUniversalTime()
$identity = [ordered]@{
  environment = 'isolated_test'
  brickadiaPid = $brickadiaPid
  omeggaPid = $OmeggaPid
  processStartTimestamp = $brickadiaStart.ToUnixTimeMilliseconds()
  brickadiaStartTimestamp = $brickadiaStart.ToUnixTimeMilliseconds()
  omeggaStartTimestamp = $omeggaStart.ToUnixTimeMilliseconds()
  udpPort = [int]$manifest.expectedUdpPort
  installationRoot = [System.IO.Path]::GetFullPath($manifest.expectedBrickadiaRoot)
  runtimeRoot = [System.IO.Path]::GetFullPath($manifest.expectedBMFRuntimeRoot)
  runtimeHash = $runtimeHash
}
$identityPath = [System.IO.Path]::GetFullPath($manifest.identityPath)
$tmpPath = "$identityPath.$PID.tmp"
[System.IO.File]::WriteAllText($tmpPath, (($identity | ConvertTo-Json -Depth 4) + "`n"), [System.Text.UTF8Encoding]::new($false))
Move-Item -LiteralPath $tmpPath -Destination $identityPath -Force
$identity | ConvertTo-Json -Depth 4
