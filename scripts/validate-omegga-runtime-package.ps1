param(
  [string]$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
  [string]$OutJson = ''
)

$ErrorActionPreference = 'Stop'

if (!$OutJson) {
  $OutJson = Join-Path $Root 'artifacts/local/omegga-runtime-package-validation.json'
}

$errors = New-Object System.Collections.Generic.List[string]
$evidence = New-Object System.Collections.Generic.List[object]
$startedAt = (Get-Date).ToUniversalTime().ToString('o')

function Add-Evidence([string]$Kind, [string]$Path, [string]$Summary) {
  if ($Path -and (Test-Path -LiteralPath $Path)) {
    $script:evidence.Add([ordered]@{
      kind = $Kind
      path = [System.IO.Path]::GetFullPath($Path)
      summary = $Summary
    })
  }
}

function Read-JsonFile([string]$Path) {
  try {
    return Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json
  } catch {
    $script:errors.Add("Invalid JSON in $Path`: $($_.Exception.Message)")
    return $null
  }
}

function Test-Contains([object[]]$Items, [string]$Value, [string]$Message) {
  if ($Value -notin @($Items)) {
    $script:errors.Add($Message)
  }
}

try {
  $packageRoot = Join-Path $Root 'packages/omegga-runtime'
  $packageManifestPath = Join-Path $packageRoot 'package-manifest.json'
  $syncMetadataPath = Join-Path $packageRoot 'sync-metadata.json'
  $sourceRoot = Join-Path $packageRoot 'source'
  $readmePath = Join-Path $packageRoot 'README.md'
  $unifiedManifestPath = Join-Path $Root 'manifests/unified-runtime.json'
  $dependenciesPath = Join-Path $Root 'manifests/dependencies.json'

  foreach ($path in @($packageManifestPath, $syncMetadataPath, $sourceRoot, $readmePath, $unifiedManifestPath, $dependenciesPath)) {
    if (!(Test-Path -LiteralPath $path)) {
      $errors.Add("Missing Omegga runtime package validation file: $path")
    } else {
      Add-Evidence 'file' $path 'Omegga runtime package validation input'
    }
  }

  $packageManifest = $null
  $unifiedManifest = $null
  $dependencies = $null
  $syncMetadata = $null
  if (Test-Path -LiteralPath $packageManifestPath) {
    $packageManifest = Read-JsonFile $packageManifestPath
  }
  if (Test-Path -LiteralPath $syncMetadataPath) {
    $syncMetadata = Read-JsonFile $syncMetadataPath
  }
  if (Test-Path -LiteralPath $unifiedManifestPath) {
    $unifiedManifest = Read-JsonFile $unifiedManifestPath
  }
  if (Test-Path -LiteralPath $dependenciesPath) {
    $dependencies = Read-JsonFile $dependenciesPath
  }

  if ($packageManifest) {
    if ([string]$packageManifest.componentId -ne 'omegga-runtime') {
      $errors.Add('Omegga runtime package componentId must be omegga-runtime.')
    }
    if ([string]$packageManifest.owner -ne 'packages/omegga-runtime') {
      $errors.Add('Omegga runtime package owner must be packages/omegga-runtime.')
    }
    if ([string]$packageManifest.sourceRepository -ne 'https://github.com/Ty-lerCox/bmf-omegga-fork') {
      $errors.Add('Omegga runtime package sourceRepository must be the BMF-supported fork URL.')
    }
    if ([string]$packageManifest.upstreamRepository -ne 'https://github.com/brickadia-community/omegga') {
      $errors.Add('Omegga runtime package upstreamRepository must be upstream Omegga.')
    }
    if ([string]$packageManifest.status -ne 'synced-source') {
      $errors.Add('Omegga runtime package status must be synced-source.')
    }
    if ([string]$packageManifest.importMode -ne 'local-fork-source-sync') {
      $errors.Add('Omegga runtime package importMode must be local-fork-source-sync.')
    }
    if (![string]::IsNullOrWhiteSpace([string]$packageManifest.sourceCommit) -and [string]$packageManifest.sourceCommit -notmatch '^[a-f0-9]{40}$') {
      $errors.Add('Omegga runtime package sourceCommit must be a git SHA when present.')
    }
    Test-Contains @($packageManifest.sourceRoots) 'packages/omegga-runtime/source' 'Omegga runtime package sourceRoots must include packages/omegga-runtime/source.'
    if ([string]$packageManifest.syncMetadata -ne 'packages/omegga-runtime/sync-metadata.json') {
      $errors.Add('Omegga runtime package syncMetadata must point at packages/omegga-runtime/sync-metadata.json.')
    }
    foreach ($surface in @(
      'BMF Bridge socket',
      'OmeggaExecuteConsoleManagerInput',
      'OmeggaCallFunctionByNameWithArguments',
      'RegisterConsoleCommandGlobalHandler'
    )) {
      Test-Contains @($packageManifest.requiredSurfaces) $surface "Omegga runtime package requiredSurfaces are missing: $surface"
    }
    foreach ($guardrail in @('do-not-vendor-node-modules', 'record-fork-commit-before-release', 'preserve-upstream-license-notice', 'keep-server-data-out-of-source')) {
      Test-Contains @($packageManifest.guardrails) $guardrail "Omegga runtime package guardrails are missing: $guardrail"
    }
  }

  if ($unifiedManifest) {
    $component = $null
    foreach ($candidate in @($unifiedManifest.components)) {
      if ([string]$candidate.id -eq 'omegga-runtime') {
        $component = $candidate
        break
      }
    }
    if (!$component) {
      $errors.Add('Unified runtime manifest is missing omegga-runtime component.')
    } else {
      if ([string]$component.owner -ne 'packages/omegga-runtime') {
        $errors.Add('Unified runtime manifest owner for omegga-runtime must be packages/omegga-runtime.')
      }
      if ([string]$component.source -ne 'packages/omegga-runtime') {
        $errors.Add('Unified runtime manifest source for omegga-runtime must be packages/omegga-runtime.')
      }
      if ([string]$component.status -ne 'synced-source') {
        $errors.Add('Unified runtime manifest status for omegga-runtime must be synced-source.')
      }
    }
  }

  if ($dependencies) {
    $dependency = $null
    foreach ($candidate in @($dependencies.dependencies)) {
      if ([string]$candidate.id -eq 'bmf-compatible-omegga-runtime') {
        $dependency = $candidate
        break
      }
    }
    if (!$dependency) {
      $errors.Add('Dependencies manifest is missing bmf-compatible-omegga-runtime.')
    } else {
      if ([string]$dependency.upstream.repository -ne 'https://github.com/brickadia-community/omegga') {
        $errors.Add('Dependencies manifest upstream repository must match upstream Omegga.')
      }
      foreach ($surface in @($packageManifest.requiredSurfaces)) {
        Test-Contains @($dependency.requiredSurfaces) ([string]$surface) "Dependencies manifest requiredSurfaces are missing: $surface"
      }
      foreach ($provide in @('brickadia-server-supervisor', 'managed-ue4ss-install', 'headless-canary-transport')) {
        Test-Contains @($dependency.provides) $provide "Dependencies manifest provides are missing: $provide"
      }
    }
  }

  if ($syncMetadata) {
    if ([string]$syncMetadata.sourceRepository -notmatch 'Ty-lerCox/bmf-omegga-fork') {
      $errors.Add('Omegga sync metadata must record the BMF-supported fork repository.')
    }
    if ([string]$syncMetadata.sourceCommit -notmatch '^[a-f0-9]{40}$') {
      $errors.Add('Omegga sync metadata must record a sourceCommit git SHA.')
    }
    foreach ($copied in @('package.json', 'package-lock.json', 'src', 'templates', 'tools', 'frontend', 'bin')) {
      Test-Contains @($syncMetadata.copiedItems) $copied "Omegga sync metadata copiedItems are missing: $copied"
    }
    foreach ($excluded in @('node_modules', 'data', 'logs', 'artifacts', 'dist', 'plugins', 'plugins-disabled')) {
      Test-Contains @($syncMetadata.excludedNames) $excluded "Omegga sync metadata excludedNames are missing: $excluded"
      if (Test-Path -LiteralPath (Join-Path $sourceRoot $excluded)) {
        $errors.Add("Synced Omegga source contains excluded directory: $excluded")
      }
    }
    foreach ($generated in @('node_modules', '.vite', '.angular', 'dist', 'logs', 'artifacts', 'target')) {
      Test-Contains @($syncMetadata.generatedExcludedNames) $generated "Omegga sync metadata generatedExcludedNames are missing: $generated"
    }
  }

  if (Test-Path -LiteralPath $sourceRoot) {
    foreach ($relative in @(
      'package.json',
      'package-lock.json',
      'LICENSE',
      'index.js',
      'bin/omegga',
      'src/brickadia/ue4ssBridge.ts',
      'src/omegga/index.ts',
      'tools/package-bmf-omegga.js',
      'templates/windows-ue4ss/ue4ss/Mods/BMF/Scripts/main.lua',
      'templates/windows-ue4ss/ue4ss/Mods/BMF/Scripts/bmf/runtime.lua'
    )) {
      if (!(Test-Path -LiteralPath (Join-Path $sourceRoot $relative))) {
        $errors.Add("Synced Omegga source is missing required file: $relative")
      }
    }
    $sourcePackagePath = Join-Path $sourceRoot 'package.json'
    if (Test-Path -LiteralPath $sourcePackagePath) {
      $sourcePackage = Read-JsonFile $sourcePackagePath
      if ([string]$sourcePackage.scripts.'package:bmf' -ne 'node tools/package-bmf-omegga.js') {
        $errors.Add('Synced Omegga package.json must expose scripts.package:bmf.')
      }
    }
    foreach ($surface in @($packageManifest.requiredSurfaces)) {
      $matches = Get-ChildItem -LiteralPath $sourceRoot -Recurse -File -ErrorAction SilentlyContinue |
        Select-String -Pattern ([string]$surface) -ErrorAction SilentlyContinue
      if (!$matches) {
        $errors.Add("Synced Omegga source is missing required surface marker: $surface")
      }
    }
    foreach ($generated in Get-ChildItem -LiteralPath $sourceRoot -Recurse -Directory -Force -ErrorAction SilentlyContinue) {
      if ($generated.Name -in @('node_modules', '.vite', '.angular', 'dist', 'logs', 'artifacts', 'target')) {
        $relativeGenerated = $generated.FullName.Substring($sourceRoot.Length).TrimStart('\', '/')
        $errors.Add("Synced Omegga source contains generated directory: $relativeGenerated")
      }
    }
  }

  if (Test-Path -LiteralPath $readmePath) {
    $readme = Get-Content -Raw -LiteralPath $readmePath
    foreach ($needle in @('BMF-compatible Omegga runtime', 'https://github.com/Ty-lerCox/bmf-omegga-fork', 'packages/omegga-runtime', 'sync-metadata.json', 'sync-omegga-runtime.ps1')) {
      if ($readme -notmatch [regex]::Escape($needle)) {
        $errors.Add("Omegga runtime README does not contain expected marker: $needle")
      }
    }
  }
} catch {
  $errors.Add($_.Exception.Message)
}

$result = [ordered]@{
  feature = 'omegga.runtime-package'
  status = if ($errors.Count -eq 0) { 'passed' } else { 'failed' }
  validationLevel = 'L0 Static'
  startedAt = $startedAt
  finishedAt = (Get-Date).ToUniversalTime().ToString('o')
  data = [ordered]@{
    packageRoot = [System.IO.Path]::GetFullPath((Join-Path $Root 'packages/omegga-runtime'))
    sourceRepository = 'https://github.com/Ty-lerCox/bmf-omegga-fork'
    upstreamRepository = 'https://github.com/brickadia-community/omegga'
  }
  evidence = $evidence.ToArray()
  errors = $errors.ToArray()
}

$json = $result | ConvertTo-Json -Depth 10
$outPath = [System.IO.Path]::GetFullPath($OutJson)
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $outPath) | Out-Null
Set-Content -LiteralPath $outPath -Value $json -Encoding UTF8
Write-Output $json

if ($errors.Count -ne 0) {
  exit 1
}
