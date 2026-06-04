param(
  [string]$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
  [string]$BrickadiaRoot = '',
  [string]$RuntimeModsDir = 'C:\Users\tycox\AppData\Roaming\omegga\steam_installs\main\Brickadia\Binaries\Win64\ue4ss\main\Mods',
  [string]$OutJson = '',
  [int]$Port = 7832,
  [switch]$AllowPluginServerExec
)

$ErrorActionPreference = 'Stop'

if (!$BrickadiaRoot) {
  $BrickadiaRoot = (Resolve-Path (Join-Path $Root '..\Brickadia')).Path
}
if (!$OutJson) {
  $OutJson = Join-Path $Root 'artifacts/local/bmf-capability-gates-canary.json'
}

$errors = New-Object System.Collections.Generic.List[string]
$evidence = New-Object System.Collections.Generic.List[object]
$commandResults = New-Object System.Collections.Generic.List[object]
$startedAt = (Get-Date).ToUniversalTime().ToString('o')
$allowPluginServerExecValue = $AllowPluginServerExec.IsPresent
$configBool = 'false'
$expectedAllowServerExecCode = 'server_exec_code=CONFIG_OPT_IN_REQUIRED'
$featureName = 'bmf.plugins.capability-gates'
$caseName = 'bmf-capability-gates'
if ($allowPluginServerExecValue) {
  $configBool = 'true'
  $expectedAllowServerExecCode = 'server_exec_code=OK'
  $featureName = 'bmf.plugins.capability-gates.server-exec-optin'
  $caseName = 'bmf-capability-gates-server-exec-optin'
}
$outPath = [System.IO.Path]::GetFullPath($OutJson)
$artifactRoot = Split-Path -Parent $outPath
$caseRoot = Join-Path $artifactRoot $caseName
New-Item -ItemType Directory -Force -Path $caseRoot | Out-Null

$startServerScript = Join-Path $BrickadiaRoot 'brickadia-ue4ss-re/scripts/start-bridge-test-server.ps1'
$sendRpcScript = Join-Path $BrickadiaRoot 'brickadia-ue4ss-re/scripts/send-bridge-rpc.js'
$sourceBmfDir = Join-Path $Root 'framework/ue4ss/Mods/BMF'
$runtimeBmfDir = Join-Path $RuntimeModsDir 'BMF'
$runtimeDenyPluginDir = Join-Path $runtimeBmfDir 'plugins/CapabilityDenyCanary'
$runtimeAllowPluginDir = Join-Path $runtimeBmfDir 'plugins/CapabilityAllowCanary'
$runtimeLogPath = Join-Path $runtimeBmfDir 'runtime/bmf.log'
$runtimeStatusPath = Join-Path $runtimeBmfDir 'runtime/status.json'
$bridgeDir = Join-Path $caseRoot "bridge-$Port"
$startPath = Join-Path $caseRoot 'server-start.json'
$pluginStagePath = Join-Path $caseRoot 'capability-plugin-stage.json'
$bmfLogPath = Join-Path $caseRoot 'bmf.log'
$statusPath = Join-Path $caseRoot 'status.json'
$allowDataCopyDir = Join-Path $caseRoot 'allow-plugin-data'
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

