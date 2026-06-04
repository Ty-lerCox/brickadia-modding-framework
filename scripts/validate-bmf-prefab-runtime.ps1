param(
  [string]$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
  [string]$BrickadiaRoot = '',
  [string]$RuntimeModsDir = 'C:\Users\tycox\AppData\Roaming\omegga\steam_installs\main\Brickadia\Binaries\Win64\ue4ss\main\Mods',
  [string]$InputBrz = '',
  [string]$OutJson = '',
  [int]$Port = 7820,
  [int]$LoadX = 60000,
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
  $OutJson = Join-Path $Root 'artifacts/local/bmf-prefab-runtime-canary.json'
}

$errors = New-Object System.Collections.Generic.List[string]
$evidence = New-Object System.Collections.Generic.List[object]
$startedAt = (Get-Date).ToUniversalTime().ToString('o')
$outPath = [System.IO.Path]::GetFullPath($OutJson)
$artifactRoot = Split-Path -Parent $outPath
$caseRoot = Join-Path $artifactRoot 'bmf-prefab-runtime'
New-Item -ItemType Directory -Force -Path $caseRoot | Out-Null

$stageScript = Join-Path $Root 'scripts/stage-brz-prefab.ps1'
$describeScript = Join-Path $Root 'scripts/describe-world-archive.ps1'
$startServerScript = Join-Path $BrickadiaRoot 'brickadia-ue4ss-re/scripts/start-bridge-test-server.ps1'
$sourceBmfDir = Join-Path $Root 'framework/ue4ss/Mods/BMF'
$runtimeBmfDir = Join-Path $RuntimeModsDir 'BMF'
$runtimePluginDir = Join-Path $runtimeBmfDir 'plugins/PrefabCanary'
$runtimeLogPath = Join-Path $runtimeBmfDir 'runtime/bmf.log'
$runtimeStatusPath = Join-Path $runtimeBmfDir 'runtime/status.json'
$worldsDir = Join-Path $BrickadiaRoot 'omegga-master/omegga-master/data/Saved/Worlds'

$worldName = 'BMF_CarBrzPrefabRuntime'
$saveName = 'BMF_AfterPrefabRuntime_{0}' -f (Get-Date -Format 'yyyyMMddHHmmss')
$marker = 'prefab-runtime-{0}' -f (Get-Date -Format 'yyyyMMddHHmmss')
$stageBrdbPath = Join-Path $caseRoot 'car-brz-prefab-runtime-world.brdb'
$stageJsonPath = Join-Path $caseRoot 'stage-brz-prefab.json'
$pluginStagePath = Join-Path $caseRoot 'prefab-canary-plugin-stage.json'
$bridgeDir = Join-Path $caseRoot "bridge-$Port"
$startPath = Join-Path $caseRoot 'server-start.json'
$bmfLogPath = Join-Path $caseRoot 'bmf.log'
$statusPath = Join-Path $caseRoot 'status.json'
$describePath = Join-Path $caseRoot 'saved-world-describe.json'
$parserPath = Join-Path $caseRoot 'saved-world-entities.json'
$savedWorldPath = Join-Path $worldsDir ($saveName + '.brdb')
$serverPid = $null
$savedSummary = $null

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

