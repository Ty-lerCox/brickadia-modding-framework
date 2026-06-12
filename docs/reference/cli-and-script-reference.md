# CLI And Script Reference

This page centralizes local CLI and script entry points so API pages can focus
on runtime contracts.

## Who Should Read This?

Maintainers should use this page when running validation, staging assets, or
building native helpers. Server operators should use the install and release
sections when checking a deployment package.

Run commands from the repository root unless a script says otherwise.

## Manager CLI

| Task | Command |
| --- | --- |
| Run the local doctor | `node .\cli\bin\bmfctl.js doctor` |
| Validate the CLI package | `.\scripts\validate-bmfctl.ps1` |

## Package And Docs

| Task | Command |
| --- | --- |
| Validate package markers | `.\scripts\validate-package.ps1` |
| Build a release zip | `.\scripts\build-release-package.ps1 -OutDir .\artifacts\local\release -Force` |
| Validate a release zip | `.\scripts\validate-release-package.ps1` |
| Validate Windows installer behavior | `.\scripts\validate-windows-installer.ps1` |
| Validate documentation style | `python scripts\validate-docs-style.py` |
| Build docs strictly | `python -m mkdocs build --strict` |

## Server And Role Files

| Task | Script |
| --- | --- |
| Patch copied server settings | `scripts/patch-server-settings.ps1` |
| Validate server settings patching | `scripts/validate-server-settings.ps1` |
| Patch copied role permissions | `scripts/patch-role-permissions.ps1` |
| Validate role permission patching | `scripts/validate-role-permissions.ps1` |
| Patch copied role assignments | `scripts/patch-role-assignments.ps1` |
| Validate role assignments | `scripts/validate-role-assignments.ps1` |

## Runtime API Canaries

| Area | Scripts |
| --- | --- |
| Command bridge | `validate-bmf-console-commands.ps1`, `validate-bmf-admin-commands.ps1` |
| API labels | `validate-bmf-api-labels.ps1` |
| Health and compatibility | `validate-bmf-server-status.ps1`, `validate-bmf-compatibility.ps1` |
| Server save/shutdown | `validate-bmf-server-save.ps1`, `validate-bmf-server-shutdown.ps1` |
| Plugins | `validate-bmf-plugin-lifecycle-storage.ps1`, `validate-bmf-plugin-lifecycle-hooks.ps1`, `validate-bmf-plugin-watchdog.ps1`, `validate-bmf-plugin-command-cleanup.ps1` |
| Sandbox and gates | `validate-bmf-unsafe-globals.ps1`, `validate-bmf-capability-gates.ps1` |
| Timers, events, audit, logging, rate limits | `validate-bmf-timers.ps1`, `validate-bmf-events.ps1`, `validate-bmf-audit-log.ps1`, `validate-bmf-logging.ps1`, `validate-bmf-rate-limits.ps1` |
| Players | `validate-player-fixtures.ps1`, `validate-bmf-player-messaging.ps1` |
| Permissions and policy | `validate-bmf-permission-policy.ps1`, `validate-bmf-command-access-policy.ps1`, `validate-bmf-command-dispatch-access.ps1`, `validate-bmf-brick-asset-policy.ps1` |
| Minigames | `validate-bmf-minigame-commands.ps1` |

## Archive And Vehicle Tooling

