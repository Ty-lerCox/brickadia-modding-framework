param(
  [string]$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
  [string]$BrickadiaRoot = '',
  [string]$RuntimeModsDir = 'C:\Users\tycox\AppData\Roaming\omegga\steam_installs\main\Brickadia\Binaries\Win64\ue4ss\main\Mods',
  [string]$OutJson = '',
  [int]$Port = 7845
)

$ErrorActionPreference = 'Stop'

if (!$BrickadiaRoot) {
  $BrickadiaRoot = (Resolve-Path (Join-Path $Root '..\Brickadia')).Path
}
if (!$OutJson) {
  $OutJson = Join-Path $Root 'artifacts/local/bmf-plugin-watchdog-canary.json'
}

$errors = New-Object System.Collections.Generic.List[string]
$evidence = New-Object System.Collections.Generic.List[object]
$commandResults = New-Object System.Collections.Generic.List[object]
$startedAt = (Get-Date).ToUniversalTime().ToString('o')
$outPath = [System.IO.Path]::GetFullPath($OutJson)
$artifactRoot = Split-Path -Parent $outPath
$caseRoot = Join-Path $artifactRoot 'bmf-plugin-watchdog'
New-Item -ItemType Directory -Force -Path $caseRoot | Out-Null

$startServerScript = Join-Path $BrickadiaRoot 'brickadia-ue4ss-re/scripts/start-bridge-test-server.ps1'
$sourceBmfDir = Join-Path $Root 'framework/ue4ss/Mods/BMF'
$runtimeBmfDir = Join-Path $RuntimeModsDir 'BMF'
$runtimePluginDir = Join-Path $runtimeBmfDir 'plugins/WatchdogCanary'
$runtimeConfigPath = Join-Path $runtimeBmfDir 'config.json'
$runtimeLogPath = Join-Path $runtimeBmfDir 'runtime/bmf.log'
$runtimeAuditPath = Join-Path $runtimeBmfDir 'runtime/audit.jsonl'
$runtimePluginLogPath = Join-Path $runtimeBmfDir 'runtime/logs/plugins/WatchdogCanary.log'
$runtimeStatusPath = Join-Path $runtimeBmfDir 'runtime/status.json'
$bridgeDir = Join-Path $caseRoot "bridge-$Port"
$bridgeLogPath = Join-Path $bridgeDir 'bridge.log'
$startPath = Join-Path $caseRoot 'server-start.json'
$pluginStagePath = Join-Path $caseRoot 'watchdog-plugin-stage.json'
$bmfLogPath = Join-Path $caseRoot 'bmf.log'
$auditPath = Join-Path $caseRoot 'audit.jsonl'
$auditParsedPath = Join-Path $caseRoot 'audit-parsed.json'
$pluginLogPath = Join-Path $caseRoot 'WatchdogCanary.log'
$statusIsolatedPath = Join-Path $caseRoot 'status-isolated.json'
$statusReloadPath = Join-Path $caseRoot 'status-after-reload.json'
$serverPid = $null
$validationLockPath = Join-Path ([System.IO.Path]::GetFullPath($RuntimeModsDir)) '.bmf-active-validation.lock'
$validationLock = $null
$runtimeSnapshotTaken = $false
$runtimeMutationStarted = $false
$runtimeBmfExistedBefore = $false
$runtimeBackupRoot = ''
$runtimeBackupBmfDir = ''
$loadedBeforeReload = 0
$canaryEnvNames = @(
  'OMEGGA_BMF_SOCKET_ENABLED',
  'BMF_COMMAND_WORKER_ENABLED',
  'BMF_COMMAND_WORKER_ASYNC',
  'BMF_ALLOW_LOOPASYNC',
  'BMF_ALLOW_GAME_THREAD_LOOP',
  'BMF_ALLOW_DELAYED_WORKER_FALLBACK',
  'BMF_COMMAND_WORKER_POLL_MS'
)
$canaryEnvOriginal = @{}
foreach ($envName in $canaryEnvNames) {
  $canaryEnvOriginal[$envName] = [Environment]::GetEnvironmentVariable($envName, 'Process')
}

