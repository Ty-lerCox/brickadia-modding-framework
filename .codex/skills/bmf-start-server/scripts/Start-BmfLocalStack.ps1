param(
  [ValidateSet('StartOrCheck', 'CheckOnly')]
  [string]$Mode = 'StartOrCheck',
  [string]$BrickadiaRoot = 'C:\Users\tycox\OneDrive\Documents\GitHub\Brickadia',
  [string]$BmfRoot = 'C:\Users\tycox\OneDrive\Documents\GitHub\bmf',
  [int]$ReadyTimeoutSeconds = 120,
  [int]$ScrapeWaitSeconds = 20,
  [switch]$Json
)

$ErrorActionPreference = 'Stop'

function New-Check {
  param(
    [string]$Name,
    [string]$Status,
    [string]$Summary,
    [object]$Evidence = $null
  )
  [ordered]@{
    name = $Name
    status = $Status
    summary = $Summary
    evidence = $Evidence
  }
}

function Test-HttpEndpoint {
  param(
    [string]$Url,
    [int]$TimeoutSeconds = 5,
    [string]$RequiredPattern = ''
  )
  try {
    $response = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec $TimeoutSeconds
    $body = [string]$response.Content
    $ok = $response.StatusCode -ge 200 -and $response.StatusCode -lt 300
    if ($RequiredPattern) {
      $ok = $ok -and ($body -match $RequiredPattern)
    }
    return [ordered]@{
      ok = [bool]$ok
      statusCode = [int]$response.StatusCode
      bytes = $body.Length
    }
  } catch {
    return [ordered]@{
      ok = $false
      error = $_.Exception.Message
    }
  }
}

function Read-JsonFile {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) {
    return $null
  }
  try {
    return Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json
  } catch {
    return $null
  }
}

function Get-FileAgeSeconds {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) {
    return $null
  }
  $item = Get-Item -LiteralPath $Path
  return [Math]::Round(((Get-Date) - $item.LastWriteTime).TotalSeconds, 3)
}

function Get-FirstMetricValue {
  param(
    [string]$MetricsText,
    [string]$Regex
  )
  $match = [regex]::Match($MetricsText, $Regex, [System.Text.RegularExpressions.RegexOptions]::Multiline)
  if (-not $match.Success) {
    return $null
  }
  return $match.Groups[1].Value
}

function Redact-CommandLine {
  param([string]$Value)
  if (-not $Value) {
    return $null
  }
  $redacted = [string]$Value
  $redacted = [regex]::Replace($redacted, '(?i)"-Token=\\?"[^"\s]*(?:\\?"){1,2}', '"-Token=[redacted]"')
  $redacted = [regex]::Replace($redacted, '(?i)-Token=\\?"[^"\s]*(?:\\?"){1,2}', '-Token=[redacted]')
  $redacted = [regex]::Replace($redacted, '(?i)(token=)[^&\s"]+', '$1[redacted]')
  return $redacted
}

function Get-ProcessSnapshot {
  $items = @(Get-CimInstance Win32_Process | Where-Object {
    $_.Name -match 'BrickadiaServer|BrickadiaSteam|alloy|node|cmd'
  } | ForEach-Object {
    [ordered]@{
      ProcessId = $_.ProcessId
      ParentProcessId = $_.ParentProcessId
      Name = $_.Name
      CommandLine = Redact-CommandLine -Value $_.CommandLine
    }
  })
  return @($items)
}

function Start-OmeggaStack {
  param(
    [string]$Root
  )
  $script = Join-Path $Root 'run-omegga.cmd'
  if (-not (Test-Path -LiteralPath $script)) {
    return [ordered]@{ started = $false; error = "run-omegga.cmd not found at $script" }
  }
  $logDir = Join-Path $Root 'artifacts\service-start'
  New-Item -ItemType Directory -Force -Path $logDir | Out-Null
  $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
  $stdout = Join-Path $logDir "omegga-skill-$stamp.out.log"
  $stderr = Join-Path $logDir "omegga-skill-$stamp.err.log"
  $process = Start-Process -FilePath 'cmd.exe' `
    -ArgumentList @('/d', '/c', "`"$script`"") `
    -WorkingDirectory $Root `
    -WindowStyle Hidden `
    -RedirectStandardOutput $stdout `
    -RedirectStandardError $stderr `
    -PassThru
  return [ordered]@{
    started = $true
    pid = $process.Id
    stdout = $stdout
    stderr = $stderr
  }
}

