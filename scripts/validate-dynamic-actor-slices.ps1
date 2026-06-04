param(
  [string]$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
  [string]$FixtureRoot = '',
  [string]$OutJson = ''
)

$ErrorActionPreference = 'Stop'

if (!$FixtureRoot) {
  $FixtureRoot = Join-Path $Root 'artifacts/overnight/20260603-215931/fixtures'
}

$errors = New-Object System.Collections.Generic.List[string]
$cases = New-Object System.Collections.Generic.List[object]
$evidence = New-Object System.Collections.Generic.List[object]
$sliceScript = Join-Path $Root 'scripts/slice-dynamic-actor-brdb.js'
$describeScript = Join-Path $Root 'scripts/describe-world-archive.ps1'

if (!(Test-Path -LiteralPath $FixtureRoot)) {
  $errors.Add("Missing archive fixture root: $FixtureRoot")
} else {
  $outputRoot = if ($OutJson) {
    Join-Path (Split-Path -Parent ([System.IO.Path]::GetFullPath($OutJson))) 'dynamic-actor-slices'
  } else {
    Join-Path $Root 'artifacts/local/dynamic-actor-slices'
  }
  New-Item -ItemType Directory -Force -Path $outputRoot | Out-Null

  $fixturePath = Join-Path $FixtureRoot 'threecars.brdb'
  if (!(Test-Path -LiteralPath $fixturePath)) {
    $errors.Add('Missing archive fixture: threecars.brdb')
  } else {
    $slicePath = Join-Path $outputRoot 'threecars.entity20.slice.brdb'
    $reportPath = Join-Path $outputRoot 'threecars.entity20.slice-report.json'
    $describePath = Join-Path $outputRoot 'threecars.entity20.slice-describe.json'
    $parserPath = Join-Path $outputRoot 'threecars.entity20.slice-entities.json'

    $sliceOutput = & node $sliceScript $fixturePath $slicePath --entity-id 20 --report-json $reportPath --force
    if ($LASTEXITCODE -ne 0) {
      throw "slice-dynamic-actor-brdb.js failed with exit code $LASTEXITCODE"
    }
    $slice = $sliceOutput | ConvertFrom-Json
    if ($slice.status -ne 'passed') {
      $errors.Add('threecars.brdb: slice script failed')
    }

    $describeOutput = & $describeScript -InputPath $slicePath -OutJson $describePath -ParserOutJson $parserPath
    $describe = $describeOutput | ConvertFrom-Json
    if ($describe.status -ne 'passed') {
      $errors.Add('threecars.entity20.slice.brdb: describe script failed')
    }
    if ([int]$describe.data.entityCount -ne 20) {
      $errors.Add("threecars.entity20.slice.brdb: expected 20 entities, got $($describe.data.entityCount)")
    }
    if ([int]$describe.data.dynamicActorGraphCount -ne 2) {
      $errors.Add("threecars.entity20.slice.brdb: expected 2 dynamic actor graphs, got $($describe.data.dynamicActorGraphCount)")
    }
    if ([int]$describe.data.dynamicActorGroupCount -ne 1) {
      $errors.Add("threecars.entity20.slice.brdb: expected 1 dynamic actor group, got $($describe.data.dynamicActorGroupCount)")
    }
    $group = @($describe.data.dynamicActorGroups | Select-Object -First 1)
    if ($group -and [int]$group.relatedEntityCount -ne 20) {
      $errors.Add("threecars.entity20.slice.brdb: expected sliced group to retain 20 related entities, got $($group.relatedEntityCount)")
    }
    if ($group -and [int]$group.relatedGridCount -ne 16) {
      $errors.Add("threecars.entity20.slice.brdb: expected sliced group to retain 16 related grids, got $($group.relatedGridCount)")
    }

    $cases.Add([ordered]@{
      file = 'threecars.brdb'
      selector = 'entity:20'
      slicePath = [System.IO.Path]::GetFullPath($slicePath)
      sliceReportPath = [System.IO.Path]::GetFullPath($reportPath)
      describePath = [System.IO.Path]::GetFullPath($describePath)
      parserPath = [System.IO.Path]::GetFullPath($parserPath)
      entityCount = [int]$describe.data.entityCount
      dynamicActorGraphCount = [int]$describe.data.dynamicActorGraphCount
      dynamicActorGroupCount = [int]$describe.data.dynamicActorGroupCount
      selectedGroupId = [int]$slice.selectedGroupId
      selectedSeedEntityId = [int]$slice.selectedSeedEntityId
    })
    $evidence.Add([ordered]@{
      kind = 'brdb'
      path = [System.IO.Path]::GetFullPath($slicePath)
      summary = 'Experimental single dynamic-actor BRDB slice'
    })
    $evidence.Add([ordered]@{
      kind = 'json'
      path = [System.IO.Path]::GetFullPath($reportPath)
      summary = 'Slice rewrite report'
    })
  }
}

$result = [ordered]@{
  feature = 'archives.dynamic-actor-brdb-slice-fixture'
  status = if ($errors.Count -eq 0) { 'passed' } else { 'failed' }
  validationLevel = 'L0 Static'
  startedAt = (Get-Date).ToUniversalTime().ToString('o')
  finishedAt = (Get-Date).ToUniversalTime().ToString('o')
  data = [ordered]@{
    fixtureRoot = [System.IO.Path]::GetFullPath($FixtureRoot)
    cases = $cases
  }
  evidence = $evidence
  errors = @($errors)
}

$json = $result | ConvertTo-Json -Depth 10
if ($OutJson) {
  $outPath = [System.IO.Path]::GetFullPath($OutJson)
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $outPath) | Out-Null
  Set-Content -LiteralPath $outPath -Value $json -Encoding UTF8
}

Write-Output $json
if ($errors.Count -ne 0) {
  exit 1
}
