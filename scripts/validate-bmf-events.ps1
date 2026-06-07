param(
  [string]$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
  [string]$BrickadiaRoot = '',
  [string]$RuntimeModsDir = 'C:\Users\tycox\AppData\Roaming\omegga\steam_installs\main\Brickadia\Binaries\Win64\ue4ss\main\Mods',
  [string]$OutJson = '',
  [int]$Port = 7839,
  [int]$WaitAfterSaveSeconds = 8,
  [switch]$AllowSharedRuntimeMutation
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
$runtimeEventPath = Join-Path $runtimeBmfDir 'runtime/events.jsonl'
$runtimePluginLogPath = Join-Path $runtimeBmfDir 'runtime/logs/plugins/EventCanary.log'
$runtimeStatusPath = Join-Path $runtimeBmfDir 'runtime/status.json'
$worldsDir = Join-Path $BrickadiaRoot 'omegga-master/omegga-master/data/Saved/Worlds'
$saveName = 'BMF_EventCanarySave_{0}' -f (Get-Date -Format 'yyyyMMddHHmmss')
$savedWorldPath = Join-Path $worldsDir ($saveName + '.brdb')
$bridgeDir = Join-Path $caseRoot "bridge-$Port"
$startPath = Join-Path $caseRoot 'server-start.json'
$pluginStagePath = Join-Path $caseRoot 'event-plugin-stage.json'
$bmfLogPath = Join-Path $caseRoot 'bmf.log'
$eventLogPath = Join-Path $caseRoot 'events.jsonl'
$pluginLogPath = Join-Path $caseRoot 'EventCanary.log'
$statusPath = Join-Path $caseRoot 'status.json'
$runtimeBackupDir = Join-Path $caseRoot 'runtime-bmf-before-test'
$serverPid = $null
$runtimeHadExistingBmf = $false
$runtimeBackupReady = $false
$validationStarted = $false

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

function Assert-SafeRuntimeMutation {
  $runtimeModsFullPath = [System.IO.Path]::GetFullPath($RuntimeModsDir)
  $standardRuntimeModsDir = Join-Path (
    Join-Path $env:APPDATA 'omegga\steam_installs\main\Brickadia\Binaries\Win64'
  ) 'ue4ss\main\Mods'
  $standardRuntimeModsFullPath = [System.IO.Path]::GetFullPath($standardRuntimeModsDir)
  $isSharedOmeggaRuntime = $runtimeModsFullPath.Equals(
    $standardRuntimeModsFullPath,
    [System.StringComparison]::OrdinalIgnoreCase
  )

  if ($isSharedOmeggaRuntime) {
    $conflicts = @(
      Get-CimInstance Win32_Process |
        Where-Object {
          $_.Name -eq 'BrickadiaServer-Win64-Shipping.exe' -and
          $_.CommandLine -notlike "*-port=*$Port*"
        }
    )
    if ($conflicts.Count -gt 0) {
      $ports = @(
        $conflicts |
          ForEach-Object {
            if ($_.CommandLine -match '-port=\\?"?([0-9]+)') { $Matches[1] } else { "pid:$($_.ProcessId)" }
          }
      )
      if ($AllowSharedRuntimeMutation) {
        throw (
          "Refusing to run shared-runtime validation while another Brickadia server is active " +
          "(ports/processes: $($ports -join ', ')). BMF runtime command files are shared across " +
          "those processes, so the live server can consume validation requests. Stop the live server first."
        )
      }
      throw (
        "Refusing to replace the shared Omegga BMF runtime while another Brickadia server is active " +
        "(ports/processes: $($ports -join ', ')). Stop the live server first or pass -AllowSharedRuntimeMutation."
      )
    }
  }
}

function Backup-RuntimeBmf {
  $caseRootFullPath = [System.IO.Path]::GetFullPath($caseRoot)
  $backupFullPath = [System.IO.Path]::GetFullPath($runtimeBackupDir)
  if (!$backupFullPath.StartsWith($caseRootFullPath, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to write runtime backup outside case root: $backupFullPath"
  }

  if (Test-Path -LiteralPath $runtimeBackupDir) {
    Remove-Item -LiteralPath $runtimeBackupDir -Recurse -Force
  }

  if (Test-Path -LiteralPath $runtimeBmfDir) {
    $script:runtimeHadExistingBmf = $true
    Copy-Item -LiteralPath $runtimeBmfDir -Destination $runtimeBackupDir -Recurse -Force
  } else {
    $script:runtimeHadExistingBmf = $false
  }
  $script:runtimeBackupReady = $true
}

function Restore-RuntimeBmf {
  if (!$script:runtimeBackupReady) {
    return
  }

  $runtimeBmfFullPath = [System.IO.Path]::GetFullPath($runtimeBmfDir)
  $runtimeModsFullPath = [System.IO.Path]::GetFullPath($RuntimeModsDir)
  if (!$runtimeBmfFullPath.StartsWith($runtimeModsFullPath, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to restore unexpected BMF runtime path: $runtimeBmfFullPath"
  }

  if (Test-Path -LiteralPath $runtimeBmfDir) {
    Remove-Item -LiteralPath $runtimeBmfDir -Recurse -Force
  }
  if ($script:runtimeHadExistingBmf) {
    Copy-Item -LiteralPath $runtimeBackupDir -Destination $runtimeBmfDir -Recurse -Force
  }
}

function Invoke-BmfConsoleCommand([string]$Command, [string]$Slug, [string[]]$ExpectedLines, [bool]$ExpectOk = $true) {
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
  if ($ExpectOk -and $joined -notmatch '^ok=true') {
    $script:errors.Add("BMF response did not report ok=true for command: $Command")
  }
  if (!$ExpectOk -and $joined -notmatch '^ok=false') {
    $script:errors.Add("BMF response did not report ok=false for command: $Command")
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

  Assert-SafeRuntimeMutation
  Backup-RuntimeBmf
  $validationStarted = $true

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
  if (Test-Path -LiteralPath $runtimeEventPath) {
    Remove-Item -LiteralPath $runtimeEventPath -Force
  }
  if (Test-Path -LiteralPath $runtimeStatusPath) {
    Remove-Item -LiteralPath $runtimeStatusPath -Force
  }
  if (Test-Path -LiteralPath $savedWorldPath) {
    Remove-Item -LiteralPath $savedWorldPath -Force
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

    Invoke-BmfConsoleCommand 'bmf.minigames.events.emit event=joinminigame player=EventKiller playerid=11111111-1111-4111-8111-111111111111 minigame=CityRPG index=0 source=validator' 'bmf-minigame-event-join-emit' @(
      'BMF bmf.minigames.events.emit OK',
      'event=minigames.joinminigame',
      'legacy_event=joinminigame',
      'code=OK'
    )

    Invoke-BmfConsoleCommand 'bmf.minigames.events.emit event=kill player=EventKiller playerid=11111111-1111-4111-8111-111111111111 minigame=CityRPG index=0 leaderboard=0,1,0 oldleaderboard=0,0,0 source=validator' 'bmf-minigame-event-emit' @(
      'BMF bmf.minigames.events.emit OK',
      'event=minigames.kill',
      'legacy_event=kill',
      'count=1',
      'code=OK'
    )

    Invoke-BmfConsoleCommand 'bmf.minigames.events.status' 'bmf-minigame-event-status' @(
      'BMF bmf.minigames.events.status OK',
      'total=',
      'joinminigame=',
      'kill=',
      'last_event=minigames.'
    )

    Invoke-BmfConsoleCommand 'bmf.minigames.events.recent event=kill limit=5' 'bmf-minigame-events-recent' @(
      'BMF bmf.minigames.events.recent OK',
      'total=',
      'returned=',
      'events_json='
    )

    Invoke-BmfConsoleCommand 'bmf.minigames.events.canary event=join' 'bmf-minigame-events-canary' @(
      'BMF bmf.minigames.events.canary OK',
      'event=minigames.joinminigame',
      'legacy_event=joinminigame',
      'handler_calls=1',
      'handler_legacy=joinminigame',
      'listener_removed=true',
      'data_restored=true',
      'metadata_legacy_event=joinminigame',
      'metadata_player_key=33333333-3333-4333-8333-333333333333',
      'metadata_minigame_key=name:CanaryArena#0',
      'handler_metadata_event_id=',
      'handler_metadata_player_key=33333333-3333-4333-8333-333333333333',
      'handler_metadata_minigame_key=name:CanaryArena#0'
    )

    Invoke-BmfConsoleCommand 'bmf.minigames.data.status' 'bmf-minigame-data-status' @(
      'BMF bmf.minigames.data.status OK',
      'total_updates=',
      'minigames=',
      'players=',
      'memberships=',
      'leaderboards=',
      'last_event=minigames.'
    )

    Invoke-BmfConsoleCommand 'bmf.minigames.data.snapshot' 'bmf-minigame-data-snapshot' @(
      'BMF bmf.minigames.data.snapshot OK',
      'total_updates=',
      'minigames=',
      'players=',
      'memberships=',
      'leaderboards=',
      'snapshot_json='
    )

    Invoke-BmfConsoleCommand 'bmf.minigames.data.list name=CityRPG index=0' 'bmf-minigame-data-list' @(
      'BMF bmf.minigames.data.list OK',
      'minigames=1',
      'returned=1',
      'minigame_1=name:CityRPG#0',
      'list_json='
    )

    Invoke-BmfConsoleCommand 'bmf.minigames.data.get name=CityRPG index=0' 'bmf-minigame-data-get' @(
      'BMF bmf.minigames.data.get OK',
      'key=name:CityRPG#0',
      'name=CityRPG',
      'index=0',
      'members=',
      'leaderboards=1',
      'matches=1',
      'minigame_json='
    )

    Invoke-BmfConsoleCommand 'bmf.minigames.data.players minigame=CityRPG index=0' 'bmf-minigame-data-players' @(
      'BMF bmf.minigames.data.players OK',
      'players=1',
      'returned=1',
      'player_1=11111111-1111-4111-8111-111111111111',
      'players_json='
    )

    Invoke-BmfConsoleCommand 'bmf.minigames.data.teams minigame=CityRPG index=0' 'bmf-minigame-data-teams' @(
      'BMF bmf.minigames.data.teams OK',
      'teams=0',
      'returned=0',
      'teams_json='
    )

    Invoke-BmfConsoleCommand 'bmf.minigames.data.leaderboard minigame=CityRPG index=0' 'bmf-minigame-data-leaderboard' @(
      'BMF bmf.minigames.data.leaderboard OK',
      'leaderboards=1',
      'returned=1',
      'leaderboard_1=11111111-1111-4111-8111-111111111111|name=EventKiller|score=0|values=3|minigame=name:CityRPG#0',
      'leaderboards_json='
    )

    Invoke-BmfConsoleCommand 'bmf.minigames.data.player player=EventKiller' 'bmf-minigame-data-player' @(
      'BMF bmf.minigames.data.player OK',
      'player_key=11111111-1111-4111-8111-111111111111',
      'player_name=EventKiller',
      'minigame_key=name:CityRPG#0',
      'leaderboard_values=3',
      'player_json='
    )

    Invoke-BmfConsoleCommand 'bmf.minigames.data.playerstate player=EventKiller' 'bmf-minigame-data-playerstate' @(
      'BMF bmf.minigames.data.playerstate OK',
      'player_key=11111111-1111-4111-8111-111111111111',
      'player_name=EventKiller',
      'in_minigame=true',
      'minigame_key=name:CityRPG#0',
      'activity_minigame_key=name:CityRPG#0',
      'has_leaderboard=true',
      'reason=membership',
      'player_state_json='
    )

    Invoke-BmfConsoleCommand 'bmf.minigames.data.membership player=EventKiller' 'bmf-minigame-data-membership' @(
      'BMF bmf.minigames.data.membership OK',
      'player_key=11111111-1111-4111-8111-111111111111',
      'minigame_key=name:CityRPG#0',
      'membership_found=true',
      'membership_json='
    )

    Invoke-BmfConsoleCommand 'bmf.minigames.events.emit event=leaveminigame player=EventKiller playerid=11111111-1111-4111-8111-111111111111 minigame=CityRPG index=0 source=validator' 'bmf-minigame-event-leave-emit' @(
      'BMF bmf.minigames.events.emit OK',
      'event=minigames.leaveminigame',
      'legacy_event=leaveminigame',
      'code=OK'
    )

    Invoke-BmfConsoleCommand 'bmf.minigames.events.recent event=leave limit=5' 'bmf-minigame-events-recent-leave' @(
      'BMF bmf.minigames.events.recent OK',
      'returned=1',
      'event_1=minigames.leaveminigame',
      'events_json='
    )

    Invoke-BmfConsoleCommand 'bmf.minigames.data.membership player=EventKiller' 'bmf-minigame-data-membership-after-leave' @(
      'BMF bmf.minigames.data.membership MINIGAME_MEMBERSHIP_NOT_FOUND',
      'player_key=11111111-1111-4111-8111-111111111111',
      'minigame_key=',
      'membership_found=false',
      'membership_json='
    )

    Invoke-BmfConsoleCommand 'bmf.minigames.data.playerstate player=EventKiller' 'bmf-minigame-data-playerstate-after-leave' @(
      'BMF bmf.minigames.data.playerstate OK',
      'player_key=11111111-1111-4111-8111-111111111111',
      'in_minigame=false',
      'minigame_key=',
      'activity_minigame_key=name:CityRPG#0',
      'has_leaderboard=true',
      'reason=known-player-no-membership',
      'player_state_json='
    )

    Invoke-BmfConsoleCommand 'bmf.minigames.events.synthetic-flow source=validator-flow' 'bmf-minigame-events-synthetic-flow' @(
      'BMF bmf.minigames.events.synthetic-flow OK',
      'code=OK',
      'source=validator-flow',
      'emitted=8',
      'handler_calls=8',
      'listeners_removed=true',
      'data_restored=true',
      'after_created_minigame=true',
      'after_join_membership=true',
      'after_team_membership=true',
      'after_round_found=true',
      'after_leaderboard_found=true',
      'after_kill_leaderboard=true',
      'after_leave_membership=false',
      'after_delete_minigame=false',
      'after_delete_team=false',
      'after_delete_round=false',
      'after_delete_leaderboard=false',
      'flow_minigames=1',
      'flow_memberships=0',
      'flow_teams=0',
      'flow_leaderboards=1',
      'flow_rounds=0',
      'event_1=minigames.created',
      'event_8=minigames.deleted'
    )

    Invoke-BmfConsoleCommand 'bmf.minigames.data.clear confirm=CLEAR_MINIGAME_DATA' 'bmf-minigame-data-clear' @(
      'BMF bmf.minigames.data.clear OK',
      'code=OK',
      'source=manual-clear',
      'confirm_required=CLEAR_MINIGAME_DATA'
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

if ($validationStarted -and (Test-Path -LiteralPath $runtimeLogPath)) {
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
} elseif ($validationStarted) {
  $errors.Add("BMF runtime log was not written: $runtimeLogPath")
}

if ($validationStarted -and (Test-Path -LiteralPath $runtimeEventPath)) {
  Copy-Item -LiteralPath $runtimeEventPath -Destination $eventLogPath -Force
  Add-Evidence 'jsonl' $eventLogPath 'BMF external event stream with emitted event records'
  $eventText = Get-Content -Raw -LiteralPath $eventLogPath
  foreach ($needle in @(
    '"source":"event"',
    '"message":"event emitted: EventCanary.custom"',
    '"event":"EventCanary.custom"',
    '"message":"event emitted: minigames.kill"',
    '"event":"minigames.kill"',
    '"legacyEvent":"kill"',
    '"message":"event emitted: minigames.leaveminigame"',
    '"event":"minigames.leaveminigame"',
    '"legacyEvent":"leaveminigame"',
    '"message":"event emitted: worldSaved"',
    '"event":"worldSaved"'
  )) {
    if ($eventText -notmatch [regex]::Escape($needle)) {
      $errors.Add("BMF event stream missing expected record text: $needle")
    }
  }
} elseif ($validationStarted) {
  $errors.Add("BMF event stream was not written: $runtimeEventPath")
}

if ($validationStarted -and (Test-Path -LiteralPath $runtimePluginLogPath)) {
  Copy-Item -LiteralPath $runtimePluginLogPath -Destination $pluginLogPath -Force
  Add-Evidence 'log' $pluginLogPath 'EventCanary per-plugin log'
} elseif ($validationStarted) {
  $errors.Add("Plugin log was not written: $runtimePluginLogPath")
}

if ($validationStarted -and (Test-Path -LiteralPath $runtimeStatusPath)) {
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
} elseif ($validationStarted) {
  $errors.Add("BMF runtime status was not written: $runtimeStatusPath")
}

try {
  Restore-RuntimeBmf
} catch {
  $errors.Add("Could not restore pre-validation BMF runtime: $($_.Exception.Message)")
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
