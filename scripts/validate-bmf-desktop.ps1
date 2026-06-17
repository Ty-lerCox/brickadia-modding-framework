param(
  [string]$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
  [string]$OutJson = ''
)

$ErrorActionPreference = 'Stop'

if (!$OutJson) {
  $OutJson = Join-Path $Root 'artifacts/local/bmf-desktop-validation.json'
}

function Add-Evidence([System.Collections.Generic.List[object]]$Evidence, [string]$Kind, [string]$Path, [string]$Summary) {
  if ($Path -and (Test-Path -LiteralPath $Path)) {
    $Evidence.Add([ordered]@{
      kind = $Kind
      path = [System.IO.Path]::GetFullPath($Path)
      summary = $Summary
    })
  }
}

$errors = New-Object System.Collections.Generic.List[string]
$evidence = New-Object System.Collections.Generic.List[object]
$startedAt = (Get-Date).ToUniversalTime().ToString('o')
$appRoot = Join-Path $Root 'apps/bmf-desktop'
$packageJsonPath = Join-Path $appRoot 'package.json'
$packageLockPath = Join-Path $appRoot 'package-lock.json'
$builderPath = Join-Path $appRoot 'electron-builder.yml'
$iconPath = Join-Path $appRoot 'build/icon.ico'
$componentPath = Join-Path $appRoot 'src/app/app.component.ts'
$templatePath = Join-Path $appRoot 'src/app/app.component.html'
$stylesPath = Join-Path $appRoot 'src/styles.scss'

