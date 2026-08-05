param(
  [string]$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
  [string]$OutJson = '',
  [string[]]$AdditionalLuaPath = @()
)

$ErrorActionPreference = 'Stop'

if (!$OutJson) {
  $OutJson = Join-Path $Root 'artifacts/local/bmf-runtime-template-parity-validation.json'
}

$errors = New-Object System.Collections.Generic.List[string]
$evidence = New-Object System.Collections.Generic.List[object]
$records = New-Object System.Collections.Generic.List[object]
$unsafeSchedulerFindings = New-Object System.Collections.Generic.List[object]
$luaSyntaxRecords = New-Object System.Collections.Generic.List[object]
$startedAt = (Get-Date).ToUniversalTime().ToString('o')
$allByteIdentical = $true
$luaValidatorPath = Join-Path $Root 'packages/omegga-runtime/source/tools/validate-lua-runtime.js'
$nodeCommand = $null

function Get-Sha256Hex([string]$Path) {
  $stream = [System.IO.File]::OpenRead($Path)
  try {
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
      return ([System.BitConverter]::ToString($sha256.ComputeHash($stream))).Replace('-', '').ToLowerInvariant()
    } finally {
      $sha256.Dispose()
    }
  } finally {
    $stream.Dispose()
  }
}

function Add-Evidence([string]$Kind, [string]$Path, [string]$Summary) {
  if ($Path -and (Test-Path -LiteralPath $Path -PathType Leaf)) {
    $script:evidence.Add([ordered]@{
      kind = $Kind
      path = [System.IO.Path]::GetFullPath($Path)
      summary = $Summary
    })
  }
}

function Test-TextMarkers([string]$Path, [string[]]$Markers, [string]$Name) {
  if (!(Test-Path -LiteralPath $Path -PathType Leaf)) {
    return
  }

  $source = Get-Content -Raw -LiteralPath $Path
  foreach ($needle in $Markers) {
    if ($source -notmatch [regex]::Escape($needle)) {
      $script:errors.Add("$Name does not contain required loader marker: $needle")
    }
  }
}