function Wait-ForStack {
  param(
    [int]$TimeoutSeconds
  )
  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  do {
    $omegga = Test-HttpEndpoint -Url 'http://127.0.0.1:8080/metrics' -TimeoutSeconds 3 -RequiredPattern 'bmf_runtime_status_up|brickadia_server_up'
    $city = Test-HttpEndpoint -Url 'http://127.0.0.1:3000/metrics' -TimeoutSeconds 3 -RequiredPattern 'cityrpg_metrics_up'
    $udp = @(Get-NetUDPEndpoint -ErrorAction SilentlyContinue | Where-Object { $_.LocalPort -eq 7777 })
    if ($omegga.ok -and $city.ok -and $udp.Count -gt 0) {
      return [ordered]@{ ready = $true; omegga = $omegga; cityrpg = $city; udp7777 = $udp[0].OwningProcess }
    }
    Start-Sleep -Seconds 3
  } while ((Get-Date) -lt $deadline)
  return [ordered]@{
    ready = $false
    omegga = $omegga
    cityrpg = $city
    udp7777 = @($udp | Select-Object -First 1).OwningProcess
  }
}

function Invoke-BmfSocketCommand {
  param(
    [object]$SocketMetadata,
    [string]$Command = 'bmf.status',
    [int]$TimeoutMs = 5000
  )
  if (-not $SocketMetadata) {
    return [ordered]@{ ok = $false; error = 'socket-metadata-missing' }
  }
  $hostName = [string]$SocketMetadata.host
  $port = [int]$SocketMetadata.port
  $token = [string]$SocketMetadata.token
  if (-not $hostName -or $port -le 0 -or -not $token) {
    return [ordered]@{ ok = $false; error = 'socket-metadata-incomplete' }
  }

  $client = New-Object System.Net.Sockets.TcpClient
  $client.ReceiveTimeout = $TimeoutMs
  $client.SendTimeout = $TimeoutMs
  try {
    $async = $client.BeginConnect($hostName, $port, $null, $null)
    if (-not $async.AsyncWaitHandle.WaitOne($TimeoutMs)) {
      $client.Close()
      return [ordered]@{ ok = $false; error = 'connect-timeout'; host = $hostName; port = $port }
    }
    $client.EndConnect($async)
    $stream = $client.GetStream()
    $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8)
    $writer = New-Object System.IO.StreamWriter($stream, [System.Text.Encoding]::UTF8)
    $writer.NewLine = "`n"
    $writer.AutoFlush = $true
    $issuedAtMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $id = 'codex-' + $issuedAtMs
    $writer.WriteLine((@{ type = 'hello'; role = 'plugin'; token = $token } | ConvertTo-Json -Compress))
    $writer.WriteLine((@{
      type = 'command'
      id = $id
      source = 'codex-bmf-start-server'
      command = $Command
      issuedAtMs = $issuedAtMs
      deadlineMs = $issuedAtMs + $TimeoutMs
      serviceClass = 'interactive'
    } | ConvertTo-Json -Compress))
    $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
    while ((Get-Date) -lt $deadline) {
      $line = $reader.ReadLine()
      if (-not $line) {
        continue
      }
      try {
        $message = $line | ConvertFrom-Json
      } catch {
        continue
      }
      if ([string]$message.type -eq 'response' -and [string]$message.id -eq $id) {
        return [ordered]@{
          ok = [bool]$message.ok
          detail = [string]$message.detail
          command = $Command
          response = [string]$message.response
        }
      }
    }
    return [ordered]@{ ok = $false; error = 'response-timeout'; command = $Command }
  } catch {
    return [ordered]@{ ok = $false; error = $_.Exception.Message; command = $Command }
  } finally {
    try { $client.Close() } catch {}
  }
}

