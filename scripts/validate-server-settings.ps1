param(
  [string]$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
  [string]$GameUserSettingsPath = '',
  [string]$PatchedOutputRoot = '',
  [string]$OutJson = ''
)

$ErrorActionPreference = 'Stop'

function Read-GeneralSettings {
  param([Parameter(Mandatory = $true)][string]$Path)

  $section = '[Server__BP_ServerSettings_General_C BP_ServerSettings_General_C]'
  $inSection = $false
  $values = @{}

  foreach ($line in [System.IO.File]::ReadAllLines($Path)) {
    if ($line.Trim() -eq $section) {
      $inSection = $true
      continue
    }
    if ($inSection -and $line -match '^\s*\[.+\]\s*$') {
      break
    }
    if ($inSection -and $line -match '^\s*([^=;\#\[]+?)\s*=(.*)$') {
      $values[$matches[1].Trim()] = $matches[2]
    }
  }

  return $values
}

function Invoke-SettingsCase {
  param(
    [Parameter(Mandatory = $true)][string]$CaseName,
    [Parameter(Mandatory = $true)][string]$InputPath,
    [Parameter(Mandatory = $true)][string]$OutputRoot,
    [System.Collections.Generic.List[string]]$Errors
  )

  $patchScript = Join-Path $Root 'scripts/patch-server-settings.ps1'
  $patchedPath = Join-Path $OutputRoot "$CaseName.GameUserSettings.patched.ini"
  $patchReportPath = Join-Path $OutputRoot "$CaseName.server-settings-report.json"

  $patchOutput = & $patchScript `
    -InputPath $InputPath `
    -OutputPath $patchedPath `
    -OutJson $patchReportPath `
    -ServerName 'BMF Canary Server' `
    -ServerDescription 'BMF file-backed settings patch canary' `
    -ServerPassword '' `
    -MaxPlayers 42 `
    -PubliclyListed false `
    -WelcomeMessage 'Welcome from BMF'

  $patchReport = $patchOutput | ConvertFrom-Json
  if ($patchReport.status -ne 'passed') {
    $Errors.Add("${CaseName}: patch script did not pass")
  }

  $settings = Read-GeneralSettings -Path $patchedPath
  $expected = [ordered]@{
    ServerName = 'BMF Canary Server'
    ServerDescription = 'BMF file-backed settings patch canary'
    ServerPassword = ''
    MaxPlayers = '42'
    bPubliclyListed = 'False'
    WelcomeMessage = '"Welcome from BMF"'
  }

  foreach ($key in $expected.Keys) {
    if (!$settings.ContainsKey($key)) {
      $Errors.Add("${CaseName}: patched settings missing $key")
    } elseif ([string]$settings[$key] -ne [string]$expected[$key]) {
      $Errors.Add("${CaseName}: expected $key=$($expected[$key]), got $($settings[$key])")
    }
  }

  [ordered]@{
    case = $CaseName
    inputPath = [System.IO.Path]::GetFullPath($InputPath)
    patchedPath = [System.IO.Path]::GetFullPath($patchedPath)
    patchReportPath = [System.IO.Path]::GetFullPath($patchReportPath)
    patchStatus = $patchReport.status
    patchedSettings = $settings
  }
}

$errors = New-Object System.Collections.Generic.List[string]
$cases = New-Object System.Collections.Generic.List[object]
$evidence = New-Object System.Collections.Generic.List[object]

if (!$PatchedOutputRoot) {
  if ($OutJson) {
    $PatchedOutputRoot = Join-Path (Split-Path -Parent ([System.IO.Path]::GetFullPath($OutJson))) 'server-settings'
  } else {
    $PatchedOutputRoot = Join-Path $Root 'artifacts/local/server-settings'
  }
}
New-Item -ItemType Directory -Force -Path $PatchedOutputRoot | Out-Null

$fixturePath = Join-Path $Root 'tests/fixtures/server/GameUserSettings.ini'
if (!(Test-Path -LiteralPath $fixturePath)) {
  $errors.Add('Missing server settings fixture: tests/fixtures/server/GameUserSettings.ini')
} else {
  $cases.Add((Invoke-SettingsCase -CaseName 'fixture' -InputPath $fixturePath -OutputRoot $PatchedOutputRoot -Errors $errors))
  $evidence.Add([ordered]@{
    kind = 'ini'
    path = $fixturePath
    summary = 'Self-contained GameUserSettings.ini fixture'
  })
}

$liveSettingsPath = $GameUserSettingsPath
if (!$liveSettingsPath) {
  $siblingRoot = Split-Path -Parent $Root
  $candidate = Join-Path $siblingRoot 'Brickadia/omegga-master/omegga-master/data/Saved/Config/WindowsServer/GameUserSettings.ini'
  if (Test-Path -LiteralPath $candidate) {
    $liveSettingsPath = $candidate
  }
}

if ($liveSettingsPath) {
  if (!(Test-Path -LiteralPath $liveSettingsPath)) {
    $errors.Add("GameUserSettingsPath does not exist: $liveSettingsPath")
  } else {
    $cases.Add((Invoke-SettingsCase -CaseName 'live-copy' -InputPath $liveSettingsPath -OutputRoot $PatchedOutputRoot -Errors $errors))
    $evidence.Add([ordered]@{
      kind = 'ini'
      path = [System.IO.Path]::GetFullPath($liveSettingsPath)
      summary = 'Current server GameUserSettings.ini, copied into a patched temp output'
    })
  }
}

$result = [ordered]@{
  feature = 'server.settings-patcher'
  status = if ($errors.Count -eq 0) { 'passed' } else { 'failed' }
  validationLevel = if ($liveSettingsPath -and (Test-Path -LiteralPath $liveSettingsPath)) { 'L2 Headless' } else { 'L0 Static' }
  startedAt = (Get-Date).ToUniversalTime().ToString('o')
  finishedAt = (Get-Date).ToUniversalTime().ToString('o')
  data = [ordered]@{
    outputRoot = [System.IO.Path]::GetFullPath($PatchedOutputRoot)
    cases = $cases
  }
  evidence = $evidence
  errors = @($errors)
}

$json = $result | ConvertTo-Json -Depth 10
if ($OutJson) {
  $outPath = [System.IO.Path]::GetFullPath($OutJson)
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $outPath) | Out-Null
  Set-Content -LiteralPath $outPath -Value $json -Encoding UTF8
}

Write-Output $json
if ($errors.Count -ne 0) {
  exit 1
}
