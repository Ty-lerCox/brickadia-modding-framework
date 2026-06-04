param(
  [string]$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
  [string]$BrickadiaRoot = '',
  [string]$RuntimeModsDir = 'C:\Users\tycox\AppData\Roaming\omegga\steam_installs\main\Brickadia\Binaries\Win64\ue4ss\main\Mods',
  [string]$OutJson = '',
  [int]$Port = 7847
)

$ErrorActionPreference = 'Stop'

if (!$BrickadiaRoot) {
  $BrickadiaRoot = (Resolve-Path (Join-Path $Root '..\Brickadia')).Path
}
if (!$OutJson) {
  $OutJson = Join-Path $Root 'artifacts/local/bmf-unsafe-globals-canary.json'
}

$errors = New-Object System.Collections.Generic.List[string]
$evidence = New-Object System.Collections.Generic.List[object]
$commandResults = New-Object System.Collections.Generic.List[object]
$startedAt = (Get-Date).ToUniversalTime().ToString('o')
$outPath = [System.IO.Path]::GetFullPath($OutJson)
$artifactRoot = Split-Path -Parent $outPath
$caseRoot = Join-Path $artifactRoot 'bmf-unsafe-globals'
New-Item -ItemType Directory -Force -Path $caseRoot | Out-Null

$startServerScript = Join-Path $BrickadiaRoot 'brickadia-ue4ss-re/scripts/start-bridge-test-server.ps1'
$sendRpcScript = Join-Path $BrickadiaRoot 'brickadia-ue4ss-re/scripts/send-bridge-rpc.js'
$sourceBmfDir = Join-Path $Root 'framework/ue4ss/Mods/BMF'
$runtimeBmfDir = Join-Path $RuntimeModsDir 'BMF'
$runtimePluginDir = Join-Path $runtimeBmfDir 'plugins/UnsafeGlobalsCanary'
$runtimeLogPath = Join-Path $runtimeBmfDir 'runtime/bmf.log'
$runtimeAuditPath = Join-Path $runtimeBmfDir 'runtime/audit.jsonl'
$runtimePluginLogPath = Join-Path $runtimeBmfDir 'runtime/logs/plugins/UnsafeGlobalsCanary.log'
$runtimeStatusPath = Join-Path $runtimeBmfDir 'runtime/status.json'
$bridgeDir = Join-Path $caseRoot "bridge-$Port"
$startPath = Join-Path $caseRoot 'server-start.json'
$pluginStagePath = Join-Path $caseRoot 'unsafe-globals-plugin-stage.json'
$bmfLogPath = Join-Path $caseRoot 'bmf.log'
$auditPath = Join-Path $caseRoot 'audit.jsonl'
$auditParsedPath = Join-Path $caseRoot 'audit-parsed.json'
$pluginLogPath = Join-Path $caseRoot 'UnsafeGlobalsCanary.log'
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
  "name": "UnsafeGlobalsCanary",
  "version": "1.0.0",
  "author": "BMF",
  "description": "Temporary BMF unsafe globals canary plugin.",
  "capabilities": ["plugins.lifecycle"]
}
'@
  Set-Content -LiteralPath (Join-Path $runtimePluginDir 'bmf.json') -Value $manifestSource -Encoding UTF8

  $pluginSource = @'
