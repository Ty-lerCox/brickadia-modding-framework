param(
  [string]$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
  [string]$BrickadiaRoot = '',
  [string]$RuntimeModsDir = 'C:\Users\tycox\AppData\Roaming\omegga\steam_installs\main\Brickadia\Binaries\Win64\ue4ss\main\Mods',
  [Parameter(Mandatory = $true)]
  [string]$BridgeDir,
  [string]$SaveName = '',
  [string]$OutJson = '',
  [int]$WaitAfterSaveSeconds = 8,
  [string]$InventoryLabelPrefix = 'vehicle',
  [string]$SpawnManifestJson = '',
  [ValidateSet('X', 'XY', 'XYZ')]
  [string]$SpawnMatchMode = 'X'
)

$ErrorActionPreference = 'Stop'

if (!$BrickadiaRoot) {
  $BrickadiaRoot = (Resolve-Path (Join-Path $Root '..\Brickadia')).Path
}
if (!$SaveName) {
  $SaveName = 'BMF_VehicleSnapshot_{0}' -f (Get-Date -Format 'yyyyMMddHHmmss')
}
if (!$OutJson) {
  $OutJson = Join-Path $Root 'artifacts/local/bmf-vehicle-snapshot.json'
}

$errors = New-Object System.Collections.Generic.List[string]
$evidence = New-Object System.Collections.Generic.List[object]
$startedAt = (Get-Date).ToUniversalTime().ToString('o')
$outPath = [System.IO.Path]::GetFullPath($OutJson)
$caseRoot = Split-Path -Parent $outPath
New-Item -ItemType Directory -Force -Path $caseRoot | Out-Null

$sendRpcScript = Join-Path $BrickadiaRoot 'brickadia-ue4ss-re/scripts/send-bridge-rpc.js'
$snapshotScript = Join-Path $Root 'scripts/summarize-vehicle-graphs.ps1'
$inventoryScript = Join-Path $Root 'scripts/export-vehicle-inventory.ps1'
$runtimeBmfDir = Join-Path $RuntimeModsDir 'BMF'
$worldsDir = Join-Path $BrickadiaRoot 'omegga-master/omegga-master/data/Saved/Worlds'
$savedWorldPath = Join-Path $worldsDir ($SaveName + '.brdb')
$rpcPath = Join-Path $caseRoot 'bmf-vehicles-snapshot-rpc.json'
$responseArtifactPath = Join-Path $caseRoot 'bmf-vehicles-snapshot-response.txt'
$snapshotPath = Join-Path $caseRoot 'vehicle-snapshot.json'
$parserPath = Join-Path $caseRoot 'vehicle-snapshot.entities.json'
$inventoryPath = Join-Path $caseRoot 'vehicle-inventory.json'
$inventoryMarkdownPath = Join-Path $caseRoot 'vehicle-inventory.md'
$inventoryCsvPath = Join-Path $caseRoot 'vehicle-inventory.csv'
$inventoryTextPath = Join-Path $caseRoot 'vehicle-inventory.txt'
$snapshot = $null
$inventory = $null
$commandRecord = $null

function Add-Evidence([string]$Kind, [string]$Path, [string]$Summary) {
  if ($Path -and (Test-Path -LiteralPath $Path)) {
    $script:evidence.Add([ordered]@{
      kind = $Kind
      path = [System.IO.Path]::GetFullPath($Path)
      summary = $Summary
    })
  }
}

function Wait-ForSavedWorldArchive([string]$Path, [int]$InitialWaitSeconds, [int]$TimeoutSeconds) {
  if ($InitialWaitSeconds -gt 0) {
    Start-Sleep -Seconds $InitialWaitSeconds
  }

  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  $lastLength = -1L
  $stableSamples = 0
  while ((Get-Date) -lt $deadline) {
    if (Test-Path -LiteralPath $Path) {
      $item = Get-Item -LiteralPath $Path
      if ($item.Length -gt 0) {
        if ($item.Length -eq $lastLength) {
          $stableSamples += 1
        } else {
          $lastLength = $item.Length
          $stableSamples = 0
        }
        if ($stableSamples -ge 2) {
          return $item
        }
      }
    }
    Start-Sleep -Milliseconds 500
  }

  if (!(Test-Path -LiteralPath $Path)) {
    throw "Saved world was not created: $Path"
  }
  $finalItem = Get-Item -LiteralPath $Path
  throw "Saved world was not ready before timeout: $Path length=$($finalItem.Length)"
}

