param(
  [string]$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
  [string]$OutJson = ''
)

$ErrorActionPreference = 'Stop'

if (!$OutJson) {
  $OutJson = Join-Path $Root 'artifacts/local/unified-runtime-manifest-validation.json'
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

function Test-HasId($Items, [string]$Id) {
  foreach ($item in @($Items)) {
    if ([string]$item.id -eq $Id) {
      return $true
    }
  }
  return $false
}

function Get-ItemById($Items, [string]$Id) {
  foreach ($item in @($Items)) {
    if ([string]$item.id -eq $Id) {
      return $item
    }
  }
  return $null
}

$errors = New-Object System.Collections.Generic.List[string]
$evidence = New-Object System.Collections.Generic.List[object]
$startedAt = (Get-Date).ToUniversalTime().ToString('o')
$manifestPath = Join-Path $Root 'manifests/unified-runtime.json'
$schemaPath = Join-Path $Root 'manifests/unified-runtime.schema.json'
$goalDocPath = Join-Path $Root 'planning/roadmap/goal.md'
$manifest = $null
$schema = $null

try {
  foreach ($requiredPath in @($manifestPath, $schemaPath, $goalDocPath)) {
    if (!(Test-Path -LiteralPath $requiredPath)) {
      throw "Required unified runtime file is missing: $requiredPath"
    }
  }

  $manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
  $schema = Get-Content -Raw -LiteralPath $schemaPath | ConvertFrom-Json
  Add-Evidence $evidence 'json' $manifestPath 'Unified runtime manifest'
  Add-Evidence $evidence 'json-schema' $schemaPath 'Unified runtime manifest schema'
  Add-Evidence $evidence 'markdown' $goalDocPath 'BMF unified runtime goal'

  if ([int]$manifest.schemaVersion -lt 1) {
    $errors.Add('schemaVersion must be >= 1.')
  }
  if ([int]$schema.schemaVersion -gt 0) {
    $errors.Add('Schema file should describe schemaVersion as a property, not set a top-level schemaVersion.')
  }
  if ([string]$manifest.status -notin @('planned', 'in-progress', 'supported')) {
    $errors.Add("Unexpected manifest status: $($manifest.status)")
  }
  if ([string]$manifest.desktop.shell -ne 'Electron') {
    $errors.Add('Desktop shell must be Electron.')
  }
  if ([string]$manifest.desktop.renderer -ne 'Angular') {
    $errors.Add('Desktop renderer must be Angular.')
  }
  if ([string]$manifest.desktop.componentSystem -notmatch 'Angular Material 3') {
    $errors.Add('Desktop component system must require Angular Material 3.')
  }
  if ([string]$manifest.desktop.installer -ne 'MSI') {
    $errors.Add('Desktop installer must be MSI.')
  }

  if ([string]$manifest.orchestration.corePackage -ne 'packages/orchestrator-core') {
    $errors.Add('Orchestration core package must be packages/orchestrator-core.')
  }
  if ([string]$manifest.orchestration.defaultMode -ne 'dry-run') {
    $errors.Add('Orchestration default mode must be dry-run.')
  }
  foreach ($operationId in @('install-stack', 'repair-stack', 'update-stack', 'start-stack', 'stop-stack', 'restart-stack', 'snapshot-stack', 'configure-telemetry', 'inspect-event-traffic')) {
    if ($operationId -notin @($manifest.orchestration.operationIds)) {
      $errors.Add("Orchestration operation id is missing: $operationId")
    }
  }
  foreach ($guardrail in @('dry-run-by-default', 'explicit-user-action-required', 'structured-logs-only', 'redact-secrets-before-display-or-export', 'target-path-scope-validation', 'backup-before-overwrite', 'journal-every-applied-step', 'rollback-instructions-generated', 'rollback-journal-executable', 'bounded-log-snapshot', 'local-profile-registry', 'explicit-start-confirmation-required', 'configured-start-script-only', 'append-only-launch-log', 'journal-every-service-action', 'do-not-send-bmf-commands', 'do-not-add-ui-driven-server-probes')) {
    if ($guardrail -notin @($manifest.orchestration.guardrails)) {
      $errors.Add("Orchestration guardrail is missing: $guardrail")
    }
  }

  $requiredComponentIds = @(
    'bmf-desktop',
    'orchestrator-core',
    'bmfctl',
    'bmf-runtime',
    'bmf-native-socket',
    'bmf-frame-telemetry',
    'omegga-runtime',
    'omegga-plugin-bmf-bridge',
    'omegga-plugin-bmf-player-sync',
    'omegga-plugin-bmf-minigame-events',
    'ue4ss-compatibility',
    'grafana-alloy',
    'grafana-dashboard'
  )
  foreach ($id in $requiredComponentIds) {
    if (!(Test-HasId $manifest.components $id)) {
      $errors.Add("Unified runtime manifest is missing component: $id")
    }
  }

  foreach ($component in @($manifest.components)) {
    if (![string]$component.id) {
      $errors.Add('Component is missing id.')
    }
    if (![string]$component.owner) {
      $errors.Add("Component $($component.id) is missing owner.")
    }
    if (![string]$component.source) {
      $errors.Add("Component $($component.id) is missing source.")
      continue
    }

    $source = [string]$component.source
    if ($source -match '^https?://') {
      continue
    }
    $sourcePath = Join-Path $Root $source
    if (!(Test-Path -LiteralPath $sourcePath)) {
      $errors.Add("Component $($component.id) source does not exist: $source")
    }
  }

  $requiredHealthCheckIds = @(
    'brickadia-files',
    'omegga-running',
    'ue4ss-enabled',
    'bmf-status-fresh',
    'bmf-socket-connected',
    'frame-telemetry-fresh',
    'metrics-endpoint',
    'alloy-ready',
    'dashboard-imported'
  )
  foreach ($id in $requiredHealthCheckIds) {
    if (!(Test-HasId $manifest.healthChecks $id)) {
      $errors.Add("Unified runtime manifest is missing health check: $id")
    }
  }

  foreach ($check in @($manifest.healthChecks)) {
    if (!(Test-HasId $manifest.components ([string]$check.component))) {
      $errors.Add("Health check $($check.id) references unknown component: $($check.component)")
    }
    if ([string]$check.severity -notin @('required', 'degraded-ok', 'optional')) {
      $errors.Add("Health check $($check.id) has invalid severity: $($check.severity)")
    }
  }

  if ([string]$manifest.telemetry.dashboardOwner -ne 'Grafana') {
    $errors.Add('Telemetry dashboard owner must be Grafana.')
  }
  if ([string]$manifest.telemetry.desktopBoundary -notmatch 'opens Grafana') {
    $errors.Add('Telemetry desktop boundary must keep Grafana as the dashboard owner.')
  }
  foreach ($telemetryCheck in @('omegga-metrics-reachable', 'bmf-runtime-status-up', 'alloy-ready', 'remote-write-healthy', 'dashboard-url-present')) {
    if ($telemetryCheck -notin @($manifest.telemetry.checks)) {
      $errors.Add("Telemetry checks are missing: $telemetryCheck")
    }
  }

  if ([string]$manifest.eventTraffic.preferredTransport -notmatch 'BMFSocket') {
    $errors.Add('Event traffic preferred transport must be BMFSocket.')
  }
  foreach ($guardrail in @('observe-existing-traffic-only', 'do-not-add-ui-driven-server-probes', 'redact-secrets-before-display-or-export', 'bound-retained-record-count')) {
    if ($guardrail -notin @($manifest.eventTraffic.guardrails)) {
      $errors.Add("Event traffic guardrails are missing: $guardrail")
    }
  }

  if ([string]$manifest.release.primaryArtifact -ne 'BMF-Desktop-<version>-x64.msi') {
    $errors.Add('Release primary artifact must be BMF-Desktop-<version>-x64.msi.')
  }
  if ([string]$manifest.release.catalogArtifact -ne 'release-catalog.json') {
    $errors.Add('Release catalog artifact must be release-catalog.json.')
  }
  foreach ($artifact in @('BMF-Desktop-<version>-x64.msi', 'BMF-Desktop-<version>-x64.msi.sha256', 'release-manifest.json', 'release-catalog.json', 'RELEASE_NOTES.md')) {
    if ($artifact -notin @($manifest.release.requiredArtifacts)) {
      $errors.Add("Release required artifacts are missing: $artifact")
    }
  }
  foreach ($field in @('bmfDesktopVersion', 'bmfRuntimeVersion', 'omeggaRuntimeVersionOrCommit', 'supportedBrickadiaBuild', 'ue4ssBundleId', 'nativeHelperHashes', 'alloyTemplateVersion', 'dashboardVersion', 'installerSha256', 'releaseCatalog', 'releaseChannel')) {
    if ($field -notin @($manifest.release.manifest)) {
      $errors.Add("Release manifest field is missing: $field")
    }
  }

  $goalDoc = Get-Content -Raw -LiteralPath $goalDocPath
  foreach ($doc in @($manifest.roadmapDocs)) {
    $docPath = Join-Path $Root ([string]$doc)
    if (!(Test-Path -LiteralPath $docPath)) {
      $errors.Add("Roadmap doc does not exist: $doc")
      continue
    }
    if ([string]$doc -ne 'planning/roadmap/goal.md') {
      $linkTarget = Split-Path -Leaf ([string]$doc)
      if ($goalDoc -notmatch [regex]::Escape("($linkTarget)")) {
        $errors.Add("Goal doc does not link to roadmap doc: $doc")
      }
    }
  }
} catch {
  $errors.Add($_.Exception.Message)
}

$componentCount = 0
$healthCheckCount = 0
$roadmapDocCount = 0
if ($manifest) {
  $componentCount = @($manifest.components).Count
  $healthCheckCount = @($manifest.healthChecks).Count
  $roadmapDocCount = @($manifest.roadmapDocs).Count
}

$result = [ordered]@{
  feature = 'unified-runtime.manifest'
  status = if ($errors.Count -eq 0) { 'passed' } else { 'failed' }
  validationLevel = 'L0 Static'
  startedAt = $startedAt
  finishedAt = (Get-Date).ToUniversalTime().ToString('o')
  data = [ordered]@{
    manifestPath = [System.IO.Path]::GetFullPath($manifestPath)
    schemaPath = [System.IO.Path]::GetFullPath($schemaPath)
    componentCount = $componentCount
    healthCheckCount = $healthCheckCount
    roadmapDocCount = $roadmapDocCount
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
