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
    'framework/ue4ss/Mods/BMF/Scripts/main.lua',
    'cli/bin/bmfctl.js',
    'cli/package.json',
    'installer/install-bmf.ps1',
    'installer/uninstall-bmf.ps1',
    'scripts/validate-package.ps1',
    'manifests/bmf-package.json',
    'manifests/release-manifest.json'
  )) {
    if (!(Test-Path -LiteralPath (Join-Path $expandDir $required))) {
      $errors.Add("Expanded release package is missing required file: $required")
    }
  }

  if (Test-Path -LiteralPath (Join-Path $expandDir 'artifacts')) {
    $errors.Add('Expanded release package unexpectedly contains artifacts/.')
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
