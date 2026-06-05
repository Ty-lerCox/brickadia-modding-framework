param(
  [int]$ProcessId = 0,
  [string]$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
  [string]$BrickadiaRoot = '',
  [string]$BridgeDir = '',
  [string]$RuntimeBmfDir = '',
  [string]$Component = '',
  [string]$ControlPath = '',
  [string]$StatusPath = '',
  [string]$EventPath = '',
  [string]$BuildScript = '',
  [string]$InjectScript = '',
  [string]$SourcePath = '',
  [string]$DllName = '',
  [UInt64[]]$ServerModifyComponentRvas = @([UInt64]0x428DD80, [UInt64]0x428DFF0),
  [string[]]$AllowedPrefix = @('buyweapon:'),
  [string[]]$AllowedContext = @(),
  [switch]$TrustExistingStatus,
  [switch]$SkipInject,
  [switch]$ForceReinject,
  [int]$CommandTimeoutSeconds = 30,
  [int]$ResponseTimeoutSeconds = 20,
  [int]$VerificationTimeoutSeconds = 20,
  [string]$OutJson = ''
)

$ErrorActionPreference = 'Stop'

function Format-Hex64([UInt64]$Value) {
  return ('0x{0:X}' -f $Value)
}

function Convert-HexToUInt64([string]$Value, [string]$Name) {
  if (!$Value) {
    throw "Missing required hex value: $Name"
  }
  $text = $Value.Trim()
  if ($text.StartsWith('0x', [System.StringComparison]::OrdinalIgnoreCase)) {
    $text = $text.Substring(2)
  }
  if (!$text) {
    throw "Missing required hex value: $Name"
  }
  return [Convert]::ToUInt64($text, 16)
}

function Convert-KeyValueLines([string[]]$Lines) {
  $map = @{}
  foreach ($line in $Lines) {
    if ($line -match '^\s*([^=\s]+)\s*=\s*(.*)$') {
      $map[$Matches[1]] = $Matches[2].Trim()
    }
  }
  return $map
}

function Read-KeyValueFile([string]$Path) {
  if (!(Test-Path -LiteralPath $Path)) {
    return @{}
  }
  return Convert-KeyValueLines ([System.IO.File]::ReadAllLines($Path))
}

function Expand-ListValues([string[]]$Values) {
  $items = New-Object System.Collections.Generic.List[string]
  foreach ($value in @($Values)) {
    foreach ($part in ([string]$value -split ',')) {
      $text = $part.Trim()
      if ($text -and !$items.Contains($text)) {
        $items.Add($text)
      }
    }
  }
  return @($items.ToArray())
}

function Find-LatestBridgeDir([string]$BrickadiaRootPath) {
  $bridgeRoot = Join-Path $BrickadiaRootPath 'omegga-master/omegga-master/data/ue4ss-bridge'
  if (!(Test-Path -LiteralPath $bridgeRoot)) {
    throw "Bridge directory root does not exist: $bridgeRoot"
  }
  $dir = Get-ChildItem -LiteralPath $bridgeRoot -Directory |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1
  if (!$dir) {
    throw "No Omegga bridge session directories found under: $bridgeRoot"
  }
  return $dir.FullName
}

