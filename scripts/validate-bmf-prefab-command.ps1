param(
  [string]$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
  [string]$BrickadiaRoot = '',
  [string]$RuntimeModsDir = 'C:\Users\tycox\AppData\Roaming\omegga\steam_installs\main\Brickadia\Binaries\Win64\ue4ss\main\Mods',
  [string]$InputBrz = '',
  [string]$OutJson = '',
  [int]$Port = 7853,
  [int]$LoadX = 64000,
  [int]$LoadY = 0,
  [int]$LoadZ = 1000,
  [int]$LoadYaw = 0,
  [int]$WaitAfterSaveSeconds = 8
)

$ErrorActionPreference = 'Stop'

if (!$BrickadiaRoot) {
  $BrickadiaRoot = (Resolve-Path (Join-Path $Root '..\Brickadia')).Path
}
if (!$InputBrz) {
  $InputBrz = Join-Path $BrickadiaRoot 'Car.brz'
}
if (!$OutJson) {
  $OutJson = Join-Path $Root 'artifacts/local/bmf-prefab-command-canary.json'
}

$errors = New-Object System.Collections.Generic.List[string]
$evidence = New-Object System.Collections.Generic.List[object]
$commandResults = New-Object System.Collections.Generic.List[object]
$startedAt = (Get-Date).ToUniversalTime().ToString('o')
$outPath = [System.IO.Path]::GetFullPath($OutJson)
$artifactRoot = Split-Path -Parent $outPath
$caseRoot = Join-Path $artifactRoot 'bmf-prefab-command'
New-Item -ItemType Directory -Force -Path $caseRoot | Out-Null

$stageScript = Join-Path $Root 'scripts/stage-brz-prefab.ps1'
$describeScript = Join-Path $Root 'scripts/describe-world-archive.ps1'
$snapshotScript = Join-Path $Root 'scripts/summarize-vehicle-graphs.ps1'
$inventoryScript = Join-Path $Root 'scripts/export-vehicle-inventory.ps1'
$startServerScript = Join-Path $BrickadiaRoot 'brickadia-ue4ss-re/scripts/start-bridge-test-server.ps1'
$sendRpcScript = Join-Path $BrickadiaRoot 'brickadia-ue4ss-re/scripts/send-bridge-rpc.js'
$sourceBmfDir = Join-Path $Root 'framework/ue4ss/Mods/BMF'
$runtimeBmfDir = Join-Path $RuntimeModsDir 'BMF'
$runtimeLogPath = Join-Path $runtimeBmfDir 'runtime/bmf.log'
$runtimeStatusPath = Join-Path $runtimeBmfDir 'runtime/status.json'
$worldsDir = Join-Path $BrickadiaRoot 'omegga-master/omegga-master/data/Saved/Worlds'

$worldName = 'BMF_CommandCarBrzPrefab'
$saveName = 'BMF_AfterPrefabCommand_{0}' -f (Get-Date -Format 'yyyyMMddHHmmss')
$stageBrdbPath = Join-Path $caseRoot 'car-brz-prefab-command-world.brdb'
$stageJsonPath = Join-Path $caseRoot 'stage-brz-prefab.json'
$bridgeDir = Join-Path $caseRoot "bridge-$Port"
$startPath = Join-Path $caseRoot 'server-start.json'
$bmfLogPath = Join-Path $caseRoot 'bmf.log'
$statusPath = Join-Path $caseRoot 'status.json'
$describePath = Join-Path $caseRoot 'saved-world-describe.json'
$describeEntitiesPath = Join-Path $caseRoot 'saved-world-entities.json'
$snapshotPath = Join-Path $caseRoot 'vehicle-snapshot.json'
$snapshotEntitiesPath = Join-Path $caseRoot 'vehicle-snapshot.entities.json'
$inventoryPath = Join-Path $caseRoot 'vehicle-inventory.json'
$inventoryMarkdownPath = Join-Path $caseRoot 'vehicle-inventory.md'
$inventoryCsvPath = Join-Path $caseRoot 'vehicle-inventory.csv'
$inventoryTextPath = Join-Path $caseRoot 'vehicle-inventory.txt'
$savedWorldPath = Join-Path $worldsDir ($saveName + '.brdb')
$serverPid = $null
$stage = $null
$archiveDescribe = $null
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

