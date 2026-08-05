param(
  [string]$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
  [string]$BrickadiaRoot = '',
  [string]$RuntimeModsDir = 'C:\Users\tycox\AppData\Roaming\omegga\steam_installs\main\Brickadia\Binaries\Win64\ue4ss\main\Mods',
  [string]$OutJson = '',
  [int]$Port = 7835
)

$ErrorActionPreference = 'Stop'

if (!$BrickadiaRoot) {
  $BrickadiaRoot = (Resolve-Path (Join-Path $Root '..\Brickadia')).Path
}
if (!$OutJson) {
  $OutJson = Join-Path $Root 'artifacts/local/bmf-timers-canary.json'
}

$errors = New-Object System.Collections.Generic.List[string]
$evidence = New-Object System.Collections.Generic.List[object]
$commandResults = New-Object System.Collections.Generic.List[object]
$startedAt = (Get-Date).ToUniversalTime().ToString('o')
$outPath = [System.IO.Path]::GetFullPath($OutJson)
$artifactRoot = Split-Path -Parent $outPath
$caseRoot = Join-Path $artifactRoot 'bmf-timers'
New-Item -ItemType Directory -Force -Path $caseRoot | Out-Null

$startServerScript = Join-Path $BrickadiaRoot 'brickadia-ue4ss-re/scripts/start-bridge-test-server.ps1'
$sendRpcScript = Join-Path $BrickadiaRoot 'brickadia-ue4ss-re/scripts/send-bridge-rpc.js'
$sourceBmfDir = Join-Path $Root 'framework/ue4ss/Mods/BMF'
$runtimeBmfDir = Join-Path $RuntimeModsDir 'BMF'
$runtimePluginDir = Join-Path $runtimeBmfDir 'plugins/TimerCanary'
$runtimeLogPath = Join-Path $runtimeBmfDir 'runtime/bmf.log'
$runtimePluginLogPath = Join-Path $runtimeBmfDir 'runtime/logs/plugins/TimerCanary.log'
$runtimeStatusPath = Join-Path $runtimeBmfDir 'runtime/status.json'
$bridgeDir = Join-Path $caseRoot "bridge-$Port"
$bridgeLogPath = Join-Path $bridgeDir 'bridge.log'
$bridgeStatusPath = Join-Path $bridgeDir 'status.json'
$startPath = Join-Path $caseRoot 'server-start.json'
$pluginStagePath = Join-Path $caseRoot 'timer-plugin-stage.json'
$bmfLogPath = Join-Path $caseRoot 'bmf.log'
$pluginLogPath = Join-Path $caseRoot 'TimerCanary.log'
$statusPath = Join-Path $caseRoot 'status.json'
$serverPid = $null
$validationLockPath = Join-Path ([System.IO.Path]::GetFullPath($RuntimeModsDir)) '.bmf-active-validation.lock'
$validationLock = $null
$runtimeSnapshotTaken = $false
$runtimeMutationStarted = $false
$runtimeBmfExistedBefore = $false
$runtimeBackupRoot = ''
$runtimeBackupBmfDir = ''

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
  $lockBytes = [System.Text.Encoding]::UTF8.GetBytes("pid=$PID`nvalidator=bmf-timers`n")
  $validationLock.Write($lockBytes, 0, $lockBytes.Length)
  $validationLock.Flush()
}