function Invoke-BmfCommand([string]$Command) {
  if (!$script:SendRpcScript -or !(Test-Path -LiteralPath $script:SendRpcScript)) {
    throw "send-bridge-rpc.js was not found: $script:SendRpcScript"
  }
  if (!$script:BridgeDir -or !(Test-Path -LiteralPath $script:BridgeDir)) {
    throw "BridgeDir does not exist: $script:BridgeDir"
  }
  if (!$script:RuntimeBmfDir -or !(Test-Path -LiteralPath $script:RuntimeBmfDir)) {
    throw "RuntimeBmfDir does not exist: $script:RuntimeBmfDir"
  }

  $bridgeCommand = "Omegga.Bridge.BMF $Command"
  $waitMs = [Math]::Max(1000, $CommandTimeoutSeconds * 1000)
  $output = & node $script:SendRpcScript --dir $script:BridgeDir --method console.exec --command-raw $bridgeCommand --wait-ms $waitMs
  $rpc = ($output -join "`n") | ConvertFrom-Json
  if ($rpc.result.accepted -ne $true -or $rpc.complete.success -ne $true) {
    throw "BMF command was not accepted/completed by the bridge: $Command"
  }

  $requestId = ''
  foreach ($chunk in @($rpc.chunks)) {
    $line = [string]$chunk.line
    if ($line -match '^queued_bmf_command id=(.+)$') {
      $requestId = $Matches[1].Trim()
      break
    }
  }
  if (!$requestId) {
    throw "Bridge response did not include a queued BMF command id for: $Command"
  }

  $responsePath = Join-Path $script:RuntimeBmfDir "runtime/commands/$requestId.response.txt"
  $deadline = (Get-Date).AddSeconds($ResponseTimeoutSeconds)
  while ((Get-Date) -lt $deadline -and !(Test-Path -LiteralPath $responsePath)) {
    Start-Sleep -Milliseconds 250
  }
  if (!(Test-Path -LiteralPath $responsePath)) {
    throw "Timed out waiting for BMF response file: $responsePath"
  }

  $lines = [System.IO.File]::ReadAllLines($responsePath)
  return [ordered]@{
    command = $Command
    requestId = $requestId
    responsePath = [System.IO.Path]::GetFullPath($responsePath)
    lines = @($lines)
    values = Convert-KeyValueLines $lines
  }
}

function Resolve-InteractComponent {
  if ($Component) {
    return $Component
  }

  $response = Invoke-BmfCommand 'bmf.tools.applicator.native-targets'
  foreach ($key in @('interact_component', 'interactComponentAddress')) {
    if ($response.values.ContainsKey($key) -and [string]$response.values[$key]) {
      return [string]$response.values[$key]
    }
  }

  throw "BMF native target response did not include interact_component. Restart with the current BMF core or pass -Component explicitly."
}

function Write-InteractControl(
  [string]$Path,
  [UInt64]$FunctionValue,
  [UInt64]$ComponentValue,
  [string]$EventOutputPath
) {
  $lines = @(
    "function=$(Format-Hex64 $FunctionValue)",
    "component=$(Format-Hex64 $ComponentValue)",
    'func_offset=0xD8',
    'locals_offset=0x28',
    'scan_bytes=0x400',
    'enable=1',
    'block=1',
    'trace=1',
    'deny_unknown=1',
    'allow_empty=1'
  )
  if ($EventOutputPath) {
    $lines += "event_path=$EventOutputPath"
  }

  $prefixes = Expand-ListValues $AllowedPrefix
  foreach ($prefix in $prefixes) {
    $lines += "allowed_prefix=$prefix"
  }

  $contexts = Expand-ListValues $AllowedContext
  foreach ($context in $contexts) {
    $lines += "allowed_context=$context"
  }

  $directory = Split-Path -Parent $Path
  if ($directory) {
    New-Item -ItemType Directory -Force -Path $directory | Out-Null
  }
  [System.IO.File]::WriteAllText($Path, (($lines -join "`n") + "`n"))
}

function Test-ExistingInstalledHook([hashtable]$Status, [UInt64]$FunctionValue, [int]$TargetProcessId) {
  if (!$Status.ContainsKey('installed') -or [string]$Status['installed'] -ne '1') {
    return $false
  }
  if ($Status.ContainsKey('pid') -and [string]$Status['pid'] -and [int]$Status['pid'] -ne $TargetProcessId) {
    return $false
  }
  if (!$Status.ContainsKey('function')) {
    return $false
  }
  try {
    $statusFunction = Convert-HexToUInt64 ([string]$Status['function']) 'status.function'
    return $statusFunction -eq $FunctionValue
  } catch {
    return $false
  }
}

function Wait-ForInstalledStatus([string]$Path, [UInt64]$FunctionValue, [UInt64]$ComponentValue, [int]$TargetProcessId, [int]$TimeoutSeconds) {
  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  while ((Get-Date) -lt $deadline) {
    $status = Read-KeyValueFile $Path
    if ($status.ContainsKey('installed') -and [string]$status['installed'] -eq '1' -and
        $status.ContainsKey('function') -and $status.ContainsKey('component')) {
      $statusFunction = Convert-HexToUInt64 ([string]$status['function']) 'status.function'
      $statusComponent = Convert-HexToUInt64 ([string]$status['component']) 'status.component'
      $pidOk = $true
      if ($status.ContainsKey('pid') -and [string]$status['pid']) {
        $pidOk = [int]$status['pid'] -eq $TargetProcessId
      }
      if ($statusFunction -eq $FunctionValue -and $statusComponent -eq $ComponentValue -and $pidOk) {
        return $status
      }
    }
    Start-Sleep -Milliseconds 250
  }
  throw "Timed out waiting for Interactable prefix guard install status to match function=$(Format-Hex64 $FunctionValue) component=$(Format-Hex64 $ComponentValue)"
}

