param(
  [string]$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
  [string]$OutJson = '',
  [string]$ArtifactDir = ''
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

function Add-Evidence([string]$Kind, [string]$Path, [string]$Summary) {
  if ($Path -and (Test-Path -LiteralPath $Path)) {
    $script:evidence.Add([ordered]@{
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

function Test-HasProperty($Object, [string]$Name) {
  if (!$Object) {
    return $false
  }
  return ($Object.PSObject.Properties.Name -contains $Name)
}

function Test-HasValue($Value) {
  if ($null -eq $Value) {
    return $false
  }
  if ($Value -is [string]) {
    return ![string]::IsNullOrWhiteSpace($Value)
  }
  if ($Value -is [array]) {
    return @($Value).Count -gt 0
  }
  if ($Value.PSObject -and $Value.PSObject.Properties.Count -gt 0) {
    return $true
  }
  return $true
}

if (!$OutJson) {
  $OutJson = Join-Path $Root 'artifacts/local/bmf-desktop-release-validation.json'
}

$errors = New-Object System.Collections.Generic.List[string]
$evidence = New-Object System.Collections.Generic.List[object]
$startedAt = (Get-Date).ToUniversalTime().ToString('o')
$outPath = Get-FullPath $OutJson
$artifactsRoot = Get-FullPath (Join-Path $Root 'artifacts/local')
if ($ArtifactDir) {
  $caseRoot = Get-FullPath $ArtifactDir
} else {
  $caseRoot = Join-Path (Split-Path -Parent $outPath) 'bmf-desktop-release-fixture-validation'
}
$fixtureDir = Join-Path $caseRoot 'fixtures'
$releaseDir = Join-Path $caseRoot 'release'
$buildJsonPath = Join-Path $caseRoot 'desktop-release-build.json'
$builderPath = Join-Path $Root 'scripts/build-bmf-desktop-release.ps1'
$unifiedRuntimePath = Join-Path $Root 'manifests/unified-runtime.json'
$build = $null
$manifest = $null
$catalog = $null

try {
  if (!(Test-Path -LiteralPath $builderPath)) {
    throw "Desktop release builder is missing: $builderPath"
  }
  $builderText = Get-Content -Raw -LiteralPath $builderPath
  foreach ($marker in @(
    '[switch]$BuildMsi',
    '[string]$NodeExe = $env:BMF_DESKTOP_NODE_EXE',
    'Resolve-NodeExecutable',
    'Test-IsSupportedDesktopNodeVersion',
    'Test-DesktopBundledAssets',
    'Test-DesktopBmfctlShim',
    '22.22.3',
    '24.15.0',
    'node_modules/@angular/cli/bin/ng.js',
    'node_modules/electron-builder/cli.js',
    "'--win', 'msi', '--x64'",
    'dist/release/win-unpacked/resources/bmf',
    'bin/bmfctl.cmd',
    'apps/bmf-desktop/package.json',
    'cli/bin/bmfctl.js',
    'packages/orchestrator-core/src/index.js',
    'packages/omegga-runtime/sync-metadata.json',
    'packages/omegga-runtime/source/package.json',
    'packages/omegga-runtime/source/src/brickadia/ue4ssBridge.ts',
    'packages/omegga-runtime/source/src/omegga/index.ts',
    'packages/omegga-plugins/bmf-bridge/plugin.json',
    'observability/grafana/bmf-dashboard.json',
    'sourceCommit',
    'bmfctlShim',
    'desktopBuild'
  )) {
    if ($builderText -notmatch [regex]::Escape($marker)) {
      $errors.Add("Desktop release builder is missing real MSI build marker: $marker")
    }
  }
  if (!(Test-IsChildPath $artifactsRoot $caseRoot)) {
    throw "Refusing to clean desktop release validation directory outside artifacts/local: $caseRoot"
  }
  if (Test-Path -LiteralPath $caseRoot) {
    Remove-Item -LiteralPath $caseRoot -Recurse -Force
  }
  New-Item -ItemType Directory -Force -Path $fixtureDir | Out-Null

  $fixtureMsiPath = Join-Path $fixtureDir 'fixture.msi'
  [System.IO.File]::WriteAllBytes($fixtureMsiPath, [byte[]](0x4D, 0x53, 0x49, 0x0D, 0x0A, 0x42, 0x4D, 0x46))
  Add-Evidence 'msi' $fixtureMsiPath 'Tiny MSI-shaped fixture used for release metadata validation'

  $buildOutput = & $builderPath `
    -Root $Root `
    -MsiPath $fixtureMsiPath `
    -Version '0.1.0-dev' `
    -OutDir $releaseDir `
    -OutJson $buildJsonPath `
    -ReleaseChannel 'dev' `
    -DownloadBaseUrl 'https://downloads.example/bmf' `
    -Force
  $build = $buildOutput | ConvertFrom-Json
  Add-Evidence 'json' $buildJsonPath 'BMF Desktop release build output JSON'
  if ($build.status -ne 'passed') {
    $errors.Add('BMF Desktop release build did not pass.')
    foreach ($errorItem in @($build.errors)) {
      $errors.Add("desktop-release-build: $errorItem")
    }
  }

  $expectedArtifactName = 'BMF-Desktop-0.1.0-dev-x64.msi'
  $primaryArtifactPath = Join-Path $releaseDir $expectedArtifactName
  $checksumPath = "$primaryArtifactPath.sha256"
  $releaseManifestPath = Join-Path $releaseDir 'release-manifest.json'
  $releaseCatalogPath = Join-Path $releaseDir 'release-catalog.json'
  $releaseNotesPath = Join-Path $releaseDir 'RELEASE_NOTES.md'
  foreach ($required in @($primaryArtifactPath, $checksumPath, $releaseManifestPath, $releaseCatalogPath, $releaseNotesPath)) {
    if (!(Test-Path -LiteralPath $required)) {
      $errors.Add("Desktop release output is missing: $required")
    }
  }
  Add-Evidence 'msi' $primaryArtifactPath 'Generated primary MSI artifact'
  Add-Evidence 'checksum' $checksumPath 'Generated primary MSI checksum'
  Add-Evidence 'json' $releaseManifestPath 'Generated BMF Desktop release manifest'
  Add-Evidence 'json' $releaseCatalogPath 'Generated BMF Desktop release catalog'
  Add-Evidence 'markdown' $releaseNotesPath 'Generated BMF Desktop release notes'

  if (Test-Path -LiteralPath $primaryArtifactPath) {
    $expectedHash = Get-Sha256Hex $primaryArtifactPath
    if ($build -and [string]$build.data.installerSha256 -ne $expectedHash) {
      $errors.Add('Build output installerSha256 does not match the generated MSI hash.')
    }
    if (Test-Path -LiteralPath $checksumPath) {
      $checksumText = (Get-Content -Raw -LiteralPath $checksumPath).Trim()
      if (!$checksumText.StartsWith($expectedHash, [System.StringComparison]::OrdinalIgnoreCase)) {
        $errors.Add('Checksum file does not start with the MSI SHA256 hash.')
      }
      if ($checksumText -notmatch [regex]::Escape($expectedArtifactName)) {
        $errors.Add('Checksum file does not include the MSI artifact name.')
      }
    }
  }

  if (Test-Path -LiteralPath $releaseManifestPath) {
    $manifest = Get-Content -Raw -LiteralPath $releaseManifestPath | ConvertFrom-Json
    $unifiedRuntime = Get-Content -Raw -LiteralPath $unifiedRuntimePath | ConvertFrom-Json
    foreach ($field in @($unifiedRuntime.release.manifest)) {
      if (!(Test-HasProperty $manifest $field)) {
        $errors.Add("Desktop release manifest is missing required field from unified runtime manifest: $field")
      } elseif (!(Test-HasValue $manifest.$field)) {
        $errors.Add("Desktop release manifest field is empty: $field")
      }
    }
    if ([string]$manifest.bmfDesktopVersion -ne '0.1.0-dev') {
      $errors.Add("Unexpected BMF Desktop version in release manifest: $($manifest.bmfDesktopVersion)")
    }
    if ([string]$manifest.omeggaRuntimeVersionOrCommit -notmatch '^[a-f0-9]{40}$') {
      $errors.Add("Release manifest Omegga runtime value must be the synced fork commit: $($manifest.omeggaRuntimeVersionOrCommit)")
    }
    if ([string]$manifest.primaryArtifact.fileName -ne $expectedArtifactName) {
      $errors.Add("Unexpected primary artifact in release manifest: $($manifest.primaryArtifact.fileName)")
    }
    if (@($manifest.requiredArtifacts) -notcontains $expectedArtifactName) {
      $errors.Add('Release manifest requiredArtifacts does not include the MSI.')
    }
    if (@($manifest.requiredArtifacts) -notcontains "$expectedArtifactName.sha256") {
      $errors.Add('Release manifest requiredArtifacts does not include the MSI checksum.')
    }
    if (@($manifest.requiredArtifacts) -notcontains 'release-catalog.json') {
      $errors.Add('Release manifest requiredArtifacts does not include the release catalog.')
    }
    if ([string]$manifest.releaseCatalog -ne 'release-catalog.json') {
      $errors.Add("Release manifest does not point at release-catalog.json: $($manifest.releaseCatalog)")
    }
    if (@($manifest.files).Count -lt 3) {
      $errors.Add('Release manifest does not include artifact file records.')
    }
  }

  if (Test-Path -LiteralPath $releaseCatalogPath) {
    $catalog = Get-Content -Raw -LiteralPath $releaseCatalogPath | ConvertFrom-Json
    if ([int]$catalog.schemaVersion -lt 1) {
      $errors.Add('Release catalog schemaVersion must be >= 1.')
    }
    if ([string]$catalog.catalogKind -ne 'bmf-desktop-release-catalog') {
      $errors.Add("Unexpected release catalog kind: $($catalog.catalogKind)")
    }
    if ([string]$catalog.releaseChannel -ne 'dev') {
      $errors.Add("Unexpected release catalog channel: $($catalog.releaseChannel)")
    }
    if ([string]$catalog.latest.version -ne '0.1.0-dev') {
      $errors.Add("Unexpected latest release version in catalog: $($catalog.latest.version)")
    }
    if ([string]$catalog.latest.artifact.fileName -ne $expectedArtifactName) {
      $errors.Add("Release catalog latest artifact does not point at the MSI: $($catalog.latest.artifact.fileName)")
    }
    if ([string]$catalog.latest.artifact.url -ne "https://downloads.example/bmf/$expectedArtifactName") {
      $errors.Add("Release catalog latest artifact URL is unexpected: $($catalog.latest.artifact.url)")
    }
    if ([string]$catalog.latest.artifact.sha256 -ne [string]$build.data.installerSha256) {
      $errors.Add('Release catalog latest artifact hash does not match build output.')
    }
    if ([string]$catalog.latest.manifest.fileName -ne 'release-manifest.json') {
      $errors.Add("Release catalog latest manifest is unexpected: $($catalog.latest.manifest.fileName)")
    }
    if (@($catalog.releases).Count -lt 1) {
      $errors.Add('Release catalog does not contain any releases.')
    }
    foreach ($guardrail in @(
      'verify-sha256-before-install',
      'require-user-confirmation-before-desktop-update',
      'keep-desktop-update-separate-from-managed-server-updates',
      'do-not-stop-running-managed-services-without-confirmation'
    )) {
      if ($guardrail -notin @($catalog.updateGuardrails)) {
        $errors.Add("Release catalog is missing update guardrail: $guardrail")
      }
    }
  }

  foreach ($generatedPath in @(
    $build.data.primaryArtifactPath,
    $build.data.checksumPath,
    $build.data.releaseManifestPath,
    $build.data.releaseCatalogPath,
    $build.data.releaseNotesPath
  )) {
    if ($generatedPath -and !(Test-IsChildPath $releaseDir $generatedPath)) {
      $errors.Add("Generated path is outside the release artifact directory: $generatedPath")
    }
  }
} catch {
  $errors.Add($_.Exception.Message)
}

$status = if ($errors.Count -eq 0) { 'passed' } else { 'failed' }
$result = [ordered]@{
  feature = 'bmf-desktop.release.static'
  status = $status
  validationLevel = 'L0 Static'
  startedAt = $startedAt
  finishedAt = (Get-Date).ToUniversalTime().ToString('o')
  data = [ordered]@{
    artifactDir = Get-FullPath $caseRoot
    releaseDir = Get-FullPath $releaseDir
    build = if ($build) { $build.data } else { $null }
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
