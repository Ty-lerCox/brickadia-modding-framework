param(
  [string]$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
  [string]$BrickadiaRoot = '',
  [string]$RuntimeModsDir = 'C:\Users\tycox\AppData\Roaming\omegga\steam_installs\main\Brickadia\Binaries\Win64\ue4ss\main\Mods',
  [string]$SourceWorldBrdb = '',
  [string]$OutJson = '',
  [int]$Port = 7830,
  [int]$VehicleCount = 3,
  [int]$IdStride = 100000,
  [int]$StartX = 90000,
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
  $OutJson = Join-Path $Root 'artifacts/local/bmf-vehicle-snapshot-command-canary.json'
}

$errors = New-Object System.Collections.Generic.List[string]
$evidence = New-Object System.Collections.Generic.List[object]
$commandResults = New-Object System.Collections.Generic.List[object]
$startedAt = (Get-Date).ToUniversalTime().ToString('o')
$outPath = [System.IO.Path]::GetFullPath($OutJson)
$artifactRoot = Split-Path -Parent $outPath
$caseRoot = Join-Path $artifactRoot 'bmf-vehicle-snapshot-command'
New-Item -ItemType Directory -Force -Path $caseRoot | Out-Null

$stageScript = Join-Path $Root 'scripts/stage-vehicle-spawn-set.ps1'
$snapshotBmfScript = Join-Path $Root 'scripts/snapshot-bmf-server-vehicles.ps1'
$startServerScript = Join-Path $BrickadiaRoot 'brickadia-ue4ss-re/scripts/start-bridge-test-server.ps1'
$sendRpcScript = Join-Path $BrickadiaRoot 'brickadia-ue4ss-re/scripts/send-bridge-rpc.js'
$sourceBmfDir = Join-Path $Root 'framework/ue4ss/Mods/BMF'
$runtimeBmfDir = Join-Path $RuntimeModsDir 'BMF'
$runtimeLogPath = Join-Path $runtimeBmfDir 'runtime/bmf.log'
$runtimeStatusPath = Join-Path $runtimeBmfDir 'runtime/status.json'
$worldNamePrefix = 'BMF_CommandVehicleSnapshotSet'
$saveName = 'BMF_VehicleSnapshotCommand_{0}' -f (Get-Date -Format 'yyyyMMddHHmmss')
$stageManifestPath = Join-Path $caseRoot 'stage-vehicle-spawn-set.json'
$bridgeDir = Join-Path $caseRoot "bridge-$Port"
$startPath = Join-Path $caseRoot 'server-start.json'
$bmfLogPath = Join-Path $caseRoot 'bmf.log'
$statusPath = Join-Path $caseRoot 'status.json'
$snapshotCommandPath = Join-Path $caseRoot 'bmf-vehicle-snapshot.json'
$serverPid = $null
$stage = $null
$snapshotCommand = $null

function Add-Evidence([string]$Kind, [string]$Path, [string]$Summary) {
  if ($Path -and (Test-Path -LiteralPath $Path)) {
    $script:evidence.Add([ordered]@{
      kind = $Kind
      path = [System.IO.Path]::GetFullPath($Path)
      summary = $Summary
    })
  }
}