try {
  foreach ($required in @(
    $packageJsonPath,
    $packageLockPath,
    (Join-Path $appRoot 'README.md'),
    (Join-Path $appRoot 'packaged-assets/package.json'),
    (Join-Path $appRoot 'packaged-assets/bin/bmfctl.cmd'),
    (Join-Path $appRoot 'angular.json'),
    (Join-Path $appRoot 'tsconfig.json'),
    (Join-Path $appRoot 'tsconfig.app.json'),
    $builderPath,
    $iconPath,
    (Join-Path $appRoot 'electron/main.cjs'),
    (Join-Path $appRoot 'electron/preload.cjs'),
    (Join-Path $appRoot 'src/main.ts'),
    (Join-Path $appRoot 'src/index.html'),
    $stylesPath,
    (Join-Path $appRoot 'src/app/preload-api.ts'),
    $componentPath,
    $templatePath,
    (Join-Path $appRoot 'src/app/app.component.scss')
  )) {
    if (!(Test-Path -LiteralPath $required)) {
      $errors.Add("Missing BMF Desktop file: $required")
    }
  }

  if (Test-Path -LiteralPath $packageJsonPath) {
    $packageJson = Get-Content -Raw -LiteralPath $packageJsonPath | ConvertFrom-Json
    Add-Evidence $evidence 'json' $packageJsonPath 'BMF Desktop package manifest'
    if ([string]$packageJson.main -ne 'electron/main.cjs') {
      $errors.Add('BMF Desktop package main must be electron/main.cjs.')
    }
    if ([string]$packageJson.engines.node -ne '^22.22.3 || ^24.15.0 || >=26.0.0') {
      $errors.Add('BMF Desktop Node engine must match Angular 22 supported Node versions.')
    }
    foreach ($dependency in @('@angular/core', '@angular/material', '@angular/cdk', '@bmf/orchestrator-core')) {
      if (!$packageJson.dependencies.$dependency) {
        $errors.Add("BMF Desktop dependency is missing: $dependency")
      }
    }
    if ([string]$packageJson.dependencies.'@angular/material' -ne '22.0.1') {
      $errors.Add('BMF Desktop must pin @angular/material 22.0.1 until the desktop build is locked.')
    }
    if ([string]$packageJson.devDependencies.electron -ne '42.4.1') {
      $errors.Add('BMF Desktop must pin Electron 42.4.1 until the desktop build is locked.')
    }
    if ([string]$packageJson.devDependencies.'electron-builder' -ne '26.15.3') {
      $errors.Add('BMF Desktop must pin electron-builder 26.15.3 until MSI packaging is locked.')
    }
    if ([string]$packageJson.scripts.'release:local' -notmatch [regex]::Escape('scripts\build-bmf-desktop-release.ps1')) {
      $errors.Add('BMF Desktop must expose release:local for the top-level MSI release builder.')
    }
  }

  if (Test-Path -LiteralPath $packageLockPath) {
    Add-Evidence $evidence 'json' $packageLockPath 'BMF Desktop npm lockfile'
    & node -e "JSON.parse(require('fs').readFileSync(process.argv[1], 'utf8'))" $packageLockPath
    if ($LASTEXITCODE -ne 0) {
      $errors.Add('BMF Desktop package-lock.json is not valid JSON.')
    }
  }

  if (Test-Path -LiteralPath $builderPath) {
    $builderText = Get-Content -Raw -LiteralPath $builderPath
    Add-Evidence $evidence 'yaml' $builderPath 'electron-builder MSI configuration'
    foreach ($needle in @(
      'target: msi',
      'BMF-Desktop-${version}-${arch}.${ext}',
      'perMachine: true',
      'icon: build/icon.ico',
      'extraResources:',
      'to: bmf/manifests',
      'to: bmf/framework/ue4ss/Mods',
      'to: bmf/packages',
      'to: bmf/cli',
      'to: bmf/apps/bmf-desktop',
      'to: bmf/bin',
      'orchestrator-core/**/*',
      'bin/**/*',
      'to: bmf/compat',
      'to: bmf/observability',
      'omegga-plugins/**/*'
    )) {
      if ($builderText -notmatch [regex]::Escape($needle)) {
        $errors.Add("electron-builder.yml does not contain expected MSI marker: $needle")
      }
    }
  }

  $shimPath = Join-Path $appRoot 'packaged-assets/bin/bmfctl.cmd'
  if (Test-Path -LiteralPath $shimPath) {
    $shimText = Get-Content -Raw -LiteralPath $shimPath
    Add-Evidence $evidence 'cmd' $shimPath 'Installed bmfctl Windows shim'
    foreach ($needle in @(
      'ELECTRON_RUN_AS_NODE=1',
      'BMF Desktop.exe',
      'cli\bin\bmfctl.js',
      '--bmf-root',
      '--profile-store',
      '--journal-root',
      '--service-root',
      '--download-dir',
      'BMF_SNAPSHOT_ROOT',
      '%APPDATA%\BMF Desktop'
    )) {
      if ($shimText -notmatch [regex]::Escape($needle)) {
        $errors.Add("bmfctl.cmd does not contain expected installed-shim marker: $needle")
      }
    }
  }

  if (Test-Path -LiteralPath $stylesPath) {
    $stylesText = Get-Content -Raw -LiteralPath $stylesPath
    Add-Evidence $evidence 'scss' $stylesPath 'Angular Material 3 theme'
    foreach ($needle in @("@use '@angular/material' as mat", '@include mat.theme', 'mat.$azure-palette', '@include mat.system-classes')) {
      if ($stylesText -notmatch [regex]::Escape($needle)) {
        $errors.Add("styles.scss does not contain expected Material 3 marker: $needle")
      }
    }
  }

  if (Test-Path -LiteralPath $componentPath) {
    $componentText = Get-Content -Raw -LiteralPath $componentPath
    Add-Evidence $evidence 'typescript' $componentPath 'Angular standalone Material control panel component'
    foreach ($needle in @('standalone: true', 'OnDestroy', 'ngOnDestroy', 'MatToolbarModule', 'MatTabsModule', 'MatTableModule', 'MatSelectModule', 'MatSlideToggleModule', 'getBootstrapPlan', 'getProfiles', 'saveProfile', 'selectProfile', 'chooseProfilePath', 'getTelemetryPlan', 'writeTelemetryAlloyConfig', 'getDashboardImportPlan', 'writeDashboardImportPayload', 'uploadDashboardImport', 'getUpdateCheck', 'getUpdatePlan', 'downloadUpdate', 'getUpdateInstallPlan', 'launchUpdateInstaller', 'getTrafficSnapshot', 'exportTrafficTrace', 'openExternal', 'getOperationTransaction', 'applyOperationTransaction', 'getRollbackTransaction', 'applyRollbackTransaction', 'getServiceAction', 'applyServiceAction', 'getLogSnapshot', 'getTroubleshootingSnapshot', 'writeTroubleshootingSnapshot', 'includePortDiagnostics', 'startReadiness', 'serviceAction', 'serviceCanStart', 'serviceCanStop', 'serviceCanRestart', 'alloyCanStart', 'alloyCanStop', 'alloyCanRestart', 'refreshServiceAction', 'startStackService', 'stopStackService', 'restartStackService', 'startAlloyService', 'stopAlloyService', 'restartAlloyService', 'updateCheck', 'updatePlan', 'updateDownload', 'updateInstallPlan', 'updateInstallHandoff', 'refreshUpdateCheck', 'refreshUpdatePlan', 'downloadDesktopUpdate', 'refreshUpdateInstallPlan', 'updateStatus', 'updatePlanStatus', 'updateDownloadStatus', 'updateInstallStatus', 'updateArtifactStatus', 'profileBackend', 'profileBackendOptions', 'trafficPageIndex', 'runtimeLogPageIndex', 'orderedEventRecords', 'paginatedEventRecords', 'paginatedRuntimeLogLines', 'brickadiaWin64Path', 'omeggaRuntimePath', 'omeggaStartScriptPath', 'bmfRuntimeDirPath', 'grafanaAlloyExecutablePath', 'grafanaAlloyConfigPath', 'profileDraft', 'profileFormDirty', 'configuredPathCount', 'frameTelemetryEnabled', 'dashboardUrl', 'dashboardOpenUrl', 'dashboardCanOpen', 'openDashboard', 'adoptDashboardUrl', 'telemetryPlan', 'telemetryAlloyWrite', 'telemetryAlloyWriteStatus', 'dashboardImportPlan', 'dashboardImportWrite', 'dashboardImportUpload', 'dashboardImportStatus', 'dashboardImportWriteStatus', 'dashboardImportUploadStatus', 'dashboardImportSecretStatus', 'refreshDashboardImportPlan', 'trafficSnapshot', 'trafficTraceExport', 'trafficLiveEnabled', 'trafficRefreshInFlight', 'trafficLastRefresh', 'trafficRefreshError', 'trafficLiveStatus', 'trafficRefreshIntervalMs', 'toggleTrafficLive', 'trafficSummary', 'filteredEventRecords', 'selectedTrafficPayload', 'trafficTransports', 'trafficStatuses', 'trafficSourceNames', 'trafficSocketState', 'trafficFilterText', 'trafficTransportFilter', 'trafficStatusFilter', 'trafficSourceFilter', 'trafficPluginFilter', 'copySelectedTrafficPayload', 'copyTrafficTrace', 'exportTrafficTrace', 'logSnapshot', 'logSummary', 'troubleshootingSnapshot', 'snapshotStatus', 'snapshotSummary', 'snapshotCopiedFiles', 'snapshotCopiedLogs', 'refreshTroubleshootingSnapshot', 'profileRegistry', 'storedProfiles', 'saveCurrentProfile', 'refreshProfiles', 'operationTransaction', 'operationRollback', 'transactionSummary', 'transactionAppliedSummary', 'transactionCanApply', 'rollbackSummary', 'rollbackCanPreview', 'rollbackCanApply', 'applySelectedTransaction', 'refreshRollbackTransaction', 'refreshTraffic', 'refreshLogs')) {
      if ($componentText -notmatch [regex]::Escape($needle)) {
        $errors.Add("app.component.ts does not contain expected desktop UI marker: $needle")
      }
    }
    foreach ($needle in @('DesktopPrerequisiteCheck', 'prerequisiteChecks', 'prerequisiteSummary', 'prerequisites=')) {
      if ($componentText -notmatch [regex]::Escape($needle)) {
        $errors.Add("app.component.ts does not contain expected prerequisite UI marker: $needle")
      }
    }
  }

  if (Test-Path -LiteralPath $templatePath) {
    $templateText = Get-Content -Raw -LiteralPath $templatePath
    foreach ($needle in @('<mat-tab label="Profiles">', 'Save Profile', 'Refresh Profiles', 'Stored Profiles', 'Launcher', 'Local Windows process', 'Brickadia Win64 path', 'Browse Brickadia Win64 path', 'Omegga runtime path', 'Browse Omegga runtime path', 'Omegga start script', 'Browse Omegga start script', 'BMF socket port', 'Alloy ready port', 'BMF runtime dir', 'Browse BMF runtime dir', 'Alloy executable', 'Browse Alloy executable', 'Alloy config path', 'Choose Alloy config path', 'Dashboard URL', 'Frame telemetry', 'Configured paths', '<mat-tab label="Components">', 'Execution Contract', 'Preview selected transaction', 'Apply selected transaction', 'Preview rollback', 'Apply rollback', 'Rollback Contract', 'Source journal', 'Rollback journal', 'Restores', 'Removals', 'Ready steps', 'Applied', 'Errors', 'Journal', 'Finished', 'Rollback', 'Desktop Updates', 'Check desktop updates', 'Plan desktop update download', 'Download desktop update', 'Preview installer handoff', 'Launch verified installer', 'Download URL', 'Output', 'Installer', 'Command', 'Launch', 'Verification', 'Catalog', '<mat-tab label="Services">', 'Start Readiness', 'Launch Contract', 'Preview start', 'Start configured service', 'Preview stop', 'Stop configured service', 'Preview restart', 'Restart configured service', 'Preview Alloy start', 'Start Alloy', 'Preview Alloy stop', 'Stop Alloy', 'Preview Alloy restart', 'Restart Alloy', 'PID', 'Owned PID', 'Started', 'Stopped', 'Restarted', 'Stop result', 'Journal written', 'Configured Ports', '<mat-tab label="Telemetry">', 'Prepare Import', 'Write Payload', 'Upload Dashboard', 'Open Grafana dashboard', 'Dashboard Import', 'Write Alloy config', 'Token env', 'SHA256', 'Bytes', 'HTTP', 'Dashboard URL', 'Secret Refs', 'Config output', '<mat-tab label="Traffic">', 'Live', 'Refresh traffic', 'Copy redacted trace', 'Export redacted trace', 'Event, command, payload', 'All transports', 'All statuses', 'All sources', 'Plugin or consumer', 'Filtered', 'Socket', 'Last', 'Export', 'Consumer', 'Copy selected payload', 'Payload', 'Export path', 'Sources', 'Retained', 'Redactions', '<table mat-table', 'paginatedEventRecords', 'Traffic pagination', 'Older traffic', '<mat-tab label="Snapshots">', 'Troubleshooting Snapshot', 'Preview troubleshooting snapshot', 'Write troubleshooting snapshot', 'Copied Files', 'Log Tails', 'Snapshot file', 'Health file', 'Traffic file', '<mat-tab label="Logs">', 'Log Snapshot', 'Refresh logs', 'Log pagination', 'Older logs')) {
      if ($templateText -notmatch [regex]::Escape($needle)) {
        $errors.Add("app.component.html does not contain expected desktop view marker: $needle")
      }
    }
    foreach ($needle in @('Setup Readiness', 'prerequisiteSummary', 'prerequisiteChecks', 'check.required')) {
      if ($templateText -notmatch [regex]::Escape($needle)) {
        $errors.Add("app.component.html does not contain expected prerequisite view marker: $needle")
      }
    }
  }

  foreach ($scriptMarker in @(
    @{ Path = (Join-Path $appRoot 'electron/main.cjs'); Needle = 'SOURCE_REPO_ROOT' },
    @{ Path = (Join-Path $appRoot 'electron/main.cjs'); Needle = 'bundledBmfRoot' },
    @{ Path = (Join-Path $appRoot 'electron/main.cjs'); Needle = 'process.resourcesPath' },
    @{ Path = (Join-Path $appRoot 'electron/main.cjs'); Needle = "app.getPath('userData')" },
    @{ Path = (Join-Path $appRoot 'electron/main.cjs'); Needle = 'profileStorePath' },
    @{ Path = (Join-Path $appRoot 'electron/main.cjs'); Needle = 'journalRoot' },
    @{ Path = (Join-Path $appRoot 'electron/main.cjs'); Needle = 'serviceRoot' },
    @{ Path = (Join-Path $appRoot 'electron/main.cjs'); Needle = 'updateDownloadDir' },
    @{ Path = (Join-Path $appRoot 'electron/main.cjs'); Needle = 'desktopRoot(input)' },
    @{ Path = (Join-Path $appRoot 'electron/main.cjs'); Needle = 'bmfRoot: base.paths?.bmfRoot || root' },
    @{ Path = (Join-Path $appRoot 'electron/main.cjs'); Needle = 'createPrerequisiteAudit' },
    @{ Path = (Join-Path $appRoot 'electron/main.cjs'); Needle = 'bmf:traffic-snapshot' },
    @{ Path = (Join-Path $appRoot 'electron/main.cjs'); Needle = 'bmf:traffic-export' },
    @{ Path = (Join-Path $appRoot 'electron/main.cjs'); Needle = 'writeTrafficTraceExport' },
    @{ Path = (Join-Path $appRoot 'electron/main.cjs'); Needle = 'trafficTraceOutputPath' },
    @{ Path = (Join-Path $appRoot 'electron/main.cjs'); Needle = 'bmf:log-snapshot' },
    @{ Path = (Join-Path $appRoot 'electron/main.cjs'); Needle = 'bmf:troubleshooting-snapshot-plan' },
    @{ Path = (Join-Path $appRoot 'electron/main.cjs'); Needle = 'bmf:troubleshooting-snapshot-write' },
    @{ Path = (Join-Path $appRoot 'electron/main.cjs'); Needle = 'bmf:profiles-list' },
    @{ Path = (Join-Path $appRoot 'electron/main.cjs'); Needle = 'bmf:profile-save' },
    @{ Path = (Join-Path $appRoot 'electron/main.cjs'); Needle = 'bmf:profile-select' },
    @{ Path = (Join-Path $appRoot 'electron/main.cjs'); Needle = 'bmf:choose-path' },
    @{ Path = (Join-Path $appRoot 'electron/main.cjs'); Needle = 'bmf:dashboard-import-plan' },
    @{ Path = (Join-Path $appRoot 'electron/main.cjs'); Needle = 'bmf:telemetry-alloy-write' },
    @{ Path = (Join-Path $appRoot 'electron/main.cjs'); Needle = 'writeTelemetryAlloyConfig' },
    @{ Path = (Join-Path $appRoot 'electron/main.cjs'); Needle = 'alloyConfigOutputPath' },
    @{ Path = (Join-Path $appRoot 'electron/main.cjs'); Needle = 'write-alloy' },
    @{ Path = (Join-Path $appRoot 'electron/main.cjs'); Needle = 'bmf:dashboard-import-payload' },
    @{ Path = (Join-Path $appRoot 'electron/main.cjs'); Needle = 'bmf:dashboard-import-upload' },
    @{ Path = (Join-Path $appRoot 'electron/main.cjs'); Needle = 'bmf:update-check' },
    @{ Path = (Join-Path $appRoot 'electron/main.cjs'); Needle = 'bmf:update-plan' },
    @{ Path = (Join-Path $appRoot 'electron/main.cjs'); Needle = 'bmf:update-download' },
    @{ Path = (Join-Path $appRoot 'electron/main.cjs'); Needle = 'bmf:update-install-plan' },
    @{ Path = (Join-Path $appRoot 'electron/main.cjs'); Needle = 'bmf:update-install-handoff' },
    @{ Path = (Join-Path $appRoot 'electron/main.cjs'); Needle = 'bmf:operation-transaction' },
    @{ Path = (Join-Path $appRoot 'electron/main.cjs'); Needle = 'bmf:rollback-transaction' },
    @{ Path = (Join-Path $appRoot 'electron/main.cjs'); Needle = 'bmf:service-action' },
    @{ Path = (Join-Path $appRoot 'electron/preload.cjs'); Needle = 'getTrafficSnapshot' },
    @{ Path = (Join-Path $appRoot 'electron/preload.cjs'); Needle = 'exportTrafficTrace' },
    @{ Path = (Join-Path $appRoot 'electron/preload.cjs'); Needle = 'getLogSnapshot' },
    @{ Path = (Join-Path $appRoot 'electron/preload.cjs'); Needle = 'getTroubleshootingSnapshot' },
    @{ Path = (Join-Path $appRoot 'electron/preload.cjs'); Needle = 'writeTroubleshootingSnapshot' },
    @{ Path = (Join-Path $appRoot 'electron/preload.cjs'); Needle = 'getProfiles' },
    @{ Path = (Join-Path $appRoot 'electron/preload.cjs'); Needle = 'saveProfile' },
    @{ Path = (Join-Path $appRoot 'electron/preload.cjs'); Needle = 'selectProfile' },
    @{ Path = (Join-Path $appRoot 'electron/preload.cjs'); Needle = 'chooseProfilePath' },
    @{ Path = (Join-Path $appRoot 'electron/preload.cjs'); Needle = 'getDashboardImportPlan' },
    @{ Path = (Join-Path $appRoot 'electron/preload.cjs'); Needle = 'writeTelemetryAlloyConfig' },
    @{ Path = (Join-Path $appRoot 'electron/preload.cjs'); Needle = 'writeDashboardImportPayload' },
    @{ Path = (Join-Path $appRoot 'electron/preload.cjs'); Needle = 'uploadDashboardImport' },
    @{ Path = (Join-Path $appRoot 'electron/preload.cjs'); Needle = 'getUpdateCheck' },
    @{ Path = (Join-Path $appRoot 'electron/preload.cjs'); Needle = 'getUpdatePlan' },
    @{ Path = (Join-Path $appRoot 'electron/preload.cjs'); Needle = 'downloadUpdate' },
    @{ Path = (Join-Path $appRoot 'electron/preload.cjs'); Needle = 'getUpdateInstallPlan' },
    @{ Path = (Join-Path $appRoot 'electron/preload.cjs'); Needle = 'launchUpdateInstaller' },
    @{ Path = (Join-Path $appRoot 'electron/preload.cjs'); Needle = 'getOperationTransaction' },
    @{ Path = (Join-Path $appRoot 'electron/preload.cjs'); Needle = 'applyOperationTransaction' },
    @{ Path = (Join-Path $appRoot 'electron/preload.cjs'); Needle = 'getRollbackTransaction' },
    @{ Path = (Join-Path $appRoot 'electron/preload.cjs'); Needle = 'applyRollbackTransaction' },
    @{ Path = (Join-Path $appRoot 'electron/preload.cjs'); Needle = 'getServiceAction' },
    @{ Path = (Join-Path $appRoot 'electron/preload.cjs'); Needle = 'applyServiceAction' },
    @{ Path = (Join-Path $appRoot 'src/app/preload-api.ts'); Needle = 'DesktopTrafficSnapshot' },
    @{ Path = (Join-Path $appRoot 'src/app/preload-api.ts'); Needle = 'DesktopTrafficTraceExport' },
    @{ Path = (Join-Path $appRoot 'src/app/preload-api.ts'); Needle = 'DesktopLogSnapshot' },
    @{ Path = (Join-Path $appRoot 'src/app/preload-api.ts'); Needle = 'DesktopTroubleshootingSnapshot' },
    @{ Path = (Join-Path $appRoot 'src/app/preload-api.ts'); Needle = 'DesktopProfileRegistry' },
    @{ Path = (Join-Path $appRoot 'src/app/preload-api.ts'); Needle = 'DesktopPathPickerResult' },
    @{ Path = (Join-Path $appRoot 'src/app/preload-api.ts'); Needle = 'backendConfig' },
    @{ Path = (Join-Path $appRoot 'src/app/preload-api.ts'); Needle = 'DesktopDashboardImportPlan' },
    @{ Path = (Join-Path $appRoot 'src/app/preload-api.ts'); Needle = 'DesktopTelemetryAlloyWrite' },
    @{ Path = (Join-Path $appRoot 'src/app/preload-api.ts'); Needle = 'DesktopDashboardImportWrite' },
    @{ Path = (Join-Path $appRoot 'src/app/preload-api.ts'); Needle = 'DesktopDashboardImportUpload' },
    @{ Path = (Join-Path $appRoot 'src/app/preload-api.ts'); Needle = 'DesktopUpdateCheck' },
    @{ Path = (Join-Path $appRoot 'src/app/preload-api.ts'); Needle = 'DesktopUpdatePlan' },
    @{ Path = (Join-Path $appRoot 'src/app/preload-api.ts'); Needle = 'DesktopUpdateDownload' },
    @{ Path = (Join-Path $appRoot 'src/app/preload-api.ts'); Needle = 'DesktopUpdateInstallPlan' },
    @{ Path = (Join-Path $appRoot 'src/app/preload-api.ts'); Needle = 'DesktopUpdateInstallHandoff' },
    @{ Path = (Join-Path $appRoot 'src/app/preload-api.ts'); Needle = 'DesktopOperationTransaction' },
    @{ Path = (Join-Path $appRoot 'src/app/preload-api.ts'); Needle = 'DesktopAppliedTransactionStep' },
    @{ Path = (Join-Path $appRoot 'src/app/preload-api.ts'); Needle = 'DesktopRollbackTransaction' },
    @{ Path = (Join-Path $appRoot 'src/app/preload-api.ts'); Needle = 'DesktopRollbackStep' },
    @{ Path = (Join-Path $appRoot 'src/app/preload-api.ts'); Needle = 'DesktopAppliedRollbackStep' },
    @{ Path = (Join-Path $appRoot 'src/app/preload-api.ts'); Needle = 'applyServiceAction' },
    @{ Path = (Join-Path $appRoot 'src/app/preload-api.ts'); Needle = 'DesktopServiceAction' },
    @{ Path = (Join-Path $appRoot 'src/app/preload-api.ts'); Needle = 'DesktopPrerequisiteAudit' },
    @{ Path = (Join-Path $appRoot 'src/app/preload-api.ts'); Needle = 'DesktopPrerequisiteCheck' }
  )) {
    $markerPath = $scriptMarker['Path']
    $markerNeedle = $scriptMarker['Needle']
    if (Test-Path -LiteralPath $markerPath) {
      $scriptText = Get-Content -Raw -LiteralPath $markerPath
      if ($scriptText -notmatch [regex]::Escape($markerNeedle)) {
        $errors.Add("$markerPath does not contain expected traffic marker: $markerNeedle")
      }
    }
  }

  foreach ($script in @((Join-Path $appRoot 'electron/main.cjs'), (Join-Path $appRoot 'electron/preload.cjs'))) {
    if (Test-Path -LiteralPath $script) {
      & node --check $script | Out-Null
      if ($LASTEXITCODE -ne 0) {
        $errors.Add("Electron script failed syntax check: $script")
      }
    }
  }
} catch {
  $errors.Add($_.Exception.Message)
}

$result = [ordered]@{
  feature = 'bmf-desktop.static'
  status = if ($errors.Count -eq 0) { 'passed' } else { 'failed' }
  validationLevel = 'L0 Static'
  startedAt = $startedAt
  finishedAt = (Get-Date).ToUniversalTime().ToString('o')
  data = [ordered]@{
    appRoot = [System.IO.Path]::GetFullPath($appRoot)
  }
  evidence = $evidence.ToArray()
  errors = $errors.ToArray()
}

$json = $result | ConvertTo-Json -Depth 10
$outPath = [System.IO.Path]::GetFullPath($OutJson)
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $outPath) | Out-Null
Set-Content -LiteralPath $outPath -Value $json -Encoding UTF8
Write-Output $json

if ($errors.Count -ne 0) {
  exit 1
}
