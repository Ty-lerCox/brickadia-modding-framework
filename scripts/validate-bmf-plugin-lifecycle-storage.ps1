param(
  [string]$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
  [string]$BrickadiaRoot = '',
  [string]$RuntimeModsDir = 'C:\Users\tycox\AppData\Roaming\omegga\steam_installs\main\Brickadia\Binaries\Win64\ue4ss\main\Mods',
  [string]$OutJson = '',
  [int]$Port = 7831
)

$ErrorActionPreference = 'Stop'

if (!$BrickadiaRoot) {
  $BrickadiaRoot = (Resolve-Path (Join-Path $Root '..\Brickadia')).Path
}
if (!$OutJson) {
  $OutJson = Join-Path $Root 'artifacts/local/bmf-plugin-lifecycle-storage-canary.json'
}

$errors = New-Object System.Collections.Generic.List[string]
$evidence = New-Object System.Collections.Generic.List[object]
$commandResults = New-Object System.Collections.Generic.List[object]
$startedAt = (Get-Date).ToUniversalTime().ToString('o')
$outPath = [System.IO.Path]::GetFullPath($OutJson)
$artifactRoot = Split-Path -Parent $outPath
$caseRoot = Join-Path $artifactRoot 'bmf-plugin-lifecycle-storage'
New-Item -ItemType Directory -Force -Path $caseRoot | Out-Null

$startServerScript = Join-Path $BrickadiaRoot 'brickadia-ue4ss-re/scripts/start-bridge-test-server.ps1'
$sendRpcScript = Join-Path $BrickadiaRoot 'brickadia-ue4ss-re/scripts/send-bridge-rpc.js'
$sourceBmfDir = Join-Path $Root 'framework/ue4ss/Mods/BMF'
$runtimeBmfDir = Join-Path $RuntimeModsDir 'BMF'
$runtimePluginDir = Join-Path $runtimeBmfDir 'plugins/LifecycleStorageCanary'
$runtimeLogPath = Join-Path $runtimeBmfDir 'runtime/bmf.log'
$runtimeStatusPath = Join-Path $runtimeBmfDir 'runtime/status.json'
$bridgeDir = Join-Path $caseRoot "bridge-$Port"
$startPath = Join-Path $caseRoot 'server-start.json'
$pluginStagePath = Join-Path $caseRoot 'lifecycle-storage-plugin-stage.json'
$bmfLogPath = Join-Path $caseRoot 'bmf.log'
$statusPath = Join-Path $caseRoot 'status.json'
$dataCopyDir = Join-Path $caseRoot 'plugin-data'
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
  New-Item -ItemType Directory -Force -Path $runtimePluginDir | Out-Null

  $manifestSource = @'
{
  "name": "LifecycleStorageCanary",
  "version": "1.2.3",
  "author": "BMF",
  "description": "Temporary lifecycle and storage canary plugin.",
  "capabilities": ["plugins.lifecycle", "plugins.storage"]
}
'@
  Set-Content -LiteralPath (Join-Path $runtimePluginDir 'bmf.json') -Value $manifestSource -Encoding UTF8

  $pluginSource = @'
local NAME = "LifecycleStorageCanary"

local function read_number(BMF, path)
  local read = BMF.storage.readText(NAME, path)
  if read.ok then
    return tonumber(read.data.text) or 0
  end
  return 0
end

