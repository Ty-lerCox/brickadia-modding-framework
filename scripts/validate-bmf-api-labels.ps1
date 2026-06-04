param(
  [string]$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
  [string]$BrickadiaRoot = '',
  [string]$RuntimeModsDir = 'C:\Users\tycox\AppData\Roaming\omegga\steam_installs\main\Brickadia\Binaries\Win64\ue4ss\main\Mods',
  [string]$OutJson = '',
  [int]$Port = 7846
)

$ErrorActionPreference = 'Stop'

if (!$BrickadiaRoot) {
  $BrickadiaRoot = (Resolve-Path (Join-Path $Root '..\Brickadia')).Path
}
if (!$OutJson) {
  $OutJson = Join-Path $Root 'artifacts/local/bmf-api-labels-canary.json'
}

$errors = New-Object System.Collections.Generic.List[string]
$evidence = New-Object System.Collections.Generic.List[object]
$commandResults = New-Object System.Collections.Generic.List[object]
$startedAt = (Get-Date).ToUniversalTime().ToString('o')
$outPath = [System.IO.Path]::GetFullPath($OutJson)
$artifactRoot = Split-Path -Parent $outPath
$caseRoot = Join-Path $artifactRoot 'bmf-api-labels'
New-Item -ItemType Directory -Force -Path $caseRoot | Out-Null

