param(
  [string]$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
  [string]$BrickadiaRoot = '',
  [string]$InputBrz = '',
  [string]$OutputBrdb = '',
  [string]$OutJson = '',
  [string]$Environment = 'Plate',
  [ValidateSet('World', 'Prefab', 'preserve')]
  [string]$BundleType = 'World',
  [double[]]$PlacementOffset = @(),
  [int[]]$EntityChunkOffset = @(),
  [switch]$PatchPhysicsMetadata,
  [switch]$StageToServerWorlds,
  [string]$WorldName = '',
  [switch]$Force
)

$ErrorActionPreference = 'Stop'

if (!$BrickadiaRoot) {
  $BrickadiaRoot = (Resolve-Path (Join-Path $Root '..\Brickadia')).Path
}
if (!$InputBrz) {
  $InputBrz = Join-Path $BrickadiaRoot 'Car.brz'
}

$inputFullPath = [System.IO.Path]::GetFullPath($InputBrz)
$safeName = [System.IO.Path]::GetFileNameWithoutExtension($inputFullPath)
$safeName = $safeName -replace '[^A-Za-z0-9_.-]', '_'
if (!$OutputBrdb) {
  $OutputBrdb = Join-Path $Root "artifacts/local/brz-prefabs/$safeName.world.brdb"
}
$outputFullPath = [System.IO.Path]::GetFullPath($OutputBrdb)
if (!$OutJson) {
  $OutJson = [System.IO.Path]::ChangeExtension($outputFullPath, '.stage.json')
}
$outPath = [System.IO.Path]::GetFullPath($OutJson)
$caseRoot = Split-Path -Parent $outPath

$diagnoseScript = Join-Path $BrickadiaRoot 'brickadia-ue4ss-re/scripts/diagnose-prefab-vehicle-structure.js'
$hashScript = Join-Path $BrickadiaRoot 'brickadia-ue4ss-re/scripts/prefab-hash-report.js'
$buildScript = Join-Path $BrickadiaRoot 'brickadia-ue4ss-re/scripts/build-prefab-world-brdb.js'
$describeScript = Join-Path $Root 'scripts/describe-world-archive.ps1'
$worldsDir = Join-Path $BrickadiaRoot 'omegga-master/omegga-master/data/Saved/Worlds'

$diagnosePath = Join-Path $caseRoot "$safeName.diagnose.json"
$hashPath = Join-Path $caseRoot "$safeName.hash-report.json"
$describePath = Join-Path $caseRoot "$safeName.staged-describe.json"
$entitiesPath = Join-Path $caseRoot "$safeName.staged-entities.json"

$errors = New-Object System.Collections.Generic.List[string]
$evidence = New-Object System.Collections.Generic.List[object]
$startedAt = (Get-Date).ToUniversalTime().ToString('o')
$diagnose = $null
$hashReport = $null
$describe = $null
$stagedWorldPath = $null

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

function Invoke-NodeJsonTool([object[]]$Arguments, [string]$ToolName) {
  $null = & node @Arguments
  if ($LASTEXITCODE -ne 0) {
    throw "$ToolName failed with exit code $LASTEXITCODE"
  }
}

