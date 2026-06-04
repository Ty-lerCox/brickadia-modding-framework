param(
  [string]$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
  [string]$BrickadiaRoot = '',
  [string]$RuntimeModsDir = 'C:\Users\tycox\AppData\Roaming\omegga\steam_installs\main\Brickadia\Binaries\Win64\ue4ss\main\Mods',
  [string]$OutJson = '',
  [int]$Port = 7845
)

$ErrorActionPreference = 'Stop'

if (!$BrickadiaRoot) {
  $BrickadiaRoot = (Resolve-Path (Join-Path $Root '..\Brickadia')).Path
}
if (!$OutJson) {
  $OutJson = Join-Path $Root 'artifacts/local/bmf-plugin-watchdog-canary.json'
}

$errors = New-Object System.Collections.Generic.List[string]
$evidence = New-Object System.Collections.Generic.List[object]
$commandResults = New-Object System.Collections.Generic.List[object]
$startedAt = (Get-Date).ToUniversalTime().ToString('o')
$outPath = [System.IO.Path]::GetFullPath($OutJson)
$artifactRoot = Split-Path -Parent $outPath
$caseRoot = Join-Path $artifactRoot 'bmf-plugin-watchdog'
New-Item -ItemType Directory -Force -Path $caseRoot | Out-Null

$startServerScript = Join-Path $BrickadiaRoot 'brickadia-ue4ss-re/scripts/start-bridge-test-server.ps1'
$sendRpcScript = Join-Path $BrickadiaRoot 'brickadia-ue4ss-re/scripts/send-bridge-rpc.js'
$sourceBmfDir = Join-Path $Root 'framework/ue4ss/Mods/BMF'
$runtimeBmfDir = Join-Path $RuntimeModsDir 'BMF'
$runtimePluginDir = Join-Path $runtimeBmfDir 'plugins/WatchdogCanary'
$runtimeLogPath = Join-Path $runtimeBmfDir 'runtime/bmf.log'
$runtimeAuditPath = Join-Path $runtimeBmfDir 'runtime/audit.jsonl'
$runtimePluginLogPath = Join-Path $runtimeBmfDir 'runtime/logs/plugins/WatchdogCanary.log'
$runtimeStatusPath = Join-Path $runtimeBmfDir 'runtime/status.json'
$bridgeDir = Join-Path $caseRoot "bridge-$Port"
$startPath = Join-Path $caseRoot 'server-start.json'
$pluginStagePath = Join-Path $caseRoot 'watchdog-plugin-stage.json'
$bmfLogPath = Join-Path $caseRoot 'bmf.log'
$auditPath = Join-Path $caseRoot 'audit.jsonl'
$auditParsedPath = Join-Path $caseRoot 'audit-parsed.json'
$pluginLogPath = Join-Path $caseRoot 'WatchdogCanary.log'
$statusIsolatedPath = Join-Path $caseRoot 'status-isolated.json'
$statusReloadPath = Join-Path $caseRoot 'status-after-reload.json'
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
  "name": "WatchdogCanary",
  "version": "1.0.0",
  "author": "BMF",
  "description": "Temporary BMF plugin watchdog canary.",
  "capabilities": ["plugins.lifecycle"]
}
'@
  Set-Content -LiteralPath (Join-Path $runtimePluginDir 'bmf.json') -Value $manifestSource -Encoding UTF8

  $pluginSource = @'
local attempts = 0

