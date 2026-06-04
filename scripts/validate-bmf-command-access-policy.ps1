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
  $OutJson = Join-Path $Root 'artifacts/local/bmf-command-access-policy-canary.json'
}

$errors = New-Object System.Collections.Generic.List[string]
$evidence = New-Object System.Collections.Generic.List[object]
$commandResults = New-Object System.Collections.Generic.List[object]
$startedAt = (Get-Date).ToUniversalTime().ToString('o')
$outPath = [System.IO.Path]::GetFullPath($OutJson)
$artifactRoot = Split-Path -Parent $outPath
$caseRoot = Join-Path $artifactRoot 'bmf-command-access-policy'
New-Item -ItemType Directory -Force -Path $caseRoot | Out-Null

$startServerScript = Join-Path $BrickadiaRoot 'brickadia-ue4ss-re/scripts/start-bridge-test-server.ps1'
$sendRpcScript = Join-Path $BrickadiaRoot 'brickadia-ue4ss-re/scripts/send-bridge-rpc.js'
$sourceBmfDir = Join-Path $Root 'framework/ue4ss/Mods/BMF'
$runtimeBmfDir = Join-Path $RuntimeModsDir 'BMF'
$runtimePluginDir = Join-Path $runtimeBmfDir 'plugins/CommandAccessPolicyCanary'
$runtimeLogPath = Join-Path $runtimeBmfDir 'runtime/bmf.log'
$runtimePluginLogPath = Join-Path $runtimeBmfDir 'runtime/logs/plugins/CommandAccessPolicyCanary.log'
$runtimeStatusPath = Join-Path $runtimeBmfDir 'runtime/status.json'
$bridgeDir = Join-Path $caseRoot "bridge-$Port"
$startPath = Join-Path $caseRoot 'server-start.json'
$pluginStagePath = Join-Path $caseRoot 'command-access-policy-plugin-stage.json'
$bmfLogPath = Join-Path $caseRoot 'bmf.log'
$pluginLogPath = Join-Path $caseRoot 'CommandAccessPolicyCanary.log'
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
  "name": "CommandAccessPolicyCanary",
  "version": "1.0.0",
  "author": "BMF",
  "description": "Temporary BMF command access policy canary plugin.",
  "capabilities": ["plugins.lifecycle"]
}
'@
  Set-Content -LiteralPath (Join-Path $runtimePluginDir 'bmf.json') -Value $manifestSource -Encoding UTF8

  $pluginSource = @'