function Sync-GrafanaEnvironment {
  $names = @(
    'GRAFANA_CLOUD_PROMETHEUS_RW_URL',
    'GRAFANA_CLOUD_PROMETHEUS_USERNAME',
    'GRAFANA_CLOUD_API_KEY',
    'BMF_GRAFANA_REMOTE_WRITE_URL',
    'BMF_GRAFANA_REMOTE_WRITE_USERNAME',
    'BMF_GRAFANA_REMOTE_WRITE_TOKEN'
  )
  foreach ($name in $names) {
    if (-not [Environment]::GetEnvironmentVariable($name, 'Process')) {
      $userValue = [Environment]::GetEnvironmentVariable($name, 'User')
      if ($userValue) {
        [Environment]::SetEnvironmentVariable($name, $userValue, 'Process')
      }
    }
  }
}

function Get-GrafanaEnvMode {
  Sync-GrafanaEnvironment
  if ($env:GRAFANA_CLOUD_PROMETHEUS_RW_URL -and $env:GRAFANA_CLOUD_PROMETHEUS_USERNAME -and $env:GRAFANA_CLOUD_API_KEY) {
    return [ordered]@{
      ok = $true
      url = 'GRAFANA_CLOUD_PROMETHEUS_RW_URL'
      username = 'GRAFANA_CLOUD_PROMETHEUS_USERNAME'
      password = 'GRAFANA_CLOUD_API_KEY'
    }
  }
  if ($env:BMF_GRAFANA_REMOTE_WRITE_URL -and $env:BMF_GRAFANA_REMOTE_WRITE_USERNAME -and $env:BMF_GRAFANA_REMOTE_WRITE_TOKEN) {
    return [ordered]@{
      ok = $true
      url = 'BMF_GRAFANA_REMOTE_WRITE_URL'
      username = 'BMF_GRAFANA_REMOTE_WRITE_USERNAME'
      password = 'BMF_GRAFANA_REMOTE_WRITE_TOKEN'
    }
  }
  return [ordered]@{
    ok = $false
    missing = @('GRAFANA_CLOUD_PROMETHEUS_RW_URL', 'GRAFANA_CLOUD_PROMETHEUS_USERNAME', 'GRAFANA_CLOUD_API_KEY')
  }
}

function Write-AlloyConfig {
  param(
    [string]$Path,
    [int]$AdminPort,
    [object]$EnvMode
  )
  $content = @"
logging {
  level  = "info"
  format = "json"
}

prometheus.remote_write "grafana_cloud" {
  endpoint {
    url = sys.env("$($EnvMode.url)")

    basic_auth {
      username = sys.env("$($EnvMode.username)")
      password = sys.env("$($EnvMode.password)")
    }

    proxy_from_environment = true
  }

  external_labels = {
    environment     = "local",
    instance        = "local",
    server_profile  = "local",
    brickadia_build = "PC-Shipping-CL15501",
  }
}

prometheus.scrape "omegga" {
  targets = [
    {
      "__address__" = "127.0.0.1:8080",
      "job"         = "bmf-omegga",
    },
  ]

  metrics_path    = "/metrics"
  scrape_interval = "15s"
  forward_to      = [prometheus.remote_write.grafana_cloud.receiver]
}

prometheus.scrape "cityrpg" {
  targets = [
    {
      "__address__" = "127.0.0.1:3000",
      "job"         = "cityrpg",
    },
  ]

  metrics_path    = "/metrics"
  scrape_interval = "15s"
  forward_to      = [prometheus.remote_write.grafana_cloud.receiver]
}

prometheus.scrape "alloy_self" {
  targets = [
    {
      "__address__" = "127.0.0.1:$AdminPort",
      "job"         = "bmf-alloy",
    },
  ]

  scrape_interval = "15s"
  forward_to      = [prometheus.remote_write.grafana_cloud.receiver]
}
"@
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path) | Out-Null
  Set-Content -LiteralPath $Path -Value $content -Encoding ASCII
}

