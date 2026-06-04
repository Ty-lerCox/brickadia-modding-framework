param(
  [string]$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
  [string]$BrickadiaRoot = '',
  [string]$SourceWorldBrdb = '',
  [string]$OutJson = '',
  [string]$ArtifactDir = '',
  [string]$WorldNamePrefix = 'BMF_VehicleSpawnSet',
  [int]$VehicleCount = 3,
  [int]$IdStride = 100000,
  [int]$StartX = 70000,
  [int]$StepX = 2000,
  [int]$LoadY = 0,
  [int]$LoadZ = 1000,
  [int]$LoadYaw = 0,
  [switch]$StageToServerWorlds
)

$ErrorActionPreference = 'Stop'

if (!$BrickadiaRoot) {
  $BrickadiaRoot = (Resolve-Path (Join-Path $Root '..\Brickadia')).Path
}
if (!$OutJson) {
  $OutJson = Join-Path $Root 'artifacts/local/vehicle-spawn-set-stage.json'
}
if ($VehicleCount -lt 1) {
  throw '-VehicleCount must be at least 1.'
}
if ($IdStride -le 0) {
  throw '-IdStride must be positive.'
}
if ($WorldNamePrefix -match '[/\\]' -or $WorldNamePrefix -match '\.\.' -or $WorldNamePrefix.Trim() -eq '') {
  throw '-WorldNamePrefix must be a non-empty Brickadia world name prefix without path separators.'
}

$errors = New-Object System.Collections.Generic.List[string]
$evidence = New-Object System.Collections.Generic.List[object]
$startedAt = (Get-Date).ToUniversalTime().ToString('o')
$outPath = [System.IO.Path]::GetFullPath($OutJson)
$artifactRoot = Split-Path -Parent $outPath
if ($ArtifactDir) {
  $caseRoot = [System.IO.Path]::GetFullPath($ArtifactDir)
} else {
  $caseRoot = Join-Path $artifactRoot 'vehicle-spawn-set-stage'
}
New-Item -ItemType Directory -Force -Path $caseRoot | Out-Null

$defaultSliceWorld = Join-Path $Root 'artifacts/overnight/20260603-215931/dynamic-actor-slice-additive/dynamic-actor-slices/threecars.entity20.slice.brdb'
$sourceWorldPath = if ($SourceWorldBrdb) {
  [System.IO.Path]::GetFullPath($SourceWorldBrdb)
} elseif (Test-Path -LiteralPath $defaultSliceWorld) {
  [System.IO.Path]::GetFullPath($defaultSliceWorld)
} else {
  ''
}

$remapScript = Join-Path $Root 'scripts/remap-staged-vehicle-brdb.js'
$snapshotScript = Join-Path $Root 'scripts/summarize-vehicle-graphs.ps1'
$worldsDir = Join-Path $BrickadiaRoot 'omegga-master/omegga-master/data/Saved/Worlds'

