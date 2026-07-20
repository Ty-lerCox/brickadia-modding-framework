param(
  [string]$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
  [string]$BrickadiaRoot = '',
  [string]$RuntimeModsDir = 'C:\Users\tycox\AppData\Roaming\omegga\steam_installs\main\Brickadia\Binaries\Win64\ue4ss\main\Mods',
  [string]$OutJson = '',
  [int]$Port = 7851
)

$ErrorActionPreference = 'Stop'

if (!$BrickadiaRoot) {
  $BrickadiaRoot = (Resolve-Path (Join-Path $Root '..\Brickadia')).Path
}
if (!$OutJson) {
  $OutJson = Join-Path $Root 'artifacts/local/bmf-brick-asset-policy-canary.json'
}

$errors = New-Object System.Collections.Generic.List[string]
$evidence = New-Object System.Collections.Generic.List[object]
$commandResults = New-Object System.Collections.Generic.List[object]
$startedAt = (Get-Date).ToUniversalTime().ToString('o')
$outPath = [System.IO.Path]::GetFullPath($OutJson)
$artifactRoot = Split-Path -Parent $outPath
$caseRoot = Join-Path $artifactRoot 'bmf-brick-asset-policy'
New-Item -ItemType Directory -Force -Path $caseRoot | Out-Null

$startServerScript = Join-Path $BrickadiaRoot 'brickadia-ue4ss-re/scripts/start-bridge-test-server.ps1'
$sendRpcScript = Join-Path $BrickadiaRoot 'brickadia-ue4ss-re/scripts/send-bridge-rpc.js'
$sourceBmfDir = Join-Path $Root 'framework/ue4ss/Mods/BMF'
$sourcePluginDir = Join-Path $Root 'deprecated/plugins/BrickAssetPlacementGuard'
$runtimeBmfDir = Join-Path $RuntimeModsDir 'BMF'
$runtimePluginDir = Join-Path $runtimeBmfDir 'plugins/BrickAssetPlacementGuard'
$runtimeLogPath = Join-Path $runtimeBmfDir 'runtime/bmf.log'
$runtimePluginLogPath = Join-Path $runtimeBmfDir 'runtime/logs/plugins/BrickAssetPlacementGuard.log'
$runtimeStatusPath = Join-Path $runtimeBmfDir 'runtime/status.json'
$nativeControlPath = Join-Path $Root 'artifacts/local/placement-asset-guard-control.txt'
$nativeStatusPath = Join-Path $Root 'artifacts/local/placement-asset-guard-status.txt'
$nativeEventPath = Join-Path $Root 'artifacts/local/placement-asset-guard-events.tsv'
$bridgeDir = Join-Path $caseRoot "bridge-$Port"
$startPath = Join-Path $caseRoot 'server-start.json'
$pluginStagePath = Join-Path $caseRoot 'brick-asset-plugin-stage.json'
$bmfLogPath = Join-Path $caseRoot 'bmf.log'
$pluginLogPath = Join-Path $caseRoot 'BrickAssetPlacementGuard.log'
$statusPath = Join-Path $caseRoot 'status.json'
$serverPid = $null

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

