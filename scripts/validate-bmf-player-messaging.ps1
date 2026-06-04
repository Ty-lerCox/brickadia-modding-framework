param(
  [string]$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
  [string]$BrickadiaRoot = '',
  [string]$RuntimeModsDir = 'C:\Users\tycox\AppData\Roaming\omegga\steam_installs\main\Brickadia\Binaries\Win64\ue4ss\main\Mods',
  [string]$OutJson = '',
  [int]$Port = 7842
)

$ErrorActionPreference = 'Stop'

if (!$BrickadiaRoot) {
  $BrickadiaRoot = (Resolve-Path (Join-Path $Root '..\Brickadia')).Path
}
if (!$OutJson) {
  $OutJson = Join-Path $Root 'artifacts/local/bmf-player-messaging-canary.json'
}

$errors = New-Object System.Collections.Generic.List[string]
$evidence = New-Object System.Collections.Generic.List[object]
$commandResults = New-Object System.Collections.Generic.List[object]
$startedAt = (Get-Date).ToUniversalTime().ToString('o')
$outPath = [System.IO.Path]::GetFullPath($OutJson)
$artifactRoot = Split-Path -Parent $outPath
$caseRoot = Join-Path $artifactRoot 'bmf-player-messaging'
New-Item -ItemType Directory -Force -Path $caseRoot | Out-Null

$startServerScript = Join-Path $BrickadiaRoot 'brickadia-ue4ss-re/scripts/start-bridge-test-server.ps1'
$sendRpcScript = Join-Path $BrickadiaRoot 'brickadia-ue4ss-re/scripts/send-bridge-rpc.js'
$sourceBmfDir = Join-Path $Root 'framework/ue4ss/Mods/BMF'
$runtimeBmfDir = Join-Path $RuntimeModsDir 'BMF'
$runtimePluginDir = Join-Path $runtimeBmfDir 'plugins/PlayerMessagingCanary'
$runtimeLogPath = Join-Path $runtimeBmfDir 'runtime/bmf.log'
$runtimePluginLogPath = Join-Path $runtimeBmfDir 'runtime/logs/plugins/PlayerMessagingCanary.log'
$runtimeStatusPath = Join-Path $runtimeBmfDir 'runtime/status.json'
$bridgeDir = Join-Path $caseRoot "bridge-$Port"
$startPath = Join-Path $caseRoot 'server-start.json'
$pluginStagePath = Join-Path $caseRoot 'player-messaging-plugin-stage.json'
$bmfLogPath = Join-Path $caseRoot 'bmf.log'
$pluginLogPath = Join-Path $caseRoot 'PlayerMessagingCanary.log'
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
  "name": "PlayerMessagingCanary",
  "version": "1.0.0",
  "author": "BMF",
  "description": "Temporary BMF player lookup and private messaging canary plugin.",
  "capabilities": ["plugins.lifecycle", "chat.whisper", "chat.statusMessage"]
}
'@
  Set-Content -LiteralPath (Join-Path $runtimePluginDir 'bmf.json') -Value $manifestSource -Encoding UTF8

  $pluginSource = @'
local players = {
  {
    uuid = "11111111-1111-4111-8111-111111111111",
    username = "OriginalBuilder",
    playerName = "OriginalBuilder",
    displayName = "Build Lead",
    originalName = "OriginalBuilder",
    roles = { "Admin" },
    controllerAvailable = false,
  },
}

