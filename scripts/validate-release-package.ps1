param(
  [string]$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
  [string]$OutJson = '',
  [string]$ArtifactDir = ''
)

$ErrorActionPreference = 'Stop'

if (!$OutJson) {
  $OutJson = Join-Path $Root 'artifacts/local/release-package-canary.json'
}

$errors = New-Object System.Collections.Generic.List[string]
$evidence = New-Object System.Collections.Generic.List[object]
$startedAt = (Get-Date).ToUniversalTime().ToString('o')
$outPath = [System.IO.Path]::GetFullPath($OutJson)
if ($ArtifactDir) {
  $caseRoot = [System.IO.Path]::GetFullPath($ArtifactDir)
} else {
  $caseRoot = Join-Path (Split-Path -Parent $outPath) 'release-package'
}
$buildDir = Join-Path $caseRoot 'build'
$expandDir = Join-Path $caseRoot 'expanded'
$buildJsonPath = Join-Path $caseRoot 'release-build.json'
$expandedStaticJsonPath = Join-Path $caseRoot 'expanded-package-static.json'
$build = $null
$expandedStatic = $null
$releaseManifest = $null

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
  foreach ($path in @(
    (Join-Path $Root 'scripts/build-release-package.ps1'),
    (Join-Path $Root 'scripts/validate-package.ps1')
  )) {
    if (!(Test-Path -LiteralPath $path)) {
      throw "Required release validation script is missing: $path"
    }
  }

  if (Test-Path -LiteralPath $caseRoot) {
    Remove-Item -LiteralPath $caseRoot -Recurse -Force
  }
  New-Item -ItemType Directory -Force -Path $caseRoot | Out-Null

  $buildOutput = & (Join-Path $Root 'scripts/build-release-package.ps1') `
    -Root $Root `
    -OutDir $buildDir `
    -OutJson $buildJsonPath `
    -Force
  $build = $buildOutput | ConvertFrom-Json
  Add-Evidence 'json' $buildJsonPath 'Release build output JSON'
  if ($build.status -ne 'passed') {
    $errors.Add('Release build did not pass.')
  }
  if (!$build.data.zipPath -or !(Test-Path -LiteralPath $build.data.zipPath)) {
    throw 'Release zip was not created.'
  }
  Add-Evidence 'zip' $build.data.zipPath 'Release zip produced by build-release-package.ps1'

  New-Item -ItemType Directory -Force -Path $expandDir | Out-Null
  Expand-Archive -LiteralPath $build.data.zipPath -DestinationPath $expandDir -Force

  foreach ($required in @(
    'README.md',
    'package.json',
    '.github/workflows/unified-runtime.yml',
    '.github/workflows/docs-checks.yml',
    '.github/workflows/pages.yml',
    'framework/ue4ss/Mods/BMF/Scripts/main.lua',
    'framework/ue4ss/Mods/BMF/Scripts/bmf/runtime.lua',
    'cli/bin/bmfctl.js',
    'cli/package.json',
    'installer/install-bmf.ps1',
    'installer/uninstall-bmf.ps1',
    'scripts/validate-package.ps1',
    'scripts/validate-orchestrator-core.ps1',
    'scripts/validate-bmf-runtime-packages.ps1',
    'scripts/validate-bmf-runtime-template-parity.ps1',
    'scripts/sync-bmf-runtime-template.ps1',
    'scripts/validate-bmf-plugin-facade-safety.ps1',
    'scripts/validate-omegga-runtime-package.ps1',
    'scripts/sync-omegga-runtime.ps1',
    'scripts/validate-ue4ss-compat-package.ps1',
    'scripts/validate-bmf-desktop.ps1',
    'scripts/build-bmf-desktop-release.ps1',
    'scripts/validate-bmf-desktop-release.ps1',
    'scripts/validate-observability-assets.ps1',
    'scripts/validate-bmf-bridge-plugin.ps1',
    'scripts/validate-bmf-omegga-adapters.ps1',
    'manifests/bmf-package.json',
    'planning/roadmap/index.md',
    'planning/roadmap/public-overview.md',
    'planning/roadmap/goal.md',
    'planning/roadmap/monorepo-consolidation.md',
    'planning/roadmap/phase-plan.md',
    'planning/roadmap/bmf-desktop-control-panel.md',
    'planning/roadmap/service-health-model.md',
    'planning/roadmap/grafana-onboarding.md',
    'planning/roadmap/event-traffic-inspector.md',
    'planning/roadmap/release-artifacts.md',
    'compat/ue4ss/package-manifest.json',
    'compat/ue4ss/README.md',
    'observability/observability-manifest.json',
    'observability/alloy/bmf.alloy.template',
    'observability/grafana/bmf-dashboard.json',
    'observability/grafana/dashboard-import.json',
    'apps/bmf-desktop/package.json',
    'apps/bmf-desktop/package-lock.json',
    'apps/bmf-desktop/electron-builder.yml',
    'apps/bmf-desktop/packaged-assets/package.json',
    'apps/bmf-desktop/packaged-assets/bin/bmfctl.cmd',
    'apps/bmf-desktop/build/icon.ico',
    'apps/bmf-desktop/src/app/app.component.ts',
    'packages/orchestrator-core/package.json',
    'packages/orchestrator-core/src/index.js',
    'packages/orchestrator-core/src/observations.js',
    'packages/orchestrator-core/src/prerequisites.js',
    'packages/orchestrator-core/src/services.js',
    'packages/orchestrator-core/src/service-actions.js',
    'packages/orchestrator-core/src/telemetry.js',
    'packages/orchestrator-core/src/traffic.js',
    'packages/orchestrator-core/src/logs.js',
    'packages/orchestrator-core/src/snapshots.js',
    'packages/orchestrator-core/src/transactions.js',
    'packages/bmf-runtime/package-manifest.json',
    'packages/bmf-runtime/README.md',
    'packages/bmf-native-socket/package-manifest.json',
    'packages/bmf-native-socket/README.md',
    'packages/bmf-frame-telemetry/package-manifest.json',
    'packages/bmf-frame-telemetry/README.md',
    'packages/omegga-runtime/package-manifest.json',
    'packages/omegga-runtime/sync-metadata.json',
    'packages/omegga-runtime/README.md',
    'packages/omegga-runtime/source/package.json',
    'packages/omegga-runtime/source/package-lock.json',
    'packages/omegga-runtime/source/LICENSE',
    'packages/omegga-runtime/source/index.js',
    'packages/omegga-runtime/source/bin/omegga',
    'packages/omegga-runtime/source/src/brickadia/ue4ssBridge.ts',
    'packages/omegga-runtime/source/src/omegga/index.ts',
    'packages/omegga-runtime/source/tools/package-bmf-omegga.js',
    'packages/omegga-runtime/source/tools/validate-lua-runtime.js',
    'packages/omegga-runtime/source/tools/validate-lua-runtime.test.js',
    'packages/omegga-runtime/source/templates/windows-ue4ss/ue4ss/Mods/BMF/Scripts/main.lua',
    'packages/omegga-runtime/source/templates/windows-ue4ss/ue4ss/Mods/BMF/Scripts/bmf/runtime.lua',
    'packages/omegga-runtime/source/templates/windows-ue4ss/ue4ss/Mods/OmeggaBridge/Scripts/main.lua',
    'packages/omegga-plugins/bmf-bridge/plugin.json',
    'packages/omegga-plugins/bmf-bridge/doc.json',
    'packages/omegga-plugins/bmf-bridge/access.json',
    'packages/omegga-plugins/bmf-bridge/omegga.plugin.js',
    'packages/omegga-plugins/bmf-bridge/omegga.plugin.test.js',
    'packages/omegga-plugins/bmf-player-sync/plugin.json',
    'packages/omegga-plugins/bmf-player-sync/doc.json',
    'packages/omegga-plugins/bmf-player-sync/access.json',
    'packages/omegga-plugins/bmf-player-sync/omegga.plugin.js',
    'packages/omegga-plugins/bmf-player-sync/omegga.plugin.test.js',
    'packages/omegga-plugins/bmf-minigame-events/plugin.json',
    'packages/omegga-plugins/bmf-minigame-events/doc.json',
    'packages/omegga-plugins/bmf-minigame-events/access.json',
    'packages/omegga-plugins/bmf-minigame-events/omegga.plugin.js',
    'packages/omegga-plugins/bmf-minigame-events/omegga.plugin.test.js',
    'manifests/release-manifest.json'
  )) {
    if (!(Test-Path -LiteralPath (Join-Path $expandDir $required))) {
      $errors.Add("Expanded release package is missing required file: $required")
    }
  }

  if (Test-Path -LiteralPath (Join-Path $expandDir 'artifacts')) {
    $errors.Add('Expanded release package unexpectedly contains artifacts/.')
  }
  foreach ($excluded in @('apps/bmf-desktop/node_modules', 'apps/bmf-desktop/.angular', 'apps/bmf-desktop/dist')) {
    if (Test-Path -LiteralPath (Join-Path $expandDir $excluded)) {
      $errors.Add("Expanded release package unexpectedly contains generated directory: $excluded")
    }
  }

  $releaseManifestPath = Join-Path $expandDir 'manifests/release-manifest.json'
  if (Test-Path -LiteralPath $releaseManifestPath) {
    $releaseManifest = Get-Content -Raw -LiteralPath $releaseManifestPath | ConvertFrom-Json
    Add-Evidence 'json' $releaseManifestPath 'Release manifest from expanded package'
    if ([string]$releaseManifest.version -ne [string]$build.data.version) {
      $errors.Add("Release manifest version $($releaseManifest.version) did not match build version $($build.data.version).")
    }
    if (@($releaseManifest.files).Count -lt 1) {
      $errors.Add('Release manifest did not contain file hashes.')
    }
  }

  $staticOutput = & (Join-Path $expandDir 'scripts/validate-package.ps1') `
    -Root $expandDir `
    -OutJson $expandedStaticJsonPath
  $expandedStatic = $staticOutput | ConvertFrom-Json
  Add-Evidence 'json' $expandedStaticJsonPath 'Static package validation of expanded release zip'
  if ($expandedStatic.status -ne 'passed') {
    $errors.Add('Expanded release package failed static validation.')
  }
} catch {
  $errors.Add($_.Exception.Message)
}

$status = 'failed'
if ($errors.Count -eq 0) {
  $status = 'passed'
}
$buildData = $null
$expandedStaticData = $null
$releaseManifestFileCount = 0
if ($build) {
  $buildData = $build.data
}
if ($expandedStatic) {
  $expandedStaticData = $expandedStatic.data
}
if ($releaseManifest) {
  $releaseManifestFileCount = @($releaseManifest.files).Count
}

$result = [ordered]@{
  feature = 'release.package.static'
  status = $status
  validationLevel = 'L0 Static'
  startedAt = $startedAt
  finishedAt = (Get-Date).ToUniversalTime().ToString('o')
  data = [ordered]@{
    artifactDir = [System.IO.Path]::GetFullPath($caseRoot)
    build = $buildData
    expandedRoot = [System.IO.Path]::GetFullPath($expandDir)
    expandedStatic = $expandedStaticData
    releaseManifestFileCount = $releaseManifestFileCount
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
