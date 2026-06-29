param(
  [string]$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
  [string]$OutJson = '',
  [string]$ArtifactDir = ''
)

$ErrorActionPreference = 'Stop'

if (!$OutJson) {
  $OutJson = Join-Path $Root 'artifacts/local/windows-installer-canary.json'
}

$errors = New-Object System.Collections.Generic.List[string]
$evidence = New-Object System.Collections.Generic.List[object]
$startedAt = (Get-Date).ToUniversalTime().ToString('o')
$outPath = [System.IO.Path]::GetFullPath($OutJson)
if ($ArtifactDir) {
  $caseRoot = [System.IO.Path]::GetFullPath($ArtifactDir)
} else {
  $caseRoot = Join-Path (Split-Path -Parent $outPath) 'windows-installer'
}
New-Item -ItemType Directory -Force -Path $caseRoot | Out-Null

$installScript = Join-Path $Root 'installer/install-bmf.ps1'
$uninstallScript = Join-Path $Root 'installer/uninstall-bmf.ps1'
$serverWin64Dir = Join-Path $caseRoot 'FakeServer/Binaries/Win64'
$modsDir = Join-Path $serverWin64Dir 'ue4ss/main/Mods'
$existingBmfDir = Join-Path $modsDir 'BMF'
$backupRoot = Join-Path $caseRoot 'Backups'
$installJsonPath = Join-Path $caseRoot 'install.json'
$rollbackJsonPath = Join-Path $caseRoot 'rollback.json'
$removeJsonPath = Join-Path $caseRoot 'remove.json'
$finalInstallJsonPath = Join-Path $caseRoot 'install-final.json'
$install = $null
$rollback = $null
$remove = $null
$finalInstall = $null

function Add-Evidence([string]$Kind, [string]$Path, [string]$Summary) {
  if ($Path -and (Test-Path -LiteralPath $Path)) {
    $script:evidence.Add([ordered]@{
      kind = $Kind
      path = [System.IO.Path]::GetFullPath($Path)
      summary = $Summary
    })
  }
}

