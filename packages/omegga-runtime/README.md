# BMF-Compatible Omegga Runtime Package Boundary

This package owns the BMF-compatible Omegga runtime component in the unified
runtime manifest. The package path is `packages/omegga-runtime`, and the
runtime source is vendored directly into `source/` inside the BMF repository:

```text
https://github.com/Ty-lerCox/brickadia-modding-framework
```

The package manifest records the BMF repository URL, upstream Omegga URL,
supported upstream commit/version, required BMF helper surfaces, packaging
guardrails, and dependency manifest link. `sync-metadata.json` records the
local sync source, copied roots, exclusions, dirty status, and commit evidence.

Upstream Omegga is tracked from:

```text
https://github.com/brickadia-community/omegga
```

Refresh the vendored source from a local Omegga-compatible checkout:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/sync-omegga-runtime.ps1 -Source C:\path\to\omegga -UpstreamCommit <sha> -UpstreamVersion <version> -Force
```

The sync script intentionally excludes `node_modules`, runtime server data,
server saves, logs, generated artifacts, and plugin deployment state.

Validation: `scripts/validate-omegga-runtime-package.ps1`.
