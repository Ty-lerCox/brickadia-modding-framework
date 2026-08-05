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

The Windows UE4SS template packages the canonical BMF loader plus
`Scripts/bmf/runtime.lua`. Both files must remain byte-identical to the copies
under `framework/ue4ss/Mods/BMF`; `package:bmf` refuses to package drifted
templates.
The parity validator compiles each BMF and OmeggaBridge runtime with pinned
Fengari Lua 5.3, then rejects direct, `pcall`, alias, and `_G["..."]` access to
`ExecuteWithDelay`, `ExecuteAsync`, and `LoopAsync`. It also rejects the
process-wide `ClearAllDelayedActions` primitive. The compiler regression test
specifically verifies Lua's 200-local-per-function limit, which an AST-only
syntax parser misses. A sibling development copy can be included locally with
`-AdditionalLuaPath`; release validation does not depend on an external
checkout.
Check without changing files with `npm run sync:runtime-template`, then apply
the two-file sync explicitly with `npm run sync:runtime-template -- -Apply`.

Validation: `scripts/validate-omegga-runtime-package.ps1` and
`scripts/validate-bmf-runtime-template-parity.ps1`.
