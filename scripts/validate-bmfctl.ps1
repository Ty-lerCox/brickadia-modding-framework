param(
  [string]$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
  [string]$OutJson = ''
)

$ErrorActionPreference = 'Stop'

if (!$OutJson) {
  $OutJson = Join-Path $Root 'artifacts/local/bmfctl-validation.json'
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

try {
  $node = Get-Command node -ErrorAction SilentlyContinue
  if (!$node) {
    throw 'Node.js is required to validate bmfctl.'
  }

  $cliPath = Join-Path $Root 'cli/bin/bmfctl.js'
  if (!(Test-Path -LiteralPath $cliPath)) {
    throw "bmfctl entrypoint is missing: $cliPath"
  }
  $snapshotPath = Join-Path $Root 'cli/src/snapshot.js'
  if (!(Test-Path -LiteralPath $snapshotPath)) {
    throw "bmfctl snapshot module is missing: $snapshotPath"
  }
  $snapshotText = Get-Content -Raw -LiteralPath $snapshotPath
  if ($snapshotText -notmatch [regex]::Escape('BMF_SNAPSHOT_ROOT')) {
    throw 'bmfctl snapshot module must support BMF_SNAPSHOT_ROOT for installed Desktop shims.'
  }
  $cliSourcePath = Join-Path $Root 'cli/src/cli.js'
  $formatPath = Join-Path $Root 'cli/src/format.js'
  $orchestratorPath = Join-Path $Root 'cli/src/orchestrator.js'
  $cliReadmePath = Join-Path $Root 'cli/README.md'
  $transactionTestPath = Join-Path $Root 'cli/test/transaction.test.js'
  foreach ($marker in @(
    @{ Path = $cliSourcePath; Needle = 'bmfctl prerequisites [--json]' },
    @{ Path = $cliSourcePath; Needle = '--release-manifest <file>' },
    @{ Path = $cliSourcePath; Needle = "command === 'prerequisites' || command === 'prereqs'" },
    @{ Path = $formatPath; Needle = 'printPrerequisites' },
    @{ Path = $orchestratorPath; Needle = 'createPrerequisiteReport' },
    @{ Path = $orchestratorPath; Needle = 'releaseManifestPath' },
    @{ Path = $cliReadmePath; Needle = 'transaction repair-stack --apply --confirm apply' },
    @{ Path = $transactionTestPath; Needle = 'bmfctl repair-stack transaction maps repair actions to concrete steps' }
  )) {
    if (Test-Path -LiteralPath $marker.Path) {
      $markerText = Get-Content -Raw -LiteralPath $marker.Path
      if ($markerText -notmatch [regex]::Escape($marker.Needle)) {
        throw "$($marker.Path) is missing prerequisite command marker: $($marker.Needle)"
      }
    }
  }

  $shimPath = Join-Path $Root 'apps/bmf-desktop/packaged-assets/bin/bmfctl.cmd'
  if (!(Test-Path -LiteralPath $shimPath)) {
    throw "Installed bmfctl shim is missing: $shimPath"
  }
  $shimText = Get-Content -Raw -LiteralPath $shimPath
  foreach ($marker in @('ELECTRON_RUN_AS_NODE=1', 'BMF Desktop.exe', 'cli\bin\bmfctl.js', '--bmf-root', '--profile-store', '--journal-root', '--service-root', '--download-dir', 'BMF_SNAPSHOT_ROOT')) {
    if ($shimText -notmatch [regex]::Escape($marker)) {
      throw "Installed bmfctl shim is missing marker: $marker"
    }
  }

  $testFiles = @(Get-ChildItem -LiteralPath (Join-Path $Root 'cli/test') -Filter '*.test.js' | ForEach-Object { $_.FullName })
  if ($testFiles.Count -eq 0) {
    throw 'No bmfctl test files were found.'
  }

  & node --test @testFiles
  if ($LASTEXITCODE -ne 0) {
    throw "bmfctl tests failed with exit code $LASTEXITCODE"
  }

  Add-Evidence 'file' $cliPath 'bmfctl executable entrypoint'
  Add-Evidence 'file' $cliSourcePath 'bmfctl command router'
  Add-Evidence 'file' $formatPath 'bmfctl output formatters'
  Add-Evidence 'file' $orchestratorPath 'bmfctl orchestrator bridge'
  Add-Evidence 'file' $shimPath 'Installed BMF Desktop bmfctl Windows shim'
  Add-Evidence 'file' $snapshotPath 'bmfctl snapshot module'
  foreach ($test in $testFiles) {
    Add-Evidence 'test' $test 'bmfctl node:test suite'
  }
} catch {
  $errors.Add($_.Exception.Message)
}

$result = [ordered]@{
  feature = 'bmfctl.static'
  status = if ($errors.Count -eq 0) { 'passed' } else { 'failed' }
  validationLevel = 'L0 Static'
  startedAt = $startedAt
  finishedAt = (Get-Date).ToUniversalTime().ToString('o')
  root = [System.IO.Path]::GetFullPath($Root)
  evidence = $evidence.ToArray()
  errors = $errors.ToArray()
}

$json = $result | ConvertTo-Json -Depth 8
New-Item -ItemType Directory -Force -Path (Split-Path -Parent ([System.IO.Path]::GetFullPath($OutJson))) | Out-Null
Set-Content -LiteralPath $OutJson -Value $json -Encoding UTF8
Write-Output $json

if ($errors.Count -ne 0) {
  exit 1
}
