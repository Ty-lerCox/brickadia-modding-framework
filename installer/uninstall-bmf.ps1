param(
  [Parameter(Mandatory = $true)]
  [string]$ServerWin64Dir,
  [string]$ModsDir = '',
  [string]$BackupRoot = '',
  [string]$RestoreBackupDir = '',
  [string]$OutJson = ''
)

$ErrorActionPreference = 'Stop'

function Get-FullPath([string]$Path) {
  return [System.IO.Path]::GetFullPath($Path)
}

function Test-IsChildPath([string]$Parent, [string]$Child) {
  $parentFull = Get-FullPath $Parent
  $childFull = Get-FullPath $Child
  if (!$parentFull.EndsWith([System.IO.Path]::DirectorySeparatorChar)) {
    $parentFull += [System.IO.Path]::DirectorySeparatorChar
  }
  return $childFull.StartsWith($parentFull, [System.StringComparison]::OrdinalIgnoreCase)
}

function Add-Evidence([System.Collections.Generic.List[object]]$Evidence, [string]$Kind, [string]$Path, [string]$Summary) {
  if ($Path -and (Test-Path -LiteralPath $Path)) {
    $Evidence.Add([ordered]@{
      kind = $Kind
      path = Get-FullPath $Path
      summary = $Summary
    })
  }
}

$errors = New-Object System.Collections.Generic.List[string]
$evidence = New-Object System.Collections.Generic.List[object]
$startedAt = (Get-Date).ToUniversalTime().ToString('o')
$serverDir = Get-FullPath $ServerWin64Dir
if (!$ModsDir) {
  $ModsDir = Join-Path $serverDir 'ue4ss/main/Mods'
}
if (!$BackupRoot) {
  $BackupRoot = Join-Path $serverDir 'BMF-Backups'
}
$modsDirFull = Get-FullPath $ModsDir
$backupRootFull = Get-FullPath $BackupRoot
$targetBmfDir = Join-Path $modsDirFull 'BMF'
$serverExe = Join-Path $serverDir 'BrickadiaServer-Win64-Shipping.exe'
$removedBackupDir = $null
$restored = $false

try {
  if (!(Test-Path -LiteralPath $serverDir)) {
    throw "Server Win64 directory does not exist: $serverDir"
  }
  if (!(Test-Path -LiteralPath $serverExe)) {
    throw "Brickadia server executable was not found: $serverExe"
  }

  $running = @(Get-CimInstance Win32_Process |
    Where-Object {
      $_.Name -eq 'BrickadiaServer-Win64-Shipping.exe' -and
      (
        ($_.ExecutablePath -and ((Get-FullPath $_.ExecutablePath) -eq (Get-FullPath $serverExe))) -or
        ($_.CommandLine -and $_.CommandLine.IndexOf($serverDir, [System.StringComparison]::OrdinalIgnoreCase) -ge 0)
      )
    })
  if ($running.Count -gt 0) {
    throw "Brickadia server is running from this directory. Stop it before uninstalling or rolling back BMF."
  }

  if (!(Test-IsChildPath $modsDirFull $targetBmfDir)) {
    throw "Refusing to remove target outside Mods directory: $targetBmfDir"
  }

  if (Test-Path -LiteralPath $targetBmfDir) {
    New-Item -ItemType Directory -Force -Path $backupRootFull | Out-Null
    $stamp = Get-Date -Format 'yyyyMMddHHmmss'
    $removedBackupDir = Join-Path $backupRootFull "BMF-removed-$stamp"
    New-Item -ItemType Directory -Force -Path $removedBackupDir | Out-Null
    Copy-Item -LiteralPath $targetBmfDir -Destination (Join-Path $removedBackupDir 'BMF') -Recurse -Force
    Add-Evidence $evidence 'directory' $removedBackupDir 'Backup of BMF installation removed by uninstall'
    Remove-Item -LiteralPath $targetBmfDir -Recurse -Force
  }

  if ($RestoreBackupDir) {
    $restoreFull = Get-FullPath $RestoreBackupDir
    $restoreBmf = Join-Path $restoreFull 'BMF'
    if (!(Test-Path -LiteralPath $restoreBmf)) {
      throw "Restore backup does not contain a BMF directory: $restoreBmf"
    }
    New-Item -ItemType Directory -Force -Path $modsDirFull | Out-Null
    Copy-Item -LiteralPath $restoreBmf -Destination $targetBmfDir -Recurse -Force
    $restored = $true
    Add-Evidence $evidence 'directory' $restoreFull 'BMF backup restored into Mods directory'
  }
} catch {
  $errors.Add($_.Exception.Message)
}

$status = 'failed'
if ($errors.Count -eq 0) {
  $status = 'passed'
}

$removedBackupDirForResult = $null
if ($removedBackupDir) {
  $removedBackupDirForResult = Get-FullPath $removedBackupDir
}
$restoreBackupDirForResult = $null
if ($RestoreBackupDir) {
  $restoreBackupDirForResult = Get-FullPath $RestoreBackupDir
}

$result = [ordered]@{
  feature = 'installer.windows.uninstall'
  status = $status
  validationLevel = 'L0 Static'
  startedAt = $startedAt
  finishedAt = (Get-Date).ToUniversalTime().ToString('o')
  data = [ordered]@{
    serverWin64Dir = $serverDir
    modsDir = $modsDirFull
    targetBmfDir = Get-FullPath $targetBmfDir
    backupRoot = $backupRootFull
    removedBackupDir = $removedBackupDirForResult
    restoreBackupDir = $restoreBackupDirForResult
    restored = $restored
    targetExists = Test-Path -LiteralPath $targetBmfDir
  }
  evidence = $evidence.ToArray()
  errors = $errors.ToArray()
}

$json = $result | ConvertTo-Json -Depth 10
if ($OutJson) {
  $outPath = Get-FullPath $OutJson
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $outPath) | Out-Null
  Set-Content -LiteralPath $outPath -Value $json -Encoding UTF8
}
Write-Output $json

if ($errors.Count -ne 0) {
  exit 1
}
