---
name: omegga-bmf-provisioning
description: Provision, repair, and verify BMF inside Omegga-managed Brickadia servers and UE4SS installs. Use when Codex needs to stage BMF for Omegga, set OMEGGA_BMF_SOURCE_DIR, preserve Brickadia saved-dir config, repair mods.txt/mods.json, resolve live versus template UE4SS paths, or diagnose cases where BMF files exist but are not enabled or loaded.
---

# Omegga BMF Provisioning

## Overview

Use this skill when Omegga is responsible for launching Brickadia and the task depends on BMF being installed, enabled, and configured in the managed UE4SS tree.

The common failure is a partial live install: a BMF folder exists, but Omegga or the UE4SS template did not enable or copy the complete mod payload.

## Workflow

1. Identify the install layers.
   - Source: the BMF repo or framework folder being developed.
   - Staging: any generated `artifacts/local/.../BMF` copy used for live testing.
   - Template: the Omegga/UE4SS template that is copied into managed servers.
   - Live: the active `Mods` folder used by the currently running Brickadia process.

2. Prefer managed provisioning.
   - Use `OMEGGA_BMF_SOURCE_DIR` when Omegga supports optional BMF installation.
   - Avoid hand-patching the live install as the durable fix; it is acceptable only for immediate diagnosis.
   - If examples/plugins are test-only, stage them in a generated copy rather than polluting framework source.

3. Preserve configuration.
   - Carry forward required `config.json` values such as `brickadiaSavedDir`.
   - Ensure the saved-dir path points at the Omegga-managed Brickadia data actually used by the server.
   - Do not overwrite local secrets or user-specific paths unless the task requires it.

4. Verify enabled state.
   - Check both file presence and UE4SS enablement files such as `mods.txt` or `mods.json`.
   - Confirm the live BMF folder includes required entry files, runtime, scripts, config, manifests, and plugin folders.
   - Read UE4SS/BMF logs or bridge status to prove the mod started.

5. Restart deliberately.
   - Stop stale Omegga/Brickadia process trees that belong to the test server before provisioning.
   - Start Omegga with explicit environment and logs when previous attempts failed silently.
   - After restart, locate the new bridge session and query BMF instead of assuming the old session is valid.

6. Report the durable fix.
   - Say whether the fix was source, staging, template, live install, or launch environment.
   - If only live files were patched, call that out as non-durable.

## Checks

```text
OMEGGA_BMF_SOURCE_DIR:
Template Mods path:
Live Mods path:
mods.txt/mods.json state:
BMF config path:
Bridge session:
BMF loaded:
```