| Task | Command |
| --- | --- |
| Describe one `.brdb` | `.\scripts\describe-world-archive.ps1 -InputPath <world.brdb> -OutJson <report.json>` |
| Validate known archive fixtures | `.\scripts\validate-archive-fixtures.ps1` |
| List brick assets in `.brdb` or `.brz` | `node .\scripts\list-brick-assets.js <archive> --out-json <report.json>` |
| Summarize vehicle graphs | `.\scripts\summarize-vehicle-graphs.ps1 -InputPath <world.brdb> -OutJson <snapshot.json>` |
| Export vehicle inventory | `.\scripts\export-vehicle-inventory.ps1 -InputSnapshotJson <snapshot.json> -OutJson <inventory.json> -OutMarkdown <inventory.md> -OutCsv <inventory.csv> -OutText <inventory.txt>` |
| Snapshot a running server through bridge RPC | `.\scripts\snapshot-server-vehicles.ps1 -BridgeDir <bridge-dir> -SaveName <save-name> -ExportInventory` |
| Snapshot a running server through BMF | `.\scripts\snapshot-bmf-server-vehicles.ps1 -BridgeDir <bridge-dir> -SaveName <save-name> -InventoryLabelPrefix car` |

## Prefab And Dynamic Actor Staging

| Task | Command |
| --- | --- |
| Stage one `.brz` prefab | `.\scripts\stage-brz-prefab.ps1 -InputBrz <input.brz> -OutputBrdb <output.brdb> -StageToServerWorlds -WorldName <world-name> -Force` |
| Validate BRZ prefab staging | `.\scripts\validate-brz-prefab-staging.ps1 -OutJson <canary.json>` |
| Capture one vehicle-like graph | `.\scripts\capture-dynamic-actor-graph.ps1 -InputPath <world.brdb> -GroupId <id> -OutJson <capture.json>` |
| Slice one dynamic actor graph | `node .\scripts\slice-dynamic-actor-brdb.js <input.brdb> <output.brdb> --entity-id <id> --force` |
| Validate dynamic actor slices | `.\scripts\validate-dynamic-actor-slices.ps1` |
| Validate additive slice load/save | `.\scripts\validate-dynamic-actor-slice-additive.ps1 -OutJson <canary.json>` |
| Remap staged vehicle ids | `node .\scripts\remap-staged-vehicle-brdb.js <input.brdb> <output.brdb> --entity-offset <n> --grid-offset <n> --force` |
| Stage a vehicle spawn set | `.\scripts\stage-vehicle-spawn-set.ps1 -VehicleCount 3 -WorldNamePrefix BMF_VehicleSpawnSet -StartX 70000 -StepX 2000 -LoadZ 1000 -StageToServerWorlds -OutJson <manifest.json>` |

## Vehicle Validation

| Task | Script |
| --- | --- |
| Validate saved vehicle snapshots | `validate-vehicle-snapshot.ps1` |
| Validate server vehicle snapshot | `validate-server-vehicle-snapshot.ps1` |
| Validate multi-vehicle snapshot | `validate-server-multi-vehicle-snapshot.ps1` |
| Validate remapped duplicate vehicle snapshot | `validate-server-remapped-duplicate-vehicle-snapshot.ps1` |
| Validate server vehicle spawn set | `validate-server-vehicle-spawn-set.ps1` |
| Validate BMF runtime spawn set | `validate-bmf-vehicle-spawn-set-runtime.ps1` |
| Validate BMF command spawn set | `validate-bmf-vehicle-spawn-set-command.ps1` |
| Validate BMF vehicle snapshot command | `validate-bmf-vehicle-snapshot-command.ps1` |

## Native Helper Scripts

| Task | Script |
| --- | --- |
| Build BMFSocket | `build-bmf-socket-native-mod.ps1` |
| Build frame telemetry native mod | `build-bmf-frame-telemetry-native-mod.ps1` |
| Build applicator blocker hook | `build-applicator-blocker-native-hook.ps1` |
| Inject applicator blocker hook | `inject-applicator-blocker-native-hook.ps1` |
| Refresh applicator blocker hook | `sync-applicator-blocker-native-hook.ps1` |
| Refresh Interactable prefix guard hook | `sync-interact-prefix-guard-native-hook.ps1` |
| Refresh placement guard hook | `sync-placement-guard-native-hook.ps1` |

Use [Dangerous Surfaces](dangerous-surfaces.md) and
[Native Hook Notes](../maintainers/native-hooks.md) before running native hook
scripts against a live server.