$startServerScript = Join-Path $BrickadiaRoot 'brickadia-ue4ss-re/scripts/start-bridge-test-server.ps1'
$sendRpcScript = Join-Path $BrickadiaRoot 'brickadia-ue4ss-re/scripts/send-bridge-rpc.js'
$sourceBmfDir = Join-Path $Root 'framework/ue4ss/Mods/BMF'
$runtimeBmfDir = Join-Path $RuntimeModsDir 'BMF'
$runtimePluginDir = Join-Path $runtimeBmfDir 'plugins/ApiLabelsCanary'
$runtimeLogPath = Join-Path $runtimeBmfDir 'runtime/bmf.log'
$runtimePluginLogPath = Join-Path $runtimeBmfDir 'runtime/logs/plugins/ApiLabelsCanary.log'
$runtimeStatusPath = Join-Path $runtimeBmfDir 'runtime/status.json'
$bridgeDir = Join-Path $caseRoot "bridge-$Port"
$startPath = Join-Path $caseRoot 'server-start.json'
$pluginStagePath = Join-Path $caseRoot 'api-labels-plugin-stage.json'
$bmfLogPath = Join-Path $caseRoot 'bmf.log'
$pluginLogPath = Join-Path $caseRoot 'ApiLabelsCanary.log'
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
    expectedOk = $ExpectedOk
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
  foreach ($path in @($startServerScript, $sendRpcScript, $sourceBmfDir)) {
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

  $manifestSource = @'
{
  "name": "ApiLabelsCanary",
  "version": "1.0.0",
  "author": "BMF",
  "description": "Temporary BMF API labels canary plugin.",
  "capabilities": ["plugins.lifecycle"]
}
'@
  Set-Content -LiteralPath (Join-Path $runtimePluginDir 'bmf.json') -Value $manifestSource -Encoding UTF8

  $pluginSource = @'
return {
  name = "ApiLabelsCanary",
  onLoad = function(BMF)
    BMF.commands.register("bmf.api.labels.canary", "API labels canary.", function()
      local whisper = BMF.apis.get("BMF.chat.whisper")
      local server_exec = BMF.apis.get("BMF.server.exec")
      local world_load = BMF.apis.get("BMF.world.loadAdditive")
      local vehicles = BMF.apis.get("BMF.vehicles.spawnSet")
      local live = BMF.apis.list({ risk = "live-player" })
      local player_required = BMF.apis.list({ requiresPlayer = true })
      local summary = BMF.apis.summary()

      local whisper_api = whisper.data and whisper.data.api or {}
      local exec_api = server_exec.data and server_exec.data.api or {}
      local world_api = world_load.data and world_load.data.api or {}
      local vehicle_api = vehicles.data and vehicles.data.api or {}
      local total = summary.data and summary.data.total or 0
      local stable = summary.data and summary.data.stability and summary.data.stability.stable or 0

      BMF.logInfo("ApiLabelsCanary handled", {
        total = total,
        live = live.data and live.data.count or 0,
      })

      return BMF.result(true, "OK", "API labels canary handled", {
        lines = {
          "whisper_stability=" .. tostring(whisper_api.stability or ""),
          "whisper_risk=" .. tostring(whisper_api.risk or ""),
          "whisper_requires_player=" .. tostring(whisper_api.requiresPlayer == true),
          "server_exec_stability=" .. tostring(exec_api.stability or ""),
          "server_exec_risk=" .. tostring(exec_api.risk or ""),
          "world_load_stability=" .. tostring(world_api.stability or ""),
          "vehicle_spawn_stability=" .. tostring(vehicle_api.stability or ""),
          "live_player_count_at_least_1=" .. tostring(((live.data and live.data.count) or 0) >= 1),
          "requires_player_count_at_least_1=" .. tostring(((player_required.data and player_required.data.count) or 0) >= 1),
          "summary_total_at_least_30=" .. tostring(total >= 30),
          "summary_stable_at_least_10=" .. tostring(stable >= 10),
        },
      })
    end)
  end,
}
'@
  Set-Content -LiteralPath (Join-Path $runtimePluginDir 'main.lua') -Value $pluginSource -Encoding UTF8

  [ordered]@{
    pluginDir = [System.IO.Path]::GetFullPath($runtimePluginDir)
    manifest = [System.IO.Path]::GetFullPath((Join-Path $runtimePluginDir 'bmf.json'))
    plugin = [System.IO.Path]::GetFullPath((Join-Path $runtimePluginDir 'main.lua'))
    command = 'bmf.api.labels.canary'
  } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $pluginStagePath -Encoding UTF8
  Add-Evidence 'json' $pluginStagePath 'Temporary ApiLabelsCanary plugin staging result'

  foreach ($path in @($runtimeLogPath, $runtimeStatusPath)) {
    if (Test-Path -LiteralPath $path) {
      Remove-Item -LiteralPath $path -Force
    }
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

    Invoke-BmfConsoleCommand 'bmf.api.labels.canary' 'bmf-api-labels-canary' @(
      'BMF bmf.api.labels.canary OK',
      'whisper_stability=scaffold',
      'whisper_risk=live-player',
      'whisper_requires_player=true',
      'server_exec_stability=restricted',
      'server_exec_risk=unsafe-native',
      'world_load_stability=experimental',
      'vehicle_spawn_stability=experimental',
      'live_player_count_at_least_1=true',
      'requires_player_count_at_least_1=true',
      'summary_total_at_least_30=true',
      'summary_stable_at_least_10=true'
    )

    Invoke-BmfConsoleCommand 'bmf.apis name=BMF.chat.whisper' 'bmf-apis-whisper' @(
      'BMF bmf.apis OK',
      'api_count=1',
      'api_1=BMF.chat.whisper|namespace=chat|stability=scaffold|risk=live-player',
      'requires_player=true',
      'capability=chat.whisper'
    )

    Invoke-BmfConsoleCommand 'bmf.apis name=BMF.server.exec' 'bmf-apis-server-exec' @(
      'BMF bmf.apis OK',
      'api_count=1',
      'api_1=BMF.server.exec|namespace=server|stability=restricted|risk=unsafe-native',
      'capability=server.exec'
    )

    Invoke-BmfConsoleCommand 'bmf.apis name=BMF.server.shutdown' 'bmf-apis-server-shutdown' @(
      'BMF bmf.apis OK',
      'api_count=1',
      'api_1=BMF.server.shutdown|namespace=server|stability=restricted|risk=high',
      'capability=server.shutdown'
    )

    Invoke-BmfConsoleCommand 'bmf.apis name=BMF.version' 'bmf-apis-version' @(
      'BMF bmf.apis OK',
      'api_count=1',
      'api_1=BMF.version|namespace=framework|stability=stable|risk=low',
      'requires_player=false'
    )

    Invoke-BmfConsoleCommand 'bmf.apis name=BMF.loadPlugins' 'bmf-apis-load-plugins' @(
      'BMF bmf.apis OK',
      'api_count=1',
      'api_1=BMF.loadPlugins|namespace=plugins|stability=stable|risk=medium',
      'requires_player=false'
    )

    Invoke-BmfConsoleCommand 'bmf.apis name=BMF.storage.readJson' 'bmf-apis-storage-readjson' @(
      'BMF bmf.apis OK',
      'api_count=1',
      'api_1=BMF.storage.readJson|namespace=storage|stability=stable|risk=low',
      'capability=plugins.storage'
    )

    Invoke-BmfConsoleCommand 'bmf.apis risk=live-player limit=20' 'bmf-apis-live-player' @(
      'BMF bmf.apis OK',
      'summary_risk_live_player=',
      'requires_player=true'
    )

    Invoke-BmfConsoleCommand 'bmf.apis stability=experimental limit=80' 'bmf-apis-experimental' @(
      'BMF bmf.apis OK',
      'BMF.world.loadAdditive|namespace=world|stability=experimental|risk=high',
      'BMF.vehicles.spawnSet|namespace=vehicles|stability=experimental|risk=high'
    )

    Invoke-BmfConsoleCommand 'bmf.server.status' 'bmf-server-status-api-labels' @(
      'BMF bmf.server.status OK',
      'api_labels='
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
  Add-Evidence 'log' $bmfLogPath 'BMF runtime log with API label evidence'
  $logText = Get-Content -Raw -LiteralPath $bmfLogPath
  foreach ($needle in @(
    'registered console command bmf.apis',
    'registered console command bmf.api.labels.canary',
    'ApiLabelsCanary handled'
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
  Add-Evidence 'log' $pluginLogPath 'ApiLabelsCanary per-plugin log'
} else {
  $errors.Add("Plugin log was not written: $runtimePluginLogPath")
}

if (Test-Path -LiteralPath $runtimeStatusPath) {
  Copy-Item -LiteralPath $runtimeStatusPath -Destination $statusPath -Force
  Add-Evidence 'json' $statusPath 'BMF runtime status after API labels canary'
  try {
    $status = Read-JsonFile $statusPath
    if ([int]$status.api_labels -lt 30) {
      $errors.Add("Expected at least 30 API labels, got $($status.api_labels).")
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
  feature = 'bmf.api-labels'
  status = $resultStatus
  validationLevel = 'L2 Headless'
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