if (!$Root) {
  $Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
}
if (!$BrickadiaRoot) {
  $BrickadiaRoot = (Resolve-Path (Join-Path (Split-Path -Parent $Root) 'Brickadia')).Path
}
if (!$RuntimeBmfDir) {
  $RuntimeBmfDir = Join-Path $env:APPDATA 'omegga/steam_installs/main/Brickadia/Binaries/Win64/ue4ss/main/Mods/BMF'
}
if (!$ControlPath) {
  $ControlPath = Join-Path $Root 'artifacts/local/interact-prefix-guard-control.txt'
}
if (!$StatusPath) {
  $StatusPath = Join-Path $Root 'artifacts/local/interact-prefix-guard-status.txt'
}
if (!$EventPath) {
  $EventPath = Join-Path $Root 'artifacts/local/interact-prefix-guard-events.tsv'
}
if (!$BuildScript) {
  $BuildScript = Join-Path $Root 'scripts/build-applicator-blocker-native-hook.ps1'
}
if (!$InjectScript) {
  $InjectScript = Join-Path $Root 'scripts/inject-applicator-blocker-native-hook.ps1'
}
if (!$SourcePath) {
  $SourcePath = Join-Path $Root 'native/interact_prefix_guard/interact_prefix_guard.cpp'
}
if (!$BridgeDir) {
  $BridgeDir = Find-LatestBridgeDir $BrickadiaRoot
}
if (!$OutJson) {
  $OutJson = Join-Path $Root 'artifacts/local/interact-prefix-guard-sync.json'
}

$script:BridgeDir = [System.IO.Path]::GetFullPath($BridgeDir)
$script:RuntimeBmfDir = [System.IO.Path]::GetFullPath($RuntimeBmfDir)
$script:SendRpcScript = Join-Path $BrickadiaRoot 'brickadia-ue4ss-re/scripts/send-bridge-rpc.js'

if ($ProcessId -eq 0) {
  $serverProcess = Get-Process BrickadiaServer-Win64-Shipping -ErrorAction Stop |
    Sort-Object StartTime -Descending |
    Select-Object -First 1
  $ProcessId = $serverProcess.Id
} else {
  $serverProcess = Get-Process -Id $ProcessId -ErrorAction Stop
}

$componentText = Resolve-InteractComponent
$componentValue = Convert-HexToUInt64 $componentText 'component'

$caseRoot = Split-Path -Parent ([System.IO.Path]::GetFullPath($OutJson))
New-Item -ItemType Directory -Force -Path $caseRoot | Out-Null
$scanJson = Join-Path $caseRoot 'interact-prefix-modify-scan.json'
$scanControl = Join-Path $caseRoot 'interact-prefix-modify-scan-control.txt'
$scanStatus = Join-Path $caseRoot 'interact-prefix-modify-scan-status.txt'
$scanResult = $null
$functionValue = [UInt64]0
$existingStatus = Read-KeyValueFile $StatusPath
$existingStatusPidOk = $false
if ($existingStatus.ContainsKey('pid') -and [string]$existingStatus['pid']) {
  $existingStatusPidOk = [int]$existingStatus['pid'] -eq $ProcessId
}
if ($existingStatus.ContainsKey('installed') -and [string]$existingStatus['installed'] -eq '1' -and
    $existingStatus.ContainsKey('function') -and ($existingStatusPidOk -or $TrustExistingStatus)) {
  $functionValue = Convert-HexToUInt64 ([string]$existingStatus['function']) 'status.function'
}

