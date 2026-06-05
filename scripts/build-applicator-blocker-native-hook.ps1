param(
  [string]$SourcePath = (Join-Path $PSScriptRoot '..\native\applicator_blocker\applicator_func_blocker.cpp'),
  [string]$OutDir = (Join-Path $PSScriptRoot '..\artifacts\local'),
  [string]$DllName = 'bmf_applicator_func_blocker.dll',
  [string]$VsRoot = 'C:\Program Files\Microsoft Visual Studio\2022\Community'
)

$ErrorActionPreference = 'Stop'

$vcvars = Join-Path $VsRoot 'VC\Auxiliary\Build\vcvars64.bat'
if (!(Test-Path -LiteralPath $vcvars)) {
  throw "vcvars64.bat not found at $vcvars"
}

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

$sourceFull = [System.IO.Path]::GetFullPath($SourcePath)
$outFull = [System.IO.Path]::GetFullPath($OutDir)
$dllPath = Join-Path $outFull $DllName
$baseName = [System.IO.Path]::GetFileNameWithoutExtension($DllName)
$pdbPath = Join-Path $outFull ($baseName + '.pdb')
$objPath = Join-Path $outFull ($baseName + '.obj')

$compile = @(
  "`"$vcvars`"",
  '>',
  'NUL',
  '&&',
  'cl.exe',
  '/nologo',
  '/std:c++20',
  '/EHsc',
  '/O2',
  '/LD',
  "`"$sourceFull`"",
  '/Fe:' + "`"$dllPath`"",
  '/Fd:' + "`"$pdbPath`"",
  '/Fo:' + "`"$objPath`"",
  'kernel32.lib',
  'user32.lib'
) -join ' '

cmd.exe /d /s /c $compile
if ($LASTEXITCODE -ne 0) {
  throw "cl.exe failed with exit code $LASTEXITCODE"
}

Get-Item -LiteralPath $dllPath
