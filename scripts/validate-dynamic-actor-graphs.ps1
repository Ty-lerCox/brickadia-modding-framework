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
$captureScript = Join-Path $Root 'scripts/capture-dynamic-actor-graph.ps1'

if (!(Test-Path -LiteralPath $FixtureRoot)) {
  $errors.Add("Missing archive fixture root: $FixtureRoot")
} else {
  $outputRoot = if ($OutJson) {
    Join-Path (Split-Path -Parent ([System.IO.Path]::GetFullPath($OutJson))) 'dynamic-actor-graphs'
  } else {
    Join-Path $Root 'artifacts/local/dynamic-actor-graphs'
  }
  New-Item -ItemType Directory -Force -Path $outputRoot | Out-Null

  foreach ($fixtureName in @('threecars.brdb', 'couplecars.brdb')) {
    $fixturePath = Join-Path $FixtureRoot $fixtureName
    if (!(Test-Path -LiteralPath $fixturePath)) {
      $errors.Add("Missing archive fixture: $fixtureName")
      continue
    }

    $caseName = [System.IO.Path]::GetFileNameWithoutExtension($fixtureName)
    $capturePath = Join-Path $outputRoot "$caseName.group1.capture.json"
    $parserPath = Join-Path $outputRoot "$caseName.group1.entities.json"
    $captureOutput = & $captureScript -InputPath $fixturePath -GroupId 1 -Name "$caseName-group-1" -OutJson $capturePath -ParserOutJson $parserPath
    $capture = $captureOutput | ConvertFrom-Json

    if ($capture.status -ne 'passed') {
      $errors.Add("${fixtureName}: dynamic actor capture failed")
      continue
    }
    if ([int]$capture.data.relatedEntityCount -ne 20) {
      $errors.Add("${fixtureName}: expected selected group to have 20 related entities, got $($capture.data.relatedEntityCount)")
    }
    if ([int]$capture.data.relatedGridCount -ne 16) {
      $errors.Add("${fixtureName}: expected selected group to have 16 related grids, got $($capture.data.relatedGridCount)")
    }
    if ([int]$capture.data.chunkPathCounts.brick -ne 16) {
      $errors.Add("${fixtureName}: expected selected group to have 16 brick chunk paths, got $($capture.data.chunkPathCounts.brick)")
    }
    if ([int]$capture.data.chunkPathCounts.component -ne 12) {
      $errors.Add("${fixtureName}: expected selected group to have 12 component chunk paths, got $($capture.data.chunkPathCounts.component)")
    }
    if ([int]$capture.data.chunkPathCounts.wire -ne 2) {
      $errors.Add("${fixtureName}: expected selected group to have 2 wire chunk paths, got $($capture.data.chunkPathCounts.wire)")
    }
    if ($capture.data.sliceReadiness.entityChunkRewriteRequired -ne $true) {
      $errors.Add("${fixtureName}: expected entity chunk row rewrite to be required for a single-car slice")
    }

    $cases.Add([ordered]@{
      file = $fixtureName
      selector = 'group:1'
      capturePath = [System.IO.Path]::GetFullPath($capturePath)
      parserPath = [System.IO.Path]::GetFullPath($parserPath)
      selectedGroupId = [int]$capture.data.selectedGroupId
      seedEntityIds = @($capture.data.seedEntityIds)
      relatedEntityCount = [int]$capture.data.relatedEntityCount
      relatedGridCount = [int]$capture.data.relatedGridCount
      chunkPathCounts = $capture.data.chunkPathCounts
      sliceStatus = [string]$capture.data.sliceReadiness.status
    })
    $evidence.Add([ordered]@{
      kind = 'json'
      path = [System.IO.Path]::GetFullPath($capturePath)
      summary = "$fixtureName dynamic actor graph capture"
    })

    if ($fixtureName -eq 'threecars.brdb') {
      $entityCapturePath = Join-Path $outputRoot "$caseName.entity20.capture.json"
      $entityParserPath = Join-Path $outputRoot "$caseName.entity20.entities.json"
      $entityCaptureOutput = & $captureScript -InputPath $fixturePath -EntityId 20 -Name "$caseName-entity-20" -OutJson $entityCapturePath -ParserOutJson $entityParserPath
      $entityCapture = $entityCaptureOutput | ConvertFrom-Json

      if ($entityCapture.status -ne 'passed') {
        $errors.Add("${fixtureName}: entity-id dynamic actor capture failed")
      } elseif ([int]$entityCapture.data.selectedGroupId -ne 1) {
        $errors.Add("${fixtureName}: expected entity id 20 to resolve to group 1, got $($entityCapture.data.selectedGroupId)")
      } elseif ([int]$entityCapture.data.relatedEntityCount -ne 20) {
        $errors.Add("${fixtureName}: expected entity id 20 graph to have 20 related entities, got $($entityCapture.data.relatedEntityCount)")
      }

      $cases.Add([ordered]@{
        file = $fixtureName
        selector = 'entity:20'
        capturePath = [System.IO.Path]::GetFullPath($entityCapturePath)
        parserPath = [System.IO.Path]::GetFullPath($entityParserPath)
        selectedGroupId = if ($entityCapture.data.selectedGroupId -ne $null) { [int]$entityCapture.data.selectedGroupId } else { $null }
        seedEntityIds = @($entityCapture.data.seedEntityIds)
        relatedEntityCount = if ($entityCapture.data.relatedEntityCount -ne $null) { [int]$entityCapture.data.relatedEntityCount } else { 0 }
        relatedGridCount = if ($entityCapture.data.relatedGridCount -ne $null) { [int]$entityCapture.data.relatedGridCount } else { 0 }
        chunkPathCounts = $entityCapture.data.chunkPathCounts
        sliceStatus = [string]$entityCapture.data.sliceReadiness.status
      })
      $evidence.Add([ordered]@{
        kind = 'json'
        path = [System.IO.Path]::GetFullPath($entityCapturePath)
        summary = "$fixtureName dynamic actor graph capture selected by entity id 20"
      })
    }
  }
}

$result = [ordered]@{
  feature = 'archives.dynamic-actor-graph-fixtures'
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
