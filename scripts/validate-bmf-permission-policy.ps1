param(
  [string]$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
  [string]$BrickadiaRoot = '',
  [string]$RuntimeModsDir = 'C:\Users\tycox\AppData\Roaming\omegga\steam_installs\main\Brickadia\Binaries\Win64\ue4ss\main\Mods',
  [string]$OutJson = '',
  [int]$Port = 7849
)

$ErrorActionPreference = 'Stop'

if (!$BrickadiaRoot) {
  $BrickadiaRoot = (Resolve-Path (Join-Path $Root '..\Brickadia')).Path
}
if (!$OutJson) {
  $OutJson = Join-Path $Root 'artifacts/local/bmf-permission-policy-canary.json'
}

$errors = New-Object System.Collections.Generic.List[string]
$evidence = New-Object System.Collections.Generic.List[object]
$commandResults = New-Object System.Collections.Generic.List[object]
$startedAt = (Get-Date).ToUniversalTime().ToString('o')
$outPath = [System.IO.Path]::GetFullPath($OutJson)
$artifactRoot = Split-Path -Parent $outPath
$caseRoot = Join-Path $artifactRoot 'bmf-permission-policy'
New-Item -ItemType Directory -Force -Path $caseRoot | Out-Null

$startServerScript = Join-Path $BrickadiaRoot 'brickadia-ue4ss-re/scripts/start-bridge-test-server.ps1'
$sendRpcScript = Join-Path $BrickadiaRoot 'brickadia-ue4ss-re/scripts/send-bridge-rpc.js'
$sourceBmfDir = Join-Path $Root 'framework/ue4ss/Mods/BMF'
$runtimeBmfDir = Join-Path $RuntimeModsDir 'BMF'
$runtimePluginDir = Join-Path $runtimeBmfDir 'plugins/PermissionPolicyCanary'
$runtimeLogPath = Join-Path $runtimeBmfDir 'runtime/bmf.log'
$runtimePluginLogPath = Join-Path $runtimeBmfDir 'runtime/logs/plugins/PermissionPolicyCanary.log'
$runtimeStatusPath = Join-Path $runtimeBmfDir 'runtime/status.json'
$bridgeDir = Join-Path $caseRoot "bridge-$Port"
$startPath = Join-Path $caseRoot 'server-start.json'
$pluginStagePath = Join-Path $caseRoot 'permission-policy-plugin-stage.json'
$bmfLogPath = Join-Path $caseRoot 'bmf.log'
$pluginLogPath = Join-Path $caseRoot 'PermissionPolicyCanary.log'
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
  "name": "PermissionPolicyCanary",
  "version": "1.0.0",
  "author": "BMF",
  "description": "Temporary BMF permission policy canary plugin.",
  "capabilities": ["plugins.lifecycle"]
}
'@
  Set-Content -LiteralPath (Join-Path $runtimePluginDir 'bmf.json') -Value $manifestSource -Encoding UTF8

  $pluginSource = @'
