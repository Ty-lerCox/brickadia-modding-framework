param(
  [string]$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
  [string]$OutDir = '',
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

function Get-Sha256Hex([string]$Path) {
  $stream = [System.IO.File]::OpenRead($Path)
  try {
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
      return ([System.BitConverter]::ToString($sha256.ComputeHash($stream))).Replace('-', '').ToLowerInvariant()
    } finally {
      $sha256.Dispose()
    }
  } finally {
    $stream.Dispose()
  }
}

function Test-IsExcludedReleaseRelativePath([string]$Relative) {
  $parts = $Relative -split '[\\/]'
  foreach ($part in $parts) {
    if ($part -in @('node_modules', '.angular', 'dist')) {
      return $true
    }
  }
  return $false
}

function Copy-ReleaseDirectory([string]$Source, [string]$Destination) {
  New-Item -ItemType Directory -Force -Path $Destination | Out-Null
  foreach ($file in Get-ChildItem -LiteralPath $Source -Recurse -File -Force) {
    $relative = Get-ChildRelativePath $Source $file.FullName
    if (Test-IsExcludedReleaseRelativePath $relative) {
      continue
    }
    $target = Join-Path $Destination $relative
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
    Copy-Item -LiteralPath $file.FullName -Destination $target -Force
  }
}

if (!$OutDir) {
  $OutDir = Join-Path $Root 'artifacts/local/release'
}
if (!$OutJson) {
  $OutJson = Join-Path $OutDir 'release-package.json'
}

$errors = New-Object System.Collections.Generic.List[string]
$evidence = New-Object System.Collections.Generic.List[object]
$startedAt = (Get-Date).ToUniversalTime().ToString('o')
$rootFull = Get-FullPath $Root
$outDirFull = Get-FullPath $OutDir
$outJsonFull = Get-FullPath $OutJson
$packageManifestPath = Join-Path $rootFull 'manifests/bmf-package.json'
$stagingRoot = Join-Path $outDirFull 'staging'
$zipPath = $null
$releaseManifestPath = $null
$fileRecords = New-Object System.Collections.Generic.List[object]
$version = '0.0.0'

try {
  if (!(Test-Path -LiteralPath $packageManifestPath)) {
    throw "Package manifest does not exist: $packageManifestPath"
  }
  $packageManifest = Get-Content -Raw -LiteralPath $packageManifestPath | ConvertFrom-Json
  $version = [string]$packageManifest.version
  if (!$version) {
    throw 'Package manifest does not contain version.'
  }

  New-Item -ItemType Directory -Force -Path $outDirFull | Out-Null
  if (Test-Path -LiteralPath $stagingRoot) {
    if (!(Test-IsChildPath $outDirFull $stagingRoot)) {
      throw "Refusing to clean staging directory outside output directory: $stagingRoot"
    }
    Remove-Item -LiteralPath $stagingRoot -Recurse -Force
  }
  New-Item -ItemType Directory -Force -Path $stagingRoot | Out-Null

  $zipPath = Join-Path $outDirFull ("bmf-{0}.zip" -f $version)
  if ((Test-Path -LiteralPath $zipPath) -and !$Force) {
    throw "Release zip already exists. Pass -Force to overwrite: $zipPath"
  }
  if (Test-Path -LiteralPath $zipPath) {
    Remove-Item -LiteralPath $zipPath -Force
  }

  $topLevelFiles = @('README.md', 'package.json', 'TODO.md', 'OVERNIGHT_STRATEGY.md')
  $topLevelDirs = @('.github', 'apps', 'framework', 'installer', 'examples', 'docs', 'planning', 'manifests', 'compat', 'observability', 'packages', 'scripts', 'tests', 'integrations', 'native', 'cli')

  foreach ($relative in $topLevelFiles) {
    $source = Join-Path $rootFull $relative
    if (!(Test-Path -LiteralPath $source)) {
      throw "Release source file is missing: $relative"
    }
    Copy-Item -LiteralPath $source -Destination (Join-Path $stagingRoot $relative) -Force
  }

  foreach ($relative in $topLevelDirs) {
    $source = Join-Path $rootFull $relative
    if (!(Test-Path -LiteralPath $source)) {
      throw "Release source directory is missing: $relative"
    }
    Copy-ReleaseDirectory $source (Join-Path $stagingRoot $relative)
  }

  foreach ($file in Get-ChildItem -LiteralPath $stagingRoot -Recurse -File) {
    $relative = (Get-ChildRelativePath $stagingRoot $file.FullName).Replace('\', '/')
    if ($relative.StartsWith('artifacts/', [System.StringComparison]::OrdinalIgnoreCase)) {
      throw "Release staging unexpectedly contains artifact file: $relative"
    }
    $fileRecords.Add([ordered]@{
      path = $relative
      bytes = $file.Length
      sha256 = Get-Sha256Hex $file.FullName
    })
  }

  $releaseManifestPath = Join-Path $stagingRoot 'manifests/release-manifest.json'
  $releaseManifest = [ordered]@{
    name = 'bmf'
    version = $version
    builtAt = (Get-Date).ToUniversalTime().ToString('o')
    package = [ordered]@{
      fileName = [System.IO.Path]::GetFileName($zipPath)
      excludes = @('artifacts/', 'node_modules/', '.angular/', 'dist/')
      includedRoots = @($topLevelFiles + $topLevelDirs)
    }
    files = $fileRecords.ToArray()
  }
  $releaseManifest | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $releaseManifestPath -Encoding UTF8
  Add-Evidence $evidence 'json' $releaseManifestPath 'Release package manifest generated in staging tree'

  Compress-Archive -Path (Join-Path $stagingRoot '*') -DestinationPath $zipPath -Force
  Add-Evidence $evidence 'zip' $zipPath 'BMF release zip'
} catch {
  $errors.Add($_.Exception.Message)
}

$status = 'failed'
if ($errors.Count -eq 0) {
  $status = 'passed'
}

$zipSha256 = $null
$zipBytes = $null
if ($zipPath -and (Test-Path -LiteralPath $zipPath)) {
  $zipSha256 = Get-Sha256Hex $zipPath
  $zipBytes = (Get-Item -LiteralPath $zipPath).Length
}
$zipPathForResult = $null
if ($zipPath) {
  $zipPathForResult = Get-FullPath $zipPath
}
$releaseManifestPathForResult = $null
if ($releaseManifestPath) {
  $releaseManifestPathForResult = Get-FullPath $releaseManifestPath
}

$result = [ordered]@{
  feature = 'release.package.build'
  status = $status
  validationLevel = 'L0 Static'
  startedAt = $startedAt
  finishedAt = (Get-Date).ToUniversalTime().ToString('o')
  data = [ordered]@{
    root = $rootFull
    outDir = $outDirFull
    stagingRoot = Get-FullPath $stagingRoot
    version = $version
    zipPath = $zipPathForResult
    zipBytes = $zipBytes
    zipSha256 = $zipSha256
    releaseManifestPath = $releaseManifestPathForResult
    fileCount = $fileRecords.Count
  }
  evidence = $evidence.ToArray()
  errors = $errors.ToArray()
}

$json = $result | ConvertTo-Json -Depth 10
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $outJsonFull) | Out-Null
Set-Content -LiteralPath $outJsonFull -Value $json -Encoding UTF8
Write-Output $json

if ($errors.Count -ne 0) {
  exit 1
}
