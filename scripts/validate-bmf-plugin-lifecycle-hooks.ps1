param(
  [string]$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
  [string]$BrickadiaRoot = '',
  [string]$RuntimeModsDir = 'C:\Users\tycox\AppData\Roaming\omegga\steam_installs\main\Brickadia\Binaries\Win64\ue4ss\main\Mods',
  [string]$OutJson = '',
  [int]$Port = 7841
)

$ErrorActionPreference = 'Stop'

if (!$BrickadiaRoot) {
  $BrickadiaRoot = (Resolve-Path (Join-Path $Root '..\Brickadia')).Path
}
if (!$OutJson) {
  $OutJson = Join-Path $Root 'artifacts/local/bmf-plugin-lifecycle-hooks-canary.json'
}

$errors = New-Object System.Collections.Generic.List[string]
$evidence = New-Object System.Collections.Generic.List[object]
$commandResults = New-Object System.Collections.Generic.List[object]
$startedAt = (Get-Date).ToUniversalTime().ToString('o')
$outPath = [System.IO.Path]::GetFullPath($OutJson)
$artifactRoot = Split-Path -Parent $outPath
$caseRoot = Join-Path $artifactRoot 'bmf-plugin-lifecycle-hooks'
New-Item -ItemType Directory -Force -Path $caseRoot | Out-Null

$startServerScript = Join-Path $BrickadiaRoot 'brickadia-ue4ss-re/scripts/start-bridge-test-server.ps1'
$sendRpcScript = Join-Path $BrickadiaRoot 'brickadia-ue4ss-re/scripts/send-bridge-rpc.js'
$sourceBmfDir = Join-Path $Root 'framework/ue4ss/Mods/BMF'
$runtimeBmfDir = Join-Path $RuntimeModsDir 'BMF'
$runtimePluginDir = Join-Path $runtimeBmfDir 'plugins/LifecycleHooksCanary'
$runtimeLogPath = Join-Path $runtimeBmfDir 'runtime/bmf.log'
$runtimePluginLogPath = Join-Path $runtimeBmfDir 'runtime/logs/plugins/LifecycleHooksCanary.log'
$runtimeStatusPath = Join-Path $runtimeBmfDir 'runtime/status.json'
$bridgeDir = Join-Path $caseRoot "bridge-$Port"
$startPath = Join-Path $caseRoot 'server-start.json'
$pluginStagePath = Join-Path $caseRoot 'lifecycle-hooks-plugin-stage.json'
$bmfLogPath = Join-Path $caseRoot 'bmf.log'
$pluginLogPath = Join-Path $caseRoot 'LifecycleHooksCanary.log'
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
  "name": "LifecycleHooksCanary",
  "version": "1.0.0",
  "author": "BMF",
  "description": "Temporary BMF lifecycle hook canary plugin.",
  "capabilities": ["plugins.lifecycle"]
}
'@
  Set-Content -LiteralPath (Join-Path $runtimePluginDir 'bmf.json') -Value $manifestSource -Encoding UTF8

  $pluginSource = @'
local state = {
  serverReady = 0,
  serverReadyPlugins = 0,
  tick = 0,
  tickErrorRaised = false,
  tickErrorSeen = false,
  commandErrorSeen = false,
  errorCount = 0,
  lastErrorHook = "",
  lastErrorMessage = "",
}

