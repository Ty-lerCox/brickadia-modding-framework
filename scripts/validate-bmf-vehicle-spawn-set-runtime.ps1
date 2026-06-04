param(
  [string]$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
  [string]$BrickadiaRoot = '',
  [string]$RuntimeModsDir = 'C:\Users\tycox\AppData\Roaming\omegga\steam_installs\main\Brickadia\Binaries\Win64\ue4ss\main\Mods',
  [string]$SourceWorldBrdb = '',
  [string]$OutJson = '',
  [int]$Port = 7826,
  [int]$VehicleCount = 3,
  [int]$IdStride = 100000,
  [int]$StartX = 76000,
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
  $OutJson = Join-Path $Root 'artifacts/local/bmf-vehicle-spawn-set-runtime-canary.json'
}

$errors = New-Object System.Collections.Generic.List[string]
$evidence = New-Object System.Collections.Generic.List[object]
$startedAt = (Get-Date).ToUniversalTime().ToString('o')
$outPath = [System.IO.Path]::GetFullPath($OutJson)
$artifactRoot = Split-Path -Parent $outPath
$caseRoot = Join-Path $artifactRoot 'bmf-vehicle-spawn-set-runtime'
New-Item -ItemType Directory -Force -Path $caseRoot | Out-Null

$stageScript = Join-Path $Root 'scripts/stage-vehicle-spawn-set.ps1'
$snapshotScript = Join-Path $Root 'scripts/summarize-vehicle-graphs.ps1'
$startServerScript = Join-Path $BrickadiaRoot 'brickadia-ue4ss-re/scripts/start-bridge-test-server.ps1'
$sourceBmfDir = Join-Path $Root 'framework/ue4ss/Mods/BMF'
$runtimeBmfDir = Join-Path $RuntimeModsDir 'BMF'
$runtimePluginDir = Join-Path $runtimeBmfDir 'plugins/VehicleSpawnSetCanary'
$runtimeLogPath = Join-Path $runtimeBmfDir 'runtime/bmf.log'
$runtimeStatusPath = Join-Path $runtimeBmfDir 'runtime/status.json'
$worldsDir = Join-Path $BrickadiaRoot 'omegga-master/omegga-master/data/Saved/Worlds'

$worldNamePrefix = 'BMF_BMFVehicleSpawnSet'
$saveName = 'BMF_AfterVehicleSpawnSetRuntime_{0}' -f (Get-Date -Format 'yyyyMMddHHmmss')
$marker = 'vehicle-spawn-set-runtime-{0}' -f (Get-Date -Format 'yyyyMMddHHmmss')
$stageManifestPath = Join-Path $caseRoot 'stage-vehicle-spawn-set.json'
$pluginStagePath = Join-Path $caseRoot 'vehicle-spawn-set-plugin-stage.json'
$bridgeDir = Join-Path $caseRoot "bridge-$Port"
$startPath = Join-Path $caseRoot 'server-start.json'
$bmfLogPath = Join-Path $caseRoot 'bmf.log'
$statusPath = Join-Path $caseRoot 'status.json'
$snapshotPath = Join-Path $caseRoot 'vehicle-snapshot.json'
$parserPath = Join-Path $caseRoot 'vehicle-snapshot.entities.json'
$savedWorldPath = Join-Path $worldsDir ($saveName + '.brdb')
$serverPid = $null
$stage = $null
$snapshot = $null

function Add-Evidence([string]$Kind, [string]$Path, [string]$Summary) {
  if ($Path -and (Test-Path -LiteralPath $Path)) {
    $script:evidence.Add([ordered]@{
      kind = $Kind
      path = [System.IO.Path]::GetFullPath($Path)
      summary = $Summary
    })
  }
}

function ConvertTo-LuaString([string]$Value) {
  return '"' + (($Value -replace '\\', '\\') -replace '"', '\"') + '"'
}

