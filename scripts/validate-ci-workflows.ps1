param(
  [string]$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
  [string]$OutJson = ''
)

$ErrorActionPreference = 'Stop'

if (!$OutJson) {
  $OutJson = Join-Path $Root 'artifacts/local/ci-workflows-validation.json'
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

$errors = New-Object System.Collections.Generic.List[string]
$evidence = New-Object System.Collections.Generic.List[object]
$startedAt = (Get-Date).ToUniversalTime().ToString('o')
$workflowPath = Join-Path $Root '.github/workflows/unified-runtime.yml'
$packageJsonPath = Join-Path $Root 'package.json'
$workflowText = ''

try {
  foreach ($required in @(
    $workflowPath,
    $packageJsonPath,
    (Join-Path $Root '.github/workflows/docs-checks.yml'),
    (Join-Path $Root '.github/workflows/pages.yml')
  )) {
    if (!(Test-Path -LiteralPath $required)) {
      $errors.Add("Missing CI file: $required")
    }
  }

  if (Test-Path -LiteralPath $workflowPath) {
    $workflowText = Get-Content -Raw -LiteralPath $workflowPath
    Add-Evidence $evidence 'yaml' $workflowPath 'Unified runtime GitHub Actions workflow'

    foreach ($needle in @(
      'name: Unified runtime CI',
      'pull_request:',
      'push:',
      'branches:',
      '- main',
      'workflow_dispatch:',
      'permissions:',
      'contents: read',
      'NODE_VERSION: "24.15.0"',
      'runs-on: windows-latest',
      'runs-on: ubuntu-latest',
      'actions/checkout@v4',
      'actions/setup-node@v4',
      'actions/setup-python@v5',
      'npm run validate:workspace',
      'npm run validate',
      'npm run test',
      'npm run install:desktop',
      'npm run build:desktop',
      'npm run validate:desktop',
      'scripts/validate-bmf-desktop-release.ps1',
      'scripts/validate-omegga-runtime-package.ps1',
      'npm --prefix packages/omegga-runtime/source ci',
      'npm --prefix packages/omegga-runtime/source test',
      'scripts/validate-bmf-runtime-packages.ps1',
      'BMF_UE4SS_SOURCE_DIR',
      'scripts/build-bmf-socket-native-mod.ps1',
      'scripts/build-bmf-frame-telemetry-native-mod.ps1',
      'npm run validate:release',
      'python -m mkdocs build --strict',
      'npm run release:desktop',
      'actions/upload-artifact@v4',
      'bmf-desktop-msi-release',
      'artifacts/local/bmf-desktop-release/**'
    )) {
      if ($workflowText -notmatch [regex]::Escape($needle)) {
        $errors.Add("unified-runtime.yml does not contain expected CI marker: $needle")
      }
    }

    foreach ($pathMarker in @(
      'apps/bmf-desktop/**',
      'cli/**',
      'compat/**',
      'framework/ue4ss/Mods/**',
      'manifests/**',
      'native/**',
      'observability/**',
      'packages/**',
      'planning/**',
      'scripts/**'
    )) {
      if ($workflowText -notmatch [regex]::Escape($pathMarker)) {
        $errors.Add("unified-runtime.yml does not watch required path: $pathMarker")
      }
    }

    foreach ($jobName in @(
      'workspace:',
      'desktop:',
      'omegga-runtime:',
      'native-helpers:',
      'packaging:',
      'docs:',
      'desktop-msi:'
    )) {
      if ($workflowText -notmatch "(?m)^  $([regex]::Escape($jobName))") {
        $errors.Add("unified-runtime.yml is missing job: $jobName")
      }
    }
  }

  if (Test-Path -LiteralPath $packageJsonPath) {
    $packageJson = Get-Content -Raw -LiteralPath $packageJsonPath | ConvertFrom-Json
    Add-Evidence $evidence 'json' $packageJsonPath 'Root package scripts for CI validation'
    $scriptValue = $packageJson.scripts.'validate:ci'
    if (!$scriptValue) {
      $errors.Add('Root package.json is missing script: validate:ci')
    } elseif ([string]$scriptValue -notmatch [regex]::Escape('scripts/validate-ci-workflows.ps1')) {
      $errors.Add('Root package.json validate:ci script must call scripts/validate-ci-workflows.ps1.')
    }
  }

  foreach ($doc in @(
    (Join-Path $Root 'README.md'),
    (Join-Path $Root 'planning/roadmap/phase-plan.md'),
    (Join-Path $Root 'planning/roadmap/goal.md'),
    (Join-Path $Root 'planning/roadmap/release-artifacts.md')
  )) {
    if (!(Test-Path -LiteralPath $doc)) {
      $errors.Add("Missing CI documentation target: $doc")
      continue
    }
    $docText = Get-Content -Raw -LiteralPath $doc
    Add-Evidence $evidence 'markdown' $doc 'CI roadmap documentation'
    if ($docText -notmatch [regex]::Escape('unified-runtime.yml')) {
      $errors.Add("$doc does not reference unified-runtime.yml")
    }
  }
} catch {
  $errors.Add($_.Exception.Message)
}

$result = [ordered]@{
  feature = 'ci.workflows.static'
  status = if ($errors.Count -eq 0) { 'passed' } else { 'failed' }
  validationLevel = 'L0 Static'
  startedAt = $startedAt
  finishedAt = (Get-Date).ToUniversalTime().ToString('o')
  data = [ordered]@{
    workflow = if ($workflowPath) { [System.IO.Path]::GetFullPath($workflowPath) } else { $null }
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
