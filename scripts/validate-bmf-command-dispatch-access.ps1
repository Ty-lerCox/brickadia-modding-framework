param(
  [string]$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
  [string]$BrickadiaRoot = '',
  [string]$RuntimeModsDir = 'C:\Users\tycox\AppData\Roaming\omegga\steam_installs\main\Brickadia\Binaries\Win64\ue4ss\main\Mods',
  [string]$OutJson = '',
  [int]$Port = 7852
)

$ErrorActionPreference = 'Stop'

if (!$BrickadiaRoot) {
  $BrickadiaRoot = (Resolve-Path (Join-Path $Root '..\Brickadia')).Path
}
if (!$OutJson) {
  $OutJson = Join-Path $Root 'artifacts/local/bmf-command-dispatch-access-canary.json'
}

$errors = New-Object System.Collections.Generic.List[string]
$evidence = New-Object System.Collections.Generic.List[object]
$commandResults = New-Object System.Collections.Generic.List[object]
$startedAt = (Get-Date).ToUniversalTime().ToString('o')
$outPath = [System.IO.Path]::GetFullPath($OutJson)
$artifactRoot = Split-Path -Parent $outPath
$caseRoot = Join-Path $artifactRoot 'bmf-command-dispatch-access'
New-Item -ItemType Directory -Force -Path $caseRoot | Out-Null

$startServerScript = Join-Path $BrickadiaRoot 'brickadia-ue4ss-re/scripts/start-bridge-test-server.ps1'
$sendRpcScript = Join-Path $BrickadiaRoot 'brickadia-ue4ss-re/scripts/send-bridge-rpc.js'
$sourceBmfDir = Join-Path $Root 'framework/ue4ss/Mods/BMF'
$runtimeBmfDir = Join-Path $RuntimeModsDir 'BMF'
$runtimePluginDir = Join-Path $runtimeBmfDir 'plugins/CommandDispatchAccessCanary'
$runtimeLogPath = Join-Path $runtimeBmfDir 'runtime/bmf.log'
$runtimeAuditPath = Join-Path $runtimeBmfDir 'runtime/audit.jsonl'
$runtimePluginLogPath = Join-Path $runtimeBmfDir 'runtime/logs/plugins/CommandDispatchAccessCanary.log'
$runtimeStatusPath = Join-Path $runtimeBmfDir 'runtime/status.json'
$bridgeDir = Join-Path $caseRoot "bridge-$Port"
$startPath = Join-Path $caseRoot 'server-start.json'
$pluginStagePath = Join-Path $caseRoot 'command-dispatch-access-plugin-stage.json'
$bmfLogPath = Join-Path $caseRoot 'bmf.log'
$auditPath = Join-Path $caseRoot 'audit.jsonl'
$auditParsedPath = Join-Path $caseRoot 'audit.parsed.json'
$pluginLogPath = Join-Path $caseRoot 'CommandDispatchAccessCanary.log'
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
  "name": "CommandDispatchAccessCanary",
  "version": "1.0.0",
  "author": "BMF",
  "description": "Temporary BMF access-checked command dispatch canary plugin.",
  "capabilities": ["plugins.lifecycle"]
}
'@
  Set-Content -LiteralPath (Join-Path $runtimePluginDir 'bmf.json') -Value $manifestSource -Encoding UTF8

  $pluginSource = @'