function Get-AlloyStatus {
  param([int]$Port)
  $ready = Test-HttpEndpoint -Url "http://127.0.0.1:$Port/-/ready" -TimeoutSeconds 3 -RequiredPattern 'Alloy is ready'
  if (-not $ready.ok) {
    return [ordered]@{ ok = $false; port = $Port; ready = $ready }
  }
  $componentsResponse = Test-HttpEndpoint -Url "http://127.0.0.1:$Port/api/v0/web/components" -TimeoutSeconds 3
  $componentIds = @()
  if ($componentsResponse.ok) {
    try {
      $componentsRaw = (Invoke-WebRequest -Uri "http://127.0.0.1:$Port/api/v0/web/components" -UseBasicParsing -TimeoutSec 3).Content
      if ($componentsRaw -is [byte[]]) {
        $componentsRaw = [System.Text.Encoding]::UTF8.GetString($componentsRaw)
      }
      $parsedComponents = $componentsRaw | ConvertFrom-Json
      $ids = @()
      if ($parsedComponents) {
        $ids += @($parsedComponents.localID)
        foreach ($component in @($parsedComponents)) {
          if ($component -and $component.PSObject.Properties.Name -contains 'localID') {
            $ids += [string]$component.localID
          }
        }
      }
      $componentIds = @($ids | Where-Object { $_ } | ForEach-Object { [string]$_ } | Sort-Object -Unique)
    } catch {
      $componentIds = @()
    }
  }
  $metricsText = ''
  try {
    $metricsText = (Invoke-WebRequest -Uri "http://127.0.0.1:$Port/metrics" -UseBasicParsing -TimeoutSec 3).Content
  } catch {
    $metricsText = ''
  }
  $samplesIn = Get-FirstMetricValue -MetricsText $metricsText -Regex '^prometheus_remote_storage_samples_in_total\s+([0-9.eE+-]+)'
  $samplesSent = Get-FirstMetricValue -MetricsText $metricsText -Regex '^prometheus_remote_storage_samples_total\{.*\}\s+([0-9.eE+-]+)'
  $samplesFailed = Get-FirstMetricValue -MetricsText $metricsText -Regex '^prometheus_remote_storage_samples_failed_total\{.*\}\s+([0-9.eE+-]+)'
  $samplesPending = Get-FirstMetricValue -MetricsText $metricsText -Regex '^prometheus_remote_storage_samples_pending\{.*\}\s+([0-9.eE+-]+)'
  $hasPipeline = $componentIds -contains 'prometheus.remote_write.grafana_cloud' -and $componentIds -contains 'prometheus.scrape.omegga'
  $failedNumber = if ($samplesFailed -ne $null) { [double]$samplesFailed } else { 0 }
  return [ordered]@{
    ok = $hasPipeline -and $failedNumber -eq 0
    port = $Port
    ready = $ready
    components = $componentIds
    hasPipeline = $hasPipeline
    samplesIn = $samplesIn
    samplesSent = $samplesSent
    samplesFailed = $samplesFailed
    samplesPending = $samplesPending
  }
}

function Start-UserAlloy {
  param(
    [string]$Root,
    [int]$Port,
    [object]$EnvMode
  )
  $alloyExe = 'C:\Program Files\GrafanaLabs\Alloy\alloy-windows-amd64.exe'
  if (-not (Test-Path -LiteralPath $alloyExe)) {
    return [ordered]@{ started = $false; error = "Alloy executable not found at $alloyExe" }
  }
  $logDir = Join-Path $Root 'artifacts\service-start'
  $dataDir = Join-Path $logDir 'alloy-data'
  $configPath = Join-Path $logDir 'bmf-grafana-cloud.alloy'
  Write-AlloyConfig -Path $configPath -AdminPort $Port -EnvMode $EnvMode
  & $alloyExe validate $configPath | Out-Null
  New-Item -ItemType Directory -Force -Path $dataDir | Out-Null
  $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
  $stdout = Join-Path $logDir "alloy-skill-$stamp.out.log"
  $stderr = Join-Path $logDir "alloy-skill-$stamp.err.log"
  $process = Start-Process -FilePath $alloyExe `
    -ArgumentList @('run', $configPath, "--server.http.listen-addr=127.0.0.1:$Port", "--storage.path=$dataDir") `
    -WorkingDirectory $Root `
    -WindowStyle Hidden `
    -RedirectStandardOutput $stdout `
    -RedirectStandardError $stderr `
    -PassThru
  return [ordered]@{
    started = $true
    pid = $process.Id
    port = $Port
    config = $configPath
    storage = $dataDir
    stdout = $stdout
    stderr = $stderr
  }
}