try {
  foreach ($path in @($BridgeDir, $sendRpcScript, $snapshotScript, $inventoryScript, $runtimeBmfDir)) {
    if (!(Test-Path -LiteralPath $path)) {
      throw "Required path does not exist: $path"
    }
  }

  $bmfCommand = "bmf.vehicles.snapshot name=$SaveName"
  $bridgeCommand = "Omegga.Bridge.BMF $bmfCommand"
  $output = & node $sendRpcScript --dir $BridgeDir --method console.exec --command-raw $bridgeCommand --wait-ms 25000 --include-logs 1
  $output | Set-Content -LiteralPath $rpcPath -Encoding UTF8
  Add-Evidence 'json' $rpcPath 'Bridge RPC output for bmf.vehicles.snapshot'

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
      Add-Evidence 'text' $responseArtifactPath 'BMF response output for bmf.vehicles.snapshot'
      $responseLines = @([System.IO.File]::ReadAllLines($responseArtifactPath))
    } else {
      $errors.Add('Timed out waiting for BMF vehicle snapshot response file.')
    }
  } else {
    $errors.Add('Bridge response did not include queued BMF request id.')
  }

  $responseFullPath = ''
  if ($responsePath) {
    $responseFullPath = [System.IO.Path]::GetFullPath($responsePath)
  }
  $commandRecord = [ordered]@{
    command = $bmfCommand
    bridgeCommand = $bridgeCommand
    rpcPath = [System.IO.Path]::GetFullPath($rpcPath)
    responsePath = $responseFullPath
    success = [bool]$rpc.complete.success
    accepted = [bool]$rpc.result.accepted
    rpcLineCount = $lines.Count
    responseLineCount = $responseLines.Count
    lines = @($responseLines)
  }

  if ($rpc.complete.success -ne $true) {
    $errors.Add('BMF vehicle snapshot command did not complete successfully.')
  }
  if ($rpc.result.accepted -ne $true) {
    $errors.Add('BMF vehicle snapshot command was not accepted by the bridge.')
  }
  $joined = ($responseLines -join "`n")
  foreach ($expected in @('ok=true', 'BMF bmf.vehicles.snapshot OK', "world=$SaveName", 'next=summarize-vehicle-graphs', 'inventory=export-vehicle-inventory')) {
    if ($joined -notmatch [regex]::Escape($expected)) {
      $errors.Add("BMF vehicle snapshot response missing expected text: $expected")
    }
  }

  $null = Wait-ForSavedWorldArchive -Path $savedWorldPath -InitialWaitSeconds $WaitAfterSaveSeconds -TimeoutSeconds 45
  Add-Evidence 'brdb' $savedWorldPath 'Saved world captured through BMF vehicle snapshot command'

  $snapshotOutput = & $snapshotScript -InputPath $savedWorldPath -OutJson $snapshotPath -ParserOutJson $parserPath
  if ($LASTEXITCODE -ne 0) {
    throw "summarize-vehicle-graphs.ps1 failed with exit code $LASTEXITCODE"
  }
  $snapshot = $snapshotOutput | ConvertFrom-Json
  Add-Evidence 'json' $snapshotPath 'Vehicle-like dynamic actor snapshot'
  Add-Evidence 'json' $parserPath 'Raw parser output for vehicle snapshot'
  if ($snapshot.status -ne 'passed') {
    $errors.Add('Vehicle snapshot did not pass.')
  }

  $inventoryOutput = & $inventoryScript `
    -Root $Root `
    -BrickadiaRoot $BrickadiaRoot `
    -InputSnapshotJson $snapshotPath `
    -OutJson $inventoryPath `
    -OutMarkdown $inventoryMarkdownPath `
    -OutCsv $inventoryCsvPath `
    -OutText $inventoryTextPath `
    -LabelPrefix $InventoryLabelPrefix `
    -SpawnManifestJson $SpawnManifestJson `
    -SpawnMatchMode $SpawnMatchMode
  if ($LASTEXITCODE -ne 0) {
    throw "export-vehicle-inventory.ps1 failed with exit code $LASTEXITCODE"
  }
  $inventory = $inventoryOutput | ConvertFrom-Json
  Add-Evidence 'json' $inventoryPath 'Vehicle inventory JSON from BMF snapshot'
  Add-Evidence 'markdown' $inventoryMarkdownPath 'Vehicle inventory Markdown from BMF snapshot'
  Add-Evidence 'csv' $inventoryCsvPath 'Vehicle inventory CSV from BMF snapshot'
  Add-Evidence 'text' $inventoryTextPath 'Vehicle inventory console-style text report from BMF snapshot'
  if ($inventory.status -ne 'passed') {
    $errors.Add('Vehicle inventory export did not pass.')
  }
} catch {
  $errors.Add($_.Exception.Message)
}

$resultStatus = 'failed'
if ($errors.Count -eq 0) {
  $resultStatus = 'passed'
}

$snapshotData = $null
$inventoryData = $null
if ($snapshot) {
  $snapshotData = $snapshot.data
}
if ($inventory) {
  $inventoryData = $inventory.data
}

$result = [ordered]@{
  feature = 'bmf.vehicles.snapshot.command'
  status = $resultStatus
  validationLevel = 'L2 Headless Server'
  startedAt = $startedAt
  finishedAt = (Get-Date).ToUniversalTime().ToString('o')
  data = [ordered]@{
    bridgeDir = [System.IO.Path]::GetFullPath($BridgeDir)
    saveName = $SaveName
    savedWorldPath = [System.IO.Path]::GetFullPath($savedWorldPath)
    command = $commandRecord
    snapshot = $snapshotData
    inventory = $inventoryData
  }
  evidence = $evidence.ToArray()
  errors = $errors.ToArray()
}

$json = $result | ConvertTo-Json -Depth 16
Set-Content -LiteralPath $outPath -Value $json -Encoding UTF8
Write-Output $json

if ($errors.Count -ne 0) {
  exit 1
}
