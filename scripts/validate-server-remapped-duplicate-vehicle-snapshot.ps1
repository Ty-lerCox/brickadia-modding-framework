param(
  [string]$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
  [string]$BrickadiaRoot = '',
  [string]$InputBrz = '',
  [string]$SourceWorldBrdb = '',
  [string]$OutJson = '',
  [int]$Port = 7823,
  [int]$EntityOffset = 100000,
  [int]$GridOffset = 100000,
  [int]$FirstLoadX = 64000,
  [int]$SecondLoadX = 66000,
  [int]$LoadY = 0,
  [int]$LoadZ = 1000,
  [int]$LoadYaw = 0
)

$ErrorActionPreference = 'Stop'

if (!$BrickadiaRoot) {
  $BrickadiaRoot = (Resolve-Path (Join-Path $Root '..\Brickadia')).Path
}
if (!$InputBrz) {
  $InputBrz = Join-Path $BrickadiaRoot 'Car.brz'
}
if (!$OutJson) {
  $OutJson = Join-Path $Root 'artifacts/local/server-remapped-duplicate-vehicle-snapshot-canary.json'
}

$errors = New-Object System.Collections.Generic.List[string]
$evidence = New-Object System.Collections.Generic.List[object]
$startedAt = (Get-Date).ToUniversalTime().ToString('o')
$outPath = [System.IO.Path]::GetFullPath($OutJson)
$artifactRoot = Split-Path -Parent $outPath
$caseRoot = Join-Path $artifactRoot 'server-remapped-duplicate-vehicle-snapshot'
New-Item -ItemType Directory -Force -Path $caseRoot | Out-Null

$stageScript = Join-Path $Root 'scripts/stage-brz-prefab.ps1'
$remapScript = Join-Path $Root 'scripts/remap-staged-vehicle-brdb.js'
$snapshotServerScript = Join-Path $Root 'scripts/snapshot-server-vehicles.ps1'
$startServerScript = Join-Path $BrickadiaRoot 'brickadia-ue4ss-re/scripts/start-bridge-test-server.ps1'
$sendRpcScript = Join-Path $BrickadiaRoot 'brickadia-ue4ss-re/scripts/send-bridge-rpc.js'
$worldsDir = Join-Path $BrickadiaRoot 'omegga-master/omegga-master/data/Saved/Worlds'

