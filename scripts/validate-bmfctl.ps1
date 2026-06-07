param(
  [string]$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
  [string]$OutJson = ''
)

$ErrorActionPreference = 'Stop'

if (!$OutJson) {
  $OutJson = Join-Path $Root 'artifacts/local/bmfctl-validation.json'
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

try {
  $node = Get-Command node -ErrorAction SilentlyContinue
  if (!$node) {
    throw 'Node.js is required to validate bmfctl.'
  }

  $cliPath = Join-Path $Root 'cli/bin/bmfctl.js'
  if (!(Test-Path -LiteralPath $cliPath)) {
    throw "bmfctl entrypoint is missing: $cliPath"
  }

  $testFiles = @(Get-ChildItem -LiteralPath (Join-Path $Root 'cli/test') -Filter '*.test.js' | ForEach-Object { $_.FullName })
  if ($testFiles.Count -eq 0) {
    throw 'No bmfctl test files were found.'
  }

  & node --test @testFiles
  if ($LASTEXITCODE -ne 0) {
    throw "bmfctl tests failed with exit code $LASTEXITCODE"
  }

  Add-Evidence 'file' $cliPath 'bmfctl executable entrypoint'
  foreach ($test in $testFiles) {
    Add-Evidence 'test' $test 'bmfctl node:test suite'
  }
} catch {
  $errors.Add($_.Exception.Message)
}

$result = [ordered]@{
  feature = 'bmfctl.static'
  status = if ($errors.Count -eq 0) { 'passed' } else { 'failed' }
  validationLevel = 'L0 Static'
  startedAt = $startedAt
  finishedAt = (Get-Date).ToUniversalTime().ToString('o')
  root = [System.IO.Path]::GetFullPath($Root)
  evidence = $evidence.ToArray()
  errors = $errors.ToArray()
}

$json = $result | ConvertTo-Json -Depth 8
New-Item -ItemType Directory -Force -Path (Split-Path -Parent ([System.IO.Path]::GetFullPath($OutJson))) | Out-Null
Set-Content -LiteralPath $OutJson -Value $json -Encoding UTF8
Write-Output $json

if ($errors.Count -ne 0) {
  exit 1
}