function Invoke-BmfConsoleCommand([string]$Command, [string]$Slug, [string[]]$ExpectedLines) {
  $rpcPath = Join-Path $caseRoot "$Slug-rpc.json"
  $responseArtifactPath = Join-Path $caseRoot "$Slug-response.txt"
  $bridgeCommand = "Omegga.Bridge.BMF $Command"
  $output = & node $sendRpcScript --dir $bridgeDir --method console.exec --command-raw $bridgeCommand --wait-ms 30000 --include-logs 1
  $output | Set-Content -LiteralPath $rpcPath -Encoding UTF8
  Add-Evidence 'json' $rpcPath "Bridge RPC output for $Command"

  $rpc = $output | ConvertFrom-Json
  $lines = @($rpc.chunks | ForEach-Object { $_.line })
  $requestId = $null
  foreach ($line in $lines) {
    if ($line -match '^queued_bmf_command id=(.+)$') {
      $requestId = $Matches[1].Trim()
      break
    }
  }

  $responseLines = @()
  $responsePath = ''
  if ($requestId) {
    $responsePath = Join-Path $runtimeBmfDir "runtime/commands/$requestId.response.txt"
    $deadline = (Get-Date).AddSeconds(20)
    while ((Get-Date) -lt $deadline -and !(Test-Path -LiteralPath $responsePath)) {
      Start-Sleep -Milliseconds 250
    }
    if (Test-Path -LiteralPath $responsePath) {
      Copy-Item -LiteralPath $responsePath -Destination $responseArtifactPath -Force
      Add-Evidence 'text' $responseArtifactPath "BMF response output for $Command"
      $responseLines = @([System.IO.File]::ReadAllLines($responseArtifactPath))
    } else {
      $script:errors.Add("Timed out waiting for BMF response file for command: $Command")
    }
  } else {
    $script:errors.Add("Bridge response did not include queued request id for command: $Command")
  }

  $responseFullPath = ''
  if ($responsePath) {
    $responseFullPath = [System.IO.Path]::GetFullPath($responsePath)
  }
  $script:commandResults.Add([ordered]@{
    command = $Command
    bridgeCommand = $bridgeCommand
    rpcPath = [System.IO.Path]::GetFullPath($rpcPath)
    responsePath = $responseFullPath
    success = [bool]$rpc.complete.success
    accepted = [bool]$rpc.result.accepted
    rpcLineCount = $lines.Count
    responseLineCount = $responseLines.Count
    lines = @($responseLines)
  })

  if ($rpc.complete.success -ne $true) {
    $script:errors.Add("Command did not complete successfully: $Command")
  }
  if ($rpc.result.accepted -ne $true) {
    $script:errors.Add("Command was not accepted by bridge: $Command")
  }

  $joined = ($responseLines -join "`n")
  if ($joined -notmatch '^ok=true') {
    $script:errors.Add("BMF response did not report ok=true for command: $Command")
  }
  foreach ($expected in $ExpectedLines) {
    if ($joined -notmatch [regex]::Escape($expected)) {
      $script:errors.Add("Command '$Command' output missing expected text: $expected")
    }
  }
}

