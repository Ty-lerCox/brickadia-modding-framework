# Windows Setup

**Labels:** `experimental`, `windows`, `desktop`, `installer`

BMF is installed into the UE4SS working directory for a Windows Brickadia
Dedicated Server.

Current target: Brickadia EA2 PC-Shipping-CL13530.

## Who Should Read This?

Server operators should use this page to set up BMF on a Windows dedicated
server. BMF maintainers should use it when checking release-package and
rollback behavior.

!!! warning
    BMF's UE4SS path is Windows-only. Linux and WSL are not supported for the
    UE4SS/BMF dedicated-server runtime.

## Prerequisites

- Windows 10 x64, Windows 11 x64, or Windows Server 2019+ x64.
- Brickadia Dedicated Server for Brickadia EA2 `PC-Shipping-CL13530`.
- BMF-supported Omegga Windows fork for Windows server launch, command
  transport, bridge helpers, logs, and validation:
  <https://github.com/Ty-lerCox/bmf-omegga-fork>.
- BMF Desktop portable exe or MSI release artifact.
- File-system access to the server `Binaries\Win64` directory.

Do not assume an arbitrary upstream Omegga install is enough. See the
[Supported Runtime Matrix](../reference/supported-runtime.md) for the current
fork contract.

## Portable Desktop Setup

Use the portable exe for the few-click setup path. It keeps profile data next
to the executable in `BMF Desktop Data`, so it can be handed to another Windows
server operator without requiring an installer first.

1. Download `BMF-Desktop-<version>-portable-x64.exe` from the release.
2. Stop the Brickadia Dedicated Server if it is already running.
3. Open the portable exe.
4. In Easy mode, choose the Brickadia Dedicated Server install folder. You can
   select the install root or the final `Brickadia\Binaries\Win64` folder.
5. Confirm the detected folder contains `BrickadiaServer-Win64-Shipping.exe`.
6. Review the Easy health rows.
7. Use the action buttons shown on unhealthy or degraded rows:
   - `Install` stages the BMF runtime, UE4SS mod files, native helpers, and
     managed profile metadata for the selected server path.
   - `Repair` restores missing BMF/UE4SS files and enablement markers.
   - `Start` or `Restart` uses the configured BMF-supported Omegga start path
     when that path is present.
8. Click `Refresh Health` after each action.

Easy mode only shows optional telemetry, frame-time, socket, and Grafana rows
when the profile has those features enabled or evidence exists. A clean
Brickadia-only profile should focus on the core rows first: server files,
UE4SS/BMF staging, and BMF runtime status.

## MSI Setup

Use the MSI when you want a normal installed application entry, Windows
installer metadata, and a stable app location. The setup flow inside the app is
the same as the portable exe: open BMF Desktop, select the Brickadia Dedicated
Server folder, then apply the Easy-mode action buttons until the core rows are
healthy.

## Release Package

Build a zip from the source tree:

```powershell
.\scripts\build-release-package.ps1 `
  -OutDir .\artifacts\local\release `
  -Force
```

Validate the zip by expanding it and running the static package validator inside
the expanded copy:

```powershell
.\scripts\validate-release-package.ps1 `
  -OutJson .\artifacts\local\release-package-canary.json
```

Release zips include the framework, installer, docs, examples, manifests,
scripts, tests, and Omegga integration files. They intentionally exclude
generated `artifacts/` and do not vendor Omegga `node_modules`.

## Scripted Install

Stop the dedicated server first. The installer refuses to modify a server
directory when `BrickadiaServer-Win64-Shipping.exe` is running from that path.

```powershell
.\installer\install-bmf.ps1 `
  -ServerWin64Dir "C:\Path\To\Brickadia\Binaries\Win64" `
  -BrickadiaSavedDir "C:\Path\To\BrickadiaServerData\Saved" `
  -Force `
  -OutJson .\artifacts\local\install-bmf.json
```

By default the target Mods folder is:

```text
<ServerWin64Dir>\ue4ss\main\Mods
```

The installer copies `framework/ue4ss/Mods/BMF` to `Mods/BMF`. If a previous
`Mods/BMF` folder exists, `-Force` backs it up under
`<ServerWin64Dir>\BMF-Backups\BMF-<timestamp>` before replacing it. The new
install writes `Mods/BMF/runtime/install-manifest.json` with copied file hashes
and backup metadata.

`-BrickadiaSavedDir` is optional for framework boot, but required for file-backed
server policy enforcers such as `NoSpawnItemApplicator`. It should point at the
server's `Saved` directory, not `Saved\Server`; the installer writes that path
to `Mods/BMF/config.json` as `brickadiaSavedDir`.

## Rollback or Remove

Restore the backup created by an install:

```powershell
.\installer\uninstall-bmf.ps1 `
  -ServerWin64Dir "C:\Path\To\Brickadia\Binaries\Win64" `
  -RestoreBackupDir "C:\Path\To\Brickadia\Binaries\Win64\BMF-Backups\BMF-20260604000000" `
  -OutJson .\artifacts\local\rollback-bmf.json
```

Remove BMF without restoring an earlier backup:

```powershell
.\installer\uninstall-bmf.ps1 `
  -ServerWin64Dir "C:\Path\To\Brickadia\Binaries\Win64" `
  -OutJson .\artifacts\local\remove-bmf.json
```

Remove-only uninstall still backs up the removed `Mods/BMF` directory under
`BMF-Backups\BMF-removed-<timestamp>`.

## Validation

The installer has a temp-directory canary that does not touch the real server:

```powershell
.\scripts\validate-windows-installer.ps1 `
  -OutJson .\artifacts\local\windows-installer-canary.json
```

It creates a fake `Binaries\Win64` directory, seeds a preexisting `Mods/BMF`,
validates backup replacement, validates rollback, then validates remove-only
uninstall.

## Manual Install Shape

1. Stop the dedicated server.
2. Install or select the BMF-supported Omegga Windows fork.
3. Install UE4SS for the Brickadia server build through that runtime or the BMF
   installer path.
4. Copy `framework/ue4ss/Mods/BMF` into the UE4SS `Mods` folder.
5. Set `brickadiaSavedDir` in `Mods/BMF/config.json` when BMF should patch
   server files such as `Saved/Server/RoleSetup2.json`.
6. Install `packages/omegga-plugins/bmf-player-sync` when Omegga-fed player
   records are desired.
7. Install `packages/omegga-plugins/bmf-minigame-events` when CityRPG or another
   plugin needs legacy-compatible minigame events from BMF.
8. Confirm `Mods/BMF/enabled.txt` exists.
9. Start the server.
10. Check `Mods/BMF/runtime/status.json`.

Do not install BMF into a running server. Runtime DLLs and mod files can be
locked or partially loaded.
