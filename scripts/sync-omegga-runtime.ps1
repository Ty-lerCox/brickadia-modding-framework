param(
  [string]$Root = '',
  [Parameter(Mandatory = $true)]
  [string]$Source,
  [string]$OutJson = '',
  [switch]$Force
)

$ErrorActionPreference = 'Stop'

if (!$Root) {
  $Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
}

if (!$OutJson) {
  $OutJson = Join-Path $Root 'artifacts/local/omegga-runtime-sync.json'
}

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

function Test-IsGeneratedSourceRelativePath([string]$RelativePath, [string[]]$GeneratedDirectoryNames) {
  $parts = $RelativePath -split '[\\/]'
  foreach ($part in $parts) {
    if ($part -in $GeneratedDirectoryNames) {
      return $true
    }
  }
  return $false
}

function Copy-SyncItem([string]$SourceRoot, [string]$DestinationRoot, [string]$RelativePath, [string[]]$GeneratedDirectoryNames) {
  $sourcePath = Join-Path $SourceRoot $RelativePath
  if (!(Test-Path -LiteralPath $sourcePath)) {
    return $false
  }
  $destinationPath = Join-Path $DestinationRoot $RelativePath
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destinationPath) | Out-Null
  $item = Get-Item -LiteralPath $sourcePath
  if ($item.PSIsContainer) {
    foreach ($file in Get-ChildItem -LiteralPath $sourcePath -Recurse -File -Force) {
      $relativeFile = $file.FullName.Substring($sourcePath.Length).TrimStart('\', '/')
      if (Test-IsGeneratedSourceRelativePath $relativeFile $GeneratedDirectoryNames) {
        continue
      }
      $target = Join-Path $destinationPath $relativeFile
      New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
      Copy-Item -LiteralPath $file.FullName -Destination $target -Force
    }
  } else {
    Copy-Item -LiteralPath $sourcePath -Destination $destinationPath -Force
  }
  return $true
}

function Get-GitFirstLine([string]$WorkDir, [string[]]$GitArgs) {
  try {
    $output = @(& git -C $WorkDir @GitArgs 2>$null)
    if ($LASTEXITCODE -eq 0 -and $output.Count -gt 0) {
      return [string]$output[0]
    }
  } catch {
  }
  return ''
}

function Get-GitLines([string]$WorkDir, [string[]]$GitArgs) {
  try {
    $output = @(& git -C $WorkDir @GitArgs 2>$null)
    if ($LASTEXITCODE -eq 0) {
      return @($output | ForEach-Object { [string]$_ })
    }
  } catch {
  }
  return @()
}

$errors = New-Object System.Collections.Generic.List[string]
$evidence = New-Object System.Collections.Generic.List[object]
$startedAt = (Get-Date).ToUniversalTime().ToString('o')
$rootFull = Get-FullPath $Root
$sourceFull = Get-FullPath $Source
$packageRoot = Join-Path $rootFull 'packages/omegga-runtime'
$destinationRoot = Join-Path $packageRoot 'source'
$outJsonFull = Get-FullPath $OutJson
$copied = New-Object System.Collections.Generic.List[string]

$allowedItems = @(
  '.gitignore',
  '.npmignore',
  '.nvmrc',
  '.prettierignore',
  '.prettierrc',
  'LICENSE',
  'README.md',
  'index.js',
  'package.json',
  'package-lock.json',
  'eslint.config.mjs',
  'vite.backend.config.mts',
  'vite.frontend.config.mts',
  'vitest.backend.config.mts',
  'bin',
  'configs',
  'docs',
  'frontend',
  'public',
  'src',
  'templates',
  'tools'
)

$excludedNames = @(
  '.git',
  '.github',
  '.vscode',
  'artifacts',
  'data',
  'dist',
  'logs',
  'node_modules',
  'plugins',
  'plugins-disabled',
  'observability'
)

$generatedDirectoryNames = @(
  'node_modules',
  '.vite',
  '.angular',
  'dist',
  'logs',
  'artifacts',
  'target'
)

