param(
  [string]$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
  [string]$BrickadiaRoot = '',
  [string]$RuntimeModsDir = 'C:\Users\tycox\AppData\Roaming\omegga\steam_installs\main\Brickadia\Binaries\Win64\ue4ss\main\Mods',
  [string]$OutJson = '',
  [int]$Port = 7839,
  [int]$WaitAfterSaveSeconds = 8
)

$ErrorActionPreference = 'Stop'

if (!$BrickadiaRoot) {
  $BrickadiaRoot = (Resolve-Path (Join-Path $Root '..\Brickadia')).Path
}
if (!$OutJson) {
  $OutJson = Join-Path $Root 'artifacts/local/bmf-events-canary.json'
}

$errors = New-Object System.Collections.Generic.List[string]
$evidence = New-Object System.Collections.Generic.List[object]
$commandResults = New-Object System.Collections.Generic.List[object]
$startedAt = (Get-Date).ToUniversalTime().ToString('o')
$outPath = [System.IO.Path]::GetFullPath($OutJson)
$artifactRoot = Split-Path -Parent $outPath
$caseRoot = Join-Path $artifactRoot 'bmf-events'
New-Item -ItemType Directory -Force -Path $caseRoot | Out-Null

$startServerScript = Join-Path $BrickadiaRoot 'brickadia-ue4ss-re/scripts/start-bridge-test-server.ps1'
$sendRpcScript = Join-Path $BrickadiaRoot 'brickadia-ue4ss-re/scripts/send-bridge-rpc.js'
$sourceBmfDir = Join-Path $Root 'framework/ue4ss/Mods/BMF'
$runtimeBmfDir = Join-Path $RuntimeModsDir 'BMF'
$runtimePluginDir = Join-Path $runtimeBmfDir 'plugins/EventCanary'
$runtimeLogPath = Join-Path $runtimeBmfDir 'runtime/bmf.log'
$runtimePluginLogPath = Join-Path $runtimeBmfDir 'runtime/logs/plugins/EventCanary.log'
$runtimeStatusPath = Join-Path $runtimeBmfDir 'runtime/status.json'
$worldsDir = Join-Path $BrickadiaRoot 'omegga-master/omegga-master/data/Saved/Worlds'
$saveName = 'BMF_EventCanarySave_{0}' -f (Get-Date -Format 'yyyyMMddHHmmss')
$savedWorldPath = Join-Path $worldsDir ($saveName + '.brdb')
$bridgeDir = Join-Path $caseRoot "bridge-$Port"
$startPath = Join-Path $caseRoot 'server-start.json'
$pluginStagePath = Join-Path $caseRoot 'event-plugin-stage.json'
$bmfLogPath = Join-Path $caseRoot 'bmf.log'
$pluginLogPath = Join-Path $caseRoot 'EventCanary.log'
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

function Invoke-BmfConsoleCommand([string]$Command, [string]$Slug, [string[]]$ExpectedLines) {
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
  "name": "EventCanary",
  "version": "1.0.0",
  "author": "BMF",
  "description": "Temporary BMF event canary plugin.",
  "capabilities": ["plugins.lifecycle"]
}
'@
  Set-Content -LiteralPath (Join-Path $runtimePluginDir 'bmf.json') -Value $manifestSource -Encoding UTF8

  $pluginSource = @'
local state = {
  serverReady = 0,
  serverReadyPlugins = 0,
  pluginLoaded = 0,
  worldSaved = 0,
  worldSavedName = "",
  custom = 0,
  customValue = 0,
  customHandlers = 0,
  customOff = false,
  customAfterOffHandlers = -1,
}