try {
  foreach ($path in @($InputBrz, $stageScript, $describeScript, $startServerScript, $sourceBmfDir)) {
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

  New-Item -ItemType Directory -Force -Path $runtimeBmfDir | Out-Null
  Copy-Item -Path (Join-Path $sourceBmfDir '*') -Destination $runtimeBmfDir -Recurse -Force
  New-Item -ItemType Directory -Force -Path $runtimePluginDir | Out-Null

  $pluginSource = @'
local SAVE_NAME = "__SAVE_NAME__"
local WORLD_NAME = "__WORLD_NAME__"
local MARKER = "__MARKER__"
local LOAD_X = __LOAD_X__
local LOAD_Y = __LOAD_Y__
local LOAD_Z = __LOAD_Z__
local LOAD_YAW = __LOAD_YAW__

return {
  onLoad = function(BMF)
    BMF.log("PrefabCanary onLoad marker=" .. MARKER)

    local missing = BMF.prefabs.loadBrz({
      source = "Car.brz",
    })
    BMF.log("PrefabCanary missingStage ok=" .. tostring(missing.ok) .. " code=" .. tostring(missing.code))

    BMF.timers.after(8000, function()
      BMF.log("PrefabCanary load begin marker=" .. MARKER)
      local load = BMF.prefabs.loadBrz({
        source = "Car.brz",
        name = WORLD_NAME,
        position = { x = LOAD_X, y = LOAD_Y, z = LOAD_Z },
        yaw = LOAD_YAW,
      })

      BMF.log("PrefabCanary load ok=" .. tostring(load.ok) .. " code=" .. tostring(load.code))
      if load.data and load.data.command then
        BMF.log("PrefabCanary load command=" .. tostring(load.data.command))
      end
      if not load.ok then
        return
      end

      BMF.timers.after(7000, function()
        BMF.log("PrefabCanary save begin name=" .. SAVE_NAME)
        local save = BMF.world.saveAs(SAVE_NAME)
        BMF.log("PrefabCanary save ok=" .. tostring(save.ok) .. " code=" .. tostring(save.code))
        if save.data and save.data.command then
          BMF.log("PrefabCanary save command=" .. tostring(save.data.command))
        end
      end)
    end)
  end,
}
'@

  $pluginSource = $pluginSource.Replace('__SAVE_NAME__', $saveName)
  $pluginSource = $pluginSource.Replace('__WORLD_NAME__', $worldName)
  $pluginSource = $pluginSource.Replace('__MARKER__', $marker)
  $pluginSource = $pluginSource.Replace('__LOAD_X__', [string]$LoadX)
  $pluginSource = $pluginSource.Replace('__LOAD_Y__', [string]$LoadY)
  $pluginSource = $pluginSource.Replace('__LOAD_Z__', [string]$LoadZ)
  $pluginSource = $pluginSource.Replace('__LOAD_YAW__', [string]$LoadYaw)

  $pluginPath = Join-Path $runtimePluginDir 'main.lua'
  Set-Content -LiteralPath $pluginPath -Value $pluginSource -Encoding UTF8
  [ordered]@{
    pluginDir = [System.IO.Path]::GetFullPath($runtimePluginDir)
    plugin = [System.IO.Path]::GetFullPath($pluginPath)
    marker = $marker
    stagedWorldName = $worldName
    saveName = $saveName
  } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $pluginStagePath -Encoding UTF8
  Add-Evidence 'json' $pluginStagePath 'Temporary BMF PrefabCanary plugin staging result'

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

  Start-Sleep -Seconds 27
} catch {
  $errors.Add($_.Exception.Message)
} finally {
  if ($serverPid) {
    Stop-Process -Id $serverPid -Force -ErrorAction SilentlyContinue
  }
  Get-CimInstance Win32_Process |
    Where-Object { $_.Name -eq 'BrickadiaServer-Win64-Shipping.exe' -and $_.CommandLine -like "*-port=`"$Port`"*"} |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
  if (Test-Path -LiteralPath $runtimePluginDir) {
    Remove-Item -LiteralPath $runtimePluginDir -Recurse -Force -ErrorAction SilentlyContinue
  }
}

if (Test-Path -LiteralPath $runtimeLogPath) {
  Copy-Item -LiteralPath $runtimeLogPath -Destination $bmfLogPath -Force
  Add-Evidence 'log' $bmfLogPath 'BMF runtime log with PrefabCanary evidence'
  $logText = Get-Content -Raw -LiteralPath $bmfLogPath
  foreach ($needle in @(
    "PrefabCanary onLoad marker=$marker",
    'PrefabCanary missingStage ok=false code=PREFAB_STAGING_REQUIRED',
    'PrefabCanary load ok=true code=OK',
    'PrefabCanary save ok=true code=OK'
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
    $describeOutput = & $describeScript -InputPath $savedWorldPath -OutJson $describePath -ParserOutJson $parserPath
    $describe = $describeOutput | ConvertFrom-Json
    Add-Evidence 'brdb' $savedWorldPath 'Saved world after BMF prefab runtime load'
    Add-Evidence 'json' $describePath 'Saved world archive summary'
    Add-Evidence 'json' $parserPath 'Saved world parser output'

    if ($describe.status -ne 'passed') {
      $errors.Add('Saved world describe did not pass.')
    }

    $entities = Read-JsonFile $parserPath
    $group = @($entities.dynamicActorGroups | Select-Object -First 1)
    $brickCount = 0
    $componentCount = 0
    $wireCount = 0
    foreach ($grid in @($entities.brickGrids)) {
      $brickCount += [int]$grid.brickCount
      $componentCount += [int]$grid.componentCount
      $wireCount += [int]$grid.wireCount
    }
    $bodyGrid = @($entities.brickGrids | Where-Object { [int]$_.gridId -eq 1 } | Select-Object -First 1)
    $gridCount = @($entities.brickGrids).Count

    if ([int]$describe.data.entityCount -ne 19) {
      $errors.Add("Saved world expected 19 entities, got $($describe.data.entityCount).")
    }
    if ([int]$describe.data.dynamicActorGroupCount -ne 1) {
      $errors.Add("Saved world expected 1 dynamic actor group, got $($describe.data.dynamicActorGroupCount).")
    }
    if (!$group -or [string]$group.status -ne 'resolved-by-joint-references') {
      $errors.Add('Saved world dynamic actor group was not resolved by joint references.')
    }
    if ($group -and [int]$group.relatedEntityCount -ne 19) {
      $errors.Add("Saved world expected 19 related entities, got $($group.relatedEntityCount).")
    }
    if ($group -and [int]$group.relatedGridCount -ne 16) {
      $errors.Add("Saved world expected 16 related grids, got $($group.relatedGridCount).")
    }
    if ($gridCount -ne 16) {
      $errors.Add("Saved world expected 16 brick grids, got $gridCount.")
    }
    if ($brickCount -ne 1528) {
      $errors.Add("Saved world expected 1528 bricks, got $brickCount.")
    }
    if ($componentCount -ne 123) {
      $errors.Add("Saved world expected 123 components, got $componentCount.")
    }
    if ($wireCount -ne 103) {
      $errors.Add("Saved world expected 103 wires, got $wireCount.")
    }
    if (!$bodyGrid -or [int]$bodyGrid.brickCount -ne 1254) {
      $errors.Add('Saved world did not retain the 1254-brick body grid as grid 1.')
    }

    $savedSummary = [ordered]@{
      savedWorldPath = [System.IO.Path]::GetFullPath($savedWorldPath)
      entityCount = [int]$describe.data.entityCount
      dynamicActorGroupCount = [int]$describe.data.dynamicActorGroupCount
      dynamicActorGroups = $entities.dynamicActorGroups
      gridCount = $gridCount
      brickCount = $brickCount
      componentCount = $componentCount
      wireCount = $wireCount
      bodyGridId = if ($bodyGrid) { [int]$bodyGrid.gridId } else { $null }
      bodyGridBrickCount = if ($bodyGrid) { [int]$bodyGrid.brickCount } else { 0 }
    }
  } catch {
    $errors.Add($_.Exception.Message)
  }
} else {
  $errors.Add("Saved world was not created: $savedWorldPath")
}

$result = [ordered]@{
  feature = 'bmf.prefabs.loadBrz.runtime'
  status = if ($errors.Count -eq 0) { 'passed' } else { 'failed' }
  validationLevel = 'L2 Headless Server'
  startedAt = $startedAt
  finishedAt = (Get-Date).ToUniversalTime().ToString('o')
  data = [ordered]@{
    inputBrz = [System.IO.Path]::GetFullPath($InputBrz)
    brickadiaRoot = [System.IO.Path]::GetFullPath($BrickadiaRoot)
    runtimeModsDir = [System.IO.Path]::GetFullPath($RuntimeModsDir)
    port = $Port
    marker = $marker
    stagedWorldName = $worldName
    saveName = $saveName
    loadLocation = [ordered]@{
      x = $LoadX
      y = $LoadY
      z = $LoadZ
      yaw = $LoadYaw
    }
    savedSummary = $savedSummary
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
