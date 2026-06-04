param(
  [string]$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
  [string]$BrickadiaRoot = '',
  [string]$RuntimeModsDir = 'C:\Users\tycox\AppData\Roaming\omegga\steam_installs\main\Brickadia\Binaries\Win64\ue4ss\main\Mods',
  [string]$OutJson = '',
  [int]$Port = 7844
)

$ErrorActionPreference = 'Stop'

if (!$BrickadiaRoot) {
  $BrickadiaRoot = (Resolve-Path (Join-Path $Root '..\Brickadia')).Path
}
if (!$OutJson) {
  $OutJson = Join-Path $Root 'artifacts/local/bmf-rate-limits-canary.json'
}

$errors = New-Object System.Collections.Generic.List[string]
$evidence = New-Object System.Collections.Generic.List[object]
$commandResults = New-Object System.Collections.Generic.List[object]
$startedAt = (Get-Date).ToUniversalTime().ToString('o')
$outPath = [System.IO.Path]::GetFullPath($OutJson)
$artifactRoot = Split-Path -Parent $outPath
$caseRoot = Join-Path $artifactRoot 'bmf-rate-limits'
New-Item -ItemType Directory -Force -Path $caseRoot | Out-Null

$startServerScript = Join-Path $BrickadiaRoot 'brickadia-ue4ss-re/scripts/start-bridge-test-server.ps1'
$sendRpcScript = Join-Path $BrickadiaRoot 'brickadia-ue4ss-re/scripts/send-bridge-rpc.js'
$sourceBmfDir = Join-Path $Root 'framework/ue4ss/Mods/BMF'
$runtimeBmfDir = Join-Path $RuntimeModsDir 'BMF'
$runtimePluginDir = Join-Path $runtimeBmfDir 'plugins/RateLimitCanary'
$runtimeLogPath = Join-Path $runtimeBmfDir 'runtime/bmf.log'
$runtimeAuditPath = Join-Path $runtimeBmfDir 'runtime/audit.jsonl'
$runtimePluginLogPath = Join-Path $runtimeBmfDir 'runtime/logs/plugins/RateLimitCanary.log'
$runtimeStatusPath = Join-Path $runtimeBmfDir 'runtime/status.json'
$bridgeDir = Join-Path $caseRoot "bridge-$Port"
$startPath = Join-Path $caseRoot 'server-start.json'
$pluginStagePath = Join-Path $caseRoot 'rate-limit-plugin-stage.json'
$bmfLogPath = Join-Path $caseRoot 'bmf.log'
$auditLogPath = Join-Path $caseRoot 'audit.jsonl'
$auditParsedPath = Join-Path $caseRoot 'audit-parsed.json'
$pluginLogPath = Join-Path $caseRoot 'RateLimitCanary.log'
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
  "name": "RateLimitCanary",
  "version": "1.0.0",
  "author": "BMF",
  "description": "Temporary BMF rate limit canary plugin.",
  "capabilities": ["plugins.lifecycle", "chat.whisper"]
}
'@
  Set-Content -LiteralPath (Join-Path $runtimePluginDir 'bmf.json') -Value $manifestSource -Encoding UTF8

  $pluginSource = @'
