param(
  [string]$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
  [string]$BrickadiaRoot = '',
  [string]$SourceWorldBrdb = '',
  [string]$OutJson = '',
  [int]$Port = 7825,
  [int]$VehicleCount = 3,
  [int]$IdStride = 100000,
  [int]$StartX = 70000,
  [int]$StepX = 2000,
  [int]$LoadY = 0,
  [int]$LoadZ = 1000,
  [int]$LoadYaw = 0
)

$ErrorActionPreference = 'Stop'

if (!$BrickadiaRoot) {
  $BrickadiaRoot = (Resolve-Path (Join-Path $Root '..\Brickadia')).Path
}
if (!$OutJson) {
  $OutJson = Join-Path $Root 'artifacts/local/server-vehicle-spawn-set-canary.json'
}

$errors = New-Object System.Collections.Generic.List[string]
$evidence = New-Object System.Collections.Generic.List[object]
$startedAt = (Get-Date).ToUniversalTime().ToString('o')
$outPath = [System.IO.Path]::GetFullPath($OutJson)
$artifactRoot = Split-Path -Parent $outPath
$caseRoot = Join-Path $artifactRoot 'server-vehicle-spawn-set'
New-Item -ItemType Directory -Force -Path $caseRoot | Out-Null

$stageScript = Join-Path $Root 'scripts/stage-vehicle-spawn-set.ps1'
$snapshotServerScript = Join-Path $Root 'scripts/snapshot-server-vehicles.ps1'
$startServerScript = Join-Path $BrickadiaRoot 'brickadia-ue4ss-re/scripts/start-bridge-test-server.ps1'
$sendRpcScript = Join-Path $BrickadiaRoot 'brickadia-ue4ss-re/scripts/send-bridge-rpc.js'

