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
$describeScript = Join-Path $Root 'scripts/describe-world-archive.ps1'

if (!(Test-Path -LiteralPath $FixtureRoot)) {
  $errors.Add("Missing archive fixture root: $FixtureRoot")
} else {
  $outputRoot = if ($OutJson) {
    Join-Path (Split-Path -Parent ([System.IO.Path]::GetFullPath($OutJson))) 'archive-describe'
  } else {
    Join-Path $Root 'artifacts/local/archive-describe'
  }
  New-Item -ItemType Directory -Force -Path $outputRoot | Out-Null

  foreach ($fixtureName in @('threecars.brdb', 'couplecars.brdb')) {
    $fixturePath = Join-Path $FixtureRoot $fixtureName
    if (!(Test-Path -LiteralPath $fixturePath)) {
      $errors.Add("Missing archive fixture: $fixtureName")
      continue
    }

    $caseName = [System.IO.Path]::GetFileNameWithoutExtension($fixtureName)
    $describePath = Join-Path $outputRoot "$caseName.describe.json"
    $parserPath = Join-Path $outputRoot "$caseName.entities.json"
    $describeOutput = & $describeScript -InputPath $fixturePath -OutJson $describePath -ParserOutJson $parserPath
    $describe = $describeOutput | ConvertFrom-Json

    if ($describe.status -ne 'passed') {
      $errors.Add("${fixtureName}: describe script failed")
      continue
    }
    if ([int]$describe.data.entityCount -ne 60) {
      $errors.Add("${fixtureName}: expected 60 entities, got $($describe.data.entityCount)")
    }
    if ([int]$describe.data.dynamicActorGroupCount -ne 3) {
      $errors.Add("${fixtureName}: expected 3 dynamic actor groups, got $($describe.data.dynamicActorGroupCount)")
    }
    if ([int]$describe.data.dynamicActorGraphCount -ne 6) {
      $errors.Add("${fixtureName}: expected 6 dynamic actor graphs, got $($describe.data.dynamicActorGraphCount)")
    }

    $cases.Add([ordered]@{
      file = $fixtureName
      describePath = [System.IO.Path]::GetFullPath($describePath)
      parserPath = [System.IO.Path]::GetFullPath($parserPath)
      entityCount = [int]$describe.data.entityCount
      dynamicActorGraphCount = [int]$describe.data.dynamicActorGraphCount
      dynamicActorGroupCount = [int]$describe.data.dynamicActorGroupCount
      typeNames = @($describe.data.typeNames)
    })
    $evidence.Add([ordered]@{
      kind = 'brdb'
      path = [System.IO.Path]::GetFullPath($fixturePath)
      summary = "$fixtureName archive fixture"
    })
  }
}

$result = [ordered]@{
  feature = 'archives.fixture-describe'
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
