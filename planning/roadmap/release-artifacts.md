# Release Artifacts

BMF Desktop should be distributed as a normal Windows desktop application and
as a portable first-run tool. The portable exe is the fastest path for a server
operator to target an existing Brickadia Dedicated Server folder; the MSI is
the normal installed-app path.

## Goal

A server operator should be able to:

1. Download the latest BMF Desktop portable exe or MSI.
2. Run the portable exe or install the MSI on Windows.
3. Open BMF Desktop.
4. Select a Brickadia Dedicated Server folder.
5. Use the app to install or update the BMF/Omegga/UE4SS/Grafana Alloy stack.

The user should not need to clone the repository, install Node, build native
modules, or run PowerShell scripts manually for the normal path.

## Primary Artifacts

| Artifact | Purpose |
| --- | --- |
| `BMF-Desktop-<version>-x64.msi` | Main installer for Windows users. |
| `BMF-Desktop-<version>-x64.msi.sha256` | Checksum for verification. |
| `BMF-Desktop-<version>-portable-x64.exe` | Portable app for handing to a Windows server operator. |
| `BMF-Desktop-<version>-portable-x64.exe.sha256` | Portable checksum for verification. |
| `release-manifest.json` | Machine-readable version, component, checksum, and compatibility metadata. |
| `release-catalog.json` | Machine-readable latest-release index for desktop and CLI update checks. |
| `RELEASE_NOTES.md` | Human-readable supported build, changes, and known issues. |

`.github/workflows/unified-runtime.yml` includes a manual/tagged
`desktop-release` job that runs `npm run release:desktop` and uploads the generated
MSI, portable exe, checksums, release manifest, release catalog, and release notes from
`artifacts/local/bmf-desktop-release`.

## Current Seed

The repo now distinguishes two release lanes:

| Lane | Script | Output |
| --- | --- | --- |
| Source package | `scripts/build-release-package.ps1` | `bmf-<version>.zip` for maintainers and validation. |
| Desktop app release | `scripts/build-bmf-desktop-release.ps1 -BuildMsi -BuildPortable` | MSI, portable exe, checksums, `release-manifest.json`, `release-catalog.json`, and `RELEASE_NOTES.md`. |

For the normal release path, install desktop dependencies with
`npm --prefix apps/bmf-desktop ci`, then run
`scripts/build-bmf-desktop-release.ps1 -BuildMsi -BuildPortable -Force`. The
script validates the selected Node executable, builds the Angular renderer,
invokes electron-builder's MSI and portable targets, and then emits the release
metadata. It requires Node `22.22.3+`, `24.15.0+`, or `26+`; pass `-NodeExe` or set
`BMF_DESKTOP_NODE_EXE` when the default `node` on `PATH` is older.

The script can still accept an existing MSI through `-MsiPath` and an existing
portable exe through `-PortablePath` when packaging metadata for externally
produced artifacts. The validator `scripts/validate-bmf-desktop-release.ps1`
uses small fixture files so package validation can prove the manifest and
checksum contract without rebuilding desktop artifacts.

Pass `-DownloadBaseUrl` to `scripts/build-bmf-desktop-release.ps1` when
publishing artifacts so `release-catalog.json` can point BMF Desktop and
`bmfctl` at release artifacts for the download-only update and verified installer
handoff flow.

## MSI Responsibilities

The MSI should install:

- BMF Desktop Electron application;
- bundled orchestration core;
- bundled `bmfctl` CLI or CLI shim;
- default component manifests;
- standard Grafana dashboard JSON;
- default Alloy config templates;
- documentation links and troubleshooting entry points.

Current seed: `electron-builder.yml` packages the self-contained read-side BMF
asset tree into `resources/bmf`, including manifests, `bmfctl`,
orchestrator-core package boundary files, UE4SS mod assets, native helper
package boundaries, the synced BMF-compatible Omegga runtime source, generic
Omegga adapters, compatibility metadata, and observability assets. BMF Desktop
defaults to those bundled assets when no source checkout is selected, while
generated profile state, journals, service logs, updates, dashboard payloads,
and snapshots default to Electron `userData`.

Current seed: the MSI resource tree also includes
`resources/bmf/bin/bmfctl.cmd`. The shim launches the bundled CLI through the
installed Electron executable with `ELECTRON_RUN_AS_NODE=1`, points `BMF_ROOT`
at `resources/bmf`, and defaults CLI profile, transaction, service, update, and
snapshot output to `%APPDATA%\BMF Desktop`.

The MSI should not install a Brickadia server automatically. BMF Desktop should
perform server, Omegga, UE4SS, BMF, native mod, adapter, and Alloy deployment
through explicit first-run actions after the user chooses a server profile.

## Release Manifest

The release manifest should include:

- BMF Desktop version;
- BMF runtime version;
- BMF-compatible Omegga runtime version or commit;
- supported Brickadia build;
- UE4SS bundle id;
- native mod versions and hashes;
- standard dashboard version;
- minimum Windows version;
- installer hash;
- portable exe hash;
- release catalog path;
- release channel.

The app should use the manifest to identify stale components and to decide
which update actions are safe.

The release catalog should point at the latest release for a channel and carry
the guardrails the app must honor before offering an update: verify SHA256,
require explicit user confirmation, keep desktop updates separate from managed
server component updates, and avoid stopping managed services without
confirmation. The shared orchestration core now exposes a read-only update
check over this catalog, with `bmfctl update check` and BMF Desktop using the
same contract before installer actions. It also exposes a download-only plan,
confirmed MSI download path, and verified installer handoff plan. The installer
handoff requires `--confirm install` or the equivalent Desktop confirmation,
launches only the MSI after SHA256 verification, and does not stop managed
services or update managed server components.

Current seed: `packages/orchestrator-core/src/transactions.js` provides the
first safe component-update primitive. It keeps transactions dry-run by
default, validates target roots, verifies `release-catalog.json` plus
`release-manifest.json` checksums before managed stack updates, snapshots the
current component state into `component-update-snapshot.json`, backs up
overwritten paths, writes an applied journal, previews rollback from the
journal, and can apply rollback with an explicit `--confirm rollback` gate. It
covers local file staging and config writes, including copying
`packages/omegga-runtime/source` into the selected writable Omegga runtime
path, writing `Start-BrickadiaOmegga.ps1` for first-run dependency
bootstrap/build/start, and then adding bundled bridge and adapter plugins.
The same runner now covers `repair-stack` by recording pre/post health
snapshots, writing a mutable-file snapshot before changes, repairing the
generated start script, restoring missing runtime/plugin files, and rewriting
UE4SS enablement files after runtime copy.
Process lifecycle and external API calls remain explicit future steps. BMF
Desktop now exposes the same journal-driven rollback preview and confirmed
rollback flow through Electron IPC.

## Signing And Verification

Preferred release posture:

- code-sign the MSI when a signing certificate is available;
- publish SHA256 checksums for every artifact;
- verify downloaded component artifacts before install;
- show publisher, version, and install path in the app's About view.

If signing is not available in early releases, checksums and clear release
notes are still required.

## Update Flow

BMF Desktop should eventually support self-update or guided update:

- check release manifest;
- compare installed desktop and component versions;
- download the MSI or component package;
- verify hash/signature;
- hand the verified desktop MSI to Windows Installer only after explicit user
  confirmation;
- close running managed services only after user confirmation;
- apply update;
- run doctor checks after update;
- preserve and execute rollback data for component installs.

Desktop app updates and managed server component updates should be separate
actions. Updating BMF Desktop should not silently replace a running server
stack.