return {
  name = "UnsafeGlobalsCanary",
  onLoad = function(BMF)
    BMF.commands.register("bmf.unsafe.globals.canary", "Unsafe globals canary.", function()
      local raw_console = _G.OmeggaExecuteConsoleManagerInput
      local direct_console = OmeggaExecuteConsoleManagerInput
      local raw_kismet = _G.OmeggaExecuteKismetConsoleCommand
      local raw_cached = _G.OmeggaExecuteCachedConsoleExec
      local raw_game_thread = _G.ExecuteInGameThread
      local raw_delay = _G.ExecuteWithDelay
      local raw_hook = _G.RegisterHook
      local raw_find = _G.StaticFindObject
      local server_exec = BMF.server.exec('Chat.Broadcast "[BMF] unsafe global canary should not run"')
      local policy = BMF.sandbox.policy()
      local denials = BMF.sandbox.denials()
      BMF.logInfo("UnsafeGlobalsCanary handled", {
        denials = denials.data and denials.data.count or 0,
      })
      return BMF.result(true, "OK", "Unsafe globals canary handled", {
        lines = {
          "raw_console_type=" .. type(raw_console),
          "direct_console_type=" .. type(direct_console),
          "raw_kismet_type=" .. type(raw_kismet),
          "raw_cached_type=" .. type(raw_cached),
          "raw_game_thread_type=" .. type(raw_game_thread),
          "raw_delay_type=" .. type(raw_delay),
          "raw_hook_type=" .. type(raw_hook),
          "raw_find_type=" .. type(raw_find),
          "lua_error_type=" .. type(error),
          "bmf_timer_type=" .. type(BMF.timers.after),
          "bmf_sandbox_type=" .. type(BMF.sandbox.policy),
          "server_exec_code=" .. tostring(server_exec.code or ""),
          "unsafe_globals_allowed=" .. tostring(policy.data and policy.data.allowPluginUnsafeGlobals or false),
          "blocked_count_at_least_8=" .. tostring(((policy.data and policy.data.blockedGlobals and #policy.data.blockedGlobals) or 0) >= 8),
          "denials_count_at_least_6=" .. tostring(((denials.data and denials.data.count) or 0) >= 6),
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
    command = 'bmf.unsafe.globals.canary'
  } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $pluginStagePath -Encoding UTF8
  Add-Evidence 'json' $pluginStagePath 'Temporary UnsafeGlobalsCanary plugin staging result'

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

    Invoke-BmfConsoleCommand 'bmf.unsafe.globals.canary' 'bmf-unsafe-globals-canary' @(
      'BMF bmf.unsafe.globals.canary OK',
      'raw_console_type=nil',
      'direct_console_type=nil',
      'raw_kismet_type=nil',
      'raw_cached_type=nil',
      'raw_game_thread_type=nil',
      'raw_delay_type=nil',
      'raw_hook_type=nil',
      'raw_find_type=nil',
      'lua_error_type=function',
      'bmf_timer_type=function',
      'bmf_sandbox_type=function',
      'server_exec_code=CAPABILITY_REQUIRED',
      'unsafe_globals_allowed=false',
      'blocked_count_at_least_8=true',
      'denials_count_at_least_6=true'
    )

    Invoke-BmfConsoleCommand 'bmf.sandbox' 'bmf-sandbox' @(
      'BMF bmf.sandbox OK',
      'unsafe_globals_allowed=false',
      'required_capability=unsafe.globals',
      'blocked_globals_count=',
      'denied_lookup_count=',
      'OmeggaExecuteConsoleManagerInput',
      'ExecuteInGameThread',
      'RegisterHook',
      'StaticFindObject',
      'denial_'
    )

    Invoke-BmfConsoleCommand 'bmf.audit.tail limit=50' 'bmf-audit-tail-unsafe-globals' @(
      'BMF bmf.audit.tail OK',
      'plugin.unsafe_global_denied|severity=warn|source=plugin|code=UNSAFE_GLOBAL_DENIED|plugin=UnsafeGlobalsCanary',
      'capability.denied|severity=warn|source=plugin|code=CAPABILITY_REQUIRED|plugin=UnsafeGlobalsCanary'
    )

    Invoke-BmfConsoleCommand 'bmf.server.status' 'bmf-server-status-unsafe-globals' @(
      'BMF bmf.server.status OK',
      'unsafe_global_denials=',
      'unsafe_globals_allowed=false'
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
  Add-Evidence 'log' $bmfLogPath 'BMF runtime log with unsafe global denial evidence'
  $logText = Get-Content -Raw -LiteralPath $bmfLogPath
  foreach ($needle in @(
    'registered console command bmf.sandbox',
    'plugin UnsafeGlobalsCanary denied unsafe global OmeggaExecuteConsoleManagerInput',
    'plugin UnsafeGlobalsCanary denied unsafe global ExecuteInGameThread',
    'UnsafeGlobalsCanary handled'
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
  Add-Evidence 'jsonl' $auditPath 'BMF audit JSONL with unsafe global denial records'
  $records = @()
  foreach ($line in [System.IO.File]::ReadAllLines($auditPath)) {
    if ($line.Trim()) {
      $records += ($line | ConvertFrom-Json)
    }
  }
  $records | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $auditParsedPath -Encoding UTF8
  Add-Evidence 'json' $auditParsedPath 'Parsed unsafe global audit records'
  $denied = @($records | Where-Object { $_.action -eq 'plugin.unsafe_global_denied' -and $_.code -eq 'UNSAFE_GLOBAL_DENIED' -and $_.plugin -eq 'UnsafeGlobalsCanary' })
  if ($denied.Count -lt 6) {
    $errors.Add("Expected at least six unsafe global denial audit records, got $($denied.Count).")
  }
} else {
  $errors.Add("BMF audit log was not written: $runtimeAuditPath")
}

if (Test-Path -LiteralPath $runtimePluginLogPath) {
  Copy-Item -LiteralPath $runtimePluginLogPath -Destination $pluginLogPath -Force
  Add-Evidence 'log' $pluginLogPath 'UnsafeGlobalsCanary per-plugin log'
} else {
  $errors.Add("Plugin log was not written: $runtimePluginLogPath")
}

if (Test-Path -LiteralPath $runtimeStatusPath) {
  Copy-Item -LiteralPath $runtimeStatusPath -Destination $statusPath -Force
  Add-Evidence 'json' $statusPath 'BMF runtime status after unsafe globals canary'
  try {
    $status = Read-JsonFile $statusPath
    if ([int]$status.plugin_unsafe_global_denials -lt 6) {
      $errors.Add("Expected at least six unsafe global denials, got $($status.plugin_unsafe_global_denials).")
    }
    if ($status.plugin_unsafe_globals_allowed -ne $false) {
      $errors.Add("Expected plugin_unsafe_globals_allowed=false in runtime status.")
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
  feature = 'bmf.plugins.unsafe-globals'
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
