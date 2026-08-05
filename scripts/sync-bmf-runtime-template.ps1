[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
  [string]$Root = '',
  [switch]$Apply,
  [string]$OutJson = ''
)

$ErrorActionPreference = 'Stop'

if (!$Root) {
  $Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
}

function Get-FullPath([string]$Path) {
  return [System.IO.Path]::GetFullPath($Path)
}

function Test-IsChildPath([string]$Parent, [string]$Child) {
  $parentFull = Get-FullPath $Parent
  $childFull = Get-FullPath $Child
  if (!$parentFull.EndsWith([System.IO.Path]::DirectorySeparatorChar)) {
    $parentFull += [System.IO.Path]::DirectorySeparatorChar
  }
  return $childFull.StartsWith($parentFull, [System.StringComparison]::OrdinalIgnoreCase)
}

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

$errors = New-Object System.Collections.Generic.List[string]
$records = New-Object System.Collections.Generic.List[object]
$rootFull = Get-FullPath $Root
$canonicalRoot = Join-Path $rootFull 'framework/ue4ss/Mods/BMF/Scripts'
$templateRoot = Join-Path $rootFull 'packages/omegga-runtime/source/templates/windows-ue4ss/ue4ss/Mods/BMF/Scripts'
$startedAt = (Get-Date).ToUniversalTime().ToString('o')
$changed = $false
$allByteIdentical = $true

$pairs = @(
  [ordered]@{
    id = 'loader'
    source = 'main.lua'
    destination = 'main.lua'
  },
  [ordered]@{
    id = 'implementation'
    source = 'bmf/runtime.lua'
    destination = 'bmf/runtime.lua'
  }
)

try {
  foreach ($pair in $pairs) {
    $sourcePath = Get-FullPath (Join-Path $canonicalRoot ([string]$pair.source))
    $destinationPath = Get-FullPath (Join-Path $templateRoot ([string]$pair.destination))

    if (!(Test-IsChildPath $canonicalRoot $sourcePath)) {
      throw "Refusing source outside the canonical runtime root: $sourcePath"
    }
    if (!(Test-IsChildPath $templateRoot $destinationPath)) {
      throw "Refusing destination outside the Omegga template runtime root: $destinationPath"
    }

    $sourceExists = Test-Path -LiteralPath $sourcePath -PathType Leaf
    $destinationExistsBefore = Test-Path -LiteralPath $destinationPath -PathType Leaf
    $sourceHash = $null
    $destinationHashBefore = $null
    $identicalBefore = $false
    $copied = $false

    if (!$sourceExists) {
      $errors.Add("Canonical runtime source is missing: $sourcePath")
      $allByteIdentical = $false
    } else {
      $sourceHash = Get-Sha256Hex $sourcePath
      if ($destinationExistsBefore) {
        $destinationHashBefore = Get-Sha256Hex $destinationPath
        $identicalBefore = $sourceHash -eq $destinationHashBefore
      }

      if (!$identicalBefore -and $Apply -and $PSCmdlet.ShouldProcess($destinationPath, "Copy canonical BMF runtime $($pair.id)")) {
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destinationPath) | Out-Null
        Copy-Item -LiteralPath $sourcePath -Destination $destinationPath -Force
        $copied = $true
        $changed = $true
      }
    }

    $destinationExistsAfter = Test-Path -LiteralPath $destinationPath -PathType Leaf
    $destinationHashAfter = if ($destinationExistsAfter) { Get-Sha256Hex $destinationPath } else { $null }
    $identicalAfter = $sourceExists -and $destinationExistsAfter -and ($sourceHash -eq $destinationHashAfter)
    if (!$identicalAfter) {
      $allByteIdentical = $false
      if ($Apply -and !$WhatIfPreference) {
        $errors.Add("Omegga runtime template did not synchronize: $destinationPath")
      }
    }

    $records.Add([ordered]@{
      id = [string]$pair.id
      source = $sourcePath
      destination = $destinationPath
      sourceSha256 = $sourceHash
      destinationSha256Before = $destinationHashBefore
      destinationSha256After = $destinationHashAfter
      identicalBefore = $identicalBefore
      identicalAfter = $identicalAfter
      copied = $copied
    })
  }
} catch {
  $errors.Add($_.Exception.Message)
  $allByteIdentical = $false
}

$mode = if ($Apply) {
  if ($WhatIfPreference) { 'what-if' } else { 'apply' }
} else {
  'check'
}
$status = if ($errors.Count -gt 0) {
  'failed'
} elseif ($allByteIdentical) {
  'synchronized'
} else {
  'changes-required'
}

$result = [ordered]@{
  feature = 'bmf.runtime-template-sync'
  status = $status
  startedAt = $startedAt
  finishedAt = (Get-Date).ToUniversalTime().ToString('o')
  data = [ordered]@{
    mode = $mode
    changed = $changed
    allByteIdentical = $allByteIdentical
    canonicalRoot = Get-FullPath $canonicalRoot
    templateRoot = Get-FullPath $templateRoot
    files = $records.ToArray()
  }
  errors = $errors.ToArray()
}

$json = $result | ConvertTo-Json -Depth 10
if ($OutJson) {
  $outPath = Get-FullPath $OutJson
  $outParent = Split-Path -Parent $outPath
  if ($outParent) {
    New-Item -ItemType Directory -Force -Path $outParent | Out-Null
  }
  Set-Content -LiteralPath $outPath -Value $json -Encoding UTF8
}
Write-Output $json

if ($errors.Count -ne 0) {
  exit 1
}