try {
  foreach ($path in @($stageScript, $snapshotBmfScript, $startServerScript, $sendRpcScript, $sourceBmfDir)) {
    if (!(Test-Path -LiteralPath $path)) {
      throw "Required path does not exist: $path"
    }
  }

  $stageArgs = @{
    Root = $Root
    BrickadiaRoot = $BrickadiaRoot
    OutJson = $stageManifestPath
    ArtifactDir = (Join-Path $caseRoot 'stage')
    WorldNamePrefix = $worldNamePrefix
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

  if (Test-Path -LiteralPath $runtimeBmfDir) {
    Remove-Item -LiteralPath $runtimeBmfDir -Recurse -Force
  }
  New-Item -ItemType Directory -Force -Path $runtimeBmfDir | Out-Null
  Copy-Item -Path (Join-Path $sourceBmfDir '*') -Destination $runtimeBmfDir -Recurse -Force

  if (Test-Path -LiteralPath $runtimeLogPath) {
    Remove-Item -LiteralPath $runtimeLogPath -Force
  }
  if (Test-Path -LiteralPath $runtimeStatusPath) {
    Remove-Item -LiteralPath $runtimeStatusPath -Force
  }

  $startOutput = & $startServerScript -BridgeDir $bridgeDir -Port $Port -VerifyWaitSeconds 30
  $startOutput | Set-Content -LiteralPath $startPath -Encoding UTF8
  $start = $startOutput | ConvertFrom-Json
  $serverPid = [int]$start.pid
  Add-Evidence 'json' $startPath 'Bridge test server startup result'
  if ($start.verified -ne $true) {
    $errors.Add("Bridge server did not verify: $($start.verify_reason)")
  } else {
    Start-Sleep -Seconds 4

    $spawnCommand = 'bmf.vehicles.spawnset prefix={0} count={1} startX={2} stepX={3} y={4} z={5} yaw={6}' -f `
      $worldNamePrefix,
      $VehicleCount,
      $StartX,
      $StepX,
      $LoadY,
      $LoadZ,
      $LoadYaw
    Invoke-BmfConsoleCommand $spawnCommand 'bmf-vehicles-spawnset' @(
      'BMF bmf.vehicles.spawnset OK',
      "requested_count=$VehicleCount",
      "loaded_count=$VehicleCount",
      "$($worldNamePrefix)_01"
    )

    Start-Sleep -Seconds 16

    $snapshotOutput = & $snapshotBmfScript `
      -Root $Root `
      -BrickadiaRoot $BrickadiaRoot `
      -RuntimeModsDir $RuntimeModsDir `
      -BridgeDir $bridgeDir `
      -SaveName $saveName `
      -OutJson $snapshotCommandPath `
      -InventoryLabelPrefix 'car' `
      -SpawnManifestJson $stageManifestPath `
      -SpawnMatchMode 'X' `
      -WaitAfterSaveSeconds 8
    if ($LASTEXITCODE -ne 0) {
      throw "snapshot-bmf-server-vehicles.ps1 failed with exit code $LASTEXITCODE"
    }
    $snapshotCommand = $snapshotOutput | ConvertFrom-Json
    Add-Evidence 'json' $snapshotCommandPath 'BMF vehicle snapshot command result'
    foreach ($item in @($snapshotCommand.evidence)) {
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

if (Test-Path -LiteralPath $runtimeLogPath) {
  Copy-Item -LiteralPath $runtimeLogPath -Destination $bmfLogPath -Force
  Add-Evidence 'log' $bmfLogPath 'BMF runtime log with vehicle snapshot command evidence'
  $logText = Get-Content -Raw -LiteralPath $bmfLogPath
  foreach ($needle in @(
    'registered console command bmf.vehicles.snapshot',
    'BMF bmf.vehicles.spawnset OK',
    'BMF bmf.vehicles.snapshot OK'
  )) {
    if ($logText -notmatch [regex]::Escape($needle)) {
      $errors.Add("BMF log missing expected line: $needle")
    }
  }
} else {
  $errors.Add("BMF runtime log was not written: $runtimeLogPath")
}

if (Test-Path -LiteralPath $runtimeStatusPath) {
  Copy-Item -LiteralPath $runtimeStatusPath -Destination $statusPath -Force
  Add-Evidence 'json' $statusPath 'BMF runtime status after vehicle snapshot command canary'
} else {
  $errors.Add("BMF runtime status was not written: $runtimeStatusPath")
}

$stageData = $null
$sourceSnapshotData = $null
$snapshotData = $null
$inventoryData = $null
if ($stage) {
  $stageData = $stage.data
  $sourceSnapshotData = $stage.data.sourceStaticSnapshot
}
if ($snapshotCommand) {
  $snapshotData = $snapshotCommand.data.snapshot
  $inventoryData = $snapshotCommand.data.inventory
}

$sourceWorldBrdb = $null
$snapshotCommandData = $null
if ($stageData) {
  $sourceWorldBrdb = $stageData.sourceWorldBrdb
}
if ($snapshotCommand) {
  $snapshotCommandData = $snapshotCommand.data
}

if ($snapshotCommand -and $sourceSnapshotData) {
  if ($snapshotCommand.status -ne 'passed') {
    $errors.Add('BMF vehicle snapshot command result did not pass.')
  }
  $expectedVehicle = @($sourceSnapshotData.vehicles | Where-Object { $_.classification -eq 'dynamic-actor-vehicle-like' } | Select-Object -First 1)
  $expectedVehicleBrickCount = [int]$expectedVehicle.brickCount * $VehicleCount
  $expectedVehicleComponentCount = [int]$expectedVehicle.componentCount * $VehicleCount
  $expectedVehicleWireCount = [int]$expectedVehicle.wireCount * $VehicleCount

  if ([int]$snapshotData.vehicleLikeGroupCount -ne $VehicleCount) {
    $errors.Add("Expected $VehicleCount vehicle-like groups, got $($snapshotData.vehicleLikeGroupCount).")
  }
  if ([int]$snapshotData.vehicleBrickCount -ne $expectedVehicleBrickCount) {
    $errors.Add("Expected $expectedVehicleBrickCount vehicle bricks, got $($snapshotData.vehicleBrickCount).")
  }
  if ([int]$snapshotData.vehicleComponentCount -ne $expectedVehicleComponentCount) {
    $errors.Add("Expected $expectedVehicleComponentCount vehicle components, got $($snapshotData.vehicleComponentCount).")
  }
  if ([int]$snapshotData.vehicleWireCount -ne $expectedVehicleWireCount) {
    $errors.Add("Expected $expectedVehicleWireCount vehicle wires, got $($snapshotData.vehicleWireCount).")
  }
  if ([int]$inventoryData.vehicleCount -ne $VehicleCount) {
    $errors.Add("Expected inventory with $VehicleCount vehicles, got $($inventoryData.vehicleCount).")
  }
  if (@($inventoryData.spawnMatches).Count -ne $VehicleCount) {
    $errors.Add("Expected inventory with $VehicleCount spawn matches, got $(@($inventoryData.spawnMatches).Count).")
  }
  if (!$inventoryData.textPath -or !(Test-Path -LiteralPath $inventoryData.textPath)) {
    $errors.Add("Vehicle inventory text report was not produced: $($inventoryData.textPath)")
  } else {
    $inventoryText = Get-Content -Raw -LiteralPath $inventoryData.textPath
    foreach ($needle in @(
      "Vehicle inventory: $VehicleCount vehicle-like groups",
      'car-001',
      'spawn=BMF_CommandVehicleSnapshotSet_01'
    )) {
      if ($inventoryText -notmatch [regex]::Escape($needle)) {
        $errors.Add("Vehicle inventory text report missing expected text: $needle")
      }
    }
  }
} elseif (!$snapshotCommand) {
  $errors.Add('BMF vehicle snapshot command result was not produced.')
}

$resultStatus = 'failed'
if ($errors.Count -eq 0) {
  $resultStatus = 'passed'
}

$result = [ordered]@{
  feature = 'bmf.vehicles.snapshot.command-canary'
  status = $resultStatus
  validationLevel = 'L2 Headless Server'
  startedAt = $startedAt
  finishedAt = (Get-Date).ToUniversalTime().ToString('o')
  data = [ordered]@{
    sourceWorldBrdb = $sourceWorldBrdb
    brickadiaRoot = [System.IO.Path]::GetFullPath($BrickadiaRoot)
    runtimeModsDir = [System.IO.Path]::GetFullPath($RuntimeModsDir)
    port = $Port
    vehicleCount = $VehicleCount
    idStride = $IdStride
    worldNamePrefix = $worldNamePrefix
    saveName = $saveName
    stage = $stageData
    commands = $commandResults.ToArray()
    snapshotCommand = $snapshotCommandData
    snapshot = $snapshotData
    inventory = $inventoryData
  }
  evidence = $evidence.ToArray()
  errors = $errors.ToArray()
}

$json = $result | ConvertTo-Json -Depth 18
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $outPath) | Out-Null
Set-Content -LiteralPath $outPath -Value $json -Encoding UTF8
Write-Output $json

if ($errors.Count -ne 0) {
  exit 1
}
