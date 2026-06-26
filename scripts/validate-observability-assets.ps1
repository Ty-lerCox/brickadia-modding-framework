param(
  [string]$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
  [string]$OutJson = ''
)

$ErrorActionPreference = 'Stop'

if (!$OutJson) {
  $OutJson = Join-Path $Root 'artifacts/local/observability-assets-validation.json'
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

function Get-PanelExpressions($Panels) {
  $expressions = New-Object System.Collections.Generic.List[string]
  foreach ($panel in @($Panels)) {
    foreach ($target in @($panel.targets)) {
      if ([string]$target.expr) {
        $expressions.Add([string]$target.expr)
      }
    }
  }
  return $expressions.ToArray()
}

$errors = New-Object System.Collections.Generic.List[string]
$evidence = New-Object System.Collections.Generic.List[object]
$startedAt = (Get-Date).ToUniversalTime().ToString('o')
$manifestPath = Join-Path $Root 'observability/observability-manifest.json'
$alloyPath = Join-Path $Root 'observability/alloy/bmf.alloy.template'
$dashboardPath = Join-Path $Root 'observability/grafana/bmf-dashboard.json'
$importPath = Join-Path $Root 'observability/grafana/dashboard-import.json'
$readmePath = Join-Path $Root 'observability/README.md'
$manifest = $null
$dashboard = $null
$import = $null

try {
  foreach ($requiredPath in @($manifestPath, $alloyPath, $dashboardPath, $importPath, $readmePath)) {
    if (!(Test-Path -LiteralPath $requiredPath)) {
      $errors.Add("Missing observability file: $requiredPath")
    }
  }

  if (Test-Path -LiteralPath $manifestPath) {
    $manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
    Add-Evidence $evidence 'json' $manifestPath 'BMF observability asset manifest'
  }
  if (Test-Path -LiteralPath $dashboardPath) {
    $dashboard = Get-Content -Raw -LiteralPath $dashboardPath | ConvertFrom-Json
    Add-Evidence $evidence 'json' $dashboardPath 'BMF standard Grafana dashboard'
  }
  if (Test-Path -LiteralPath $importPath) {
    $import = Get-Content -Raw -LiteralPath $importPath | ConvertFrom-Json
    Add-Evidence $evidence 'json' $importPath 'BMF Grafana dashboard import contract'
  }
  if (Test-Path -LiteralPath $alloyPath) {
    $alloy = Get-Content -Raw -LiteralPath $alloyPath
    Add-Evidence $evidence 'alloy' $alloyPath 'BMF Grafana Alloy config template'
    foreach ($needle in @(
      'prometheus.remote_write "grafana_cloud"',
      'prometheus.scrape "omegga"',
      'prometheus.scrape "alloy_self"',
      'sys.env("BMF_GRAFANA_REMOTE_WRITE_URL")',
      'sys.env("BMF_GRAFANA_REMOTE_WRITE_USERNAME")',
      'sys.env("BMF_GRAFANA_REMOTE_WRITE_TOKEN")',
      'forward_to      = [prometheus.remote_write.grafana_cloud.receiver]',
      'proxy_from_environment = true',
      '{{environment}}',
      '{{instance}}',
      '{{server_profile}}',
      '{{brickadia_build}}'
    )) {
      if ($alloy -notmatch [regex]::Escape($needle)) {
        $errors.Add("Alloy template does not contain expected marker: $needle")
      }
    }
  }

  $telemetryCorePath = Join-Path $Root 'packages/orchestrator-core/src/telemetry.js'
  if (Test-Path -LiteralPath $telemetryCorePath) {
    $telemetrySource = Get-Content -Raw -LiteralPath $telemetryCorePath
    Add-Evidence $evidence 'javascript' $telemetryCorePath 'orchestrator-core telemetry onboarding renderer'
    foreach ($needle in @('createTelemetryOnboardingPlan', 'writeTelemetryAlloyConfig', 'createDashboardImportPlan', 'writeDashboardImportPayload', 'executeDashboardImport', 'remoteWriteSecretRefs', 'dashboard-import-dry-run-only', 'dashboard-payload-redacts-secrets', 'grafana-upload-requires-confirm-import', 'do-not-store-secret-values', 'missingSecretRefs')) {
      if ($telemetrySource -notmatch [regex]::Escape($needle)) {
        $errors.Add("Telemetry renderer does not contain expected marker: $needle")
      }
    }
  } else {
    $errors.Add("Missing telemetry renderer: $telemetryCorePath")
  }

  if ($manifest) {
    foreach ($pathValue in @($manifest.alloy.template, $manifest.grafana.dashboard, $manifest.grafana.import)) {
      if (!(Test-Path -LiteralPath (Join-Path $Root ([string]$pathValue)))) {
        $errors.Add("Observability manifest references missing file: $pathValue")
      }
    }
    foreach ($label in @('environment', 'instance', 'server_profile', 'brickadia_build')) {
      if ($label -notin @($manifest.labels)) {
        $errors.Add("Observability manifest is missing label: $label")
      }
    }
    foreach ($metric in @('bmf_runtime_status_up', 'brickadia_frame_fps', 'brickadia_frame_delta_milliseconds', 'brickadia_frame_slow_total', 'bmf_command_total', 'bmf_event_total')) {
      if ($metric -notin @($manifest.metrics)) {
        $errors.Add("Observability manifest is missing metric: $metric")
      }
    }
  }

  if ($dashboard) {
    if ([string]$dashboard.uid -ne 'bmf-standard') {
      $errors.Add('Dashboard uid must be bmf-standard.')
    }
    if ([string]$dashboard.title -notmatch 'BMF') {
      $errors.Add('Dashboard title must identify BMF.')
    }
    if (@($dashboard.panels).Count -lt 6) {
      $errors.Add('Dashboard must contain at least six panels.')
    }
    $variables = @($dashboard.templating.list | ForEach-Object { [string]$_.name })
    foreach ($variable in @('datasource', 'environment', 'instance', 'server_profile', 'brickadia_build')) {
      if ($variable -notin $variables) {
        $errors.Add("Dashboard is missing templating variable: $variable")
      }
    }
    $expressions = (Get-PanelExpressions $dashboard.panels) -join "`n"
    foreach ($metric in @('bmf_runtime_status_up', 'up{job="bmf-omegga"', 'bmf_socket_connected', 'brickadia_frame_fps', 'brickadia_frame_delta_milliseconds', 'brickadia_frame_slow_total', 'bmf_command_total', 'bmf_event_total')) {
      if ($expressions -notmatch [regex]::Escape($metric)) {
        $errors.Add("Dashboard queries do not contain expected metric: $metric")
      }
    }
  }

  if ($import) {
    if ([string]$import.api.defaultEndpoint -ne 'POST /api/dashboards/db') {
      $errors.Add('Dashboard import contract must declare POST /api/dashboards/db.')
    }
    foreach ($input in @('grafanaBaseUrl', 'grafanaApiToken', 'prometheusDatasourceUid', 'environment', 'instance', 'server_profile', 'brickadia_build')) {
      if ($input -notin @($import.requiredInputs)) {
        $errors.Add("Dashboard import contract is missing input: $input")
      }
    }
    if ('grafanaApiToken' -notin @($import.secretFields)) {
      $errors.Add('Dashboard import contract must mark grafanaApiToken as secret.')
    }
  }
} catch {
  $errors.Add($_.Exception.Message)
}

$result = [ordered]@{
  feature = 'observability.assets'
  status = if ($errors.Count -eq 0) { 'passed' } else { 'failed' }
  validationLevel = 'L0 Static'
  startedAt = $startedAt
  finishedAt = (Get-Date).ToUniversalTime().ToString('o')
  data = [ordered]@{
    manifestPath = [System.IO.Path]::GetFullPath($manifestPath)
    dashboardPath = [System.IO.Path]::GetFullPath($dashboardPath)
    alloyPath = [System.IO.Path]::GetFullPath($alloyPath)
    dashboardPanels = if ($dashboard) { @($dashboard.panels).Count } else { 0 }
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
