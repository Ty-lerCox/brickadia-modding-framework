param(
  [string]$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
  [string]$BrickadiaRoot = '',
  [string]$RuntimeModsDir = 'C:\Users\tycox\AppData\Roaming\omegga\steam_installs\main\Brickadia\Binaries\Win64\ue4ss\main\Mods',
  [string]$OutJson = '',
  [int]$Port = 7850
)

$ErrorActionPreference = 'Stop'

if (!$BrickadiaRoot) {
  $BrickadiaRoot = (Resolve-Path (Join-Path $Root '..\Brickadia')).Path
}
if (!$OutJson) {
  $OutJson = Join-Path $Root 'artifacts/local/bmf-role-assignments-canary.json'
}

$errors = New-Object System.Collections.Generic.List[string]
$evidence = New-Object System.Collections.Generic.List[object]
$commandResults = New-Object System.Collections.Generic.List[object]
$startedAt = (Get-Date).ToUniversalTime().ToString('o')
$outPath = [System.IO.Path]::GetFullPath($OutJson)
$artifactRoot = Split-Path -Parent $outPath
$caseRoot = Join-Path $artifactRoot 'bmf-role-assignments'
New-Item -ItemType Directory -Force -Path $caseRoot | Out-Null

$startServerScript = Join-Path $BrickadiaRoot 'brickadia-ue4ss-re/scripts/start-bridge-test-server.ps1'
$sendRpcScript = Join-Path $BrickadiaRoot 'brickadia-ue4ss-re/scripts/send-bridge-rpc.js'
$sourceBmfDir = Join-Path $Root 'framework/ue4ss/Mods/BMF'
$runtimeBmfDir = Join-Path $RuntimeModsDir 'BMF'
$runtimePluginDir = Join-Path $runtimeBmfDir 'plugins/RoleAssignmentsCanary'
$runtimeLogPath = Join-Path $runtimeBmfDir 'runtime/bmf.log'
$runtimePluginLogPath = Join-Path $runtimeBmfDir 'runtime/logs/plugins/RoleAssignmentsCanary.log'
$runtimeStatusPath = Join-Path $runtimeBmfDir 'runtime/status.json'
$bridgeDir = Join-Path $caseRoot "bridge-$Port"
$startPath = Join-Path $caseRoot 'server-start.json'
$pluginStagePath = Join-Path $caseRoot 'role-assignments-plugin-stage.json'
$bmfLogPath = Join-Path $caseRoot 'bmf.log'
$pluginLogPath = Join-Path $caseRoot 'RoleAssignmentsCanary.log'
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
  "name": "RoleAssignmentsCanary",
  "version": "1.0.0",
  "author": "BMF",
  "description": "Temporary BMF role assignment reader canary plugin.",
  "capabilities": ["plugins.lifecycle"]
}
'@
  Set-Content -LiteralPath (Join-Path $runtimePluginDir 'bmf.json') -Value $manifestSource -Encoding UTF8

  $pluginSource = @'
