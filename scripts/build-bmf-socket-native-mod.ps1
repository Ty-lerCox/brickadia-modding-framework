param(
  [string]$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
  [string]$Ue4ssSourceDir = 'C:\Users\tycox\Tools\reverse-engineering\RE-UE4SS',
  [string]$OutDir = '',
  [string]$Generator = 'Visual Studio 17 2022',
  [string]$Config = 'Game__Shipping__Win64',
  [string]$CMakePath = '',
  [switch]$EnforceUe4ssVersionCheck,
  [switch]$Deploy
)

$ErrorActionPreference = 'Stop'

function Get-FullPath([string]$Path) {
  return [System.IO.Path]::GetFullPath($Path)
}

$rootFull = Get-FullPath $Root
$ue4ssFull = Get-FullPath $Ue4ssSourceDir
$sourceDir = Join-Path $rootFull 'native/bmf_socket'
if (!$OutDir) {
  $OutDir = Join-Path $rootFull 'artifacts/local/bmf-socket'
}
$outFull = Get-FullPath $OutDir
$wrapperDir = Join-Path $outFull 'cmake-src'
$buildDir = Join-Path $outFull 'build'

if (!$CMakePath) {
  $cmakeCommand = Get-Command cmake -ErrorAction SilentlyContinue
  if ($cmakeCommand) {
    $CMakePath = $cmakeCommand.Source
  } else {
    $vsCmake = 'C:\Program Files\Microsoft Visual Studio\2022\Community\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe'
    if (Test-Path -LiteralPath $vsCmake) {
      $CMakePath = $vsCmake
    }
  }
}
if (!$CMakePath -or !(Test-Path -LiteralPath $CMakePath)) {
  throw 'cmake was not found on PATH and the Visual Studio bundled cmake.exe was not found.'
}

if (!(Test-Path -LiteralPath (Join-Path $ue4ssFull 'CMakeLists.txt'))) {
  throw "UE4SS source directory is missing CMakeLists.txt: $ue4ssFull"
}
if (!(Test-Path -LiteralPath (Join-Path $sourceDir 'bmf_socket.cpp'))) {
  throw "BMFSocket source is missing: $sourceDir"
}

New-Item -ItemType Directory -Force -Path $wrapperDir | Out-Null
New-Item -ItemType Directory -Force -Path $buildDir | Out-Null

$wrapper = @"
cmake_minimum_required(VERSION 3.22)
project(BMFSocketBuild)
add_subdirectory("$($ue4ssFull.Replace('\', '/'))" RE-UE4SS)
add_subdirectory("$($sourceDir.Replace('\', '/'))" BMFSocket)
"@
$wrapperPath = Join-Path $wrapperDir 'CMakeLists.txt'
$wrapper | Set-Content -LiteralPath $wrapperPath -Encoding UTF8

$configureArgs = @()
if (!$EnforceUe4ssVersionCheck) {
  $configureArgs += '-DUE4SS_VERSION_CHECK=OFF'
}

if ($Generator -eq 'Ninja') {
  & $CMakePath -S $wrapperDir -B $buildDir -G Ninja -DCMAKE_BUILD_TYPE=$Config @configureArgs
  if ($LASTEXITCODE -ne 0) {
    throw "cmake configure failed with exit code $LASTEXITCODE"
  }
  & $CMakePath --build $buildDir --target BMFSocket
} else {
  & $CMakePath -S $wrapperDir -B $buildDir -G $Generator -A x64 @configureArgs
  if ($LASTEXITCODE -ne 0) {
    throw "cmake configure failed with exit code $LASTEXITCODE"
  }
  & $CMakePath --build $buildDir --config $Config --target BMFSocket
}
if ($LASTEXITCODE -ne 0) {
  throw "cmake build failed with exit code $LASTEXITCODE"
}

$dll = Get-ChildItem -LiteralPath $buildDir -Recurse -Filter 'BMFSocket.dll' |
  Sort-Object LastWriteTimeUtc -Descending |
  Select-Object -First 1
if (!$dll) {
  throw "BMFSocket.dll was not produced under $buildDir"
}

$result = [ordered]@{
  dll = $dll.FullName
  deployed = $false
  deployedPath = $null
}

if ($Deploy) {
  $targetDir = Join-Path $rootFull 'framework/ue4ss/Mods/BMFSocket/dlls'
  New-Item -ItemType Directory -Force -Path $targetDir | Out-Null
  $target = Join-Path $targetDir 'main.dll'
  Copy-Item -LiteralPath $dll.FullName -Destination $target -Force
  $result.deployed = $true
  $result.deployedPath = $target
}

$result | ConvertTo-Json -Depth 4