return {
  name = "CommandDispatchAccessCanary",
  onLoad = function(BMF)
    BMF.commands.register("bmf.secure.echo", "Access-checked echo canary.", function(args)
      return BMF.result(true, "OK", "Secure echo handled", {
        lines = {
          "secure_echo_args=" .. tostring(args or ""),
        },
      })
    end)

    BMF.commands.register("bmf.command.dispatch.access.canary", "Access-checked dispatch canary.", function(args, ar)
      local admin = "11111111-1111-4111-8111-111111111111"
      local guest = "33333333-3333-4333-8333-333333333333"
      local policy = {
        default = "deny",
        console = "allow",
        assignments = {
          savedPlayerRoles = {
            [admin] = { roles = { "Admin" } },
            [guest] = { roles = {} },
          },
        },
        commands = {
          ["bmf.secure.echo"] = { roles = { "Admin" } },
        },
      }

      local allowed = BMF.commands.dispatchWithAccess(policy, admin, "bmf.secure.echo", "allowed", ar)
      local denied = BMF.commands.dispatchWithAccess(policy, guest, "bmf.secure.echo", "denied", ar)
      local console = BMF.commands.dispatchWithAccess(policy, { source = "console" }, "bmf.secure.echo", "console", ar)
      local invalid = BMF.commands.dispatchWithAccess(policy, guest, "../bad", "", ar)
      local api = BMF.apis.get("BMF.commands.dispatchWithAccess")
      local api_label = api.data and api.data.api or {}

      BMF.logInfo("CommandDispatchAccessCanary handled", {
        allowed = allowed,
        denied = denied,
        console = console,
        invalid = invalid,
      })

      return BMF.result(true, "OK", "Access-checked dispatch canary handled", {
        lines = {
          "allowed_dispatch_result=" .. tostring(allowed == true),
          "denied_dispatch_result=" .. tostring(denied == true),
          "console_dispatch_result=" .. tostring(console == true),
          "invalid_dispatch_result=" .. tostring(invalid == true),
          "api_stability=" .. tostring(api_label.stability or ""),
          "api_risk=" .. tostring(api_label.risk or ""),
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
    command = 'bmf.command.dispatch.access.canary'
  } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $pluginStagePath -Encoding UTF8
  Add-Evidence 'json' $pluginStagePath 'Temporary CommandDispatchAccessCanary plugin staging result'

  foreach ($path in @($runtimeLogPath, $runtimeStatusPath, $runtimeAuditPath)) {
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

    Invoke-BmfConsoleCommand 'bmf.command.dispatch.access.canary' 'bmf-command-dispatch-access-canary' @(
      'BMF bmf.command.dispatch.access.canary OK',
      'BMF bmf.secure.echo begin',
      'secure_echo_args=allowed',
      'BMF bmf.secure.echo ACCESS_DENIED role-missing',
      'actor_source=player',
      'actor_uuid=33333333-3333-4333-8333-333333333333',
      'BMF bmf.secure.echo OK Secure echo handled',
      'secure_echo_args=console',
      'BMF ../bad ACCESS_ERROR INVALID_COMMAND',
      'allowed_dispatch_result=true',
      'denied_dispatch_result=true',
      'console_dispatch_result=true',
      'invalid_dispatch_result=false',
      'api_stability=stable',
      'api_risk=medium'
    )

    Invoke-BmfConsoleCommand 'bmf.apis name=BMF.commands.dispatchWithAccess' 'bmf-apis-command-dispatch-access' @(
      'BMF bmf.apis OK',
      'api_count=1',
      'api_1=BMF.commands.dispatchWithAccess|namespace=commands|stability=stable|risk=medium'
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
  Add-Evidence 'log' $bmfLogPath 'BMF runtime log with access-checked dispatch evidence'
  $logText = Get-Content -Raw -LiteralPath $bmfLogPath
  foreach ($needle in @(
    'registered console command bmf.command.dispatch.access.canary',
    'registered console command bmf.secure.echo',
    'CommandDispatchAccessCanary handled'
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
  Add-Evidence 'jsonl' $auditPath 'BMF audit JSONL with command access grant/deny evidence'
  $records = New-Object System.Collections.Generic.List[object]
  foreach ($line in [System.IO.File]::ReadAllLines($auditPath)) {
    if ($line.Trim() -eq '') {
      continue
    }
    try {
      $records.Add(($line | ConvertFrom-Json))
    } catch {
      $errors.Add("Invalid audit JSONL line: $line")
    }
  }
  $records.ToArray() | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $auditParsedPath -Encoding UTF8
  Add-Evidence 'json' $auditParsedPath 'Parsed command access audit records'

  if (!(@($records | Where-Object { $_.action -eq 'command.access_granted' -and $_.code -eq 'ACCESS_GRANTED' }).Count -gt 0)) {
    $errors.Add('Audit log missing command.access_granted ACCESS_GRANTED record.')
  }
  if (!(@($records | Where-Object { $_.action -eq 'command.denied' -and $_.code -eq 'ACCESS_DENIED' }).Count -gt 0)) {
    $errors.Add('Audit log missing command.denied ACCESS_DENIED record.')
  }
  if (!(@($records | Where-Object { $_.action -eq 'command.denied' -and $_.data.reason -eq 'role-missing' }).Count -gt 0)) {
    $errors.Add('Audit log missing command.denied role-missing record.')
  }
} else {
  $errors.Add("BMF audit log was not written: $runtimeAuditPath")
}

if (Test-Path -LiteralPath $runtimePluginLogPath) {
  Copy-Item -LiteralPath $runtimePluginLogPath -Destination $pluginLogPath -Force
  Add-Evidence 'log' $pluginLogPath 'CommandDispatchAccessCanary per-plugin log'
} else {
  $errors.Add("Plugin log was not written: $runtimePluginLogPath")
}

if (Test-Path -LiteralPath $runtimeStatusPath) {
  Copy-Item -LiteralPath $runtimeStatusPath -Destination $statusPath -Force
  Add-Evidence 'json' $statusPath 'BMF runtime status after access-checked dispatch canary'
  try {
    $status = Read-JsonFile $statusPath
    if ([string]$status.state -ne 'running') {
      $errors.Add("Expected runtime status state=running, got $($status.state).")
    }
    if ([int]$status.api_labels -lt 57) {
      $errors.Add("Expected at least 57 API labels, got $($status.api_labels).")
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
  feature = 'bmf.commands.dispatch-access'
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