try {
  New-Item -ItemType Directory -Force -Path $caseRoot | Out-Null
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $outputFullPath) | Out-Null

  foreach ($path in @($inputFullPath, $diagnoseScript, $hashScript, $buildScript, $describeScript)) {
    if (!(Test-Path -LiteralPath $path)) {
      throw "Required path does not exist: $path"
    }
  }
  if ((Test-Path -LiteralPath $outputFullPath) -and !$Force) {
    throw "Refusing to overwrite existing output BRDB without -Force: $outputFullPath"
  }
  if ($PlacementOffset.Count -ne 0 -and $PlacementOffset.Count -ne 3) {
    throw '-PlacementOffset must contain exactly three numbers when supplied.'
  }
  if ($EntityChunkOffset.Count -ne 0 -and $EntityChunkOffset.Count -ne 3) {
    throw '-EntityChunkOffset must contain exactly three integers when supplied.'
  }

  Invoke-NodeJsonTool @($diagnoseScript, $inputFullPath, '--out-json', $diagnosePath) 'diagnose-prefab-vehicle-structure.js'
  $diagnose = Read-JsonFile $diagnosePath
  Add-Evidence 'json' $diagnosePath 'Source BRZ dynamic-entity diagnosis'

  Invoke-NodeJsonTool @($hashScript, $inputFullPath, '--out-json', $hashPath) 'prefab-hash-report.js'
  $hashReport = Read-JsonFile $hashPath
  Add-Evidence 'json' $hashPath 'Source BRZ hash and summary report'

  $buildArgs = @($buildScript, $inputFullPath, $outputFullPath, $Environment, '--bundle-type', $BundleType)
  if ($PlacementOffset.Count -eq 3) {
    $buildArgs += @('--placement-offset', [string]$PlacementOffset[0], [string]$PlacementOffset[1], [string]$PlacementOffset[2])
  }
  if ($EntityChunkOffset.Count -eq 3) {
    $buildArgs += @('--entity-chunk-offset', [string]$EntityChunkOffset[0], [string]$EntityChunkOffset[1], [string]$EntityChunkOffset[2])
  }
  if ($PatchPhysicsMetadata) {
    $buildArgs += '--patch-physics-metadata'
  }
  Invoke-NodeJsonTool $buildArgs 'build-prefab-world-brdb.js'
  Add-Evidence 'brdb' $outputFullPath 'Staged world BRDB converted from BRZ'

  $describeOutput = & $describeScript -InputPath $outputFullPath -OutJson $describePath -ParserOutJson $entitiesPath
  if ($LASTEXITCODE -ne 0) {
    throw "describe-world-archive.ps1 failed with exit code $LASTEXITCODE"
  }
  $describe = $describeOutput | ConvertFrom-Json
  Add-Evidence 'json' $describePath 'Staged BRDB archive summary'
  Add-Evidence 'json' $entitiesPath 'Staged BRDB parser output'

  if ($StageToServerWorlds) {
    if (!$WorldName) {
      $WorldName = "BMF_${safeName}_PrefabWorld"
    }
    New-Item -ItemType Directory -Force -Path $worldsDir | Out-Null
    $stagedWorldPath = Join-Path $worldsDir ($WorldName + '.brdb')
    if ((Test-Path -LiteralPath $stagedWorldPath) -and !$Force) {
      throw "Refusing to overwrite staged server world without -Force: $stagedWorldPath"
    }
    Copy-Item -LiteralPath $outputFullPath -Destination $stagedWorldPath -Force
    Add-Evidence 'brdb' $stagedWorldPath 'BRDB copied into Brickadia Saved/Worlds for LoadAdditive'
  }
} catch {
  $errors.Add($_.Exception.Message)
}

$warnings = New-Object System.Collections.Generic.List[string]
foreach ($warning in @($diagnose.warnings)) {
  if ($warning) {
    $warnings.Add([string]$warning)
  }
}
if ($PatchPhysicsMetadata) {
  $warnings.Add('PatchPhysicsMetadata is diagnostic-only; local L2 probes can crash Brickadia at TVariant.h:148 when loading dynamic prefab metadata.')
}

$prefab = $null
if ($hashReport) {
  $prefab = @($hashReport.prefabs | Select-Object -First 1)
}

$result = [ordered]@{
  feature = 'archives.brz-prefab-stage.static'
  status = if ($errors.Count -eq 0) { 'passed' } else { 'failed' }
  validationLevel = 'L0 Static'
  startedAt = $startedAt
  finishedAt = (Get-Date).ToUniversalTime().ToString('o')
  data = [ordered]@{
    root = [System.IO.Path]::GetFullPath($Root)
    brickadiaRoot = [System.IO.Path]::GetFullPath($BrickadiaRoot)
    inputBrz = $inputFullPath
    outputBrdb = $outputFullPath
    outputBytes = if (Test-Path -LiteralPath $outputFullPath) { (Get-Item -LiteralPath $outputFullPath).Length } else { 0 }
    environment = $Environment
    bundleType = $BundleType
    patchPhysicsMetadata = [bool]$PatchPhysicsMetadata
    placementOffset = if ($PlacementOffset.Count -eq 3) { @($PlacementOffset) } else { $null }
    entityChunkOffset = if ($EntityChunkOffset.Count -eq 3) { @($EntityChunkOffset) } else { $null }
    stagedWorldName = if ($StageToServerWorlds) { $WorldName } else { $null }
    stagedWorldPath = if ($stagedWorldPath) { [System.IO.Path]::GetFullPath($stagedWorldPath) } else { $null }
    source = if ($prefab) {
      [ordered]@{
        name = $prefab.name
        bytes = $prefab.bytes
        brPrefabHashCandidate = $prefab.brPrefabHashCandidate
        rawSha256 = $prefab.supportingHashes.rawSha256
        bIsPhysicsGrid = $prefab.summary.bIsPhysicsGrid
        brickCount = $prefab.summary.brickCount
        componentCount = $prefab.summary.componentCount
        entityCount = $prefab.summary.entityCount
        wireCount = $prefab.summary.wireCount
        entityTypes = @($prefab.summary.entityTypes)
        jointEntityReferences = $prefab.summary.jointEntityReferences
      }
    } else { $null }
    stagedArchive = if ($describe) { $describe.data } else { $null }
    warnings = @($warnings)
  }
  evidence = $evidence
  errors = @($errors)
}

$json = $result | ConvertTo-Json -Depth 14
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $outPath) | Out-Null
Set-Content -LiteralPath $outPath -Value $json -Encoding UTF8
Write-Output $json

if ($errors.Count -ne 0) {
  exit 1
}
