param(
  [string]$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
  [string]$BrickadiaRoot = '',
  [string]$RuntimeModsDir = 'C:\Users\tycox\AppData\Roaming\omegga\steam_installs\main\Brickadia\Binaries\Win64\ue4ss\main\Mods',
  [string]$OutJson = '',
  [int]$Port = 7856,
  [switch]$AllowSharedRuntimeMutation
)

$ErrorActionPreference = 'Stop'

if (!$BrickadiaRoot) {
  $BrickadiaRoot = (Resolve-Path (Join-Path $Root '..\Brickadia')).Path
}
if (!$OutJson) {
  $OutJson = Join-Path $Root 'artifacts/local/bmf-minigame-commands-canary.json'
}

$errors = New-Object System.Collections.Generic.List[string]
$evidence = New-Object System.Collections.Generic.List[object]
$commandResults = New-Object System.Collections.Generic.List[object]
$startedAt = (Get-Date).ToUniversalTime().ToString('o')
$outPath = [System.IO.Path]::GetFullPath($OutJson)
$artifactRoot = Split-Path -Parent $outPath
$caseRoot = Join-Path $artifactRoot 'bmf-minigame-commands'
New-Item -ItemType Directory -Force -Path $caseRoot | Out-Null

$startServerScript = Join-Path $BrickadiaRoot 'brickadia-ue4ss-re/scripts/start-bridge-test-server.ps1'
$sendRpcScript = Join-Path $BrickadiaRoot 'brickadia-ue4ss-re/scripts/send-bridge-rpc.js'
$sourceBmfDir = Join-Path $Root 'framework/ue4ss/Mods/BMF'
$runtimeBmfDir = Join-Path $RuntimeModsDir 'BMF'
$runtimeLogPath = Join-Path $runtimeBmfDir 'runtime/bmf.log'
$runtimeStatusPath = Join-Path $runtimeBmfDir 'runtime/status.json'
$bridgeDir = Join-Path $caseRoot "bridge-$Port"
$startPath = Join-Path $caseRoot 'server-start.json'
$bmfLogPath = Join-Path $caseRoot 'bmf.log'
$statusPath = Join-Path $caseRoot 'status.json'
$runtimeBackupDir = Join-Path $caseRoot 'runtime-bmf-before-test'
$serverPid = $null
$presetName = 'BMF_CommandMinigameCanary'
$runtimeHadExistingBmf = $false
$runtimeBackupReady = $false
$validationStarted = $false

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

function Assert-SafeRuntimeMutation {
  $runtimeModsFullPath = [System.IO.Path]::GetFullPath($RuntimeModsDir)
  $standardRuntimeModsDir = Join-Path (
    Join-Path $env:APPDATA 'omegga\steam_installs\main\Brickadia\Binaries\Win64'
  ) 'ue4ss\main\Mods'
  $standardRuntimeModsFullPath = [System.IO.Path]::GetFullPath($standardRuntimeModsDir)
  $isSharedOmeggaRuntime = $runtimeModsFullPath.Equals(
    $standardRuntimeModsFullPath,
    [System.StringComparison]::OrdinalIgnoreCase
  )

  if ($isSharedOmeggaRuntime) {
    $conflicts = @(
      Get-CimInstance Win32_Process |
        Where-Object {
          $_.Name -eq 'BrickadiaServer-Win64-Shipping.exe' -and
          $_.CommandLine -notlike "*-port=*$Port*"
        }
    )
    if ($conflicts.Count -gt 0) {
      $ports = @(
        $conflicts |
          ForEach-Object {
            if ($_.CommandLine -match '-port=\\?"?([0-9]+)') { $Matches[1] } else { "pid:$($_.ProcessId)" }
          }
      )
      if ($AllowSharedRuntimeMutation) {
        throw (
          "Refusing to run shared-runtime validation while another Brickadia server is active " +
          "(ports/processes: $($ports -join ', ')). BMF runtime command files are shared across " +
          "those processes, so the live server can consume validation requests. Stop the live server first."
        )
      }
      throw (
        "Refusing to replace the shared Omegga BMF runtime while another Brickadia server is active " +
        "(ports/processes: $($ports -join ', ')). Stop the live server first or pass -AllowSharedRuntimeMutation."
      )
    }
  }
}

