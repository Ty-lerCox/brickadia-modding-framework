param(
  [int]$ProcessId = 0,
  [string]$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
  [string]$BrickadiaRoot = '',
  [string]$BridgeDir = '',
  [string]$RuntimeBmfDir = '',
  [string[]]$DeniedAsset = @('Entity_Wheel_Steelie1'),
  [string[]]$AllowedContext = @(),
  [string]$ControlPath = '',
  [string]$StatusPath = '',
  [string]$EventPath = '',
  [string]$BuildScript = '',
  [string]$InjectScript = '',
  [string]$SourcePath = '',
  [string]$DllName = '',
  [switch]$TrustExistingStatus,
  [switch]$SkipInject,
  [switch]$ForceReinject,
  [int]$CommandTimeoutSeconds = 30,
  [int]$ResponseTimeoutSeconds = 20,
  [int]$VerificationTimeoutSeconds = 20,
  [string[]]$DeniedPrefabHash = @(),
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
  if ($text.Contains('|')) {
    $text = ($text -split '\|', 2)[0].Trim()
  }
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
  $roots = @(
    (Join-Path $BrickadiaRootPath 'omegga-master/omegga-master/data/ue4ss-bridge'),
    (Join-Path $BrickadiaRootPath 'omegga-master/omegga-master/data')
  )
  foreach ($bridgeRoot in $roots) {
    if (!(Test-Path -LiteralPath $bridgeRoot)) {
      continue
    }
    $dir = Get-ChildItem -LiteralPath $bridgeRoot -Directory |
      Where-Object { $_.Name -like 'ue4ss-bridge*' } |
      Sort-Object LastWriteTime -Descending |
      Select-Object -First 1
    if ($dir) {
      return $dir.FullName
    }
  }
  throw "No Omegga bridge session directories found under Brickadia root: $BrickadiaRootPath"
}

function Invoke-BridgeConsole([string]$Command) {
  if (!$script:SendRpcScript -or !(Test-Path -LiteralPath $script:SendRpcScript)) {
    throw "send-bridge-rpc.js was not found: $script:SendRpcScript"
  }
  if (!$script:BridgeDir -or !(Test-Path -LiteralPath $script:BridgeDir)) {
    throw "BridgeDir does not exist: $script:BridgeDir"
  }

  $waitMs = [Math]::Max(1000, $CommandTimeoutSeconds * 1000)
  $output = & node $script:SendRpcScript --dir $script:BridgeDir --method console.exec --command-raw $Command --wait-ms $waitMs --include-logs 0
  $rpc = ($output -join "`n") | ConvertFrom-Json
  if ($rpc.result.accepted -ne $true -or $rpc.complete.success -ne $true) {
    throw "Bridge command was not accepted/completed: $Command"
  }
  return @($rpc.chunks | ForEach-Object { [string]$_.line })
}

function Resolve-PlacementFunction {
  $lines = Invoke-BridgeConsole 'Omegga.Bridge.DescribeUFunctionSignature ServerPlaceSimpleEntityVolume 3 6'
  foreach ($line in $lines) {
    if ($line -match 'hit\[\d+\]\s+addr=0x([0-9A-Fa-f]+)\s+') {
      return [ordered]@{
        address = [Convert]::ToUInt64($Matches[1], 16)
        lines = $lines
        source = 'DescribeUFunctionSignature'
      }
    }
  }

  $fallback = Invoke-BridgeConsole 'Omegga.Bridge.DescribeFunctionObject ServerPlaceSimpleEntityVolume 3 12'
  foreach ($line in $fallback) {
    if ($line -match 'addr=0x([0-9A-Fa-f]+)') {
      return [ordered]@{
        address = [Convert]::ToUInt64($Matches[1], 16)
        lines = $fallback
        source = 'DescribeFunctionObject'
      }
    }
  }

  throw "Could not resolve ServerPlaceSimpleEntityVolume UFunction address.`n$($lines -join "`n")`n$($fallback -join "`n")"
}

