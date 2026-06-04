param(
  [Parameter(Mandatory = $true)]
  [string]$InputPath,
  [string]$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
  [string]$BrickadiaRoot = '',
  [string]$ParserPath = '',
  [string]$OutJson = '',
  [string]$ParserOutJson = ''
)

$ErrorActionPreference = 'Stop'

if (!$BrickadiaRoot) {
  $BrickadiaRoot = (Resolve-Path (Join-Path $Root '..\Brickadia')).Path
}
if (!$ParserPath) {
  $ParserPath = Join-Path $BrickadiaRoot 'brickadia-ue4ss-re/scripts/list-world-entities.js'
}

$inputFullPath = [System.IO.Path]::GetFullPath($InputPath)
$parserFullPath = [System.IO.Path]::GetFullPath($ParserPath)
if (!(Test-Path -LiteralPath $inputFullPath)) {
  throw "Input archive does not exist: $inputFullPath"
}
if (!(Test-Path -LiteralPath $parserFullPath)) {
  throw "BRDB parser script does not exist: $parserFullPath"
}

if (!$ParserOutJson) {
  if ($OutJson) {
    $ParserOutJson = [System.IO.Path]::ChangeExtension([System.IO.Path]::GetFullPath($OutJson), '.entities.json')
  } else {
    $ParserOutJson = Join-Path ([System.IO.Path]::GetTempPath()) ("bmf-vehicle-entities-" + [guid]::NewGuid().ToString('n') + ".json")
  }
}
$parserOutFullPath = [System.IO.Path]::GetFullPath($ParserOutJson)
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $parserOutFullPath) | Out-Null

$null = & node $parserFullPath $inputFullPath --out-json $parserOutFullPath
if ($LASTEXITCODE -ne 0) {
  throw "list-world-entities.js failed with exit code $LASTEXITCODE"
}

$parsed = Get-Content -Raw -LiteralPath $parserOutFullPath | ConvertFrom-Json
$gridById = @{}
foreach ($grid in @($parsed.brickGrids)) {
  $gridById[[int]$grid.gridId] = $grid
}

$vehicles = New-Object System.Collections.Generic.List[object]
foreach ($group in @($parsed.dynamicActorGroups)) {
  $relatedGrids = @()
  $brickCount = 0
  $componentCount = 0
  $wireCount = 0
  $bodyGrid = $null

  foreach ($gridId in @($group.relatedGridIds)) {
    $grid = $gridById[[int]$gridId]
    if (!$grid) {
      continue
    }
    $relatedGrids += $grid
    $brickCount += [int]$grid.brickCount
    $componentCount += [int]$grid.componentCount
    $wireCount += [int]$grid.wireCount
    if (!$bodyGrid -or [int]$grid.brickCount -gt [int]$bodyGrid.brickCount) {
      $bodyGrid = $grid
    }
  }

  $seedTypes = @($group.seedEntities | ForEach-Object { $_.typeName } | Sort-Object -Unique)
  $classification = if (
    [string]$group.status -eq 'resolved-by-joint-references' -and
    [int]$group.relatedGridCount -gt 1 -and
    $seedTypes -contains 'BrickGridDynamicActor'
  ) {
    'dynamic-actor-vehicle-like'
  } else {
    'dynamic-actor-group'
  }

  $vehicles.Add([ordered]@{
    vehicleId = $vehicles.Count + 1
    groupId = [int]$group.groupId
    classification = $classification
    status = [string]$group.status
    center = $group.center
    seedEntityIds = @($group.seedEntityIds)
    seedTypes = $seedTypes
    relatedEntityIds = @($group.relatedEntityIds)
    relatedGridIds = @($group.relatedGridIds)
    relatedEntityCount = [int]$group.relatedEntityCount
    relatedGridCount = [int]$group.relatedGridCount
    gridCount = @($relatedGrids).Count
    brickCount = $brickCount
    componentCount = $componentCount
    wireCount = $wireCount
    bodyGrid = if ($bodyGrid) {
      [ordered]@{
        gridId = [int]$bodyGrid.gridId
        brickCount = [int]$bodyGrid.brickCount
        componentCount = [int]$bodyGrid.componentCount
        wireCount = [int]$bodyGrid.wireCount
      }
    } else { $null }
    chunkPathCounts = $group.chunkPathCounts
  })
}

$vehicleBrickCount = 0
$vehicleComponentCount = 0
$vehicleWireCount = 0
foreach ($vehicle in $vehicles) {
  $vehicleBrickCount += [int]$vehicle.brickCount
  $vehicleComponentCount += [int]$vehicle.componentCount
  $vehicleWireCount += [int]$vehicle.wireCount
}

$result = [ordered]@{
  feature = 'archives.vehicle-graph-snapshot'
  status = 'passed'
  validationLevel = 'L0 Static'
  startedAt = (Get-Date).ToUniversalTime().ToString('o')
  finishedAt = (Get-Date).ToUniversalTime().ToString('o')
  data = [ordered]@{
    inputPath = $inputFullPath
    parserPath = $parserFullPath
    parserOutput = $parserOutFullPath
    archiveBytes = (Get-Item -LiteralPath $inputFullPath).Length
    entityCount = @($parsed.entities).Count
    brickGridCount = @($parsed.brickGrids).Count
    dynamicActorGroupCount = @($parsed.dynamicActorGroups).Count
    vehicleLikeGroupCount = @($vehicles | Where-Object { $_.classification -eq 'dynamic-actor-vehicle-like' }).Count
    vehicleBrickCount = $vehicleBrickCount
    vehicleComponentCount = $vehicleComponentCount
    vehicleWireCount = $vehicleWireCount
    vehicles = $vehicles
  }
  evidence = @(
    [ordered]@{
      kind = 'json'
      path = $parserOutFullPath
      summary = 'Raw parser output from list-world-entities.js'
    }
  )
  errors = @()
}

$json = $result | ConvertTo-Json -Depth 14
if ($OutJson) {
  $outPath = [System.IO.Path]::GetFullPath($OutJson)
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $outPath) | Out-Null
  Set-Content -LiteralPath $outPath -Value $json -Encoding UTF8
}

Write-Output $json
