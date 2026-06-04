param(
  [string]$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
  [string]$BrickadiaRoot = '',
  [string]$FixtureRoot = '',
  [string]$OutJson = '',
  [int]$Port = 7814,
  [int]$LoadX = 48000,
  [int]$LoadY = 0,
  [int]$LoadZ = 1000,
  [int]$LoadYaw = 0
)

$ErrorActionPreference = 'Stop'

if (!$BrickadiaRoot) {
  $BrickadiaRoot = (Resolve-Path (Join-Path $Root '..\Brickadia')).Path
}
if (!$FixtureRoot) {
  $FixtureRoot = Join-Path $Root 'artifacts/overnight/20260603-215931/fixtures'
}
if (!$OutJson) {
  $OutJson = Join-Path $Root 'artifacts/local/dynamic-actor-slice-additive-canary.json'
}

$errors = New-Object System.Collections.Generic.List[string]
$evidence = New-Object System.Collections.Generic.List[object]
$startedAt = (Get-Date).ToUniversalTime().ToString('o')
$outPath = [System.IO.Path]::GetFullPath($OutJson)
$artifactRoot = Split-Path -Parent $outPath
$caseRoot = Join-Path $artifactRoot 'dynamic-actor-slice-additive'
New-Item -ItemType Directory -Force -Path $caseRoot | Out-Null

$validateSliceScript = Join-Path $Root 'scripts/validate-dynamic-actor-slices.ps1'
$describeScript = Join-Path $Root 'scripts/describe-world-archive.ps1'
$startServerScript = Join-Path $BrickadiaRoot 'brickadia-ue4ss-re/scripts/start-bridge-test-server.ps1'
$sendRpcScript = Join-Path $BrickadiaRoot 'brickadia-ue4ss-re/scripts/send-bridge-rpc.js'
$worldsDir = Join-Path $BrickadiaRoot 'omegga-master/omegga-master/data/Saved/Worlds'

$staticCanaryPath = Join-Path $caseRoot 'static-slice-canary.json'
$bridgeDir = Join-Path $caseRoot "bridge-$Port"
$startPath = Join-Path $caseRoot 'server-start.json'
$loadRpcPath = Join-Path $caseRoot 'load-additive-rpc.json'
$saveRpcPath = Join-Path $caseRoot 'saveas-rpc.json'
$describePath = Join-Path $caseRoot 'saved-world-describe.json'
$parserPath = Join-Path $caseRoot 'saved-world-entities.json'
$worldName = 'BMF_SlicedCarEntity20_ClosureV2'
$saveName = 'BMF_AfterSlicedCarClosureV2_{0}' -f (Get-Date -Format 'yyyyMMddHHmmss')
$serverPid = $null
$savedWorldPath = Join-Path $worldsDir ($saveName + '.brdb')

function Add-Evidence([string]$Kind, [string]$Path, [string]$Summary) {
  $script:evidence.Add([ordered]@{
    kind = $Kind
    path = [System.IO.Path]::GetFullPath($Path)
    summary = $Summary
  })
}

function Read-JsonFile([string]$Path) {
  $text = Get-Content -Raw -LiteralPath $Path
  if ($text.Length -gt 0 -and [int][char]$text[0] -eq 0xfeff) {
    $text = $text.Substring(1)
  }
  return $text | ConvertFrom-Json
}

