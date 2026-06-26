param(
  [string]$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
  [string]$OutJson = ''
)

$ErrorActionPreference = 'Stop'

if (!$OutJson) {
  $OutJson = Join-Path $Root 'artifacts/local/bmf-omegga-adapters-validation.json'
}

$errors = New-Object System.Collections.Generic.List[string]
$evidence = New-Object System.Collections.Generic.List[object]
$startedAt = (Get-Date).ToUniversalTime().ToString('o')

function Add-Evidence([string]$Kind, [string]$Path, [string]$Summary) {
  if ($Path -and (Test-Path -LiteralPath $Path)) {
    $script:evidence.Add([ordered]@{
      kind = $Kind
      path = [System.IO.Path]::GetFullPath($Path)
      summary = $Summary
    })
  }
}

function Test-AdapterPackage(
  [string]$Name,
  [string]$RelativeRoot,
  [string[]]$SourceMarkers,
  [string[]]$ReadmeMarkers
) {
  $adapterRoot = Join-Path $Root $RelativeRoot
  foreach ($relative in @(
    'plugin.json',
    'doc.json',
    'access.json',
    'README.md',
    'omegga.plugin.js',
    'omegga.plugin.test.js'
  )) {
    $path = Join-Path $adapterRoot $relative
    if (!(Test-Path -LiteralPath $path)) {
      $script:errors.Add("Missing $Name adapter file: $RelativeRoot/$relative")
      continue
    }
    Add-Evidence 'file' $path "$Name adapter $relative"
  }

  foreach ($relative in @('plugin.json', 'doc.json', 'access.json')) {
    $path = Join-Path $adapterRoot $relative
    if (Test-Path -LiteralPath $path) {
      try {
        Get-Content -Raw -LiteralPath $path | ConvertFrom-Json | Out-Null
      } catch {
        $script:errors.Add("Invalid JSON in ${RelativeRoot}/${relative}: $($_.Exception.Message)")
      }
    }
  }

  $sourcePath = Join-Path $adapterRoot 'omegga.plugin.js'
  if (Test-Path -LiteralPath $sourcePath) {
    $source = Get-Content -Raw -LiteralPath $sourcePath
    foreach ($needle in $SourceMarkers) {
      if ($source -notmatch [regex]::Escape($needle)) {
        $script:errors.Add("$Name adapter source does not contain expected marker: $needle")
      }
    }
  }

  $readmePath = Join-Path $adapterRoot 'README.md'
  if (Test-Path -LiteralPath $readmePath) {
    $readme = Get-Content -Raw -LiteralPath $readmePath
    foreach ($needle in $ReadmeMarkers) {
      if ($readme -notmatch [regex]::Escape($needle)) {
        $script:errors.Add("$Name adapter README does not contain expected marker: $needle")
      }
    }
  }

  $testPath = Join-Path $adapterRoot 'omegga.plugin.test.js'
  if (Test-Path -LiteralPath $testPath) {
    $testOutput = & node --test $testPath 2>&1
    $exitCode = $LASTEXITCODE
    Add-Evidence 'test' $testPath "$Name adapter Node test suite"
    if ($exitCode -ne 0) {
      $script:errors.Add("$Name adapter Node tests failed.")
      foreach ($line in @($testOutput)) {
        $script:errors.Add([string]$line)
      }
    }
  }
}

try {
  Test-AdapterPackage `
    -Name 'BMF player sync' `
    -RelativeRoot 'packages/omegga-plugins/bmf-player-sync' `
    -SourceMarkers @(
      'class BmfPlayerSync',
      'OMEGGA_BMF_RUNTIME_DIR',
      'OMEGGA_BMF_PLAYER_CACHE_PATH',
      'bridgePluginName',
      'invokeBmfCommand',
      'bmf.players.sync',
      'bmf.interact.console',
      'parseBrickadiaLogPlayers',
      'syncIntervalMs'
    ) `
    -ReadmeMarkers @(
      'safe Omegga player identity records',
      'packages/omegga-plugins/bmf-player-sync',
      'OMEGGA_BMF_RUNTIME_DIR',
      'authenticated loopback socket',
      'bmf.players.sync',
      'InteractConsolePrefixGuard'
    )

  Test-AdapterPackage `
    -Name 'BMF minigame events' `
    -RelativeRoot 'packages/omegga-plugins/bmf-minigame-events' `
    -SourceMarkers @(
      'class BmfMinigameEvents',
      'allowUnsafeConsoleSnapshots',
      'bridgePluginName',
      'eventTransport=socket',
      'invokeBmfCommand',
      'bmf.minigames.events.emit',
      'bmf.minigames.data.apply-snapshot',
      'seedCacheFromBmfData',
      'adapterEventQueuedAtMs'
    ) `
    -ReadmeMarkers @(
      'Safe by default',
      'allowUnsafeConsoleSnapshots=true',
      '/bmfminigamestatus',
      'through that socket bridge',
      'packages/omegga-plugins/bmf-minigame-events'
    )
} catch {
  $errors.Add($_.Exception.Message)
}

$result = [ordered]@{
  feature = 'omegga.bmf-adapters'
  status = if ($errors.Count -eq 0) { 'passed' } else { 'failed' }
  validationLevel = 'L0 Static'
  startedAt = $startedAt
  finishedAt = (Get-Date).ToUniversalTime().ToString('o')
  data = [ordered]@{
    adapterRoots = @(
      [System.IO.Path]::GetFullPath((Join-Path $Root 'packages/omegga-plugins/bmf-player-sync')),
      [System.IO.Path]::GetFullPath((Join-Path $Root 'packages/omegga-plugins/bmf-minigame-events'))
    )
  }
  evidence = $evidence.ToArray()
  errors = $errors.ToArray()
}

$json = $result | ConvertTo-Json -Depth 10
$outPath = [System.IO.Path]::GetFullPath($OutJson)
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $outPath) | Out-Null
Set-Content -LiteralPath $outPath -Value $json -Encoding UTF8
Write-Output $json

if ($errors.Count -ne 0) {
  exit 1
}