function Backup-ActiveBmfRuntime {
  Assert-RuntimeBmfTarget
  $script:runtimeBmfExistedBefore = Test-Path -LiteralPath $runtimeBmfDir -PathType Container
  $script:runtimeBackupRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("bmf-timers-validation-$PID-" + [guid]::NewGuid().ToString('N'))
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
    @($runtimePluginLogPath, $pluginLogPath),
    @($runtimeStatusPath, $statusPath)
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

function Invoke-BmfConsoleCommand([string]$Command, [string]$Slug, [string[]]$ExpectedLines) {
  $rpcPath = Join-Path $caseRoot "$Slug-rpc.json"
  $bridgeCommand = "Omegga.Bridge.BMF $Command"
  $responseArtifactPath = Join-Path $caseRoot "$Slug-response.txt"
  foreach ($staleArtifact in @($rpcPath, $responseArtifactPath)) {
    if (Test-Path -LiteralPath $staleArtifact) {
      Remove-Item -LiteralPath $staleArtifact -Force
    }
  }
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
    $deadline = (Get-Date).AddSeconds(12)
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
  if ($joined -notmatch '^ok=true') {
    $script:errors.Add("BMF response did not report ok=true for command: $Command")
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

  $existingServers = @(Get-CimInstance Win32_Process | Where-Object { $_.Name -eq 'BrickadiaServer-Win64-Shipping.exe' })
  if ($existingServers.Count -gt 0) {
    throw 'Refusing to stage the timer canary while another Brickadia server process is running.'
  }

  Acquire-ActiveBmfValidationLock
  foreach ($artifactPath in @($bmfLogPath, $pluginLogPath, $statusPath)) {
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
  $runtimePluginsDir = Join-Path $runtimeBmfDir 'plugins'
  if (Test-Path -LiteralPath $runtimePluginsDir) {
    Remove-Item -LiteralPath $runtimePluginsDir -Recurse -Force
  }
  New-Item -ItemType Directory -Force -Path $runtimePluginDir | Out-Null

  $manifestSource = @'
{
  "name": "TimerCanary",
  "version": "1.0.0",
  "author": "BMF",
  "description": "Temporary timer canary plugin.",
  "capabilities": ["plugins.lifecycle", "timers.basic"]
}
'@
  Set-Content -LiteralPath (Join-Path $runtimePluginDir 'bmf.json') -Value $manifestSource -Encoding UTF8

  $pluginSource = @'
local state = {
  after = 0,
  every = 0,
  everyLastCount = 0,
  cancelled = 0,
  cancelBefore = false,
  everyCancelled = false,
}

return {
  name = "TimerCanary",
  onLoad = function(BMF)
    local cancelled_id = BMF.timers.after(700, function()
      state.cancelled = state.cancelled + 1
      BMF.logError("TimerCanary cancelled timer unexpectedly fired")
    end)
    state.cancelBefore = BMF.timers.cancel(cancelled_id)

    BMF.timers.after(250, function()
      state.after = state.after + 1
      BMF.logInfo("TimerCanary after fired", { phase = "after", count = state.after })
    end)

    BMF.timers.every(200, function(id, count)
      state.every = state.every + 1
      state.everyLastCount = count
      BMF.logInfo("TimerCanary every fired", { phase = "every", count = count })
      if count >= 3 then
        state.everyCancelled = BMF.timers.cancel(id)
        BMF.logInfo(
          "TimerCanary complete"
            .. " after_count=" .. tostring(state.after)
            .. " every_count=" .. tostring(state.every)
            .. " every_last_count=" .. tostring(state.everyLastCount)
            .. " cancelled_count=" .. tostring(state.cancelled)
            .. " cancel_before=" .. tostring(state.cancelBefore)
            .. " every_cancelled=" .. tostring(state.everyCancelled)
            .. " active_count=" .. tostring(BMF.timers.activeCount()))
        BMF.timers.after(400, function()
          BMF.logInfo(
            "TimerCanary post-completion sentinel fired"
              .. " active_count=" .. tostring(BMF.timers.activeCount()))
        end)
      end
    end)

    BMF.commands.register("bmf.timers.canary", "Timer canary.", function()
      return BMF.result(true, "OK", "Timer canary handled", {
        lines = {
          "after_count=" .. tostring(state.after),
          "every_count=" .. tostring(state.every),
          "every_last_count=" .. tostring(state.everyLastCount),
          "cancelled_count=" .. tostring(state.cancelled),
          "cancel_before=" .. tostring(state.cancelBefore),
          "every_cancelled=" .. tostring(state.everyCancelled),
          "active_count=" .. tostring(BMF.timers.activeCount()),
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
    command = 'bmf.timers.canary'
  } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $pluginStagePath -Encoding UTF8
  Add-Evidence 'json' $pluginStagePath 'Temporary TimerCanary plugin staging result'

  if (Test-Path -LiteralPath $runtimeLogPath) {
    Remove-Item -LiteralPath $runtimeLogPath -Force
  }
  if (Test-Path -LiteralPath $runtimeStatusPath) {
    Remove-Item -LiteralPath $runtimeStatusPath -Force
  }

  $startOutput = & $startServerScript -BridgeDir $bridgeDir -Port $Port -VerifyWaitSeconds 30
  $startOutput | Set-Content -LiteralPath $startPath -Encoding UTF8
  $start = $startOutput | ConvertFrom-Json
  $serverPid = [int]$start.pid
  Add-Evidence 'json' $startPath 'Bridge test server startup result'
  if ($start.verified -ne $true) {
    $errors.Add("Bridge server did not verify: $($start.verify_reason)")
  } else {
    $completionNeedle = 'TimerCanary complete after_count=1 every_count=3 every_last_count=3 cancelled_count=0 cancel_before=true every_cancelled=true active_count=0'
    $sentinelNeedle = 'TimerCanary post-completion sentinel fired active_count=0'
    $completionDeadline = (Get-Date).AddSeconds(12)
    $completionObserved = $false
    $sentinelObserved = $false
    while ((Get-Date) -lt $completionDeadline) {
      if (Test-Path -LiteralPath $runtimePluginLogPath) {
        $livePluginLog = Get-Content -Raw -LiteralPath $runtimePluginLogPath
        if ($livePluginLog -match [regex]::Escape($completionNeedle)) {
          $completionObserved = $true
        }
        if ($livePluginLog -match [regex]::Escape($sentinelNeedle)) {
          $sentinelObserved = $true
        }
        if ($completionObserved -and $sentinelObserved) {
          break
        }
      }
      Start-Sleep -Milliseconds 250
    }
    if (-not $completionObserved) {
      $errors.Add('Timer canary did not publish its automatic completion record.')
    }
    if (-not $sentinelObserved) {
      $errors.Add('Timer canary post-completion sentinel did not fire.')
    }

    # Headless validation intentionally disables both command transports, which
    # are the production status-heartbeat owners. The exact completion record
    # above proves four timer callbacks and the sentinel proves the one-shot
    # chain remains healthy after the canary timers finish.
    if ($serverPid -and !(Get-Process -Id $serverPid -ErrorAction SilentlyContinue)) {
      $errors.Add('Bridge server exited after the timer canary completed.')
    }
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
      $errors.Add("Failed to stop the timer validation server: $($_.Exception.Message)")
    }
    if ($runtimeMutationStarted) {
      try {
        Capture-ActiveBmfEvidence
      } catch {
        $errors.Add("Failed to capture timer validation evidence: $($_.Exception.Message)")
      }
      try {
        Restore-ActiveBmfRuntime
      } catch {
        $errors.Add("Failed to restore the active BMF runtime: $($_.Exception.Message). Backup retained at $runtimeBackupRoot")
      }
    }
  } finally {
    Release-ActiveBmfValidationLock
  }
}

if (Test-Path -LiteralPath $bmfLogPath) {
  Add-Evidence 'log' $bmfLogPath 'BMF framework log with timer evidence'
  $logText = Get-Content -Raw -LiteralPath $bmfLogPath
  foreach ($needle in @(
    '[TimerCanary] TimerCanary after fired',
    '[TimerCanary] TimerCanary every fired',
    '[TimerCanary] TimerCanary complete',
    'after_count=1',
    'every_count=3',
    'every_last_count=3',
    'cancelled_count=0',
    'cancel_before=true',
    'every_cancelled=true',
    'active_count=0',
    'TimerCanary post-completion sentinel fired active_count=0'
  )) {
    if ($logText -notmatch [regex]::Escape($needle)) {
      $errors.Add("BMF log missing expected line: $needle")
    }
  }
  if ($logText -match [regex]::Escape('TimerCanary cancelled timer unexpectedly fired')) {
    $errors.Add('Cancelled timer unexpectedly fired according to BMF log.')
  }
} elseif ($runtimeMutationStarted) {
  $errors.Add("BMF runtime log was not written: $runtimeLogPath")
}

if (Test-Path -LiteralPath $pluginLogPath) {
  Add-Evidence 'log' $pluginLogPath 'TimerCanary per-plugin log'
} elseif ($runtimeMutationStarted) {
  $errors.Add("Plugin log was not written: $runtimePluginLogPath")
}

if (Test-Path -LiteralPath $bridgeLogPath) {
  Add-Evidence 'log' $bridgeLogPath 'OmeggaBridge one-shot scheduler activity during timer canary'
  $bridgeLogText = Get-Content -Raw -LiteralPath $bridgeLogPath
  foreach ($needle in @(
    'Starting game-thread-only inbox poller via ExecuteInGameThreadAfterFramesChain',
    'Inbox poll tick 1',
    'Scheduling callback via ExecuteInGameThread EngineTick'
  )) {
    if ($bridgeLogText -notmatch [regex]::Escape($needle)) {
      $errors.Add("Bridge log missing expected scheduler evidence: $needle")
    }
  }
} elseif ($runtimeMutationStarted) {
  $errors.Add("Bridge log was not written: $bridgeLogPath")
}

if (Test-Path -LiteralPath $bridgeStatusPath) {
  Add-Evidence 'json' $bridgeStatusPath 'OmeggaBridge scheduler status during timer canary'
  try {
    $bridgeStatus = Read-JsonFile $bridgeStatusPath
    if ($bridgeStatus.inbox_loop_active -ne $true) {
      $errors.Add('Expected the OmeggaBridge inbox loop to remain active.')
    }
    if ([string]$bridgeStatus.inbox_scheduler -ne 'ExecuteInGameThreadAfterFramesChain') {
      $errors.Add("Unexpected OmeggaBridge scheduler: $($bridgeStatus.inbox_scheduler)")
    }
    foreach ($field in @(
      'inbox_loop_cancel_error_total',
      'inbox_loop_callback_error_total',
      'inbox_loop_thread_violation_total'
    )) {
      if ([int]$bridgeStatus.$field -ne 0) {
        $errors.Add("Expected zero $field, got $($bridgeStatus.$field).")
      }
    }
  } catch {
    $errors.Add("Could not parse OmeggaBridge status: $($_.Exception.Message)")
  }
} elseif ($runtimeMutationStarted) {
  $errors.Add("OmeggaBridge status was not written: $bridgeStatusPath")
}

if (Test-Path -LiteralPath $statusPath) {
  Add-Evidence 'json' $statusPath 'BMF runtime status after timer canary'
  try {
    $status = Read-JsonFile $statusPath
    if ([int]$status.plugins_loaded -lt 1) {
      $errors.Add("Expected at least one plugin loaded, got $($status.plugins_loaded).")
    }
    if ($status.timers_pump_started -ne $true) {
      $errors.Add('Expected the bounded timer pump to remain started.')
    }
    if ([string]$status.timers_pump_mode -ne 'ExecuteInGameThreadAfterFramesChain') {
      $errors.Add("Unexpected timer pump mode: $($status.timers_pump_mode)")
    }
    if ([int]$status.scheduler_thread_violations -ne 0) {
      $errors.Add("Expected zero scheduler thread violations, got $($status.scheduler_thread_violations).")
    }
    if ([int]$status.scheduler_thread_check_errors -ne 0) {
      $errors.Add("Expected zero scheduler thread-check errors, got $($status.scheduler_thread_check_errors).")
    }
    if ([int]$status.scheduler_dispatch_errors -ne 0) {
      $errors.Add("Expected zero scheduler dispatch errors, got $($status.scheduler_dispatch_errors).")
    }
    if ([int]$status.timers_callback_errors -ne 0) {
      $errors.Add("Expected zero timer callback errors, got $($status.timers_callback_errors).")
    }
  } catch {
    $errors.Add("Could not parse BMF status: $($_.Exception.Message)")
  }
} elseif ($runtimeMutationStarted) {
  $errors.Add("BMF runtime status was not written: $runtimeStatusPath")
}

$resultStatus = 'failed'
if ($errors.Count -eq 0) {
  $resultStatus = 'passed'
}

$result = [ordered]@{
  feature = 'bmf.timers.runtime'
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