try {
  foreach ($path in @($stageScript, $snapshotScript, $startServerScript, $sourceBmfDir)) {
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

  New-Item -ItemType Directory -Force -Path $runtimeBmfDir | Out-Null
  Copy-Item -Path (Join-Path $sourceBmfDir '*') -Destination $runtimeBmfDir -Recurse -Force
  New-Item -ItemType Directory -Force -Path $runtimePluginDir | Out-Null

  $copyLines = New-Object System.Collections.Generic.List[string]
  foreach ($copy in @($stage.data.stagedCopies)) {
    $position = $copy.position
    $copyLines.Add(('  {{ name = {0}, position = {{ x = {1}, y = {2}, z = {3} }}, yaw = {4} }}' -f `
      (ConvertTo-LuaString $copy.worldName),
      [string]$position.x,
      [string]$position.y,
      [string]$position.z,
      [string]$position.yaw))
  }
  $copiesLua = $copyLines.ToArray() -join ",`n"

  $pluginSource = @'
local SAVE_NAME = "__SAVE_NAME__"
local MARKER = "__MARKER__"
local EXPECTED_COUNT = __EXPECTED_COUNT__
local COPIES = {
__COPIES__
}

return {
  onLoad = function(BMF)
    BMF.log("VehicleSpawnSetCanary onLoad marker=" .. MARKER)

    local invalid = BMF.vehicles.planSpawnSet({ count = 0, worldNamePrefix = "Invalid" })
    BMF.log("VehicleSpawnSetCanary invalid ok=" .. tostring(invalid.ok) .. " code=" .. tostring(invalid.code))

    local planned = BMF.vehicles.planSpawnSet({ copies = COPIES })
    local planned_count = 0
    if planned.data and planned.data.loads then
      planned_count = #planned.data.loads
    end
    BMF.log("VehicleSpawnSetCanary plan ok=" .. tostring(planned.ok) .. " code=" .. tostring(planned.code) .. " count=" .. tostring(planned_count))
    if not planned.ok or planned_count ~= EXPECTED_COUNT then
      return
    end

    BMF.timers.after(8000, function()
      BMF.log("VehicleSpawnSetCanary spawn begin marker=" .. MARKER)
      local spawned = BMF.vehicles.spawnSet({ copies = COPIES })
      local spawn_count = 0
      if spawned.data and spawned.data.vehicleCount then
        spawn_count = spawned.data.vehicleCount
      end
      BMF.log("VehicleSpawnSetCanary spawn ok=" .. tostring(spawned.ok) .. " code=" .. tostring(spawned.code) .. " count=" .. tostring(spawn_count))
      if not spawned.ok then
        return
      end

      BMF.timers.after(14000, function()
        BMF.log("VehicleSpawnSetCanary save begin name=" .. SAVE_NAME)
        local save = BMF.world.saveAs(SAVE_NAME)
        BMF.log("VehicleSpawnSetCanary save ok=" .. tostring(save.ok) .. " code=" .. tostring(save.code))
        if save.data and save.data.command then
          BMF.log("VehicleSpawnSetCanary save command=" .. tostring(save.data.command))
        end
      end)
    end)
  end,
}
'@

  $pluginSource = $pluginSource.Replace('__SAVE_NAME__', $saveName)
  $pluginSource = $pluginSource.Replace('__MARKER__', $marker)
  $pluginSource = $pluginSource.Replace('__EXPECTED_COUNT__', [string]$VehicleCount)
  $pluginSource = $pluginSource.Replace('__COPIES__', $copiesLua)

  $pluginPath = Join-Path $runtimePluginDir 'main.lua'
  Set-Content -LiteralPath $pluginPath -Value $pluginSource -Encoding UTF8
  [ordered]@{
    pluginDir = [System.IO.Path]::GetFullPath($runtimePluginDir)
    plugin = [System.IO.Path]::GetFullPath($pluginPath)
    marker = $marker
    saveName = $saveName
    stagedCopies = $stage.data.stagedCopies
  } | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $pluginStagePath -Encoding UTF8
  Add-Evidence 'json' $pluginStagePath 'Temporary BMF VehicleSpawnSetCanary plugin staging result'

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
  }

  Start-Sleep -Seconds 42
} catch {
  $errors.Add($_.Exception.Message)
} finally {
  if ($serverPid) {
    Stop-Process -Id $serverPid -Force -ErrorAction SilentlyContinue
  }
  Get-CimInstance Win32_Process |
    Where-Object { $_.Name -eq 'BrickadiaServer-Win64-Shipping.exe' -and $_.CommandLine -like "*-port=`"$Port`*"} |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
  if (Test-Path -LiteralPath $runtimePluginDir) {
    Remove-Item -LiteralPath $runtimePluginDir -Recurse -Force -ErrorAction SilentlyContinue
  }
}

if (Test-Path -LiteralPath $runtimeLogPath) {
  Copy-Item -LiteralPath $runtimeLogPath -Destination $bmfLogPath -Force
  Add-Evidence 'log' $bmfLogPath 'BMF runtime log with VehicleSpawnSetCanary evidence'
  $logText = Get-Content -Raw -LiteralPath $bmfLogPath
  foreach ($needle in @(
    "VehicleSpawnSetCanary onLoad marker=$marker",
    'VehicleSpawnSetCanary invalid ok=false code=INVALID_VEHICLE_COUNT',
    "VehicleSpawnSetCanary plan ok=true code=OK count=$VehicleCount",
    "VehicleSpawnSetCanary spawn ok=true code=OK count=$VehicleCount",
    'VehicleSpawnSetCanary save ok=true code=OK'
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
  Add-Evidence 'json' $statusPath 'BMF runtime status'
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
    Add-Evidence 'brdb' $savedWorldPath 'Saved world after BMF vehicle spawn-set runtime load'
    Add-Evidence 'json' $snapshotPath 'Vehicle-like dynamic actor snapshot'
    Add-Evidence 'json' $parserPath 'Raw parser output for vehicle snapshot'

    if ($snapshot.status -ne 'passed') {
      $errors.Add('Vehicle snapshot did not pass.')
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
    foreach ($vehicle in @($snapshot.data.vehicles | Where-Object { $_.classification -eq 'dynamic-actor-vehicle-like' })) {
      if ([int]$vehicle.relatedEntityCount -ne [int]$expectedVehicle.relatedEntityCount) {
        $errors.Add("Vehicle $($vehicle.vehicleId) expected $($expectedVehicle.relatedEntityCount) related entities, got $($vehicle.relatedEntityCount).")
      }
      if ([int]$vehicle.relatedGridCount -ne [int]$expectedVehicle.relatedGridCount) {
        $errors.Add("Vehicle $($vehicle.vehicleId) expected $($expectedVehicle.relatedGridCount) related grids, got $($vehicle.relatedGridCount).")
      }
      if (!$vehicle.bodyGrid -or [int]$vehicle.bodyGrid.brickCount -ne [int]$expectedVehicle.bodyGrid.brickCount) {
        $errors.Add("Vehicle $($vehicle.vehicleId) did not identify a $($expectedVehicle.bodyGrid.brickCount)-brick body grid.")
      }
    }
  } catch {
    $errors.Add($_.Exception.Message)
  }
} else {
  $errors.Add("Saved world was not created: $savedWorldPath")
}

$result = [ordered]@{
  feature = 'bmf.vehicles.spawnSet.runtime'
  status = if ($errors.Count -eq 0) { 'passed' } else { 'failed' }
  validationLevel = 'L2 Headless Server'
  startedAt = $startedAt
  finishedAt = (Get-Date).ToUniversalTime().ToString('o')
  data = [ordered]@{
    sourceWorldBrdb = if ($stage) { $stage.data.sourceWorldBrdb } else { $null }
    brickadiaRoot = [System.IO.Path]::GetFullPath($BrickadiaRoot)
    runtimeModsDir = [System.IO.Path]::GetFullPath($RuntimeModsDir)
    port = $Port
    marker = $marker
    vehicleCount = $VehicleCount
    idStride = $IdStride
    worldNamePrefix = $worldNamePrefix
    saveName = $saveName
    stage = if ($stage) { $stage.data } else { $null }
    snapshot = if ($snapshot) { $snapshot.data } else { $null }
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
