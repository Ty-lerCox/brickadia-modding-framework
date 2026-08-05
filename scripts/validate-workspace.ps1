param(
  [string]$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
  [string]$OutJson = ''
)

$ErrorActionPreference = 'Stop'

if (!$OutJson) {
  $OutJson = Join-Path $Root 'artifacts/local/workspace-validation.json'
}

function Add-Evidence([System.Collections.Generic.List[object]]$Evidence, [string]$Kind, [string]$Path, [string]$Summary) {
  if ($Path -and (Test-Path -LiteralPath $Path)) {
    $Evidence.Add([ordered]@{
      kind = $Kind
      path = [System.IO.Path]::GetFullPath($Path)
      summary = $Summary
    })
  }
}

function Get-JsonPropertyValue($Object, [string]$Name) {
  $property = $Object.PSObject.Properties | Where-Object { $_.Name -eq $Name } | Select-Object -First 1
  if ($property) {
    return $property.Value
  }
  return $null
}

function Require-Script($Scripts, [string]$Name, [string]$Needle, [System.Collections.Generic.List[string]]$Errors) {
  $scriptValue = Get-JsonPropertyValue $Scripts $Name
  if (!$scriptValue) {
    $Errors.Add("Root package.json is missing script: $Name")
    return
  }
  if ($Needle -and ([string]$scriptValue -notmatch [regex]::Escape($Needle))) {
    $Errors.Add("Root package.json script '$Name' must contain: $Needle")
  }
}

$errors = New-Object System.Collections.Generic.List[string]
$evidence = New-Object System.Collections.Generic.List[object]
$startedAt = (Get-Date).ToUniversalTime().ToString('o')
$packageJsonPath = Join-Path $Root 'package.json'
$packageJson = $null