$originalWorldName = 'BMF_CarDuplicateOriginal'
$remappedWorldName = 'BMF_CarDuplicateRemapped'
$saveName = 'BMF_RemappedDuplicateVehicleSnapshot_{0}' -f (Get-Date -Format 'yyyyMMddHHmmss')
$defaultSliceWorld = Join-Path $Root 'artifacts/overnight/20260603-215931/dynamic-actor-slice-additive/dynamic-actor-slices/threecars.entity20.slice.brdb'
$sourceWorldPath = if ($SourceWorldBrdb) {
  [System.IO.Path]::GetFullPath($SourceWorldBrdb)
} elseif (Test-Path -LiteralPath $defaultSliceWorld) {
  [System.IO.Path]::GetFullPath($defaultSliceWorld)
} else {
  Join-Path $caseRoot 'car-source-world.brdb'
}
$stagePath = Join-Path $caseRoot 'stage-brz-prefab.json'
$sourceStaticSnapshotPath = Join-Path $caseRoot 'source-world.vehicle-snapshot.json'
$sourceStaticEntitiesPath = Join-Path $caseRoot 'source-world.entities.json'
$remappedWorldPath = Join-Path $caseRoot 'car-remapped-world.brdb'
$remapReportPath = Join-Path $caseRoot 'car-remapped-world.report.json'
$remappedStaticSnapshotPath = Join-Path $caseRoot 'car-remapped-world.vehicle-snapshot.json'
$remappedStaticEntitiesPath = Join-Path $caseRoot 'car-remapped-world.entities.json'
$originalStagedWorldPath = Join-Path $worldsDir ($originalWorldName + '.brdb')
$remappedStagedWorldPath = Join-Path $worldsDir ($remappedWorldName + '.brdb')
$bridgeDir = Join-Path $caseRoot "bridge-$Port"
$startPath = Join-Path $caseRoot 'server-start.json'
$loadOriginalPath = Join-Path $caseRoot 'load-original-rpc.json'
$loadRemappedPath = Join-Path $caseRoot 'load-remapped-rpc.json'
$snapshotPath = Join-Path $caseRoot 'server-remapped-duplicate-vehicle-snapshot.json'
$serverPid = $null
$snapshotResult = $null
$sourceStaticSnapshot = $null
$remapReport = $null
$staticRemappedSnapshot = $null

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
  foreach ($path in @($stageScript, $remapScript, $snapshotServerScript, $startServerScript, $sendRpcScript)) {
    if (!(Test-Path -LiteralPath $path)) {
      throw "Required path does not exist: $path"
    }
  }
  if ((Test-Path -LiteralPath $defaultSliceWorld) -and !$SourceWorldBrdb) {
    Add-Evidence 'brdb' $sourceWorldPath 'Default source dynamic-actor slice with body-grid entity'
  }
  if ((($SourceWorldBrdb) -or (Test-Path -LiteralPath $defaultSliceWorld)) -and !(Test-Path -LiteralPath $sourceWorldPath)) {
    throw "Source world BRDB does not exist: $sourceWorldPath"
  }
  if (!$SourceWorldBrdb -and !(Test-Path -LiteralPath $defaultSliceWorld) -and !(Test-Path -LiteralPath $InputBrz)) {
    throw "Input BRZ does not exist: $InputBrz"
  }

  if (!$SourceWorldBrdb -and !(Test-Path -LiteralPath $defaultSliceWorld)) {
    $stageOutput = & $stageScript -Root $Root -BrickadiaRoot $BrickadiaRoot -InputBrz $InputBrz -OutputBrdb $sourceWorldPath -OutJson $stagePath -Force
    if ($LASTEXITCODE -ne 0) {
      throw "stage-brz-prefab.ps1 failed with exit code $LASTEXITCODE"
    }
    $stage = $stageOutput | ConvertFrom-Json
    if ($stage.status -ne 'passed') {
      throw 'BRZ staging did not pass.'
    }
    Add-Evidence 'json' $stagePath 'Static BRZ-to-BRDB staging result'
  }
  Add-Evidence 'brdb' $sourceWorldPath 'Original staged single-car world BRDB'

  $sourceSnapshotOutput = & (Join-Path $Root 'scripts/summarize-vehicle-graphs.ps1') -InputPath $sourceWorldPath -OutJson $sourceStaticSnapshotPath -ParserOutJson $sourceStaticEntitiesPath
  if ($LASTEXITCODE -ne 0) {
    throw "summarize-vehicle-graphs.ps1 failed with exit code $LASTEXITCODE"
  }
  $sourceStaticSnapshot = $sourceSnapshotOutput | ConvertFrom-Json
  Add-Evidence 'json' $sourceStaticSnapshotPath 'Static vehicle snapshot for source BRDB'
  Add-Evidence 'json' $sourceStaticEntitiesPath 'Raw parser output for source BRDB'
  if ($sourceStaticSnapshot.data.vehicleLikeGroupCount -ne 1) {
    $errors.Add("Source static snapshot expected 1 vehicle-like group, got $($sourceStaticSnapshot.data.vehicleLikeGroupCount).")
  }

  $remapOutput = & node $remapScript $sourceWorldPath $remappedWorldPath --entity-offset $EntityOffset --grid-offset $GridOffset --report-json $remapReportPath --force
  if ($LASTEXITCODE -ne 0) {
    throw "remap-staged-vehicle-brdb.js failed with exit code $LASTEXITCODE"
  }
  $remapReport = $remapOutput | ConvertFrom-Json
  Add-Evidence 'json' $remapReportPath 'Static BRDB entity/grid id remap report'
  Add-Evidence 'brdb' $remappedWorldPath 'Remapped staged single-car world BRDB'

  $staticSnapshotOutput = & (Join-Path $Root 'scripts/summarize-vehicle-graphs.ps1') -InputPath $remappedWorldPath -OutJson $remappedStaticSnapshotPath -ParserOutJson $remappedStaticEntitiesPath
  if ($LASTEXITCODE -ne 0) {
    throw "summarize-vehicle-graphs.ps1 failed with exit code $LASTEXITCODE"
  }
  $staticRemappedSnapshot = $staticSnapshotOutput | ConvertFrom-Json
  Add-Evidence 'json' $remappedStaticSnapshotPath 'Static vehicle snapshot for remapped BRDB'
  Add-Evidence 'json' $remappedStaticEntitiesPath 'Raw parser output for remapped BRDB'
  if ($staticRemappedSnapshot.data.vehicleLikeGroupCount -ne 1) {
    $errors.Add("Remapped static snapshot expected 1 vehicle-like group, got $($staticRemappedSnapshot.data.vehicleLikeGroupCount).")
  }
  if ($sourceStaticSnapshot -and $staticRemappedSnapshot -and $sourceStaticSnapshot.data.vehicleLikeGroupCount -eq 1 -and $staticRemappedSnapshot.data.vehicleLikeGroupCount -eq 1) {
    $sourceVehicle = @($sourceStaticSnapshot.data.vehicles | Where-Object { $_.classification -eq 'dynamic-actor-vehicle-like' } | Select-Object -First 1)
    $remappedVehicle = @($staticRemappedSnapshot.data.vehicles | Where-Object { $_.classification -eq 'dynamic-actor-vehicle-like' } | Select-Object -First 1)
    if ([int]$remappedVehicle.relatedEntityCount -ne [int]$sourceVehicle.relatedEntityCount) {
      $errors.Add("Remapped static vehicle expected $($sourceVehicle.relatedEntityCount) related entities, got $($remappedVehicle.relatedEntityCount).")
    }
    if ([int]$remappedVehicle.relatedGridCount -ne [int]$sourceVehicle.relatedGridCount) {
      $errors.Add("Remapped static vehicle expected $($sourceVehicle.relatedGridCount) related grids, got $($remappedVehicle.relatedGridCount).")
    }
    if ([int]$remappedVehicle.brickCount -ne [int]$sourceVehicle.brickCount) {
      $errors.Add("Remapped static vehicle expected $($sourceVehicle.brickCount) bricks, got $($remappedVehicle.brickCount).")
    }
  }

  New-Item -ItemType Directory -Force -Path $worldsDir | Out-Null
  Copy-Item -LiteralPath $sourceWorldPath -Destination $originalStagedWorldPath -Force
  Copy-Item -LiteralPath $remappedWorldPath -Destination $remappedStagedWorldPath -Force
  Add-Evidence 'brdb' $originalStagedWorldPath 'Original world copied into Brickadia Saved/Worlds'
  Add-Evidence 'brdb' $remappedStagedWorldPath 'Remapped world copied into Brickadia Saved/Worlds'

  $startOutput = & $startServerScript -BridgeDir $bridgeDir -Port $Port -VerifyWaitSeconds 30
  $startOutput | Set-Content -LiteralPath $startPath -Encoding UTF8
  $start = $startOutput | ConvertFrom-Json
  $serverPid = [int]$start.pid
  Add-Evidence 'json' $startPath 'Bridge test server startup result'
  if ($start.verified -ne $true) {
    $errors.Add("Bridge server did not verify: $($start.verify_reason)")
  } else {
    Start-Sleep -Seconds 2

    $loadOriginalCommand = "Omegga.Bridge.ForceConsoleExecutor consolemanager BR.World.LoadAdditive $originalWorldName $FirstLoadX $LoadY $LoadZ $LoadYaw"
    $loadOriginalOutput = & node $sendRpcScript --dir $bridgeDir --method console.exec --command-raw $loadOriginalCommand --wait-ms 20000 --include-logs 1
    $loadOriginalOutput | Set-Content -LiteralPath $loadOriginalPath -Encoding UTF8
    $loadOriginal = $loadOriginalOutput | ConvertFrom-Json
    Add-Evidence 'json' $loadOriginalPath 'LoadAdditive bridge RPC result for original world'
    if ($loadOriginal.complete.success -ne $true) {
      $errors.Add('Original LoadAdditive RPC did not report success.')
    }

    Start-Sleep -Seconds 4

    $loadRemappedCommand = "Omegga.Bridge.ForceConsoleExecutor consolemanager BR.World.LoadAdditive $remappedWorldName $SecondLoadX $LoadY $LoadZ $LoadYaw"
    $loadRemappedOutput = & node $sendRpcScript --dir $bridgeDir --method console.exec --command-raw $loadRemappedCommand --wait-ms 20000 --include-logs 1
    $loadRemappedOutput | Set-Content -LiteralPath $loadRemappedPath -Encoding UTF8
    $loadRemapped = $loadRemappedOutput | ConvertFrom-Json
    Add-Evidence 'json' $loadRemappedPath 'LoadAdditive bridge RPC result for remapped world'
    if ($loadRemapped.complete.success -ne $true) {
      $errors.Add('Remapped LoadAdditive RPC did not report success.')
    }

    Start-Sleep -Seconds 10

    $snapshotOutput = & $snapshotServerScript -Root $Root -BrickadiaRoot $BrickadiaRoot -BridgeDir $bridgeDir -SaveName $saveName -OutJson $snapshotPath
    if ($LASTEXITCODE -ne 0) {
      throw "snapshot-server-vehicles.ps1 failed with exit code $LASTEXITCODE"
    }
    $snapshotResult = $snapshotOutput | ConvertFrom-Json
    Add-Evidence 'json' $snapshotPath 'Server remapped duplicate vehicle snapshot result'
    foreach ($item in @($snapshotResult.evidence)) {
      Add-Evidence $item.kind $item.path $item.summary
    }
  }
} catch {
  $errors.Add($_.Exception.Message)
} finally {
  if ($serverPid) {
    Stop-Process -Id $serverPid -Force -ErrorAction SilentlyContinue
  }
  Get-CimInstance Win32_Process |
    Where-Object { $_.Name -eq 'BrickadiaServer-Win64-Shipping.exe' -and $_.CommandLine -like "*-port=`"$Port`"*"} |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}

if ($snapshotResult) {
  $snapshot = $snapshotResult.data.snapshot
  $expectedVehicle = $null
  if ($sourceStaticSnapshot) {
    $expectedVehicle = @($sourceStaticSnapshot.data.vehicles | Where-Object { $_.classification -eq 'dynamic-actor-vehicle-like' } | Select-Object -First 1)
  }
  if (!$expectedVehicle) {
    $expectedVehicle = [pscustomobject]@{
      relatedEntityCount = 19
      relatedGridCount = 16
      brickCount = 1528
      componentCount = 123
      wireCount = 103
      bodyGrid = [pscustomobject]@{ brickCount = 1254 }
    }
  }
  $expectedVehicleBrickCount = [int]$expectedVehicle.brickCount * 2
  $expectedVehicleComponentCount = [int]$expectedVehicle.componentCount * 2
  $expectedVehicleWireCount = [int]$expectedVehicle.wireCount * 2
  if ($snapshotResult.status -ne 'passed') {
    $errors.Add('Server remapped duplicate vehicle snapshot did not pass.')
  }
  if ([int]$snapshot.vehicleLikeGroupCount -ne 2) {
    $errors.Add("Expected 2 vehicle-like groups, got $($snapshot.vehicleLikeGroupCount).")
  }
  if ([int]$snapshot.vehicleBrickCount -ne $expectedVehicleBrickCount) {
    $errors.Add("Expected $expectedVehicleBrickCount vehicle bricks, got $($snapshot.vehicleBrickCount).")
  }
  if ([int]$snapshot.vehicleComponentCount -ne $expectedVehicleComponentCount) {
    $errors.Add("Expected $expectedVehicleComponentCount vehicle components, got $($snapshot.vehicleComponentCount).")
  }
  if ([int]$snapshot.vehicleWireCount -ne $expectedVehicleWireCount) {
    $errors.Add("Expected $expectedVehicleWireCount vehicle wires, got $($snapshot.vehicleWireCount).")
  }

  foreach ($vehicle in @($snapshot.vehicles | Where-Object { $_.classification -eq 'dynamic-actor-vehicle-like' })) {
    if ([int]$vehicle.relatedEntityCount -ne [int]$expectedVehicle.relatedEntityCount) {
      $errors.Add("Vehicle $($vehicle.vehicleId) expected $($expectedVehicle.relatedEntityCount) related entities, got $($vehicle.relatedEntityCount).")
    }
    if ([int]$vehicle.relatedGridCount -ne [int]$expectedVehicle.relatedGridCount) {
      $errors.Add("Vehicle $($vehicle.vehicleId) expected $($expectedVehicle.relatedGridCount) related grids, got $($vehicle.relatedGridCount).")
    }
    if ([int]$vehicle.brickCount -ne [int]$expectedVehicle.brickCount) {
      $errors.Add("Vehicle $($vehicle.vehicleId) expected $($expectedVehicle.brickCount) bricks, got $($vehicle.brickCount).")
    }
    if ([int]$vehicle.componentCount -ne [int]$expectedVehicle.componentCount) {
      $errors.Add("Vehicle $($vehicle.vehicleId) expected $($expectedVehicle.componentCount) components, got $($vehicle.componentCount).")
    }
    if ([int]$vehicle.wireCount -ne [int]$expectedVehicle.wireCount) {
      $errors.Add("Vehicle $($vehicle.vehicleId) expected $($expectedVehicle.wireCount) wires, got $($vehicle.wireCount).")
    }
    if (!$vehicle.bodyGrid -or [int]$vehicle.bodyGrid.brickCount -ne [int]$expectedVehicle.bodyGrid.brickCount) {
      $errors.Add("Vehicle $($vehicle.vehicleId) did not identify a $($expectedVehicle.bodyGrid.brickCount)-brick body grid.")
    }
  }
} else {
  $errors.Add('Server remapped duplicate vehicle snapshot result was not produced.')
}

$result = [ordered]@{
  feature = 'server.vehicle-snapshot.remapped-duplicate-additive-l2'
  status = if ($errors.Count -eq 0) { 'passed' } else { 'failed' }
  validationLevel = 'L2 Headless Server'
  startedAt = $startedAt
  finishedAt = (Get-Date).ToUniversalTime().ToString('o')
  data = [ordered]@{
    inputBrz = if ($InputBrz) { [System.IO.Path]::GetFullPath($InputBrz) } else { $null }
    sourceWorldBrdb = [System.IO.Path]::GetFullPath($sourceWorldPath)
    remappedWorldBrdb = [System.IO.Path]::GetFullPath($remappedWorldPath)
    brickadiaRoot = [System.IO.Path]::GetFullPath($BrickadiaRoot)
    port = $Port
    entityOffset = $EntityOffset
    gridOffset = $GridOffset
    originalWorldName = $originalWorldName
    remappedWorldName = $remappedWorldName
    saveName = $saveName
    loadLocations = @(
      [ordered]@{ name = $originalWorldName; x = $FirstLoadX; y = $LoadY; z = $LoadZ; yaw = $LoadYaw },
      [ordered]@{ name = $remappedWorldName; x = $SecondLoadX; y = $LoadY; z = $LoadZ; yaw = $LoadYaw }
    )
    sourceStaticSnapshot = if ($sourceStaticSnapshot) { $sourceStaticSnapshot.data } else { $null }
    remap = if ($remapReport) { $remapReport } else { $null }
    staticRemappedSnapshot = if ($staticRemappedSnapshot) { $staticRemappedSnapshot.data } else { $null }
    snapshot = if ($snapshotResult) { $snapshotResult.data.snapshot } else { $null }
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
