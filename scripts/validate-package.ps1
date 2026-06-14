param(
  [string]$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
  [string]$OutJson = ''
)

$ErrorActionPreference = 'Stop'

$requiredFiles = @(
  'README.md',
  'TODO.md',
  'OVERNIGHT_STRATEGY.md',
  'manifests/bmf-package.json',
  'manifests/compatibility.json',
  'manifests/dependencies.json',
  'manifests/canary.schema.json',
  'cli/README.md',
  'cli/package.json',
  'cli/bin/bmfctl.js',
  'cli/src/cli.js',
  'cli/src/context.js',
  'cli/src/doctor.js',
  'cli/src/file.js',
  'cli/src/format.js',
  'cli/src/index.js',
  'cli/src/mods.js',
  'cli/src/repair.js',
  'cli/src/snapshot.js',
  'cli/test/doctor-repair.test.js',
  'cli/test/helpers.js',
  'cli/test/mods.test.js',
  'cli/test/snapshot.test.js',
  'installer/install-bmf.ps1',
  'installer/uninstall-bmf.ps1',
  'framework/ue4ss/Mods/BMF/bmf.json',
  'framework/ue4ss/Mods/BMF/config.json',
  'framework/ue4ss/Mods/BMF/enabled.txt',
  'framework/ue4ss/Mods/BMF/Scripts/main.lua',
  'framework/ue4ss/Mods/BMFSocket/README.md',
  'framework/ue4ss/Mods/BMFSocket/dlls/.gitkeep',
  'framework/ue4ss/Mods/BMFFrameTelemetry/README.md',
  'framework/ue4ss/Mods/BMFFrameTelemetry/dlls/.gitkeep',
  'examples/AssignRole/bmf.json',
  'examples/AssignRole/main.lua',
  'examples/HelloBroadcast/bmf.json',
  'examples/HelloBroadcast/main.lua',
  'examples/TimedBroadcast/bmf.json',
  'examples/TimedBroadcast/main.lua',
  'examples/LoadThreeCars/bmf.json',
  'examples/LoadThreeCars/main.lua',
  'examples/LoadCarBrz/bmf.json',
  'examples/LoadCarBrz/main.lua',
  'examples/SpawnVehicleSet/bmf.json',
  'examples/SpawnVehicleSet/main.lua',
  'examples/ListMinigames/bmf.json',
  'examples/ListMinigames/main.lua',
  'examples/NoSpawnItemApplicator/bmf.json',
  'examples/NoSpawnItemApplicator/config.json',
  'examples/NoSpawnItemApplicator/main.lua',
  'examples/InteractConsolePrefixGuard/bmf.json',
  'examples/InteractConsolePrefixGuard/config.json',
  'examples/InteractConsolePrefixGuard/main.lua',
  'examples/BrickAssetPlacementGuard/bmf.json',
  'examples/BrickAssetPlacementGuard/config.json',
  'examples/BrickAssetPlacementGuard/main.lua',
  'examples/RuntimeBrickState/bmf.json',
  'examples/RuntimeBrickState/main.lua',
  'examples/WelcomeMessage/bmf.json',
  'examples/WelcomeMessage/main.lua',
  'docs/install/windows.md',
  'docs/architecture/omegga-supported-runtime.md',
  'docs/architecture/standalone-runtime.md',
  'docs/getting-started/first-plugin.md',
  'docs/api/apis.md',
  'docs/api/archives.md',
  'docs/api/audit.md',
  'docs/api/compatibility.md',
  'docs/api/commands.md',
  'docs/api/events.md',
  'docs/api/plugins.md',
  'docs/api/prefabs.md',
  'docs/api/vehicles.md',
  'docs/api/health.md',
  'docs/api/logging.md',
  'docs/api/timers.md',
  'docs/api/chat.md',
  'docs/api/minigames.md',
  'docs/api/players.md',
  'docs/api/permissions.md',
  'docs/api/rate-limits.md',
  'docs/api/server.md',
  'docs/api/world.md',
  'docs/validation/canary-contract.md',
  'tests/fixtures/players/empty.json',
  'tests/fixtures/players/one-player.json',
  'tests/fixtures/players/malformed.json',
  'integrations/omegga/bmf-player-sync/plugin.json',
  'integrations/omegga/bmf-player-sync/doc.json',
  'integrations/omegga/bmf-player-sync/access.json',
  'integrations/omegga/bmf-player-sync/omegga.plugin.js',
  'integrations/omegga/bmf-player-sync/README.md',
  'integrations/omegga/bmf-minigame-events/plugin.json',
  'integrations/omegga/bmf-minigame-events/doc.json',
  'integrations/omegga/bmf-minigame-events/access.json',
  'integrations/omegga/bmf-minigame-events/omegga.plugin.js',
  'integrations/omegga/bmf-minigame-events/omegga.plugin.test.js',
  'integrations/omegga/bmf-minigame-events/README.md',
  'tests/fixtures/roles/default-role.json',
  'tests/fixtures/roles/role-assignments.json',
  'tests/fixtures/server/GameUserSettings.ini',
  'scripts/validate-windows-installer.ps1',
  'scripts/validate-bmfctl.ps1',
  'scripts/build-release-package.ps1',
  'scripts/validate-release-package.ps1',
  'scripts/validate-player-fixtures.ps1',
  'scripts/patch-role-permissions.ps1',
  'scripts/validate-role-permissions.ps1',
  'scripts/patch-role-assignments.ps1',
  'scripts/validate-role-assignments.ps1',
  'scripts/describe-world-archive.ps1',
  'scripts/summarize-vehicle-graphs.ps1',
  'scripts/export-vehicle-inventory.ps1',
  'scripts/validate-vehicle-snapshot.ps1',
  'scripts/snapshot-server-vehicles.ps1',
  'scripts/validate-server-vehicle-snapshot.ps1',
  'scripts/validate-server-multi-vehicle-snapshot.ps1',
  'scripts/remap-staged-vehicle-brdb.js',
  'scripts/validate-server-remapped-duplicate-vehicle-snapshot.ps1',
  'scripts/stage-vehicle-spawn-set.ps1',
  'scripts/validate-server-vehicle-spawn-set.ps1',
  'scripts/validate-bmf-vehicle-spawn-set-runtime.ps1',
  'scripts/validate-bmf-console-commands.ps1',
  'scripts/validate-bmf-vehicle-spawn-set-command.ps1',
  'scripts/validate-bmf-admin-commands.ps1',
  'scripts/validate-bmf-minigame-commands.ps1',
  'scripts/validate-bmf-plugin-lifecycle-storage.ps1',
  'scripts/validate-bmf-plugin-lifecycle-hooks.ps1',
  'scripts/validate-bmf-plugin-command-cleanup.ps1',
  'scripts/validate-bmf-plugin-watchdog.ps1',
  'scripts/validate-bmf-api-labels.ps1',
  'scripts/validate-bmf-compatibility.ps1',
  'scripts/validate-bmf-unsafe-globals.ps1',
  'scripts/validate-bmf-capability-gates.ps1',
  'scripts/validate-bmf-logging.ps1',
  'scripts/validate-bmf-timers.ps1',
  'scripts/validate-bmf-server-status.ps1',
  'scripts/validate-bmf-server-save.ps1',
  'scripts/validate-bmf-server-shutdown.ps1',
  'scripts/validate-bmf-events.ps1',
  'scripts/validate-bmf-audit-log.ps1',
  'scripts/validate-bmf-rate-limits.ps1',
  'scripts/validate-bmf-player-messaging.ps1',
  'scripts/validate-bmf-permission-policy.ps1',
  'scripts/validate-bmf-brick-asset-policy.ps1',
  'scripts/validate-bmf-role-assignments.ps1',
  'scripts/validate-bmf-command-access-policy.ps1',
  'scripts/validate-bmf-command-dispatch-access.ps1',
  'scripts/list-brick-assets.js',
  'scripts/build-brick-asset-prefab-index.js',
  'scripts/build-applicator-blocker-native-hook.ps1',
  'scripts/build-bmf-socket-native-mod.ps1',
  'scripts/build-bmf-frame-telemetry-native-mod.ps1',
  'scripts/inject-applicator-blocker-native-hook.ps1',
  'scripts/sync-applicator-blocker-native-hook.ps1',
  'native/applicator_blocker/applicator_func_blocker.cpp',
  'native/bmf_socket/CMakeLists.txt',
  'native/bmf_socket/bmf_socket.cpp',
  'native/bmf_frame_telemetry/CMakeLists.txt',
  'native/bmf_frame_telemetry/bmf_frame_telemetry.cpp',
  'scripts/sync-placement-guard-native-hook.ps1',
  'native/placement_guard/placement_guard.cpp',
  'scripts/snapshot-bmf-server-vehicles.ps1',
  'scripts/validate-bmf-vehicle-snapshot-command.ps1',
  'scripts/stage-brz-prefab.ps1',
  'scripts/validate-brz-prefab-staging.ps1',
  'scripts/validate-bmf-prefab-runtime.ps1',
  'scripts/validate-bmf-prefab-command.ps1',
  'scripts/validate-bmf-prefab-brdb-command.ps1',
  'scripts/validate-archive-fixtures.ps1',
  'scripts/capture-dynamic-actor-graph.ps1',
  'scripts/validate-dynamic-actor-graphs.ps1',
  'scripts/slice-dynamic-actor-brdb.js',
  'scripts/validate-dynamic-actor-slices.ps1',
  'scripts/validate-dynamic-actor-slice-additive.ps1',
  'scripts/list-minigame-presets.ps1',
  'scripts/patch-server-settings.ps1',
  'scripts/validate-server-settings.ps1'
)