try {
  $staticOutput = & $validateSliceScript -FixtureRoot $FixtureRoot -OutJson $staticCanaryPath
  if ($LASTEXITCODE -ne 0) {
    throw "validate-dynamic-actor-slices.ps1 failed with exit code $LASTEXITCODE"
  }
  $staticCanary = $staticOutput | ConvertFrom-Json
  if ($staticCanary.status -ne 'passed') {
    $errors.Add('Static dynamic actor slice canary did not pass.')
  }

  $sliceCase = @($staticCanary.data.cases | Select-Object -First 1)
  if (!$sliceCase -or !(Test-Path -LiteralPath $sliceCase.slicePath)) {
    throw 'Static slice canary did not produce a slice path.'
  }

  New-Item -ItemType Directory -Force -Path $worldsDir | Out-Null
  $stagedWorldPath = Join-Path $worldsDir ($worldName + '.brdb')
  Copy-Item -LiteralPath $sliceCase.slicePath -Destination $stagedWorldPath -Force

  Add-Evidence 'json' $staticCanaryPath 'Static slice canary'
  Add-Evidence 'brdb' $stagedWorldPath 'Staged additive-load BRDB slice'

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

    $saveCommand = "Omegga.Bridge.ForceConsoleExecutor consolemanager BR.World.SaveAs $saveName"
    $saveOutput = & node $sendRpcScript --dir $bridgeDir --method console.exec --command-raw $saveCommand --wait-ms 20000 --include-logs 1
    $saveOutput | Set-Content -LiteralPath $saveRpcPath -Encoding UTF8
    $saveRpc = $saveOutput | ConvertFrom-Json
    Add-Evidence 'json' $saveRpcPath 'SaveAs bridge RPC result'
    if ($saveRpc.complete.success -ne $true) {
      $errors.Add('SaveAs RPC did not report success.')
    }

    Start-Sleep -Seconds 8
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

$savedSummary = $null
if (Test-Path -LiteralPath $savedWorldPath) {
  try {
    $describeOutput = & $describeScript -InputPath $savedWorldPath -OutJson $describePath -ParserOutJson $parserPath
    $describe = $describeOutput | ConvertFrom-Json
    Add-Evidence 'brdb' $savedWorldPath 'Saved world after additive load'
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
    $bodyGrid = @($entities.brickGrids | Where-Object { [int]$_.gridId -eq 2 } | Select-Object -First 1)

    if ([int]$describe.data.entityCount -ne 20) {
      $errors.Add("Saved world expected 20 entities, got $($describe.data.entityCount).")
    }
    if ([int]$describe.data.dynamicActorGroupCount -ne 1) {
      $errors.Add("Saved world expected 1 dynamic actor group, got $($describe.data.dynamicActorGroupCount).")
    }
    if (!$group -or [string]$group.status -ne 'resolved-by-joint-references') {
      $errors.Add("Saved world dynamic actor group was not resolved by joint references.")
    }
    if ($group -and [int]$group.relatedEntityCount -ne 20) {
      $errors.Add("Saved world expected 20 related entities, got $($group.relatedEntityCount).")
    }
    if ($group -and [int]$group.relatedGridCount -ne 16) {
      $errors.Add("Saved world expected 16 related grids, got $($group.relatedGridCount).")
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
      $errors.Add('Saved world did not retain the 1254-brick body grid as grid 2.')
    }

    $savedSummary = [ordered]@{
      savedWorldPath = [System.IO.Path]::GetFullPath($savedWorldPath)
      entityCount = [int]$describe.data.entityCount
      dynamicActorGroupCount = [int]$describe.data.dynamicActorGroupCount
      dynamicActorGroups = $entities.dynamicActorGroups
      gridCount = @($entities.brickGrids).Count
      brickCount = $brickCount
      componentCount = $componentCount
      wireCount = $wireCount
      bodyGridBrickCount = if ($bodyGrid) { [int]$bodyGrid.brickCount } else { 0 }
    }
  } catch {
    $errors.Add($_.Exception.Message)
  }
} else {
  $errors.Add("Saved world was not created: $savedWorldPath")
}

$result = [ordered]@{
  feature = 'archives.dynamic-actor-brdb-slice-additive'
  status = if ($errors.Count -eq 0) { 'passed' } else { 'failed' }
  validationLevel = 'L2 Headless Server'
  startedAt = $startedAt
  finishedAt = (Get-Date).ToUniversalTime().ToString('o')
  data = [ordered]@{
    fixtureRoot = [System.IO.Path]::GetFullPath($FixtureRoot)
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
    savedSummary = $savedSummary
  }
  evidence = $evidence
  errors = @($errors)
}

$json = $result | ConvertTo-Json -Depth 12
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $outPath) | Out-Null
Set-Content -LiteralPath $outPath -Value $json -Encoding UTF8
Write-Output $json

if ($errors.Count -ne 0) {
  exit 1
}