function Resolve-PrefabFunction {
  $lines = Invoke-BridgeConsole 'Omegga.Bridge.DescribeUFunctionSignature ServerPastePrefab 3 6'
  foreach ($line in $lines) {
    if ($line -match 'hit\[\d+\]\s+addr=0x([0-9A-Fa-f]+)\s+') {
      return [ordered]@{
        address = [Convert]::ToUInt64($Matches[1], 16)
        lines = $lines
        source = 'DescribeUFunctionSignature'
      }
    }
  }

  $fallback = Invoke-BridgeConsole 'Omegga.Bridge.DescribeFunctionObject ServerPastePrefab 3 12'
  foreach ($line in $fallback) {
    if ($line -match 'addr=0x([0-9A-Fa-f]+)') {
      return [ordered]@{
        address = [Convert]::ToUInt64($Matches[1], 16)
        lines = $fallback
        source = 'DescribeFunctionObject'
      }
    }
  }

  throw "Could not resolve ServerPastePrefab UFunction address.`n$($lines -join "`n")`n$($fallback -join "`n")"
}

function Resolve-DeniedAsset([string]$Name) {
  $text = $Name.Trim()
  if (!$text) {
    throw "Denied asset name cannot be empty."
  }
  if ($text -match '^0x[0-9A-Fa-f]+$') {
    return [ordered]@{
      name = $text
      address = Convert-HexToUInt64 $text 'denied asset'
      source = 'explicit-address'
      lines = @()
    }
  }

  $lines = Invoke-BridgeConsole "Omegga.Bridge.DescribeObjectNameLite $text"
  foreach ($line in $lines) {
    if ($line -match 'hit\[\d+\]\s+addr=0x([0-9A-Fa-f]+)\s+') {
      return [ordered]@{
        name = $text
        address = [Convert]::ToUInt64($Matches[1], 16)
        source = 'DescribeObjectNameLite'
        lines = $lines
      }
    }
  }

  throw "Could not resolve denied placement asset '$text'.`n$($lines -join "`n")"
}

function Write-PlacementControl(
  [string]$Path,
  [UInt64]$FunctionValue,
  [UInt64]$PrefabFunctionValue,
  [UInt64]$PlacePrefabMethodBlock,
  [UInt64]$PlaceBrickMethodBlock,
  [UInt64]$PlaceBrickResolveRef,
  [UInt64]$PlaceBrickPrimaryClass,
  [UInt64]$PlaceBrickVariantClass,
  [UInt64]$PlaceBrickAssetClass,
  [UInt64]$PlaceBrickResolvePrimary,
  [UInt64]$PlaceBrickResolveVariant,
  [object[]]$DeniedAssets,
  [string[]]$AllowedContexts,
  [string[]]$DeniedPrefabHashes
) {
  $lines = @(
    "function=$(Format-Hex64 $FunctionValue)",
    "prefab_function=$(Format-Hex64 $PrefabFunctionValue)",
    "place_prefab_method_block=$(Format-Hex64 $PlacePrefabMethodBlock)",
    "place_brick_method_block=$(Format-Hex64 $PlaceBrickMethodBlock)",
    "place_brick_resolve_ref=$(Format-Hex64 $PlaceBrickResolveRef)",
    "place_brick_primary_class=$(Format-Hex64 $PlaceBrickPrimaryClass)",
    "place_brick_variant_class=$(Format-Hex64 $PlaceBrickVariantClass)",
    "place_brick_asset_class=$(Format-Hex64 $PlaceBrickAssetClass)",
    "place_brick_resolve_primary=$(Format-Hex64 $PlaceBrickResolvePrimary)",
    "place_brick_resolve_variant=$(Format-Hex64 $PlaceBrickResolveVariant)",
    'func_offset=0xD8',
    'prefab_func_offset=0xD8',
    'locals_offset=0x28',
    'asset_offset=0x80',
    'prefab_hash_offset=0x0',
    'place_prefab_apply_slot_offset=0x18',
    'place_prefab_payload_offset=0x18',
    'place_prefab_payload_hash_offset=0x28',
    'place_brick_apply_slot_offset=0x18',
    'place_brick_ref_offset=0x1C',
    'place_brick_variant_offset=0x24',
    'place_brick_asset_record_offset=0x20',
    'enable=1',
    'block=1',
    'trace=1'
  )
  if ($EventPath) {
    $lines += "event_path=$([System.IO.Path]::GetFullPath($EventPath))"
  }
  foreach ($asset in @($DeniedAssets)) {
    $lines += "denied_asset=$(Format-Hex64 ([UInt64]$asset.address))|$($asset.name)"
  }
  foreach ($context in @(Expand-ListValues $AllowedContexts)) {
    $lines += "allowed_context=$context"
  }
  foreach ($prefabHash in @(Expand-ListValues $DeniedPrefabHashes)) {
    $lines += "denied_prefab_hash=$prefabHash"
  }

  $directory = Split-Path -Parent $Path
  if ($directory) {
    New-Item -ItemType Directory -Force -Path $directory | Out-Null
  }
  [System.IO.File]::WriteAllText($Path, (($lines -join "`n") + "`n"))
}

function Test-ExistingInstalledHook([hashtable]$Status, [UInt64]$FunctionValue, [UInt64]$PrefabFunctionValue, [int]$TargetProcessId) {
  if (!$Status.ContainsKey('installed') -or [string]$Status['installed'] -ne '1') {
    return $false
  }
  if (!$Status.ContainsKey('prefab_installed') -or [string]$Status['prefab_installed'] -ne '1') {
    return $false
  }
  if (!$Status.ContainsKey('action_prefab_installed') -or [string]$Status['action_prefab_installed'] -ne '1') {
    return $false
  }
  if (!$Status.ContainsKey('action_brick_installed') -or [string]$Status['action_brick_installed'] -ne '1') {
    return $false
  }
  if ($Status.ContainsKey('pid') -and [string]$Status['pid'] -and [int]$Status['pid'] -ne $TargetProcessId) {
    return $false
  }
  if (!$Status.ContainsKey('function')) {
    return $false
  }
  if (!$Status.ContainsKey('prefab_function')) {
    return $false
  }
  try {
    $statusFunction = Convert-HexToUInt64 ([string]$Status['function']) 'status.function'
    $statusPrefabFunction = Convert-HexToUInt64 ([string]$Status['prefab_function']) 'status.prefab_function'
    return $statusFunction -eq $FunctionValue -and $statusPrefabFunction -eq $PrefabFunctionValue
  } catch {
    return $false
  }
}

function Wait-ForInstalledStatus([string]$Path, [UInt64]$FunctionValue, [UInt64]$PrefabFunctionValue, [int]$TargetProcessId, [int]$TimeoutSeconds) {
  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  while ((Get-Date) -lt $deadline) {
    $status = Read-KeyValueFile $Path
    if ($status.ContainsKey('installed') -and [string]$status['installed'] -eq '1' -and
        $status.ContainsKey('prefab_installed') -and [string]$status['prefab_installed'] -eq '1' -and
        $status.ContainsKey('action_prefab_installed') -and [string]$status['action_prefab_installed'] -eq '1' -and
        $status.ContainsKey('action_brick_installed') -and [string]$status['action_brick_installed'] -eq '1' -and
        $status.ContainsKey('function') -and $status.ContainsKey('prefab_function') -and $status.ContainsKey('denied_asset_count')) {
      $statusFunction = Convert-HexToUInt64 ([string]$status['function']) 'status.function'
      $statusPrefabFunction = Convert-HexToUInt64 ([string]$status['prefab_function']) 'status.prefab_function'
      $pidOk = $true
      if ($status.ContainsKey('pid') -and [string]$status['pid']) {
        $pidOk = [int]$status['pid'] -eq $TargetProcessId
      }
      if ($statusFunction -eq $FunctionValue -and $statusPrefabFunction -eq $PrefabFunctionValue -and $pidOk -and [int]$status['denied_asset_count'] -gt 0) {
        return $status
      }
    }
    Start-Sleep -Milliseconds 250
  }
  throw "Timed out waiting for placement guard install status to match function=$(Format-Hex64 $FunctionValue) prefab_function=$(Format-Hex64 $PrefabFunctionValue)"
}

if (!$Root) {
  $Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
}
$Root = [System.IO.Path]::GetFullPath($Root)
if (!$BrickadiaRoot) {
  $BrickadiaRoot = (Resolve-Path (Join-Path (Split-Path -Parent $Root) 'Brickadia')).Path
}
$BrickadiaRoot = [System.IO.Path]::GetFullPath($BrickadiaRoot)
if (!$RuntimeBmfDir) {
  $RuntimeBmfDir = Join-Path $env:APPDATA 'omegga/steam_installs/main/Brickadia/Binaries/Win64/ue4ss/main/Mods/BMF'
}
if (!$ControlPath) {
  $ControlPath = Join-Path $Root 'artifacts/local/placement-asset-guard-control.txt'
}
if (!$StatusPath) {
  $StatusPath = Join-Path $Root 'artifacts/local/placement-asset-guard-status.txt'
}
if (!$EventPath) {
  $EventPath = Join-Path $Root 'artifacts/local/placement-asset-guard-events.tsv'
}
if (!$BuildScript) {
  $BuildScript = Join-Path $Root 'scripts/build-applicator-blocker-native-hook.ps1'
}
if (!$InjectScript) {
  $InjectScript = Join-Path $Root 'scripts/inject-applicator-blocker-native-hook.ps1'
}
if (!$SourcePath) {
  $SourcePath = Join-Path $Root 'native/placement_guard/placement_guard.cpp'
}
if (!$BridgeDir) {
  $BridgeDir = Find-LatestBridgeDir $BrickadiaRoot
}
if (!$OutJson) {
  $OutJson = Join-Path $Root 'artifacts/local/placement-asset-guard-sync.json'
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

$moduleBase = [UInt64]$serverProcess.MainModule.BaseAddress.ToInt64()
$placePrefabMethodBlock = $moduleBase + [UInt64]0x6C79D50
$placeBrickMethodBlock = $moduleBase + [UInt64]0x6C77CE0
$placeBrickResolveRef = $moduleBase + [UInt64]0x53ABF0
$placeBrickPrimaryClass = $moduleBase + [UInt64]0x419DF90
$placeBrickVariantClass = $moduleBase + [UInt64]0x419ED20
$placeBrickAssetClass = $moduleBase + [UInt64]0x419D800
$placeBrickResolvePrimary = $moduleBase + [UInt64]0x86270
$placeBrickResolveVariant = $moduleBase + [UInt64]0x430FB00

$functionTarget = Resolve-PlacementFunction
$functionValue = [UInt64]$functionTarget.address
$prefabFunctionTarget = Resolve-PrefabFunction
$prefabFunctionValue = [UInt64]$prefabFunctionTarget.address
$resolvedAssets = New-Object System.Collections.Generic.List[object]
foreach ($name in @(Expand-ListValues $DeniedAsset)) {
  $resolvedAssets.Add((Resolve-DeniedAsset $name))
}
if ($resolvedAssets.Count -eq 0) {
  throw "At least one denied placement asset is required."
}

Write-PlacementControl `
  -Path $ControlPath `
  -FunctionValue $functionValue `
  -PrefabFunctionValue $prefabFunctionValue `
  -PlacePrefabMethodBlock $placePrefabMethodBlock `
  -PlaceBrickMethodBlock $placeBrickMethodBlock `
  -PlaceBrickResolveRef $placeBrickResolveRef `
  -PlaceBrickPrimaryClass $placeBrickPrimaryClass `
  -PlaceBrickVariantClass $placeBrickVariantClass `
  -PlaceBrickAssetClass $placeBrickAssetClass `
  -PlaceBrickResolvePrimary $placeBrickResolvePrimary `
  -PlaceBrickResolveVariant $placeBrickResolveVariant `
  -DeniedAssets @($resolvedAssets.ToArray()) `
  -AllowedContexts (Expand-ListValues $AllowedContext) `
  -DeniedPrefabHashes (Expand-ListValues $DeniedPrefabHash)

$statusBefore = Read-KeyValueFile $StatusPath
$alreadyInstalled = Test-ExistingInstalledHook $statusBefore $functionValue $prefabFunctionValue $ProcessId
$injected = $false
$dllPath = ''
$verifiedStatus = @{}

if ($SkipInject) {
  $verifiedStatus = Read-KeyValueFile $StatusPath
} elseif ($alreadyInstalled -and !$ForceReinject) {
  Start-Sleep -Seconds 2
  $verifiedStatus = Wait-ForInstalledStatus $StatusPath $functionValue $prefabFunctionValue $ProcessId $VerificationTimeoutSeconds
} else {
  foreach ($path in @($BuildScript, $InjectScript, $SourcePath)) {
    if (!(Test-Path -LiteralPath $path)) {
      throw "Required path does not exist: $path"
    }
  }
  if (!$DllName) {
    $DllName = 'bmf_placement_asset_guard_pid{0}_{1}.dll' -f $ProcessId, (Get-Date -Format 'yyyyMMddHHmmss')
  }

  $buildOutput = & $BuildScript -SourcePath $SourcePath -DllName $DllName
  $builtItem = $buildOutput | Where-Object { $_ -is [System.IO.FileInfo] } | Select-Object -Last 1
  if ($builtItem) {
    $dllPath = $builtItem.FullName
  } else {
    $dllPath = Join-Path $Root "artifacts/local/$DllName"
  }
  if (!(Test-Path -LiteralPath $dllPath)) {
    throw "Placement guard DLL was not built: $dllPath"
  }

  & $InjectScript -ProcessId $ProcessId -DllPath $dllPath | Out-Null
  $injected = $true
  $verifiedStatus = Wait-ForInstalledStatus $StatusPath $functionValue $prefabFunctionValue $ProcessId $VerificationTimeoutSeconds
}

$result = [ordered]@{
  feature = 'placement-asset.native-func-guard.sync'
  status = 'ready'
  processId = $ProcessId
  processName = $serverProcess.ProcessName
  function = Format-Hex64 $functionValue
  functionSource = $functionTarget.source
  prefabFunction = Format-Hex64 $prefabFunctionValue
  prefabFunctionSource = $prefabFunctionTarget.source
  placePrefabMethodBlock = Format-Hex64 $placePrefabMethodBlock
  placePrefabMethodBlockRva = '0x6C79D50'
  placeBrickMethodBlock = Format-Hex64 $placeBrickMethodBlock
  placeBrickMethodBlockRva = '0x6C77CE0'
  placeBrickResolveRef = Format-Hex64 $placeBrickResolveRef
  placeBrickResolveRefRva = '0x53ABF0'
  placeBrickPrimaryClass = Format-Hex64 $placeBrickPrimaryClass
  placeBrickPrimaryClassRva = '0x419DF90'
  placeBrickVariantClass = Format-Hex64 $placeBrickVariantClass
  placeBrickVariantClassRva = '0x419ED20'
  placeBrickAssetClass = Format-Hex64 $placeBrickAssetClass
  placeBrickAssetClassRva = '0x419D800'
  placeBrickResolvePrimary = Format-Hex64 $placeBrickResolvePrimary
  placeBrickResolvePrimaryRva = '0x86270'
  placeBrickResolveVariant = Format-Hex64 $placeBrickResolveVariant
  placeBrickResolveVariantRva = '0x430FB00'
  deniedAssets = @($resolvedAssets | ForEach-Object {
    [ordered]@{
      name = $_.name
      address = Format-Hex64 ([UInt64]$_.address)
      source = $_.source
    }
  })
  allowedContexts = @(Expand-ListValues $AllowedContext)
  deniedPrefabHashes = @(Expand-ListValues $DeniedPrefabHash)
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
  verifiedStatus = $verifiedStatus
}

$json = $result | ConvertTo-Json -Depth 8
New-Item -ItemType Directory -Force -Path (Split-Path -Parent ([System.IO.Path]::GetFullPath($OutJson))) | Out-Null
$json | Set-Content -LiteralPath $OutJson -Encoding UTF8
$json