if ($functionValue -eq 0) {
  $scanScript = Join-Path $Root 'scripts/sync-applicator-blocker-native-hook.ps1'
  if (!(Test-Path -LiteralPath $scanScript)) {
    throw "Applicator native scanner script does not exist: $scanScript"
  }

  & $scanScript `
    -ProcessId $ProcessId `
    -Root $Root `
    -BrickadiaRoot $BrickadiaRoot `
    -BridgeDir $script:BridgeDir `
    -RuntimeBmfDir $script:RuntimeBmfDir `
    -ControlPath $scanControl `
    -StatusPath $scanStatus `
    -DeniedComponent (Format-Hex64 $componentValue) `
    -ServerAddComponentRvas $ServerModifyComponentRvas `
    -SkipInject `
    -OutJson $scanJson | Out-Null

  if (!(Test-Path -LiteralPath $scanJson)) {
    throw "Native scan did not write output JSON: $scanJson"
  }
  $scanResult = Get-Content -Raw -LiteralPath $scanJson | ConvertFrom-Json
  $functionValue = Convert-HexToUInt64 ([string]$scanResult.function) 'scan.function'
}

Write-InteractControl `
  -Path $ControlPath `
  -FunctionValue $functionValue `
  -ComponentValue $componentValue `
  -EventOutputPath ([System.IO.Path]::GetFullPath($EventPath))

$statusBefore = Read-KeyValueFile $StatusPath
$alreadyInstalled = Test-ExistingInstalledHook $statusBefore $functionValue $ProcessId
$injected = $false
$dllPath = ''
$verifiedStatus = @{}

if ($SkipInject) {
  $verifiedStatus = Read-KeyValueFile $StatusPath
} elseif ($alreadyInstalled -and !$ForceReinject) {
  Start-Sleep -Seconds 2
  $verifiedStatus = Read-KeyValueFile $StatusPath
} else {
  if (!(Test-Path -LiteralPath $BuildScript)) {
    throw "Build script does not exist: $BuildScript"
  }
  if (!(Test-Path -LiteralPath $InjectScript)) {
    throw "Inject script does not exist: $InjectScript"
  }
  if (!(Test-Path -LiteralPath $SourcePath)) {
    throw "Native source does not exist: $SourcePath"
  }
  if (!$DllName) {
    $DllName = 'bmf_interact_prefix_guard_pid{0}_{1}.dll' -f $ProcessId, (Get-Date -Format 'yyyyMMddHHmmss')
  }

  $buildOutput = & $BuildScript -SourcePath $SourcePath -DllName $DllName
  $builtItem = $buildOutput | Where-Object { $_ -is [System.IO.FileInfo] } | Select-Object -Last 1
  if ($builtItem) {
    $dllPath = $builtItem.FullName
  } else {
    $dllPath = Join-Path $Root "artifacts/local/$DllName"
  }
  if (!(Test-Path -LiteralPath $dllPath)) {
    throw "Interact prefix guard DLL was not built: $dllPath"
  }

  & $InjectScript -ProcessId $ProcessId -DllPath $dllPath | Out-Null
  $injected = $true
  $verifiedStatus = Wait-ForInstalledStatus $StatusPath $functionValue $componentValue $ProcessId $VerificationTimeoutSeconds
}

$result = [ordered]@{
  feature = 'interact-prefix.native-func-guard.sync'
  status = 'ready'
  processId = $ProcessId
  processName = $serverProcess.ProcessName
  function = Format-Hex64 $functionValue
  component = Format-Hex64 $componentValue
  serverModifyComponentRvas = @($ServerModifyComponentRvas | ForEach-Object { Format-Hex64 $_ })
  allowedPrefixes = @(Expand-ListValues $AllowedPrefix)
  allowedContexts = @(Expand-ListValues $AllowedContext)
  alreadyInstalled = [bool]$alreadyInstalled
  injected = [bool]$injected
  skippedInject = [bool]$SkipInject
  forceReinject = [bool]$ForceReinject
  trustedExistingStatus = [bool]$TrustExistingStatus
  controlPath = [System.IO.Path]::GetFullPath($ControlPath)
  statusPath = [System.IO.Path]::GetFullPath($StatusPath)
  eventPath = [System.IO.Path]::GetFullPath($EventPath)
  bridgeDir = $script:BridgeDir
  runtimeBmfDir = $script:RuntimeBmfDir
  dllPath = $dllPath
  scanJson = if (Test-Path -LiteralPath $scanJson) { [System.IO.Path]::GetFullPath($scanJson) } else { '' }
  verifiedStatus = $verifiedStatus
}

$json = $result | ConvertTo-Json -Depth 8
$json | Set-Content -LiteralPath $OutJson -Encoding UTF8
$json
