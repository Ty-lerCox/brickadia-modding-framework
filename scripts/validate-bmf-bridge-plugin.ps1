param(
  [string]$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
  [string]$OutJson = ''
)

$ErrorActionPreference = 'Stop'

if (!$OutJson) {
  $OutJson = Join-Path $Root 'artifacts/local/bmf-bridge-plugin-validation.json'
}

$errors = New-Object System.Collections.Generic.List[string]
$evidence = New-Object System.Collections.Generic.List[object]
$startedAt = (Get-Date).ToUniversalTime().ToString('o')
$pluginRoot = Join-Path $Root 'packages/omegga-plugins/bmf-bridge'

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
  foreach ($relative in @(
    'plugin.json',
    'doc.json',
    'access.json',
    'README.md',
    'omegga.plugin.js',
    'omegga.plugin.test.js'
  )) {
    $path = Join-Path $pluginRoot $relative
    if (!(Test-Path -LiteralPath $path)) {
      $errors.Add("Missing BMF bridge plugin file: packages/omegga-plugins/bmf-bridge/$relative")
      continue
    }
    Add-Evidence 'file' $path "BMF bridge plugin $relative"
  }

  foreach ($relative in @('plugin.json', 'doc.json', 'access.json')) {
    $path = Join-Path $pluginRoot $relative
    if (Test-Path -LiteralPath $path) {
      try {
        Get-Content -Raw -LiteralPath $path | ConvertFrom-Json | Out-Null
      } catch {
        $errors.Add("Invalid JSON in packages/omegga-plugins/bmf-bridge/${relative}: $($_.Exception.Message)")
      }
    }
  }

  $sourcePath = Join-Path $pluginRoot 'omegga.plugin.js'
  if (Test-Path -LiteralPath $sourcePath) {
    $source = Get-Content -Raw -LiteralPath $sourcePath
    foreach ($needle in @(
      'subscribe(filter, handler)',
      'unsubscribe(id)',
      'invokeCommand(commandText',
      'emitPlugin(event',
      'normalizeEnvelope',
      'maxRecords',
      'socket.json',
      'OMEGGA_BMF_SOCKET_TOKEN',
      'redactValue',
      'unsupported BMF transport',
      'do-not-add-ui-driven-server-probes'
    )) {
      if ($source -notmatch [regex]::Escape($needle)) {
        $errors.Add("omegga.plugin.js does not contain expected bridge marker: $needle")
      }
    }
  }

  $readmePath = Join-Path $pluginRoot 'README.md'
  if (Test-Path -LiteralPath $readmePath) {
    $readme = Get-Content -Raw -LiteralPath $readmePath
    foreach ($needle in @(
      'game-mode neutral',
      'BMFSocket',
      'BMF Lua -> BMFSocket -> Omegga socket broker',
      'bounded in-memory buffer',
      'does not start native probes'
    )) {
      if ($readme -notmatch [regex]::Escape($needle)) {
        $errors.Add("BMF bridge README does not contain expected marker: $needle")
      }
    }
  }

  $testPath = Join-Path $pluginRoot 'omegga.plugin.test.js'
  if (Test-Path -LiteralPath $testPath) {
    $testOutput = & node --test $testPath 2>&1
    $exitCode = $LASTEXITCODE
    Add-Evidence 'test' $testPath 'BMF bridge Node test suite'
    if ($exitCode -ne 0) {
      $errors.Add('BMF bridge Node tests failed.')
      foreach ($line in @($testOutput)) {
        $errors.Add([string]$line)
      }
    }
  }
} catch {
  $errors.Add($_.Exception.Message)
}

$result = [ordered]@{
  feature = 'omegga.bmf-bridge'
  status = if ($errors.Count -eq 0) { 'passed' } else { 'failed' }
  validationLevel = 'L0 Static'
  startedAt = $startedAt
  finishedAt = (Get-Date).ToUniversalTime().ToString('o')
  data = [ordered]@{
    pluginRoot = [System.IO.Path]::GetFullPath($pluginRoot)
    retainedRecordDefault = 500
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
