param(
  [string]$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
  [string]$BrickadiaRoot = '',
  [Parameter(Mandatory = $true)]
  [string]$BridgeDir,
  [string]$SaveName = '',
  [string]$OutJson = '',
  [int]$WaitAfterSaveSeconds = 8,
  [switch]$ExportInventory,
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
  $SaveName = 'BMF_ServerVehicleSnapshot_{0}' -f (Get-Date -Format 'yyyyMMddHHmmss')
}
if (!$OutJson) {
  $OutJson = Join-Path $Root 'artifacts/local/server-vehicle-snapshot.json'
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
$worldsDir = Join-Path $BrickadiaRoot 'omegga-master/omegga-master/data/Saved/Worlds'
$savedWorldPath = Join-Path $worldsDir ($SaveName + '.brdb')
$saveRpcPath = Join-Path $caseRoot 'saveas-rpc.json'
$snapshotPath = Join-Path $caseRoot 'vehicle-snapshot.json'
$parserPath = Join-Path $caseRoot 'vehicle-snapshot.entities.json'
$inventoryPath = Join-Path $caseRoot 'vehicle-inventory.json'
$inventoryMarkdownPath = Join-Path $caseRoot 'vehicle-inventory.md'
$inventoryCsvPath = Join-Path $caseRoot 'vehicle-inventory.csv'
$snapshot = $null
$inventory = $null

function Add-Evidence([string]$Kind, [string]$Path, [string]$Summary) {
  if ($Path -and (Test-Path -LiteralPath $Path)) {
    $script:evidence.Add([ordered]@{
      kind = $Kind
      path = [System.IO.Path]::GetFullPath($Path)
      summary = $Summary
    })
  }
}

try {
  $requiredPaths = @($BridgeDir, $sendRpcScript, $snapshotScript)
  if ($ExportInventory) {
    $requiredPaths += $inventoryScript
  }
  foreach ($path in $requiredPaths) {
    if (!(Test-Path -LiteralPath $path)) {
      throw "Required path does not exist: $path"
    }
  }

  $saveCommand = "Omegga.Bridge.ForceConsoleExecutor consolemanager BR.World.SaveAs $SaveName"
  $saveOutput = & node $sendRpcScript --dir $BridgeDir --method console.exec --command-raw $saveCommand --wait-ms 20000 --include-logs 1
  $saveOutput | Set-Content -LiteralPath $saveRpcPath -Encoding UTF8
  $saveRpc = $saveOutput | ConvertFrom-Json
  Add-Evidence 'json' $saveRpcPath 'SaveAs bridge RPC result for vehicle snapshot'
  if ($saveRpc.complete.success -ne $true) {
    $errors.Add('SaveAs RPC did not report success.')
  }

  Start-Sleep -Seconds $WaitAfterSaveSeconds

  if (!(Test-Path -LiteralPath $savedWorldPath)) {
    throw "Saved world was not created: $savedWorldPath"
  }
  Add-Evidence 'brdb' $savedWorldPath 'Saved world captured for vehicle snapshot'

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

  if ($ExportInventory) {
    $inventoryOutput = & $inventoryScript `
      -Root $Root `
      -BrickadiaRoot $BrickadiaRoot `
      -InputSnapshotJson $snapshotPath `
      -OutJson $inventoryPath `
      -OutMarkdown $inventoryMarkdownPath `
      -OutCsv $inventoryCsvPath `
      -LabelPrefix $InventoryLabelPrefix `
      -SpawnManifestJson $SpawnManifestJson `
      -SpawnMatchMode $SpawnMatchMode
    if ($LASTEXITCODE -ne 0) {
      throw "export-vehicle-inventory.ps1 failed with exit code $LASTEXITCODE"
    }
    $inventory = $inventoryOutput | ConvertFrom-Json
    Add-Evidence 'json' $inventoryPath 'Vehicle inventory JSON'
    Add-Evidence 'markdown' $inventoryMarkdownPath 'Vehicle inventory Markdown report'
    Add-Evidence 'csv' $inventoryCsvPath 'Vehicle inventory CSV report'
    if ($inventory.status -ne 'passed') {
      $errors.Add('Vehicle inventory export did not pass.')
    }
  }
} catch {
  $errors.Add($_.Exception.Message)
}

$result = [ordered]@{
  feature = 'server.vehicle-snapshot'
  status = if ($errors.Count -eq 0) { 'passed' } else { 'failed' }
  validationLevel = 'L2 Headless Server'
  startedAt = $startedAt
  finishedAt = (Get-Date).ToUniversalTime().ToString('o')
  data = [ordered]@{
    bridgeDir = [System.IO.Path]::GetFullPath($BridgeDir)
    saveName = $SaveName
    savedWorldPath = [System.IO.Path]::GetFullPath($savedWorldPath)
    snapshot = if ($snapshot) { $snapshot.data } else { $null }
    inventory = if ($inventory) { $inventory.data } else { $null }
  }
  evidence = $evidence
  errors = @($errors)
}

$json = $result | ConvertTo-Json -Depth 16
Set-Content -LiteralPath $outPath -Value $json -Encoding UTF8
Write-Output $json

if ($errors.Count -ne 0) {
  exit 1
}
