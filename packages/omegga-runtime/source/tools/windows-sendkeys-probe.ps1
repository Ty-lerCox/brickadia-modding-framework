param(
  [string]$Text = 'hello world',
  [int]$StartupDelayMs = 1000,
  [int]$PostActivateDelayMs = 500,
  [int]$WaitTimeoutMs = 5000
)

$ErrorActionPreference = 'Stop'

$root = Join-Path $env:TEMP ('omegga-sendkeys-probe-' + [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())
New-Item -ItemType Directory -Path $root | Out-Null

$childScript = Join-Path $root 'child.ps1'
$resultFile = Join-Path $root 'result.txt'

@'
$value = Read-Host
[System.IO.File]::WriteAllText($args[0], 'ECHO:' + $value)
'@ | Set-Content -Path $childScript -Encoding ASCII

$proc = Start-Process -FilePath 'powershell.exe' -ArgumentList @(
  '-NoLogo',
  '-NoProfile',
  '-File',
  $childScript,
  $resultFile
) -PassThru

Start-Sleep -Milliseconds $StartupDelayMs

$shell = New-Object -ComObject WScript.Shell
$activated = $shell.AppActivate($proc.Id)
Start-Sleep -Milliseconds $PostActivateDelayMs
$shell.SendKeys($Text + '~')

$exited = $proc.WaitForExit($WaitTimeoutMs)
if (-not $exited) {
  Stop-Process -Id $proc.Id -Force
}

[ordered]@{
  root = $root
  activated = $activated
  exited = $exited
  exitCode = if ($proc.HasExited) { $proc.ExitCode } else { $null }
  output = if (Test-Path $resultFile) { Get-Content -Path $resultFile -Raw } else { '' }
} | ConvertTo-Json -Depth 3