return {
  name = NAME,
  onLoad = function(BMF)
    local count = read_number(BMF, "state/load-count.txt") + 1
    BMF.storage.writeText(NAME, "state/load-count.txt", tostring(count))
    BMF.storage.writeConfig(NAME, {
      enabled = true,
      lastLoad = count,
      plugin = NAME,
    })
    BMF.storage.writeJson(NAME, "state/profile.json", {
      plugin = NAME,
      loadCount = count,
      score = 42,
      flags = { "json", "storage" },
    })
    BMF.storage.writeText(NAME, "state/bad.json", "{bad json")
    BMF.storage.appendText(NAME, "state/lifecycle.log", "onLoad count=" .. tostring(count) .. "\n")
    BMF.log("LifecycleStorageCanary onLoad count=" .. tostring(count))

    BMF.commands.register("bmf.lifecycle.storage", "Lifecycle storage canary.", function()
      local load_count = read_number(BMF, "state/load-count.txt")
      local unload_count = read_number(BMF, "state/unload-count.txt")
      local config = BMF.storage.readConfigText(NAME)
      local config_json = BMF.storage.readConfig(NAME)
      local profile = BMF.storage.readJson(NAME, "state/profile.json")
      local bad_json = BMF.storage.readJson(NAME, "state/bad.json")
      local escape = BMF.storage.writeText(NAME, "../escape.txt", "bad")
      return BMF.result(true, "OK", "Lifecycle storage canary handled", {
        lines = {
          "load_count=" .. tostring(load_count),
          "unload_count=" .. tostring(unload_count),
          "config_ok=" .. tostring(config.ok),
          "config_json_ok=" .. tostring(config_json.ok),
          "config_last_load=" .. tostring((config_json.data and config_json.data.value and config_json.data.value.lastLoad) or 0),
          "profile_ok=" .. tostring(profile.ok),
          "profile_load_count=" .. tostring((profile.data and profile.data.value and profile.data.value.loadCount) or 0),
          "profile_score=" .. tostring((profile.data and profile.data.value and profile.data.value.score) or 0),
          "profile_flag_2=" .. tostring((profile.data and profile.data.value and profile.data.value.flags and profile.data.value.flags[2]) or ""),
          "bad_json_ok=" .. tostring(bad_json.ok),
          "bad_json_code=" .. tostring(bad_json.code),
          "escape_ok=" .. tostring(escape.ok),
          "escape_code=" .. tostring(escape.code),
        },
      })
    end)
  end,
  onUnload = function(BMF, reason)
    local count = read_number(BMF, "state/unload-count.txt") + 1
    BMF.storage.writeText(NAME, "state/unload-count.txt", tostring(count))
    BMF.storage.appendText(NAME, "state/lifecycle.log", "onUnload reason=" .. tostring(reason or "") .. " count=" .. tostring(count) .. "\n")
    BMF.log("LifecycleStorageCanary onUnload reason=" .. tostring(reason or "") .. " count=" .. tostring(count))
  end,
}
'@
  Set-Content -LiteralPath (Join-Path $runtimePluginDir 'main.lua') -Value $pluginSource -Encoding UTF8
  [ordered]@{
    pluginDir = [System.IO.Path]::GetFullPath($runtimePluginDir)
    manifest = [System.IO.Path]::GetFullPath((Join-Path $runtimePluginDir 'bmf.json'))
    plugin = [System.IO.Path]::GetFullPath((Join-Path $runtimePluginDir 'main.lua'))
    command = 'bmf.lifecycle.storage'
  } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $pluginStagePath -Encoding UTF8
  Add-Evidence 'json' $pluginStagePath 'Temporary LifecycleStorageCanary plugin staging result'

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

    Invoke-BmfConsoleCommand 'bmf.plugins' 'bmf-plugins-before-reload' @(
      'BMF bmf.plugins OK',
      'plugin=LifecycleStorageCanary version=1.2.3 capabilities=2'
    )
    Invoke-BmfConsoleCommand 'bmf.lifecycle.storage' 'bmf-lifecycle-before-reload' @(
      'BMF bmf.lifecycle.storage OK',
      'load_count=1',
      'unload_count=0',
      'config_ok=true',
      'config_json_ok=true',
      'config_last_load=1',
      'profile_ok=true',
      'profile_load_count=1',
      'profile_score=42',
      'profile_flag_2=storage',
      'bad_json_ok=false',
      'bad_json_code=JSON_PARSE_FAILED',
      'escape_ok=false',
      'escape_code=INVALID_STORAGE_PATH'
    )
    Invoke-BmfConsoleCommand 'bmf.reload' 'bmf-reload' @(
      'BMF bmf.reload OK',
      'plugins_unloaded=1',
      'unload_errors=0',
      'plugins_loaded=1',
      'plugin_errors=0'
    )
    Invoke-BmfConsoleCommand 'bmf.lifecycle.storage' 'bmf-lifecycle-after-reload' @(
      'BMF bmf.lifecycle.storage OK',
      'load_count=2',
      'unload_count=1',
      'config_ok=true',
      'config_json_ok=true',
      'config_last_load=2',
      'profile_ok=true',
      'profile_load_count=2',
      'bad_json_code=JSON_PARSE_FAILED',
      'escape_ok=false'
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
  Add-Evidence 'log' $bmfLogPath 'BMF runtime log with lifecycle/storage evidence'
  $logText = Get-Content -Raw -LiteralPath $bmfLogPath
  foreach ($needle in @(
    'LifecycleStorageCanary onLoad count=1',
    'LifecycleStorageCanary onUnload reason=reload count=1',
    'LifecycleStorageCanary onLoad count=2',
    'BMF bmf.lifecycle.storage OK'
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
  Add-Evidence 'json' $statusPath 'BMF runtime status after lifecycle/storage canary'
  try {
    $status = Read-JsonFile $statusPath
    if ([int]$status.plugins_loaded -lt 1) {
      $errors.Add("Expected at least one plugin loaded, got $($status.plugins_loaded).")
    }
  } catch {
    $errors.Add("Could not parse BMF status: $($_.Exception.Message)")
  }
} else {
  $errors.Add("BMF runtime status was not written: $runtimeStatusPath")
}

if (Test-Path -LiteralPath (Join-Path $runtimePluginDir 'data')) {
  if (Test-Path -LiteralPath $dataCopyDir) {
    Remove-Item -LiteralPath $dataCopyDir -Recurse -Force
  }
  New-Item -ItemType Directory -Force -Path $dataCopyDir | Out-Null
  Copy-Item -Path (Join-Path $runtimePluginDir 'data/*') -Destination $dataCopyDir -Recurse -Force
  Add-Evidence 'directory' $dataCopyDir 'LifecycleStorageCanary persisted data directory'
  $loadCountPath = Join-Path $dataCopyDir 'state/load-count.txt'
  $unloadCountPath = Join-Path $dataCopyDir 'state/unload-count.txt'
  $profilePath = Join-Path $dataCopyDir 'state/profile.json'
  $badJsonPath = Join-Path $dataCopyDir 'state/bad.json'
  if ((Get-Content -Raw -LiteralPath $loadCountPath).Trim() -ne '2') {
    $errors.Add('Persisted load-count.txt did not equal 2 after reload.')
  }
  if ((Get-Content -Raw -LiteralPath $unloadCountPath).Trim() -ne '1') {
    $errors.Add('Persisted unload-count.txt did not equal 1 after reload.')
  }
  try {
    $profile = Read-JsonFile $profilePath
    if ([int]$profile.loadCount -ne 2) {
      $errors.Add("Persisted profile.json loadCount did not equal 2 after reload; got $($profile.loadCount).")
    }
    if ([int]$profile.score -ne 42) {
      $errors.Add("Persisted profile.json score did not equal 42; got $($profile.score).")
    }
  } catch {
    $errors.Add("Persisted profile.json could not be parsed: $($_.Exception.Message)")
  }
  if ((Get-Content -Raw -LiteralPath $badJsonPath).Trim() -ne '{bad json') {
    $errors.Add('Persisted bad.json did not retain malformed JSON fixture.')
  }
} else {
  $errors.Add('LifecycleStorageCanary data directory was not written.')
}

if (Test-Path -LiteralPath $runtimePluginDir) {
  Remove-Item -LiteralPath $runtimePluginDir -Recurse -Force -ErrorAction SilentlyContinue
}

$resultStatus = 'failed'
if ($errors.Count -eq 0) {
  $resultStatus = 'passed'
}

$result = [ordered]@{
  feature = 'bmf.plugins.lifecycle-storage'
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