$sourceSnapshotPath = Join-Path $caseRoot 'source-world.vehicle-snapshot.json'
$sourceEntitiesPath = Join-Path $caseRoot 'source-world.entities.json'
$sourceSnapshot = $null
$stagedCopies = New-Object System.Collections.Generic.List[object]

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
  foreach ($path in @($remapScript, $snapshotScript)) {
    if (!(Test-Path -LiteralPath $path)) {
      throw "Required path does not exist: $path"
    }
  }
  if (!$sourceWorldPath -or !(Test-Path -LiteralPath $sourceWorldPath)) {
    throw "Source world BRDB does not exist. Pass -SourceWorldBrdb or run the dynamic actor slice canary first."
  }

  Add-Evidence 'brdb' $sourceWorldPath 'Source graph-closure single-car dynamic-actor slice'

  $sourceSnapshotOutput = & $snapshotScript -InputPath $sourceWorldPath -OutJson $sourceSnapshotPath -ParserOutJson $sourceEntitiesPath
  if ($LASTEXITCODE -ne 0) {
    throw "summarize-vehicle-graphs.ps1 failed with exit code $LASTEXITCODE"
  }
  $sourceSnapshot = $sourceSnapshotOutput | ConvertFrom-Json
  Add-Evidence 'json' $sourceSnapshotPath 'Static vehicle snapshot for source slice'
  Add-Evidence 'json' $sourceEntitiesPath 'Raw parser output for source slice'
  if ([int]$sourceSnapshot.data.vehicleLikeGroupCount -ne 1) {
    $errors.Add("Source static snapshot expected 1 vehicle-like group, got $($sourceSnapshot.data.vehicleLikeGroupCount).")
  }
  $expectedVehicle = @($sourceSnapshot.data.vehicles | Where-Object { $_.classification -eq 'dynamic-actor-vehicle-like' } | Select-Object -First 1)
  if (!$expectedVehicle) {
    throw 'Source snapshot did not contain a vehicle-like dynamic actor group.'
  }

  if ($StageToServerWorlds) {
    New-Item -ItemType Directory -Force -Path $worldsDir | Out-Null
  }

  for ($index = 1; $index -le $VehicleCount; $index++) {
    $worldName = '{0}_{1:D2}' -f $WorldNamePrefix, $index
    $artifactBrdb = Join-Path $caseRoot ('vehicle-{0:D2}.brdb' -f $index)
    $stagePath = if ($StageToServerWorlds) { Join-Path $worldsDir ($worldName + '.brdb') } else { $null }
    $reportPath = Join-Path $caseRoot ('vehicle-{0:D2}.remap-report.json' -f $index)
    $staticSnapshotPath = Join-Path $caseRoot ('vehicle-{0:D2}.vehicle-snapshot.json' -f $index)
    $staticEntitiesPath = Join-Path $caseRoot ('vehicle-{0:D2}.entities.json' -f $index)
    $offset = ($index - 1) * $IdStride

    if ($index -eq 1) {
      Copy-Item -LiteralPath $sourceWorldPath -Destination $artifactBrdb -Force
      [ordered]@{
        feature = 'archives.staged-vehicle-brdb-id-remap'
        status = 'passed'
        validationLevel = 'L0 Static'
        inputPath = [System.IO.Path]::GetFullPath($sourceWorldPath)
        outputPath = [System.IO.Path]::GetFullPath($artifactBrdb)
        entityOffset = 0
        gridOffset = 0
        notes = @('Copy 1 uses the source archive without id remapping.')
      } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $reportPath -Encoding UTF8
    } else {
      $remapOutput = & node $remapScript $sourceWorldPath $artifactBrdb --entity-offset $offset --grid-offset $offset --report-json $reportPath --force
      if ($LASTEXITCODE -ne 0) {
        throw "remap-staged-vehicle-brdb.js failed for copy $index with exit code $LASTEXITCODE"
      }
      $null = $remapOutput | ConvertFrom-Json
    }
    Add-Evidence 'json' $reportPath "Static id remap report for vehicle copy $index"
    Add-Evidence 'brdb' $artifactBrdb "Staged vehicle copy $index BRDB"

    $staticOutput = & $snapshotScript -InputPath $artifactBrdb -OutJson $staticSnapshotPath -ParserOutJson $staticEntitiesPath
    if ($LASTEXITCODE -ne 0) {
      throw "summarize-vehicle-graphs.ps1 failed for copy $index with exit code $LASTEXITCODE"
    }
    $staticSnapshot = $staticOutput | ConvertFrom-Json
    Add-Evidence 'json' $staticSnapshotPath "Static vehicle snapshot for vehicle copy $index"
    Add-Evidence 'json' $staticEntitiesPath "Raw parser output for vehicle copy $index"
    $staticVehicle = @($staticSnapshot.data.vehicles | Where-Object { $_.classification -eq 'dynamic-actor-vehicle-like' } | Select-Object -First 1)
    if ([int]$staticSnapshot.data.vehicleLikeGroupCount -ne 1 -or !$staticVehicle) {
      $errors.Add("Vehicle copy $index static snapshot did not contain exactly one vehicle-like group.")
    } elseif (
      [int]$staticVehicle.relatedEntityCount -ne [int]$expectedVehicle.relatedEntityCount -or
      [int]$staticVehicle.relatedGridCount -ne [int]$expectedVehicle.relatedGridCount -or
      [int]$staticVehicle.brickCount -ne [int]$expectedVehicle.brickCount -or
      [int]$staticVehicle.componentCount -ne [int]$expectedVehicle.componentCount -or
      [int]$staticVehicle.wireCount -ne [int]$expectedVehicle.wireCount
    ) {
      $errors.Add("Vehicle copy $index static snapshot does not match source vehicle totals.")
    }

    $stagePathFull = $null
    if ($StageToServerWorlds) {
      Copy-Item -LiteralPath $artifactBrdb -Destination $stagePath -Force
      $stagePathFull = [System.IO.Path]::GetFullPath($stagePath)
      Add-Evidence 'brdb' $stagePath "Vehicle copy $index copied into Brickadia Saved/Worlds"
    }

    $stagedCopies.Add([ordered]@{
      index = $index
      worldName = $worldName
      artifactBrdb = [System.IO.Path]::GetFullPath($artifactBrdb)
      stagedWorldPath = $stagePathFull
      entityOffset = $offset
      gridOffset = $offset
      position = [ordered]@{
        x = $StartX + (($index - 1) * $StepX)
        y = $LoadY
        z = $LoadZ
        yaw = $LoadYaw
      }
      staticSnapshot = $staticSnapshot.data
    })
  }
} catch {
  $errors.Add($_.Exception.Message)
}

$sourceWorldFullPath = $null
if ($sourceWorldPath) {
  $sourceWorldFullPath = [System.IO.Path]::GetFullPath($sourceWorldPath)
}
$sourceSnapshotData = $null
if ($sourceSnapshot) {
  $sourceSnapshotData = $sourceSnapshot.data
}

$result = [ordered]@{
  feature = 'archives.vehicle-spawn-set.stage'
  status = if ($errors.Count -eq 0) { 'passed' } else { 'failed' }
  validationLevel = 'L0 Static'
  startedAt = $startedAt
  finishedAt = (Get-Date).ToUniversalTime().ToString('o')
  data = [ordered]@{
    sourceWorldBrdb = $sourceWorldFullPath
    brickadiaRoot = [System.IO.Path]::GetFullPath($BrickadiaRoot)
    artifactDir = [System.IO.Path]::GetFullPath($caseRoot)
    stageToServerWorlds = $StageToServerWorlds.IsPresent
    worldNamePrefix = $WorldNamePrefix
    vehicleCount = $VehicleCount
    idStride = $IdStride
    sourceStaticSnapshot = $sourceSnapshotData
    stagedCopies = $stagedCopies.ToArray()
  }
  evidence = $evidence
  errors = @($errors)
}

$json = $result | ConvertTo-Json -Depth 18
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $outPath) | Out-Null
Set-Content -LiteralPath $outPath -Value $json -Encoding UTF8
Write-Output $json

if ($errors.Count -ne 0) {
  exit 1
}
