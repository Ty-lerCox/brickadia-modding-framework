param(
  [string]$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
  [string]$BrickadiaRoot = '',
  [string]$InputBrz = '',
  [string]$OutJson = '',
  [int]$Port = 7821,
  [int]$LoadX = 62000,
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
  $OutJson = Join-Path $Root 'artifacts/local/server-vehicle-snapshot-canary.json'
}

$errors = New-Object System.Collections.Generic.List[string]
$evidence = New-Object System.Collections.Generic.List[object]
$startedAt = (Get-Date).ToUniversalTime().ToString('o')
$outPath = [System.IO.Path]::GetFullPath($OutJson)
$artifactRoot = Split-Path -Parent $outPath
$caseRoot = Join-Path $artifactRoot 'server-vehicle-snapshot'
New-Item -ItemType Directory -Force -Path $caseRoot | Out-Null

$stageScript = Join-Path $Root 'scripts/stage-brz-prefab.ps1'
$snapshotServerScript = Join-Path $Root 'scripts/snapshot-server-vehicles.ps1'
$startServerScript = Join-Path $BrickadiaRoot 'brickadia-ue4ss-re/scripts/start-bridge-test-server.ps1'
$sendRpcScript = Join-Path $BrickadiaRoot 'brickadia-ue4ss-re/scripts/send-bridge-rpc.js'

