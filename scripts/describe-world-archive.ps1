param(
  [Parameter(Mandatory = $true)]
  [string]$InputPath,
  [string]$ParserPath = '',
  [string]$OutJson = '',
  [string]$ParserOutJson = ''
)

$ErrorActionPreference = 'Stop'

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
    $ParserOutJson = Join-Path ([System.IO.Path]::GetTempPath()) ("bmf-world-entities-" + [guid]::NewGuid().ToString('n') + ".json")
  }
}
$parserOutFullPath = [System.IO.Path]::GetFullPath($ParserOutJson)
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $parserOutFullPath) | Out-Null

$null = & node $parserFullPath $inputFullPath --out-json $parserOutFullPath

$parsed = Get-Content -Raw -LiteralPath $parserOutFullPath | ConvertFrom-Json
$entities = @($parsed.entities)
$groups = @($parsed.dynamicActorGroups)
$graphs = @($parsed.dynamicActorGraphs)
$typeNames = @($parsed.typeNames)

$typeCounts = @($entities | Group-Object typeName | Sort-Object Name | ForEach-Object {
  [ordered]@{
    typeName = $_.Name
    count = $_.Count
  }
})

$groupSummaries = @($groups | ForEach-Object {
  [ordered]@{
    groupId = $_.groupId
    status = $_.status
    seedEntityIds = @($_.seedEntityIds)
    relatedEntityCount = $_.relatedEntityCount
    relatedGridCount = $_.relatedGridCount
    center = $_.center
    chunkPathCounts = $_.chunkPathCounts
  }
})

$result = [ordered]@{
  feature = 'archives.describe'
  status = 'passed'
  validationLevel = 'L0 Static'
  startedAt = (Get-Date).ToUniversalTime().ToString('o')
  finishedAt = (Get-Date).ToUniversalTime().ToString('o')
  data = [ordered]@{
    inputPath = $inputFullPath
    parserPath = $parserFullPath
    parserOutput = $parserOutFullPath
    archiveBytes = (Get-Item -LiteralPath $inputFullPath).Length
    entityCount = $entities.Count
    typeNames = $typeNames
    typeCounts = $typeCounts
    dynamicActorGraphCount = $graphs.Count
    dynamicActorGroupCount = $groups.Count
    dynamicActorGroups = $groupSummaries
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

$json = $result | ConvertTo-Json -Depth 12
if ($OutJson) {
  $outPath = [System.IO.Path]::GetFullPath($OutJson)
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $outPath) | Out-Null
  Set-Content -LiteralPath $outPath -Value $json -Encoding UTF8
}

Write-Output $json
