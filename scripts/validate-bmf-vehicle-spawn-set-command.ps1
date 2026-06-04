param(
  [string]$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
  [string]$BrickadiaRoot = '',
  [string]$RuntimeModsDir = 'C:\Users\tycox\AppData\Roaming\omegga\steam_installs\main\Brickadia\Binaries\Win64\ue4ss\main\Mods',
  [string]$SourceWorldBrdb = '',
  [string]$OutJson = '',
  [int]$Port = 7828,
  [int]$VehicleCount = 3,
  [int]$IdStride = 100000,
  [int]$StartX = 84000,
  [int]$StepX = 2000,
  [int]$LoadY = 0,
  [int]$LoadZ = 1000,
  [int]$LoadYaw = 0,
  [int]$WaitAfterSaveSeconds = 8
)

$ErrorActionPreference = 'Stop'

if (!$BrickadiaRoot) {
  $BrickadiaRoot = (Resolve-Path (Join-Path $Root '..\Brickadia')).Path
}
if (!$OutJson) {
  $OutJson = Join-Path $Root 'artifacts/local/bmf-vehicle-spawn-set-command-canary.json'
}

$errors = New-Object System.Collections.Generic.List[string]
$evidence = New-Object System.Collections.Generic.List[object]
$commandResults = New-Object System.Collections.Generic.List[object]
$startedAt = (Get-Date).ToUniversalTime().ToString('o')
$outPath = [System.IO.Path]::GetFullPath($OutJson)
$artifactRoot = Split-Path -Parent $outPath
$caseRoot = Join-Path $artifactRoot 'bmf-vehicle-spawn-set-command'
New-Item -ItemType Directory -Force -Path $caseRoot | Out-Null

$stageScript = Join-Path $Root 'scripts/stage-vehicle-spawn-set.ps1'
$snapshotScript = Join-Path $Root 'scripts/summarize-vehicle-graphs.ps1'
$inventoryScript = Join-Path $Root 'scripts/export-vehicle-inventory.ps1'
$startServerScript = Join-Path $BrickadiaRoot 'brickadia-ue4ss-re/scripts/start-bridge-test-server.ps1'
$sendRpcScript = Join-Path $BrickadiaRoot 'brickadia-ue4ss-re/scripts/send-bridge-rpc.js'
$sourceBmfDir = Join-Path $Root 'framework/ue4ss/Mods/BMF'
$runtimeBmfDir = Join-Path $RuntimeModsDir 'BMF'
$runtimeLogPath = Join-Path $runtimeBmfDir 'runtime/bmf.log'
$runtimeStatusPath = Join-Path $runtimeBmfDir 'runtime/status.json'
$worldsDir = Join-Path $BrickadiaRoot 'omegga-master/omegga-master/data/Saved/Worlds'

$worldNamePrefix = 'BMF_CommandVehicleSpawnSet'
$saveName = 'BMF_AfterVehicleSpawnSetCommand_{0}' -f (Get-Date -Format 'yyyyMMddHHmmss')
$stageManifestPath = Join-Path $caseRoot 'stage-vehicle-spawn-set.json'
$bridgeDir = Join-Path $caseRoot "bridge-$Port"
$startPath = Join-Path $caseRoot 'server-start.json'
$bmfLogPath = Join-Path $caseRoot 'bmf.log'
$statusPath = Join-Path $caseRoot 'status.json'
$snapshotPath = Join-Path $caseRoot 'vehicle-snapshot.json'
$parserPath = Join-Path $caseRoot 'vehicle-snapshot.entities.json'
$inventoryPath = Join-Path $caseRoot 'vehicle-inventory.json'
$inventoryMarkdownPath = Join-Path $caseRoot 'vehicle-inventory.md'
$inventoryCsvPath = Join-Path $caseRoot 'vehicle-inventory.csv'
$inventoryTextPath = Join-Path $caseRoot 'vehicle-inventory.txt'
$savedWorldPath = Join-Path $worldsDir ($saveName + '.brdb')
$serverPid = $null
$stage = $null
$snapshot = $null
$inventory = $null

function Add-Evidence([string]$Kind, [string]$Path, [string]$Summary) {
  if ($Path -and (Test-Path -LiteralPath $Path)) {
    $script:evidence.Add([ordered]@{
      kind = $Kind
      path = [System.IO.Path]::GetFullPath($Path)
      summary = $Summary
    })
  }
}

