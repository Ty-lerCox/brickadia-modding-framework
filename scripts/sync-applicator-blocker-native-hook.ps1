param(
  [int]$ProcessId = 0,
  [string]$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
  [string]$BrickadiaRoot = '',
  [string]$BridgeDir = '',
  [string]$RuntimeBmfDir = '',
  [string]$ControlPath = '',
  [string]$StatusPath = '',
  [string]$BuildScript = '',
  [string]$InjectScript = '',
  [string]$DllName = '',
  [string]$DeniedComponent = '',
  [UInt64[]]$ServerAddComponentRvas = @([UInt64]0x62A5450),
  [int]$CommandTimeoutSeconds = 30,
  [int]$ResponseTimeoutSeconds = 20,
  [int]$VerificationTimeoutSeconds = 20,
  [switch]$SkipInject,
  [switch]$ForceReinject,
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
  if ($script:SocketCommandScript -and (Test-Path -LiteralPath $script:SocketCommandScript)) {
    $runtimeDir = Join-Path $script:RuntimeBmfDir 'runtime'
    $timeoutMs = [Math]::Max(1000, $CommandTimeoutSeconds * 1000)
    $output = & node $script:SocketCommandScript --runtime-dir $runtimeDir --command $Command --timeout-ms $timeoutMs
    if ($LASTEXITCODE -ne 0) {
      throw "BMF socket command failed: $Command"
    }
    $socket = ($output -join "`n") | ConvertFrom-Json
    $lines = @([string]$socket.response -split "`r?`n")
    return [ordered]@{
      command = $Command
      requestId = [string]$socket.id
      responsePath = ''
      lines = $lines
      values = Convert-KeyValueLines $lines
    }
  }

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
  $jsonText = ($output -join "`n")
  $rpc = $jsonText | ConvertFrom-Json
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

function Ensure-NativeScannerType {
  if ('BmfNativeTargetScanner' -as [type]) {
    return
  }

  $source = @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

public static class BmfNativeTargetScanner {
  [DllImport("kernel32.dll", SetLastError=true)] static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool CloseHandle(IntPtr h);
  [DllImport("kernel32.dll", SetLastError=true)] static extern IntPtr VirtualQueryEx(IntPtr hProcess, IntPtr lpAddress, out MEMORY_BASIC_INFORMATION64 lpBuffer, uint dwLength);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool ReadProcessMemory(IntPtr hProcess, IntPtr lpBaseAddress, byte[] lpBuffer, UIntPtr nSize, out UIntPtr lpNumberOfBytesRead);

  [StructLayout(LayoutKind.Sequential)] struct MEMORY_BASIC_INFORMATION64 {
    public ulong BaseAddress;
    public ulong AllocationBase;
    public uint AllocationProtect;
    public uint __alignment1;
    public ulong RegionSize;
    public uint State;
    public uint Protect;
    public uint Type;
    public uint __alignment2;
  }

  const uint PROCESS_QUERY_INFORMATION = 0x0400;
  const uint PROCESS_VM_READ = 0x0010;
  const uint MEM_COMMIT = 0x1000;
  const uint PAGE_NOACCESS = 0x01;
  const uint PAGE_GUARD = 0x100;
  const uint PAGE_EXECUTE = 0x10;
  const uint PAGE_EXECUTE_READ = 0x20;
  const uint PAGE_EXECUTE_READWRITE = 0x40;
  const uint PAGE_EXECUTE_WRITECOPY = 0x80;

  static bool IsReadableData(uint protect) {
    if ((protect & PAGE_GUARD) != 0 || (protect & PAGE_NOACCESS) != 0) return false;
    uint p = protect & 0xff;
    if (p == PAGE_EXECUTE || p == PAGE_EXECUTE_READ || p == PAGE_EXECUTE_READWRITE || p == PAGE_EXECUTE_WRITECOPY) return false;
    return true;
  }

  static ulong U64(byte[] b, int i) { return BitConverter.ToUInt64(b, i); }
  static uint U32(byte[] b, int i) { return BitConverter.ToUInt32(b, i); }
  static ushort U16(byte[] b, int i) { return BitConverter.ToUInt16(b, i); }

  static bool ContainsTarget(ulong[] targets, ulong value) {
    if (targets == null) return false;
    for (int i = 0; i < targets.Length; ++i) {
      if (targets[i] == value) return true;
    }
    return false;
  }

  static IntPtr Ptr(ulong value) {
    return new IntPtr(unchecked((long)value));
  }

  public static string Inspect(int pid, ulong function, uint funcOffset, uint flagsOffset) {
    StringBuilder sb = new StringBuilder();
    IntPtr h = OpenProcess(PROCESS_QUERY_INFORMATION | PROCESS_VM_READ, false, pid);
    if (h == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error(), "OpenProcess failed");
    try {
      int readSize = 0x200;
      byte[] buf = new byte[readSize];
      UIntPtr got;
      if (!ReadProcessMemory(h, Ptr(function), buf, (UIntPtr)(uint)readSize, out got) || got.ToUInt64() < 0xE0) {
        sb.AppendLine("valid=0");
        sb.AppendLine("reason=read-failed");
        return sb.ToString();
      }
      ulong slot = U64(buf, (int)funcOffset);
      uint flags = U32(buf, (int)flagsOffset);
      byte numParms = buf[0xB4];
      ushort parmsSize = U16(buf, 0xB6);
      bool valid = flags != 0 && (flags & 0x440) == 0x440 && numParms >= 1 && numParms <= 8 && parmsSize >= 0x10 && parmsSize <= 0x200 && slot != 0;
      sb.AppendLine(valid ? "valid=1" : "valid=0");
      sb.AppendLine(string.Format("function=0x{0:X}", function));
      sb.AppendLine(string.Format("slot=0x{0:X}", slot));
      sb.AppendLine(string.Format("flags=0x{0:X}", flags));
      sb.AppendLine(string.Format("numParms={0}", numParms));
      sb.AppendLine(string.Format("parmsSize=0x{0:X}", parmsSize));
      return sb.ToString();
    } finally {
      CloseHandle(h);
    }
  }

  public static string Scan(int pid, ulong[] targets, uint funcOffset, uint flagsOffset, uint minParams, uint maxParams, uint minParamsSize, uint maxParamsSize, int maxHits) {
    IntPtr h = OpenProcess(PROCESS_QUERY_INFORMATION | PROCESS_VM_READ, false, pid);
    if (h == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error(), "OpenProcess failed");
    try {
      ulong addr = 0x10000;
      uint mbiSize = (uint)Marshal.SizeOf(typeof(MEMORY_BASIC_INFORMATION64));
      List<string> hits = new List<string>();
      ulong regions = 0, scanned = 0;
      while (addr < 0x0000800000000000UL) {
        MEMORY_BASIC_INFORMATION64 mbi;
        if (VirtualQueryEx(h, Ptr(addr), out mbi, mbiSize) == IntPtr.Zero) {
          addr += 0x10000;
          continue;
        }

        ulong start = mbi.BaseAddress;
        ulong size = mbi.RegionSize;
        ulong end = start + size;
        if (end <= addr) {
          addr += 0x10000;
          continue;
        }

        if (mbi.State == MEM_COMMIT && IsReadableData(mbi.Protect) && size >= 0xE0) {
          regions++;
          const int chunkSize = 4 * 1024 * 1024;
          ulong pos = start;
          while (pos < end) {
            ulong remaining = end - pos;
            int readSize = (int)Math.Min((ulong)chunkSize, remaining);
            byte[] buf = new byte[readSize];
            UIntPtr got;
            if (ReadProcessMemory(h, Ptr(pos), buf, (UIntPtr)(uint)readSize, out got) && got.ToUInt64() >= 0xE0) {
              int n = (int)got.ToUInt64();
              scanned += (ulong)n;
              for (int i = 0; i + 0xE0 <= n; i += 0x10) {
                ulong func = U64(buf, i + (int)funcOffset);
                if (!ContainsTarget(targets, func)) continue;
                uint flags = U32(buf, i + (int)flagsOffset);
                byte numParms = buf[i + 0xB4];
                ushort parmsSize = U16(buf, i + 0xB6);
                if (flags == 0 || (flags & 0x440) != 0x440) continue;
                if (numParms < minParams || numParms > maxParams) continue;
                if (parmsSize < minParamsSize || parmsSize > maxParamsSize) continue;
                hits.Add(string.Format("candidate=0x{0:X} func=0x{1:X} flags=0x{2:X} numParms={3} parmsSize=0x{4:X}", pos + (ulong)i, func, flags, numParms, parmsSize));
                if (hits.Count >= maxHits) break;
              }
            }
            if (hits.Count >= maxHits) break;
            if ((ulong)readSize >= remaining) {
              break;
            }
            if (readSize > 0xE0) {
              pos += (ulong)(readSize - 0xE0);
            } else {
              pos += (ulong)readSize;
            }
          }
        }

        if (hits.Count >= maxHits) break;
        addr = end;
      }

      StringBuilder sb = new StringBuilder();
      sb.AppendLine(string.Format("regions={0}", regions));
      sb.AppendLine(string.Format("scanned=0x{0:X}", scanned));
      sb.AppendLine(string.Format("hits={0}", hits.Count));
      for (int i = 0; i < hits.Count; ++i) {
        sb.AppendLine(hits[i]);
      }
      return sb.ToString();
    } finally {
      CloseHandle(h);
    }
  }
}
'@

  Add-Type -TypeDefinition $source
}

function Find-UFunctionCandidate([int]$TargetProcessId, [UInt64[]]$NativeTargets) {
  Ensure-NativeScannerType
  $scan = [BmfNativeTargetScanner]::Scan($TargetProcessId, $NativeTargets, 0xD8, 0xB0, 1, 8, 0x10, 0x200, 50)
  $hits = New-Object System.Collections.Generic.List[UInt64]
  foreach ($line in ($scan -split "`r?`n")) {
    if ($line -match '^candidate=0x([0-9A-Fa-f]+)\s+') {
      $hits.Add([Convert]::ToUInt64($Matches[1], 16))
    }
  }
  return [ordered]@{
    scanOutput = $scan
    hits = @($hits)
  }
}

function Test-ExistingInstalledHook([int]$TargetProcessId, [UInt64[]]$NativeTargets, [hashtable]$Status) {
  if (!$Status.ContainsKey('installed') -or [string]$Status['installed'] -ne '1') {
    return $false
  }
  if (!$Status.ContainsKey('function') -or !$Status.ContainsKey('detour') -or !$Status.ContainsKey('original')) {
    return $false
  }
  $hookModules = @(Get-Process -Id $TargetProcessId -ErrorAction Stop | ForEach-Object {
    $_.Modules | Where-Object {
      $_.ModuleName -like 'bmf_applicator_func_blocker*' -or $_.FileName -like '*bmf_applicator_func_blocker*'
    }
  })
  if ($hookModules.Count -eq 0) {
    return $false
  }

  $function = Convert-HexToUInt64 ([string]$Status['function']) 'status.function'
  $detour = Convert-HexToUInt64 ([string]$Status['detour']) 'status.detour'
  $original = Convert-HexToUInt64 ([string]$Status['original']) 'status.original'
  $originalMatches = $false
  foreach ($target in $NativeTargets) {
    if ($target -eq $original) {
      $originalMatches = $true
      break
    }
  }
  if (!$originalMatches) {
    return $false
  }

  Ensure-NativeScannerType
  $inspect = [BmfNativeTargetScanner]::Inspect($TargetProcessId, $function, 0xD8, 0xB0)
  $values = Convert-KeyValueLines ($inspect -split "`r?`n")
  if (!$values.ContainsKey('valid') -or [string]$values['valid'] -ne '1') {
    return $false
  }
  if (!$values.ContainsKey('slot')) {
    return $false
  }
  $slot = Convert-HexToUInt64 ([string]$values['slot']) 'inspected.slot'
  return $slot -eq $detour
}

function Set-ControlValues([string]$Path, [hashtable]$Updates) {
  $defaultLines = @(
    'enable=1',
    'block=1',
    'scan_net_native=0',
    'scan_process_memory=0',
    'scan_only=0',
    'function=0x0',
    'denied_component=0x0',
    'func_offset=0xD8',
    'function_flags_offset=0xB0',
    'locals_offset=0x28',
    'node_offset=0x0',
    'required_function_flags=0x440',
    'excluded_function_flags=0x0',
    'max_hooks=0',
    'min_params=1',
    'max_params=8',
    'min_params_size=0x10',
    'max_params_size=0x200',
    'max_scan_bytes=0x40000000'
  )

  $lines = @()
  if (Test-Path -LiteralPath $Path) {
    $lines = @([System.IO.File]::ReadAllLines($Path))
  } else {
    $lines = $defaultLines
  }

  $seen = @{}
  $next = New-Object System.Collections.Generic.List[string]
  foreach ($line in $lines) {
    if ($line -match '^\s*([^=\s]+)\s*=') {
      $key = $Matches[1]
      if ($Updates.ContainsKey($key)) {
        if (!$seen.ContainsKey($key)) {
          $next.Add("$key=$($Updates[$key])")
          $seen[$key] = $true
        }
        continue
      }
    }
    $next.Add($line)
  }

  foreach ($key in $Updates.Keys) {
    if (!$seen.ContainsKey($key)) {
      $next.Add("$key=$($Updates[$key])")
    }
  }

  $parent = Split-Path -Parent $Path
  if ($parent) {
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
  }
  [System.IO.File]::WriteAllLines($Path, @($next), [System.Text.Encoding]::UTF8)
}

function Wait-ForInstalledStatus([string]$Path, [UInt64]$Function, [UInt64]$Denied, [int]$TimeoutSeconds) {
  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  while ((Get-Date) -lt $deadline) {
    $status = Read-KeyValueFile $Path
    if ($status.ContainsKey('installed') -and [string]$status['installed'] -eq '1' -and
        $status.ContainsKey('function') -and $status.ContainsKey('denied_component')) {
      $statusFunction = Convert-HexToUInt64 ([string]$status['function']) 'status.function'
      $statusDenied = Convert-HexToUInt64 ([string]$status['denied_component']) 'status.denied_component'
      if ($statusFunction -eq $Function -and $statusDenied -eq $Denied) {
        return $status
      }
    }
    Start-Sleep -Milliseconds 500
  }
  throw "Timed out waiting for native blocker install status to match function=$(Format-Hex64 $Function) denied_component=$(Format-Hex64 $Denied)"
}

$Root = [System.IO.Path]::GetFullPath($Root)
if (!$BrickadiaRoot) {
  $candidateBrickadiaRoot = Join-Path $Root '..\Brickadia'
  if (Test-Path -LiteralPath $candidateBrickadiaRoot) {
    $BrickadiaRoot = (Resolve-Path -LiteralPath $candidateBrickadiaRoot).Path
  } else {
    $BrickadiaRoot = (Get-Location).Path
  }
}
$BrickadiaRoot = [System.IO.Path]::GetFullPath($BrickadiaRoot)

if (!$RuntimeBmfDir) {
  $RuntimeBmfDir = Join-Path $env:APPDATA 'omegga\steam_installs\main\Brickadia\Binaries\Win64\ue4ss\main\Mods\BMF'
}
if (!$ControlPath) {
  $ControlPath = Join-Path $Root 'artifacts/local/applicator-func-blocker-control.txt'
}
if (!$StatusPath) {
  $StatusPath = Join-Path $Root 'artifacts/local/applicator-func-blocker-status.txt'
}
if (!$BuildScript) {
  $BuildScript = Join-Path $Root 'scripts/build-applicator-blocker-native-hook.ps1'
}
if (!$InjectScript) {
  $InjectScript = Join-Path $Root 'scripts/inject-applicator-blocker-native-hook.ps1'
}
if (!$BridgeDir) {
  $BridgeDir = Find-LatestBridgeDir $BrickadiaRoot
}

$script:BridgeDir = [System.IO.Path]::GetFullPath($BridgeDir)
$script:RuntimeBmfDir = [System.IO.Path]::GetFullPath($RuntimeBmfDir)
$script:SendRpcScript = Join-Path $BrickadiaRoot 'brickadia-ue4ss-re/scripts/send-bridge-rpc.js'
$script:SocketCommandScript = Join-Path $Root 'scripts/invoke-bmf-socket-command.js'

if ($ProcessId -eq 0) {
  $serverProcess = Get-Process BrickadiaServer-Win64-Shipping -ErrorAction Stop |
    Sort-Object StartTime -Descending |
    Select-Object -First 1
  $ProcessId = $serverProcess.Id
} else {
  $serverProcess = Get-Process -Id $ProcessId -ErrorAction Stop
}

$module = $serverProcess.Modules |
  Where-Object { $_.ModuleName -eq 'BrickadiaServer-Win64-Shipping.exe' } |
  Select-Object -First 1
if (!$module) {
  $module = $serverProcess.MainModule
}
if (!$module) {
  throw "Could not resolve Brickadia server main module for PID $ProcessId"
}

$moduleBase = [UInt64]$module.BaseAddress.ToInt64()
$nativeTargets = New-Object System.Collections.Generic.List[UInt64]
foreach ($rva in $ServerAddComponentRvas) {
  $nativeTargets.Add($moduleBase + $rva)
}
$nativeTargetArray = [UInt64[]]$nativeTargets.ToArray()

$nativeTargetResponse = $null
if (!$DeniedComponent) {
  $nativeTargetResponse = Invoke-BmfCommand 'bmf.tools.applicator.native-targets refresh=true unsafe=true'
  if (!$nativeTargetResponse.values.ContainsKey('denied_component') -or !$nativeTargetResponse.values['denied_component']) {
    throw "BMF native target response did not include denied_component."
  }
  $DeniedComponent = [string]$nativeTargetResponse.values['denied_component']
}
$deniedComponentValue = Convert-HexToUInt64 $DeniedComponent 'denied_component'
if ($deniedComponentValue -eq 0) {
  throw 'BMF native target discovery returned a null denied_component; refusing to inject a non-enforcing hook.'
}
$deniedComponentDescribeResponse = Invoke-BmfCommand "bmf.tools.uobject.describe address=$DeniedComponent"
$deniedComponentDescribe = $deniedComponentDescribeResponse.values
$describedName = [string]$deniedComponentDescribe['object_name']
$describedFullName = [string]$deniedComponentDescribe['object_full_name']
$describedClass = [string]$deniedComponentDescribe['object_class']
$describedClassFullName = [string]$deniedComponentDescribe['object_class_full_name']
$deniedComponentVerified =
  [string]$deniedComponentDescribe['ok'] -eq 'true' -and
  $describedName -eq 'Component_ItemSpawn' -and
  $describedFullName.Contains(':BRRegistry.Component_ItemSpawn') -and
  $describedClass -eq 'Component_ItemSpawn_C' -and
  $describedClassFullName.Contains('/Game/Bricks/ComponentTypes/Component_ItemSpawn.Component_ItemSpawn_C')
if (!$deniedComponentVerified) {
  throw "Refusing to inject: denied_component=$DeniedComponent is not the live BRRegistry Component_ItemSpawn object."
}

$functionValue = [UInt64]0
$scanResult = Find-UFunctionCandidate $ProcessId $nativeTargetArray
if ($scanResult.hits.Count -eq 1) {
  $functionValue = [UInt64]$scanResult.hits[0]
} elseif ($scanResult.hits.Count -gt 1) {
  throw "Expected one ServerAddComponent UFunction candidate, found $($scanResult.hits.Count).`n$($scanResult.scanOutput)"
}

$statusBefore = Read-KeyValueFile $StatusPath
$alreadyInstalled = $false
if ($functionValue -eq 0) {
  $alreadyInstalled = Test-ExistingInstalledHook $ProcessId $nativeTargetArray $statusBefore
  if ($alreadyInstalled) {
    $functionValue = Convert-HexToUInt64 ([string]$statusBefore['function']) 'status.function'
  } else {
    throw "Could not find a live ServerAddComponent UFunction candidate and no valid existing hook was detected.`n$($scanResult.scanOutput)"
  }
}

$controlUpdates = @{
  function = Format-Hex64 $functionValue
  denied_component = Format-Hex64 $deniedComponentValue
  scan_net_native = '0'
  scan_process_memory = '0'
  scan_only = '0'
  max_hooks = '0'
}
Set-ControlValues $ControlPath $controlUpdates

$injected = $false
$dllPath = ''
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
  if (!$DllName) {
    $DllName = 'bmf_applicator_func_blocker_pid{0}_{1}.dll' -f $ProcessId, (Get-Date -Format 'yyyyMMddHHmmss')
  }
  $buildOutput = & $BuildScript -DllName $DllName
  $builtItem = $buildOutput | Where-Object { $_ -is [System.IO.FileInfo] } | Select-Object -Last 1
  if ($builtItem) {
    $dllPath = $builtItem.FullName
  } else {
    $dllPath = Join-Path $Root "artifacts/local/$DllName"
  }
  if (!(Test-Path -LiteralPath $dllPath)) {
    throw "Native blocker DLL was not built: $dllPath"
  }

  & $InjectScript -ProcessId $ProcessId -DllPath $dllPath | Out-Null
  $injected = $true
  $verifiedStatus = Wait-ForInstalledStatus $StatusPath $functionValue $deniedComponentValue $VerificationTimeoutSeconds
}

