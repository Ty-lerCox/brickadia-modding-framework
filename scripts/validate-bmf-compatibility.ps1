param(
  [string]$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
  [string]$BrickadiaRoot = '',
  [string]$RuntimeModsDir = 'C:\Users\tycox\AppData\Roaming\omegga\steam_installs\main\Brickadia\Binaries\Win64\ue4ss\main\Mods',
  [string]$OutJson = '',
  [int]$Port = 7848
)

$ErrorActionPreference = 'Stop'

if (!$BrickadiaRoot) {
  $BrickadiaRoot = (Resolve-Path (Join-Path $Root '..\Brickadia')).Path
}
if (!$OutJson) {
  $OutJson = Join-Path $Root 'artifacts/local/bmf-compatibility-canary.json'
}

$errors = New-Object System.Collections.Generic.List[string]
$evidence = New-Object System.Collections.Generic.List[object]
$commandResults = New-Object System.Collections.Generic.List[object]
$startedAt = (Get-Date).ToUniversalTime().ToString('o')
$outPath = [System.IO.Path]::GetFullPath($OutJson)
$artifactRoot = Split-Path -Parent $outPath
$caseRoot = Join-Path $artifactRoot 'bmf-compatibility'
New-Item -ItemType Directory -Force -Path $caseRoot | Out-Null

$startServerScript = Join-Path $BrickadiaRoot 'brickadia-ue4ss-re/scripts/start-bridge-test-server.ps1'
$sendRpcScript = Join-Path $BrickadiaRoot 'brickadia-ue4ss-re/scripts/send-bridge-rpc.js'
$sourceBmfDir = Join-Path $Root 'framework/ue4ss/Mods/BMF'
$runtimeBmfDir = Join-Path $RuntimeModsDir 'BMF'
$runtimePluginDir = Join-Path $runtimeBmfDir 'plugins/CompatibilityCanary'
$runtimeLogPath = Join-Path $runtimeBmfDir 'runtime/bmf.log'
$runtimePluginLogPath = Join-Path $runtimeBmfDir 'runtime/logs/plugins/CompatibilityCanary.log'
$runtimeStatusPath = Join-Path $runtimeBmfDir 'runtime/status.json'
$bridgeDir = Join-Path $caseRoot "bridge-$Port"
$startPath = Join-Path $caseRoot 'server-start.json'
$pluginStagePath = Join-Path $caseRoot 'compatibility-plugin-stage.json'
$bmfLogPath = Join-Path $caseRoot 'bmf.log'
$pluginLogPath = Join-Path $caseRoot 'CompatibilityCanary.log'
$statusPath = Join-Path $caseRoot 'status.json'
$serverPid = $null

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