return {
  name = "RateLimitCanary",
  onLoad = function(BMF)
    BMF.commands.register("bmf.ratelimits.canary", "Rate limit canary.", function()
      local first = BMF.rateLimits.check("canary.custom", { limit = 1, windowSeconds = 60 })
      local second = BMF.rateLimits.check("canary.custom", { limit = 1, windowSeconds = 60 })
      local whisper_limited_index = 0
      local whisper_limited_code = ""
      for index = 1, 25 do
        local response = BMF.chat.whisper("MissingPlayer", "rate limit probe")
        if response.code == "RATE_LIMITED" then
          whisper_limited_index = index
          whisper_limited_code = response.code
          break
        end
      end
      local buckets = BMF.rateLimits.recent()
      BMF.logInfo("RateLimitCanary handled", {
        custom = second.code,
        whisper = whisper_limited_code,
      })
      return BMF.result(true, "OK", "Rate limit canary handled", {
        lines = {
          "custom_first_ok=" .. tostring(first.ok),
          "custom_second_ok=" .. tostring(second.ok),
          "custom_second_code=" .. tostring(second.code),
          "custom_subject=" .. tostring(second.data and second.data.subject or ""),
          "whisper_limited_index=" .. tostring(whisper_limited_index),
          "whisper_limited_code=" .. tostring(whisper_limited_code),
          "bucket_count=" .. tostring((buckets.data and buckets.data.buckets and #buckets.data.buckets) or 0),
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
    command = 'bmf.ratelimits.canary'
  } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $pluginStagePath -Encoding UTF8
  Add-Evidence 'json' $pluginStagePath 'Temporary RateLimitCanary plugin staging result'

  foreach ($path in @($runtimeLogPath, $runtimeStatusPath, $runtimeAuditPath)) {
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

    Invoke-BmfConsoleCommand 'bmf.ratelimits.canary' 'bmf-ratelimits-canary' @(
      'BMF bmf.ratelimits.canary OK',
      'custom_first_ok=true',
      'custom_second_ok=false',
      'custom_second_code=RATE_LIMITED',
      'custom_subject=plugin:RateLimitCanary',
      'whisper_limited_index=21',
      'whisper_limited_code=RATE_LIMITED'
    )

    Invoke-BmfConsoleCommand 'bmf.ratelimits' 'bmf-ratelimits' @(
      'BMF bmf.ratelimits OK',
      'bucket_count=',
      'canary.custom|subject=plugin:RateLimitCanary|count=1',
      'chat.whisper|subject=plugin:RateLimitCanary|count=20'
    )

    Invoke-BmfConsoleCommand 'bmf.audit.tail limit=50' 'bmf-audit-tail' @(
      'BMF bmf.audit.tail OK',
      'rate_limit.denied|severity=warn|source=plugin|code=RATE_LIMITED|plugin=RateLimitCanary'
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
  Add-Evidence 'log' $bmfLogPath 'BMF runtime log with rate limit evidence'
  $logText = Get-Content -Raw -LiteralPath $bmfLogPath
  foreach ($needle in @(
    'registered console command bmf.ratelimits',
    'RateLimitCanary handled',
    'BMF bmf.ratelimits.canary OK',
    'BMF bmf.ratelimits OK'
  )) {
    if ($logText -notmatch [regex]::Escape($needle)) {
      $errors.Add("BMF log missing expected line: $needle")
    }
  }
} else {
  $errors.Add("BMF runtime log was not written: $runtimeLogPath")
}

if (Test-Path -LiteralPath $runtimeAuditPath) {
  Copy-Item -LiteralPath $runtimeAuditPath -Destination $auditLogPath -Force
  Add-Evidence 'jsonl' $auditLogPath 'BMF audit JSONL with rate-limit evidence'
  $records = New-Object System.Collections.Generic.List[object]
  foreach ($line in [System.IO.File]::ReadAllLines($auditLogPath)) {
    if ($line.Trim() -eq '') {
      continue
    }
    try {
      $records.Add(($line | ConvertFrom-Json))
    } catch {
      $errors.Add("Invalid audit JSONL line: $line")
    }
  }
  $records.ToArray() | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $auditParsedPath -Encoding UTF8
  Add-Evidence 'json' $auditParsedPath 'Parsed audit records from audit.jsonl'

  $rateDenied = @($records | Where-Object { $_.action -eq 'rate_limit.denied' -and $_.code -eq 'RATE_LIMITED' })
  if ($rateDenied.Count -lt 2) {
    $errors.Add("Expected at least two rate_limit.denied audit records, got $($rateDenied.Count).")
  }
} else {
  $errors.Add("BMF audit log was not written: $runtimeAuditPath")
}

if (Test-Path -LiteralPath $runtimePluginLogPath) {
  Copy-Item -LiteralPath $runtimePluginLogPath -Destination $pluginLogPath -Force
  Add-Evidence 'log' $pluginLogPath 'RateLimitCanary per-plugin log'
} else {
  $errors.Add("Plugin log was not written: $runtimePluginLogPath")
}

if (Test-Path -LiteralPath $runtimeStatusPath) {
  Copy-Item -LiteralPath $runtimeStatusPath -Destination $statusPath -Force
  Add-Evidence 'json' $statusPath 'BMF runtime status after rate limit canary'
  try {
    $status = Read-JsonFile $statusPath
    if ([int]$status.rate_limit_buckets -lt 2) {
      $errors.Add("Expected at least two rate limit buckets, got $($status.rate_limit_buckets).")
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
  feature = 'bmf.rate-limits'
  status = $resultStatus
  validationLevel = 'L2 Headless + L5 Negative'
  startedAt = $startedAt
  finishedAt = (Get-Date).ToUniversalTime().ToString('o')
  data = [ordered]@{
    brickadiaRoot = [System.IO.Path]::GetFullPath($BrickadiaRoot)
    runtimeModsDir = [System.IO.Path]::GetFullPath($RuntimeModsDir)
    port = $Port
    bridgeDir = [System.IO.Path]::GetFullPath($bridgeDir)
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
