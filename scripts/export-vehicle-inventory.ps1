param(
  [string]$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
  [string]$BrickadiaRoot = '',
  [string]$InputSnapshotJson = '',
  [string]$InputBrdb = '',
  [string]$OutJson = '',
  [string]$OutMarkdown = '',
  [string]$OutCsv = '',
  [string]$OutText = '',
  [string]$LabelPrefix = 'vehicle',
  [string]$SpawnManifestJson = '',
  [ValidateSet('X', 'XY', 'XYZ')]
  [string]$SpawnMatchMode = 'X',
  [switch]$IncludeAllDynamicActorGroups
)

$ErrorActionPreference = 'Stop'

if (!$BrickadiaRoot) {
  $BrickadiaRoot = (Resolve-Path (Join-Path $Root '..\Brickadia')).Path
}
if (!$OutJson) {
  $OutJson = Join-Path $Root 'artifacts/local/vehicle-inventory.json'
}
if (!$InputSnapshotJson -and !$InputBrdb) {
  throw 'Pass -InputSnapshotJson or -InputBrdb.'
}

$errors = New-Object System.Collections.Generic.List[string]
$evidence = New-Object System.Collections.Generic.List[object]
$startedAt = (Get-Date).ToUniversalTime().ToString('o')
$outPath = [System.IO.Path]::GetFullPath($OutJson)
$caseRoot = Split-Path -Parent $outPath
New-Item -ItemType Directory -Force -Path $caseRoot | Out-Null

if (!$OutMarkdown) {
  $OutMarkdown = [System.IO.Path]::ChangeExtension($outPath, '.md')
}
if (!$OutCsv) {
  $OutCsv = [System.IO.Path]::ChangeExtension($outPath, '.csv')
}
if (!$OutText) {
  $OutText = [System.IO.Path]::ChangeExtension($outPath, '.txt')
}
$markdownPath = [System.IO.Path]::GetFullPath($OutMarkdown)
$csvPath = [System.IO.Path]::GetFullPath($OutCsv)
$textPath = [System.IO.Path]::GetFullPath($OutText)

$snapshotScript = Join-Path $Root 'scripts/summarize-vehicle-graphs.ps1'
$snapshotPath = $null
$snapshotResult = $null
$snapshotData = $null
$spawnManifestPath = $null
$spawnManifest = $null
$spawnCopies = @()
$matches = New-Object System.Collections.Generic.List[object]

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
  $text = Get-Content -Raw -LiteralPath $Path
  if ($text.Length -gt 0 -and [int][char]$text[0] -eq 0xfeff) {
    $text = $text.Substring(1)
  }
  return $text | ConvertFrom-Json
}

function Resolve-SnapshotData($Snapshot) {
  if ($Snapshot.data -and $Snapshot.data.vehicles) {
    return $Snapshot.data
  }
  if ($Snapshot.data -and $Snapshot.data.snapshot -and $Snapshot.data.snapshot.vehicles) {
    return $Snapshot.data.snapshot
  }
  if ($Snapshot.snapshot -and $Snapshot.snapshot.vehicles) {
    return $Snapshot.snapshot
  }
  if ($Snapshot.vehicles) {
    return $Snapshot
  }
  throw 'Input JSON does not contain a recognized vehicle snapshot shape.'
}

function Format-Number([object]$Value) {
  if ($null -eq $Value) {
    return ''
  }
  $number = [double]$Value
  return $number.ToString('0.###', [System.Globalization.CultureInfo]::InvariantCulture)
}

function Join-Ids($Values) {
  $items = @($Values | ForEach-Object { [string]$_ })
  return $items -join ','
}

function Get-MatchDistance($Copy, $Row, [string]$Mode) {
  $position = $Copy.position
  if (!$position) {
    return [double]::PositiveInfinity
  }

  $dx = [double]$Row.centerX - [double]$position.x
  if ($Mode -eq 'X') {
    return [math]::Abs($dx)
  }

  $dy = [double]$Row.centerY - [double]$position.y
  if ($Mode -eq 'XY') {
    return [math]::Sqrt(($dx * $dx) + ($dy * $dy))
  }

  $dz = [double]$Row.centerZ - [double]$position.z
  return [math]::Sqrt(($dx * $dx) + ($dy * $dy) + ($dz * $dz))
}