function Test-LuaRuntimeSafety([string]$Path, [string]$Name, [bool]$Required) {
  if (!(Test-Path -LiteralPath $Path -PathType Leaf)) {
    if ($Required) {
      $script:errors.Add("Lua scheduler safety source is missing for ${Name}: $Path")
    }
    return
  }

  $absolutePath = [System.IO.Path]::GetFullPath($Path)
  $nativeOutput = @(& $script:nodeCommand $script:luaValidatorPath $absolutePath 2>&1)
  $nativeExitCode = $LASTEXITCODE
  $jsonText = ($nativeOutput | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
  $validation = $null
  try {
    $validation = $jsonText | ConvertFrom-Json
  } catch {
    $script:errors.Add("Lua 5.3 validator did not return JSON for ${Name}: $jsonText")
    return
  }

  foreach ($fileResult in @($validation.files)) {
    $script:luaSyntaxRecords.Add([ordered]@{
      source = $Name
      path = $absolutePath
      luaVersion = [string]$validation.luaVersion
      compiler = [string]$validation.compiler
      parser = [string]$validation.parser
      passed = [bool]$fileResult.syntaxPassed
      error = if ($fileResult.syntaxError) { [string]$fileResult.syntaxError } else { $null }
      compilerPassed = [bool]$fileResult.compilerPassed
      compilerError = if ($fileResult.compilerError) { [string]$fileResult.compilerError } else { $null }
      astPassed = [bool]$fileResult.astPassed
      astError = if ($fileResult.astError) { [string]$fileResult.astError } else { $null }
    })
    if (!$fileResult.syntaxPassed) {
      $script:errors.Add("Lua 5.3 syntax validation failed for ${Name}: $($fileResult.syntaxError)")
    }
    foreach ($item in @($fileResult.unsafeSchedulerFindings)) {
      $finding = [ordered]@{
        source = $Name
        path = $absolutePath
        primitive = [string]$item.primitive
        invocation = [string]$item.invocation
        line = [int]$item.line
        column = [int]$item.column
      }
      $script:unsafeSchedulerFindings.Add($finding)
      $script:errors.Add("Forbidden Lua scheduler surface in $Name at line $($item.line): $($item.invocation)($($item.primitive)).")
    }
  }

  if ($nativeExitCode -ne 0 -and [string]$validation.status -eq 'passed') {
    $script:errors.Add("Lua 5.3 validator exited with code $nativeExitCode for $Name despite reporting passed.")
  }
  Add-Evidence 'lua-runtime-validation-source' $Path "$Name Lua 5.3 compile and scheduler safety scan"
}

$pairs = @(
  [ordered]@{
    id = 'loader'
    label = 'BMF runtime loader'
    canonical = 'framework/ue4ss/Mods/BMF/Scripts/main.lua'
    template = 'packages/omegga-runtime/source/templates/windows-ue4ss/ue4ss/Mods/BMF/Scripts/main.lua'
    markers = @('runtime_candidates', 'Scripts/bmf/runtime.lua', 'loadfile')
  },
  [ordered]@{
    id = 'implementation'
    label = 'BMF runtime implementation'
    canonical = 'framework/ue4ss/Mods/BMF/Scripts/bmf/runtime.lua'
    template = 'packages/omegga-runtime/source/templates/windows-ue4ss/ue4ss/Mods/BMF/Scripts/bmf/runtime.lua'
    markers = @()
  }
)

try {
  if (!(Test-Path -LiteralPath $luaValidatorPath -PathType Leaf)) {
    throw "Lua runtime validator is missing: $luaValidatorPath"
  }
  $nodeCommand = (Get-Command node -ErrorAction Stop).Source
  Add-Evidence 'lua-runtime-validator' $luaValidatorPath 'Pinned Lua 5.3 compiler and scheduler safety validator'

  foreach ($pair in $pairs) {
    $canonicalPath = Join-Path $Root ([string]$pair.canonical)
    $templatePath = Join-Path $Root ([string]$pair.template)
    $canonicalExists = Test-Path -LiteralPath $canonicalPath -PathType Leaf
    $templateExists = Test-Path -LiteralPath $templatePath -PathType Leaf
    $canonicalHash = $null
    $templateHash = $null
    $canonicalBytes = $null
    $templateBytes = $null
    $byteIdentical = $false

    if (!$canonicalExists) {
      $errors.Add("Canonical $($pair.label) is missing: $($pair.canonical)")
      $allByteIdentical = $false
    } else {
      $canonicalHash = Get-Sha256Hex $canonicalPath
      $canonicalBytes = (Get-Item -LiteralPath $canonicalPath).Length
      Add-Evidence 'canonical-runtime-source' $canonicalPath "Canonical $($pair.label)"
      Test-TextMarkers $canonicalPath @($pair.markers) "Canonical $($pair.label)"
    }

    if (!$templateExists) {
      $errors.Add("Omegga template $($pair.label) is missing: $($pair.template)")
      $allByteIdentical = $false
    } else {
      $templateHash = Get-Sha256Hex $templatePath
      $templateBytes = (Get-Item -LiteralPath $templatePath).Length
      Add-Evidence 'omegga-runtime-template' $templatePath "Omegga template $($pair.label)"
      Test-TextMarkers $templatePath @($pair.markers) "Omegga template $($pair.label)"
    }

    if ($canonicalExists -and $templateExists) {
      $byteIdentical = ($canonicalBytes -eq $templateBytes) -and ($canonicalHash -eq $templateHash)
      if (!$byteIdentical) {
        $errors.Add("Omegga template $($pair.label) is not byte-identical to $($pair.canonical) (canonical sha256=$canonicalHash, template sha256=$templateHash).")
        $allByteIdentical = $false
      }
    }

    $records.Add([ordered]@{
      id = [string]$pair.id
      canonical = [ordered]@{
        path = [System.IO.Path]::GetFullPath($canonicalPath)
        exists = $canonicalExists
        bytes = $canonicalBytes
        sha256 = $canonicalHash
      }
      template = [ordered]@{
        path = [System.IO.Path]::GetFullPath($templatePath)
        exists = $templateExists
        bytes = $templateBytes
        sha256 = $templateHash
      }
      byteIdentical = $byteIdentical
    })
  }

  $schedulerSafetyTargets = New-Object System.Collections.Generic.List[object]
  $schedulerSafetyTargets.Add([ordered]@{
    name = 'canonical BMF loader'
    path = Join-Path $Root 'framework/ue4ss/Mods/BMF/Scripts/main.lua'
    required = $false
  })
  $schedulerSafetyTargets.Add([ordered]@{
    name = 'canonical BMF runtime'
    path = Join-Path $Root 'framework/ue4ss/Mods/BMF/Scripts/bmf/runtime.lua'
    required = $false
  })
  $schedulerSafetyTargets.Add([ordered]@{
    name = 'packaged BMF loader'
    path = Join-Path $Root 'packages/omegga-runtime/source/templates/windows-ue4ss/ue4ss/Mods/BMF/Scripts/main.lua'
    required = $false
  })
  $schedulerSafetyTargets.Add([ordered]@{
    name = 'packaged BMF runtime'
    path = Join-Path $Root 'packages/omegga-runtime/source/templates/windows-ue4ss/ue4ss/Mods/BMF/Scripts/bmf/runtime.lua'
    required = $false
  })
  $schedulerSafetyTargets.Add([ordered]@{
    name = 'vendored OmeggaBridge runtime'
    path = Join-Path $Root 'packages/omegga-runtime/source/templates/windows-ue4ss/ue4ss/Mods/OmeggaBridge/Scripts/main.lua'
    required = $true
  })
  foreach ($additionalPath in @($AdditionalLuaPath)) {
    if ([string]::IsNullOrWhiteSpace([string]$additionalPath)) {
      continue
    }
    $resolvedAdditionalPath = if ([System.IO.Path]::IsPathRooted([string]$additionalPath)) {
      [System.IO.Path]::GetFullPath([string]$additionalPath)
    } else {
      [System.IO.Path]::GetFullPath((Join-Path $Root ([string]$additionalPath)))
    }
    $schedulerSafetyTargets.Add([ordered]@{
      name = "additional Lua runtime: $resolvedAdditionalPath"
      path = $resolvedAdditionalPath
      required = $true
    })
  }
  foreach ($target in $schedulerSafetyTargets) {
    Test-LuaRuntimeSafety ([string]$target.path) ([string]$target.name) ([bool]$target.required)
  }
} catch {
  $errors.Add($_.Exception.Message)
  $allByteIdentical = $false
}

$result = [ordered]@{
  feature = 'bmf.runtime-template-parity'
  status = if ($errors.Count -eq 0) { 'passed' } else { 'failed' }
  validationLevel = 'L0 Static'
  startedAt = $startedAt
  finishedAt = (Get-Date).ToUniversalTime().ToString('o')
  data = [ordered]@{
    allByteIdentical = $allByteIdentical
    files = $records.ToArray()
    luaSyntax = $luaSyntaxRecords.ToArray()
    unsafeSchedulerFindings = $unsafeSchedulerFindings.ToArray()
  }
  evidence = $evidence.ToArray()
  errors = $errors.ToArray()
}

$json = $result | ConvertTo-Json -Depth 10
$outPath = [System.IO.Path]::GetFullPath($OutJson)
$outParent = Split-Path -Parent $outPath
if ($outParent) {
  New-Item -ItemType Directory -Force -Path $outParent | Out-Null
}
Set-Content -LiteralPath $outPath -Value $json -Encoding UTF8
Write-Output $json

if ($errors.Count -ne 0) {
  exit 1
}
