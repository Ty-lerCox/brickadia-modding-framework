param(
  [string]$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
  [string]$OutJson = ''
)

$ErrorActionPreference = 'Stop'

if (!$OutJson) {
  $OutJson = Join-Path $Root 'artifacts/local/ue4ss-compat-package-validation.json'
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
  $packageRoot = Join-Path $Root 'compat/ue4ss'
  $packageManifestPath = Join-Path $packageRoot 'package-manifest.json'
  $readmePath = Join-Path $packageRoot 'README.md'
  $compatibilityPath = Join-Path $Root 'manifests/compatibility.json'
  $unifiedManifestPath = Join-Path $Root 'manifests/unified-runtime.json'

  foreach ($path in @($packageManifestPath, $readmePath, $compatibilityPath, $unifiedManifestPath)) {
    if (!(Test-Path -LiteralPath $path)) {
      $errors.Add("Missing UE4SS compatibility package validation file: $path")
    } else {
      Add-Evidence 'file' $path 'UE4SS compatibility package validation input'
    }
  }

  $packageManifest = $null
  $compatibility = $null
  $unifiedManifest = $null
  if (Test-Path -LiteralPath $packageManifestPath) {
    $packageManifest = Read-JsonFile $packageManifestPath
  }
  if (Test-Path -LiteralPath $compatibilityPath) {
    $compatibility = Read-JsonFile $compatibilityPath
  }
  if (Test-Path -LiteralPath $unifiedManifestPath) {
    $unifiedManifest = Read-JsonFile $unifiedManifestPath
  }

  if ($packageManifest) {
    if ([string]$packageManifest.componentId -ne 'ue4ss-compatibility') {
      $errors.Add('UE4SS compatibility package componentId must be ue4ss-compatibility.')
    }
    if ([string]$packageManifest.owner -ne 'compat/ue4ss') {
      $errors.Add('UE4SS compatibility package owner must be compat/ue4ss.')
    }
    if ([string]$packageManifest.compatibilityManifest -ne 'manifests/compatibility.json') {
      $errors.Add('UE4SS compatibility package must point at manifests/compatibility.json.')
    }
    if ([string]$packageManifest.targetBrickadiaBuild -ne 'PC-Shipping-CL24045983') {
      $errors.Add('UE4SS compatibility package targetBrickadiaBuild must be PC-Shipping-CL24045983.')
    }
    if ([string]$packageManifest.serverExecutable -ne 'BrickadiaServer-Win64-Shipping.exe') {
      $errors.Add('UE4SS compatibility package serverExecutable must be BrickadiaServer-Win64-Shipping.exe.')
    }
    foreach ($guardrail in @('validate-before-release', 'preserve-current-install-paths', 'keep-compatibility-manifest-authoritative', 'do-not-vendor-server-runtime-data')) {
      Test-Contains @($packageManifest.guardrails) $guardrail "UE4SS compatibility guardrails are missing: $guardrail"
    }
    foreach ($relative in @($packageManifest.sourceRoots)) {
      $path = Join-Path $Root ([string]$relative)
      if (!(Test-Path -LiteralPath $path)) {
        $errors.Add("UE4SS compatibility source root does not exist: $relative")
      } else {
        Add-Evidence 'source-root' $path 'UE4SS compatibility source root'
      }
    }
    foreach ($relative in @($packageManifest.requiredFiles)) {
      $path = Join-Path $Root ([string]$relative)
      if (!(Test-Path -LiteralPath $path)) {
        $errors.Add("UE4SS compatibility required file does not exist: $relative")
      } else {
        Add-Evidence 'required-file' $path 'UE4SS compatibility required file'
      }
    }
  }

  if ($compatibility) {
    if ([string]$compatibility.brickadia.primaryTarget -notmatch 'PC-Shipping-CL24045983') {
      $errors.Add('Compatibility manifest primary target must include PC-Shipping-CL24045983.')
    }
    if ([string]$compatibility.brickadia.serverExecutable -ne 'BrickadiaServer-Win64-Shipping.exe') {
      $errors.Add('Compatibility manifest server executable must be BrickadiaServer-Win64-Shipping.exe.')
    }
    if ([string]$compatibility.brickadia.platform -ne 'Windows') {
      $errors.Add('Compatibility manifest platform must be Windows.')
    }
    if ($compatibility.ue4ss.required -ne $true) {
      $errors.Add('Compatibility manifest must require UE4SS.')
    }
    if ([string]$compatibility.runtimeStrategy.status -ne 'omegga-supported-runtime') {
      $errors.Add('Compatibility manifest runtime strategy must be omegga-supported-runtime.')
    }
    foreach ($feature in @('installer.windows', 'release.package', 'compatibility.diagnostics', 'commands.console')) {
      if (!$compatibility.features.$feature) {
        $errors.Add("Compatibility manifest is missing feature entry: $feature")
      }
    }
  }

  if ($unifiedManifest) {
    $component = $null
    foreach ($candidate in @($unifiedManifest.components)) {
      if ([string]$candidate.id -eq 'ue4ss-compatibility') {
        $component = $candidate
        break
      }
    }
    if (!$component) {
      $errors.Add('Unified runtime manifest is missing ue4ss-compatibility component.')
    } else {
      if ([string]$component.owner -ne 'compat/ue4ss') {
        $errors.Add('Unified runtime manifest owner for ue4ss-compatibility must be compat/ue4ss.')
      }
      if ([string]$component.source -ne 'compat/ue4ss') {
        $errors.Add('Unified runtime manifest source for ue4ss-compatibility must be compat/ue4ss.')
      }
    }
  }

  if (Test-Path -LiteralPath $readmePath) {
    $readme = Get-Content -Raw -LiteralPath $readmePath
    foreach ($needle in @('UE4SS compatibility component', 'manifests/compatibility.json', 'PC-Shipping-CL24045983', 'compat/ue4ss')) {
      if ($readme -notmatch [regex]::Escape($needle)) {
        $errors.Add("UE4SS compatibility README does not contain expected marker: $needle")
      }
    }
  }
} catch {
  $errors.Add($_.Exception.Message)
}

$result = [ordered]@{
  feature = 'ue4ss.compat-package'
  status = if ($errors.Count -eq 0) { 'passed' } else { 'failed' }
  validationLevel = 'L0 Static'
  startedAt = $startedAt
  finishedAt = (Get-Date).ToUniversalTime().ToString('o')
  data = [ordered]@{
    packageRoot = [System.IO.Path]::GetFullPath((Join-Path $Root 'compat/ue4ss'))
    compatibilityManifest = [System.IO.Path]::GetFullPath((Join-Path $Root 'manifests/compatibility.json'))
    targetBrickadiaBuild = 'PC-Shipping-CL24045983'
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