function Backup-RuntimeBmf {
  $caseRootFullPath = [System.IO.Path]::GetFullPath($caseRoot)
  $backupFullPath = [System.IO.Path]::GetFullPath($runtimeBackupDir)
  if (!$backupFullPath.StartsWith($caseRootFullPath, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to write runtime backup outside case root: $backupFullPath"
  }

  if (Test-Path -LiteralPath $runtimeBackupDir) {
    Remove-Item -LiteralPath $runtimeBackupDir -Recurse -Force
  }

  if (Test-Path -LiteralPath $runtimeBmfDir) {
    $script:runtimeHadExistingBmf = $true
    Copy-Item -LiteralPath $runtimeBmfDir -Destination $runtimeBackupDir -Recurse -Force
  } else {
    $script:runtimeHadExistingBmf = $false
  }
  $script:runtimeBackupReady = $true
}

function Restore-RuntimeBmf {
  if (!$script:runtimeBackupReady) {
    return
  }

  $runtimeBmfFullPath = [System.IO.Path]::GetFullPath($runtimeBmfDir)
  $runtimeModsFullPath = [System.IO.Path]::GetFullPath($RuntimeModsDir)
  if (!$runtimeBmfFullPath.StartsWith($runtimeModsFullPath, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to restore unexpected BMF runtime path: $runtimeBmfFullPath"
  }

  if (Test-Path -LiteralPath $runtimeBmfDir) {
    Remove-Item -LiteralPath $runtimeBmfDir -Recurse -Force
  }
  if ($script:runtimeHadExistingBmf) {
    Copy-Item -LiteralPath $runtimeBackupDir -Destination $runtimeBmfDir -Recurse -Force
  }
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
    $script:errors.Add("BMF worker did not report ok=true for command: $Command")
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

  Assert-SafeRuntimeMutation
  Backup-RuntimeBmf
  $validationStarted = $true

  if (Test-Path -LiteralPath $runtimeBmfDir) {
    Remove-Item -LiteralPath $runtimeBmfDir -Recurse -Force
  }
  New-Item -ItemType Directory -Force -Path $runtimeBmfDir | Out-Null
  Copy-Item -Path (Join-Path $sourceBmfDir '*') -Destination $runtimeBmfDir -Recurse -Force

  foreach ($path in @($runtimeLogPath, $runtimeStatusPath)) {
    if (Test-Path -LiteralPath $path) {
      Remove-Item -LiteralPath $path -Force
    }
  }

  $startOutput = & $startServerScript -RuntimeModsDir $RuntimeModsDir -BridgeDir $bridgeDir -Port $Port -VerifyWaitSeconds 30
  $startOutput | Set-Content -LiteralPath $startPath -Encoding UTF8
  $start = $startOutput | ConvertFrom-Json
  $serverPid = [int]$start.pid
  Add-Evidence 'json' $startPath 'Bridge test server startup result'
  if ($start.verified -ne $true) {
    $errors.Add("Bridge server did not verify: $($start.verify_reason)")
  } else {
    Start-Sleep -Seconds 4

    Invoke-BmfConsoleCommand 'bmf.minigames.list' 'bmf-minigames-list' @(
      'BMF bmf.minigames.list UNSAFE_MINIGAME_COMMAND_DISABLED',
      'command=Server.Minigames.List',
      'allowUnsafeMinigameConsoleCommands=false'
    )
    Invoke-BmfConsoleCommand 'bmf.minigames.objects.snapshot limit=4' 'bmf-minigames-objects-snapshot' @(
      'BMF bmf.minigames.objects.snapshot UNSAFE_MINIGAME_OBJECT_SNAPSHOT_DISABLED',
      'code=UNSAFE_MINIGAME_OBJECT_SNAPSHOT_DISABLED',
      'allowUnsafeMinigameObjectSnapshot=false'
    )
    Invoke-BmfConsoleCommand "bmf.minigames.loadpreset name=$presetName" 'bmf-minigames-loadpreset' @(
      'BMF bmf.minigames.loadpreset UNSAFE_MINIGAME_COMMAND_DISABLED',
      'action=loadPreset',
      "preset=$presetName",
      'code=UNSAFE_MINIGAME_COMMAND_DISABLED',
      "command=Server.Minigames.LoadPreset `"$presetName`"",
      'allowUnsafeMinigameConsoleCommands=false'
    )
    Invoke-BmfConsoleCommand "bmf.minigames.savepreset index=0 name=$presetName" 'bmf-minigames-savepreset' @(
      'BMF bmf.minigames.savepreset UNSAFE_MINIGAME_COMMAND_DISABLED',
      'action=savePreset',
      'index=0',
      "preset=$presetName",
      'code=UNSAFE_MINIGAME_COMMAND_DISABLED',
      "command=Server.Minigames.SavePreset 0 `"$presetName`"",
      'allowUnsafeMinigameConsoleCommands=false'
    )
    Invoke-BmfConsoleCommand 'bmf.minigames.definitions.status' 'bmf-minigames-definitions-status-before' @(
      'BMF bmf.minigames.definitions.status OK',
      'code=OK',
      'definitions=0',
      'teams=0',
      'last_error='
    )
    Invoke-BmfConsoleCommand 'bmf.minigames.definitions.set name=CityRPG index=0 teams=Police,Criminal persistent=true owneronly=false includedbrickmode=all maxplayers=16 source=validator' 'bmf-minigames-definitions-set' @(
      'BMF bmf.minigames.definitions.set OK',
      'code=OK',
      'key=name:CityRPG#0',
      'name=CityRPG',
      'index=0',
      'teams=2',
      'persistent=true',
      'owner_only=false',
      'included_brick_mode=all',
      'live_enforcement=definition-only',
      'updated=false',
      'definition_json='
    )
    Invoke-BmfConsoleCommand 'bmf.minigames.definitions.list' 'bmf-minigames-definitions-list' @(
      'BMF bmf.minigames.definitions.list OK',
      'code=OK',
      'definitions=1',
      'returned=1',
      'definition_1=name:CityRPG#0|name=CityRPG|index=0|teams=2|persistent=true',
      'definitions_json='
    )
    Invoke-BmfConsoleCommand 'bmf.minigames.definitions.get name=CityRPG index=0' 'bmf-minigames-definitions-get' @(
      'BMF bmf.minigames.definitions.get OK',
      'code=OK',
      'key=name:CityRPG#0',
      'name=CityRPG',
      'index=0',
      'teams=2',
      'persistent=true',
      'definition_json='
    )
    Invoke-BmfConsoleCommand 'bmf.minigames.definitions.delete name=CityRPG index=0' 'bmf-minigames-definitions-delete-confirm-required' @(
      'BMF bmf.minigames.definitions.delete CONFIRMATION_REQUIRED',
      'code=CONFIRMATION_REQUIRED',
      'confirm_required=DELETE_MINIGAME_DEFINITION',
      'deleted=false'
    )
    Invoke-BmfConsoleCommand 'bmf.minigames.definitions.delete name=CityRPG index=0 confirm=DELETE_MINIGAME_DEFINITION' 'bmf-minigames-definitions-delete' @(
      'BMF bmf.minigames.definitions.delete OK',
      'code=OK',
      'key=name:CityRPG#0',
      'deleted=true',
      'definition_json='
    )
    Invoke-BmfConsoleCommand 'bmf.minigames.definitions.status' 'bmf-minigames-definitions-status-after' @(
      'BMF bmf.minigames.definitions.status OK',
      'code=OK',
      'definitions=0',
      'teams=0',
      'last_error='
    )
    Invoke-BmfConsoleCommand 'bmf.minigames.nextround index=0' 'bmf-minigames-nextround' @(
      'BMF bmf.minigames.nextround UNSAFE_MINIGAME_COMMAND_DISABLED',
      'action=nextRound',
      'index=0',
      'code=UNSAFE_MINIGAME_COMMAND_DISABLED',
      'command=Server.Minigames.NextRound 0',
      'allowUnsafeMinigameConsoleCommands=false'
    )
    Invoke-BmfConsoleCommand 'bmf.minigames.reset index=0' 'bmf-minigames-reset' @(
      'BMF bmf.minigames.reset UNSAFE_MINIGAME_COMMAND_DISABLED',
      'action=reset',
      'index=0',
      'code=UNSAFE_MINIGAME_COMMAND_DISABLED',
      'command=Server.Minigames.Reset 0',
      'allowUnsafeMinigameConsoleCommands=false'
    )
    Invoke-BmfConsoleCommand 'bmf.minigames.delete index=0' 'bmf-minigames-delete' @(
      'BMF bmf.minigames.delete UNSAFE_MINIGAME_COMMAND_DISABLED',
      'action=delete',
      'index=0',
      'code=UNSAFE_MINIGAME_COMMAND_DISABLED',
      'command=Server.Minigames.Delete 0',
      'allowUnsafeMinigameConsoleCommands=false'
    )
    Invoke-BmfConsoleCommand 'bmf.minigames.loadpreset name=../Escape' 'bmf-minigames-loadpreset-invalid' @(
      'BMF bmf.minigames.loadpreset INVALID_PRESET_NAME',
      'action=loadPreset',
      'preset=../Escape',
      'code=INVALID_PRESET_NAME'
    )
    Invoke-BmfConsoleCommand 'bmf.minigames.reset index=abc' 'bmf-minigames-reset-invalid' @(
      'BMF bmf.minigames.reset INVALID_MINIGAME_INDEX',
      'action=reset',
      'index=abc',
      'code=INVALID_MINIGAME_INDEX'
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

if ($validationStarted -and (Test-Path -LiteralPath $runtimeLogPath)) {
  Copy-Item -LiteralPath $runtimeLogPath -Destination $bmfLogPath -Force
  Add-Evidence 'log' $bmfLogPath 'BMF runtime log with minigame command evidence'
  $logText = Get-Content -Raw -LiteralPath $bmfLogPath
  foreach ($needle in @(
    'registered console command bmf.minigames.list',
    'registered console command bmf.minigames.loadpreset',
    'registered console command bmf.minigames.savepreset',
    'registered console command bmf.minigames.nextround',
    'registered console command bmf.minigames.reset',
    'registered console command bmf.minigames.delete',
    'registered console command bmf.minigames.definitions.status',
    'registered console command bmf.minigames.definitions.set',
    'registered console command bmf.minigames.definitions.list',
    'registered console command bmf.minigames.definitions.get',
    'registered console command bmf.minigames.definitions.delete',
    'registered console command bmf.minigames.events.canary',
    'registered console command bmf.minigames.events.recent',
    'registered console command bmf.minigames.data.list',
    'registered console command bmf.minigames.data.snapshot',
    'registered console command bmf.minigames.data.get',
    'registered console command bmf.minigames.data.players',
    'registered console command bmf.minigames.data.teams',
    'registered console command bmf.minigames.data.leaderboard',
    'registered console command bmf.minigames.data.player',
    'registered console command bmf.minigames.data.playerstate',
    'registered console command bmf.minigames.data.membership',
    'registered console command bmf.minigames.data.clear',
    'registered console command bmf.minigames.objects.snapshot',
    'BMF bmf.minigames.loadpreset UNSAFE_MINIGAME_COMMAND_DISABLED',
    'BMF bmf.minigames.definitions.set OK',
    'BMF bmf.minigames.definitions.delete CONFIRMATION_REQUIRED',
    'BMF bmf.minigames.objects.snapshot UNSAFE_MINIGAME_OBJECT_SNAPSHOT_DISABLED',
    'BMF bmf.minigames.reset INVALID_MINIGAME_INDEX'
  )) {
    if ($logText -notmatch [regex]::Escape($needle)) {
      $errors.Add("BMF log missing expected line: $needle")
    }
  }
} elseif ($validationStarted) {
  $errors.Add("BMF runtime log was not written: $runtimeLogPath")
}

if ($validationStarted -and (Test-Path -LiteralPath $runtimeStatusPath)) {
  Copy-Item -LiteralPath $runtimeStatusPath -Destination $statusPath -Force
  Add-Evidence 'json' $statusPath 'BMF runtime status after minigame command canary'
  try {
    $status = Read-JsonFile $statusPath
    if ([int]$status.api_labels -lt 60) {
      $errors.Add("Expected at least 60 API labels after minigame lifecycle labels, got $($status.api_labels).")
    }
  } catch {
    $errors.Add("Could not parse BMF status: $($_.Exception.Message)")
  }
} elseif ($validationStarted) {
  $errors.Add("BMF runtime status was not written: $runtimeStatusPath")
}

try {
  Restore-RuntimeBmf
} catch {
  $errors.Add("Could not restore pre-validation BMF runtime: $($_.Exception.Message)")
}

$resultStatus = 'failed'
if ($errors.Count -eq 0) {
  $resultStatus = 'passed'
}

$result = [ordered]@{
  feature = 'bmf.minigames.lifecycle-commands'
  status = $resultStatus
  validationLevel = 'L2 Headless + L5 Negative'
  startedAt = $startedAt
  finishedAt = (Get-Date).ToUniversalTime().ToString('o')
  data = [ordered]@{
    brickadiaRoot = [System.IO.Path]::GetFullPath($BrickadiaRoot)
    runtimeModsDir = [System.IO.Path]::GetFullPath($RuntimeModsDir)
    port = $Port
    bridgeDir = [System.IO.Path]::GetFullPath($bridgeDir)
    presetName = $presetName
    commands = $commandResults.ToArray()
  }
  evidence = $evidence.ToArray()
  errors = $errors.ToArray()
}

$json = $result | ConvertTo-Json -Depth 12
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $outPath) | Out-Null
Set-Content -LiteralPath $outPath -Value $json -Encoding UTF8
Write-Output $json

if ($errors.Count -ne 0) {
  exit 1
}