function Wait-ForSavedWorldArchive([string]$Path, [int]$InitialWaitSeconds, [int]$TimeoutSeconds) {
  if ($InitialWaitSeconds -gt 0) {
    Start-Sleep -Seconds $InitialWaitSeconds
  }

  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  $lastLength = -1L
  $stableSamples = 0
  while ((Get-Date) -lt $deadline) {
    if (Test-Path -LiteralPath $Path) {
      $item = Get-Item -LiteralPath $Path
      if ($item.Length -gt 0) {
        if ($item.Length -eq $lastLength) {
          $stableSamples += 1
        } else {
          $lastLength = $item.Length
          $stableSamples = 0
        }
        if ($stableSamples -ge 2) {
          return $item
        }
      }
    }
    Start-Sleep -Milliseconds 500
  }

  if (!(Test-Path -LiteralPath $Path)) {
    throw "Saved world was not created: $Path"
  }
  $finalItem = Get-Item -LiteralPath $Path
  throw "Saved world was not ready before timeout: $Path length=$($finalItem.Length)"
}

function Read-JsonFile([string]$Path) {
  $text = Get-Content -Raw -LiteralPath $Path
  if ($text.Length -gt 0 -and [int][char]$text[0] -eq 0xfeff) {
    $text = $text.Substring(1)
  }
  return $text | ConvertFrom-Json
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
  foreach ($path in @($stageScript, $snapshotScript, $inventoryScript, $startServerScript, $sendRpcScript, $sourceBmfDir)) {
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
  if (Test-Path -LiteralPath $savedWorldPath) {
    Remove-Item -LiteralPath $savedWorldPath -Force
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

    $saveCommand = 'bmf.world.saveas name={0}' -f $saveName
    Invoke-BmfConsoleCommand $saveCommand 'bmf-world-saveas' @(
      'BMF bmf.world.saveas OK',
      "world=$saveName"
    )

    $null = Wait-ForSavedWorldArchive -Path $savedWorldPath -InitialWaitSeconds $WaitAfterSaveSeconds -TimeoutSeconds 45
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
  Add-Evidence 'log' $bmfLogPath 'BMF runtime log with command-driven vehicle spawn-set evidence'
  $logText = Get-Content -Raw -LiteralPath $bmfLogPath
  foreach ($needle in @(
    'registered console command bmf.vehicles.spawnset',
    'registered console command bmf.world.saveas',
    'BMF bmf.vehicles.spawnset OK',
    'BMF bmf.world.saveas OK'
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
  Add-Evidence 'json' $statusPath 'BMF runtime status after command-driven vehicle spawn-set canary'
  try {
    $null = Read-JsonFile $statusPath
  } catch {
    $errors.Add("Could not parse BMF status: $($_.Exception.Message)")
  }
} else {
  $errors.Add("BMF runtime status was not written: $runtimeStatusPath")
}

if (Test-Path -LiteralPath $savedWorldPath) {
  try {
    $snapshotOutput = & $snapshotScript -InputPath $savedWorldPath -OutJson $snapshotPath -ParserOutJson $parserPath
    if ($LASTEXITCODE -ne 0) {
      throw "summarize-vehicle-graphs.ps1 failed with exit code $LASTEXITCODE"
    }
    $snapshot = $snapshotOutput | ConvertFrom-Json
    Add-Evidence 'brdb' $savedWorldPath 'Saved world after command-driven BMF vehicle spawn-set load'
    Add-Evidence 'json' $snapshotPath 'Vehicle-like dynamic actor snapshot'
    Add-Evidence 'json' $parserPath 'Raw parser output for vehicle snapshot'

    $inventoryOutput = & $inventoryScript -Root $Root -BrickadiaRoot $BrickadiaRoot -InputSnapshotJson $snapshotPath -OutJson $inventoryPath -OutMarkdown $inventoryMarkdownPath -OutCsv $inventoryCsvPath -OutText $inventoryTextPath -LabelPrefix 'car' -SpawnManifestJson $stageManifestPath -SpawnMatchMode 'X'
    if ($LASTEXITCODE -ne 0) {
      throw "export-vehicle-inventory.ps1 failed with exit code $LASTEXITCODE"
    }
    $inventory = $inventoryOutput | ConvertFrom-Json
    Add-Evidence 'json' $inventoryPath 'Vehicle inventory JSON with staged-copy matches'
    Add-Evidence 'markdown' $inventoryMarkdownPath 'Vehicle inventory Markdown with staged-copy matches'
    Add-Evidence 'csv' $inventoryCsvPath 'Vehicle inventory CSV with staged-copy matches'
    Add-Evidence 'text' $inventoryTextPath 'Vehicle inventory console-style text report with staged-copy matches'

    if ($snapshot.status -ne 'passed') {
      $errors.Add('Vehicle snapshot did not pass.')
    }
    if ($inventory.status -ne 'passed') {
      $errors.Add('Vehicle inventory export did not pass.')
    }

    $expectedVehicle = @($stage.data.sourceStaticSnapshot.vehicles | Where-Object { $_.classification -eq 'dynamic-actor-vehicle-like' } | Select-Object -First 1)
    $expectedVehicleBrickCount = [int]$expectedVehicle.brickCount * $VehicleCount
    $expectedVehicleComponentCount = [int]$expectedVehicle.componentCount * $VehicleCount
    $expectedVehicleWireCount = [int]$expectedVehicle.wireCount * $VehicleCount

    if ([int]$snapshot.data.vehicleLikeGroupCount -ne $VehicleCount) {
      $errors.Add("Expected $VehicleCount vehicle-like groups, got $($snapshot.data.vehicleLikeGroupCount).")
    }
    if ([int]$snapshot.data.vehicleBrickCount -ne $expectedVehicleBrickCount) {
      $errors.Add("Expected $expectedVehicleBrickCount vehicle bricks, got $($snapshot.data.vehicleBrickCount).")
    }
    if ([int]$snapshot.data.vehicleComponentCount -ne $expectedVehicleComponentCount) {
      $errors.Add("Expected $expectedVehicleComponentCount vehicle components, got $($snapshot.data.vehicleComponentCount).")
    }
    if ([int]$snapshot.data.vehicleWireCount -ne $expectedVehicleWireCount) {
      $errors.Add("Expected $expectedVehicleWireCount vehicle wires, got $($snapshot.data.vehicleWireCount).")
    }

    if ([int]$inventory.data.vehicleCount -ne $VehicleCount) {
      $errors.Add("Expected inventory with $VehicleCount vehicles, got $($inventory.data.vehicleCount).")
    }
    if (@($inventory.data.spawnMatches).Count -ne $VehicleCount) {
      $errors.Add("Expected inventory with $VehicleCount spawn matches, got $(@($inventory.data.spawnMatches).Count).")
    }
    if (!(Test-Path -LiteralPath $inventoryTextPath)) {
      $errors.Add("Vehicle inventory text report was not produced: $inventoryTextPath")
    } else {
      $inventoryText = Get-Content -Raw -LiteralPath $inventoryTextPath
      foreach ($needle in @(
        "Vehicle inventory: $VehicleCount vehicle-like groups",
        'car-001',
        'spawn=BMF_CommandVehicleSpawnSet_01'
      )) {
        if ($inventoryText -notmatch [regex]::Escape($needle)) {
          $errors.Add("Vehicle inventory text report missing expected text: $needle")
        }
      }
    }

    foreach ($vehicle in @($snapshot.data.vehicles | Where-Object { $_.classification -eq 'dynamic-actor-vehicle-like' })) {
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
  } catch {
    $errors.Add($_.Exception.Message)
  }
}

$resultStatus = 'failed'
if ($errors.Count -eq 0) {
  $resultStatus = 'passed'
}

$stageData = $null
$sourceSnapshotData = $null
$snapshotData = $null
$inventoryData = $null
if ($stage) {
  $stageData = $stage.data
  $sourceSnapshotData = $stage.data.sourceStaticSnapshot
}
if ($snapshot) {
  $snapshotData = $snapshot.data
}
if ($inventory) {
  $inventoryData = $inventory.data
}

$result = [ordered]@{
  feature = 'bmf.vehicles.spawnSet.command'
  status = $resultStatus
  validationLevel = 'L2 Headless Server'
  startedAt = $startedAt
  finishedAt = (Get-Date).ToUniversalTime().ToString('o')
  data = [ordered]@{
    sourceWorldBrdb = if ($stageData) { $stageData.sourceWorldBrdb } else { $null }
    brickadiaRoot = [System.IO.Path]::GetFullPath($BrickadiaRoot)
    runtimeModsDir = [System.IO.Path]::GetFullPath($RuntimeModsDir)
    port = $Port
    vehicleCount = $VehicleCount
    idStride = $IdStride
    waitAfterSaveSeconds = $WaitAfterSaveSeconds
    worldNamePrefix = $worldNamePrefix
    saveName = $saveName
    stage = $stageData
    sourceStaticSnapshot = $sourceSnapshotData
    commands = $commandResults.ToArray()
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
