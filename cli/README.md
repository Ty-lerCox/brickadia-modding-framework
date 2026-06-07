# bmfctl

`bmfctl` is the CLI manager and troubleshooting tool for BMF environments.

It is intentionally CLI-first and dependency-free. The first release focuses on
diagnosing existing installs, collecting troubleshooting snapshots, and safely
repairing common UE4SS mod enablement problems.

## Commands

```powershell
node .\cli\bin\bmfctl.js doctor
node .\cli\bin\bmfctl.js doctor --json
node .\cli\bin\bmfctl.js doctor --fix --dry-run
node .\cli\bin\bmfctl.js repair bmf.enable
node .\cli\bin\bmfctl.js snapshot
node .\cli\bin\bmfctl.js mods list
node .\cli\bin\bmfctl.js mods enable BMF
```

Common path overrides:

```powershell
node .\cli\bin\bmfctl.js doctor `
  --omegga C:\path\to\omegga `
  --game-win64 C:\path\to\Brickadia\Binaries\Win64 `
  --compat-root C:\path\to\brickadia-ue4ss-re
```

## Doctor

`doctor` checks the layers that usually break BMF installs:

- BMF repo/package files.
- BMF-compatible Omegga runtime and Windows UE4SS template.
- Brickadia UE4SS compatibility bundle manifests.
- Live `dwmapi.dll`/UE4SS `Mods` directories.
- `BMF` and `OmeggaBridge` folders plus `mods.txt`/`mods.json` enablement.
- UE4SS log failure signals.
- Omegga bridge runtime status files.

Findings include severity, evidence, next action, and repair command when a safe
repair is available.

## Repairs

Repairs support `--dry-run` and create backups before changing files.

Available repair IDs:

- `bmf.enable`
- `bmf.copy`
- `bridge.enable`
- `bridge.copy`
- `all`

Repair logs and backups are written under `artifacts/bmfctl/`.

## Snapshots

`snapshot` writes a troubleshooting folder containing:

- `doctor.json`
- `snapshot.json`
- selected BMF/Omegga/UE4SS config and manifest files
- tailed logs, not full logs

The default output path is `artifacts/bmfctl/snapshots/<timestamp>/`.
