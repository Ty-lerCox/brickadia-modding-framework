[CmdletBinding()]
param(
  [string]$Root = '',
  [Parameter(Mandatory = $true)]
  [string]$StagedRuntimePath,
  [string]$OutJson = ''
)

$ErrorActionPreference = 'Stop'

if (!$Root) {
  $Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
}

function Get-Sha256Hex([string]$Path) {
  return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

$startedAt = (Get-Date).ToUniversalTime().ToString('o')
$rootFull = [System.IO.Path]::GetFullPath($Root)
$canonicalPath = Join-Path $rootFull 'framework/ue4ss/Mods/BMF/Scripts/bmf/runtime.lua'
$templatePath = Join-Path $rootFull 'packages/omegga-runtime/source/templates/windows-ue4ss/ue4ss/Mods/BMF/Scripts/bmf/runtime.lua'
$validatorPath = Join-Path $rootFull 'packages/omegga-runtime/source/tools/validate-lua-runtime.js'
$stagedPath = [System.IO.Path]::GetFullPath($StagedRuntimePath)
$errors = New-Object System.Collections.Generic.List[string]
$compilerResult = $null

foreach ($requiredPath in @($canonicalPath, $templatePath, $validatorPath)) {
  if (!(Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
    $errors.Add("Required deployment-gate input is missing: $requiredPath")
  }
}

if ($errors.Count -eq 0) {
  $canonicalHash = Get-Sha256Hex $canonicalPath
  $templateHash = Get-Sha256Hex $templatePath
  if ($canonicalHash -ne $templateHash) {
    $errors.Add("Canonical/template byte parity failed: canonical=$canonicalHash template=$templateHash")
  }

  if ($errors.Count -eq 0) {
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $stagedPath) | Out-Null
    Copy-Item -LiteralPath $canonicalPath -Destination $stagedPath -Force
    $stagedHash = Get-Sha256Hex $stagedPath
    if ($stagedHash -ne $canonicalHash) {
      $errors.Add("Final staged deployment runtime is not byte-identical: canonical=$canonicalHash staged=$stagedHash")
    }
  }

  if ($errors.Count -eq 0) {
    $nodeCommand = (Get-Command node -ErrorAction Stop).Source
    $compilerOutput = @(& $nodeCommand $validatorPath $canonicalPath $templatePath $stagedPath 2>&1)
    $compilerExitCode = $LASTEXITCODE
    $compilerText = ($compilerOutput | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
    try {
      $compilerResult = $compilerText | ConvertFrom-Json
    } catch {
      $errors.Add("Pinned Lua 5.3 compiler returned invalid output: $compilerText")
    }

    if ($null -ne $compilerResult) {
      foreach ($fileResult in @($compilerResult.files)) {
        if (!$fileResult.compilerPassed) {
          $errors.Add("Lua 5.3 compile failed for $($fileResult.source): $($fileResult.compilerError)")
        }
        if (!$fileResult.astPassed) {
          $errors.Add("Lua 5.3 AST validation failed for $($fileResult.source): $($fileResult.astError)")
        }
      }
      if ([string]$compilerResult.status -ne 'passed' -or $compilerExitCode -ne 0) {
        $errors.Add("Pinned Lua 5.3 compiler gate exited $compilerExitCode with status $($compilerResult.status).")
      }
    }
  }
}

$result = [ordered]@{
  feature = 'bmf.runtime-deployment-compile-gate'
  status = if ($errors.Count -eq 0) { 'passed' } else { 'failed' }
  startedAt = $startedAt
  finishedAt = (Get-Date).ToUniversalTime().ToString('o')
  data = [ordered]@{
    canonical = [ordered]@{
      path = [System.IO.Path]::GetFullPath($canonicalPath)
      sha256 = if (Test-Path -LiteralPath $canonicalPath) { Get-Sha256Hex $canonicalPath } else { $null }
    }
    template = [ordered]@{
      path = [System.IO.Path]::GetFullPath($templatePath)
      sha256 = if (Test-Path -LiteralPath $templatePath) { Get-Sha256Hex $templatePath } else { $null }
    }
    staged = [ordered]@{
      path = $stagedPath
      sha256 = if (Test-Path -LiteralPath $stagedPath) { Get-Sha256Hex $stagedPath } else { $null }
    }
    compiler = $compilerResult
  }
  errors = $errors.ToArray()
}

$json = $result | ConvertTo-Json -Depth 12
if ($OutJson) {
  $outPath = [System.IO.Path]::GetFullPath($OutJson)
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $outPath) | Out-Null
  Set-Content -LiteralPath $outPath -Value $json -Encoding UTF8
}
Write-Output $json

if ($errors.Count -ne 0) {
  exit 1
}