function Ensure-Alloy {
  param(
    [string]$Root,
    [int]$ScrapeWait
  )
  foreach ($port in @(12346, 12345)) {
    $status = Get-AlloyStatus -Port $port
    if ($status.ok -and $status.hasPipeline) {
      if ($ScrapeWait -gt 0) { Start-Sleep -Seconds $ScrapeWait }
      return [ordered]@{ status = Get-AlloyStatus -Port $port; started = $null }
    }
  }
  if ($Mode -eq 'CheckOnly') {
    return [ordered]@{ status = Get-AlloyStatus -Port 12346; started = $null; skippedStart = $true }
  }
  $envMode = Get-GrafanaEnvMode
  if (-not $envMode.ok) {
    return [ordered]@{ status = $null; started = $null; error = 'grafana-remote-write-env-missing'; missing = $envMode.missing }
  }
  $candidatePort = 12346
  while (Get-NetTCPConnection -State Listen -LocalPort $candidatePort -ErrorAction SilentlyContinue) {
    $candidatePort++
    if ($candidatePort -gt 12355) {
      return [ordered]@{ status = $null; started = $null; error = 'no-free-alloy-admin-port' }
    }
  }
  $started = Start-UserAlloy -Root $Root -Port $candidatePort -EnvMode $envMode
  Start-Sleep -Seconds $ScrapeWait
  return [ordered]@{ status = Get-AlloyStatus -Port $candidatePort; started = $started }
}

$checks = New-Object System.Collections.Generic.List[object]
$startedActions = New-Object System.Collections.Generic.List[object]
$runtimeDir = Join-Path $env:APPDATA 'omegga\steam_installs\main\Brickadia\Binaries\Win64\ue4ss\main\Mods\BMF\runtime'
$statusPath = Join-Path $runtimeDir 'status.json'
$socketPath = Join-Path $runtimeDir 'socket.json'
$bridgePath = Join-Path $runtimeDir 'bmf-bridge-status.json'
$telemetryPath = Join-Path $runtimeDir 'telemetry.json'
$frameTelemetryPath = Join-Path $runtimeDir 'frame-telemetry.json'

$omeggaProbe = Test-HttpEndpoint -Url 'http://127.0.0.1:8080/metrics' -TimeoutSeconds 3 -RequiredPattern 'bmf_runtime_status_up|brickadia_server_up'
$cityProbe = Test-HttpEndpoint -Url 'http://127.0.0.1:3000/metrics' -TimeoutSeconds 3 -RequiredPattern 'cityrpg_metrics_up'
$udp7777 = @(Get-NetUDPEndpoint -ErrorAction SilentlyContinue | Where-Object { $_.LocalPort -eq 7777 })

if (($Mode -ne 'CheckOnly') -and (-not $omeggaProbe.ok -or -not $cityProbe.ok -or $udp7777.Count -eq 0)) {
  $startResult = Start-OmeggaStack -Root $BrickadiaRoot
  $startedActions.Add([ordered]@{ action = 'start-omegga'; result = $startResult }) | Out-Null
  $ready = Wait-ForStack -TimeoutSeconds $ReadyTimeoutSeconds
  $omeggaProbe = $ready.omegga
  $cityProbe = $ready.cityrpg
  $udp7777 = @(Get-NetUDPEndpoint -ErrorAction SilentlyContinue | Where-Object { $_.LocalPort -eq 7777 })
}