try {
  if ($InputBrdb) {
    if (!(Test-Path -LiteralPath $InputBrdb)) {
      throw "Input BRDB does not exist: $InputBrdb"
    }
    if (!(Test-Path -LiteralPath $snapshotScript)) {
      throw "Vehicle snapshot script does not exist: $snapshotScript"
    }
    $snapshotPath = Join-Path $caseRoot 'vehicle-inventory.snapshot.json'
    $parserPath = Join-Path $caseRoot 'vehicle-inventory.entities.json'
    $snapshotOutput = & $snapshotScript -Root $Root -BrickadiaRoot $BrickadiaRoot -InputPath $InputBrdb -OutJson $snapshotPath -ParserOutJson $parserPath
    if ($LASTEXITCODE -ne 0) {
      throw "summarize-vehicle-graphs.ps1 failed with exit code $LASTEXITCODE"
    }
    $snapshotResult = $snapshotOutput | ConvertFrom-Json
    Add-Evidence 'brdb' $InputBrdb 'Input BRDB used for vehicle inventory'
    Add-Evidence 'json' $snapshotPath 'Vehicle snapshot generated for inventory'
    Add-Evidence 'json' $parserPath 'Raw parser output generated for inventory'
  } else {
    if (!(Test-Path -LiteralPath $InputSnapshotJson)) {
      throw "Input snapshot JSON does not exist: $InputSnapshotJson"
    }
    $snapshotPath = [System.IO.Path]::GetFullPath($InputSnapshotJson)
    $snapshotResult = Read-JsonFile $snapshotPath
    Add-Evidence 'json' $snapshotPath 'Input vehicle snapshot JSON'
  }

  $snapshotData = Resolve-SnapshotData $snapshotResult

  if ($SpawnManifestJson) {
    if (!(Test-Path -LiteralPath $SpawnManifestJson)) {
      throw "Spawn manifest JSON does not exist: $SpawnManifestJson"
    }
    $spawnManifestPath = [System.IO.Path]::GetFullPath($SpawnManifestJson)
    $spawnManifest = Read-JsonFile $spawnManifestPath
    if (!$spawnManifest.data -or !$spawnManifest.data.stagedCopies) {
      throw 'Spawn manifest JSON does not contain data.stagedCopies.'
    }
    $spawnCopies = @($spawnManifest.data.stagedCopies)
    Add-Evidence 'json' $spawnManifestPath 'Spawn manifest used for vehicle inventory matching'
  }
} catch {
  $errors.Add($_.Exception.Message)
}

$rows = New-Object System.Collections.Generic.List[object]
if ($snapshotData) {
  foreach ($vehicle in @($snapshotData.vehicles)) {
    if (!$IncludeAllDynamicActorGroups -and [string]$vehicle.classification -ne 'dynamic-actor-vehicle-like') {
      continue
    }
    $center = $vehicle.center
    if (!$center) {
      $center = [pscustomobject]@{ X = $null; Y = $null; Z = $null }
    }
    $bodyGrid = $vehicle.bodyGrid
    $label = '{0}-{1:D3}' -f $LabelPrefix, [int]$vehicle.vehicleId
    $rows.Add([pscustomobject][ordered]@{
      label = $label
      vehicleId = [int]$vehicle.vehicleId
      groupId = [int]$vehicle.groupId
      classification = [string]$vehicle.classification
      status = [string]$vehicle.status
      centerX = if ($null -ne $center.X) { [double]$center.X } else { $null }
      centerY = if ($null -ne $center.Y) { [double]$center.Y } else { $null }
      centerZ = if ($null -ne $center.Z) { [double]$center.Z } else { $null }
      relatedEntityCount = [int]$vehicle.relatedEntityCount
      relatedGridCount = [int]$vehicle.relatedGridCount
      brickCount = [int]$vehicle.brickCount
      componentCount = [int]$vehicle.componentCount
      wireCount = [int]$vehicle.wireCount
      bodyGridId = if ($bodyGrid) { [int]$bodyGrid.gridId } else { $null }
      bodyGridBrickCount = if ($bodyGrid) { [int]$bodyGrid.brickCount } else { 0 }
      plannedCopyIndex = $null
      plannedWorldName = $null
      plannedX = $null
      plannedY = $null
      plannedZ = $null
      plannedYaw = $null
      deltaX = $null
      deltaY = $null
      deltaZ = $null
      matchDistance = $null
      seedEntityIds = Join-Ids $vehicle.seedEntityIds
      relatedGridIds = Join-Ids $vehicle.relatedGridIds
    })
  }
}

