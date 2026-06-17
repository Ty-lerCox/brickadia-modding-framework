param(
  [string]$OmeggaDir = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
  [int]$StartupTimeoutSec = 180,
  [int]$CommandTimeoutSec = 45
)

$ErrorActionPreference = 'Stop'

$traceFile = Join-Path $OmeggaDir 'windows-bridge-trace.log'
$stdoutQueue = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
$stderrQueue = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
$allLines = [System.Collections.Generic.List[string]]::new()
$stdoutHandler = $null
$stderrHandler = $null
$process = $null

function Add-OutputLine([string]$prefix, [string]$line) {
  $formatted = "$prefix $line"
  $allLines.Add($formatted)
  Write-Host $formatted
}

function Drain-ProcessOutput {
  $line = $null

  while ($stdoutQueue.TryDequeue([ref]$line)) {
    Add-OutputLine '[stdout]' $line
  }

  while ($stderrQueue.TryDequeue([ref]$line)) {
    Add-OutputLine '[stderr]' $line
  }
}

function Wait-ForMatch([string[]]$patterns, [int]$timeoutSec, [string]$label) {
  $deadline = (Get-Date).AddSeconds($timeoutSec)
  while ((Get-Date) -lt $deadline) {
    Drain-ProcessOutput

    foreach ($line in $allLines) {
      foreach ($pattern in $patterns) {
        if ($line -match $pattern) {
          return [pscustomobject]@{
            Label = $label
            Pattern = $pattern
            Line = $line
          }
        }
      }
    }

    if ($process.HasExited) {
      Drain-ProcessOutput
      throw "Probe target exited before '$label' completed. Exit code: $($process.ExitCode)"
    }

    Start-Sleep -Milliseconds 200
  }

  Drain-ProcessOutput
  return $null
}

function Stop-ProbeProcess {
  if (-not $process) {
    return
  }

  try {
    if (-not $process.HasExited) {
      $process.StandardInput.WriteLine('/stop')
      $process.StandardInput.Flush()
      if (-not $process.WaitForExit(15000)) {
        $process.Kill($true)
        $process.WaitForExit()
      }
    }
  } catch {
    if (-not $process.HasExited) {
      $process.Kill($true)
      $process.WaitForExit()
    }
  }
}

try {
  if (Test-Path $traceFile) {
    Remove-Item $traceFile -Force
  }

  $psi = [System.Diagnostics.ProcessStartInfo]::new()
  $psi.FileName = 'node.exe'
  $psi.Arguments = '--enable-source-maps index.js'
  $psi.WorkingDirectory = $OmeggaDir
  $psi.UseShellExecute = $false
  $psi.RedirectStandardInput = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.CreateNoWindow = $true
  $psi.Environment['OMEGGA_BRIDGE_SENDKEYS'] = '1'
  $psi.Environment['OMEGGA_BRIDGE_KEEP_VISIBLE'] = '1'
  $psi.Environment['OMEGGA_BRIDGE_DEBUG'] = '1'
  $psi.Environment['OMEGGA_BRIDGE_TRACE'] = $traceFile
  $psi.Environment['NO_COLOR'] = '1'
  $psi.Environment['FORCE_COLOR'] = '0'

  $process = [System.Diagnostics.Process]::new()
  $process.StartInfo = $psi

  $stdoutHandler = [System.Diagnostics.DataReceivedEventHandler]{
    param($sender, $eventArgs)
    if ($null -ne $eventArgs.Data) {
      $stdoutQueue.Enqueue($eventArgs.Data)
    }
  }

  $stderrHandler = [System.Diagnostics.DataReceivedEventHandler]{
    param($sender, $eventArgs)
    if ($null -ne $eventArgs.Data) {
      $stderrQueue.Enqueue($eventArgs.Data)
    }
  }

  $process.add_OutputDataReceived($stdoutHandler)
  $process.add_ErrorDataReceived($stderrHandler)

  if (-not $process.Start()) {
    throw 'Failed to start Omegga probe process'
  }

  $process.BeginOutputReadLine()
  $process.BeginErrorReadLine()

  $started = Wait-ForMatch @(
    'Server has started',
    'Select authentication method',
    'Server failed authentication check'
  ) $StartupTimeoutSec 'startup'

  if (-not $started) {
    throw "Timed out waiting for server startup after $StartupTimeoutSec seconds"
  }

  if ($started.Pattern -eq 'Select authentication method') {
    throw 'Omegga requested interactive authentication during the probe'
  }

  if ($started.Pattern -eq 'Server failed authentication check') {
    throw 'Brickadia authentication failed during the probe'
  }

  $mapLoaded = Wait-ForMatch @(
    'Map changed to',
    'World successfully loaded'
  ) 60 'map load'

  if (-not $mapLoaded) {
    throw 'Timed out waiting for the initial map load'
  }

  Add-OutputLine '[probe]' 'Sending /status'
  $process.StandardInput.WriteLine('/status')
  $process.StandardInput.Flush()

  $statusResult = Wait-ForMatch @(
    'Server Status',
    'An error occurred while getting server status',
    'Server Not Responding',
    'Server caught unhandled exception'
  ) $CommandTimeoutSec 'status command'

  Add-OutputLine '[probe]' 'Sending /cmd Server.Status'
  $process.StandardInput.WriteLine('/cmd Server.Status')
  $process.StandardInput.Flush()

  $rawStatusResult = Wait-ForMatch @(
    'LogConsoleCommands:',
    'Server Not Responding',
    'Server caught unhandled exception'
  ) $CommandTimeoutSec 'raw server status command'

  $result = [pscustomobject]@{
    startupMatched = $started.Line
    mapMatched = $mapLoaded.Line
    statusMatched = if ($statusResult) { $statusResult.Line } else { $null }
    rawStatusMatched = if ($rawStatusResult) { $rawStatusResult.Line } else { $null }
    statusSucceeded = [bool]($statusResult -and $statusResult.Pattern -eq 'Server Status')
    rawStatusSucceeded = [bool]($rawStatusResult -and $rawStatusResult.Pattern -eq 'LogConsoleCommands:')
    traceFile = $traceFile
  }

  Add-OutputLine '[probe-result]' ($result | ConvertTo-Json -Compress)

  if (Test-Path $traceFile) {
    Add-OutputLine '[trace]' '--- begin bridge trace ---'
    Get-Content -Path $traceFile | ForEach-Object { Add-OutputLine '[trace]' $_ }
    Add-OutputLine '[trace]' '--- end bridge trace ---'
  }

  if (-not $result.statusSucceeded -and -not $result.rawStatusSucceeded) {
    exit 1
  }

  exit 0
} finally {
  try {
    Stop-ProbeProcess
  } finally {
    if ($process) {
      try { $process.CancelOutputRead() } catch {}
      try { $process.CancelErrorRead() } catch {}
      try {
        if ($stdoutHandler) { $process.remove_OutputDataReceived($stdoutHandler) }
      } catch {}
      try {
        if ($stderrHandler) { $process.remove_ErrorDataReceived($stderrHandler) }
      } catch {}
      $process.Dispose()
    }
  }
}