$checks.Add((New-Check -Name 'omegga-metrics' -Status ($(if ($omeggaProbe.ok) { 'healthy' } else { 'unhealthy' })) -Summary 'Omegga metrics endpoint on 127.0.0.1:8080/metrics.' -Evidence $omeggaProbe)) | Out-Null
$checks.Add((New-Check -Name 'cityrpg-metrics' -Status ($(if ($cityProbe.ok) { 'healthy' } else { 'unhealthy' })) -Summary 'CityRPG metrics endpoint on 127.0.0.1:3000/metrics.' -Evidence $cityProbe)) | Out-Null
$checks.Add((New-Check -Name 'brickadia-udp' -Status ($(if ($udp7777.Count -gt 0) { 'healthy' } else { 'unhealthy' })) -Summary 'Brickadia dedicated server UDP 7777 binding.' -Evidence @($udp7777 | Select-Object LocalAddress, LocalPort, OwningProcess))) | Out-Null

$bmfStatus = Read-JsonFile -Path $statusPath
$socketMetadata = Read-JsonFile -Path $socketPath
$bridgeStatus = Read-JsonFile -Path $bridgePath
$telemetry = Read-JsonFile -Path $telemetryPath
$frameTelemetry = Read-JsonFile -Path $frameTelemetryPath
$statusHealthy = $bmfStatus -and $bmfStatus.state -eq 'running' -and [bool]$bmfStatus.server_ready -and [int]$bmfStatus.plugin_errors -eq 0
$checks.Add((New-Check -Name 'bmf-runtime' -Status ($(if ($statusHealthy) { 'healthy' } else { 'unhealthy' })) -Summary 'BMF runtime status file is fresh, running, server-ready, and free of plugin errors.' -Evidence ([ordered]@{
  path = $statusPath
  ageSeconds = Get-FileAgeSeconds -Path $statusPath
  state = $bmfStatus.state
  version = $bmfStatus.version
  compatibility = $bmfStatus.compatibility_status
  pluginErrors = $bmfStatus.plugin_errors
  socketWorkerStarted = $bmfStatus.socket_worker_started
}))) | Out-Null

$socketCommand = Invoke-BmfSocketCommand -SocketMetadata $socketMetadata -Command 'bmf.status' -TimeoutMs 5000
$checks.Add((New-Check -Name 'bmf-socket-command' -Status ($(if ($socketCommand.ok) { 'healthy' } else { 'unhealthy' })) -Summary 'BMF native socket accepts and answers a bmf.status command.' -Evidence ([ordered]@{
  socketMetadataPath = $socketPath
  socketAgeSeconds = Get-FileAgeSeconds -Path $socketPath
  host = $socketMetadata.host
  port = $socketMetadata.port
  workerMode = $socketMetadata.workerMode
  pollCount = $socketMetadata.pollCount
  receivedCommands = $socketMetadata.receivedCommands
  sentResponses = $socketMetadata.sentResponses
  commandOk = $socketCommand.ok
  detail = $socketCommand.detail
  error = $socketCommand.error
}))) | Out-Null

$bridgeConnected = $bridgeStatus -and $bridgeStatus.socket -and [bool]$bridgeStatus.socket.connected
$checks.Add((New-Check -Name 'bmf-bridge-traffic' -Status ($(if ($bridgeConnected -or ($socketMetadata.receivedCommands -gt 0 -and $socketMetadata.sentResponses -gt 0)) { 'healthy' } else { 'degraded' })) -Summary 'BMF bridge/socket metadata shows live socket traffic.' -Evidence ([ordered]@{
  bridgeStatusPath = $bridgePath
  bridgeAgeSeconds = Get-FileAgeSeconds -Path $bridgePath
  bridgeConnected = $bridgeConnected
  bridgeErrors = $bridgeStatus.socket.errors
  socketReceivedCommands = $socketMetadata.receivedCommands
  socketReceivedMessages = $socketMetadata.receivedMessages
  socketSentResponses = $socketMetadata.sentResponses
  socketSentEvents = $socketMetadata.sentEvents
}))) | Out-Null