try {
  foreach ($required in @(
    $packageJsonPath,
    (Join-Path $Root 'README.md'),
    (Join-Path $Root 'planning/roadmap/goal.md'),
    (Join-Path $Root 'planning/roadmap/phase-plan.md'),
    (Join-Path $Root 'planning/roadmap/monorepo-consolidation.md'),
    (Join-Path $Root 'apps/bmf-desktop/package-lock.json'),
    (Join-Path $Root 'packages/omegga-runtime/source/package-lock.json')
  )) {
    if (!(Test-Path -LiteralPath $required)) {
      $errors.Add("Missing workspace file: $required")
    }
  }

  if (Test-Path -LiteralPath $packageJsonPath) {
    $packageJson = Get-Content -Raw -LiteralPath $packageJsonPath | ConvertFrom-Json
    Add-Evidence $evidence 'json' $packageJsonPath 'root workspace package manifest'

    if ([string]$packageJson.name -ne '@bmf/workspace') {
      $errors.Add('Root package.json must be named @bmf/workspace.')
    }
    if ($packageJson.private -ne $true) {
      $errors.Add('Root package.json must be private.')
    }
    if ([string]$packageJson.engines.node -ne '^22.22.3 || ^24.15.0 || >=26.0.0') {
      $errors.Add('Root package.json Node engine must match the Desktop Angular engine floor.')
    }

    $workspaces = @($packageJson.workspaces)
    foreach ($workspace in @('apps/bmf-desktop', 'cli', 'packages/orchestrator-core')) {
      if ($workspaces -notcontains $workspace) {
        $errors.Add("Root package.json is missing workspace: $workspace")
      }
    }
    foreach ($excludedWorkspace in @('packages/omegga-runtime/source', 'apps/bmf-desktop/packaged-assets')) {
      if ($workspaces -contains $excludedWorkspace) {
        $errors.Add("Root package.json must keep dependency island out of npm workspaces: $excludedWorkspace")
      }
    }

    $scripts = $packageJson.scripts
    Require-Script $scripts 'setup' 'install:desktop' $errors
    Require-Script $scripts 'setup' 'install:omegga' $errors
    Require-Script $scripts 'install:desktop' 'npm --prefix apps/bmf-desktop ci' $errors
    Require-Script $scripts 'install:omegga' 'npm --prefix packages/omegga-runtime/source ci' $errors
    Require-Script $scripts 'build:desktop' 'npm --prefix apps/bmf-desktop run build' $errors
    Require-Script $scripts 'release:desktop' 'scripts/build-bmf-desktop-release.ps1' $errors
    Require-Script $scripts 'test:core' 'npm --prefix packages/orchestrator-core test' $errors
    Require-Script $scripts 'test:cli' 'npm --prefix cli test' $errors
    Require-Script $scripts 'doctor' 'cli/bin/bmfctl.js doctor' $errors
    Require-Script $scripts 'sync:runtime-template' 'scripts/sync-bmf-runtime-template.ps1' $errors
    Require-Script $scripts 'validate' 'scripts/validate-package.ps1' $errors
    Require-Script $scripts 'validate:workspace' 'scripts/validate-workspace.ps1' $errors
    Require-Script $scripts 'validate:ci' 'scripts/validate-ci-workflows.ps1' $errors
    Require-Script $scripts 'validate:desktop' 'scripts/validate-bmf-desktop.ps1' $errors
    Require-Script $scripts 'validate:orchestrator' 'scripts/validate-orchestrator-core.ps1' $errors
    Require-Script $scripts 'validate:runtime-packages' 'scripts/validate-bmf-runtime-packages.ps1' $errors
    Require-Script $scripts 'validate:runtime-template-parity' 'scripts/validate-bmf-runtime-template-parity.ps1' $errors
    Require-Script $scripts 'validate:plugin-facade-safety' 'scripts/validate-bmf-plugin-facade-safety.ps1' $errors
    Require-Script $scripts 'validate:release' 'scripts/validate-release-package.ps1' $errors
  }

  $expectedWorkspacePackages = [ordered]@{
    'apps/bmf-desktop' = '@bmf/desktop'
    'cli' = '@bmf/bmfctl'
    'packages/orchestrator-core' = '@bmf/orchestrator-core'
  }
  foreach ($entry in $expectedWorkspacePackages.GetEnumerator()) {
    $workspacePackagePath = Join-Path $Root (Join-Path $entry.Key 'package.json')
    if (!(Test-Path -LiteralPath $workspacePackagePath)) {
      $errors.Add("Workspace package is missing package.json: $($entry.Key)")
      continue
    }
    $workspacePackage = Get-Content -Raw -LiteralPath $workspacePackagePath | ConvertFrom-Json
    Add-Evidence $evidence 'json' $workspacePackagePath "workspace package: $($entry.Key)"
    if ([string]$workspacePackage.name -ne [string]$entry.Value) {
      $errors.Add("Workspace package $($entry.Key) must be named $($entry.Value).")
    }
  }

  $rootReadmePath = Join-Path $Root 'README.md'
  if (Test-Path -LiteralPath $rootReadmePath) {
    $readmeText = Get-Content -Raw -LiteralPath $rootReadmePath
    Add-Evidence $evidence 'markdown' $rootReadmePath 'root README workspace entry point'
    foreach ($needle in @('## Root Workspace', 'npm run setup', 'npm run validate', 'npm run validate:ci', 'npm run release:desktop')) {
      if ($readmeText -notmatch [regex]::Escape($needle)) {
        $errors.Add("README.md does not contain expected root workspace marker: $needle")
      }
    }
  }

  $monorepoDocPath = Join-Path $Root 'planning/roadmap/monorepo-consolidation.md'
  if (Test-Path -LiteralPath $monorepoDocPath) {
    $monorepoText = Get-Content -Raw -LiteralPath $monorepoDocPath
    Add-Evidence $evidence 'markdown' $monorepoDocPath 'monorepo consolidation workspace contract'
    foreach ($needle in @('## Root Workspace Contract', 'dependency islands', 'scripts/validate-workspace.ps1')) {
      if ($monorepoText -notmatch [regex]::Escape($needle)) {
        $errors.Add("monorepo-consolidation.md does not contain expected workspace marker: $needle")
      }
    }
  }

  $phasePlanPath = Join-Path $Root 'planning/roadmap/phase-plan.md'
  if (Test-Path -LiteralPath $phasePlanPath) {
    $phasePlanText = Get-Content -Raw -LiteralPath $phasePlanPath
    Add-Evidence $evidence 'markdown' $phasePlanPath 'phase plan workspace exit criteria'
    foreach ($needle in @('root `package.json`', 'scripts/validate-workspace.ps1', 'npm run setup')) {
      if ($phasePlanText -notmatch [regex]::Escape($needle)) {
        $errors.Add("phase-plan.md does not contain expected workspace marker: $needle")
      }
    }
  }

  $goalPath = Join-Path $Root 'planning/roadmap/goal.md'
  if (Test-Path -LiteralPath $goalPath) {
    $goalText = Get-Content -Raw -LiteralPath $goalPath
    Add-Evidence $evidence 'markdown' $goalPath 'goal workspace reference'
    foreach ($needle in @('Root workspace', 'scripts/validate-workspace.ps1', 'npm run setup')) {
      if ($goalText -notmatch [regex]::Escape($needle)) {
        $errors.Add("goal.md does not contain expected workspace marker: $needle")
      }
    }
  }

  foreach ($commandName in @('node', 'npm')) {
    if (!(Get-Command $commandName -ErrorAction SilentlyContinue)) {
      $errors.Add("$commandName is required for the root workspace setup contract.")
    }
  }
} catch {
  $errors.Add($_.Exception.Message)
}

$result = [ordered]@{
  feature = 'workspace.static'
  status = if ($errors.Count -eq 0) { 'passed' } else { 'failed' }
  validationLevel = 'L0 Static'
  startedAt = $startedAt
  finishedAt = (Get-Date).ToUniversalTime().ToString('o')
  data = [ordered]@{
    package = if ($packageJson) { $packageJson.name } else { $null }
    workspaces = if ($packageJson) { @($packageJson.workspaces) } else { @() }
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