$errors = New-Object System.Collections.Generic.List[string]
$files = New-Object System.Collections.Generic.List[object]

foreach ($relative in $requiredFiles) {
  $path = Join-Path $Root $relative
  if (!(Test-Path -LiteralPath $path)) {
    $errors.Add("Missing required file: $relative")
    continue
  }

  $hash = Get-FileHash -Algorithm SHA256 -LiteralPath $path
  $files.Add([ordered]@{
    path = $relative
    sha256 = $hash.Hash.ToLowerInvariant()
    bytes = (Get-Item -LiteralPath $path).Length
  })
}

foreach ($jsonRelative in @(
  'manifests/bmf-package.json',
  'manifests/compatibility.json',
  'manifests/dependencies.json',
  'manifests/canary.schema.json',
  'cli/package.json',
  'examples/AssignRole/bmf.json',
  'framework/ue4ss/Mods/BMF/bmf.json',
  'framework/ue4ss/Mods/BMF/config.json',
  'examples/HelloBroadcast/bmf.json',
  'examples/TimedBroadcast/bmf.json',
  'examples/LoadThreeCars/bmf.json',
  'examples/LoadCarBrz/bmf.json',
  'examples/SpawnVehicleSet/bmf.json',
  'examples/ListMinigames/bmf.json',
  'examples/NoSpawnItemApplicator/bmf.json',
  'examples/NoSpawnItemApplicator/config.json',
  'examples/InteractConsolePrefixGuard/bmf.json',
  'examples/InteractConsolePrefixGuard/config.json',
  'examples/BrickAssetPlacementGuard/bmf.json',
  'examples/BrickAssetPlacementGuard/config.json',
  'examples/RuntimeBrickState/bmf.json',
  'examples/WelcomeMessage/bmf.json',
  'tests/fixtures/players/empty.json',
  'tests/fixtures/players/one-player.json',
  'tests/fixtures/players/malformed.json',
  'integrations/omegga/bmf-player-sync/plugin.json',
  'integrations/omegga/bmf-player-sync/doc.json',
  'integrations/omegga/bmf-player-sync/access.json',
  'integrations/omegga/bmf-minigame-events/plugin.json',
  'integrations/omegga/bmf-minigame-events/doc.json',
  'integrations/omegga/bmf-minigame-events/access.json',
  'tests/fixtures/roles/default-role.json',
  'tests/fixtures/roles/role-assignments.json'
)) {
  $path = Join-Path $Root $jsonRelative
  if (Test-Path -LiteralPath $path) {
    try {
      Get-Content -Raw -LiteralPath $path | ConvertFrom-Json | Out-Null
    } catch {
      $errors.Add("Invalid JSON in ${jsonRelative}: $($_.Exception.Message)")
    }
  }
}