if ($spawnCopies.Count -gt 0 -and $rows.Count -gt 0) {
  $available = New-Object System.Collections.Generic.List[object]
  foreach ($row in $rows) {
    $available.Add($row)
  }

  foreach ($copy in $spawnCopies) {
    $bestRow = $null
    $bestDistance = [double]::PositiveInfinity
    foreach ($row in $available) {
      $distance = Get-MatchDistance $copy $row $SpawnMatchMode
      if ($distance -lt $bestDistance) {
        $bestDistance = $distance
        $bestRow = $row
      }
    }

    if ($bestRow) {
      $position = $copy.position
      $bestRow.plannedCopyIndex = [int]$copy.index
      $bestRow.plannedWorldName = [string]$copy.worldName
      $bestRow.plannedX = [double]$position.x
      $bestRow.plannedY = [double]$position.y
      $bestRow.plannedZ = [double]$position.z
      $bestRow.plannedYaw = [double]$position.yaw
      $bestRow.deltaX = [double]$bestRow.centerX - [double]$position.x
      $bestRow.deltaY = [double]$bestRow.centerY - [double]$position.y
      $bestRow.deltaZ = [double]$bestRow.centerZ - [double]$position.z
      $bestRow.matchDistance = $bestDistance
      $matches.Add([pscustomobject][ordered]@{
        copyIndex = [int]$copy.index
        worldName = [string]$copy.worldName
        vehicleLabel = [string]$bestRow.label
        vehicleId = [int]$bestRow.vehicleId
        groupId = [int]$bestRow.groupId
        matchMode = $SpawnMatchMode
        matchDistance = $bestDistance
        deltaX = $bestRow.deltaX
        deltaY = $bestRow.deltaY
        deltaZ = $bestRow.deltaZ
      })
      $null = $available.Remove($bestRow)
    }
  }
}

$vehicleCount = $rows.Count
$totalBricks = 0
$totalComponents = 0
$totalWires = 0
foreach ($row in $rows) {
  $totalBricks += [int]$row.brickCount
  $totalComponents += [int]$row.componentCount
  $totalWires += [int]$row.wireCount
}