try {
  foreach ($path in @($installScript, $uninstallScript)) {
    if (!(Test-Path -LiteralPath $path)) {
      throw "Required installer script does not exist: $path"
    }
  }

  New-Item -ItemType Directory -Force -Path $existingBmfDir | Out-Null
  New-Item -ItemType File -Force -Path (Join-Path $serverWin64Dir 'BrickadiaServer-Win64-Shipping.exe') | Out-Null
  Set-Content -LiteralPath (Join-Path $existingBmfDir 'old-plugin.txt') -Value 'preexisting install' -Encoding UTF8
  New-Item -ItemType Directory -Force -Path (Join-Path $existingBmfDir 'plugins/ExistingPlugin') | Out-Null
  Set-Content -LiteralPath (Join-Path $existingBmfDir 'plugins/ExistingPlugin/main.lua') -Value 'return {}' -Encoding UTF8

  $installOutput = & $installScript `
    -Root $Root `
    -ServerWin64Dir $serverWin64Dir `
    -BackupRoot $backupRoot `
    -OutJson $installJsonPath `
    -Force
  $install = $installOutput | ConvertFrom-Json
  Add-Evidence 'json' $installJsonPath 'Installer output JSON'

  if ($install.status -ne 'passed') {
    $errors.Add('Installer did not pass.')
  }
  foreach ($relative in @('bmf.json', 'enabled.txt', 'Scripts/main.lua', 'Scripts/bmf/runtime.lua', 'runtime/install-manifest.json')) {
    $path = Join-Path $existingBmfDir $relative
    if (!(Test-Path -LiteralPath $path)) {
      $errors.Add("Installed BMF is missing expected file: $relative")
    }
  }
  $backupDir = $install.data.backupDir
  if (!$backupDir -or !(Test-Path -LiteralPath (Join-Path $backupDir 'BMF/old-plugin.txt'))) {
    $errors.Add('Installer did not back up the previous BMF directory.')
  } else {
    Add-Evidence 'directory' $backupDir 'Backup created by install-bmf.ps1'
  }

  $rollbackOutput = & $uninstallScript `
    -ServerWin64Dir $serverWin64Dir `
    -BackupRoot $backupRoot `
    -RestoreBackupDir $backupDir `
    -OutJson $rollbackJsonPath
  $rollback = $rollbackOutput | ConvertFrom-Json
  Add-Evidence 'json' $rollbackJsonPath 'Rollback output JSON'

  if ($rollback.status -ne 'passed' -or $rollback.data.restored -ne $true) {
    $errors.Add('Rollback did not restore the previous BMF backup.')
  }
  if (!(Test-Path -LiteralPath (Join-Path $existingBmfDir 'old-plugin.txt'))) {
    $errors.Add('Rollback did not restore the preexisting BMF sentinel file.')
  }
  if (Test-Path -LiteralPath (Join-Path $existingBmfDir 'Scripts/main.lua')) {
    $errors.Add('Rollback left the newly installed BMF script in the restored old install.')
  }
  if (Test-Path -LiteralPath (Join-Path $existingBmfDir 'Scripts/bmf/runtime.lua')) {
    $errors.Add('Rollback left the newly installed BMF runtime module in the restored old install.')
  }

  $finalInstallOutput = & $installScript `
    -Root $Root `
    -ServerWin64Dir $serverWin64Dir `
    -BackupRoot $backupRoot `
    -OutJson $finalInstallJsonPath `
    -Force
  $finalInstall = $finalInstallOutput | ConvertFrom-Json
  Add-Evidence 'json' $finalInstallJsonPath 'Final installer output JSON before remove-only uninstall'

  $removeOutput = & $uninstallScript `
    -ServerWin64Dir $serverWin64Dir `
    -BackupRoot $backupRoot `
    -OutJson $removeJsonPath
  $remove = $removeOutput | ConvertFrom-Json
  Add-Evidence 'json' $removeJsonPath 'Remove-only uninstall output JSON'

  if ($remove.status -ne 'passed' -or $remove.data.targetExists -ne $false) {
    $errors.Add('Remove-only uninstall did not remove the BMF target directory.')
  }
  if (!$remove.data.removedBackupDir -or !(Test-Path -LiteralPath (Join-Path $remove.data.removedBackupDir 'BMF/bmf.json'))) {
    $errors.Add('Remove-only uninstall did not back up the removed BMF directory.')
  }
} catch {
  $errors.Add($_.Exception.Message)
}

$status = 'failed'
if ($errors.Count -eq 0) {
  $status = 'passed'
}

$installData = $null
$rollbackData = $null
$finalInstallData = $null
$removeData = $null
if ($install) {
  $installData = $install.data
}
if ($rollback) {
  $rollbackData = $rollback.data
}
if ($finalInstall) {
  $finalInstallData = $finalInstall.data
}
if ($remove) {
  $removeData = $remove.data
}

$result = [ordered]@{
  feature = 'installer.windows.static'
  status = $status
  validationLevel = 'L0 Static'
  startedAt = $startedAt
  finishedAt = (Get-Date).ToUniversalTime().ToString('o')
  data = [ordered]@{
    artifactDir = [System.IO.Path]::GetFullPath($caseRoot)
    serverWin64Dir = [System.IO.Path]::GetFullPath($serverWin64Dir)
    modsDir = [System.IO.Path]::GetFullPath($modsDir)
    install = $installData
    rollback = $rollbackData
    finalInstall = $finalInstallData
    remove = $removeData
  }
  evidence = $evidence.ToArray()
  errors = $errors.ToArray()
}

$json = $result | ConvertTo-Json -Depth 12
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $outPath) | Out-Null
Set-Content -LiteralPath $outPath -Value $json -Encoding UTF8
Write-Output $json

if ($errors.Count -ne 0) {
  exit 1
}
