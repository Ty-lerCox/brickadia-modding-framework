param(
  [string]$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
  [string]$OutJson = ''
)

$ErrorActionPreference = 'Stop'
$errors = New-Object System.Collections.Generic.List[string]
$startedAt = (Get-Date).ToUniversalTime().ToString('o')

function Require-Text([string]$Text, [string]$Needle, [string]$Label) {
  if ($Text -notmatch [regex]::Escape($Needle)) {
    $errors.Add("$Label is missing required safety marker: $Needle")
  }
}

function Reject-Text([string]$Text, [string]$Needle, [string]$Label) {
  if ($Text -match [regex]::Escape($Needle)) {
    $errors.Add("$Label contains forbidden recurring-discovery marker: $Needle")
  }
}

$pluginCases = @(
  [ordered]@{
    name = 'InteractConsolePrefixGuard'
    tickPattern = 'function\s+Plugin\.onTick\(BMF\)\s+pollNativeEvents\(BMF\)\s+end'
  },
  [ordered]@{
    name = 'NoSpawnItemApplicator'
    tickPattern = '(?s)function\s+Plugin\.onTick\(BMF\)\s+local\s+size\s*=\s*fileSize\(Plugin\.feedback\.path\).*?pollNativeFeedback\(BMF\).*?end\s+end'
  }
)

$deployments = @(
  [ordered]@{
    label = 'canonical'
    pluginRoot = 'framework/ue4ss/Mods/BMF/plugins'
    runtime = 'framework/ue4ss/Mods/BMF/Scripts/bmf/runtime.lua'
  },
  [ordered]@{
    label = 'omegga-package'
    pluginRoot = 'packages/omegga-runtime/source/templates/windows-ue4ss/ue4ss/Mods/BMF/plugins'
    runtime = 'packages/omegga-runtime/source/templates/windows-ue4ss/ue4ss/Mods/BMF/Scripts/main.lua'
  }
)

foreach ($deployment in $deployments) {
  foreach ($case in $pluginCases) {
    $label = "$($deployment.label)/$($case.name)"
    $pluginDir = Join-Path $Root "$($deployment.pluginRoot)/$($case.name)"
    $sourcePath = Join-Path $pluginDir 'main.lua'
    $configPath = Join-Path $pluginDir 'config.json'
    if (!(Test-Path -LiteralPath $sourcePath) -or !(Test-Path -LiteralPath $configPath)) {
      $errors.Add("Missing $label source or config.")
      continue
    }

    $source = Get-Content -Raw -LiteralPath $sourcePath
    $config = Get-Content -Raw -LiteralPath $configPath | ConvertFrom-Json
    if ($config.policy.proactivePrimeAllowedContexts -ne $false) {
      $errors.Add("$label must default proactivePrimeAllowedContexts to false.")
    }

    Reject-Text $source 'nativeTargets' $label
    Reject-Text $source 'proactivePrimeAllowedContext(' $label
    Reject-Text $source 'BMF.timers.after' $label
    Reject-Text $source 'writeNativePolicy(BMF, "status")' $label
    Require-Text $source 'context_discovery_mode=explicit-address-only' $label
    Require-Text $source 'live UObject discovery is disabled' $label
    if ($source -notmatch $case.tickPattern) {
      $errors.Add("$label onTick is not the expected bounded file-only implementation.")
    }
  }

  $runtimePath = Join-Path $Root $deployment.runtime
  if (!(Test-Path -LiteralPath $runtimePath)) {
    $errors.Add("Missing $($deployment.label) BMF runtime: $runtimePath")
  } else {
    $runtime = Get-Content -Raw -LiteralPath $runtimePath
    foreach ($needle in @(
      'if options.refresh ~= true then',
      'NATIVE_TARGETS_NOT_CACHED',
      'if options.unsafe ~= true then',
      'UNSAFE_DISCOVERY_CONFIRMATION_REQUIRED',
      'discovery=explicit-unsafe-only',
      'native_targets_requests',
      'native_targets_cache_reads',
      'native_targets_rejected_requests',
      'native_targets_refresh_count'
    )) {
      Require-Text $runtime $needle "$($deployment.label) BMF runtime"
    }
    Require-Text $runtime 'refresh = option_boolean(options, "refresh", false)' "$($deployment.label) native-targets command"
    Require-Text $runtime 'unsafe = option_boolean(options, "unsafe", false)' "$($deployment.label) native-targets command"

    $positiveAddressChecks = [regex]::Matches(
      $runtime,
      [regex]::Escape('type(address) == "number" and address > 0')
    ).Count
    if ($positiveAddressChecks -lt 2) {
      $errors.Add("$($deployment.label) BMF runtime must reject numeric zero pointers in every tool address resolver.")
    }
    $zeroStringChecks = [regex]::Matches(
      $runtime,
      [regex]::Escape('not hex:match("^0x?0+$")')
    ).Count
    if ($zeroStringChecks -lt 2) {
      $errors.Add("$($deployment.label) BMF runtime must reject string zero pointers in every tool address resolver.")
    }
  }
}

foreach ($relativePath in @(
  'scripts/sync-applicator-blocker-native-hook.ps1',
  'scripts/sync-interact-prefix-guard-native-hook.ps1'
)) {
  $scriptPath = Join-Path $Root $relativePath
  if (!(Test-Path -LiteralPath $scriptPath)) {
    $errors.Add("Missing native provisioning script: $relativePath")
    continue
  }
  $scriptSource = Get-Content -Raw -LiteralPath $scriptPath
  Require-Text $scriptSource 'bmf.tools.applicator.native-targets refresh=true unsafe=true' $relativePath
  Require-Text $scriptSource 'refusing to inject a non-enforcing hook' $relativePath
}

$result = [ordered]@{
  feature = 'bmf.applicator-context-safety'
  status = if ($errors.Count -eq 0) { 'passed' } else { 'failed' }
  validationLevel = 'L0 Static + L5 Negative'
  startedAt = $startedAt
  finishedAt = (Get-Date).ToUniversalTime().ToString('o')
  data = [ordered]@{
    recurringDiscoveryAllowed = $false
    nativeDiscoveryMode = 'explicit-unsafe-only'
    guardedPlugins = @($pluginCases.name)
    validatedDeployments = @($deployments.label)
  }
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