function Invoke-BmfConsoleCommand(
  [string]$Command,
  [string]$Slug,
  [string[]]$ExpectedLines,
  [bool]$ExpectedOk = $true
) {
  $rpcPath = Join-Path $caseRoot "$Slug-rpc.json"
  $bridgeCommand = "Omegga.Bridge.BMF $Command"
  $responseArtifactPath = Join-Path $caseRoot "$Slug-response.txt"
  $output = & node $sendRpcScript --dir $bridgeDir --method console.exec --command-raw $bridgeCommand --wait-ms 25000 --include-logs 1
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
    $deadline = (Get-Date).AddSeconds(15)
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

  $script:commandResults.Add([ordered]@{
    command = $Command
    bridgeCommand = $bridgeCommand
    rpcPath = [System.IO.Path]::GetFullPath($rpcPath)
    responsePath = if ($responsePath) { [System.IO.Path]::GetFullPath($responsePath) } else { '' }
    success = [bool]$rpc.complete.success
    accepted = [bool]$rpc.result.accepted
    expectedOk = $ExpectedOk
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
  $expectedOkLine = 'ok=' + $ExpectedOk.ToString().ToLowerInvariant()
  if ($joined -notmatch [regex]::Escape($expectedOkLine)) {
    $script:errors.Add("BMF response did not report $expectedOkLine for command: $Command")
  }
  foreach ($expected in $ExpectedLines) {
    if ($joined -notmatch [regex]::Escape($expected)) {
      $script:errors.Add("Command '$Command' output missing expected text: $expected")
    }
  }
}

try {
  foreach ($path in @($startServerScript, $sendRpcScript, $sourceBmfDir, $sourcePluginDir)) {
    if (!(Test-Path -LiteralPath $path)) {
      throw "Required path does not exist: $path"
    }
  }

  if (Test-Path -LiteralPath $runtimeBmfDir) {
    Remove-Item -LiteralPath $runtimeBmfDir -Recurse -Force
  }
  New-Item -ItemType Directory -Force -Path $runtimeBmfDir | Out-Null
  Copy-Item -Path (Join-Path $sourceBmfDir '*') -Destination $runtimeBmfDir -Recurse -Force
  New-Item -ItemType Directory -Force -Path $runtimePluginDir | Out-Null
  Copy-Item -Path (Join-Path $sourcePluginDir '*') -Destination $runtimePluginDir -Recurse -Force

  [ordered]@{
    pluginDir = [System.IO.Path]::GetFullPath($runtimePluginDir)
    manifest = [System.IO.Path]::GetFullPath((Join-Path $runtimePluginDir 'bmf.json'))
    plugin = [System.IO.Path]::GetFullPath((Join-Path $runtimePluginDir 'main.lua'))
    config = [System.IO.Path]::GetFullPath((Join-Path $runtimePluginDir 'config.json'))
    commands = @('bmf.brickassetguard.status', 'bmf.brickassetguard.check', 'bmf.brickassetguard.prefab-check')
  } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $pluginStagePath -Encoding UTF8
  Add-Evidence 'json' $pluginStagePath 'BrickAssetPlacementGuard plugin staging result'

  foreach ($path in @($runtimeLogPath, $runtimeStatusPath)) {
    if (Test-Path -LiteralPath $path) {
      Remove-Item -LiteralPath $path -Force
    }
  }
  foreach ($path in @($nativeControlPath, $nativeStatusPath, $nativeEventPath)) {
    if (Test-Path -LiteralPath $path) {
      Remove-Item -LiteralPath $path -Force
    }
  }

  $startOutput = & $startServerScript -RuntimeModsDir $RuntimeModsDir -BridgeDir $bridgeDir -Port $Port -VerifyWaitSeconds 30
  $startOutput | Set-Content -LiteralPath $startPath -Encoding UTF8
  $start = $startOutput | ConvertFrom-Json
  $serverPid = [int]$start.pid
  Add-Evidence 'json' $startPath 'Bridge test server startup result'
  if ($start.verified -ne $true) {
    $errors.Add("Bridge server did not verify: $($start.verify_reason)")
  } else {
    Start-Sleep -Seconds 4

    Invoke-BmfConsoleCommand 'bmf.apis name=BMF.permissions.evaluateBrickAssetAccess' 'bmf-apis-brick-asset-access' @(
      'BMF bmf.apis OK',
      'api_count=1',
      'api_1=BMF.permissions.evaluateBrickAssetAccess|namespace=permissions|stability=stable|risk=low',
      'requires_player=false'
    )

    Invoke-BmfConsoleCommand 'bmf.brickassetguard.status' 'bmf-brickassetguard-status' @(
      'BMF bmf.brickassetguard.status OK',
      'policy=brickAssetPlacementGuard',
      'enforcement=serverplacesimpleentityvolume-serverpasteprefab-placeprefabaction-placebrickaction-native-policy',
      'live_hook=ServerPlaceSimpleEntityVolume,ServerPastePrefab,BrickAction_PlacePrefab,BrickAction_PlaceBrick',
      'admin_roles=',
      'denied_assets=',
      'Entity_Wheel_*',
      'prefab_guard_enabled=true',
      'prefab_index_code=OK',
      'prefab_index_count=2',
      'restricted_prefab_hash_count=1',
      'prefab_denied_canary_hash=1111111111111111111111111111111111111111111111111111111111111111',
      'prefab_denied_canary_allowed=false',
      'prefab_denied_canary_decision=prefab-asset-denied',
      'prefab_denied_canary_asset=Entity_Wheel_Steelie1',
      'denied_canary_allowed=false',
      'denied_canary_decision=asset-denied',
      'admin_canary_allowed=false',
      'admin_canary_decision=asset-denied',
      'allowed_canary_allowed=true',
      'role_assignments_saved_dir=C:/Users/tycox/OneDrive/Documents/GitHub/Brickadia/omegga-master/omegga-master/data/Saved',
      'role_assignments_code=OK',
      'role_assignments_path=C:/Users/tycox/OneDrive/Documents/GitHub/Brickadia/omegga-master/omegga-master/data/Saved/Server/RoleAssignments.json'
    )

    Invoke-BmfConsoleCommand 'bmf.brickassetguard.check asset=Entity_Wheel_Steelie1 roles=Default' 'bmf-brickassetguard-check-default-denied' @(
      'BMF bmf.brickassetguard.check OK',
      'asset=Entity_Wheel_Steelie1',
      'asset_label=Wheel / Tire',
      'allowed=false',
      'decision=asset-denied',
      'matched_asset=Entity_Wheel_*',
      'roles=Default'
    )

    Invoke-BmfConsoleCommand 'bmf.brickassetguard.check asset=Entity_Wheel_Steelie1 roles=Admin' 'bmf-brickassetguard-check-admin-denied' @(
      'BMF bmf.brickassetguard.check OK',
      'asset=Entity_Wheel_Steelie1',
      'allowed=false',
      'decision=asset-denied',
      'matched_asset=Entity_Wheel_*',
      'matched_role=',
      'roles=Admin'
    )

    Invoke-BmfConsoleCommand 'bmf.brickassetguard.check asset=PB_DefaultMicroBrick roles=Default' 'bmf-brickassetguard-check-procedural-allowed' @(
      'BMF bmf.brickassetguard.check OK',
      'asset=PB_DefaultMicroBrick',
      'allowed=true',
      'decision=asset-allowed',
      'roles=Default'
    )

    Invoke-BmfConsoleCommand 'bmf.brickassetguard.prefab-check hash=1111111111111111111111111111111111111111111111111111111111111111 roles=Default' 'bmf-brickassetguard-prefab-check-default-denied' @(
      'BMF bmf.brickassetguard.prefab-check OK',
      'hash=1111111111111111111111111111111111111111111111111111111111111111',
      'allowed=false',
      'decision=prefab-asset-denied',
      'asset=Entity_Wheel_Steelie1',
      'matched_asset=Entity_Wheel_*',
      'roles=Default',
      'asset_count=2',
      'prefab_index_code=OK',
      'prefab_index_count=2',
      'enforcement=serverpasteprefab-and-placeprefab-action-native-policy'
    )

    Invoke-BmfConsoleCommand 'bmf.brickassetguard.prefab-check hash=2222222222222222222222222222222222222222222222222222222222222222 roles=Default' 'bmf-brickassetguard-prefab-check-default-allowed' @(
      'BMF bmf.brickassetguard.prefab-check OK',
      'hash=2222222222222222222222222222222222222222222222222222222222222222',
      'allowed=true',
      'decision=prefab-assets-allowed',
      'roles=Default',
      'asset_count=1',
      'prefab_index_code=OK',
      'prefab_index_count=2'
    )
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
  Add-Evidence 'log' $bmfLogPath 'BMF runtime log with brick asset policy evidence'
  $logText = Get-Content -Raw -LiteralPath $bmfLogPath
  foreach ($needle in @(
    'registered console command bmf.brickassetguard.status',
    'registered console command bmf.brickassetguard.check',
    'registered console command bmf.brickassetguard.prefab-check',
    'loaded plugin BrickAssetPlacementGuard'
  )) {
    if ($logText -notmatch [regex]::Escape($needle)) {
      $errors.Add("BMF log missing expected line: $needle")
    }
  }
} else {
  $errors.Add("BMF runtime log was not written: $runtimeLogPath")
}

if (Test-Path -LiteralPath $runtimePluginLogPath) {
  Copy-Item -LiteralPath $runtimePluginLogPath -Destination $pluginLogPath -Force
  Add-Evidence 'log' $pluginLogPath 'BrickAssetPlacementGuard per-plugin log'
} else {
  $errors.Add("Plugin log was not written: $runtimePluginLogPath")
}

if (Test-Path -LiteralPath $runtimeStatusPath) {
  Copy-Item -LiteralPath $runtimeStatusPath -Destination $statusPath -Force
  Add-Evidence 'json' $statusPath 'BMF runtime status after brick asset policy canary'
  try {
    $status = Read-JsonFile $statusPath
    if ([int]$status.plugins_loaded -lt 1) {
      $errors.Add("Expected at least one plugin loaded, got $($status.plugins_loaded).")
    }
  } catch {
    $errors.Add("Could not parse BMF status: $($_.Exception.Message)")
  }
} else {
  $errors.Add("BMF runtime status was not written: $runtimeStatusPath")
}

$resultStatus = 'failed'
if ($errors.Count -eq 0) {
  $resultStatus = 'passed'
}

$result = [ordered]@{
  feature = 'bmf.permissions.brick-asset-policy'
  status = $resultStatus
  validationLevel = 'L2 Headless + L5 Negative'
  startedAt = $startedAt
  finishedAt = (Get-Date).ToUniversalTime().ToString('o')
  evidence = @($evidence.ToArray())
  errors = @($errors.ToArray())
  data = [ordered]@{
    brickadiaRoot = [System.IO.Path]::GetFullPath($BrickadiaRoot)
    runtimeModsDir = [System.IO.Path]::GetFullPath($RuntimeModsDir)
    bridgeDir = [System.IO.Path]::GetFullPath($bridgeDir)
    port = $Port
    commands = @($commandResults.ToArray())
  }
}

$json = $result | ConvertTo-Json -Depth 12
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $outPath) | Out-Null
Set-Content -LiteralPath $outPath -Value $json -Encoding UTF8
Write-Output $json

if ($errors.Count -ne 0) {
  exit 1
}
