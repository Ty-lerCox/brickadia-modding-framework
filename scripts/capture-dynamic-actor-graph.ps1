param(
  [Parameter(Mandatory = $true)]
  [string]$InputPath,
  [int]$EntityId = -1,
  [int]$GroupId = -1,
  [string]$Name = '',
  [string]$ParserPath = '',
  [string]$OutJson = '',
  [string]$ParserOutJson = ''
)

$ErrorActionPreference = 'Stop'

function ConvertTo-IntArray($Values) {
  return @($Values | ForEach-Object { [int]$_ })
}

function Contains-Int($Values, [int]$Needle) {
  foreach ($value in @($Values)) {
    if ([int]$value -eq $Needle) {
      return $true
    }
  }
  return $false
}

function Sum-GridField($Grids, [string]$FieldName) {
  $sum = 0
  foreach ($grid in @($Grids)) {
    if ($null -ne $grid.$FieldName) {
      $sum += [int]$grid.$FieldName
    }
  }
  return $sum
}

if (!$ParserPath) {
  $root = Resolve-Path (Join-Path $PSScriptRoot '..')
  $siblingRoot = Split-Path -Parent $root.Path
  $ParserPath = Join-Path $siblingRoot 'Brickadia/brickadia-ue4ss-re/scripts/list-world-entities.js'
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
    $ParserOutJson = Join-Path ([System.IO.Path]::GetTempPath()) ("bmf-dynamic-actor-entities-" + [guid]::NewGuid().ToString('n') + ".json")
  }
}

$parserOutFullPath = [System.IO.Path]::GetFullPath($ParserOutJson)
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $parserOutFullPath) | Out-Null

$null = & node $parserFullPath $inputFullPath --out-json $parserOutFullPath
$parsed = Get-Content -Raw -LiteralPath $parserOutFullPath | ConvertFrom-Json

$errors = New-Object System.Collections.Generic.List[string]
$groups = @($parsed.dynamicActorGroups)
$entities = @($parsed.entities)

if ($groups.Count -eq 0) {
  $errors.Add('Archive contains no dynamic actor groups.')
}

$selectedGroup = $null
if ($GroupId -ge 0) {
  $selectedGroup = @($groups | Where-Object { [int]$_.groupId -eq $GroupId } | Select-Object -First 1)
  if (!$selectedGroup) {
    $errors.Add("No dynamic actor group matched group id $GroupId.")
  }
} elseif ($EntityId -ge 0) {
  $selectedGroup = @($groups | Where-Object { Contains-Int $_.seedEntityIds $EntityId } | Select-Object -First 1)
  if (!$selectedGroup) {
    $selectedGroup = @($groups | Where-Object { Contains-Int $_.relatedEntityIds $EntityId } | Select-Object -First 1)
  }
  if (!$selectedGroup) {
    $errors.Add("No dynamic actor group contained entity id $EntityId.")
  }
} elseif ($groups.Count -eq 1) {
  $selectedGroup = $groups[0]
} elseif ($groups.Count -gt 1) {
  $errors.Add('Archive has multiple dynamic actor groups; pass -EntityId or -GroupId.')
}

$selectedSeedEntityId = $EntityId
if ($selectedGroup -and ($selectedSeedEntityId -lt 0 -or !(Contains-Int $selectedGroup.seedEntityIds $selectedSeedEntityId))) {
  $selectedSeedEntityId = [int]@($selectedGroup.seedEntityIds)[0]
}

$selectedParserOutFullPath = $parserOutFullPath
$selectedGraph = $null
if ($errors.Count -eq 0) {
  $selectedParserOutFullPath = [System.IO.Path]::ChangeExtension($parserOutFullPath, ".entity-$selectedSeedEntityId.json")
  $null = & node $parserFullPath $inputFullPath --entity-id $selectedSeedEntityId --out-json $selectedParserOutFullPath
  $selectedParsed = Get-Content -Raw -LiteralPath $selectedParserOutFullPath | ConvertFrom-Json
  $selectedGraph = $selectedParsed.selectedEntityGraph
  if (!$selectedGraph) {
    $errors.Add("Parser did not return a selected entity graph for entity $selectedSeedEntityId.")
  }
}

$entityChunkAnalysis = @()
$selectedEntityIds = @()
$selectedGridIds = @()
$selectedChunkPaths = [ordered]@{
  brick = @()
  component = @()
  wire = @()
}
$relatedGrids = @()
$missingEntityIds = @()
$entityChunkRewriteRequired = $false

