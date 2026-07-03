# Advanced Install Reference

**Labels:** `advanced`, `windows`, `installer`, `maintainer`

Use [First Install With BMF Desktop](windows.md) for normal Windows setup. This
page is for maintainers and advanced recovery.

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

`-BrickadiaSavedDir` is not required for framework boot, but is required for
file-backed server policy enforcers such as `NoSpawnItemApplicator`. It should
point at the server's `Saved` directory, not `Saved\Server`; the installer
writes that path to `Mods/BMF/config.json` as `brickadiaSavedDir`.

## Rollback Or Remove

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
2. Install or select the BMF-vendored Omegga Windows runtime.
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