return {
  name = "RoleAssignmentsCanary",
  onLoad = function(BMF)
    BMF.commands.register("bmf.role.assignments.canary", "Role assignment reader canary.", function()
      local player_one = "11111111-1111-4111-8111-111111111111"
      local player_two = "22222222-2222-4222-8222-222222222222"
      local player_missing = "33333333-3333-4333-8333-333333333333"
      local assignments = {
        savedPlayerRoles = {
          [player_one] = { roles = { "Admin" } },
          [player_two] = { roles = { "Moderator", "Moderator", "Bad/Role" } },
          ["not-a-uuid"] = { roles = { "Admin" } },
        },
      }

      local described = BMF.permissions.describeRoleAssignments(assignments)
      local one = BMF.permissions.getPlayerRoles(assignments, player_one)
      local one_record = BMF.permissions.getPlayerRoles(assignments, { uuid = player_one })
      local two = BMF.permissions.getPlayerRoles(assignments, player_two)
      local missing = BMF.permissions.getPlayerRoles(assignments, player_missing)
      local invalid = BMF.permissions.getPlayerRoles(assignments, "bad-player-id")
      local has_admin = BMF.permissions.playerHasRole(assignments, player_one, "admin")
      local has_moderator_before = BMF.permissions.playerHasRole(assignments, player_one, "Moderator")
      local planned = BMF.permissions.planPlayerRoleAssignment(assignments, {
        uuid = player_one,
        add = { "Moderator" },
        remove = { "Admin" },
      })
      local planned_roles = BMF.permissions.getPlayerRoles(planned.data and planned.data.assignments or {}, player_one)
      local has_moderator_after = BMF.permissions.playerHasRole(planned.data and planned.data.assignments or {}, player_one, "moderator")
      local api = BMF.apis.get("BMF.permissions.getPlayerRoles")
      local api_label = api.data and api.data.api or {}

      BMF.logInfo("RoleAssignmentsCanary handled", {
        players = described.data and described.data.playerCount,
        player = player_one,
      })

      return BMF.result(true, "OK", "Role assignment reader canary handled", {
        lines = {
          "described_players=" .. tostring((described.data and described.data.playerCount) or 0),
          "described_invalid_players=" .. tostring((described.data and described.data.invalidPlayerCount) or 0),
          "described_duplicate_roles=" .. tostring((described.data and described.data.duplicateRoleCount) or 0),
          "described_invalid_roles=" .. tostring((described.data and described.data.invalidRoleCount) or 0),
          "one_found=" .. tostring(one.data and one.data.found or false),
          "one_role_count=" .. tostring((one.data and one.data.roleCount) or 0),
          "one_first_role=" .. tostring((one.data and one.data.roles and one.data.roles[1]) or ""),
          "one_record_role_count=" .. tostring((one_record.data and one_record.data.roleCount) or 0),
          "two_duplicate_roles=" .. tostring((two.data and two.data.duplicateRoleCount) or 0),
          "two_invalid_roles=" .. tostring((two.data and two.data.invalidRoleCount) or 0),
          "missing_found=" .. tostring(missing.data and missing.data.found or false),
          "missing_role_count=" .. tostring((missing.data and missing.data.roleCount) or 0),
          "invalid_code=" .. tostring(invalid.code or ""),
          "has_admin_before=" .. tostring(has_admin.data and has_admin.data.hasRole or false),
          "has_moderator_before=" .. tostring(has_moderator_before.data and has_moderator_before.data.hasRole or false),
          "planned_ok=" .. tostring(planned.ok == true),
          "planned_role_count=" .. tostring((planned_roles.data and planned_roles.data.roleCount) or 0),
          "planned_first_role=" .. tostring((planned_roles.data and planned_roles.data.roles and planned_roles.data.roles[1]) or ""),
          "has_moderator_after=" .. tostring(has_moderator_after.data and has_moderator_after.data.hasRole or false),
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
    command = 'bmf.role.assignments.canary'
  } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $pluginStagePath -Encoding UTF8
  Add-Evidence 'json' $pluginStagePath 'Temporary RoleAssignmentsCanary plugin staging result'

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

    Invoke-BmfConsoleCommand 'bmf.role.assignments.canary' 'bmf-role-assignments-canary' @(
      'BMF bmf.role.assignments.canary OK',
      'described_players=2',
      'described_invalid_players=1',
      'described_duplicate_roles=1',
      'described_invalid_roles=1',
      'one_found=true',
      'one_role_count=1',
      'one_first_role=Admin',
      'one_record_role_count=1',
      'two_duplicate_roles=1',
      'two_invalid_roles=1',
      'missing_found=false',
      'missing_role_count=0',
      'invalid_code=INVALID_PLAYER_ID',
      'has_admin_before=true',
      'has_moderator_before=false',
      'planned_ok=true',
      'planned_role_count=1',
      'planned_first_role=Moderator',
      'has_moderator_after=true',
      'api_stability=stable',
      'api_risk=low'
    )

    Invoke-BmfConsoleCommand 'bmf.apis name=BMF.permissions.getPlayerRoles' 'bmf-apis-role-assignments' @(
      'BMF bmf.apis OK',
      'api_count=1',
      'api_1=BMF.permissions.getPlayerRoles|namespace=permissions|stability=stable|risk=low'
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
  Add-Evidence 'log' $bmfLogPath 'BMF runtime log with role assignment reader evidence'
  $logText = Get-Content -Raw -LiteralPath $bmfLogPath
  foreach ($needle in @(
    'registered console command bmf.role.assignments.canary',
    'RoleAssignmentsCanary handled'
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
  Add-Evidence 'log' $pluginLogPath 'RoleAssignmentsCanary per-plugin log'
} else {
  $errors.Add("Plugin log was not written: $runtimePluginLogPath")
}

if (Test-Path -LiteralPath $runtimeStatusPath) {
  Copy-Item -LiteralPath $runtimeStatusPath -Destination $statusPath -Force
  Add-Evidence 'json' $statusPath 'BMF runtime status after role assignment reader canary'
  try {
    $status = Read-JsonFile $statusPath
    if ([string]$status.state -ne 'running') {
      $errors.Add("Expected runtime status state=running, got $($status.state).")
    }
    if ([int]$status.api_labels -lt 38) {
      $errors.Add("Expected at least 38 API labels, got $($status.api_labels).")
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
  feature = 'bmf.permissions.role-assignment-readers'
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
