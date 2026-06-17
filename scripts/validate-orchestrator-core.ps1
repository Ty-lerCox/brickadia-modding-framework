param(
  [string]$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
  [string]$OutJson = ''
)

$ErrorActionPreference = 'Stop'

if (!$OutJson) {
  $OutJson = Join-Path $Root 'artifacts/local/orchestrator-core-validation.json'
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
$packageRoot = Join-Path $Root 'packages/orchestrator-core'
$packageJsonPath = Join-Path $packageRoot 'package.json'
$testDir = Join-Path $packageRoot 'test'
$testOutput = @()
$testExitCode = 0

try {
  foreach ($required in @(
    $packageJsonPath,
    (Join-Path $packageRoot 'README.md'),
    (Join-Path $packageRoot 'src/file.js'),
    (Join-Path $packageRoot 'src/manifest.js'),
    (Join-Path $packageRoot 'src/profiles.js'),
    (Join-Path $packageRoot 'src/health.js'),
    (Join-Path $packageRoot 'src/observations.js'),
    (Join-Path $packageRoot 'src/prerequisites.js'),
    (Join-Path $packageRoot 'src/operations.js'),
    (Join-Path $packageRoot 'src/services.js'),
    (Join-Path $packageRoot 'src/service-actions.js'),
    (Join-Path $packageRoot 'src/telemetry.js'),
    (Join-Path $packageRoot 'src/traffic.js'),
    (Join-Path $packageRoot 'src/logs.js'),
    (Join-Path $packageRoot 'src/snapshots.js'),
    (Join-Path $packageRoot 'src/transactions.js'),
    (Join-Path $packageRoot 'src/index.js'),
    (Join-Path $packageRoot 'test/manifest.test.js')
  )) {
    if (!(Test-Path -LiteralPath $required)) {
      $errors.Add("Missing orchestrator-core file: $required")
    }
  }

  if (Test-Path -LiteralPath $packageJsonPath) {
    Get-Content -Raw -LiteralPath $packageJsonPath | ConvertFrom-Json | Out-Null
    Add-Evidence $evidence 'json' $packageJsonPath 'orchestrator-core package manifest'
  }

  foreach ($path in @(
    (Join-Path $packageRoot 'README.md'),
    (Join-Path $packageRoot 'src/index.js'),
    (Join-Path $packageRoot 'test/manifest.test.js')
  )) {
    Add-Evidence $evidence 'file' $path 'orchestrator-core static source'
  }

  $transactionsPath = Join-Path $packageRoot 'src/transactions.js'
  if (Test-Path -LiteralPath $transactionsPath) {
    $transactionsSource = Get-Content -Raw -LiteralPath $transactionsPath
    foreach ($needle in @(
      'write-omegga-start-script',
      'Start-BrickadiaOmegga.ps1',
      'BMF_OMEGGA_BOOTSTRAP_BUILD_SCRIPT',
      'ForceInstallDependencies',
      'npm is required to install Omegga dependencies',
      'Invoke-BmfCommand $npmCommand.Source @("start")',
      'updateReleaseEvidenceSteps',
      'verify-release-checksums',
      'component-update.snapshot',
      'releaseCatalogPath',
      'releaseManifestPath',
      'update-omegga-runtime',
      'repairStackSteps',
      'health-snapshot',
      'repair.mutable-files.snapshot',
      'repair-mod-enablement',
      'repairMissingRuntimeFileSteps',
      'verify-after-repair'
    )) {
      if ($transactionsSource -notmatch [regex]::Escape($needle)) {
        $errors.Add("transactions.js does not contain expected Omegga bootstrap marker: $needle")
      }
    }
  }

  $profilesPath = Join-Path $packageRoot 'src/profiles.js'
  if (Test-Path -LiteralPath $profilesPath) {
    $profilesSource = Get-Content -Raw -LiteralPath $profilesPath
    foreach ($needle in @('PROFILE_BACKENDS', 'local-process', 'normalizeProfileBackend', 'backendConfig', 'defaultOmeggaStartScript', 'Start-BrickadiaOmegga.ps1', 'defaultGrafanaAlloyExecutable', 'grafanaAlloyExecutable')) {
      if ($profilesSource -notmatch [regex]::Escape($needle)) {
        $errors.Add("profiles.js does not contain expected profile path marker: $needle")
      }
    }
  }

  $prerequisitesPath = Join-Path $packageRoot 'src/prerequisites.js'
  if (Test-Path -LiteralPath $prerequisitesPath) {
    $prerequisitesSource = Get-Content -Raw -LiteralPath $prerequisitesPath
    foreach ($needle in @('createPrerequisiteAudit', 'PREREQUISITE_GUARDRAILS', 'REQUIRED_NODE_MAJOR_FOR_OMEGGA', 'no-silent-external-installs', 'omegga-install-target', 'grafana-alloy-executable')) {
      if ($prerequisitesSource -notmatch [regex]::Escape($needle)) {
        $errors.Add("prerequisites.js does not contain expected prerequisite audit marker: $needle")
      }
    }
  }

  $serviceActionsPath = Join-Path $packageRoot 'src/service-actions.js'
  if (Test-Path -LiteralPath $serviceActionsPath) {
    $serviceActionsSource = Get-Content -Raw -LiteralPath $serviceActionsPath
    foreach ($needle in @('start-alloy', 'stop-alloy', 'restart-alloy', 'configured-alloy-executable-only', '--server.http.listen-addr', 'grafana-alloy', 'read-local-process-state-only', 'owned-pid-file-required', 'verify-owned-process-before-stop', 'buildServiceLaunchCommand')) {
      if ($serviceActionsSource -notmatch [regex]::Escape($needle)) {
        $errors.Add("service-actions.js does not contain expected Alloy service marker: $needle")
      }
    }
  }

  $trafficPath = Join-Path $packageRoot 'src/traffic.js'
  if (Test-Path -LiteralPath $trafficPath) {
    $trafficSource = Get-Content -Raw -LiteralPath $trafficPath
    foreach ($needle in @(
      'writeTrafficTraceExport',
      'traffic.trace.export',
      'explicit-export-confirmation-required',
      'export-redacted-snapshot-only',
      'support-export-can-anonymize-players',
      'support-export-can-redact-private-ips'
    )) {
      if ($trafficSource -notmatch [regex]::Escape($needle)) {
        $errors.Add("traffic.js does not contain expected traffic export marker: $needle")
      }
    }
  }

  $nodeCommand = Get-Command node -ErrorAction SilentlyContinue
  if (!$nodeCommand) {
    $errors.Add('Node.js is required to validate orchestrator-core tests.')
  } elseif (Test-Path -LiteralPath $testDir) {
    $testFiles = @(Get-ChildItem -LiteralPath $testDir -Filter '*.test.js' -File | ForEach-Object { $_.FullName })
    if ($testFiles.Count -eq 0) {
      $errors.Add('No orchestrator-core test files found.')
    } else {
      Push-Location $packageRoot
      try {
        $testOutput = & node --test @testFiles 2>&1
        $testExitCode = $LASTEXITCODE
      } finally {
        Pop-Location
      }
      if ($testExitCode -ne 0) {
        $errors.Add("orchestrator-core node tests failed with exit code $testExitCode.")
        foreach ($line in @($testOutput | Select-Object -Last 12)) {
          $errors.Add("node-test: $line")
        }
      }
    }
  }
} catch {
  $errors.Add($_.Exception.Message)
}

$result = [ordered]@{
  feature = 'orchestrator-core.static'
  status = if ($errors.Count -eq 0) { 'passed' } else { 'failed' }
  validationLevel = 'L0 Static'
  startedAt = $startedAt
  finishedAt = (Get-Date).ToUniversalTime().ToString('o')
  data = [ordered]@{
    packageRoot = [System.IO.Path]::GetFullPath($packageRoot)
    testExitCode = $testExitCode
    testOutput = @($testOutput)
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