function Read-JsonFile([string]$Path) {
  $text = Get-Content -Raw -LiteralPath $Path
  if ($text.Length -gt 0 -and [int][char]$text[0] -eq 0xfeff) {
    $text = $text.Substring(1)
  }
  return $text | ConvertFrom-Json
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
  foreach ($path in @($InputBrz, $stageScript, $describeScript, $snapshotScript, $inventoryScript, $startServerScript, $sendRpcScript, $sourceBmfDir)) {
    if (!(Test-Path -LiteralPath $path)) {
      throw "Required path does not exist: $path"
    }
  }

  $sourceName = [System.IO.Path]::GetFileName($InputBrz)
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
  foreach ($item in @($stage.evidence)) {
    Add-Evidence $item.kind $item.path $item.summary
  }
  if ($stage.status -ne 'passed') {
    $errors.Add('Static BRZ staging did not pass.')
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

    $loadCommand = 'bmf.prefabs.loadbrz source={0} name={1} x={2} y={3} z={4} yaw={5}' -f `
      $sourceName,
      $worldName,
      $LoadX,
      $LoadY,
      $LoadZ,
      $LoadYaw
    Invoke-BmfConsoleCommand $loadCommand 'bmf-prefabs-loadbrz' @(
      'BMF bmf.prefabs.loadbrz OK',
      "source=$sourceName",
      "world=$worldName",
      "staged_world=$worldName",
      'api=BMF.prefabs.loadBrz',
      'next=bmf.world.saveas'
    )

    Start-Sleep -Seconds 8

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
  Add-Evidence 'log' $bmfLogPath 'BMF runtime log with command-driven prefab load evidence'
  $logText = Get-Content -Raw -LiteralPath $bmfLogPath
  foreach ($needle in @(
    'registered console command bmf.prefabs.loadbrz',
    'BMF bmf.prefabs.loadbrz OK',
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
  Add-Evidence 'json' $statusPath 'BMF runtime status after command-driven prefab load'
} else {
  $errors.Add("BMF runtime status was not written: $runtimeStatusPath")
}

if (Test-Path -LiteralPath $savedWorldPath) {
  try {
    $describeOutput = & $describeScript -InputPath $savedWorldPath -OutJson $describePath -ParserOutJson $describeEntitiesPath
    if ($LASTEXITCODE -ne 0) {
      throw "describe-world-archive.ps1 failed with exit code $LASTEXITCODE"
    }
    $archiveDescribe = $describeOutput | ConvertFrom-Json
    Add-Evidence 'brdb' $savedWorldPath 'Saved world after command-driven BMF prefab load'
    Add-Evidence 'json' $describePath 'Saved world archive description'
    Add-Evidence 'json' $describeEntitiesPath 'Saved world raw parser output'
    if ($archiveDescribe.status -ne 'passed') {
      $errors.Add('Saved world archive description did not pass.')
    }

    $snapshotOutput = & $snapshotScript -InputPath $savedWorldPath -OutJson $snapshotPath -ParserOutJson $snapshotEntitiesPath
    if ($LASTEXITCODE -ne 0) {
      throw "summarize-vehicle-graphs.ps1 failed with exit code $LASTEXITCODE"
    }
    $snapshot = $snapshotOutput | ConvertFrom-Json
    Add-Evidence 'json' $snapshotPath 'Vehicle-like dynamic actor snapshot after prefab command'
    Add-Evidence 'json' $snapshotEntitiesPath 'Raw parser output for prefab command vehicle snapshot'

    $inventoryOutput = & $inventoryScript -Root $Root -BrickadiaRoot $BrickadiaRoot -InputSnapshotJson $snapshotPath -OutJson $inventoryPath -OutMarkdown $inventoryMarkdownPath -OutCsv $inventoryCsvPath -OutText $inventoryTextPath -LabelPrefix 'car'
    if ($LASTEXITCODE -ne 0) {
      throw "export-vehicle-inventory.ps1 failed with exit code $LASTEXITCODE"
    }
    $inventory = $inventoryOutput | ConvertFrom-Json
    Add-Evidence 'json' $inventoryPath 'Vehicle inventory JSON after prefab command'
    Add-Evidence 'markdown' $inventoryMarkdownPath 'Vehicle inventory Markdown after prefab command'
    Add-Evidence 'csv' $inventoryCsvPath 'Vehicle inventory CSV after prefab command'
    Add-Evidence 'text' $inventoryTextPath 'Vehicle inventory text report after prefab command'

    if ([int]$archiveDescribe.data.entityCount -ne 19) {
      $errors.Add("Saved world expected 19 entities, got $($archiveDescribe.data.entityCount).")
    }
    if ([int]$archiveDescribe.data.dynamicActorGroupCount -ne 1) {
      $errors.Add("Saved world expected 1 dynamic actor group, got $($archiveDescribe.data.dynamicActorGroupCount).")
    }
    if ($snapshot.status -ne 'passed') {
      $errors.Add('Vehicle snapshot did not pass.')
    }
    if ([int]$snapshot.data.vehicleLikeGroupCount -ne 1) {
      $errors.Add("Expected 1 vehicle-like group, got $($snapshot.data.vehicleLikeGroupCount).")
    }
    if ([int]$snapshot.data.vehicleBrickCount -ne 1528) {
      $errors.Add("Expected 1528 vehicle bricks, got $($snapshot.data.vehicleBrickCount).")
    }
    if ([int]$snapshot.data.vehicleComponentCount -ne 123) {
      $errors.Add("Expected 123 vehicle components, got $($snapshot.data.vehicleComponentCount).")
    }
    if ([int]$snapshot.data.vehicleWireCount -ne 103) {
      $errors.Add("Expected 103 vehicle wires, got $($snapshot.data.vehicleWireCount).")
    }
    if ($inventory.status -ne 'passed') {
      $errors.Add('Vehicle inventory export did not pass.')
    }
    if ([int]$inventory.data.vehicleCount -ne 1) {
      $errors.Add("Expected inventory with 1 vehicle, got $($inventory.data.vehicleCount).")
    }
    if (!(Test-Path -LiteralPath $inventoryTextPath)) {
      $errors.Add("Vehicle inventory text report was not produced: $inventoryTextPath")
    } else {
      $inventoryText = Get-Content -Raw -LiteralPath $inventoryTextPath
      foreach ($needle in @('Vehicle inventory: 1 vehicle-like groups', 'car-001', 'bricks=1528')) {
        if ($inventoryText -notmatch [regex]::Escape($needle)) {
          $errors.Add("Vehicle inventory text report missing expected text: $needle")
        }
      }
    }
  } catch {
    $errors.Add($_.Exception.Message)
  }
} else {
  $errors.Add("Saved world was not created: $savedWorldPath")
}

$resultStatus = 'failed'
if ($errors.Count -eq 0) {
  $resultStatus = 'passed'
}

$result = [ordered]@{
  feature = 'bmf.prefabs.loadBrz.command'
  status = $resultStatus
  validationLevel = 'L2 Headless Server'
  startedAt = $startedAt
  finishedAt = (Get-Date).ToUniversalTime().ToString('o')
  data = [ordered]@{
    inputBrz = [System.IO.Path]::GetFullPath($InputBrz)
    brickadiaRoot = [System.IO.Path]::GetFullPath($BrickadiaRoot)
    runtimeModsDir = [System.IO.Path]::GetFullPath($RuntimeModsDir)
    port = $Port
    waitAfterSaveSeconds = $WaitAfterSaveSeconds
    stagedWorldName = $worldName
    saveName = $saveName
    loadLocation = [ordered]@{
      x = $LoadX
      y = $LoadY
      z = $LoadZ
      yaw = $LoadYaw
    }
    stage = if ($stage) { $stage.data } else { $null }
    commands = $commandResults.ToArray()
    archive = if ($archiveDescribe) { $archiveDescribe.data } else { $null }
    snapshot = if ($snapshot) { $snapshot.data } else { $null }
    inventory = if ($inventory) { $inventory.data } else { $null }
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
