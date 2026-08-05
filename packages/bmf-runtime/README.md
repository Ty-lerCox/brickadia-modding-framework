# BMF Runtime Package Boundary

This package owns the BMF UE4SS Lua runtime component in the unified runtime
manifest while preserving the current install source layout:

```text
framework/ue4ss/Mods/BMF
```

The package manifest intentionally records the current source root, entrypoint,
required files, install root, and runtime outputs. `Scripts/main.lua` is the
stable UE4SS entrypoint; the implementation lives in
`Scripts/bmf/runtime.lua`. `orchestrator-core` still stages the runtime from the
existing `framework/ue4ss/Mods/BMF` path so current install scripts and live
validation stay compatible while the monorepo package layout matures.

The Omegga Windows template must carry byte-identical copies of both the loader
and `Scripts/bmf/runtime.lua`; the package build fails when either copy drifts.
The same gate compiles every runtime source with pinned Fengari Lua 5.3 before
packaging, then uses a pinned Lua AST parser to reject direct, `pcall`, alias,
and `_G["..."]` access to `ExecuteWithDelay`, `ExecuteAsync`, and `LoopAsync`.
It also rejects the process-wide `ClearAllDelayedActions` primitive. The
compiler gate catches Lua's 200-local-per-function limit, which an AST-only
syntax check does not enforce.
Check without changing files with `npm run sync:runtime-template`, then apply
the two-file sync explicitly with `npm run sync:runtime-template -- -Apply`.

Validation: `scripts/validate-bmf-runtime-packages.ps1` and
`scripts/validate-bmf-runtime-template-parity.ps1`.