return {
  name = "PermissionPolicyCanary",
  onLoad = function(BMF)
    BMF.commands.register("bmf.permission.policy.canary", "Permission policy canary.", function()
      local unsafe_role = {
        name = "Default",
        permissions = {
          { name = "BR.Permission.Building", state = "Allowed" },
          { name = "BR.Permission.Building.Applicator", state = "Allowed" },
          { name = "BR.Permission.Building.Applicator.EditBricks", state = "Allowed" },
          { name = "BR.Permission.Building.Applicator.EditEntities", state = "Allowed" },
          { name = "BR.Permission.SpawnItems", state = "Allowed" },
        },
      }
      local duplicate_role = {
        name = "Default",
        permissions = {
          { name = "BR.Permission.Building", state = "Allowed" },
          { name = "BR.Permission.Building", state = "Allowed" },
          { name = "BR.Permission.Building.Applicator", state = "Allowed" },
          { name = "BR.Permission.Building.Applicator.EditBricks", state = "Allowed" },
          { name = "BR.Permission.Building.Applicator.EditEntities", state = "Allowed" },
          { name = "BR.Permission.SpawnItems", state = "Forbidden" },
        },
      }

      local before = BMF.permissions.evaluateNoSpawnItemApplicator(unsafe_role)
      local planned = BMF.permissions.planRolePatch(unsafe_role, { noSpawnItemApplicator = true })
      local after = BMF.permissions.evaluateNoSpawnItemApplicator(planned.data and planned.data.role or {})
      local described = BMF.permissions.describeRole(planned.data and planned.data.role or {})
      local duplicate = BMF.permissions.evaluateNoSpawnItemApplicator(duplicate_role)
      local invalid = BMF.permissions.describeRole(nil)
      local api = BMF.apis.get("BMF.permissions.evaluateNoSpawnItemApplicator")
      local api_label = api.data and api.data.api or {}

      BMF.logInfo("PermissionPolicyCanary handled", {
        before = before.data and before.data.compliant,
        after = after.data and after.data.compliant,
      })

      return BMF.result(true, "OK", "Permission policy canary handled", {
        lines = {
          "before_compliant=" .. tostring(before.data and before.data.compliant or false),
          "before_spawn_items_state=" .. tostring(before.data and before.data.spawnItemsState or ""),
          "before_safe_applicator_allowed=" .. tostring(before.data and before.data.safeApplicatorAllowed or false),
          "plan_ok=" .. tostring(planned.ok == true),
          "plan_forbidden_count=" .. tostring((planned.data and planned.data.changes and #planned.data.changes.forbidden) or 0),
          "after_compliant=" .. tostring(after.data and after.data.compliant or false),
          "after_spawn_items_forbidden=" .. tostring(after.data and after.data.spawnItemsForbidden or false),
          "after_spawn_items_state=" .. tostring(after.data and after.data.spawnItemsState or ""),
          "after_safe_applicator_allowed=" .. tostring(after.data and after.data.safeApplicatorAllowed or false),
          "after_missing_allowed_count=" .. tostring((after.data and after.data.missingAllowed and #after.data.missingAllowed) or 0),
          "describe_permission_count=" .. tostring((described.data and described.data.permissionCount) or 0),
          "describe_duplicate_count=" .. tostring((described.data and described.data.duplicateCount) or 0),
          "duplicate_compliant=" .. tostring(duplicate.data and duplicate.data.compliant or false),
          "duplicate_count=" .. tostring((duplicate.data and duplicate.data.duplicateCount) or 0),
          "invalid_code=" .. tostring(invalid.code or ""),
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
    command = 'bmf.permission.policy.canary'
  } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $pluginStagePath -Encoding UTF8
  Add-Evidence 'json' $pluginStagePath 'Temporary PermissionPolicyCanary plugin staging result'

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

    Invoke-BmfConsoleCommand 'bmf.permission.policy.canary' 'bmf-permission-policy-canary' @(
      'BMF bmf.permission.policy.canary OK',
      'before_compliant=false',
      'before_spawn_items_state=Allowed',
      'before_safe_applicator_allowed=true',
      'plan_ok=true',
      'plan_forbidden_count=1',
      'after_compliant=true',
      'after_spawn_items_forbidden=true',
      'after_spawn_items_state=Forbidden',
      'after_safe_applicator_allowed=true',
      'after_missing_allowed_count=0',
      'describe_permission_count=5',
      'describe_duplicate_count=0',
      'duplicate_compliant=false',
      'duplicate_count=1',
      'invalid_code=INVALID_ROLE',
      'api_stability=stable',
      'api_risk=medium'
    )

    Invoke-BmfConsoleCommand 'bmf.apis name=BMF.permissions.evaluateNoSpawnItemApplicator' 'bmf-apis-permission-policy' @(
      'BMF bmf.apis OK',
      'api_count=1',
      'api_1=BMF.permissions.evaluateNoSpawnItemApplicator|namespace=permissions|stability=stable|risk=medium'
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
  Add-Evidence 'log' $bmfLogPath 'BMF runtime log with permission policy evidence'
  $logText = Get-Content -Raw -LiteralPath $bmfLogPath
  foreach ($needle in @(
    'registered console command bmf.permission.policy.canary',
    'PermissionPolicyCanary handled'
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
  Add-Evidence 'log' $pluginLogPath 'PermissionPolicyCanary per-plugin log'
} else {
  $errors.Add("Plugin log was not written: $runtimePluginLogPath")
}

if (Test-Path -LiteralPath $runtimeStatusPath) {
  Copy-Item -LiteralPath $runtimeStatusPath -Destination $statusPath -Force
  Add-Evidence 'json' $statusPath 'BMF runtime status after permission policy canary'
  try {
    $status = Read-JsonFile $statusPath
    if ([string]$status.state -ne 'running') {
      $errors.Add("Expected runtime status state=running, got $($status.state).")
    }
    if ([int]$status.api_labels -lt 35) {
      $errors.Add("Expected at least 35 API labels, got $($status.api_labels).")
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
  feature = 'bmf.permissions.no-spawn-item-policy'
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