if ($selectedGraph) {
  $selectedEntityIds = ConvertTo-IntArray $selectedGraph.relatedEntityIds
  $selectedGridIds = ConvertTo-IntArray $selectedGraph.relatedGridIds
  $missingEntityIds = ConvertTo-IntArray $selectedGraph.missingEntityIds
  $relatedGrids = @($selectedGraph.relatedGrids)
  $selectedChunkPaths = [ordered]@{
    brick = @($selectedGraph.chunkPaths.brick)
    component = @($selectedGraph.chunkPaths.component)
    wire = @($selectedGraph.chunkPaths.wire)
  }

  $selectedByChunk = @{}
  foreach ($entity in @($selectedGraph.relatedEntities)) {
    $chunkPath = [string]$entity.chunkPath
    if (!$selectedByChunk.ContainsKey($chunkPath)) {
      $selectedByChunk[$chunkPath] = New-Object System.Collections.Generic.List[int]
    }
    $selectedByChunk[$chunkPath].Add([int]$entity.persistentIndex)
  }

  foreach ($chunkPath in @($selectedByChunk.Keys | Sort-Object)) {
    $allIds = ConvertTo-IntArray @($entities | Where-Object { $_.chunkPath -eq $chunkPath } | ForEach-Object { $_.persistentIndex })
    $inGraph = ConvertTo-IntArray $selectedByChunk[$chunkPath]
    $extraIds = @($allIds | Where-Object { !(Contains-Int $inGraph ([int]$_)) })
    if ($extraIds.Count -gt 0) {
      $entityChunkRewriteRequired = $true
    }
    $entityChunkAnalysis += [ordered]@{
      chunkPath = $chunkPath
      selectedEntityIds = $inGraph
      selectedEntityCount = $inGraph.Count
      totalEntityIdsInChunk = $allIds
      totalEntityCountInChunk = $allIds.Count
      unrelatedEntityIdsInChunk = ConvertTo-IntArray $extraIds
      unrelatedEntityCountInChunk = $extraIds.Count
      requiresRowRewrite = $extraIds.Count -gt 0
    }
  }

  if ($missingEntityIds.Count -gt 0) {
    $errors.Add("Selected graph has missing entity ids: $($missingEntityIds -join ', ').")
  }
}

$brickCount = Sum-GridField $relatedGrids 'brickCount'
$componentCount = Sum-GridField $relatedGrids 'componentCount'
$wireCount = Sum-GridField $relatedGrids 'wireCount'

$captureName = if ($Name) {
  $Name
} elseif ($selectedGroup) {
  "dynamic-actor-group-$($selectedGroup.groupId)"
} else {
  'dynamic-actor-graph'
}

$sliceStatus = if ($errors.Count -ne 0) {
  'not-evaluated'
} elseif ($entityChunkRewriteRequired) {
  'blocked-by-entity-chunk-row-rewrite'
} else {
  'file-prune-candidate'
}

$result = [ordered]@{
  feature = 'archives.dynamic-actor-graph-capture'
  status = if ($errors.Count -eq 0) { 'passed' } else { 'failed' }
  validationLevel = 'L0 Static'
  startedAt = (Get-Date).ToUniversalTime().ToString('o')
  finishedAt = (Get-Date).ToUniversalTime().ToString('o')
  data = [ordered]@{
    name = $captureName
    inputPath = $inputFullPath
    parserPath = $parserFullPath
    parserOutput = $parserOutFullPath
    selectedParserOutput = $selectedParserOutFullPath
    requestedEntityId = if ($EntityId -ge 0) { $EntityId } else { $null }
    requestedGroupId = if ($GroupId -ge 0) { $GroupId } else { $null }
    selectedGroupId = if ($selectedGroup) { [int]$selectedGroup.groupId } else { $null }
    selectedSeedEntityId = if ($selectedSeedEntityId -ge 0) { $selectedSeedEntityId } else { $null }
    seedEntityIds = if ($selectedGroup) { ConvertTo-IntArray $selectedGroup.seedEntityIds } else { @() }
    relatedEntityIds = $selectedEntityIds
    relatedGridIds = $selectedGridIds
    relatedEntityCount = $selectedEntityIds.Count
    relatedGridCount = $selectedGridIds.Count
    missingEntityIds = $missingEntityIds
    chunkPaths = $selectedChunkPaths
    chunkPathCounts = [ordered]@{
      brick = @($selectedChunkPaths.brick).Count
      component = @($selectedChunkPaths.component).Count
      wire = @($selectedChunkPaths.wire).Count
    }
    brickCount = $brickCount
    componentCount = $componentCount
    wireCount = $wireCount
    entityChunks = $entityChunkAnalysis
    sliceReadiness = [ordered]@{
      status = $sliceStatus
      entityChunkRewriteRequired = $entityChunkRewriteRequired
      gridDirectoriesAreIsolated = $selectedGridIds.Count -gt 0
      notes = @(
        'Grid directories for the selected actor graph can be file-pruned by persistent grid id.',
        'Entity chunks are structure-of-arrays rows; if a selected chunk also contains unrelated entity rows, a standalone archive must rewrite that chunk instead of copying it whole.'
      )
    }
  }
  evidence = @(
    [ordered]@{
      kind = 'brdb'
      path = $inputFullPath
      summary = 'Source world archive'
    },
    [ordered]@{
      kind = 'json'
      path = $parserOutFullPath
      summary = 'Full dynamic actor group parser output'
    },
    [ordered]@{
      kind = 'json'
      path = $selectedParserOutFullPath
      summary = 'Selected entity graph parser output'
    }
  )
  errors = @($errors)
}

$json = $result | ConvertTo-Json -Depth 14
if ($OutJson) {
  $outPath = [System.IO.Path]::GetFullPath($OutJson)
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $outPath) | Out-Null
  Set-Content -LiteralPath $outPath -Value $json -Encoding UTF8
}

Write-Output $json
if ($errors.Count -ne 0) {
  exit 1
}