return {
  name = "CommandAccessPolicyCanary",
  onLoad = function(BMF)
    BMF.commands.register("bmf.command.access.canary", "Command access policy canary.", function()
      local admin = "11111111-1111-4111-8111-111111111111"
      local moderator = "22222222-2222-4222-8222-222222222222"
      local guest = "33333333-3333-4333-8333-333333333333"
      local policy = {
        default = "deny",
        console = "allow",
        assignments = {
          savedPlayerRoles = {
            [admin] = { roles = { "Admin" } },
            [moderator] = { roles = { "Moderator" } },
            [guest] = { roles = {} },
          },
        },
        commands = {
          ["BMF.CHAT.Broadcast"] = { roles = { "Admin", "Moderator" } },
          ["bmf.server.save"] = { roles = { "Admin" } },
          ["bmf.players.list"] = { allow = true },
          ["bmf.world.loadadditive"] = { deny = true },
          ["bmf.audit.tail"] = { roles = { "Admin" }, denyRoles = { "MutedStaff" } },
        },
      }

      local admin_save = BMF.permissions.evaluateCommandAccess(policy, admin, "bmf.server.save")
      local moderator_save = BMF.permissions.evaluateCommandAccess(policy, moderator, "bmf.server.save")
      local moderator_broadcast = BMF.permissions.evaluateCommandAccess(policy, moderator, "bmf.chat.broadcast")
      local guest_players_list = BMF.permissions.evaluateCommandAccess(policy, guest, "bmf.players.list")
      local guest_unknown = BMF.permissions.evaluateCommandAccess(policy, guest, "bmf.unknown")
      local console_unknown = BMF.permissions.evaluateCommandAccess(policy, { source = "console" }, "bmf.unknown")
      local denied_command = BMF.permissions.evaluateCommandAccess(policy, guest, "bmf.world.loadadditive")
      local direct_actor = BMF.permissions.evaluateCommandAccess(policy, { roles = { "Moderator" } }, "bmf.chat.broadcast")
      local denied_role = BMF.permissions.evaluateCommandAccess(policy, { roles = { "Admin", "MutedStaff" } }, "bmf.audit.tail")
      local invalid_command = BMF.permissions.evaluateCommandAccess(policy, guest, "../bad")
      local api = BMF.apis.get("BMF.permissions.evaluateCommandAccess")
      local api_label = api.data and api.data.api or {}

      BMF.logInfo("CommandAccessPolicyCanary handled", {
        adminSave = admin_save.data and admin_save.data.allowed,
        moderatorSave = moderator_save.data and moderator_save.data.allowed,
      })

      return BMF.result(true, "OK", "Command access policy canary handled", {
        lines = {
          "admin_save_allowed=" .. tostring(admin_save.data and admin_save.data.allowed or false),
          "admin_save_decision=" .. tostring(admin_save.data and admin_save.data.decision or ""),
          "admin_role_source=" .. tostring(admin_save.data and admin_save.data.roleSource or ""),
          "actor_roles_from_assignments=" .. tostring((admin_save.data and admin_save.data.actorRoles and admin_save.data.actorRoles[1]) or ""),
          "moderator_save_allowed=" .. tostring(moderator_save.data and moderator_save.data.allowed or false),
          "moderator_save_decision=" .. tostring(moderator_save.data and moderator_save.data.decision or ""),
          "moderator_broadcast_allowed=" .. tostring(moderator_broadcast.data and moderator_broadcast.data.allowed or false),
          "moderator_broadcast_decision=" .. tostring(moderator_broadcast.data and moderator_broadcast.data.decision or ""),
          "guest_players_list_allowed=" .. tostring(guest_players_list.data and guest_players_list.data.allowed or false),
          "guest_players_list_decision=" .. tostring(guest_players_list.data and guest_players_list.data.decision or ""),
          "guest_unknown_allowed=" .. tostring(guest_unknown.data and guest_unknown.data.allowed or false),
          "guest_unknown_decision=" .. tostring(guest_unknown.data and guest_unknown.data.decision or ""),
          "console_unknown_allowed=" .. tostring(console_unknown.data and console_unknown.data.allowed or false),
          "console_unknown_decision=" .. tostring(console_unknown.data and console_unknown.data.decision or ""),
          "deny_command_allowed=" .. tostring(denied_command.data and denied_command.data.allowed or false),
          "deny_command_decision=" .. tostring(denied_command.data and denied_command.data.decision or ""),
          "direct_actor_role_allowed=" .. tostring(direct_actor.data and direct_actor.data.allowed or false),
          "direct_actor_role_source=" .. tostring(direct_actor.data and direct_actor.data.roleSource or ""),
          "deny_role_allowed=" .. tostring(denied_role.data and denied_role.data.allowed or false),
          "deny_role_decision=" .. tostring(denied_role.data and denied_role.data.decision or ""),
          "invalid_command_code=" .. tostring(invalid_command.code or ""),
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
    command = 'bmf.command.access.canary'
  } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $pluginStagePath -Encoding UTF8
  Add-Evidence 'json' $pluginStagePath 'Temporary CommandAccessPolicyCanary plugin staging result'

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

    Invoke-BmfConsoleCommand 'bmf.command.access.canary' 'bmf-command-access-policy-canary' @(
      'BMF bmf.command.access.canary OK',
      'admin_save_allowed=true',
      'admin_save_decision=role-allowed',
      'admin_role_source=assignments',
      'actor_roles_from_assignments=Admin',
      'moderator_save_allowed=false',
      'moderator_save_decision=role-missing',
      'moderator_broadcast_allowed=true',
      'moderator_broadcast_decision=role-allowed',
      'guest_players_list_allowed=true',
      'guest_players_list_decision=explicit-allow',
      'guest_unknown_allowed=false',
      'guest_unknown_decision=unknown-command-default-deny',
      'console_unknown_allowed=true',
      'console_unknown_decision=console-source',
      'deny_command_allowed=false',
      'deny_command_decision=explicit-deny',
      'direct_actor_role_allowed=true',
      'direct_actor_role_source=actor',
      'deny_role_allowed=false',
      'deny_role_decision=role-denied',
      'invalid_command_code=INVALID_COMMAND',
      'api_stability=stable',
      'api_risk=medium'
    )

    Invoke-BmfConsoleCommand 'bmf.apis name=BMF.permissions.evaluateCommandAccess' 'bmf-apis-command-access-policy' @(
      'BMF bmf.apis OK',
      'api_count=1',
      'api_1=BMF.permissions.evaluateCommandAccess|namespace=permissions|stability=stable|risk=medium'
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
  Add-Evidence 'log' $bmfLogPath 'BMF runtime log with command access policy evidence'
  $logText = Get-Content -Raw -LiteralPath $bmfLogPath
  foreach ($needle in @(
    'registered console command bmf.command.access.canary',
    'CommandAccessPolicyCanary handled'
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
  Add-Evidence 'log' $pluginLogPath 'CommandAccessPolicyCanary per-plugin log'
} else {
  $errors.Add("Plugin log was not written: $runtimePluginLogPath")
}

if (Test-Path -LiteralPath $runtimeStatusPath) {
  Copy-Item -LiteralPath $runtimeStatusPath -Destination $statusPath -Force
  Add-Evidence 'json' $statusPath 'BMF runtime status after command access policy canary'
  try {
    $status = Read-JsonFile $statusPath
    if ([string]$status.state -ne 'running') {
      $errors.Add("Expected runtime status state=running, got $($status.state).")
    }
    if ([int]$status.api_labels -lt 39) {
      $errors.Add("Expected at least 39 API labels, got $($status.api_labels).")
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
  feature = 'bmf.permissions.command-access-policy'
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
