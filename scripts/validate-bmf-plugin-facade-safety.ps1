[CmdletBinding()]
param(
  [string]$Root = '',
  [string]$OutJson = ''
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($Root)) {
  $Root = Split-Path -Parent $PSScriptRoot
}
$startedAt = (Get-Date).ToUniversalTime().ToString('o')
$runtimePath = Join-Path $Root 'framework/ue4ss/Mods/BMF/Scripts/bmf/runtime.lua'
$pluginRoot = Join-Path $Root 'framework/ue4ss/Mods/BMF/plugins'
$exampleRoot = Join-Path $Root 'examples'
$failures = [System.Collections.Generic.List[string]]::new()
$evidence = [System.Collections.Generic.List[object]]::new()
$checkedLuaFiles = 0

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
  $source = Get-Content -LiteralPath $runtimePath -Raw
  Add-Evidence 'lua-runtime' $runtimePath 'Canonical BMF runtime plugin facade source'

function Assert-SourcePattern {
  param([string]$Pattern, [string]$Label)
  if (![regex]::IsMatch($source, $Pattern, [System.Text.RegularExpressions.RegexOptions]::Singleline)) {
    $failures.Add($Label)
  }
}

$createMatch = [regex]::Match(
  $source,
  'function create_plugin_api\(plugin_name, manifest\)(?<body>.*?)\r?\nend\r?\n\r?\nfunction unload_plugin',
  [System.Text.RegularExpressions.RegexOptions]::Singleline
)
$createBody = $createMatch.Groups['body'].Value
if ($createBody -eq '') {
  $failures.Add('Could not isolate create_plugin_api.')
} elseif ([regex]::IsMatch($createBody, 'for key, value in pairs\(BMF\)')) {
  $failures.Add('create_plugin_api still shallow-copies the top-level BMF table.')
}

Assert-SourcePattern 'local function unregister_event_handler\(id, owner\).*?entry\.owner ~= owner' 'Owner-aware event unregister helper is missing.'
Assert-SourcePattern 'api\.events\.off = function\(id\).*?unregister_event_handler\(id, plugin_name\)' 'Plugin events.off is not owner scoped.'
Assert-SourcePattern 'register_minigame_event_handler\(name, handler, owner\).*?register_event_handler\(event_name,.*?owner\)' 'Minigame subscriptions are not owner tagged.'
Assert-SourcePattern 'api\.minigames\.off = function\(id\).*?unregister_event_handler\(id, plugin_name\)' 'Plugin minigames.off is not owner scoped.'
Assert-SourcePattern 'local existing = state\.commands\[command_name\].*?COMMAND_ALREADY_REGISTERED.*?state\.commands\[command_name\] = \{' 'Command collision rejection is missing or occurs after overwrite.'
Assert-SourcePattern 'api\.commands\.dispatchWithAccess = function.*?require_capability\(plugin_name, manifest, "commands\.dispatchWithAccess"' 'Access-checked plugin dispatch is not capability gated.'
Assert-SourcePattern 'local function copy_plugin_api_value.*?seen\[value\].*?copy_plugin_api_value\(child, seen\)' 'Recursive plugin namespace copy is missing.'
Assert-SourcePattern 'local function create_plugin_os_library\(\).*?clock = os\.clock.*?date = os\.date.*?difftime = os\.difftime.*?time = os\.time' 'Time-only plugin os facade is missing.'
Assert-SourcePattern 'create_plugin_io_library\(manifest\).*?has_manifest_capability\(manifest, "filesystem\.raw"\).*?open = io\.open' 'Raw plugin io is not capability gated.'

if ([regex]::IsMatch($createBody, 'api\.commands\.dispatch\s*=')) {
  $failures.Add('Unrestricted plugin command dispatch remains exposed.')
}
if ($source -match 'copy_plugin_library\((io|os)\)') {
  $failures.Add('The full io or os library is still copied into plugin environments.')
}

$allowedRoots = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
@(
  'version', 'started_at', 'result', 'health', 'logging', 'apis', 'compatibility',
  'sandbox', 'plugins', 'permissions', 'minigames', 'interact', 'log', 'logInfo',
  'logWarn', 'logError', 'logger', 'audit', 'rateLimits', 'timers', 'events',
  'commands', 'tools', 'server', 'chat', 'players', 'world', 'bricks', 'prefabs',
  'vehicles', 'storage', 'capabilities'
) | ForEach-Object { [void]$allowedRoots.Add($_) }

Get-ChildItem -Path $pluginRoot, $exampleRoot -Recurse -Filter '*.lua' -File | ForEach-Object {
  $script:checkedLuaFiles += 1
  $lua = Get-Content -LiteralPath $_.FullName -Raw
  foreach ($match in [regex]::Matches($lua, '\bBMF\.(?<root>[A-Za-z_][A-Za-z0-9_]*)')) {
    $rootName = $match.Groups['root'].Value
    if (!$allowedRoots.Contains($rootName)) {
      $failures.Add("$($_.FullName) uses BMF.$rootName, which is absent from the explicit plugin facade.")
    }
  }

  if ($_.Directory.Parent.FullName -eq (Get-Item -LiteralPath $pluginRoot).FullName) {
    $manifestPath = Join-Path $_.Directory.FullName 'bmf.json'
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    if ($lua -match '\bio\.' -and @($manifest.capabilities) -notcontains 'filesystem.raw') {
      $failures.Add("$($_.Directory.Name) uses io without filesystem.raw.")
    }
    foreach ($match in [regex]::Matches($lua, '\bos\.(?<name>[A-Za-z_][A-Za-z0-9_]*)')) {
      if ($match.Groups['name'].Value -notin @('clock', 'date', 'difftime', 'time')) {
        $failures.Add("$($_.Directory.Name) uses blocked os.$($match.Groups['name'].Value).")
      }
    }
  }
}

  Add-Evidence 'plugin-root' $pluginRoot 'Canonical bundled plugin sources'
  Add-Evidence 'example-root' $exampleRoot 'BMF example plugin sources'
} catch {
  $failures.Add($_.Exception.Message)
}

$result = [ordered]@{
  feature = 'bmf.plugin-facade-safety'
  status = if ($failures.Count -eq 0) { 'passed' } else { 'failed' }
  validationLevel = 'L0 Static'
  startedAt = $startedAt
  finishedAt = (Get-Date).ToUniversalTime().ToString('o')
  data = [ordered]@{
    runtimePath = [System.IO.Path]::GetFullPath($runtimePath)
    pluginRoot = [System.IO.Path]::GetFullPath($pluginRoot)
    exampleRoot = [System.IO.Path]::GetFullPath($exampleRoot)
    checkedLuaFiles = $checkedLuaFiles
    allowedFacadeRoots = @($allowedRoots | Sort-Object)
  }
  evidence = $evidence.ToArray()
  errors = $failures.ToArray()
}

$json = $result | ConvertTo-Json -Depth 8
if ($OutJson) {
  $outPath = [System.IO.Path]::GetFullPath($OutJson)
  $outParent = Split-Path -Parent $outPath
  if ($outParent) {
    New-Item -ItemType Directory -Force -Path $outParent | Out-Null
  }
  Set-Content -LiteralPath $outPath -Value $json -Encoding UTF8
}
Write-Output $json

if ($failures.Count -ne 0) {
  exit 1
}
