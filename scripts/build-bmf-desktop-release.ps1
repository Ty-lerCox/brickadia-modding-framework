param(
  [string]$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
  [string]$MsiPath = '',
  [string]$PortablePath = '',
  [string]$Version = '',
  [string]$OutDir = '',
  [string]$OutJson = '',
  [string]$ReleaseChannel = 'dev',
  [string]$DownloadBaseUrl = '',
  [switch]$BuildMsi,
  [switch]$BuildPortable,
  [string]$NodeExe = $env:BMF_DESKTOP_NODE_EXE,
  [switch]$Force
)

$ErrorActionPreference = 'Stop'

function Get-FullPath([string]$Path) {
  return [System.IO.Path]::GetFullPath($Path)
}

function Read-JsonFile([string]$Path) {
  if (!(Test-Path -LiteralPath $Path)) {
    return $null
  }
  return Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json
}

function Add-Evidence([System.Collections.Generic.List[object]]$Evidence, [string]$Kind, [string]$Path, [string]$Summary) {
  if ($Path -and (Test-Path -LiteralPath $Path)) {
    $Evidence.Add([ordered]@{
      kind = $Kind
      path = Get-FullPath $Path
      summary = $Summary
    })
  }
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

function Resolve-NodeExecutable([string]$RequestedNodeExe) {
  $candidate = $RequestedNodeExe
  if ([string]::IsNullOrWhiteSpace($candidate)) {
    $candidate = 'node'
  }
  $command = Get-Command $candidate -ErrorAction Stop
  return $command.Source
}

function Get-NodeVersion([string]$ResolvedNodeExe) {
  $versionText = (& $ResolvedNodeExe -p "process.versions.node" 2>&1)
  if ($LASTEXITCODE -ne 0) {
    throw "Unable to execute Node for BMF Desktop build: $ResolvedNodeExe"
  }
  return [string]($versionText | Select-Object -First 1)
}

function Test-IsSupportedDesktopNodeVersion([string]$VersionText) {
  $version = [System.Version]$VersionText
  if ($version.Major -eq 22) {
    return $version -ge [System.Version]'22.22.3'
  }
  if ($version.Major -eq 24) {
    return $version -ge [System.Version]'24.15.0'
  }
  return $version.Major -ge 26
}

function Format-ProcessArgument([string]$Argument) {
  if ($null -eq $Argument) {
    return '""'
  }
  if ($Argument -notmatch '[\s"]') {
    return $Argument
  }
  return '"' + ($Argument -replace '"', '\"') + '"'
}

function Invoke-DesktopBuildCommand([string]$Node, [string]$Script, [string[]]$Arguments, [string]$WorkingDirectory, [string]$Label) {
  $processInfo = [System.Diagnostics.ProcessStartInfo]::new()
  $processInfo.FileName = $Node
  $processInfo.WorkingDirectory = $WorkingDirectory
  $processInfo.UseShellExecute = $false
  $processInfo.RedirectStandardOutput = $true
  $processInfo.RedirectStandardError = $true

  $nodeDirectory = Split-Path -Parent $Node
  $environmentVariables = $processInfo.EnvironmentVariables
  if ($nodeDirectory -and $environmentVariables) {
    $pathKey = if ($environmentVariables.ContainsKey('PATH')) { 'PATH' } else { 'Path' }
    $environmentVariables[$pathKey] = "$nodeDirectory;$($environmentVariables[$pathKey])"
  }

  $processInfo.Arguments = (@($Script) + @($Arguments) | ForEach-Object { Format-ProcessArgument $_ }) -join ' '

  $process = [System.Diagnostics.Process]::new()
  $process.StartInfo = $processInfo
  [void]$process.Start()
  $stdoutTask = $process.StandardOutput.ReadToEndAsync()
  $stderrTask = $process.StandardError.ReadToEndAsync()
  $process.WaitForExit()
  $stdout = $stdoutTask.GetAwaiter().GetResult()
  $stderr = $stderrTask.GetAwaiter().GetResult()
  $exitCode = $process.ExitCode
  $process.Dispose()
  $output = @()
  if ($stdout) {
    $output += @($stdout -split "\r?\n")
  }
  if ($stderr) {
    $output += @($stderr -split "\r?\n")
  }
  if ($exitCode -ne 0) {
    $tail = @($output | Select-Object -Last 30) -join [Environment]::NewLine
    throw "$Label failed with exit code $exitCode.$([Environment]::NewLine)$tail"
  }
  return @($output)
}

function Test-DesktopBundledAssets([string]$DesktopRoot) {
  $resourceRoot = Join-Path $DesktopRoot 'dist/release/win-unpacked/resources/bmf'
  $required = @(
    'manifests/unified-runtime.json',
    'manifests/bmf-package.json',
    'bin/bmfctl.cmd',
    'apps/bmf-desktop/package.json',
    'framework/ue4ss/Mods/BMF/bmf.json',
    'framework/ue4ss/Mods/BMFSocket/README.md',
    'cli/bin/bmfctl.js',
    'cli/src/cli.js',
    'packages/orchestrator-core/package.json',
    'packages/orchestrator-core/src/index.js',
    'packages/bmf-runtime/package-manifest.json',
    'packages/bmf-native-socket/package-manifest.json',
    'packages/omegga-runtime/package-manifest.json',
    'packages/omegga-runtime/sync-metadata.json',
    'packages/omegga-runtime/source/package.json',
    'packages/omegga-runtime/source/package-lock.json',
    'packages/omegga-runtime/source/src/brickadia/ue4ssBridge.ts',
    'packages/omegga-runtime/source/src/omegga/index.ts',
    'packages/omegga-runtime/source/tools/package-bmf-omegga.js',
    'packages/omegga-runtime/source/templates/windows-ue4ss/ue4ss/Mods/BMF/Scripts/main.lua',
    'packages/omegga-runtime/source/templates/windows-ue4ss/ue4ss/Mods/BMF/Scripts/bmf/runtime.lua',
    'packages/omegga-runtime/source/templates/windows-ue4ss/ue4ss/Mods/OmeggaBridge/Scripts/main.lua',
    'packages/omegga-plugins/bmf-bridge/plugin.json',
    'packages/omegga-plugins/bmf-player-sync/plugin.json',
    'packages/omegga-plugins/bmf-minigame-events/plugin.json',
    'compat/ue4ss/package-manifest.json',
    'observability/observability-manifest.json',
    'observability/alloy/bmf.alloy.template',
    'observability/grafana/bmf-dashboard.json'
  )
  $missing = New-Object System.Collections.Generic.List[string]
  foreach ($relative in $required) {
    $candidate = Join-Path $resourceRoot $relative
    if (!(Test-Path -LiteralPath $candidate)) {
      $missing.Add($relative)
    }
  }
  if ($missing.Count -gt 0) {
    throw "BMF Desktop MSI bundle is missing required BMF resource(s): $($missing -join ', ')"
  }
  return [ordered]@{
    resourceRoot = Get-FullPath $resourceRoot
    requiredFiles = $required
  }
}

function Test-DesktopBmfctlShim([string]$DesktopRoot, [string]$ExpectedVersion) {
  $shimPath = Join-Path $DesktopRoot 'dist/release/win-unpacked/resources/bmf/bin/bmfctl.cmd'
  if (!(Test-Path -LiteralPath $shimPath)) {
    throw "Installed bmfctl shim is missing from the unpacked app: $shimPath"
  }
  $output = & cmd /c "`"$shimPath`" version" 2>&1
  $exitCode = $LASTEXITCODE
  if ($exitCode -ne 0) {
    $tail = @($output | Select-Object -Last 20) -join [Environment]::NewLine
    throw "Installed bmfctl shim failed with exit code $exitCode.$([Environment]::NewLine)$tail"
  }
  $lines = @($output | ForEach-Object { [string]$_ })
  $expectedVersionOutput = "bmfctl $ExpectedVersion"
  if (!($lines | Where-Object { $_ -eq $expectedVersionOutput })) {
    throw "Installed bmfctl shim did not report a bmfctl version. Output: $($lines -join ' | ')"
  }
  return [ordered]@{
    shimPath = Get-FullPath $shimPath
    versionOutput = $lines
  }
}

function Get-ComponentById($UnifiedRuntime, [string]$Id) {
  if (!$UnifiedRuntime -or !$UnifiedRuntime.components) {
    return $null
  }
  foreach ($component in @($UnifiedRuntime.components)) {
    if ([string]$component.id -eq $Id) {
      return $component
    }
  }
  return $null
}

function Get-SupportedBrickadiaBuild($PackageManifest, $Compatibility) {
  if ($PackageManifest -and $PackageManifest.supportedBrickadiaBuilds -and @($PackageManifest.supportedBrickadiaBuilds).Count -gt 0) {
    $first = @($PackageManifest.supportedBrickadiaBuilds)[0]
    if ($first.build) {
      return [string]$first.build
    }
  }
  if ($Compatibility -and $Compatibility.brickadia -and $Compatibility.brickadia.primaryTarget) {
    $target = [string]$Compatibility.brickadia.primaryTarget
    if ($target -match '(PC-Shipping-CL\d+)') {
      return $Matches[1]
    }
    return $target
  }
  return 'unknown'
}

function New-FileRecord([string]$Path, [string]$ArtifactRole) {
  $item = Get-Item -LiteralPath $Path
  return [ordered]@{
    role = $ArtifactRole
    fileName = $item.Name
    path = $item.Name
    bytes = $item.Length
    sha256 = Get-Sha256Hex $Path
  }
}

function Join-ReleaseUrl([string]$BaseUrl, [string]$FileName) {
  if ([string]::IsNullOrWhiteSpace($BaseUrl)) {
    return ''
  }
  return ('{0}/{1}' -f $BaseUrl.TrimEnd('/'), $FileName)
}

function New-NativeHashRecord([string]$Root, [string]$RelativePath, [string]$Role) {
  $path = Join-Path $Root $RelativePath
  if (!(Test-Path -LiteralPath $path)) {
    return [ordered]@{
      role = $Role
      path = $RelativePath.Replace('\', '/')
      missing = $true
    }
  }
  $item = Get-Item -LiteralPath $path
  return [ordered]@{
    role = $Role
    path = $RelativePath.Replace('\', '/')
    bytes = $item.Length
    sha256 = Get-Sha256Hex $path
  }
}

if (!$OutDir) {
  $OutDir = Join-Path $Root 'artifacts/local/bmf-desktop-release'
}
if (!$OutJson) {
  $OutJson = Join-Path $OutDir 'desktop-release-build.json'
}

$errors = New-Object System.Collections.Generic.List[string]
$evidence = New-Object System.Collections.Generic.List[object]
$startedAt = (Get-Date).ToUniversalTime().ToString('o')
$rootFull = Get-FullPath $Root
$outDirFull = Get-FullPath $OutDir
$outJsonFull = Get-FullPath $OutJson
$desktopPackagePath = Join-Path $rootFull 'apps/bmf-desktop/package.json'
$packageManifestPath = Join-Path $rootFull 'manifests/bmf-package.json'
$omeggaRuntimeManifestPath = Join-Path $rootFull 'packages/omegga-runtime/package-manifest.json'
$compatibilityPath = Join-Path $rootFull 'manifests/compatibility.json'
$unifiedRuntimePath = Join-Path $rootFull 'manifests/unified-runtime.json'
$observabilityManifestPath = Join-Path $rootFull 'observability/observability-manifest.json'
$primaryArtifactPath = $null
$portableArtifactPath = $null
$checksumPath = $null
$portableChecksumPath = $null
$releaseManifestPath = $null
$releaseCatalogPath = $null
$releaseNotesPath = $null
$installerSha256 = $null
$installerBytes = $null
$portableSha256 = $null
$portableBytes = $null
$desktopBuild = [ordered]@{
  requested = [bool]($BuildMsi -or $BuildPortable)
  buildMsi = [bool]$BuildMsi
  buildPortable = [bool]$BuildPortable
}

try {
  $portablePathProvided = ![string]::IsNullOrWhiteSpace($PortablePath)
  $desktopPackage = Read-JsonFile $desktopPackagePath
  if (!$desktopPackage) {
    throw "BMF Desktop package manifest is missing: $desktopPackagePath"
  }
  if (!$Version) {
    $Version = [string]$desktopPackage.version
  }
  if (!$Version) {
    throw 'BMF Desktop package manifest does not contain version.'
  }
  if (!$MsiPath) {
    $MsiPath = Join-Path $rootFull ("apps/bmf-desktop/dist/release/BMF-Desktop-{0}-x64.msi" -f $Version)
  }
  if (!$PortablePath) {
    $PortablePath = Join-Path $rootFull ("apps/bmf-desktop/dist/release/BMF-Desktop-{0}-portable-x64.exe" -f $Version)
  }
  $msiFull = Get-FullPath $MsiPath
  $portableFull = Get-FullPath $PortablePath
  if ($BuildMsi -or $BuildPortable) {
    $desktopRoot = Join-Path $rootFull 'apps/bmf-desktop'
    $ngScript = Join-Path $desktopRoot 'node_modules/@angular/cli/bin/ng.js'
    $builderScript = Join-Path $desktopRoot 'node_modules/electron-builder/cli.js'
    if (!(Test-Path -LiteralPath $ngScript)) {
      throw "Angular CLI is not installed for BMF Desktop. Run npm --prefix apps/bmf-desktop ci before building the MSI."
    }
    if (!(Test-Path -LiteralPath $builderScript)) {
      throw "electron-builder is not installed for BMF Desktop. Run npm --prefix apps/bmf-desktop ci before building the MSI."
    }
    $resolvedNode = Resolve-NodeExecutable $NodeExe
    $nodeVersion = Get-NodeVersion $resolvedNode
    if (!(Test-IsSupportedDesktopNodeVersion $nodeVersion)) {
      throw "BMF Desktop MSI build requires Node 22.22.3+, 24.15.0+, or 26+. Found Node $nodeVersion at $resolvedNode."
    }
    $desktopBuild['nodeExe'] = $resolvedNode
    $desktopBuild['nodeVersion'] = $nodeVersion
    $rendererOutput = Invoke-DesktopBuildCommand `
      -Node $resolvedNode `
      -Script $ngScript `
      -Arguments @('build', '--configuration', 'production') `
      -WorkingDirectory $desktopRoot `
      -Label 'BMF Desktop Angular renderer build'
    $builderTargets = New-Object System.Collections.Generic.List[string]
    if ($BuildMsi) {
      $builderTargets.Add('msi')
    }
    if ($BuildPortable) {
      $builderTargets.Add('portable')
    }
    $builderArguments = @('--win') + $builderTargets.ToArray() + @('--x64')
    $installerOutput = Invoke-DesktopBuildCommand `
      -Node $resolvedNode `
      -Script $builderScript `
      -Arguments $builderArguments `
      -WorkingDirectory $desktopRoot `
      -Label 'BMF Desktop Windows artifact build'
    $bundledAssets = Test-DesktopBundledAssets $desktopRoot
    $bmfctlShim = Test-DesktopBmfctlShim $desktopRoot $Version
    $desktopBuild['rendererOutputTail'] = @($rendererOutput | Select-Object -Last 8)
    $desktopBuild['installerOutputTail'] = @($installerOutput | Select-Object -Last 12)
    $desktopBuild['bundledAssets'] = $bundledAssets
    $desktopBuild['bmfctlShim'] = $bmfctlShim
  }
  if (!(Test-Path -LiteralPath $msiFull)) {
    throw "MSI artifact does not exist. Build it with npm --prefix apps/bmf-desktop run dist:msi, pass -BuildMsi, or pass -MsiPath: $msiFull"
  }
  $portableRequired = [bool]$BuildPortable -or $portablePathProvided
  if ($portableRequired -and !(Test-Path -LiteralPath $portableFull)) {
    throw "Portable artifact does not exist. Build it with npm --prefix apps/bmf-desktop run dist:portable, pass -BuildPortable, or pass -PortablePath: $portableFull"
  }

  $packageManifest = Read-JsonFile $packageManifestPath
  $omeggaRuntimeManifest = Read-JsonFile $omeggaRuntimeManifestPath
  $compatibility = Read-JsonFile $compatibilityPath
  $unifiedRuntime = Read-JsonFile $unifiedRuntimePath
  $observabilityManifest = Read-JsonFile $observabilityManifestPath
  $omeggaComponent = Get-ComponentById $unifiedRuntime 'omegga-runtime'
  $ue4ssComponent = Get-ComponentById $unifiedRuntime 'ue4ss-compatibility'
  $supportedBuild = Get-SupportedBrickadiaBuild $packageManifest $compatibility
  $ue4ssBundleId = if ($ue4ssComponent -and $ue4ssComponent.status) {
    "ue4ss-$($ue4ssComponent.status)-$supportedBuild"
  } else {
    "ue4ss-$supportedBuild"
  }
  $bmfRuntimeVersion = if ($packageManifest -and $packageManifest.version) { [string]$packageManifest.version } else { $Version }
  $omeggaRuntimeVersionOrCommit = if ($omeggaRuntimeManifest -and $omeggaRuntimeManifest.sourceCommit) {
    [string]$omeggaRuntimeManifest.sourceCommit
  } elseif ($omeggaComponent -and $omeggaComponent.source) {
    [string]$omeggaComponent.source
  } elseif ($omeggaComponent -and $omeggaComponent.status) {
    [string]$omeggaComponent.status
  } else {
    'unknown'
  }
  $alloyTemplateVersion = if ($observabilityManifest -and $observabilityManifest.version) { [string]$observabilityManifest.version } else { $Version }
  $dashboardVersion = if ($observabilityManifest -and $observabilityManifest.grafana -and $observabilityManifest.grafana.dashboardVersion) {
    [string]$observabilityManifest.grafana.dashboardVersion
  } else {
    $Version
  }

  New-Item -ItemType Directory -Force -Path $outDirFull | Out-Null
  $artifactName = "BMF-Desktop-$Version-x64.msi"
  $portableArtifactName = "BMF-Desktop-$Version-portable-x64.exe"
  $primaryArtifactPath = Join-Path $outDirFull $artifactName
  $portableArtifactPath = Join-Path $outDirFull $portableArtifactName
  $checksumPath = "$primaryArtifactPath.sha256"
  $portableChecksumPath = "$portableArtifactPath.sha256"
  $releaseManifestPath = Join-Path $outDirFull 'release-manifest.json'
  $releaseCatalogPath = Join-Path $outDirFull 'release-catalog.json'
  $releaseNotesPath = Join-Path $outDirFull 'RELEASE_NOTES.md'

  $portableAvailable = Test-Path -LiteralPath $portableFull
  $releaseOutputPaths = @($primaryArtifactPath, $checksumPath, $releaseManifestPath, $releaseCatalogPath, $releaseNotesPath)
  if ($portableAvailable) {
    $releaseOutputPaths += @($portableArtifactPath, $portableChecksumPath)
  }
  foreach ($path in $releaseOutputPaths) {
    if ((Test-Path -LiteralPath $path) -and !$Force) {
      throw "Release artifact already exists. Pass -Force to overwrite: $path"
    }
  }

  if ($msiFull -ne (Get-FullPath $primaryArtifactPath)) {
    Copy-Item -LiteralPath $msiFull -Destination $primaryArtifactPath -Force
  }
  if ($portableAvailable -and $portableFull -ne (Get-FullPath $portableArtifactPath)) {
    Copy-Item -LiteralPath $portableFull -Destination $portableArtifactPath -Force
  }

  $installerRecord = New-FileRecord $primaryArtifactPath 'installer'
  $installerUrl = Join-ReleaseUrl $DownloadBaseUrl $artifactName
  if ($installerUrl) {
    $installerRecord['url'] = $installerUrl
  }
  $installerSha256 = [string]$installerRecord.sha256
  $installerBytes = [int64]$installerRecord.bytes
  Set-Content -LiteralPath $checksumPath -Encoding UTF8 -Value ("{0}  {1}" -f $installerSha256, $artifactName)
  $checksumRecord = New-FileRecord $checksumPath 'checksum'
  $portableRecord = $null
  $portableChecksumRecord = $null
  $optionalReleaseRecords = @()
  $optionalRequiredArtifacts = @()
  if ($portableAvailable) {
    $portableRecord = New-FileRecord $portableArtifactPath 'portable'
    $portableUrl = Join-ReleaseUrl $DownloadBaseUrl $portableArtifactName
    if ($portableUrl) {
      $portableRecord['url'] = $portableUrl
    }
    $portableSha256 = [string]$portableRecord.sha256
    $portableBytes = [int64]$portableRecord.bytes
    Set-Content -LiteralPath $portableChecksumPath -Encoding UTF8 -Value ("{0}  {1}" -f $portableSha256, $portableArtifactName)
    $portableChecksumRecord = New-FileRecord $portableChecksumPath 'portable-checksum'
    $optionalReleaseRecords = @($portableRecord, $portableChecksumRecord)
    $optionalRequiredArtifacts = @($portableArtifactName, "$portableArtifactName.sha256")
  }

  $nativeHelperHashes = [ordered]@{
    BMFSocket = @(
      New-NativeHashRecord $rootFull 'framework/ue4ss/Mods/BMFSocket/dlls/main.dll' 'dll'
      New-NativeHashRecord $rootFull 'native/bmf_socket/CMakeLists.txt' 'build'
      New-NativeHashRecord $rootFull 'native/bmf_socket/bmf_socket.cpp' 'source'
    )
    BMFFrameTelemetry = @(
      New-NativeHashRecord $rootFull 'framework/ue4ss/Mods/BMFFrameTelemetry/dlls/main.dll' 'dll'
      New-NativeHashRecord $rootFull 'native/bmf_frame_telemetry/CMakeLists.txt' 'build'
      New-NativeHashRecord $rootFull 'native/bmf_frame_telemetry/bmf_frame_telemetry.cpp' 'source'
    )
  }

  $releaseNotes = New-Object System.Collections.Generic.List[string]
  foreach ($line in @(
    "# BMF Desktop $Version",
    '',
    "- Release channel: $ReleaseChannel",
    "- Primary artifact: $artifactName",
    "- SHA256: $installerSha256",
    "- Supported Brickadia build: $supportedBuild",
    "- UE4SS bundle id: $ue4ssBundleId",
    '',
    '## Included',
    '',
    '- BMF Desktop Electron shell with Angular and Angular Material 3 renderer.',
    '- Shared orchestration core for install, repair, update, health, log, and traffic plans.',
    '- Default Grafana Alloy template and standard Grafana dashboard JSON.',
    '- Unified runtime manifest covering BMF, Omegga, UE4SS, native helpers, adapters, and observability assets.',
    '',
    '## Verification',
    '',
    "Verify the MSI with `$artifactName.sha256` before installing it.",
    '',
    '## Known Issues',
    '',
    '- Dev artifacts are not code-signed until a signing certificate is configured.',
    '- BMF Desktop updates and managed server component updates are intentionally separate actions.'
  )) {
    $releaseNotes.Add($line)
  }
  if ($portableRecord) {
    $releaseNotes.Insert(5, "- Portable artifact: $portableArtifactName")
    $releaseNotes.Insert(6, "- Portable SHA256: $portableSha256")
    $verificationIndex = $releaseNotes.IndexOf("Verify the MSI with `$artifactName.sha256` before installing it.")
    if ($verificationIndex -ge 0) {
      $releaseNotes.Insert($verificationIndex + 1, "Verify the portable exe with `$portableArtifactName.sha256` before running it.")
    }
  }
  Set-Content -LiteralPath $releaseNotesPath -Encoding UTF8 -Value $releaseNotes
  $releaseNotesRecord = New-FileRecord $releaseNotesPath 'release-notes'

  $releaseManifest = [ordered]@{
    schemaVersion = 1
    releaseKind = 'bmf-desktop-release'
    generatedAt = (Get-Date).ToUniversalTime().ToString('o')
    releaseChannel = $ReleaseChannel
    bmfDesktopVersion = $Version
    bmfRuntimeVersion = $bmfRuntimeVersion
    omeggaRuntimeVersionOrCommit = $omeggaRuntimeVersionOrCommit
    supportedBrickadiaBuild = $supportedBuild
    ue4ssBundleId = $ue4ssBundleId
    nativeHelperHashes = $nativeHelperHashes
    alloyTemplateVersion = $alloyTemplateVersion
    dashboardVersion = $dashboardVersion
    minimumWindowsVersion = 'Windows 10 x64 or Windows Server 2019 x64'
    installerSha256 = $installerSha256
    portableSha256 = $portableSha256
    primaryArtifact = $installerRecord
    portableArtifact = $portableRecord
    releaseCatalog = 'release-catalog.json'
    requiredArtifacts = @($artifactName, "$artifactName.sha256") + $optionalRequiredArtifacts + @('release-manifest.json', 'release-catalog.json', 'RELEASE_NOTES.md')
    files = @($installerRecord, $checksumRecord) + $optionalReleaseRecords + @($releaseNotesRecord)
  }
  $releaseManifest | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $releaseManifestPath -Encoding UTF8
  $releaseManifestRecord = New-FileRecord $releaseManifestPath 'release-manifest'

  $catalogRelease = [ordered]@{
    version = $Version
    channel = $ReleaseChannel
    publishedAt = $releaseManifest['generatedAt']
    artifact = $installerRecord
    portableArtifact = $portableRecord
    checksum = $checksumRecord
    portableChecksum = $portableChecksumRecord
    manifest = $releaseManifestRecord
    releaseNotes = $releaseNotesRecord
    supportedBrickadiaBuild = $supportedBuild
    bmfRuntimeVersion = $bmfRuntimeVersion
    omeggaRuntimeVersionOrCommit = $omeggaRuntimeVersionOrCommit
    ue4ssBundleId = $ue4ssBundleId
    dashboardVersion = $dashboardVersion
    minimumWindowsVersion = $releaseManifest.minimumWindowsVersion
  }
  $releaseCatalog = [ordered]@{
    schemaVersion = 1
    catalogKind = 'bmf-desktop-release-catalog'
    generatedAt = (Get-Date).ToUniversalTime().ToString('o')
    releaseChannel = $ReleaseChannel
    latest = $catalogRelease
    releases = @($catalogRelease)
    updateGuardrails = @(
      'verify-sha256-before-install',
      'require-user-confirmation-before-desktop-update',
      'keep-desktop-update-separate-from-managed-server-updates',
      'do-not-stop-running-managed-services-without-confirmation'
    )
  }
  $releaseCatalog | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $releaseCatalogPath -Encoding UTF8

  Add-Evidence $evidence 'msi' $primaryArtifactPath 'BMF Desktop MSI release artifact'
  Add-Evidence $evidence 'checksum' $checksumPath 'BMF Desktop MSI SHA256 checksum'
  Add-Evidence $evidence 'exe' $portableArtifactPath 'BMF Desktop portable release artifact'
  Add-Evidence $evidence 'checksum' $portableChecksumPath 'BMF Desktop portable SHA256 checksum'
  Add-Evidence $evidence 'json' $releaseManifestPath 'BMF Desktop release manifest'
  Add-Evidence $evidence 'json' $releaseCatalogPath 'BMF Desktop release catalog'
  Add-Evidence $evidence 'markdown' $releaseNotesPath 'BMF Desktop release notes'
} catch {
  $errors.Add($_.Exception.Message)
}

$status = if ($errors.Count -eq 0) { 'passed' } else { 'failed' }
$result = [ordered]@{
  feature = 'bmf-desktop.release.build'
  status = $status
  validationLevel = 'L0 Static'
  startedAt = $startedAt
  finishedAt = (Get-Date).ToUniversalTime().ToString('o')
  data = [ordered]@{
    root = $rootFull
    outDir = $outDirFull
    version = $Version
    releaseChannel = $ReleaseChannel
    primaryArtifactPath = if ($primaryArtifactPath) { Get-FullPath $primaryArtifactPath } else { $null }
    checksumPath = if ($checksumPath) { Get-FullPath $checksumPath } else { $null }
    releaseManifestPath = if ($releaseManifestPath) { Get-FullPath $releaseManifestPath } else { $null }
    releaseCatalogPath = if ($releaseCatalogPath) { Get-FullPath $releaseCatalogPath } else { $null }
    releaseNotesPath = if ($releaseNotesPath) { Get-FullPath $releaseNotesPath } else { $null }
    portableArtifactPath = if ($portableArtifactPath -and (Test-Path -LiteralPath $portableArtifactPath)) { Get-FullPath $portableArtifactPath } else { $null }
    portableChecksumPath = if ($portableChecksumPath -and (Test-Path -LiteralPath $portableChecksumPath)) { Get-FullPath $portableChecksumPath } else { $null }
    installerSha256 = $installerSha256
    installerBytes = $installerBytes
    portableSha256 = $portableSha256
    portableBytes = $portableBytes
    desktopBuild = $desktopBuild
  }
  evidence = $evidence.ToArray()
  errors = $errors.ToArray()
}

$json = $result | ConvertTo-Json -Depth 12
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $outJsonFull) | Out-Null
Set-Content -LiteralPath $outJsonFull -Value $json -Encoding UTF8
Write-Output $json

if ($errors.Count -ne 0) {
  exit 1
}