$result = [ordered]@{
  feature = 'applicator.native-func-blocker.sync'
  status = 'ready'
  processId = $ProcessId
  processName = $serverProcess.ProcessName
  moduleBase = Format-Hex64 $moduleBase
  serverAddComponentNativeTargets = @($nativeTargets | ForEach-Object { Format-Hex64 $_ })
  function = Format-Hex64 $functionValue
  deniedComponent = Format-Hex64 $deniedComponentValue
  alreadyInstalled = [bool]$alreadyInstalled
  injected = [bool]$injected
  skippedInject = [bool]$SkipInject
  forceReinject = [bool]$ForceReinject
  controlPath = [System.IO.Path]::GetFullPath($ControlPath)
  statusPath = [System.IO.Path]::GetFullPath($StatusPath)
  bridgeDir = $script:BridgeDir
  runtimeBmfDir = $script:RuntimeBmfDir
  nativeTargetResponsePath = if ($nativeTargetResponse) { $nativeTargetResponse.responsePath } else { '' }
  deniedComponentDescribeResponsePath = $deniedComponentDescribeResponse.responsePath
  deniedComponentVerified = [bool]$deniedComponentVerified
  deniedComponentObjectName = $describedName
  deniedComponentObjectFullName = $describedFullName
  dllPath = $dllPath
  scan = @{
    hits = $scanResult.hits.Count
  }
  verifiedStatus = $verifiedStatus
}

$json = $result | ConvertTo-Json -Depth 8
if ($OutJson) {
  $outPath = [System.IO.Path]::GetFullPath($OutJson)
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $outPath) | Out-Null
  Set-Content -LiteralPath $outPath -Value $json -Encoding UTF8
}

$json