return {
  name = "WatchdogCanary",
  onLoad = function(BMF)
    BMF.commands.register("bmf.watchdog.fail", "Watchdog failure canary.", function()
      attempts = attempts + 1
      BMF.logInfo("WatchdogCanary fail attempt", { attempt = attempts })
      error("WatchdogCanary forced failure " .. tostring(attempts), 0)
    end)
  end,
  onUnload = function(BMF, reason)
    BMF.logInfo("WatchdogCanary onUnload", { reason = reason })
  end,
}
'@
  Set-Content -LiteralPath (Join-Path $runtimePluginDir 'main.lua') -Value $pluginSource -Encoding UTF8

  [ordered]@{
    pluginDir = [System.IO.Path]::GetFullPath($runtimePluginDir)
    manifest = [System.IO.Path]::GetFullPath((Join-Path $runtimePluginDir 'bmf.json'))
    plugin = [System.IO.Path]::GetFullPath((Join-Path $runtimePluginDir 'main.lua'))
    command = 'bmf.watchdog.fail'
    expectedThreshold = 3
  } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $pluginStagePath -Encoding UTF8
  Add-Evidence 'json' $pluginStagePath 'Temporary WatchdogCanary plugin staging result'

  foreach ($path in @($runtimeLogPath, $runtimeAuditPath, $runtimeStatusPath)) {
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

    Invoke-BmfConsoleCommand 'bmf.watchdog.fail' 'bmf-watchdog-fail-1' @(
      'BMF bmf.watchdog.fail ERROR WatchdogCanary forced failure 1'
    )
    Invoke-BmfConsoleCommand 'bmf.watchdog.fail' 'bmf-watchdog-fail-2' @(
      'BMF bmf.watchdog.fail ERROR WatchdogCanary forced failure 2'
    )
    Invoke-BmfConsoleCommand 'bmf.watchdog.fail' 'bmf-watchdog-fail-3' @(
      'BMF bmf.watchdog.fail ERROR WatchdogCanary forced failure 3'
    )

    Start-Sleep -Seconds 1
    if (Test-Path -LiteralPath $runtimeStatusPath) {
      Copy-Item -LiteralPath $runtimeStatusPath -Destination $statusIsolatedPath -Force
      Add-Evidence 'json' $statusIsolatedPath 'BMF runtime status after watchdog isolation'
      $status = Read-JsonFile $statusIsolatedPath
      if ([int]$status.plugin_watchdog_isolated -ne 1) {
        $errors.Add("Expected one isolated plugin before reload, got $($status.plugin_watchdog_isolated).")
      }
    } else {
      $errors.Add("BMF runtime status was not written before reload: $runtimeStatusPath")
    }

    Invoke-BmfConsoleCommand 'bmf.watchdog.fail' 'bmf-watchdog-fail-blocked' @(
      'BMF bmf.watchdog.fail PLUGIN_ISOLATED Plugin is isolated by watchdog',
      'plugin=WatchdogCanary',
      'error_count=3',
      'isolated=true'
    )

    Invoke-BmfConsoleCommand 'bmf.plugins.watchdog' 'bmf-plugins-watchdog-isolated' @(
      'BMF bmf.plugins.watchdog OK',
      'watchdog_enabled=true',
      'watchdog_threshold=3',
      'watchdog_isolated=1',
      'plugin_1=WatchdogCanary|errors=3|isolated=true|last_hook=command:bmf.watchdog.fail|last_error=WatchdogCanary forced failure 3'
    )

    Invoke-BmfConsoleCommand 'bmf.plugins' 'bmf-plugins-isolated' @(
      'BMF bmf.plugins OK',
      'plugin=WatchdogCanary version=1.0.0 capabilities=1 errors=3 isolated=true',
      'plugin_errors=3'
    )

    Invoke-BmfConsoleCommand 'bmf.audit.tail limit=50' 'bmf-audit-tail-watchdog' @(
      'BMF bmf.audit.tail OK',
      'plugin.isolated|severity=error|source=plugin|code=PLUGIN_ISOLATED|plugin=WatchdogCanary',
      'command.blocked|severity=warn|source=command|code=PLUGIN_ISOLATED|plugin=WatchdogCanary'
    )

    Invoke-BmfConsoleCommand 'bmf.reload' 'bmf-reload-watchdog' @(
      'BMF bmf.reload OK',
      'plugins_unloaded=1',
      'unload_errors=0',
      'plugins_loaded=1',
      'plugin_errors=0'
    )

    Start-Sleep -Seconds 1
    if (Test-Path -LiteralPath $runtimeStatusPath) {
      Copy-Item -LiteralPath $runtimeStatusPath -Destination $statusReloadPath -Force
      Add-Evidence 'json' $statusReloadPath 'BMF runtime status after watchdog reload recovery'
      $status = Read-JsonFile $statusReloadPath
      if ([int]$status.plugin_watchdog_isolated -ne 0) {
        $errors.Add("Expected zero isolated plugins after reload, got $($status.plugin_watchdog_isolated).")
      }
    } else {
      $errors.Add("BMF runtime status was not written after reload: $runtimeStatusPath")
    }

    Invoke-BmfConsoleCommand 'bmf.plugins.watchdog' 'bmf-plugins-watchdog-after-reload' @(
      'BMF bmf.plugins.watchdog OK',
      'watchdog_enabled=true',
      'watchdog_threshold=3',
      'watchdog_isolated=0',
      'plugin_1=WatchdogCanary|errors=0|isolated=false|last_hook=|last_error='
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
  Add-Evidence 'log' $bmfLogPath 'BMF runtime log with watchdog evidence'
  $logText = Get-Content -Raw -LiteralPath $bmfLogPath
  foreach ($needle in @(
    'plugin WatchdogCanary command:bmf.watchdog.fail failed: WatchdogCanary forced failure 1',
    'plugin WatchdogCanary isolated by watchdog errors=3 threshold=3',
    'WatchdogCanary onUnload'
  )) {
    if ($logText -notmatch [regex]::Escape($needle)) {
      $errors.Add("BMF log missing expected line: $needle")
    }
  }
} else {
  $errors.Add("BMF runtime log was not written: $runtimeLogPath")
}

if (Test-Path -LiteralPath $runtimeAuditPath) {
  Copy-Item -LiteralPath $runtimeAuditPath -Destination $auditPath -Force
  Add-Evidence 'jsonl' $auditPath 'BMF audit JSONL with watchdog isolation records'
  $records = @()
  foreach ($line in [System.IO.File]::ReadAllLines($auditPath)) {
    if ($line.Trim()) {
      $records += ($line | ConvertFrom-Json)
    }
  }
  $records | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $auditParsedPath -Encoding UTF8
  Add-Evidence 'json' $auditParsedPath 'Parsed watchdog audit records'
  $isolated = @($records | Where-Object { $_.action -eq 'plugin.isolated' -and $_.code -eq 'PLUGIN_ISOLATED' -and $_.plugin -eq 'WatchdogCanary' })
  if ($isolated.Count -lt 1) {
    $errors.Add("Expected at least one plugin.isolated audit record for WatchdogCanary.")
  }
  $blocked = @($records | Where-Object { $_.action -eq 'command.blocked' -and $_.code -eq 'PLUGIN_ISOLATED' -and $_.plugin -eq 'WatchdogCanary' })
  if ($blocked.Count -lt 1) {
    $errors.Add("Expected at least one command.blocked audit record for WatchdogCanary.")
  }
} else {
  $errors.Add("BMF audit log was not written: $runtimeAuditPath")
}

if (Test-Path -LiteralPath $runtimePluginLogPath) {
  Copy-Item -LiteralPath $runtimePluginLogPath -Destination $pluginLogPath -Force
  Add-Evidence 'log' $pluginLogPath 'WatchdogCanary per-plugin log'
  $pluginLog = Get-Content -Raw -LiteralPath $pluginLogPath
  if ($pluginLog -match 'forced failure 4') {
    $errors.Add("Fourth watchdog command reached plugin handler; expected PLUGIN_ISOLATED block before handler.")
  }
} else {
  $errors.Add("Plugin log was not written: $runtimePluginLogPath")
}

$resultStatus = 'failed'
if ($errors.Count -eq 0) {
  $resultStatus = 'passed'
}

$result = [ordered]@{
  feature = 'bmf.plugins.watchdog'
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