$stageManifestPath = Join-Path $caseRoot 'stage-vehicle-spawn-set.json'
$bridgeDir = Join-Path $caseRoot "bridge-$Port"
$startPath = Join-Path $caseRoot 'server-start.json'
$snapshotPath = Join-Path $caseRoot 'server-vehicle-spawn-set.json'
$saveName = 'BMF_VehicleSpawnSet_{0}' -f (Get-Date -Format 'yyyyMMddHHmmss')
$serverPid = $null
$stage = $null
$snapshotResult = $null

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
  foreach ($path in @($stageScript, $snapshotServerScript, $startServerScript, $sendRpcScript)) {
    if (!(Test-Path -LiteralPath $path)) {
      throw "Required path does not exist: $path"
    }
  }

  $stageArgs = @{
    Root = $Root
    BrickadiaRoot = $BrickadiaRoot
    OutJson = $stageManifestPath
    ArtifactDir = $caseRoot
    WorldNamePrefix = 'BMF_VehicleSpawnSet'
    VehicleCount = $VehicleCount
    IdStride = $IdStride
    StartX = $StartX
    StepX = $StepX
    LoadY = $LoadY
    LoadZ = $LoadZ
    LoadYaw = $LoadYaw
    StageToServerWorlds = $true
  }
  if ($SourceWorldBrdb) {
    $stageArgs.SourceWorldBrdb = $SourceWorldBrdb
  }
  $stageOutput = & $stageScript @stageArgs
  if ($LASTEXITCODE -ne 0) {
    throw "stage-vehicle-spawn-set.ps1 failed with exit code $LASTEXITCODE"
  }
  $stage = $stageOutput | ConvertFrom-Json
  Add-Evidence 'json' $stageManifestPath 'Vehicle spawn-set staged-world manifest'
  foreach ($item in @($stage.evidence)) {
    Add-Evidence $item.kind $item.path $item.summary
  }
  if ($stage.status -ne 'passed') {
    $errors.Add('Vehicle spawn-set staging did not pass.')
  }

  $startOutput = & $startServerScript -BridgeDir $bridgeDir -Port $Port -VerifyWaitSeconds 30
  $startOutput | Set-Content -LiteralPath $startPath -Encoding UTF8
  $start = $startOutput | ConvertFrom-Json
  $serverPid = [int]$start.pid
  Add-Evidence 'json' $startPath 'Bridge test server startup result'
  if ($start.verified -ne $true) {
    $errors.Add("Bridge server did not verify: $($start.verify_reason)")
  } else {
    Start-Sleep -Seconds 2
    foreach ($copy in @($stage.data.stagedCopies)) {
      $loadPath = Join-Path $caseRoot ('load-{0:D2}-rpc.json' -f [int]$copy.index)
      $position = $copy.position
      $loadCommand = "Omegga.Bridge.ForceConsoleExecutor consolemanager BR.World.LoadAdditive $($copy.worldName) $($position.x) $($position.y) $($position.z) $($position.yaw)"
      $loadOutput = & node $sendRpcScript --dir $bridgeDir --method console.exec --command-raw $loadCommand --wait-ms 20000 --include-logs 1
      $loadOutput | Set-Content -LiteralPath $loadPath -Encoding UTF8
      $loadRpc = $loadOutput | ConvertFrom-Json
      Add-Evidence 'json' $loadPath "LoadAdditive bridge RPC result for vehicle copy $($copy.index)"
      if ($loadRpc.complete.success -ne $true) {
        $errors.Add("LoadAdditive RPC did not report success for vehicle copy $($copy.index).")
      }
      Start-Sleep -Seconds 3
    }

    Start-Sleep -Seconds 10

    $snapshotOutput = & $snapshotServerScript -Root $Root -BrickadiaRoot $BrickadiaRoot -BridgeDir $bridgeDir -SaveName $saveName -OutJson $snapshotPath -ExportInventory -InventoryLabelPrefix 'car' -SpawnManifestJson $stageManifestPath -SpawnMatchMode 'X'
    if ($LASTEXITCODE -ne 0) {
      throw "snapshot-server-vehicles.ps1 failed with exit code $LASTEXITCODE"
    }
    $snapshotResult = $snapshotOutput | ConvertFrom-Json
    Add-Evidence 'json' $snapshotPath 'Server vehicle spawn-set snapshot result'
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
    Where-Object { $_.Name -eq 'BrickadiaServer-Win64-Shipping.exe' -and $_.CommandLine -like "*-port=`"$Port`*"} |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}

$stageData = $null
$sourceSnapshotData = $null
$stagedCopies = @()
if ($stage) {
  $stageData = $stage.data
  $sourceSnapshotData = $stage.data.sourceStaticSnapshot
  $stagedCopies = @($stage.data.stagedCopies)
}

$snapshotData = $null
if ($snapshotResult) {
  $snapshotData = $snapshotResult.data.snapshot
}
$inventoryData = $null
if ($snapshotResult) {
  $inventoryData = $snapshotResult.data.inventory
}

if ($snapshotResult -and $sourceSnapshotData) {
  $snapshot = $snapshotResult.data.snapshot
  $inventory = $snapshotResult.data.inventory
  $expectedVehicle = @($sourceSnapshotData.vehicles | Where-Object { $_.classification -eq 'dynamic-actor-vehicle-like' } | Select-Object -First 1)
  $expectedVehicleBrickCount = [int]$expectedVehicle.brickCount * $VehicleCount
  $expectedVehicleComponentCount = [int]$expectedVehicle.componentCount * $VehicleCount
  $expectedVehicleWireCount = [int]$expectedVehicle.wireCount * $VehicleCount
  if ($snapshotResult.status -ne 'passed') {
    $errors.Add('Server vehicle spawn-set snapshot did not pass.')
  }
  if (!$inventory -or [int]$inventory.vehicleCount -ne $VehicleCount) {
    $errors.Add("Expected inventory with $VehicleCount vehicles, got $($inventory.vehicleCount).")
  }
  if (!$inventory -or @($inventory.spawnMatches).Count -ne $VehicleCount) {
    $errors.Add("Expected inventory with $VehicleCount spawn matches, got $(@($inventory.spawnMatches).Count).")
  }
  if ([int]$snapshot.vehicleLikeGroupCount -ne $VehicleCount) {
    $errors.Add("Expected $VehicleCount vehicle-like groups, got $($snapshot.vehicleLikeGroupCount).")
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
} elseif (!$snapshotResult) {
  $errors.Add('Server vehicle spawn-set snapshot result was not produced.')
}

$result = [ordered]@{
  feature = 'server.vehicle-spawn-set.additive-l2'
  status = if ($errors.Count -eq 0) { 'passed' } else { 'failed' }
  validationLevel = 'L2 Headless Server'
  startedAt = $startedAt
  finishedAt = (Get-Date).ToUniversalTime().ToString('o')
  data = [ordered]@{
    sourceWorldBrdb = if ($stageData) { $stageData.sourceWorldBrdb } else { $null }
    brickadiaRoot = [System.IO.Path]::GetFullPath($BrickadiaRoot)
    port = $Port
    vehicleCount = $VehicleCount
    idStride = $IdStride
    saveName = $saveName
    stage = $stageData
    sourceStaticSnapshot = $sourceSnapshotData
    stagedCopies = $stagedCopies
    snapshot = $snapshotData
    inventory = $inventoryData
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