function Invoke-BmfConsoleCommand(
  [string]$Command,
  [string]$Slug,
  [string[]]$ExpectedLines,
  [bool]$ExpectedOk = $true
) {
  $rpcPath = Join-Path $caseRoot "$Slug-rpc.json"
  $bridgeCommand = "Omegga.Bridge.BMF $Command"
  $responseArtifactPath = Join-Path $caseRoot "$Slug-response.txt"
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
    $deadline = (Get-Date).AddSeconds(15)
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
    expectedOk = $ExpectedOk
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
  foreach ($path in @($startServerScript, $sendRpcScript, $sourceBmfDir)) {
    if (!(Test-Path -LiteralPath $path)) {
      throw "Required path does not exist: $path"
    }
  }

  if (Test-Path -LiteralPath $runtimeBmfDir) {
    Remove-Item -LiteralPath $runtimeBmfDir -Recurse -Force
  }
  New-Item -ItemType Directory -Force -Path $runtimeBmfDir | Out-Null
  Copy-Item -Path (Join-Path $sourceBmfDir '*') -Destination $runtimeBmfDir -Recurse -Force
  New-Item -ItemType Directory -Force -Path $runtimePluginDir | Out-Null

  $manifestSource = @'
{
  "name": "CompatibilityCanary",
  "version": "1.0.0",
  "author": "BMF",
  "description": "Temporary BMF compatibility diagnostics canary plugin.",
  "capabilities": ["plugins.lifecycle"]
}
'@
  Set-Content -LiteralPath (Join-Path $runtimePluginDir 'bmf.json') -Value $manifestSource -Encoding UTF8

  $pluginSource = @'
return {
  name = "CompatibilityCanary",
  onLoad = function(BMF)
    BMF.commands.register("bmf.compatibility.canary", "Compatibility diagnostics canary.", function()
      local checked = BMF.compatibility.check()
      local helpers = BMF.compatibility.helpers()
      local health = BMF.health()
      local api = BMF.apis.get("BMF.compatibility.check")
      local data = checked.data or {}
      local ue4ss = data.ue4ss or {}
      local group_count = #(ue4ss.helperGroups or {})
      local console_executor = false
      local timer_scheduler = false
      for _, group in ipairs(ue4ss.helperGroups or {}) do
        if group.id == "consoleExecutor" then
          console_executor = group.available == true
        elseif group.id == "timerScheduler" then
          timer_scheduler = group.available == true
        end
      end
      local api_label = api.data and api.data.api or {}

      BMF.logInfo("CompatibilityCanary handled", {
        status = data.status,
        targetBuild = data.targetBuild,
      })

      return BMF.result(true, "OK", "Compatibility canary handled", {
        lines = {
          "compatibility_status=" .. tostring(data.status or ""),
          "target_build=" .. tostring(data.targetBuild or ""),
          "platform=" .. tostring(data.platform or ""),
          "build_detection=" .. tostring(data.buildDetection or ""),
          "unsupported_build_policy=" .. tostring(data.unsupportedBuildPolicy or ""),
          "required_groups_available=" .. tostring((ue4ss.requiredGroupCount or 0) == (ue4ss.requiredGroupsAvailable or -1)),
          "missing_required_groups=" .. tostring(#(ue4ss.missingRequiredGroups or {})),
          "console_executor_available=" .. tostring(console_executor),
          "timer_scheduler_available=" .. tostring(timer_scheduler),
          "helper_group_count_at_least_5=" .. tostring(group_count >= 5),
          "api_stability=" .. tostring(api_label.stability or ""),
          "api_risk=" .. tostring(api_label.risk or ""),
          "health_target_build=" .. tostring((health.data and health.data.target_build) or ""),
          "health_compatibility_status=" .. tostring((health.data and health.data.compatibility_status) or ""),
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
    command = 'bmf.compatibility.canary'
  } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $pluginStagePath -Encoding UTF8
  Add-Evidence 'json' $pluginStagePath 'Temporary CompatibilityCanary plugin staging result'

  foreach ($path in @($runtimeLogPath, $runtimeStatusPath)) {
    if (Test-Path -LiteralPath $path) {
      Remove-Item -LiteralPath $path -Force
    }
  }

  $startOutput = & $startServerScript -BridgeDir $bridgeDir -Port $Port -VerifyWaitSeconds 30
  $startOutput | Set-Content -LiteralPath $startPath -Encoding UTF8
  $start = $startOutput | ConvertFrom-Json
  $serverPid = [int]$start.pid
  Add-Evidence 'json' $startPath 'Bridge test server startup result'
  if ($start.verified -ne $true) {
    $errors.Add("Bridge server did not verify: $($start.verify_reason)")
  } else {
    Start-Sleep -Seconds 4

    Invoke-BmfConsoleCommand 'bmf.compatibility.canary' 'bmf-compatibility-canary' @(
      'BMF bmf.compatibility.canary OK',
      'compatibility_status=ok',
      'target_build=PC-Shipping-CL15565',
      'platform=windows-dedicated-server',
      'build_detection=declared-target-only',
      'unsupported_build_policy=report-only',
      'required_groups_available=true',
      'missing_required_groups=0',
      'console_executor_available=true',
      'timer_scheduler_available=true',
      'helper_group_count_at_least_5=true',
      'api_stability=stable',
      'api_risk=low',
      'health_target_build=PC-Shipping-CL15565',
      'health_compatibility_status=ok'
    )

    Invoke-BmfConsoleCommand 'bmf.compatibility' 'bmf-compatibility' @(
      'BMF bmf.compatibility OK',
      'compatibility_status=ok',
      'target_build=PC-Shipping-CL15565',
      'platform=windows-dedicated-server',
      'build_detection=declared-target-only',
      'unsupported_build_policy=report-only',
      'ue4ss_required=true',
      'ue4ss_status=patched-runtime-required',
      'required_helper_groups=2',
      'required_helper_groups_available=2',
      'missing_required_helper_groups=',
      'helper_consoleExecutor_available=true',
      'helper_timerScheduler_available=true',
      'helper_consoleCommandRegistration_required=false',
      'helper_objectLookup_required=false'
    )

    Invoke-BmfConsoleCommand 'bmf.status' 'bmf-status-compatibility' @(
      'BMF bmf.status OK',
      'target_build=PC-Shipping-CL15565',
      'compatibility_status=ok',
      'build_detection=declared-target-only',
      'runtime_required_helper_groups=2',
      'runtime_required_helper_groups_available=2'
    )

    Invoke-BmfConsoleCommand 'bmf.server.status' 'bmf-server-status-compatibility' @(
      'BMF bmf.server.status OK',
      'build_id=PC-Shipping-CL15565',
      'compatibility_status=ok',
      'target_build=PC-Shipping-CL15565',
      'build_detection=declared-target-only',
      'required_helper_groups=2',
      'required_helper_groups_available=2',
      'missing_required_helper_groups=0'
    )

    Invoke-BmfConsoleCommand 'bmf.apis name=BMF.compatibility.check' 'bmf-apis-compatibility-check' @(
      'BMF bmf.apis OK',
      'api_count=1',
      'api_1=BMF.compatibility.check|namespace=compatibility|stability=stable|risk=low'
    )
  }
} catch {
  $errors.Add($_.Exception.Message)
} finally {
  if ($serverPid) {
    Stop-Process -Id $serverPid -Force -ErrorAction SilentlyContinue
  }
  Get-CimInstance Win32_Process |
    Where-Object { $_.Name -eq 'BrickadiaServer-Win64-Shipping.exe' -and $_.CommandLine -like "*-port=`"$Port`*"} |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}

if (Test-Path -LiteralPath $runtimeLogPath) {
  Copy-Item -LiteralPath $runtimeLogPath -Destination $bmfLogPath -Force
  Add-Evidence 'log' $bmfLogPath 'BMF runtime log with compatibility diagnostics evidence'
  $logText = Get-Content -Raw -LiteralPath $bmfLogPath
  foreach ($needle in @(
    'registered console command bmf.compatibility',
    'registered console command bmf.compatibility.canary',
    'CompatibilityCanary handled'
  )) {
    if ($logText -notmatch [regex]::Escape($needle)) {
      $errors.Add("BMF log missing expected line: $needle")
    }
  }
} else {
  $errors.Add("BMF runtime log was not written: $runtimeLogPath")
}

if (Test-Path -LiteralPath $runtimePluginLogPath) {
  Copy-Item -LiteralPath $runtimePluginLogPath -Destination $pluginLogPath -Force
  Add-Evidence 'log' $pluginLogPath 'CompatibilityCanary per-plugin log'
} else {
  $errors.Add("Plugin log was not written: $runtimePluginLogPath")
}

if (Test-Path -LiteralPath $runtimeStatusPath) {
  Copy-Item -LiteralPath $runtimeStatusPath -Destination $statusPath -Force
  Add-Evidence 'json' $statusPath 'BMF runtime status after compatibility canary'
  try {
    $status = Read-JsonFile $statusPath
    if ([string]$status.target_build -ne 'PC-Shipping-CL15565') {
      $errors.Add("Expected target_build=PC-Shipping-CL15565, got $($status.target_build).")
    }
    if ([string]$status.build_detection -ne 'declared-target-only') {
      $errors.Add("Expected build_detection=declared-target-only, got $($status.build_detection).")
    }
    if ([string]$status.compatibility_status -ne 'ok') {
      $errors.Add("Expected compatibility_status=ok, got $($status.compatibility_status).")
    }
    if ([int]$status.runtime_required_helper_groups -ne 2) {
      $errors.Add("Expected runtime_required_helper_groups=2, got $($status.runtime_required_helper_groups).")
    }
    if ([int]$status.runtime_required_helper_groups_available -ne 2) {
      $errors.Add("Expected runtime_required_helper_groups_available=2, got $($status.runtime_required_helper_groups_available).")
    }
    if ([int]$status.runtime_missing_required_helper_groups -ne 0) {
      $errors.Add("Expected runtime_missing_required_helper_groups=0, got $($status.runtime_missing_required_helper_groups).")
    }
  } catch {
    $errors.Add("Could not parse BMF status: $($_.Exception.Message)")
  }
} else {
  $errors.Add("BMF runtime status was not written: $runtimeStatusPath")
}

$resultStatus = 'failed'
if ($errors.Count -eq 0) {
  $resultStatus = 'passed'
}

$result = [ordered]@{
  feature = 'bmf.compatibility'
  status = $resultStatus
  validationLevel = 'L2 Headless'
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
