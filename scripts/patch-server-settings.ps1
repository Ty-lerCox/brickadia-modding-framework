param(
  [Parameter(Mandatory = $true)]
  [string]$InputPath,
  [string]$OutputPath = '',
  [string]$OutJson = '',
  [AllowEmptyString()]
  [string]$ServerName = $null,
  [AllowEmptyString()]
  [string]$ServerDescription = $null,
  [AllowEmptyString()]
  [string]$ServerPassword = $null,
  [Nullable[int]]$MaxPlayers = $null,
  [string]$PubliclyListed = '',
  [AllowEmptyString()]
  [string]$WelcomeMessage = $null
)

$ErrorActionPreference = 'Stop'

$generalSection = '[Server__BP_ServerSettings_General_C BP_ServerSettings_General_C]'

function Test-SettingsText {
  param(
    [string]$Name,
    [AllowEmptyString()][string]$Value,
    [int]$MaxLength
  )

  if ($null -eq $Value) {
    return
  }
  if ($Value.Length -gt $MaxLength) {
    throw "$Name must be $MaxLength characters or fewer"
  }
  if ($Value -match '[\x00-\x08\x0B\x0C\x0E-\x1F]') {
    throw "$Name contains unsupported control characters"
  }
  if ($Value -match '[\r\n]') {
    throw "$Name must not contain newlines"
  }
}

function Convert-IniString {
  param(
    [AllowEmptyString()][string]$Value,
    [switch]$Quote
  )

  if ($null -eq $Value) {
    return ''
  }
  if ($Quote) {
    return '"' + ($Value -replace '\\', '\\' -replace '"', '\"') + '"'
  }
  return $Value
}

function Convert-PublicBool {
  param([string]$Value)
  if (!$Value) {
    return $null
  }
  switch -Regex ($Value.Trim().ToLowerInvariant()) {
    '^(true|1|yes|public)$' { return 'True' }
    '^(false|0|no|private)$' { return 'False' }
    default { throw 'PubliclyListed must be true/false, yes/no, public/private, or 1/0' }
  }
}

$inputFullPath = [System.IO.Path]::GetFullPath($InputPath)
if (!(Test-Path -LiteralPath $inputFullPath)) {
  throw "Input GameUserSettings.ini does not exist: $inputFullPath"
}

$settings = [ordered]@{}
if ($PSBoundParameters.ContainsKey('ServerName')) {
  Test-SettingsText -Name 'ServerName' -Value $ServerName -MaxLength 128
  $settings.ServerName = Convert-IniString $ServerName
}
if ($PSBoundParameters.ContainsKey('ServerDescription')) {
  Test-SettingsText -Name 'ServerDescription' -Value $ServerDescription -MaxLength 512
  $settings.ServerDescription = Convert-IniString $ServerDescription
}
if ($PSBoundParameters.ContainsKey('ServerPassword')) {
  Test-SettingsText -Name 'ServerPassword' -Value $ServerPassword -MaxLength 128
  $settings.ServerPassword = Convert-IniString $ServerPassword
}
if ($PSBoundParameters.ContainsKey('MaxPlayers')) {
  if ($MaxPlayers -lt 1 -or $MaxPlayers -gt 255) {
    throw 'MaxPlayers must be between 1 and 255'
  }
  $settings.MaxPlayers = [string]$MaxPlayers
}
if ($PubliclyListed) {
  $settings.bPubliclyListed = Convert-PublicBool $PubliclyListed
}
if ($PSBoundParameters.ContainsKey('WelcomeMessage')) {
  Test-SettingsText -Name 'WelcomeMessage' -Value $WelcomeMessage -MaxLength 512
  $settings.WelcomeMessage = Convert-IniString $WelcomeMessage -Quote
}

if ($settings.Count -eq 0) {
  throw 'At least one server setting must be supplied'
}

$lines = New-Object System.Collections.Generic.List[string]
foreach ($line in [System.IO.File]::ReadAllLines($inputFullPath)) {
  $lines.Add($line)
}

$sectionStart = -1
for ($i = 0; $i -lt $lines.Count; $i++) {
  if ($lines[$i].Trim() -eq $generalSection) {
    $sectionStart = $i
    break
  }
}

if ($sectionStart -lt 0) {
  if ($lines.Count -gt 0 -and $lines[$lines.Count - 1].Trim() -ne '') {
    $lines.Add('')
  }
  $sectionStart = $lines.Count
  $lines.Add($generalSection)
}

$sectionEnd = $lines.Count
for ($i = $sectionStart + 1; $i -lt $lines.Count; $i++) {
  if ($lines[$i] -match '^\s*\[.+\]\s*$') {
    $sectionEnd = $i
    break
  }
}

$changed = New-Object System.Collections.Generic.List[object]
$seen = @{}
for ($i = $sectionStart + 1; $i -lt $sectionEnd; $i++) {
  if ($lines[$i] -match '^\s*([^=;\#\[]+?)\s*=(.*)$') {
    $key = $matches[1].Trim()
    if ($settings.Contains($key)) {
      $oldValue = $matches[2]
      $newValue = [string]$settings[$key]
      $lines[$i] = "$key=$newValue"
      $seen[$key] = $true
      $changed.Add([ordered]@{
        key = $key
        oldValue = $oldValue
        newValue = $newValue
      })
    }
  }
}

$insertAt = $sectionEnd
foreach ($key in $settings.Keys) {
  if (!$seen.ContainsKey($key)) {
    $value = [string]$settings[$key]
    $lines.Insert($insertAt, "$key=$value")
    $insertAt++
    $changed.Add([ordered]@{
      key = $key
      oldValue = $null
      newValue = $value
    })
  }
}

$writtenPath = $null
if ($OutputPath) {
  $outputFullPath = [System.IO.Path]::GetFullPath($OutputPath)
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $outputFullPath) | Out-Null
  [System.IO.File]::WriteAllLines($outputFullPath, [string[]]$lines, [System.Text.UTF8Encoding]::new($false))
  $writtenPath = $outputFullPath
}

$result = [ordered]@{
  feature = 'server.settings-patch'
  status = 'passed'
  validationLevel = 'L0 Static'
  startedAt = (Get-Date).ToUniversalTime().ToString('o')
  finishedAt = (Get-Date).ToUniversalTime().ToString('o')
  data = [ordered]@{
    inputPath = $inputFullPath
    outputPath = $writtenPath
    section = $generalSection
    changed = $changed
  }
  evidence = @(
    [ordered]@{
      kind = 'ini'
      path = $inputFullPath
      summary = 'Input GameUserSettings.ini'
    }
  )
  errors = @()
}

$json = $result | ConvertTo-Json -Depth 8
if ($OutJson) {
  $outPath = [System.IO.Path]::GetFullPath($OutJson)
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $outPath) | Out-Null
  Set-Content -LiteralPath $outPath -Value $json -Encoding UTF8
}

Write-Output $json