$frameOk = $frameTelemetry -and [bool]$frameTelemetry.hook_registered -and (Get-FileAgeSeconds -Path $frameTelemetryPath) -lt 30
$checks.Add((New-Check -Name 'frame-telemetry' -Status ($(if ($frameOk) { 'healthy' } else { 'degraded' })) -Summary 'Native BMF frame telemetry file is fresh and hook-registered.' -Evidence ([ordered]@{
  path = $frameTelemetryPath
  ageSeconds = Get-FileAgeSeconds -Path $frameTelemetryPath
  hookRegistered = $frameTelemetry.hook_registered
  avgMs = $frameTelemetry.window.delta_ms_avg
  maxMs = $frameTelemetry.window.delta_ms_max
  avgFps = $frameTelemetry.window.fps_avg
}))) | Out-Null

$telemetryOk = $telemetry -and (Get-FileAgeSeconds -Path $telemetryPath) -lt 30
$checks.Add((New-Check -Name 'bmf-telemetry' -Status ($(if ($telemetryOk) { 'healthy' } else { 'degraded' })) -Summary 'BMF telemetry file is fresh.' -Evidence ([ordered]@{
  path = $telemetryPath
  ageSeconds = Get-FileAgeSeconds -Path $telemetryPath
  commandTotal = $telemetry.commands.total
  commandOk = $telemetry.commands.ok
  commandError = $telemetry.commands.error
  socketPolls = $telemetry.socket.poll_count
}))) | Out-Null

$alloy = Ensure-Alloy -Root $BrickadiaRoot -ScrapeWait $ScrapeWaitSeconds
if ($alloy.started) {
  $startedActions.Add([ordered]@{ action = 'start-alloy'; result = $alloy.started }) | Out-Null
}
$alloyStatus = $alloy.status
$alloyHealthy = $alloyStatus -and $alloyStatus.ok -and ([double]($alloyStatus.samplesFailed -as [double]) -eq 0)
$checks.Add((New-Check -Name 'alloy-remote-write' -Status ($(if ($alloyHealthy) { 'healthy' } else { 'unhealthy' })) -Summary 'Grafana Alloy has scrape components and remote-write queue has no failed samples.' -Evidence ([ordered]@{
  port = $alloyStatus.port
  components = $alloyStatus.components
  samplesIn = $alloyStatus.samplesIn
  samplesSent = $alloyStatus.samplesSent
  samplesFailed = $alloyStatus.samplesFailed
  samplesPending = $alloyStatus.samplesPending
  started = $alloy.started
  error = $alloy.error
  missing = $alloy.missing
}))) | Out-Null

$processes = Get-ProcessSnapshot
$checks.Add((New-Check -Name 'processes' -Status 'info' -Summary 'Relevant local processes.' -Evidence @($processes))) | Out-Null

$unhealthy = @($checks | Where-Object { $_.status -eq 'unhealthy' })
$degraded = @($checks | Where-Object { $_.status -eq 'degraded' })
$overall = if ($unhealthy.Count -gt 0) { 'unhealthy' } elseif ($degraded.Count -gt 0) { 'degraded' } else { 'healthy' }
$startedActionArray = @($startedActions.ToArray())
$checkArray = @($checks.ToArray())

$report = [ordered]@{
  status = $overall
  mode = $Mode
  generatedAt = (Get-Date).ToUniversalTime().ToString('o')
  roots = [ordered]@{
    brickadia = $BrickadiaRoot
    bmf = $BmfRoot
    bmfDesktopApp = (Join-Path $BmfRoot 'apps\bmf-desktop')
    bmfRuntimeDir = $runtimeDir
  }
  startedActions = $startedActionArray
  checks = $checkArray
}

if ($Json) {
  $report | ConvertTo-Json -Depth 10
} else {
  Write-Output "BMF local stack status: $overall"
  foreach ($check in $checks) {
    Write-Output ("[{0}] {1}: {2}" -f $check.status, $check.name, $check.summary)
  }
  Write-Output ''
  Write-Output ($report | ConvertTo-Json -Depth 10)
}