function Invoke-BmfConsoleCommand([string]$Command, [string]$Slug, [string[]]$ExpectedLines) {
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

  if (Test-Path -LiteralPath $runtimeBmfDir) {
    Remove-Item -LiteralPath $runtimeBmfDir -Recurse -Force
  }
  New-Item -ItemType Directory -Force -Path $runtimeBmfDir | Out-Null
  Copy-Item -Path (Join-Path $sourceBmfDir '*') -Destination $runtimeBmfDir -Recurse -Force
  New-Item -ItemType Directory -Force -Path $runtimeDenyPluginDir | Out-Null
  New-Item -ItemType Directory -Force -Path $runtimeAllowPluginDir | Out-Null

  $denyManifestSource = @'
{
  "name": "CapabilityDenyCanary",
  "version": "1.0.0",
  "author": "BMF",
  "description": "Temporary capability denial canary plugin.",
  "capabilities": ["plugins.lifecycle"]
}
'@
  Set-Content -LiteralPath (Join-Path $runtimeDenyPluginDir 'bmf.json') -Value $denyManifestSource -Encoding UTF8

  $denyPluginSource = @'
local NAME = "CapabilityDenyCanary"

local function code_of(response)
  if type(response) == "table" then
    return tostring(response.code or "")
  end
  return ""
end

return {
  name = NAME,
  onLoad = function(BMF)
    BMF.commands.register("bmf.capability.deny", "Capability denial canary.", function()
      local server_exec = BMF.server.exec('Chat.Broadcast "[BMF] capability deny should not run"')
      local global_server_exec = _G.BMF.server.exec('Chat.Broadcast "[BMF] global capability deny should not run"')
      local server_save = BMF.server.save({ name = "BMF_CapabilityDenied_ServerSave_ShouldNotSave" })
      local server_shutdown = BMF.server.shutdown({ confirm = "BMF_SHUTDOWN", reason = "capability-deny" })
      local chat = BMF.chat.broadcast("[BMF] capability deny should not run")
      local storage = BMF.storage.writeText(NAME, "state/deny.txt", "bad")
      local save = BMF.world.saveAs("BMF_CapabilityDenied_ShouldNotSave")
      local require_exec = BMF.capabilities.require("server.exec")
      return BMF.result(true, "OK", "Capability denial canary handled", {
        lines = {
          "server_exec_code=" .. code_of(server_exec),
          "global_server_exec_code=" .. code_of(global_server_exec),
          "server_save_code=" .. code_of(server_save),
          "server_shutdown_code=" .. code_of(server_shutdown),
          "chat_code=" .. code_of(chat),
          "storage_code=" .. code_of(storage),
          "world_save_code=" .. code_of(save),
          "has_server_exec=" .. tostring(BMF.capabilities.has("server.exec")),
          "require_server_exec_code=" .. code_of(require_exec),
          "plugin_helper_server_exec=" .. tostring(BMF.plugins.hasCapability(NAME, "server.exec")),
        },
      })
    end)
  end,
}
'@
  Set-Content -LiteralPath (Join-Path $runtimeDenyPluginDir 'main.lua') -Value $denyPluginSource -Encoding UTF8

  $allowManifestSource = @'
{
  "name": "CapabilityAllowCanary",
  "version": "1.0.0",
  "author": "BMF",
  "description": "Temporary capability allowance canary plugin.",
  "capabilities": ["server.exec.restricted", "server.shutdown", "chat.broadcast", "plugins.storage"]
}
'@
  Set-Content -LiteralPath (Join-Path $runtimeAllowPluginDir 'bmf.json') -Value $allowManifestSource -Encoding UTF8

  $allowPluginSource = @'
local NAME = "CapabilityAllowCanary"

local function code_of(response)
  if type(response) == "table" then
    return tostring(response.code or "")
  end
  return ""
end

return {
  name = NAME,
  onLoad = function(BMF)
    BMF.commands.register("bmf.capability.allow", "Capability allowance canary.", function()
      local require_exec = BMF.capabilities.require("server.exec")
      local write_old = BMF.storage.writeText(NAME, "state/allow.txt", "ok")
      local write_short = BMF.storage.writeText("state/short.txt", "short")
      local read_old = BMF.storage.readText(NAME, "state/allow.txt")
      local read_short = BMF.storage.readText("state/short.txt")
      local cross = BMF.storage.writeText("CapabilityDenyCanary", "state/cross.txt", "bad")
      local chat = BMF.chat.broadcast("[BMF] capability allow canary")
      local server_exec = BMF.server.exec('Chat.Broadcast "[BMF] capability server exec canary"')
      local server_shutdown = BMF.server.shutdown({ confirm = "BMF_SHUTDOWN", reason = "capability-config-deny" })
      return BMF.result(true, "OK", "Capability allowance canary handled", {
        lines = {
          "has_server_exec=" .. tostring(BMF.capabilities.has("server.exec")),
          "require_server_exec_code=" .. code_of(require_exec),
          "plugin_helper_server_exec=" .. tostring(BMF.plugins.hasCapability(NAME, "server.exec")),
          "plugin_helper_server_shutdown=" .. tostring(BMF.plugins.hasCapability(NAME, "server.shutdown")),
          "storage_write_code=" .. code_of(write_old),
          "storage_short_write_code=" .. code_of(write_short),
          "storage_read_text=" .. tostring((read_old.data or {}).text or ""),
          "storage_short_read_text=" .. tostring((read_short.data or {}).text or ""),
          "cross_storage_code=" .. code_of(cross),
          "server_exec_code=" .. code_of(server_exec),
          "server_shutdown_code=" .. code_of(server_shutdown),
          "chat_denied=" .. tostring(code_of(chat) == "CAPABILITY_REQUIRED"),
          "server_exec_denied=" .. tostring(code_of(server_exec) == "CAPABILITY_REQUIRED"),
        },
      })
    end)
  end,
}
'@
  Set-Content -LiteralPath (Join-Path $runtimeAllowPluginDir 'main.lua') -Value $allowPluginSource -Encoding UTF8

  $configSource = @"
{
  "allowPluginServerExec": $configBool
}
"@
  Set-Content -LiteralPath (Join-Path $runtimeBmfDir 'config.json') -Value $configSource -Encoding UTF8

  [ordered]@{
    denyPluginDir = [System.IO.Path]::GetFullPath($runtimeDenyPluginDir)
    allowPluginDir = [System.IO.Path]::GetFullPath($runtimeAllowPluginDir)
    configPath = [System.IO.Path]::GetFullPath((Join-Path $runtimeBmfDir 'config.json'))
    allowPluginServerExec = $allowPluginServerExecValue
    commands = @('bmf.capability.deny', 'bmf.capability.allow')
  } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $pluginStagePath -Encoding UTF8
  Add-Evidence 'json' $pluginStagePath 'Temporary capability canary plugin staging result'

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
    Start-Sleep -Seconds 4

    Invoke-BmfConsoleCommand 'bmf.plugins' 'bmf-plugins' @(
      'BMF bmf.plugins OK',
      'plugin=CapabilityAllowCanary version=1.0.0 capabilities=4',
      'plugin=CapabilityDenyCanary version=1.0.0 capabilities=1'
    )
    Invoke-BmfConsoleCommand 'bmf.capability.deny' 'bmf-capability-deny' @(
      'BMF bmf.capability.deny OK',
      'server_exec_code=CAPABILITY_REQUIRED',
      'global_server_exec_code=CAPABILITY_REQUIRED',
      'server_save_code=CAPABILITY_REQUIRED',
      'server_shutdown_code=CAPABILITY_REQUIRED',
      'chat_code=CAPABILITY_REQUIRED',
      'storage_code=CAPABILITY_REQUIRED',
      'world_save_code=CAPABILITY_REQUIRED',
      'has_server_exec=false',
      'require_server_exec_code=CAPABILITY_REQUIRED',
      'plugin_helper_server_exec=false'
    )
    Invoke-BmfConsoleCommand 'bmf.capability.allow' 'bmf-capability-allow' @(
      'BMF bmf.capability.allow OK',
      'has_server_exec=true',
      'require_server_exec_code=OK',
      'plugin_helper_server_exec=true',
      'plugin_helper_server_shutdown=true',
      'storage_write_code=OK',
      'storage_short_write_code=OK',
      'storage_read_text=ok',
      'storage_short_read_text=short',
      'cross_storage_code=CAPABILITY_REQUIRED',
      $expectedAllowServerExecCode,
      'server_shutdown_code=CONFIG_OPT_IN_REQUIRED',
      'chat_denied=false',
      'server_exec_denied=false'
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
  Add-Evidence 'log' $bmfLogPath 'BMF runtime log with capability gate evidence'
  $logText = Get-Content -Raw -LiteralPath $bmfLogPath
  foreach ($needle in @(
    'registered console command bmf.capability.deny',
    'registered console command bmf.capability.allow',
    'BMF bmf.capability.deny OK',
    'BMF bmf.capability.allow OK'
  )) {
    if ($logText -notmatch [regex]::Escape($needle)) {
      $errors.Add("BMF log missing expected line: $needle")
    }
  }
} else {
  $errors.Add("BMF runtime log was not written: $runtimeLogPath")
}

if (Test-Path -LiteralPath $runtimeStatusPath) {
  Copy-Item -LiteralPath $runtimeStatusPath -Destination $statusPath -Force
  Add-Evidence 'json' $statusPath 'BMF runtime status after capability gate canary'
  try {
    $status = Read-JsonFile $statusPath
    if ([int]$status.plugins_loaded -lt 2) {
      $errors.Add("Expected at least two plugins loaded, got $($status.plugins_loaded).")
    }
  } catch {
    $errors.Add("Could not parse BMF status: $($_.Exception.Message)")
  }
} else {
  $errors.Add("BMF runtime status was not written: $runtimeStatusPath")
}

$denyWritePath = Join-Path $runtimeDenyPluginDir 'data/state/deny.txt'
if (Test-Path -LiteralPath $denyWritePath) {
  $errors.Add("Denied plugin wrote storage despite missing capability: $denyWritePath")
}

if (Test-Path -LiteralPath (Join-Path $runtimeAllowPluginDir 'data')) {
  Copy-Item -LiteralPath (Join-Path $runtimeAllowPluginDir 'data') -Destination $allowDataCopyDir -Recurse -Force
  Add-Evidence 'directory' $allowDataCopyDir 'CapabilityAllowCanary persisted data directory'
  $allowPath = Join-Path $allowDataCopyDir 'state/allow.txt'
  $shortPath = Join-Path $allowDataCopyDir 'state/short.txt'
  if ((Get-Content -Raw -LiteralPath $allowPath).Trim() -ne 'ok') {
    $errors.Add('Persisted allow.txt did not equal ok.')
  }
  if ((Get-Content -Raw -LiteralPath $shortPath).Trim() -ne 'short') {
    $errors.Add('Persisted short.txt did not equal short.')
  }
} else {
  $errors.Add('CapabilityAllowCanary data directory was not written.')
}

$resultStatus = 'failed'
if ($errors.Count -eq 0) {
  $resultStatus = 'passed'
}

$result = [ordered]@{
  feature = $featureName
  status = $resultStatus
  validationLevel = 'L2 Headless + L5 Negative'
  startedAt = $startedAt
  finishedAt = (Get-Date).ToUniversalTime().ToString('o')
  data = [ordered]@{
    brickadiaRoot = [System.IO.Path]::GetFullPath($BrickadiaRoot)
    runtimeModsDir = [System.IO.Path]::GetFullPath($RuntimeModsDir)
    port = $Port
    bridgeDir = [System.IO.Path]::GetFullPath($bridgeDir)
    denyPluginDir = [System.IO.Path]::GetFullPath($runtimeDenyPluginDir)
    allowPluginDir = [System.IO.Path]::GetFullPath($runtimeAllowPluginDir)
    allowPluginServerExec = $allowPluginServerExecValue
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
