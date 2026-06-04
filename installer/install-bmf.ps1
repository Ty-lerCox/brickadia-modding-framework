param(
  [string]$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
  [Parameter(Mandatory = $true)]
  [string]$ServerWin64Dir,
  [string]$ModsDir = '',
  [string]$BackupRoot = '',
  [string]$OutJson = '',
  [switch]$Force
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

function Get-ChildRelativePath([string]$Parent, [string]$Child) {
  $parentFull = Get-FullPath $Parent
  $childFull = Get-FullPath $Child
  if (!$parentFull.EndsWith([System.IO.Path]::DirectorySeparatorChar)) {
    $parentFull += [System.IO.Path]::DirectorySeparatorChar
  }
  if (!$childFull.StartsWith($parentFull, [System.StringComparison]::OrdinalIgnoreCase)) {
    return $childFull
  }
  return $childFull.Substring($parentFull.Length)
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
$sourceBmfDir = Join-Path $Root 'framework/ue4ss/Mods/BMF'
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
$installManifestPath = Join-Path $targetBmfDir 'runtime/install-manifest.json'
$backupDir = $null
$installedFiles = New-Object System.Collections.Generic.List[object]

try {
  if (!(Test-Path -LiteralPath $sourceBmfDir)) {
    throw "Source BMF package does not exist: $sourceBmfDir"
  }
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
    throw "Brickadia server is running from this directory. Stop it before installing BMF."
  }

  New-Item -ItemType Directory -Force -Path $modsDirFull | Out-Null
  New-Item -ItemType Directory -Force -Path $backupRootFull | Out-Null

  if (!(Test-IsChildPath $modsDirFull $targetBmfDir)) {
    throw "Refusing to install outside Mods directory: $targetBmfDir"
  }

  if (Test-Path -LiteralPath $targetBmfDir) {
    if (!$Force) {
      throw "BMF is already installed at $targetBmfDir. Pass -Force to back it up and replace it."
    }
    $stamp = Get-Date -Format 'yyyyMMddHHmmss'
    $backupDir = Join-Path $backupRootFull "BMF-$stamp"
    New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
    Copy-Item -LiteralPath $targetBmfDir -Destination (Join-Path $backupDir 'BMF') -Recurse -Force
    Add-Evidence $evidence 'directory' $backupDir 'Backup of previous BMF installation'
    if (!(Test-IsChildPath $modsDirFull $targetBmfDir)) {
      throw "Refusing to remove target outside Mods directory: $targetBmfDir"
    }
    Remove-Item -LiteralPath $targetBmfDir -Recurse -Force
  }

  Copy-Item -LiteralPath $sourceBmfDir -Destination $targetBmfDir -Recurse -Force
  Add-Evidence $evidence 'directory' $targetBmfDir 'Installed BMF UE4SS mod directory'

  foreach ($file in Get-ChildItem -LiteralPath $targetBmfDir -Recurse -File) {
    $relative = Get-ChildRelativePath $targetBmfDir $file.FullName
    $hash = Get-FileHash -Algorithm SHA256 -LiteralPath $file.FullName
    $installedFiles.Add([ordered]@{
      path = $relative.Replace('\', '/')
      bytes = $file.Length
      sha256 = $hash.Hash.ToLowerInvariant()
    })
  }

  $backupDirForManifest = $null
  if ($backupDir) {
    $backupDirForManifest = Get-FullPath $backupDir
  }

  $manifest = [ordered]@{
    installedAt = (Get-Date).ToUniversalTime().ToString('o')
    root = Get-FullPath $Root
    serverWin64Dir = $serverDir
    modsDir = $modsDirFull
    sourceBmfDir = Get-FullPath $sourceBmfDir
    targetBmfDir = Get-FullPath $targetBmfDir
    backupDir = $backupDirForManifest
    force = $Force.IsPresent
    files = $installedFiles.ToArray()
  }
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $installManifestPath) | Out-Null
  $manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $installManifestPath -Encoding UTF8
  Add-Evidence $evidence 'json' $installManifestPath 'BMF install manifest'
} catch {
  $errors.Add($_.Exception.Message)
}

$status = 'failed'
if ($errors.Count -eq 0) {
  $status = 'passed'
}

$backupDirForResult = $null
if ($backupDir) {
  $backupDirForResult = Get-FullPath $backupDir
}
$installManifestForResult = $null
if (Test-Path -LiteralPath $installManifestPath) {
  $installManifestForResult = Get-FullPath $installManifestPath
}

$result = [ordered]@{
  feature = 'installer.windows.install'
  status = $status
  validationLevel = 'L0 Static'
  startedAt = $startedAt
  finishedAt = (Get-Date).ToUniversalTime().ToString('o')
  data = [ordered]@{
    serverWin64Dir = $serverDir
    modsDir = $modsDirFull
    sourceBmfDir = Get-FullPath $sourceBmfDir
    targetBmfDir = Get-FullPath $targetBmfDir
    backupRoot = $backupRootFull
    backupDir = $backupDirForResult
    installManifest = $installManifestForResult
    installedFileCount = $installedFiles.Count
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
