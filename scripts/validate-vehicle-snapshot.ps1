param(
  [string]$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
  [string]$FixtureRoot = '',
  [string]$OutJson = ''
)

$ErrorActionPreference = 'Stop'

if (!$FixtureRoot) {
  $FixtureRoot = Join-Path $Root 'artifacts/validation/20260603-215931/fixtures'
}
if (!$OutJson) {
  $OutJson = Join-Path $Root 'artifacts/local/vehicle-snapshot-canary.json'
}

$errors = New-Object System.Collections.Generic.List[string]
$evidence = New-Object System.Collections.Generic.List[object]
$startedAt = (Get-Date).ToUniversalTime().ToString('o')
$outPath = [System.IO.Path]::GetFullPath($OutJson)
$caseRoot = Join-Path (Split-Path -Parent $outPath) 'vehicle-snapshot'
New-Item -ItemType Directory -Force -Path $caseRoot | Out-Null

$snapshotScript = Join-Path $Root 'scripts/summarize-vehicle-graphs.ps1'
$cases = @(
  [ordered]@{
    name = 'threecars'
    input = Join-Path $FixtureRoot 'threecars.brdb'
    expectedVehicleLikeGroupCount = 3
    expectedVehicleBrickCount = 4584
    expectedBodyGridBrickCount = 1254
  },
  [ordered]@{
    name = 'couplecars'
    input = Join-Path $FixtureRoot 'couplecars.brdb'
    expectedVehicleLikeGroupCount = 3
    expectedVehicleBrickCount = 4584
    expectedBodyGridBrickCount = 1254
  }
)

function Add-Evidence([string]$Kind, [string]$Path, [string]$Summary) {
  if ($Path -and (Test-Path -LiteralPath $Path)) {
    $script:evidence.Add([ordered]@{
      kind = $Kind
      path = [System.IO.Path]::GetFullPath($Path)
      summary = $Summary
    })
  }
}

$caseResults = New-Object System.Collections.Generic.List[object]

foreach ($case in $cases) {
  try {
    if (!(Test-Path -LiteralPath $case.input)) {
      $errors.Add("Missing fixture: $($case.input)")
      continue
    }

    $snapshotPath = Join-Path $caseRoot ($case.name + '.vehicle-snapshot.json')
    $parserPath = Join-Path $caseRoot ($case.name + '.entities.json')
    $snapshotOutput = & $snapshotScript -InputPath $case.input -OutJson $snapshotPath -ParserOutJson $parserPath
    if ($LASTEXITCODE -ne 0) {
      throw "summarize-vehicle-graphs.ps1 failed with exit code $LASTEXITCODE"
    }
    $snapshot = $snapshotOutput | ConvertFrom-Json
    Add-Evidence 'json' $snapshotPath "$($case.name) vehicle snapshot"
    Add-Evidence 'json' $parserPath "$($case.name) parser output"

    if ($snapshot.status -ne 'passed') {
      $errors.Add("$($case.name) vehicle snapshot did not pass.")
    }
    if ([int]$snapshot.data.vehicleLikeGroupCount -ne [int]$case.expectedVehicleLikeGroupCount) {
      $errors.Add("$($case.name) expected $($case.expectedVehicleLikeGroupCount) vehicle-like groups, got $($snapshot.data.vehicleLikeGroupCount).")
    }
    if ([int]$snapshot.data.vehicleBrickCount -ne [int]$case.expectedVehicleBrickCount) {
      $errors.Add("$($case.name) expected $($case.expectedVehicleBrickCount) vehicle bricks, got $($snapshot.data.vehicleBrickCount).")
    }
    foreach ($vehicle in @($snapshot.data.vehicles)) {
      if ([int]$vehicle.relatedGridCount -ne 16) {
        $errors.Add("$($case.name) vehicle $($vehicle.vehicleId) expected 16 related grids, got $($vehicle.relatedGridCount).")
      }
      if ([int]$vehicle.brickCount -ne 1528) {
        $errors.Add("$($case.name) vehicle $($vehicle.vehicleId) expected 1528 bricks, got $($vehicle.brickCount).")
      }
      if (!$vehicle.bodyGrid -or [int]$vehicle.bodyGrid.brickCount -ne [int]$case.expectedBodyGridBrickCount) {
        $errors.Add("$($case.name) vehicle $($vehicle.vehicleId) did not identify a $($case.expectedBodyGridBrickCount)-brick body grid.")
      }
    }

    $caseResults.Add([ordered]@{
      name = $case.name
      input = [System.IO.Path]::GetFullPath($case.input)
      vehicleLikeGroupCount = [int]$snapshot.data.vehicleLikeGroupCount
      vehicleBrickCount = [int]$snapshot.data.vehicleBrickCount
      vehicles = $snapshot.data.vehicles
    })
  } catch {
    $errors.Add($_.Exception.Message)
  }
}

$result = [ordered]@{
  feature = 'archives.vehicle-graph-snapshot.fixtures'
  status = if ($errors.Count -eq 0) { 'passed' } else { 'failed' }
  validationLevel = 'L0 Static'
  startedAt = $startedAt
  finishedAt = (Get-Date).ToUniversalTime().ToString('o')
  data = [ordered]@{
    fixtureRoot = [System.IO.Path]::GetFullPath($FixtureRoot)
    cases = $caseResults
  }
  evidence = $evidence
  errors = @($errors)
}

$json = $result | ConvertTo-Json -Depth 16
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $outPath) | Out-Null
Set-Content -LiteralPath $outPath -Value $json -Encoding UTF8
Write-Output $json

if ($errors.Count -ne 0) {
  exit 1
}