$worldName = 'BMF_CarServerVehicleSnapshot'
$saveName = 'BMF_ServerVehicleSnapshot_{0}' -f (Get-Date -Format 'yyyyMMddHHmmss')
$stageBrdbPath = Join-Path $caseRoot 'car-server-vehicle-snapshot-world.brdb'
$stageJsonPath = Join-Path $caseRoot 'stage-brz-prefab.json'
$bridgeDir = Join-Path $caseRoot "bridge-$Port"
$startPath = Join-Path $caseRoot 'server-start.json'
$loadRpcPath = Join-Path $caseRoot 'load-additive-rpc.json'
$snapshotPath = Join-Path $caseRoot 'server-vehicle-snapshot.json'
$serverPid = $null
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
  foreach ($path in @($InputBrz, $stageScript, $snapshotServerScript, $startServerScript, $sendRpcScript)) {
    if (!(Test-Path -LiteralPath $path)) {
      throw "Required path does not exist: $path"
    }
  }

  $stageOutput = & $stageScript `
    -Root $Root `
    -BrickadiaRoot $BrickadiaRoot `
    -InputBrz $InputBrz `
    -OutputBrdb $stageBrdbPath `
    -OutJson $stageJsonPath `
    -Environment 'Plate' `
    -BundleType 'World' `
    -StageToServerWorlds `
    -WorldName $worldName `
    -Force
  if ($LASTEXITCODE -ne 0) {
    throw "stage-brz-prefab.ps1 failed with exit code $LASTEXITCODE"
  }
  $stage = $stageOutput | ConvertFrom-Json
  Add-Evidence 'json' $stageJsonPath 'Static BRZ-to-BRDB staging result'
  Add-Evidence 'brdb' $stageBrdbPath 'World BRDB produced from source BRZ'
  if ($stage.status -ne 'passed') {
    $errors.Add('Static BRZ staging did not pass.')
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

    $loadCommand = "Omegga.Bridge.ForceConsoleExecutor consolemanager BR.World.LoadAdditive $worldName $LoadX $LoadY $LoadZ $LoadYaw"
    $loadOutput = & node $sendRpcScript --dir $bridgeDir --method console.exec --command-raw $loadCommand --wait-ms 20000 --include-logs 1
    $loadOutput | Set-Content -LiteralPath $loadRpcPath -Encoding UTF8
    $loadRpc = $loadOutput | ConvertFrom-Json
    Add-Evidence 'json' $loadRpcPath 'LoadAdditive bridge RPC result'
    if ($loadRpc.complete.success -ne $true) {
      $errors.Add('LoadAdditive RPC did not report success.')
    }

    Start-Sleep -Seconds 8

    $snapshotOutput = & $snapshotServerScript -Root $Root -BrickadiaRoot $BrickadiaRoot -BridgeDir $bridgeDir -SaveName $saveName -OutJson $snapshotPath -ExportInventory -InventoryLabelPrefix 'car'
    if ($LASTEXITCODE -ne 0) {
      throw "snapshot-server-vehicles.ps1 failed with exit code $LASTEXITCODE"
    }
    $snapshotResult = $snapshotOutput | ConvertFrom-Json
    Add-Evidence 'json' $snapshotPath 'Server vehicle snapshot result'
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
  $inventory = $snapshotResult.data.inventory
  if ($snapshotResult.status -ne 'passed') {
    $errors.Add('Server vehicle snapshot did not pass.')
  }
  if (!$inventory -or [int]$inventory.vehicleCount -ne 1) {
    $errors.Add("Expected inventory with 1 vehicle, got $($inventory.vehicleCount).")
  }
  if ([int]$snapshot.vehicleLikeGroupCount -ne 1) {
    $errors.Add("Expected 1 vehicle-like group, got $($snapshot.vehicleLikeGroupCount).")
  }
  if ([int]$snapshot.vehicleBrickCount -ne 1528) {
    $errors.Add("Expected 1528 vehicle bricks, got $($snapshot.vehicleBrickCount).")
  }
  $vehicle = @($snapshot.vehicles | Select-Object -First 1)
  if (!$vehicle) {
    $errors.Add('Vehicle snapshot did not contain a vehicle record.')
  } else {
    if ([int]$vehicle.relatedEntityCount -ne 19) {
      $errors.Add("Expected 19 related entities, got $($vehicle.relatedEntityCount).")
    }
    if ([int]$vehicle.relatedGridCount -ne 16) {
      $errors.Add("Expected 16 related grids, got $($vehicle.relatedGridCount).")
    }
    if ([int]$vehicle.brickCount -ne 1528) {
      $errors.Add("Expected vehicle brick count 1528, got $($vehicle.brickCount).")
    }
    if ([int]$vehicle.componentCount -ne 123) {
      $errors.Add("Expected vehicle component count 123, got $($vehicle.componentCount).")
    }
    if ([int]$vehicle.wireCount -ne 103) {
      $errors.Add("Expected vehicle wire count 103, got $($vehicle.wireCount).")
    }
    if (!$vehicle.bodyGrid -or [int]$vehicle.bodyGrid.brickCount -ne 1254) {
      $errors.Add('Vehicle snapshot did not identify a 1254-brick body grid.')
    }
  }
} else {
  $errors.Add('Server vehicle snapshot result was not produced.')
}

$result = [ordered]@{
  feature = 'server.vehicle-snapshot.additive-l2'
  status = if ($errors.Count -eq 0) { 'passed' } else { 'failed' }
  validationLevel = 'L2 Headless Server'
  startedAt = $startedAt
  finishedAt = (Get-Date).ToUniversalTime().ToString('o')
  data = [ordered]@{
    inputBrz = [System.IO.Path]::GetFullPath($InputBrz)
    brickadiaRoot = [System.IO.Path]::GetFullPath($BrickadiaRoot)
    port = $Port
    stagedWorldName = $worldName
    saveName = $saveName
    loadLocation = [ordered]@{
      x = $LoadX
      y = $LoadY
      z = $LoadZ
      yaw = $LoadYaw
    }
    snapshot = if ($snapshotResult) { $snapshotResult.data.snapshot } else { $null }
    inventory = if ($snapshotResult) { $snapshotResult.data.inventory } else { $null }
  }
  evidence = $evidence
  errors = @($errors)
}

$json = $result | ConvertTo-Json -Depth 16
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $outPath) | Out-Null
Set-Content -LiteralPath $outPath -Value $json -Encoding UTF8
Write-Output $json

if ($errors.Count -ne 0) {
  exit 1
}
