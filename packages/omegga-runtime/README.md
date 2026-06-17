# BMF-Compatible Omegga Runtime Package Boundary

This package owns the BMF-compatible Omegga runtime component in the unified
runtime manifest. The package path is `packages/omegga-runtime`, and the
runtime source is now synced into `source/` from the BMF Windows fork:

```text
https://github.com/Ty-lerCox/bmf-omegga-fork
```

The package manifest records the fork URL, upstream Omegga URL, synced fork
commit, required BMF helper surfaces, packaging guardrails, and dependency
manifest link. `sync-metadata.json` records the local sync source, copied
roots, exclusions, dirty status, and source commit evidence.

Refresh the synced source from a local fork checkout:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/sync-omegga-runtime.ps1 -Source C:\path\to\bmf-omegga-fork -Force
```

The sync script intentionally excludes `node_modules`, runtime server data,
server saves, logs, generated artifacts, and plugin deployment state.

Validation: `scripts/validate-omegga-runtime-package.ps1`.