$standaloneDoc = Join-Path $Root 'docs/architecture/standalone-runtime.md'
if (Test-Path -LiteralPath $standaloneDoc) {
  $source = Get-Content -Raw -LiteralPath $standaloneDoc
  foreach ($needle in @('future independence track', 'BMF Supervisor', 'Omegga Replacement Map', 'first BMF package')) {
    if ($source -notmatch [regex]::Escape($needle)) {
      $errors.Add("standalone-runtime.md does not contain expected marker: $needle")
    }
  }
}

$omeggaRuntimeDoc = Join-Path $Root 'docs/architecture/omegga-supported-runtime.md'
if (Test-Path -LiteralPath $omeggaRuntimeDoc) {
  $source = Get-Content -Raw -LiteralPath $omeggaRuntimeDoc
  foreach ($needle in @('BMF-compatible Omegga runtime', 'Current Contract', 'Omegga.Bridge.BMF', 'OmeggaCallFunctionByNameWithArguments')) {
    if ($source -notmatch [regex]::Escape($needle)) {
      $errors.Add("omegga-supported-runtime.md does not contain expected marker: $needle")
    }
  }
}

$mainLua = Join-Path $Root 'framework/ue4ss/Mods/BMF/Scripts/main.lua'
if (Test-Path -LiteralPath $mainLua) {
  $source = Get-Content -Raw -LiteralPath $mainLua
  foreach ($needle in @('_G.BMF', 'BMF.version', 'BMF.health', 'TARGET_BRICKADIA_BUILD', 'PC-Shipping-CL13530', 'BUILD_DETECTION_MODE', 'declared-target-only', 'UNSUPPORTED_BUILD_POLICY', 'report-only', 'RUNTIME_HELPER_GROUPS', 'compatibility_snapshot', 'BMF.compatibility.check', 'BMF.compatibility.helpers', 'bmf.compatibility', 'compatibility_status', 'target_build', 'runtime_required_helper_groups', 'RegisterConsoleCommandGlobalHandler', 'ExecuteWithDelay', 'OmeggaExecuteConsoleManagerInput', 'BMF.apis.list', 'BMF.apis.get', 'BMF.apis.summary', 'API_REGISTRY', 'api_registry_summary', 'bmf.apis', 'unsafe-native', 'live-player', 'BMF.sandbox.policy', 'BMF.sandbox.denials', 'bmf.sandbox', 'UNSAFE_PLUGIN_GLOBALS', 'plugin_global_lookup', 'plugin.unsafe_global_denied', 'UNSAFE_GLOBAL_DENIED', 'allowPluginUnsafeGlobals', 'unsafe.globals', 'BMF.events.on', 'BMF.events.off', 'BMF.events.emit', 'BMF.events.listenerCount', 'serverReady', 'pluginLoaded', 'pluginUnloaded', 'worldSaved', 'shutdownRequested', 'remove_event_handlers_for_owner', 'record_plugin_error', 'run_plugin_hook', 'plugin_watchdog_note_error', 'plugin_watchdog_isolated', 'PLUGIN_ISOLATED', 'plugin.isolated', 'BMF.plugins.watchdog', 'bmf.plugins.watchdog', 'pluginWatchdogMaxErrors', 'onServerReady', 'onTick', 'onError', 'plugin_tick_active', 'BMF.server.status', 'BMF.server.save', 'BMF.server.shutdown', 'bmf.server.status', 'bmf.server.save', 'bmf.server.shutdown', 'BMF_SHUTDOWN', 'CONFIRMATION_REQUIRED', 'server.shutdown', 'allowPluginServerShutdown', 'headless-empty', 'BMF.logging', 'BMF.logWarn', 'BMF.logError', 'events.jsonl', 'audit.jsonl', 'AUDIT_LOG_PATH', 'audit_record', 'BMF.audit.record', 'BMF.audit.recent', 'bmf.audit.tail', 'BMF.rateLimits.check', 'BMF.rateLimits.recent', 'rate_limit_check', 'RATE_LIMITED', 'rate_limit.denied', 'bmf.ratelimits', 'log_plugin', 'BMF.timers.after', 'BMF.timers.every', 'BMF.timers.cancel', 'BMF.timers.activeCount', 'BMF.chat.broadcast', 'BMF.chat.whisper', 'BMF.chat.statusMessage', 'BMF.server.planSettingsPatch', 'BMF.players.normalize', 'BMF.players.resolve', 'BMF.players.getName', 'BMF.interact.handleConsoleMessage', 'interactConsole', 'bmf.interact.console', 'BMF.permissions.describeRole', 'BMF.permissions.evaluateNoSpawnItemApplicator', 'BMF.permissions.evaluateApplicatorComponentAccess', 'BMF.permissions.evaluateInteractConsolePrefixAccess', 'BMF.permissions.evaluateBrickAssetAccess', 'BMF.permissions.enforceNoSpawnItemApplicator', 'BMF.tools.onApplicatorComponentApply', 'BMF.tools.applicator.status', 'BMF.tools.applicator.refreshComponentCache', 'tools.applicator', 'noSpawnItemApplicator', 'BMF.permissions.describeRoleAssignments', 'BMF.permissions.loadRoleAssignments', 'BMF.permissions.getPlayerRoles', 'BMF.permissions.playerHasRole', 'BMF.permissions.evaluateCommandAccess', 'savedPlayerRoles', 'BMF.permissions.planRolePatch', 'BMF.permissions.planPlayerRoleAssignment', 'BMF.minigames.list', 'BMF.minigames.loadPreset', 'BMF.minigames.savePreset', 'BMF.minigames.nextRound', 'BMF.minigames.reset', 'BMF.minigames.delete', 'BMF.minigames.emitEvent', 'BMF.minigames.on', 'BMF.minigames.off', 'BMF.minigames.listenerCount', 'BMF.minigames.eventStatus', 'BMF.minigames.syntheticFlow', 'BMF.minigames.define', 'BMF.minigames.definitions', 'BMF.minigames.definition', 'BMF.minigames.deleteDefinition', 'BMF.minigames.definitionStatus', 'BMF.minigames.recentEvents', 'BMF.minigames.applySnapshot', 'BMF.minigames.data', 'BMF.minigames.dataStatus', 'BMF.minigames.dataList', 'BMF.minigames.get', 'BMF.minigames.getPlayer', 'BMF.minigames.players', 'BMF.minigames.teams', 'BMF.minigames.leaderboard', 'BMF.minigames.membership', 'BMF.minigames.playerState', 'BMF.minigames.clearData', 'BMF.minigames.objectSnapshot', 'BMF.world.loadAdditive', 'BMF.world.saveAs', 'BMF.prefabs.loadBrz', 'BMF.prefabs.loadBrdb', 'BMF.vehicles.planSpawnSet', 'BMF.vehicles.spawnSet', 'BMF.commands.register', 'BMF.commands.dispatch', 'BMF.commands.dispatchWithAccess', 'register_command', 'remove_commands_for_owner', 'BMF.plugins.list', 'BMF.plugins.hasCapability', 'BMF.storage.writeText', 'BMF.storage.readText', 'BMF.storage.readJson', 'BMF.storage.writeJson', 'BMF.storage.readConfig', 'BMF.storage.writeConfig', 'JSON_PARSE_FAILED', 'BMF.unloadPlugins', 'BMF.loadPlugins', 'CAPABILITY_REQUIRED', 'CONFIG_OPT_IN_REQUIRED', 'PLAYER_DELIVERY_UNAVAILABLE', 'allowPluginServerExec', 'create_plugin_api', 'api.audit', 'api.rateLimits', 'api.capabilities', 'api.commands', 'server.exec.restricted', 'server.save', 'chat.whisper', 'chat.statusMessage', 'register_builtin_commands', 'bmf.health', 'bmf.version', 'bmf.load', 'bmf.unload', 'bmf.chat.broadcast', 'bmf.chat.whisper', 'bmf.chat.statusmessage', 'bmf.players.list', 'bmf.players.find', 'bmf.players.getname', 'bmf.interact.console', 'bmf.permissions.role-assignments', 'bmf.permissions.enforce-nospawnitem', 'bmf.tools.applicator.status', 'bmf.tools.applicator.refresh', 'bmf.minigames.list', 'bmf.minigames.loadpreset', 'bmf.minigames.savepreset', 'bmf.minigames.nextround', 'bmf.minigames.reset', 'bmf.minigames.delete', 'bmf.minigames.definitions.status', 'bmf.minigames.definitions.set', 'bmf.minigames.definitions.list', 'bmf.minigames.definitions.get', 'bmf.minigames.definitions.delete', 'bmf.minigames.events.emit', 'bmf.minigames.events.canary', 'bmf.minigames.events.synthetic-flow', 'bmf.minigames.events.status', 'bmf.minigames.events.recent', 'bmf.minigames.data.status', 'bmf.minigames.data.snapshot', 'bmf.minigames.data.apply-snapshot', 'bmf.minigames.data.list', 'bmf.minigames.data.get', 'bmf.minigames.data.players', 'bmf.minigames.data.teams', 'bmf.minigames.data.leaderboard', 'bmf.minigames.data.player', 'bmf.minigames.data.playerstate', 'bmf.minigames.data.membership', 'bmf.minigames.data.clear', 'bmf.minigames.objects.snapshot', 'bmf.world.saveas', 'bmf.prefabs.loadbrz', 'bmf.prefabs.loadbrdb', 'bmf.vehicles.spawnset', 'bmf.vehicles.snapshot')) {
    if ($source -notmatch [regex]::Escape($needle)) {
      $errors.Add("main.lua does not contain expected API marker: $needle")
    }
  }
  foreach ($needle in @('BMF.minigames.reconcileDefinitions', 'bmf.minigames.definitions.reconcile', 'BMF.minigames.applySnapshot', 'bmf.minigames.data.apply-snapshot')) {
    if ($source -notmatch [regex]::Escape($needle)) {
      $errors.Add("main.lua does not contain expected minigame reconcile marker: $needle")
    }
  }
  foreach ($needle in @('BMF.players.sync', 'BMF.players.summary', 'BMF.players.whisperSummary', 'bmf.players.sync', 'bmf.players.summary', 'PLAYER_CACHE_PATH')) {
    if ($source -notmatch [regex]::Escape($needle)) {
      $errors.Add("main.lua does not contain expected player-cache marker: $needle")
    }
  }
}

