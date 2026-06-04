param(
  [string]$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
  [string]$PresetRoot = '',
  [string]$OutJson = ''
)

$ErrorActionPreference = 'Stop'

if (!$PresetRoot) {
  $siblingRoot = Split-Path -Parent $Root
  $candidate = Join-Path $siblingRoot 'Brickadia/omegga-master/omegga-master/data/Saved/Presets/Minigame'
  if (Test-Path -LiteralPath $candidate) {
    $PresetRoot = $candidate
  } else {
    $PresetRoot = Join-Path $Root 'tests/fixtures/minigames/presets'
  }
}

$presetFullPath = [System.IO.Path]::GetFullPath($PresetRoot)
$errors = New-Object System.Collections.Generic.List[string]
$presets = New-Object System.Collections.Generic.List[object]
$evidence = New-Object System.Collections.Generic.List[object]

if (Test-Path -LiteralPath $presetFullPath) {
  foreach ($file in Get-ChildItem -LiteralPath $presetFullPath -Recurse -Filter '*.bp' -File -ErrorAction SilentlyContinue | Sort-Object FullName) {
    $relative = [System.IO.Path]::GetRelativePath($presetFullPath, $file.FullName)
    $name = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
    $presets.Add([ordered]@{
      name = $name
      relativePath = $relative
      path = $file.FullName
      bytes = $file.Length
      lastWriteTime = $file.LastWriteTimeUtc.ToString('o')
    })
  }
  $evidence.Add([ordered]@{
    kind = 'directory'
    path = $presetFullPath
    summary = 'Minigame preset directory'
  })
} else {
  $errors.Add("Preset root does not exist: $presetFullPath")
}

$result = [ordered]@{
  feature = 'minigames.presets'
  status = if ($errors.Count -eq 0) { 'passed' } else { 'failed' }
  validationLevel = 'L0 Static'
  startedAt = (Get-Date).ToUniversalTime().ToString('o')
  finishedAt = (Get-Date).ToUniversalTime().ToString('o')
  data = [ordered]@{
    presetRoot = $presetFullPath
    count = $presets.Count
    presets = $presets
  }
  evidence = $evidence
  errors = @($errors)
}

$json = $result | ConvertTo-Json -Depth 8
if ($OutJson) {
  $outPath = [System.IO.Path]::GetFullPath($OutJson)
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $outPath) | Out-Null
  Set-Content -LiteralPath $outPath -Value $json -Encoding UTF8
}

Write-Output $json
if ($errors.Count -ne 0) {
  exit 1
}