try {
  foreach ($required in @(
    (Join-Path $sourceFull 'package.json'),
    (Join-Path $sourceFull 'src'),
    (Join-Path $sourceFull 'templates')
  )) {
    if (!(Test-Path -LiteralPath $required)) {
      throw "Omegga source is missing required path: $required"
    }
  }

  $packageRootFull = Get-FullPath $packageRoot
  $destinationFull = Get-FullPath $destinationRoot
  if (!(Test-IsChildPath $packageRootFull $destinationFull)) {
    throw "Refusing to sync outside packages/omegga-runtime: $destinationFull"
  }

  if ((Test-Path -LiteralPath $destinationFull) -and !$Force) {
    throw "Omegga runtime source destination already exists. Pass -Force to replace it: $destinationFull"
  }
  if (Test-Path -LiteralPath $destinationFull) {
    Remove-Item -LiteralPath $destinationFull -Recurse -Force
  }
  New-Item -ItemType Directory -Force -Path $destinationFull | Out-Null

  foreach ($item in $allowedItems) {
    if (Copy-SyncItem $sourceFull $destinationFull $item $generatedDirectoryNames) {
      $copied.Add($item)
    }
  }

  foreach ($excluded in $excludedNames) {
    $candidate = Join-Path $destinationFull $excluded
    if (Test-Path -LiteralPath $candidate) {
      $errors.Add("Excluded Omegga source path was copied unexpectedly: $excluded")
    }
  }
  foreach ($generated in Get-ChildItem -LiteralPath $destinationFull -Recurse -Directory -Force -ErrorAction SilentlyContinue) {
    if ($generated.Name -in $generatedDirectoryNames) {
      $relativeGenerated = $generated.FullName.Substring($destinationFull.Length).TrimStart('\', '/')
      $errors.Add("Generated Omegga source directory was copied unexpectedly: $relativeGenerated")
    }
  }

  $packageJsonPath = Join-Path $destinationFull 'package.json'
  $packageJson = Get-Content -Raw -LiteralPath $packageJsonPath | ConvertFrom-Json
  if ([string]$packageJson.scripts.'package:bmf' -ne 'node tools/package-bmf-omegga.js') {
    $errors.Add('Synced Omegga source package.json must expose scripts.package:bmf.')
  }
  foreach ($surface in @(
    'BmfSocketBridgeHost',
    'OmeggaExecuteConsoleManagerInput',
    'OmeggaExecuteKismetConsoleCommand',
    'OmeggaExecuteCachedConsoleExec',
    'OmeggaCallFunctionByNameWithArguments',
    'RegisterConsoleCommandGlobalHandler'
  )) {
    $matches = Get-ChildItem -LiteralPath $destinationFull -Recurse -File -ErrorAction SilentlyContinue |
      Select-String -Pattern $surface -ErrorAction SilentlyContinue
    if (!$matches) {
      $errors.Add("Synced Omegga source is missing required surface marker: $surface")
    }
  }

  $remote = Get-GitFirstLine $sourceFull @('remote', 'get-url', 'origin')
  $commit = Get-GitFirstLine $sourceFull @('rev-parse', 'HEAD')
  $dirty = Get-GitLines $sourceFull @('status', '--short')
  $metadataPath = Join-Path $packageRoot 'sync-metadata.json'
  $metadata = [ordered]@{
    schemaVersion = 1
    syncedAt = (Get-Date).ToUniversalTime().ToString('o')
    source = $sourceFull
    sourceRepository = $remote
    sourceCommit = $commit
    dirtyStatus = @($dirty)
    destination = $destinationFull
    copiedItems = @($copied)
    excludedNames = $excludedNames
    generatedExcludedNames = $generatedDirectoryNames
    guardrails = @(
      'do-not-vendor-node-modules',
      'do-not-vendor-runtime-server-data',
      'do-not-vendor-server-saves',
      'do-not-vendor-logs',
      'record-fork-commit-before-release',
      'preserve-upstream-license-notice'
    )
  }
  $metadata | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $metadataPath -Encoding UTF8

  Add-Evidence $evidence 'directory' $destinationFull 'Synced BMF-compatible Omegga runtime source'
  Add-Evidence $evidence 'json' $metadataPath 'Omegga runtime sync metadata'
  Add-Evidence $evidence 'json' $packageJsonPath 'Synced Omegga package manifest'
} catch {
  $errors.Add($_.Exception.Message)
}

$status = if ($errors.Count -eq 0) { 'passed' } else { 'failed' }
$result = [ordered]@{
  feature = 'omegga.runtime-sync'
  status = $status
  validationLevel = 'L0 Static'
  startedAt = $startedAt
  finishedAt = (Get-Date).ToUniversalTime().ToString('o')
  data = [ordered]@{
    root = $rootFull
    source = $sourceFull
    destination = $destinationRoot
    copiedItems = @($copied)
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