$vehicleInventoryScript = Join-Path $Root 'scripts/export-vehicle-inventory.ps1'
if (Test-Path -LiteralPath $vehicleInventoryScript) {
  $source = Get-Content -Raw -LiteralPath $vehicleInventoryScript
  foreach ($needle in @('OutText', "ChangeExtension(`$outPath, '.txt')", 'Vehicle inventory console-style text report', 'textPath')) {
    if ($source -notmatch [regex]::Escape($needle)) {
      $errors.Add("export-vehicle-inventory.ps1 does not contain expected text-report marker: $needle")
    }
  }
}

$result = [ordered]@{
  feature = 'package.static'
  status = if ($errors.Count -eq 0) { 'passed' } else { 'failed' }
  validationLevel = 'L0 Static'
  startedAt = (Get-Date).ToUniversalTime().ToString('o')
  finishedAt = (Get-Date).ToUniversalTime().ToString('o')
  root = $Root
  files = $files
  errors = @($errors)
  evidence = @(
    [ordered]@{
      kind = 'file'
      path = 'scripts/validate-package.ps1'
      summary = 'Static package validation script'
    }
  )
}

$json = $result | ConvertTo-Json -Depth 8
if ($OutJson) {
  $outPath = [System.IO.Path]::GetFullPath($OutJson)
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $outPath) | Out-Null
  Set-Content -LiteralPath $outPath -Value $json -Encoding UTF8
}

Write-Output $json
if ($errors.Count -ne 0) {
  exit 1
}
