# First Install With BMF Desktop

**Labels:** `experimental`, `windows`, `desktop`, `installer`

The first install path for BMF is BMF Desktop in Easy mode. A server operator
should be able to download the portable app, point it at a Brickadia Dedicated
Server folder, and use the Easy-mode action buttons to install, repair, start,
or restart the required services.

Current target: Brickadia EA3.1 PC-Shipping-CL15581.

## Who Should Read This?

Server operators should use this page to set up BMF on a Windows dedicated
server with BMF Desktop. BMF maintainers should keep this page focused on the
portable Desktop flow before script or package internals.

!!! warning
    BMF's UE4SS path is Windows-only. Linux and WSL are not supported for the
    UE4SS/BMF dedicated-server runtime.

## What You Need

- Windows 10 x64, Windows 11 x64, or Windows Server 2019+ x64.
- Brickadia Dedicated Server for Brickadia EA3.1 `PC-Shipping-CL15581`.
- Required BMF-vendored Omegga Windows runtime for Windows server launch, command
  transport, bridge helpers, logs, and validation:
  <https://github.com/Ty-lerCox/brickadia-modding-framework/tree/main/packages/omegga-runtime>.
- BMF Desktop portable exe from the BMF release:
  `BMF-Desktop-<version>-portable-x64.exe`.
- File-system access to the server `Binaries\Win64` directory.

Do not assume an arbitrary upstream Omegga install is enough. See the
[Supported Runtime Matrix](../reference/supported-runtime.md) for the current
fork contract.

## Download BMF Desktop

1. Open the BMF release page:
   <https://github.com/Ty-lerCox/brickadia-modding-framework/releases>.
2. Download `BMF-Desktop-<version>-portable-x64.exe`.
3. Put the exe somewhere durable on the Windows server, such as:
   `C:\BMF\BMF-Desktop-<version>-portable-x64.exe`.
4. Keep the generated `BMF Desktop Data` folder next to the portable exe. That
   folder stores the selected profile, logs, journals, and local Desktop state.

Use the portable exe for first install. The MSI is still supported when you
want a normal installed application entry and Windows installer metadata, but
the in-app setup flow is the same.

## Target The Dedicated Server Folder

1. Stop the Brickadia Dedicated Server if it is already running.
2. Open the BMF Desktop portable exe.
3. Stay in Easy mode.
4. Click `Select Folder` or `Change Folder`.
5. Pick the Brickadia Dedicated Server install folder. You can select either:
   - the install root that contains `Brickadia\Binaries\Win64`; or
   - the final `Brickadia\Binaries\Win64` folder.
6. Confirm BMF Desktop detected:
   `BrickadiaServer-Win64-Shipping.exe`.

After selection, BMF Desktop saves a local profile for that server and refreshes
the Easy health list.

## Install Or Repair From Easy Mode

Easy mode is the first-install checklist. Start at the top and use the action
buttons that appear on unhealthy, degraded, or unknown rows.

| Easy action | What it does |
| --- | --- |
| `Install` | Stages the BMF runtime, UE4SS mod files, native helpers, Omegga bridge assets, and managed profile metadata for the selected server. |
| `Repair` | Restores missing BMF/UE4SS files, bridge files, runtime files, enablement markers, and generated launch metadata. |
| `Update` | Applies verified release evidence to refresh managed BMF/Omegga/UE4SS assets. |
| `Start` | Starts the configured BMF-supported Omegga launch path for the selected profile. |
| `Restart` | Stops the BMF-owned process for the selected profile, then starts it again. |
| `Refresh Health` | Rechecks local files, runtime status, ports, logs, and configured health evidence. |

Use this loop for first install:

1. Click `Install` on the first core row that offers it.
2. Click `Refresh Health`.
3. If a core row still reports `degraded`, `unhealthy`, or `unknown`, click its
   `Repair` action.
4. Click `Refresh Health`.
5. Click `Start` or `Restart` when Easy mode shows the stack is staged but not
   running.
6. Click `Refresh Health` again and confirm the core rows are healthy.

The first rows to care about are:

- Brickadia dedicated server files;
- UE4SS + OmeggaBridge;
- BMF runtime;
- Omegga runtime/start path;
- Omegga metrics when the server is running.

Easy mode only shows telemetry, frame-time, socket, and Grafana rows when the
profile has those features enabled or evidence exists. A clean first-run
profile should focus on the core rows first: server files, UE4SS/BMF staging,
Omegga runtime/start path, and BMF runtime status.

## When Easy Mode Is Blocked

If an Easy action is blocked, read the row detail and fix the named input
before trying again. Common blockers are:

- the selected folder does not contain `BrickadiaServer-Win64-Shipping.exe`;
- the dedicated server is still running and locking files;
- the required Omegga runtime path is missing;
- PowerShell or Node/npm is missing for the managed Omegga start path;
- a port is already owned by another process.

Use `Refresh Health` after correcting a blocker. BMF Desktop records action
journals and logs under `BMF Desktop Data` next to the portable exe.

## MSI Setup For Installed Desktop

Use the MSI when you want a normal installed application entry, Windows
installer metadata, and a stable app location. The setup flow inside the app is
the same as the portable exe: open BMF Desktop, select the Brickadia Dedicated
Server folder, then apply the Easy-mode action buttons until the core rows are
healthy.

## Advanced Recovery

First install should stay in BMF Desktop Easy mode. Maintainers can use
[Advanced Install Reference](advanced-reference.md) for release packages,
scripted install, rollback, validation canaries, and manual install shape.