return {
  name = "LifecycleHooksCanary",
  onLoad = function(BMF)
    BMF.commands.register("bmf.lifecycle.hooks", "Lifecycle hook canary.", function()
      return BMF.result(true, "OK", "Lifecycle hook canary handled", {
        lines = {
          "server_ready_count=" .. tostring(state.serverReady),
          "server_ready_plugins=" .. tostring(state.serverReadyPlugins),
          "tick_count=" .. tostring(state.tick),
          "tick_count_at_least_2=" .. tostring(state.tick >= 2),
          "tick_error_seen=" .. tostring(state.tickErrorSeen),
          "command_error_seen=" .. tostring(state.commandErrorSeen),
          "error_count=" .. tostring(state.errorCount),
          "last_error_hook=" .. tostring(state.lastErrorHook),
          "last_error_message=" .. tostring(state.lastErrorMessage),
        },
      })
    end)

    BMF.commands.register("bmf.lifecycle.fail", "Lifecycle hook failure canary.", function()
      error("LifecycleHooksCanary forced command failure", 0)
    end)
  end,
  onServerReady = function(BMF, data)
    state.serverReady = state.serverReady + 1
    state.serverReadyPlugins = tonumber(data.pluginsLoaded) or 0
    BMF.logInfo("LifecycleHooksCanary onServerReady", { pluginsLoaded = state.serverReadyPlugins })
  end,
  onTick = function(BMF, data)
    state.tick = state.tick + 1
    if state.tick == 1 then
      BMF.logInfo("LifecycleHooksCanary onTick", { tick = state.tick, runtimeTick = data.tick })
    end
    if state.tick == 2 and not state.tickErrorRaised then
      state.tickErrorRaised = true
      error("LifecycleHooksCanary forced tick failure", 0)
    end
  end,
  onError = function(BMF, context)
    state.errorCount = state.errorCount + 1
    state.lastErrorHook = tostring(context.hook or "")
    state.lastErrorMessage = tostring(context.error or "")
    if state.lastErrorHook == "onTick" then
      state.tickErrorSeen = true
    end
    if state.lastErrorHook == "command:bmf.lifecycle.fail" then
      state.commandErrorSeen = true
    end
    BMF.logInfo("LifecycleHooksCanary onError", {
      hook = state.lastErrorHook,
      error = state.lastErrorMessage,
    })
  end,
}
'@
  Set-Content -LiteralPath (Join-Path $runtimePluginDir 'main.lua') -Value $pluginSource -Encoding UTF8

  [ordered]@{
    pluginDir = [System.IO.Path]::GetFullPath($runtimePluginDir)
    manifest = [System.IO.Path]::GetFullPath((Join-Path $runtimePluginDir 'bmf.json'))
    plugin = [System.IO.Path]::GetFullPath((Join-Path $runtimePluginDir 'main.lua'))
    commands = @('bmf.lifecycle.hooks', 'bmf.lifecycle.fail')
  } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $pluginStagePath -Encoding UTF8
  Add-Evidence 'json' $pluginStagePath 'Temporary LifecycleHooksCanary plugin staging result'

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
    Start-Sleep -Seconds 5

    Invoke-BmfConsoleCommand 'bmf.lifecycle.hooks' 'bmf-lifecycle-hooks-before-command-error' @(
      'BMF bmf.lifecycle.hooks OK',
      'server_ready_count=1',
      'server_ready_plugins=1',
      'tick_count_at_least_2=true',
      'tick_error_seen=true',
      'command_error_seen=false',
      'error_count=1',
      'last_error_hook=onTick',
      'last_error_message=LifecycleHooksCanary forced tick failure'
    )

    Invoke-BmfConsoleCommand 'bmf.lifecycle.fail' 'bmf-lifecycle-fail' @(
      'BMF bmf.lifecycle.fail ERROR LifecycleHooksCanary forced command failure'
    )

    Invoke-BmfConsoleCommand 'bmf.lifecycle.hooks' 'bmf-lifecycle-hooks-after-command-error' @(
      'BMF bmf.lifecycle.hooks OK',
      'server_ready_count=1',
      'tick_count_at_least_2=true',
      'tick_error_seen=true',
      'command_error_seen=true',
      'error_count=2',
      'last_error_hook=command:bmf.lifecycle.fail',
      'last_error_message=LifecycleHooksCanary forced command failure'
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
  Add-Evidence 'log' $bmfLogPath 'BMF runtime log with lifecycle hook evidence'
  $logText = Get-Content -Raw -LiteralPath $bmfLogPath
  foreach ($needle in @(
    'LifecycleHooksCanary onServerReady',
    'LifecycleHooksCanary onTick',
    'LifecycleHooksCanary onError',
    'plugin LifecycleHooksCanary onTick failed',
    'plugin LifecycleHooksCanary command:bmf.lifecycle.fail failed'
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
  Add-Evidence 'log' $pluginLogPath 'LifecycleHooksCanary per-plugin log'
} else {
  $errors.Add("Plugin log was not written: $runtimePluginLogPath")
}

if (Test-Path -LiteralPath $runtimeStatusPath) {
  Copy-Item -LiteralPath $runtimeStatusPath -Destination $statusPath -Force
  Add-Evidence 'json' $statusPath 'BMF runtime status after lifecycle hook canary'
  try {
    $status = Read-JsonFile $statusPath
    if ($status.server_ready -ne $true) {
      $errors.Add('Expected BMF status server_ready=true.')
    }
    if ($status.plugin_tick_active -ne $true) {
      $errors.Add('Expected BMF status plugin_tick_active=true.')
    }
    if ([int]$status.plugin_errors -lt 2) {
      $errors.Add("Expected at least two plugin errors, got $($status.plugin_errors).")
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
  feature = 'bmf.plugins.lifecycle-hooks'
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
    commands = $commandResults.ToArray()
  }
  evidence = $evidence.ToArray()
  errors = $errors.ToArray()
}

$json = $result | ConvertTo-Json -Depth 10
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $outPath) | Out-Null
Set-Content -LiteralPath $outPath -Value $json -Encoding UTF8
Write-Output $json
