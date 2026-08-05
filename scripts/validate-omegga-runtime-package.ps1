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

# A development checkout may legitimately contain ignored dependency/build
# roots. Validate the tracked source boundary there; an extracted release has
# no matching git root, so validate its packaged filesystem directly.
function Get-SourceBoundary(
  [string]$RepositoryRoot,
  [string]$SourceRoot,
  [string]$SourceRelative,
  [System.Collections.Generic.HashSet[string]]$ForbiddenDirectoryNames
) {
  $repositoryFull = [System.IO.Path]::GetFullPath($RepositoryRoot)
  $gitCommand = Get-Command git -ErrorAction SilentlyContinue
  if ($gitCommand) {
    $gitTopOutput = @(& $gitCommand.Source -C $repositoryFull rev-parse --show-toplevel 2>$null)
    $gitTopExitCode = $LASTEXITCODE
    if ($gitTopExitCode -eq 0 -and $gitTopOutput.Count -gt 0) {
      $gitTop = [System.IO.Path]::GetFullPath(([string]$gitTopOutput[0]).Trim())
      if ($gitTop.Equals($repositoryFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        $trackedRelativeFiles = @(& $gitCommand.Source -C $repositoryFull ls-files -- $SourceRelative 2>$null)
        if ($LASTEXITCODE -ne 0) {
          throw 'Could not enumerate tracked Omegga source files with git ls-files.'
        }

        $files = [System.Collections.Generic.List[string]]::new()
        $forbiddenDirectories = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $sourcePrefix = $SourceRelative.TrimEnd('/') + '/'
        foreach ($relativePathValue in $trackedRelativeFiles) {
          $relativePath = ([string]$relativePathValue).Replace('\', '/')
          if (!$relativePath.StartsWith($sourcePrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            continue
          }
          $withinSource = $relativePath.Substring($sourcePrefix.Length)
          $fullPath = Join-Path $repositoryFull ($relativePath.Replace('/', [System.IO.Path]::DirectorySeparatorChar))
          if (Test-Path -LiteralPath $fullPath -PathType Leaf) {
            $files.Add([System.IO.Path]::GetFullPath($fullPath))
          }

          $parts = @($withinSource -split '/')
          for ($index = 0; $index -lt ($parts.Count - 1); $index += 1) {
            if ($ForbiddenDirectoryNames.Contains($parts[$index])) {
              [void]$forbiddenDirectories.Add(($parts[0..$index] -join '/'))
            }
          }
        }

        return [pscustomobject]@{
          mode = 'git-tracked'
          files = $files.ToArray()
          forbiddenDirectories = @($forbiddenDirectories | Sort-Object)
        }
      }
    }
  }

  $files = [System.Collections.Generic.List[string]]::new()
  $forbiddenDirectories = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
  $directories = [System.Collections.Generic.Stack[string]]::new()
  $directories.Push([System.IO.Path]::GetFullPath($SourceRoot))
  while ($directories.Count -gt 0) {
    $directory = $directories.Pop()
    foreach ($file in Get-ChildItem -LiteralPath $directory -File -Force -ErrorAction SilentlyContinue) {
      $files.Add($file.FullName)
    }
    foreach ($child in Get-ChildItem -LiteralPath $directory -Directory -Force -ErrorAction SilentlyContinue) {
      if ($ForbiddenDirectoryNames.Contains($child.Name)) {
        $relativeGenerated = $child.FullName.Substring($SourceRoot.Length).TrimStart('\', '/').Replace('\', '/')
        [void]$forbiddenDirectories.Add($relativeGenerated)
      } else {
        $directories.Push($child.FullName)
      }
    }
  }

  return [pscustomobject]@{
    mode = 'packaged-filesystem'
    files = $files.ToArray()
    forbiddenDirectories = @($forbiddenDirectories | Sort-Object)
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
  $sourceRootRelative = 'packages/omegga-runtime/source'
  $sourceBoundaryMode = 'unavailable'
  $sourceBoundaryFileCount = 0
  $sourceBoundaryForbiddenDirectories = @()

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
    if ([string]$packageManifest.sourceRepository -ne 'https://github.com/Ty-lerCox/brickadia-modding-framework') {
      $errors.Add('Omegga runtime package sourceRepository must be the BMF repository URL.')
    }
    if ([string]$packageManifest.upstreamRepository -ne 'https://github.com/brickadia-community/omegga') {
      $errors.Add('Omegga runtime package upstreamRepository must be upstream Omegga.')
    }
    if ([string]$packageManifest.status -ne 'synced-source') {
      $errors.Add('Omegga runtime package status must be synced-source.')
    }
    if ([string]$packageManifest.importMode -ne 'vendored-source') {
      $errors.Add('Omegga runtime package importMode must be vendored-source.')
    }
    if (![string]::IsNullOrWhiteSpace([string]$packageManifest.sourceCommit) -and [string]$packageManifest.sourceCommit -notmatch '^[a-f0-9]{40}$') {
      $errors.Add('Omegga runtime package sourceCommit must be a git SHA when present.')
    }
    if ([string]$packageManifest.upstreamCommit -notmatch '^[a-f0-9]{40}$') {
      $errors.Add('Omegga runtime package upstreamCommit must be a git SHA.')
    }
    if ([string]::IsNullOrWhiteSpace([string]$packageManifest.upstreamVersion)) {
      $errors.Add('Omegga runtime package upstreamVersion must be recorded.')
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
    foreach ($guardrail in @('do-not-vendor-node-modules', 'record-supported-upstream-commit-before-release', 'preserve-upstream-license-notice', 'keep-server-data-out-of-source', 'canonical-bmf-runtime-template-byte-parity', 'no-async-lua-scheduler-callbacks', 'no-global-delayed-action-clears', 'detect-forbidden-scheduler-aliases', 'lua-5.3-compile-before-package')) {
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
    if ([string]$syncMetadata.sourceRepository -ne 'https://github.com/Ty-lerCox/brickadia-modding-framework') {
      $errors.Add('Omegga sync metadata must record the BMF repository.')
    }
    if ([string]$syncMetadata.upstreamRepository -ne 'https://github.com/brickadia-community/omegga') {
      $errors.Add('Omegga sync metadata must record upstream Omegga.')
    }
    if ([string]$syncMetadata.sourceCommit -notmatch '^[a-f0-9]{40}$') {
      $errors.Add('Omegga sync metadata must record a sourceCommit git SHA.')
    }
    if ([string]$syncMetadata.upstreamCommit -notmatch '^[a-f0-9]{40}$') {
      $errors.Add('Omegga sync metadata must record an upstreamCommit git SHA.')
    }
    if ([string]::IsNullOrWhiteSpace([string]$syncMetadata.upstreamVersion)) {
      $errors.Add('Omegga sync metadata must record upstreamVersion.')
    }
    foreach ($copied in @('CHANGELOG.md', 'drizzle.config.ts', 'drizzle.plugin.config.ts', 'package.json', 'package-lock.json', 'src', 'templates', 'tools', 'frontend', 'bin')) {
      Test-Contains @($syncMetadata.copiedItems) $copied "Omegga sync metadata copiedItems are missing: $copied"
    }
    foreach ($excluded in @('node_modules', 'data', 'logs', 'artifacts', 'dist', 'plugins', 'plugins-disabled')) {
      Test-Contains @($syncMetadata.excludedNames) $excluded "Omegga sync metadata excludedNames are missing: $excluded"
    }
    foreach ($generated in @('node_modules', '.vite', '.angular', 'dist', 'logs', 'artifacts', 'target')) {
      Test-Contains @($syncMetadata.generatedExcludedNames) $generated "Omegga sync metadata generatedExcludedNames are missing: $generated"
    }
  }

  if (Test-Path -LiteralPath $sourceRoot) {
    $forbiddenDirectoryNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($name in @('node_modules', '.vite', '.angular', 'dist', 'logs', 'artifacts', 'target')) {
      [void]$forbiddenDirectoryNames.Add($name)
    }
    $sourceBoundary = Get-SourceBoundary $Root $sourceRoot $sourceRootRelative $forbiddenDirectoryNames
    $sourceBoundaryMode = [string]$sourceBoundary.mode
    $sourceBoundaryFiles = @($sourceBoundary.files)
    $sourceBoundaryFileCount = $sourceBoundaryFiles.Count
    $boundaryForbiddenDirectories = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($relativeGenerated in @($sourceBoundary.forbiddenDirectories)) {
      [void]$boundaryForbiddenDirectories.Add([string]$relativeGenerated)
    }
    $rootOnlyExcludedNames = @('data', 'plugins', 'plugins-disabled')
    foreach ($sourceFile in $sourceBoundaryFiles) {
      $withinSource = $sourceFile.Substring($sourceRoot.Length).TrimStart('\', '/').Replace('\', '/')
      $parts = @($withinSource -split '/')
      if ($parts.Count -gt 1 -and $parts[0] -in $rootOnlyExcludedNames) {
        [void]$boundaryForbiddenDirectories.Add($parts[0])
      }
    }
    $sourceBoundaryForbiddenDirectories = @($boundaryForbiddenDirectories | Sort-Object)
    foreach ($relativeGenerated in $sourceBoundaryForbiddenDirectories) {
      $errors.Add("Omegga $sourceBoundaryMode source boundary contains forbidden generated directory: $relativeGenerated")
    }

    foreach ($relative in @(
      'package.json',
      'package-lock.json',
      'LICENSE',
      'index.js',
      'bin/omegga',
      'src/brickadia/ue4ssBridge.ts',
      'src/omegga/index.ts',
      'tools/package-bmf-omegga.js',
      'tools/validate-lua-runtime.js',
      'tools/validate-lua-runtime.test.js',
      'templates/windows-ue4ss/ue4ss/Mods/BMF/Scripts/main.lua',
      'templates/windows-ue4ss/ue4ss/Mods/BMF/Scripts/bmf/runtime.lua',
      'templates/windows-ue4ss/ue4ss/Mods/OmeggaBridge/Scripts/main.lua'
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
      if ([string]$sourcePackage.scripts.'test:lua-runtime-guard' -ne 'node --test tools/validate-lua-runtime.test.js') {
        $errors.Add('Synced Omegga package.json must expose the pinned Lua runtime guard regression test.')
      }
      if ([string]$sourcePackage.devDependencies.fengari -ne '0.1.5') {
        $errors.Add('Synced Omegga package.json must pin fengari 0.1.5 for Lua 5.3 compilation.')
      }
      if ([string]$sourcePackage.devDependencies.luaparse -ne '0.3.1') {
        $errors.Add('Synced Omegga package.json must pin luaparse 0.3.1 for scheduler AST scanning.')
      }
    }
    foreach ($surface in @($packageManifest.requiredSurfaces)) {
      $surfaceFound = $false
      foreach ($sourceFile in $sourceBoundaryFiles) {
        if ([System.IO.Path]::GetExtension($sourceFile).ToLowerInvariant() -notin @('.js', '.cjs', '.mjs', '.ts', '.tsx', '.mts', '.lua', '.md', '.json', '.ps1', '.yml', '.yaml', '.txt', '.ini')) {
          continue
        }
        if (Select-String -LiteralPath $sourceFile -Pattern ([string]$surface) -SimpleMatch -Quiet -ErrorAction SilentlyContinue) {
          $surfaceFound = $true
          break
        }
      }
      if (!$surfaceFound) {
        $errors.Add("Synced Omegga source is missing required surface marker: $surface")
      }
    }
  }

  if (Test-Path -LiteralPath $readmePath) {
    $readme = Get-Content -Raw -LiteralPath $readmePath
    foreach ($needle in @('BMF-compatible Omegga runtime', 'https://github.com/Ty-lerCox/brickadia-modding-framework', 'https://github.com/brickadia-community/omegga', 'packages/omegga-runtime', 'sync-metadata.json', 'sync-omegga-runtime.ps1')) {
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
    sourceRepository = 'https://github.com/Ty-lerCox/brickadia-modding-framework'
    upstreamRepository = 'https://github.com/brickadia-community/omegga'
    sourceBoundaryMode = $sourceBoundaryMode
    sourceBoundaryFileCount = $sourceBoundaryFileCount
    sourceBoundaryForbiddenDirectories = @($sourceBoundaryForbiddenDirectories)
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
