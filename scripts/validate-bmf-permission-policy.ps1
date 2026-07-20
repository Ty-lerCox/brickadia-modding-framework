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

$otherServers = @(
  Get-CimInstance Win32_Process |
    Where-Object {
      $_.Name -eq 'BrickadiaServer-Win64-Shipping.exe' -and
      $_.CommandLine -notlike "*-port=`"$Port`"*"
    }
)
if ($otherServers.Count -gt 0) {
  $otherPids = @($otherServers | Select-Object -ExpandProperty ProcessId) -join ','
  throw "Refusing permission-policy canary while another Brickadia server is active (pid=$otherPids); the shared UE4SS Mods directory would collide."
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
$sourceNoSpawnItemPluginDir = Join-Path $Root 'framework/ue4ss/Mods/BMF/plugins/NoSpawnItemApplicator'
$sourceInteractPrefixPluginDir = Join-Path $Root 'framework/ue4ss/Mods/BMF/plugins/InteractConsolePrefixGuard'
$runtimeBmfDir = Join-Path $RuntimeModsDir 'BMF'
$runtimePluginDir = Join-Path $runtimeBmfDir 'plugins/PermissionPolicyCanary'
$runtimeNoSpawnItemPluginDir = Join-Path $runtimeBmfDir 'plugins/NoSpawnItemApplicator'
$runtimeInteractPrefixPluginDir = Join-Path $runtimeBmfDir 'plugins/InteractConsolePrefixGuard'
$runtimeLogPath = Join-Path $runtimeBmfDir 'runtime/bmf.log'
$runtimePluginLogPath = Join-Path $runtimeBmfDir 'runtime/logs/plugins/PermissionPolicyCanary.log'
$runtimeNoSpawnItemPluginLogPath = Join-Path $runtimeBmfDir 'runtime/logs/plugins/NoSpawnItemApplicator.log'
$runtimeInteractPrefixPluginLogPath = Join-Path $runtimeBmfDir 'runtime/logs/plugins/InteractConsolePrefixGuard.log'
$runtimeStatusPath = Join-Path $runtimeBmfDir 'runtime/status.json'
$bridgeDir = Join-Path $caseRoot "bridge-$Port"
$startPath = Join-Path $caseRoot 'server-start.json'
$pluginStagePath = Join-Path $caseRoot 'permission-policy-plugin-stage.json'
$roleSetupCanaryPath = Join-Path $caseRoot 'RoleSetup2.enforce.input.json'
$bmfLogPath = Join-Path $caseRoot 'bmf.log'
$pluginLogPath = Join-Path $caseRoot 'PermissionPolicyCanary.log'
$noSpawnItemPluginLogPath = Join-Path $caseRoot 'NoSpawnItemApplicator.log'
$interactPrefixPluginLogPath = Join-Path $caseRoot 'InteractConsolePrefixGuard.log'
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

function Get-PermissionEntries($Role, [string]$Name) {
  if ($null -eq $Role -or !($Role.PSObject.Properties.Name -contains 'permissions')) {
    return @()
  }
  return @($Role.permissions | Where-Object {
    $null -ne $_ -and ($_.PSObject.Properties.Name -contains 'name') -and [string]$_.name -eq $Name
  })
}

function Assert-NoSpawnItemRolePolicy($Role, [string]$RoleName, [bool]$AllowInheritedSpawnItems = $false) {
  foreach ($permission in @(
    'BR.Permission.Building',
    'BR.Permission.Building.Applicator',
    'BR.Permission.Building.Applicator.EditBricks',
    'BR.Permission.Building.Applicator.EditEntities'
  )) {
    $entries = @(Get-PermissionEntries $Role $permission)
    if ($entries.Count -ne 1 -or [string]$entries[0].state -ne 'Allowed') {
      $script:errors.Add("${RoleName}: expected $permission exactly once with state Allowed.")
    }
  }

  $spawnItems = @(Get-PermissionEntries $Role 'BR.Permission.SpawnItems')
  if ($AllowInheritedSpawnItems) {
    if ($spawnItems.Count -eq 0) {
      return
    }
    if ($spawnItems.Count -ne 1 -or [string]$spawnItems[0].state -ne 'Forbidden') {
      $script:errors.Add("${RoleName}: expected BR.Permission.SpawnItems to be inherited/missing or exactly once with state Forbidden.")
    }
    return
  }

  if ($spawnItems.Count -ne 1 -or [string]$spawnItems[0].state -ne 'Forbidden') {
    $script:errors.Add("${RoleName}: expected BR.Permission.SpawnItems exactly once with state Forbidden.")
  }
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
  foreach ($path in @($startServerScript, $sendRpcScript, $sourceBmfDir, $sourceNoSpawnItemPluginDir, $sourceInteractPrefixPluginDir)) {
    if (!(Test-Path -LiteralPath $path)) {
      throw "Required path does not exist: $path"
    }
  }
  Copy-Item -LiteralPath (Join-Path $Root 'tests/fixtures/roles/default-role.json') -Destination $roleSetupCanaryPath -Force

  if (Test-Path -LiteralPath $runtimeBmfDir) {
    Remove-Item -LiteralPath $runtimeBmfDir -Recurse -Force
  }
  New-Item -ItemType Directory -Force -Path $runtimeBmfDir | Out-Null
  Copy-Item -Path (Join-Path $sourceBmfDir '*') -Destination $runtimeBmfDir -Recurse -Force
  New-Item -ItemType Directory -Force -Path $runtimePluginDir | Out-Null
  New-Item -ItemType Directory -Force -Path $runtimeNoSpawnItemPluginDir | Out-Null
  New-Item -ItemType Directory -Force -Path $runtimeInteractPrefixPluginDir | Out-Null
  Copy-Item -Path (Join-Path $sourceNoSpawnItemPluginDir '*') -Destination $runtimeNoSpawnItemPluginDir -Recurse -Force
  Copy-Item -Path (Join-Path $sourceInteractPrefixPluginDir '*') -Destination $runtimeInteractPrefixPluginDir -Recurse -Force

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
      local denied_component = BMF.permissions.evaluateApplicatorComponentAccess({ component = "SpawnItem" })
      local denied_item_spawn_component = BMF.permissions.evaluateApplicatorComponentAccess({ component = "ItemSpawn" })
      local denied_class_component = BMF.permissions.evaluateApplicatorComponentAccess({ component = "/Script/Brickadia.BRSpawnItemComponent" })
      local allowed_component = BMF.permissions.evaluateApplicatorComponentAccess({ component = "Light" })
      local interact_buyweapon = BMF.permissions.evaluateInteractConsolePrefixAccess({
        tag = "buyweapon:ak",
        actor = { uuid = "player-default", roles = { "Default" } },
        allowedPrefixes = { "buyweapon:" },
        adminRoles = { "Owner", "Admin", "Moderator" },
      })
      local interact_teleport_default = BMF.permissions.evaluateInteractConsolePrefixAccess({
        tag = "teleport:spawn",
        actor = { uuid = "player-default", roles = { "Default" } },
        allowedPrefixes = { "buyweapon:" },
        adminRoles = { "Owner", "Admin", "Moderator" },
      })
      local interact_teleport_admin = BMF.permissions.evaluateInteractConsolePrefixAccess({
        tag = "teleport:spawn",
        actor = { uuid = "player-admin", roles = { "Admin" } },
        allowedPrefixes = { "buyweapon:" },
        adminRoles = { "Owner", "Admin", "Moderator" },
      })
      local interact_teleport_moderator = BMF.permissions.evaluateInteractConsolePrefixAccess({
        tag = "teleport:spawn",
        actor = { uuid = "player-moderator", roles = { "Moderator" } },
        allowedPrefixes = { "buyweapon:" },
        adminRoles = { "Owner", "Admin", "Moderator" },
      })
      local interact_empty = BMF.permissions.evaluateInteractConsolePrefixAccess({
        tag = "",
        actor = { uuid = "player-default", roles = { "Default" } },
        allowedPrefixes = { "buyweapon:" },
        adminRoles = { "Owner", "Admin", "Moderator" },
      })
      local api = BMF.apis.get("BMF.permissions.evaluateNoSpawnItemApplicator")
      local api_label = api.data and api.data.api or {}
      local component_api = BMF.apis.get("BMF.permissions.evaluateApplicatorComponentAccess")
      local component_api_label = component_api.data and component_api.data.api or {}
      local interact_api = BMF.apis.get("BMF.permissions.evaluateInteractConsolePrefixAccess")
      local interact_api_label = interact_api.data and interact_api.data.api or {}
      local live_hook_api = BMF.apis.get("BMF.tools.onApplicatorComponentApply")
      local live_hook_api_label = live_hook_api.data and live_hook_api.data.api or {}
      local live_status_api = BMF.apis.get("BMF.tools.applicator.status")
      local live_status_api_label = live_status_api.data and live_status_api.data.api or {}

      BMF.logInfo("PermissionPolicyCanary handled", {
        before = before.data and before.data.compliant,
        after = after.data and after.data.compliant,
        spawnItemAllowed = denied_component.data and denied_component.data.allowed,
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
          "component_spawn_item_allowed=" .. tostring(denied_component.data and denied_component.data.allowed),
          "component_spawn_item_decision=" .. tostring(denied_component.data and denied_component.data.decision or ""),
          "component_spawn_item_key=" .. tostring(denied_component.data and denied_component.data.componentKey or ""),
          "component_item_spawn_allowed=" .. tostring(denied_item_spawn_component.data and denied_item_spawn_component.data.allowed),
          "component_item_spawn_key=" .. tostring(denied_item_spawn_component.data and denied_item_spawn_component.data.componentKey or ""),
          "component_class_allowed=" .. tostring(denied_class_component.data and denied_class_component.data.allowed),
          "component_light_allowed=" .. tostring(allowed_component.data and allowed_component.data.allowed),
          "component_light_decision=" .. tostring(allowed_component.data and allowed_component.data.decision or ""),
          "interact_buyweapon_allowed=" .. tostring(interact_buyweapon.data and interact_buyweapon.data.allowed),
          "interact_buyweapon_decision=" .. tostring(interact_buyweapon.data and interact_buyweapon.data.decision or ""),
          "interact_buyweapon_matched_prefix=" .. tostring(interact_buyweapon.data and interact_buyweapon.data.matchedPrefix or ""),
          "interact_teleport_default_allowed=" .. tostring(interact_teleport_default.data and interact_teleport_default.data.allowed),
          "interact_teleport_default_decision=" .. tostring(interact_teleport_default.data and interact_teleport_default.data.decision or ""),
          "interact_teleport_admin_allowed=" .. tostring(interact_teleport_admin.data and interact_teleport_admin.data.allowed),
          "interact_teleport_admin_decision=" .. tostring(interact_teleport_admin.data and interact_teleport_admin.data.decision or ""),
          "interact_teleport_admin_matched_role=" .. tostring(interact_teleport_admin.data and interact_teleport_admin.data.matchedRole or ""),
          "interact_teleport_moderator_allowed=" .. tostring(interact_teleport_moderator.data and interact_teleport_moderator.data.allowed),
          "interact_teleport_moderator_decision=" .. tostring(interact_teleport_moderator.data and interact_teleport_moderator.data.decision or ""),
          "interact_teleport_moderator_matched_role=" .. tostring(interact_teleport_moderator.data and interact_teleport_moderator.data.matchedRole or ""),
          "interact_empty_allowed=" .. tostring(interact_empty.data and interact_empty.data.allowed),
          "interact_empty_decision=" .. tostring(interact_empty.data and interact_empty.data.decision or ""),
          "api_stability=" .. tostring(api_label.stability or ""),
          "api_risk=" .. tostring(api_label.risk or ""),
          "component_api_stability=" .. tostring(component_api_label.stability or ""),
          "component_api_risk=" .. tostring(component_api_label.risk or ""),
          "interact_api_stability=" .. tostring(interact_api_label.stability or ""),
          "interact_api_risk=" .. tostring(interact_api_label.risk or ""),
          "live_hook_api_stability=" .. tostring(live_hook_api_label.stability or ""),
          "live_hook_api_risk=" .. tostring(live_hook_api_label.risk or ""),
          "live_hook_api_capability=" .. tostring(live_hook_api_label.capability or ""),
          "live_status_api_stability=" .. tostring(live_status_api_label.stability or ""),
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
    noSpawnItemPluginDir = [System.IO.Path]::GetFullPath($runtimeNoSpawnItemPluginDir)
    interactPrefixPluginDir = [System.IO.Path]::GetFullPath($runtimeInteractPrefixPluginDir)
    roleSetupCanaryPath = [System.IO.Path]::GetFullPath($roleSetupCanaryPath)
    command = 'bmf.permission.policy.canary'
    exampleCommands = @('bmf.nospawnitem.status', 'bmf.nospawnitem.check', 'bmf.interactprefix.status', 'bmf.interactprefix.check')
  } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $pluginStagePath -Encoding UTF8
  Add-Evidence 'json' $pluginStagePath 'Temporary PermissionPolicyCanary plugin staging result'

  foreach ($path in @($runtimeLogPath, $runtimeStatusPath)) {
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
      'component_spawn_item_allowed=false',
      'component_spawn_item_decision=component-denied',
      'component_spawn_item_key=spawnitem',
      'component_item_spawn_allowed=false',
      'component_item_spawn_key=itemspawn',
      'component_class_allowed=false',
      'component_light_allowed=true',
      'component_light_decision=component-allowed',
      'interact_buyweapon_allowed=true',
      'interact_buyweapon_decision=prefix-allowed',
      'interact_buyweapon_matched_prefix=buyweapon:',
      'interact_teleport_default_allowed=false',
      'interact_teleport_default_decision=prefix-denied',
      'interact_teleport_admin_allowed=true',
      'interact_teleport_admin_decision=admin-bypass',
      'interact_teleport_admin_matched_role=Admin',
      'interact_teleport_moderator_allowed=true',
      'interact_teleport_moderator_decision=admin-bypass',
      'interact_teleport_moderator_matched_role=Moderator',
      'interact_empty_allowed=true',
      'interact_empty_decision=empty-allowed',
      'api_stability=stable',
      'api_risk=medium',
      'component_api_stability=stable',
      'component_api_risk=low',
      'interact_api_stability=stable',
      'interact_api_risk=medium',
      'live_hook_api_stability=experimental',
      'live_hook_api_risk=unsafe-native',
      'live_hook_api_capability=tools.applicator',
      'live_status_api_stability=experimental'
    )

    Invoke-BmfConsoleCommand 'bmf.apis name=BMF.permissions.evaluateNoSpawnItemApplicator' 'bmf-apis-permission-policy' @(
      'BMF bmf.apis OK',
      'api_count=1',
      'api_1=BMF.permissions.evaluateNoSpawnItemApplicator|namespace=permissions|stability=stable|risk=medium'
    )

    Invoke-BmfConsoleCommand 'bmf.apis name=BMF.permissions.evaluateApplicatorComponentAccess' 'bmf-apis-applicator-component-policy' @(
      'BMF bmf.apis OK',
      'api_count=1',
      'api_1=BMF.permissions.evaluateApplicatorComponentAccess|namespace=permissions|stability=stable|risk=low'
    )

    Invoke-BmfConsoleCommand 'bmf.apis name=BMF.permissions.evaluateInteractConsolePrefixAccess' 'bmf-apis-interact-console-prefix-policy' @(
      'BMF bmf.apis OK',
      'api_count=1',
      'api_1=BMF.permissions.evaluateInteractConsolePrefixAccess|namespace=permissions|stability=stable|risk=medium'
    )

    Invoke-BmfConsoleCommand 'bmf.apis name=BMF.tools.onApplicatorComponentApply' 'bmf-apis-applicator-live-hook' @(
      'BMF bmf.apis OK',
      'api_count=1',
      'api_1=BMF.tools.onApplicatorComponentApply|namespace=tools|stability=experimental|risk=unsafe-native',
      'requires_player=true',
      'capability=tools.applicator'
    )

    Invoke-BmfConsoleCommand 'bmf.tools.applicator.status refresh=true' 'bmf-tools-applicator-status' @(
      'BMF bmf.tools.applicator.status OK',
      'registered=',
      'handler_count=1',
      'denied_events=0',
      'param_null_events=0',
      'cache_count=',
      'trace_path='
    )

    Invoke-BmfConsoleCommand 'bmf.nospawnitem.status' 'bmf-nospawnitem-status' @(
      'BMF bmf.nospawnitem.status OK',
      'policy=noSpawnItemApplicator',
      'role_compliant=true',
      'safe_applicator_allowed=true',
      'spawn_items_permission_state=Forbidden',
      'spawn_item_component_allowed=false',
      'spawn_item_component_decision=component-denied',
      'light_component_allowed=true',
      'live_applicator_hook_available=true',
      'live_hook_code=',
      'applicator_hook_handler_count=1',
      'applicator_hook_denied_events=0',
      'enforcement_code=ROLE_SETUP_PATH_UNAVAILABLE',
      'enforcement_ok=false',
      'enforcement=role-setup-file'
    )

    Invoke-BmfConsoleCommand 'bmf.nospawnitem.check component=SpawnItem' 'bmf-nospawnitem-check-spawnitem' @(
      'BMF bmf.nospawnitem.check OK',
      'component=SpawnItem',
      'allowed=false',
      'decision=component-denied',
      'matched_component=SpawnItem'
    )

    Invoke-BmfConsoleCommand 'bmf.nospawnitem.check component=ItemSpawn' 'bmf-nospawnitem-check-itemspawn' @(
      'BMF bmf.nospawnitem.check OK',
      'component=ItemSpawn',
      'allowed=false',
      'decision=component-denied',
      'matched_component=ItemSpawn'
    )

    Invoke-BmfConsoleCommand 'bmf.nospawnitem.check component=Light' 'bmf-nospawnitem-check-light' @(
      'BMF bmf.nospawnitem.check OK',
      'component=Light',
      'allowed=true',
      'decision=component-allowed'
    )

    Invoke-BmfConsoleCommand 'bmf.interactprefix.status' 'bmf-interactprefix-status-initial' @(
      'BMF bmf.interactprefix.status OK',
      'code=OK',
      'ok=true',
      'policy=interactConsolePrefixGuard',
      'enforcement=servermodifycomponent-native-prefix-policy',
      'save_time_hook=ufunction-func-native',
      'admin_roles=Admin|Moderator|Owner',
      'allowed_prefixes=buyweapon:',
      'received=0',
      'allowed=0',
      'denied=0'
    )

    Invoke-BmfConsoleCommand 'bmf.interactprefix.check tag=buyweapon%3Aak roles=Default' 'bmf-interactprefix-check-buyweapon' @(
      'BMF bmf.interactprefix.check OK',
      'code=OK',
      'ok=true',
      'tag=buyweapon:ak',
      'allowed=true',
      'decision=prefix-allowed',
      'matched_prefix=buyweapon:'
    )

    Invoke-BmfConsoleCommand 'bmf.interactprefix.check tag=teleport%3Aspawn roles=Default' 'bmf-interactprefix-check-teleport-default' @(
      'BMF bmf.interactprefix.check OK',
      'code=OK',
      'ok=true',
      'tag=teleport:spawn',
      'allowed=false',
      'decision=prefix-denied'
    )

    Invoke-BmfConsoleCommand 'bmf.interactprefix.check tag=teleport%3Aspawn roles=Admin' 'bmf-interactprefix-check-teleport-admin' @(
      'BMF bmf.interactprefix.check OK',
      'code=OK',
      'ok=true',
      'tag=teleport:spawn',
      'allowed=true',
      'decision=admin-bypass',
      'matched_role=Admin'
    )

    Invoke-BmfConsoleCommand 'bmf.interactprefix.check tag=teleport%3Aspawn roles=Moderator' 'bmf-interactprefix-check-teleport-moderator' @(
      'BMF bmf.interactprefix.check OK',
      'code=OK',
      'ok=true',
      'tag=teleport:spawn',
      'allowed=true',
      'decision=admin-bypass',
      'matched_role=Moderator'
    )

    Invoke-BmfConsoleCommand 'bmf.interact.console source=canary player=00000000-0000-0000-0000-000000000001 name=Canary message=buyweapon%3Aak' 'bmf-interact-console-buyweapon' @(
      'BMF bmf.interact.console OK',
      'event=interactConsole',
      'source=canary',
      'player_uuid=00000000-0000-0000-0000-000000000001',
      'player_name=Canary',
      'message=buyweapon:ak',
      'handler_count=1',
      'error_count=0',
      'code=OK',
      'ok=true'
    )

    Invoke-BmfConsoleCommand 'bmf.interact.console source=canary player=00000000-0000-0000-0000-000000000001 name=Canary message=teleport%3Aspawn' 'bmf-interact-console-teleport' @(
      'BMF bmf.interact.console OK',
      'event=interactConsole',
      'source=canary',
      'player_uuid=00000000-0000-0000-0000-000000000001',
      'player_name=Canary',
      'message=teleport:spawn',
      'handler_count=1',
      'error_count=0',
      'code=OK',
      'ok=true'
    )

    Invoke-BmfConsoleCommand 'bmf.interactprefix.status' 'bmf-interactprefix-status-after-events' @(
      'BMF bmf.interactprefix.status OK',
      'code=OK',
      'ok=true',
      'policy=interactConsolePrefixGuard',
      'received=2',
      'allowed=1',
      'denied=1',
      'last_decision=prefix-denied',
      'last_player=00000000-0000-0000-0000-000000000001',
      'last_tag=teleport:spawn'
    )

    $roleSetupCanaryCommandPath = ([System.IO.Path]::GetFullPath($roleSetupCanaryPath)).Replace('\', '/')
    Invoke-BmfConsoleCommand "bmf.permissions.enforce-nospawnitem path=$roleSetupCanaryCommandPath" 'bmf-permissions-enforce-nospawnitem' @(
      'BMF bmf.permissions.enforce-nospawnitem OK',
      'code=OK',
      'ok=true',
      'dry_run=false',
      'changed=true',
      'written=true',
      'patched_role_count=3',
      'role_count=3',
      'patched_roles=Default|Moderator|Admin',
      'restart_required=true',
      'live_hot_reload_supported=false'
    )

    Invoke-BmfConsoleCommand "bmf.permissions.enforce-nospawnitem path=$roleSetupCanaryCommandPath" 'bmf-permissions-enforce-nospawnitem-idempotent' @(
      'BMF bmf.permissions.enforce-nospawnitem OK',
      'code=OK',
      'ok=true',
      'dry_run=false',
      'changed=false',
      'written=false',
      'patched_role_count=0',
      'role_count=3',
      'patched_roles=',
      'restart_required=false',
      'live_hot_reload_supported=false'
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
    'registered console command bmf.nospawnitem.status',
    'registered console command bmf.nospawnitem.check',
    'registered console command bmf.interactprefix.status',
    'registered console command bmf.interactprefix.check',
    'registered console command bmf.interactprefix.handle',
    'NoSpawnItemApplicator loaded',
    'InteractConsolePrefixGuard loaded',
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

if (Test-Path -LiteralPath $runtimeNoSpawnItemPluginLogPath) {
  Copy-Item -LiteralPath $runtimeNoSpawnItemPluginLogPath -Destination $noSpawnItemPluginLogPath -Force
  Add-Evidence 'log' $noSpawnItemPluginLogPath 'NoSpawnItemApplicator per-plugin log'
} else {
  $errors.Add("Plugin log was not written: $runtimeNoSpawnItemPluginLogPath")
}

if (Test-Path -LiteralPath $runtimeInteractPrefixPluginLogPath) {
  Copy-Item -LiteralPath $runtimeInteractPrefixPluginLogPath -Destination $interactPrefixPluginLogPath -Force
  Add-Evidence 'log' $interactPrefixPluginLogPath 'InteractConsolePrefixGuard per-plugin log'
} else {
  $errors.Add("Plugin log was not written: $runtimeInteractPrefixPluginLogPath")
}

if (Test-Path -LiteralPath $roleSetupCanaryPath) {
  Add-Evidence 'json' $roleSetupCanaryPath 'RoleSetup2 copy patched by bmf.permissions.enforce-nospawnitem'
  try {
    $roleSetup = Read-JsonFile $roleSetupCanaryPath
    Assert-NoSpawnItemRolePolicy $roleSetup.defaultRole 'Default'
    foreach ($role in @($roleSetup.roles)) {
      Assert-NoSpawnItemRolePolicy $role ([string]$role.name) $true
    }
  } catch {
    $errors.Add("Could not parse patched RoleSetup2 canary: $($_.Exception.Message)")
  }

  $backupFiles = @(Get-ChildItem -LiteralPath (Split-Path -Parent $roleSetupCanaryPath) -Filter 'RoleSetup2.enforce.input.json.bmf-backup-*.json' -File -ErrorAction SilentlyContinue)
  if ($backupFiles.Count -lt 1) {
    $errors.Add("Expected a RoleSetup2 backup file for enforce canary.")
  } else {
    Add-Evidence 'json' $backupFiles[0].FullName 'RoleSetup2 backup from no-spawn-item enforcer'
  }
} else {
  $errors.Add("RoleSetup2 enforce canary file was not written: $roleSetupCanaryPath")
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
  feature = 'bmf.permissions.no-spawn-item-and-interact-prefix-policy'
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