return {
  name = "EventCanary",
  onLoad = function(BMF)
    BMF.events.on("serverReady", function(data)
      state.serverReady = state.serverReady + 1
      state.serverReadyPlugins = tonumber(data.pluginsLoaded) or 0
      BMF.logInfo("EventCanary serverReady", { pluginsLoaded = state.serverReadyPlugins })
    end)
    BMF.events.on("pluginLoaded", function(data)
      if data.name == "EventCanary" then
        state.pluginLoaded = state.pluginLoaded + 1
        BMF.logInfo("EventCanary pluginLoaded", { name = data.name })
      end
    end)
    BMF.events.on("pluginUnloaded", function(data)
      if data.name == "EventCanary" then
        BMF.logInfo("EventCanary pluginUnloaded", { name = data.name, reason = data.reason })
      end
    end)
    BMF.events.on("worldSaved", function(data)
      state.worldSaved = state.worldSaved + 1
      state.worldSavedName = tostring(data.world or "")
      BMF.logInfo("EventCanary worldSaved", { world = state.worldSavedName })
    end)

    local custom_id = BMF.events.on("EventCanary.custom", function(data)
      state.custom = state.custom + 1
      state.customValue = tonumber(data.value) or 0
    end)
    local emitted = BMF.events.emit("EventCanary.custom", { value = 7 })
    state.customHandlers = emitted.data.handlers or 0
    state.customOff = BMF.events.off(custom_id)
    local emitted_after_off = BMF.events.emit("EventCanary.custom", { value = 8 })
    state.customAfterOffHandlers = emitted_after_off.data.handlers or -1

    BMF.commands.register("bmf.events.canary", "Event canary.", function()
      return BMF.result(true, "OK", "Event canary handled", {
        lines = {
          "server_ready_count=" .. tostring(state.serverReady),
          "server_ready_plugins=" .. tostring(state.serverReadyPlugins),
          "plugin_loaded_count=" .. tostring(state.pluginLoaded),
          "world_saved_count=" .. tostring(state.worldSaved),
          "world_saved_name=" .. tostring(state.worldSavedName),
          "custom_count=" .. tostring(state.custom),
          "custom_value=" .. tostring(state.customValue),
          "custom_handlers=" .. tostring(state.customHandlers),
          "custom_off=" .. tostring(state.customOff),
          "custom_after_off_handlers=" .. tostring(state.customAfterOffHandlers),
          "server_ready_listeners=" .. tostring(BMF.events.listenerCount("serverReady")),
          "plugin_loaded_listeners=" .. tostring(BMF.events.listenerCount("pluginLoaded")),
          "plugin_unloaded_listeners=" .. tostring(BMF.events.listenerCount("pluginUnloaded")),
          "world_saved_listeners=" .. tostring(BMF.events.listenerCount("worldSaved")),
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
    command = 'bmf.events.canary'
  } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $pluginStagePath -Encoding UTF8
  Add-Evidence 'json' $pluginStagePath 'Temporary EventCanary plugin staging result'

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

    Invoke-BmfConsoleCommand 'bmf.events.canary' 'bmf-events-before-save' @(
      'BMF bmf.events.canary OK',
      'server_ready_count=1',
      'plugin_loaded_count=1',
      'world_saved_count=0',
      'custom_count=1',
      'custom_value=7',
      'custom_handlers=1',
      'custom_off=true',
      'custom_after_off_handlers=0',
      'server_ready_listeners=1',
      'plugin_loaded_listeners=1',
      'plugin_unloaded_listeners=1',
      'world_saved_listeners=1'
    )

    Invoke-BmfConsoleCommand "bmf.server.save name=$saveName" 'bmf-server-save' @(
      'BMF bmf.server.save OK',
      "world=$saveName",
      'api=BMF.server.save'
    )

    Start-Sleep -Seconds $WaitAfterSaveSeconds

    Invoke-BmfConsoleCommand 'bmf.events.canary' 'bmf-events-after-save' @(
      'BMF bmf.events.canary OK',
      'server_ready_count=1',
      'plugin_loaded_count=1',
      'world_saved_count=1',
      "world_saved_name=$saveName",
      'custom_count=1',
      'custom_after_off_handlers=0',
      'server_ready_listeners=1',
      'plugin_loaded_listeners=1',
      'plugin_unloaded_listeners=1',
      'world_saved_listeners=1'
    )

    Invoke-BmfConsoleCommand 'bmf.reload' 'bmf-reload' @(
      'BMF bmf.reload OK',
      'plugins_unloaded=1',
      'unload_errors=0',
      'plugins_loaded=1',
      'plugin_errors=0'
    )

    Start-Sleep -Seconds 2

    Invoke-BmfConsoleCommand 'bmf.events.canary' 'bmf-events-after-reload' @(
      'BMF bmf.events.canary OK',
      'server_ready_count=0',
      'plugin_loaded_count=1',
      'world_saved_count=0',
      'custom_count=1',
      'custom_after_off_handlers=0',
      'server_ready_listeners=1',
      'plugin_loaded_listeners=1',
      'plugin_unloaded_listeners=1',
      'world_saved_listeners=1'
    )

    if (!(Test-Path -LiteralPath $savedWorldPath)) {
      $errors.Add("Saved world was not created for worldSaved event: $savedWorldPath")
    } else {
      Add-Evidence 'brdb' $savedWorldPath 'World BRDB saved during event canary'
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
  Add-Evidence 'log' $bmfLogPath 'BMF runtime log with event evidence'
  $logText = Get-Content -Raw -LiteralPath $bmfLogPath
  foreach ($needle in @(
    'EventCanary serverReady',
    'EventCanary pluginLoaded',
    'EventCanary pluginUnloaded',
    'EventCanary worldSaved',
    'event_handlers_removed=4',
    'BMF bmf.events.canary OK'
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
  Add-Evidence 'log' $pluginLogPath 'EventCanary per-plugin log'
} else {
  $errors.Add("Plugin log was not written: $runtimePluginLogPath")
}

if (Test-Path -LiteralPath $runtimeStatusPath) {
  Copy-Item -LiteralPath $runtimeStatusPath -Destination $statusPath -Force
  Add-Evidence 'json' $statusPath 'BMF runtime status after event canary'
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
  feature = 'bmf.events.runtime'
  status = $resultStatus
  validationLevel = 'L2 Headless'
  startedAt = $startedAt
  finishedAt = (Get-Date).ToUniversalTime().ToString('o')
  data = [ordered]@{
    brickadiaRoot = [System.IO.Path]::GetFullPath($BrickadiaRoot)
    runtimeModsDir = [System.IO.Path]::GetFullPath($RuntimeModsDir)
    port = $Port
    bridgeDir = [System.IO.Path]::GetFullPath($bridgeDir)
    pluginDir = [System.IO.Path]::GetFullPath($runtimePluginDir)
    saveName = $saveName
    savedWorldPath = [System.IO.Path]::GetFullPath($savedWorldPath)
    commands = $commandResults.ToArray()
  }
  evidence = $evidence.ToArray()
  errors = $errors.ToArray()
}

$json = $result | ConvertTo-Json -Depth 10
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $outPath) | Out-Null
Set-Content -LiteralPath $outPath -Value $json -Encoding UTF8
Write-Output $json

if ($errors.Count -ne 0) {
  exit 1
}