$consoleLines = New-Object System.Collections.Generic.List[string]
$consoleLines.Add(("Vehicle inventory: {0} vehicle-like groups, {1} bricks, {2} components, {3} wires" -f $vehicleCount, $totalBricks, $totalComponents, $totalWires))
foreach ($row in $rows) {
  $spawnText = ''
  if ($row.plannedWorldName) {
    $spawnText = " spawn=$($row.plannedWorldName) dx=$(Format-Number $row.deltaX)"
  }
  $consoleLines.Add(("{0} group={1} center=({2},{3},{4}) grids={5} bricks={6} bodyGrid={7}/{8} status={9}" -f `
    $row.label,
    $row.groupId,
    (Format-Number $row.centerX),
    (Format-Number $row.centerY),
    (Format-Number $row.centerZ),
    $row.relatedGridCount,
    $row.brickCount,
    $row.bodyGridId,
    $row.bodyGridBrickCount,
    ($row.status + $spawnText)))
}

$markdownLines = New-Object System.Collections.Generic.List[string]
$markdownLines.Add('# Vehicle Inventory')
$markdownLines.Add('')
$markdownLines.Add(('- Vehicles: `{0}`' -f $vehicleCount))
$markdownLines.Add(('- Bricks: `{0}`' -f $totalBricks))
$markdownLines.Add(('- Components: `{0}`' -f $totalComponents))
$markdownLines.Add(('- Wires: `{0}`' -f $totalWires))
$markdownLines.Add('')
$markdownLines.Add('| Label | Spawn | Group | Center | Delta | Entities | Grids | Bricks | Components | Wires | Body Grid | Status |')
$markdownLines.Add('| --- | --- | ---: | --- | --- | ---: | ---: | ---: | ---: | ---: | --- | --- |')
foreach ($row in $rows) {
  $centerText = '({0}, {1}, {2})' -f (Format-Number $row.centerX), (Format-Number $row.centerY), (Format-Number $row.centerZ)
  $spawnText = if ($row.plannedWorldName) { $row.plannedWorldName } else { '' }
  $deltaText = if ($row.plannedWorldName) {
    '({0}, {1}, {2})' -f (Format-Number $row.deltaX), (Format-Number $row.deltaY), (Format-Number $row.deltaZ)
  } else {
    ''
  }
  $bodyText = '{0} / {1} bricks' -f $row.bodyGridId, $row.bodyGridBrickCount
  $markdownLines.Add(('| `{0}` | `{1}` | {2} | `{3}` | `{4}` | {5} | {6} | {7} | {8} | {9} | `{10}` | `{11}` |' -f `
    $row.label,
    $spawnText,
    $row.groupId,
    $centerText,
    $deltaText,
    $row.relatedEntityCount,
    $row.relatedGridCount,
    $row.brickCount,
    $row.componentCount,
    $row.wireCount,
    $bodyText,
    $row.status))
}
$markdownLines.Add('')
if ($matches.Count -gt 0) {
  $markdownLines.Add('## Spawn Matches')
  $markdownLines.Add('')
  $markdownLines.Add('| Copy | World | Vehicle | Group | Match | Delta |')
  $markdownLines.Add('| ---: | --- | --- | ---: | ---: | --- |')
  foreach ($match in $matches) {
    $deltaText = '({0}, {1}, {2})' -f (Format-Number $match.deltaX), (Format-Number $match.deltaY), (Format-Number $match.deltaZ)
    $markdownLines.Add(('| {0} | `{1}` | `{2}` | {3} | {4} | `{5}` |' -f `
      $match.copyIndex,
      $match.worldName,
      $match.vehicleLabel,
      $match.groupId,
      (Format-Number $match.matchDistance),
      $deltaText))
  }
  $markdownLines.Add('')
}
$markdownLines.Add('```text')
foreach ($line in $consoleLines) {
  $markdownLines.Add($line)
}
$markdownLines.Add('```')

try {
  $rows.ToArray() | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding UTF8
  Set-Content -LiteralPath $markdownPath -Value ($markdownLines -join [Environment]::NewLine) -Encoding UTF8
  Set-Content -LiteralPath $textPath -Value ($consoleLines.ToArray() -join [Environment]::NewLine) -Encoding UTF8
  Add-Evidence 'csv' $csvPath 'Vehicle inventory CSV'
  Add-Evidence 'markdown' $markdownPath 'Vehicle inventory Markdown report'
  Add-Evidence 'text' $textPath 'Vehicle inventory console-style text report'
} catch {
  $errors.Add($_.Exception.Message)
}

$result = [ordered]@{
  feature = 'archives.vehicle-inventory'
  status = if ($errors.Count -eq 0) { 'passed' } else { 'failed' }
  validationLevel = 'L0 Static'
  startedAt = $startedAt
  finishedAt = (Get-Date).ToUniversalTime().ToString('o')
  data = [ordered]@{
    inputSnapshotJson = if ($snapshotPath) { [System.IO.Path]::GetFullPath($snapshotPath) } else { $null }
    inputBrdb = if ($InputBrdb) { [System.IO.Path]::GetFullPath($InputBrdb) } else { $null }
    spawnManifestJson = $spawnManifestPath
    spawnMatchMode = if ($spawnCopies.Count -gt 0) { $SpawnMatchMode } else { $null }
    markdownPath = $markdownPath
    csvPath = $csvPath
    textPath = $textPath
    vehicleCount = $vehicleCount
    brickCount = $totalBricks
    componentCount = $totalComponents
    wireCount = $totalWires
    console = $consoleLines.ToArray()
    spawnMatches = $matches.ToArray()
    vehicles = $rows.ToArray()
  }
  evidence = $evidence
  errors = @($errors)
}

$json = $result | ConvertTo-Json -Depth 12
Set-Content -LiteralPath $outPath -Value $json -Encoding UTF8
Write-Output $json

if ($errors.Count -ne 0) {
  exit 1
}
