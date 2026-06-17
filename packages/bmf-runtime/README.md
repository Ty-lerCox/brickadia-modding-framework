# BMF Runtime Package Boundary

This package owns the BMF UE4SS Lua runtime component in the unified runtime
manifest while preserving the current install source layout:

```text
framework/ue4ss/Mods/BMF
```

The package manifest intentionally records the current source root, entrypoint,
required files, install root, and runtime outputs. `orchestrator-core` still
stages the runtime from the existing `framework/ue4ss/Mods/BMF` path so current
install scripts and live validation stay compatible while the monorepo package
layout matures.

Validation: `scripts/validate-bmf-runtime-packages.ps1`.