function Assert-RuntimeBmfTarget {
  $modsFull = [System.IO.Path]::GetFullPath($RuntimeModsDir).TrimEnd('\', '/')
  $bmfFull = [System.IO.Path]::GetFullPath($runtimeBmfDir).TrimEnd('\', '/')
  $expected = [System.IO.Path]::GetFullPath((Join-Path $modsFull 'BMF')).TrimEnd('\', '/')
  if (![string]::Equals($bmfFull, $expected, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to mutate unexpected BMF runtime path: $bmfFull (expected $expected)"
  }
}

function Acquire-ActiveBmfValidationLock {
  Assert-RuntimeBmfTarget
  New-Item -ItemType Directory -Force -Path $RuntimeModsDir | Out-Null
  try {
    $script:validationLock = [System.IO.File]::Open(
      $validationLockPath,
      [System.IO.FileMode]::OpenOrCreate,
      [System.IO.FileAccess]::ReadWrite,
      [System.IO.FileShare]::None
    )
  } catch [System.IO.IOException] {
    throw "Active BMF staging is already locked by another validation process: $validationLockPath. Run live BMF validators serially."
  }

  $validationLock.SetLength(0)
  $lockBytes = [System.Text.Encoding]::UTF8.GetBytes("pid=$PID`nvalidator=bmf-plugin-watchdog`n")
  $validationLock.Write($lockBytes, 0, $lockBytes.Length)
  $validationLock.Flush()
}

function Backup-ActiveBmfRuntime {
  Assert-RuntimeBmfTarget
  $script:runtimeBmfExistedBefore = Test-Path -LiteralPath $runtimeBmfDir -PathType Container
  $script:runtimeBackupRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("bmf-watchdog-validation-$PID-" + [guid]::NewGuid().ToString('N'))
  $script:runtimeBackupBmfDir = Join-Path $runtimeBackupRoot 'BMF'
  New-Item -ItemType Directory -Force -Path $runtimeBackupRoot | Out-Null
  try {
    if ($runtimeBmfExistedBefore) {
      Copy-Item -LiteralPath $runtimeBmfDir -Destination $runtimeBackupBmfDir -Recurse -Force
    }
    $script:runtimeSnapshotTaken = $true
  } catch {
    Remove-Item -LiteralPath $runtimeBackupRoot -Recurse -Force -ErrorAction SilentlyContinue
    throw
  }
}

function Capture-ActiveBmfEvidence {
  foreach ($pair in @(
    @($runtimeLogPath, $bmfLogPath),
    @($runtimeAuditPath, $auditPath),
    @($runtimePluginLogPath, $pluginLogPath)
  )) {
    if (Test-Path -LiteralPath $pair[0] -PathType Leaf) {
      Copy-Item -LiteralPath $pair[0] -Destination $pair[1] -Force
    }
  }
}

function Restore-ActiveBmfRuntime {
  if (!$runtimeSnapshotTaken) {
    return
  }
  Assert-RuntimeBmfTarget
  if ($runtimeBmfExistedBefore -and !(Test-Path -LiteralPath $runtimeBackupBmfDir -PathType Container)) {
    throw "Active BMF backup is missing: $runtimeBackupBmfDir"
  }
  if (Test-Path -LiteralPath $runtimeBmfDir) {
    Remove-Item -LiteralPath $runtimeBmfDir -Recurse -Force
  }
  if ($runtimeBmfExistedBefore) {
    Copy-Item -LiteralPath $runtimeBackupBmfDir -Destination $runtimeBmfDir -Recurse -Force
  }
  if ($runtimeBackupRoot -and (Test-Path -LiteralPath $runtimeBackupRoot)) {
    Remove-Item -LiteralPath $runtimeBackupRoot -Recurse -Force
  }
  $script:runtimeSnapshotTaken = $false
}

function Release-ActiveBmfValidationLock {
  if ($validationLock) {
    $validationLock.Dispose()
    $script:validationLock = $null
  }
  if (Test-Path -LiteralPath $validationLockPath) {
    Remove-Item -LiteralPath $validationLockPath -Force -ErrorAction SilentlyContinue
  }
}

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

function Invoke-BmfFileCommand(
  [string]$Command,
  [string]$Slug,
  [string[]]$ExpectedLines,
  [bool]$ExpectedOk = $true
) {
  $commandDir = Join-Path $runtimeBmfDir 'runtime/commands'
  $requestId = '{0}_{1}_{2}' -f $Slug, [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds(), [guid]::NewGuid().ToString('N').Substring(0, 8)
  $requestArtifactPath = Join-Path $caseRoot "$Slug-request.txt"
  $requestTempPath = Join-Path $commandDir "$requestId.request.tmp"
  $requestPath = Join-Path $commandDir "$requestId.request.txt"
  $responseArtifactPath = Join-Path $caseRoot "$Slug-response.txt"
  $responsePath = Join-Path $commandDir "$requestId.response.txt"
  foreach ($staleArtifact in @($requestArtifactPath, $responseArtifactPath)) {
    if (Test-Path -LiteralPath $staleArtifact) {
      Remove-Item -LiteralPath $staleArtifact -Force
    }
  }
  New-Item -ItemType Directory -Force -Path $commandDir | Out-Null
  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($requestArtifactPath, $Command, $utf8NoBom)
  Copy-Item -LiteralPath $requestArtifactPath -Destination $requestTempPath -Force
  Move-Item -LiteralPath $requestTempPath -Destination $requestPath -Force
  Add-Evidence 'text' $requestArtifactPath "Direct BMF file-command request for $Command"

  $responseLines = @()
  $deadline = (Get-Date).AddSeconds(15)
  while ((Get-Date) -lt $deadline -and !(Test-Path -LiteralPath $responsePath)) {
    Start-Sleep -Milliseconds 250
  }
  $responseObserved = Test-Path -LiteralPath $responsePath
  if ($responseObserved) {
    Copy-Item -LiteralPath $responsePath -Destination $responseArtifactPath -Force
    Add-Evidence 'text' $responseArtifactPath "BMF file-command response for $Command"
    $responseLines = @([System.IO.File]::ReadAllLines($responseArtifactPath))
  } else {
    $script:errors.Add("Timed out waiting for BMF file-command response: $Command")
  }

  $script:commandResults.Add([ordered]@{
    command = $Command
    transport = 'file-command'
    requestId = $requestId
    requestPath = [System.IO.Path]::GetFullPath($requestArtifactPath)
    responsePath = [System.IO.Path]::GetFullPath($responseArtifactPath)
    runtimeResponsePath = [System.IO.Path]::GetFullPath($responsePath)
    success = [bool]$responseObserved
    expectedOk = $ExpectedOk
    responseLineCount = $responseLines.Count
    lines = @($responseLines)
  })

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
  foreach ($path in @($startServerScript, $sourceBmfDir)) {
    if (!(Test-Path -LiteralPath $path)) {
      throw "Required path does not exist: $path"
    }
  }

  $existingServers = @(Get-CimInstance Win32_Process | Where-Object { $_.Name -eq 'BrickadiaServer-Win64-Shipping.exe' })
  if ($existingServers.Count -gt 0) {
    throw 'Refusing to stage the watchdog canary while another Brickadia server process is running.'
  }

  Acquire-ActiveBmfValidationLock
  foreach ($artifactPath in @(
    $bmfLogPath,
    $auditPath,
    $auditParsedPath,
    $pluginLogPath,
    $statusIsolatedPath,
    $statusReloadPath
  )) {
    if (Test-Path -LiteralPath $artifactPath) {
      Remove-Item -LiteralPath $artifactPath -Force
    }
  }
  Backup-ActiveBmfRuntime
  $runtimeMutationStarted = $true
  if (Test-Path -LiteralPath $runtimeBmfDir) {
    Remove-Item -LiteralPath $runtimeBmfDir -Recurse -Force
  }
  New-Item -ItemType Directory -Force -Path $runtimeBmfDir | Out-Null
  Copy-Item -Path (Join-Path $sourceBmfDir '*') -Destination $runtimeBmfDir -Recurse -Force
  $runtimeConfig = Read-JsonFile $runtimeConfigPath
  $runtimeConfig.jsonlLogs = $true
  $runtimeConfigJson = $runtimeConfig | ConvertTo-Json -Depth 20
  [System.IO.File]::WriteAllText($runtimeConfigPath, $runtimeConfigJson, (New-Object System.Text.UTF8Encoding($false)))
  $runtimePluginsDir = Join-Path $runtimeBmfDir 'plugins'
  if (Test-Path -LiteralPath $runtimePluginsDir) {
    Remove-Item -LiteralPath $runtimePluginsDir -Recurse -Force
  }
  New-Item -ItemType Directory -Force -Path $runtimePluginDir | Out-Null

  $manifestSource = @'
{
  "name": "WatchdogCanary",
  "version": "1.0.0",
  "author": "BMF",
  "description": "Temporary BMF plugin watchdog canary.",
  "capabilities": ["plugins.lifecycle"]
}
'@
  Set-Content -LiteralPath (Join-Path $runtimePluginDir 'bmf.json') -Value $manifestSource -Encoding UTF8

  $pluginSource = @'
local attempts = 0

return {
  name = "WatchdogCanary",
  onLoad = function(BMF)
    BMF.commands.register("bmf.watchdog.fail", "Watchdog failure canary.", function()
      attempts = attempts + 1
      BMF.logInfo("WatchdogCanary fail attempt", { attempt = attempts })
      error("WatchdogCanary forced failure " .. tostring(attempts), 0)
    end)
  end,
  onUnload = function(BMF, reason)
    BMF.logInfo("WatchdogCanary onUnload", { reason = reason })
  end,
}
'@
  Set-Content -LiteralPath (Join-Path $runtimePluginDir 'main.lua') -Value $pluginSource -Encoding UTF8

  [ordered]@{
    pluginDir = [System.IO.Path]::GetFullPath($runtimePluginDir)
    manifest = [System.IO.Path]::GetFullPath((Join-Path $runtimePluginDir 'bmf.json'))
    plugin = [System.IO.Path]::GetFullPath((Join-Path $runtimePluginDir 'main.lua'))
    command = 'bmf.watchdog.fail'
    expectedThreshold = 3
  } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $pluginStagePath -Encoding UTF8
  Add-Evidence 'json' $pluginStagePath 'Temporary WatchdogCanary plugin staging result'

  foreach ($path in @($runtimeLogPath, $runtimeAuditPath, $runtimeStatusPath)) {
    if (Test-Path -LiteralPath $path) {
      Remove-Item -LiteralPath $path -Force
    }
  }

  # The production socket is intentionally absent in this isolated process.
  # Enable the game-thread-only file worker solely as the canary control plane.
  $env:OMEGGA_BMF_SOCKET_ENABLED = '0'
  $env:BMF_COMMAND_WORKER_ENABLED = '1'
  $env:BMF_COMMAND_WORKER_ASYNC = '0'
  $env:BMF_ALLOW_LOOPASYNC = '0'
  $env:BMF_ALLOW_GAME_THREAD_LOOP = '0'
  $env:BMF_ALLOW_DELAYED_WORKER_FALLBACK = '1'
  $env:BMF_COMMAND_WORKER_POLL_MS = '250'

  $startOutput = & $startServerScript -BridgeDir $bridgeDir -Port $Port -VerifyWaitSeconds 30
  $startOutput | Set-Content -LiteralPath $startPath -Encoding UTF8
  $start = $startOutput | ConvertFrom-Json
  $serverPid = [int]$start.pid
  Add-Evidence 'json' $startPath 'Bridge test server startup result'
  if ($start.verified -ne $true) {
    $errors.Add("Bridge server did not verify: $($start.verify_reason)")
  } else {
    $readyDeadline = (Get-Date).AddSeconds(15)
    $workerReady = $false
    while ((Get-Date) -lt $readyDeadline) {
      if ($serverPid -and !(Get-Process -Id $serverPid -ErrorAction SilentlyContinue)) {
        break
      }
      $bridgeReady = Test-Path -LiteralPath $bridgeLogPath
      if ($bridgeReady) {
        $bridgeReady = (Get-Content -Raw -LiteralPath $bridgeLogPath) -match [regex]::Escape('Inbox poll tick 1')
      }
      if ($bridgeReady -and (Test-Path -LiteralPath $runtimeStatusPath)) {
        try {
          $readyStatus = Read-JsonFile $runtimeStatusPath
          if (
            $readyStatus.command_worker_started -eq $true -and
            [string]$readyStatus.command_worker_mode -eq 'ExecuteInGameThreadAfterFramesChain' -and
            [int]$readyStatus.scheduler_thread_violations -eq 0 -and
            [int]$readyStatus.scheduler_dispatch_errors -eq 0
          ) {
            $workerReady = $true
            break
          }
        } catch {
          # Retry while status.json is being replaced.
        }
      }
      Start-Sleep -Milliseconds 250
    }
    if (-not $workerReady) {
      throw 'BMF file-command worker and OmeggaBridge one-shot chains did not become ready.'
    }

    Invoke-BmfFileCommand 'bmf.watchdog.fail' 'bmf-watchdog-fail-1' @(
      'BMF bmf.watchdog.fail ERROR WatchdogCanary forced failure 1'
    )
    Invoke-BmfFileCommand 'bmf.watchdog.fail' 'bmf-watchdog-fail-2' @(
      'BMF bmf.watchdog.fail ERROR WatchdogCanary forced failure 2'
    )
    Invoke-BmfFileCommand 'bmf.watchdog.fail' 'bmf-watchdog-fail-3' @(
      'BMF bmf.watchdog.fail ERROR WatchdogCanary forced failure 3'
    )

    Start-Sleep -Seconds 1
    if (Test-Path -LiteralPath $runtimeStatusPath) {
      Copy-Item -LiteralPath $runtimeStatusPath -Destination $statusIsolatedPath -Force
      Add-Evidence 'json' $statusIsolatedPath 'BMF runtime status after watchdog isolation'
      $status = Read-JsonFile $statusIsolatedPath
      $loadedBeforeReload = [int]$status.plugins_loaded
      if ([int]$status.plugin_watchdog_isolated -ne 1) {
        $errors.Add("Expected one isolated plugin before reload, got $($status.plugin_watchdog_isolated).")
      }
      if ([string]$status.command_worker_mode -ne 'ExecuteInGameThreadAfterFramesChain') {
        $errors.Add("Unexpected command worker mode: $($status.command_worker_mode)")
      }
      if ([int]$status.scheduler_thread_violations -ne 0) {
        $errors.Add("Expected zero scheduler thread violations, got $($status.scheduler_thread_violations).")
      }
      if ([int]$status.scheduler_dispatch_errors -ne 0) {
        $errors.Add("Expected zero scheduler dispatch errors, got $($status.scheduler_dispatch_errors).")
      }
    } else {
      $errors.Add("BMF runtime status was not written before reload: $runtimeStatusPath")
    }

    Invoke-BmfFileCommand 'bmf.watchdog.fail' 'bmf-watchdog-fail-blocked' @(
      'BMF bmf.watchdog.fail PLUGIN_ISOLATED Plugin is isolated by watchdog',
      'plugin=WatchdogCanary',
      'error_count=3',
      'isolated=true'
    )

    Invoke-BmfFileCommand 'bmf.plugins.watchdog' 'bmf-plugins-watchdog-isolated' @(
      'BMF bmf.plugins.watchdog OK',
      'watchdog_enabled=true',
      'watchdog_threshold=3',
      'watchdog_isolated=1',
      'WatchdogCanary|errors=3|isolated=true|last_hook=command:bmf.watchdog.fail|last_error=WatchdogCanary forced failure 3'
    )

    Invoke-BmfFileCommand 'bmf.plugins' 'bmf-plugins-isolated' @(
      'BMF bmf.plugins OK',
      'plugin=WatchdogCanary version=1.0.0 capabilities=1 errors=3 isolated=true',
      'plugin_errors=3'
    )

    Invoke-BmfFileCommand 'bmf.audit.tail limit=50' 'bmf-audit-tail-watchdog' @(
      'BMF bmf.audit.tail OK',
      'plugin.isolated|severity=error|source=plugin|code=PLUGIN_ISOLATED|plugin=WatchdogCanary',
      'command.blocked|severity=warn|source=command|code=PLUGIN_ISOLATED|plugin=WatchdogCanary'
    )

    Invoke-BmfFileCommand 'bmf.reload' 'bmf-reload-watchdog' @(
      'BMF bmf.reload OK',
      "plugins_unloaded=$loadedBeforeReload",
      'unload_errors=0',
      "plugins_loaded=$loadedBeforeReload",
      'plugin_errors=0'
    )

    Start-Sleep -Seconds 1
    if (Test-Path -LiteralPath $runtimeStatusPath) {
      Copy-Item -LiteralPath $runtimeStatusPath -Destination $statusReloadPath -Force
      Add-Evidence 'json' $statusReloadPath 'BMF runtime status after watchdog reload recovery'
      $status = Read-JsonFile $statusReloadPath
      if ([int]$status.plugin_watchdog_isolated -ne 0) {
        $errors.Add("Expected zero isolated plugins after reload, got $($status.plugin_watchdog_isolated).")
      }
      if ([int]$status.plugins_loaded -ne $loadedBeforeReload) {
        $errors.Add("Expected $loadedBeforeReload plugins after reload, got $($status.plugins_loaded).")
      }
    } else {
      $errors.Add("BMF runtime status was not written after reload: $runtimeStatusPath")
    }

    Invoke-BmfFileCommand 'bmf.plugins.watchdog' 'bmf-plugins-watchdog-after-reload' @(
      'BMF bmf.plugins.watchdog OK',
      'watchdog_enabled=true',
      'watchdog_threshold=3',
      'watchdog_isolated=0',
      'WatchdogCanary|errors=0|isolated=false|last_hook=|last_error='
    )
  }
} catch {
  $errors.Add($_.Exception.Message)
} finally {
  try {
    try {
      if ($serverPid) {
        Stop-Process -Id $serverPid -Force -ErrorAction SilentlyContinue
        Wait-Process -Id $serverPid -Timeout 10 -ErrorAction SilentlyContinue
      }
      Get-CimInstance Win32_Process |
        Where-Object { $_.Name -eq 'BrickadiaServer-Win64-Shipping.exe' -and $_.CommandLine -like "*-port=`"$Port`*"} |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    } catch {
      $errors.Add("Failed to stop the watchdog validation server: $($_.Exception.Message)")
    }
    if ($runtimeMutationStarted) {
      try {
        Capture-ActiveBmfEvidence
      } catch {
        $errors.Add("Failed to capture watchdog validation evidence: $($_.Exception.Message)")
      }
      try {
        Restore-ActiveBmfRuntime
      } catch {
        $errors.Add("Failed to restore the active BMF runtime: $($_.Exception.Message). Backup retained at $runtimeBackupRoot")
      }
    }
  } finally {
    Release-ActiveBmfValidationLock
    foreach ($envName in $canaryEnvNames) {
      [Environment]::SetEnvironmentVariable($envName, $canaryEnvOriginal[$envName], 'Process')
    }
  }
}

if (Test-Path -LiteralPath $bmfLogPath) {
  Add-Evidence 'log' $bmfLogPath 'BMF runtime log with watchdog evidence'
  $logText = Get-Content -Raw -LiteralPath $bmfLogPath
  foreach ($needle in @(
    'plugin WatchdogCanary command:bmf.watchdog.fail failed: WatchdogCanary forced failure 1',
    'plugin WatchdogCanary isolated by watchdog errors=3 threshold=3',
    'WatchdogCanary onUnload'
  )) {
    if ($logText -notmatch [regex]::Escape($needle)) {
      $errors.Add("BMF log missing expected line: $needle")
    }
  }
} elseif ($runtimeMutationStarted) {
  $errors.Add("BMF runtime log was not written: $runtimeLogPath")
}

if (Test-Path -LiteralPath $auditPath) {
  Add-Evidence 'jsonl' $auditPath 'BMF audit JSONL with watchdog isolation records'
  $records = @()
  foreach ($line in [System.IO.File]::ReadAllLines($auditPath)) {
    if ($line.Trim()) {
      $records += ($line | ConvertFrom-Json)
    }
  }
  $records | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $auditParsedPath -Encoding UTF8
  Add-Evidence 'json' $auditParsedPath 'Parsed watchdog audit records'
  $isolated = @($records | Where-Object { $_.action -eq 'plugin.isolated' -and $_.code -eq 'PLUGIN_ISOLATED' -and $_.plugin -eq 'WatchdogCanary' })
  if ($isolated.Count -lt 1) {
    $errors.Add("Expected at least one plugin.isolated audit record for WatchdogCanary.")
  }
  $blocked = @($records | Where-Object { $_.action -eq 'command.blocked' -and $_.code -eq 'PLUGIN_ISOLATED' -and $_.plugin -eq 'WatchdogCanary' })
  if ($blocked.Count -lt 1) {
    $errors.Add("Expected at least one command.blocked audit record for WatchdogCanary.")
  }
} elseif ($runtimeMutationStarted) {
  $errors.Add("BMF audit log was not written: $runtimeAuditPath")
}

if (Test-Path -LiteralPath $pluginLogPath) {
  Add-Evidence 'log' $pluginLogPath 'WatchdogCanary per-plugin log'
  $pluginLog = Get-Content -Raw -LiteralPath $pluginLogPath
  if ($pluginLog -match 'forced failure 4') {
    $errors.Add("Fourth watchdog command reached plugin handler; expected PLUGIN_ISOLATED block before handler.")
  }
} elseif ($runtimeMutationStarted) {
  $errors.Add("Plugin log was not written: $runtimePluginLogPath")
}

$resultStatus = 'failed'
if ($errors.Count -eq 0) {
  $resultStatus = 'passed'
}

$result = [ordered]@{
  feature = 'bmf.plugins.watchdog'
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