return {
  name = "PlayerMessagingCanary",
  onLoad = function(BMF)
    BMF.commands.register("bmf.player.messaging.canary", "Player messaging canary.", function()
      local exact = BMF.players.find(players, "OriginalBuilder")
      local partial = BMF.players.find(players, "Lead")
      local by_uuid = BMF.players.find(players, "11111111-1111-4111-8111-111111111111")
      local named = BMF.players.getName(players[1])
      local whisper = BMF.chat.whisper(players[1], "private hello")
      local status = BMF.chat.statusMessage(players[1], "status hello")
      local missing = BMF.chat.whisper("MissingPlayer", "private hello")
      BMF.logInfo("PlayerMessagingCanary handled", {
        exact = exact.code,
        partial = partial.code,
        whisper = whisper.code,
        missing = missing.code,
      })
      return BMF.result(true, "OK", "Player messaging canary handled", {
        lines = {
          "exact_ok=" .. tostring(exact.ok),
          "exact_match=" .. tostring(exact.data and exact.data.match or ""),
          "partial_ok=" .. tostring(partial.ok),
          "partial_match=" .. tostring(partial.data and partial.data.match or ""),
          "uuid_ok=" .. tostring(by_uuid.ok),
          "name_ok=" .. tostring(named.ok),
          "display_name=" .. tostring(named.data and named.data.displayName or ""),
          "original_name=" .. tostring(named.data and named.data.originalName or ""),
          "whisper_ok=" .. tostring(whisper.ok),
          "whisper_code=" .. tostring(whisper.code),
          "whisper_delivered=" .. tostring((whisper.data and whisper.data.delivered) == true),
          "status_ok=" .. tostring(status.ok),
          "status_code=" .. tostring(status.code),
          "missing_code=" .. tostring(missing.code),
          "missing_adapter=" .. tostring(missing.data and missing.data.adapter or ""),
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
    command = 'bmf.player.messaging.canary'
  } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $pluginStagePath -Encoding UTF8
  Add-Evidence 'json' $pluginStagePath 'Temporary PlayerMessagingCanary plugin staging result'

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

    Invoke-BmfConsoleCommand 'bmf.player.messaging.canary' 'bmf-player-messaging-canary' @(
      'BMF bmf.player.messaging.canary OK',
      'exact_ok=true',
      'exact_match=username',
      'partial_ok=true',
      'partial_match=partial:displayName',
      'uuid_ok=true',
      'name_ok=true',
      'display_name=Build Lead',
      'original_name=OriginalBuilder',
      'whisper_ok=false',
      'whisper_code=PLAYER_DELIVERY_UNAVAILABLE',
      'whisper_delivered=false',
      'status_ok=false',
      'status_code=PLAYER_DELIVERY_UNAVAILABLE',
      'missing_code=PLAYER_NOT_FOUND',
      'missing_adapter=headless-empty'
    )

    Invoke-BmfConsoleCommand 'bmf.players.find query=MissingPlayer' 'bmf-players-find-missing' @(
      'BMF bmf.players.find PLAYER_NOT_FOUND',
      'query=MissingPlayer',
      'code=PLAYER_NOT_FOUND',
      'adapter=headless-empty'
    )

    Invoke-BmfConsoleCommand 'bmf.players.getname query=MissingPlayer' 'bmf-players-getname-missing' @(
      'BMF bmf.players.getname PLAYER_NOT_FOUND',
      'query=MissingPlayer',
      'code=PLAYER_NOT_FOUND',
      'adapter=headless-empty'
    )

    Invoke-BmfConsoleCommand 'bmf.chat.whisper target=MissingPlayer message=hello' 'bmf-chat-whisper-missing' @(
      'BMF bmf.chat.whisper PLAYER_NOT_FOUND',
      'target=MissingPlayer',
      'message=hello',
      'code=PLAYER_NOT_FOUND',
      'adapter=headless-empty'
    )

    Invoke-BmfConsoleCommand 'bmf.chat.statusmessage target=MissingPlayer message=hello' 'bmf-chat-statusmessage-missing' @(
      'BMF bmf.chat.statusmessage PLAYER_NOT_FOUND',
      'target=MissingPlayer',
      'message=hello',
      'code=PLAYER_NOT_FOUND',
      'adapter=headless-empty'
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
  Add-Evidence 'log' $bmfLogPath 'BMF runtime log with player messaging evidence'
  $logText = Get-Content -Raw -LiteralPath $bmfLogPath
  foreach ($needle in @(
    'registered console command bmf.chat.whisper',
    'registered console command bmf.chat.statusmessage',
    'registered console command bmf.players.find',
    'registered console command bmf.players.getname',
    'PlayerMessagingCanary handled',
    'BMF bmf.chat.whisper PLAYER_NOT_FOUND',
    'BMF bmf.chat.statusmessage PLAYER_NOT_FOUND'
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
  Add-Evidence 'log' $pluginLogPath 'PlayerMessagingCanary per-plugin log'
} else {
  $errors.Add("Plugin log was not written: $runtimePluginLogPath")
}

if (Test-Path -LiteralPath $runtimeStatusPath) {
  Copy-Item -LiteralPath $runtimeStatusPath -Destination $statusPath -Force
  Add-Evidence 'json' $statusPath 'BMF runtime status after player messaging canary'
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

$resultStatus = 'failed'
if ($errors.Count -eq 0) {
  $resultStatus = 'passed'
}

$result = [ordered]@{
  feature = 'bmf.player-messaging'
  status = $resultStatus
  validationLevel = 'L2 Headless + L0 Fixture'
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
