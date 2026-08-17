# Native Hook Notes

Native hooks are maintainer-owned implementation details. API pages should link
here instead of documenting pointer scans, process-local refresh behavior, or
hook sync scripts inline.

## Who Should Read This?

BMF maintainers should use this page when refreshing or validating native hook
paths. Plugin authors should prefer the Lua policy APIs and example plugins
unless they are explicitly working on hook infrastructure.

## Operating Rules

- Treat native hooks as per-build and per-process.
- Refresh hook pointers after every Brickadia server restart.
- Keep hook code focused on capture, cancellation, and handoff.
- Keep gameplay policy in BMF Lua or plugins.
- Record `L6 Frame Time` evidence before promoting native mutation into normal
  gameplay.

Current `Release-EA3-CL-15565` live-confirmed hotfix mapping:

- `/Script/Brickadia.BRTool_Applicator:ServerAddComponent`: `0x62AB0A0`
  (`FunctionFlags=0x4220CC0`, `2` parameters, `ParmsSize=0x10`)

The mapping was derived by a relocation-aware semantic match against the
preserved CL15526 executable. All twenty-five neighboring functions matched
exactly after relocation normalization; the next-best candidates matched only
nine. The live CL15565 process then returned
one exact `/Script/Brickadia.BRTool_Applicator:ServerAddComponent` UFunction
with the expected flags, parameter ABI, native slot, and original implementation
at module RVA `0x62AB0A0`. The exact-build native blocker was installed only
after its reflected identity and `SpawnItem` deny/`Light` allow policy canaries
passed.

Prior `Release-EA3-CL-15526` live-confirmed hotfix mapping:

- `/Script/Brickadia.BRTool_Applicator:ServerAddComponent`: `0x62A5450`
  (`FunctionFlags=0x4220CC0`, `2` parameters, `ParmsSize=0x10`)

The CL15526 process returned one exact UFunction and the installed blocker
emitted a live `ItemSpawnDenied` event. This mapping is historical evidence and
must not be applied to CL15565.

Prior `Release-EA3-CL-15447` live-reflected RPC exec-thunk mappings:

- `/Script/Brickadia.BRTool_Applicator:ServerAddComponent`: `0x62937B0`
  (`2` parameters, `ParmsSize=0x10`)
- `/Script/Brickadia.BRTool_Applicator:ServerModifyComponentV3`: `0x6294A90`
  (`3` parameters, `ParmsSize=0x40`)
- `/Script/Brickadia.BRCharacter:ServerMaybeStartInteract`: `0x6AA5B60`
  (`3` parameters, `ParmsSize=0xA`)
- `/Script/Brickadia.BRCharacter:ServerStopAnyInteract`: `0x6AA7450`
  (`0` parameters, `ParmsSize=0x0`)

All four mappings were unique and confirmed against the live CL15447 module.
The old `ServerModifyComponent` and `ServerInteract` names return no live hits.
The two `BRCharacter` RPCs are discovery evidence, not drop-in replacements for
the removed Interact hook. Keep the ModifyV3 and interaction guards disabled
until their owner, parameter layout, and cancellation semantics are adapted and
canary-tested.

These values are build-specific and must be re-derived after a server update.

## Applicator Blocker

The experimental `NoSpawnItemApplicator` live blocker depends on Brickadia
runtime pointers that move on every server restart. With the BMF-supported
Omegga Windows fork already running, refresh and install the blocker with:

```powershell
.\scripts\sync-applicator-blocker-native-hook.ps1
```

The sync script asks BMF for the current `ItemSpawn` component pointer, scans
the running server for the Applicator component-add function, updates the native
control file, builds/injects the native DLL if needed, and skips reinjection
when the hook is already installed in that process.

The CL15565 default RVA and automatic synchronization are active in the
production supervisor after the exact-build identity and denial canary passed.
Placement synchronization remains independently disabled.

Player and role decisions remain owned by
`framework/ue4ss/Mods/BMF/plugins/NoSpawnItemApplicator`,
which can write allowed contexts back into the native control file when policy
permits a retry.

## Interactable Prefix Guard

The Interactable prefix guard blocks denied Print-to-Console tags at save time.
Its sync command is intentionally fail-closed on CL15447:

```powershell
.\scripts\sync-interact-prefix-guard-native-hook.ps1
```

Do not supply the known ModifyV3 RVA merely to bypass that guard. First adapt
the native payload decoder from the old `0x20` parameter layout to the proven
CL15447 `0x40` layout, then run negative and positive canaries before restoring
automatic synchronization.

`framework/ue4ss/Mods/BMF/plugins/InteractConsolePrefixGuard` owns whitelisted prefixes, allowed
contexts, denial mode, and feedback event paths.

## Runtime Brick State

Runtime brick state mutation is a native control path, not a general tag
resolver. Public callers should provide `uuid=<uuid> purpose=<purpose>` or a
canonical `lookup:<uuid>:<purpose>` tag; explicit live runtime brick ids are
diagnostic/cache values that BMF validates before applying visibility or
collision changes.

See [Runtime Brick State](../api/runtime-bricks.md) for caller rules and
[Observability and Performance](../architecture/observability-performance.md)
for frame-time requirements.

## CL15447 Placement Mapping Evidence

The CL15447 binary contains the following statically derived placement targets:

- PlacePrefab method block `0x82995C0`; apply body `0x68C30D0`
- PlaceBrick method block `0x8298E40`; apply body `0x68B0920`
- BasicBrick class getter `0x533B540`
- ProceduralBrick class getter `0x533C110`
- Procedural resolver `0x533D300`

These are mapping evidence only. The game now inlines the old object-reference
and primary-brick resolution, reads the primary record at `[brick+0x100]`, and
does not preserve the old placement guard's full resolver/asset contract. Keep
native placement action hooks disabled until the decoder and offsets are
redesigned and canary-tested; copying these RVAs into the old hook is unsafe.

## Where Details Belong

| Detail | Location |
| --- | --- |
| Public parameters and result codes | API reference page |
| High-level ownership and sequence flow | Architecture patterns |
| Pointer refresh, hook sync, native control files | This page |
| Per-build offsets or pointer signatures | Native source, generated control artifacts, or validation logs |
| Gameplay allow/deny rules | Lua policy API or example plugin docs |

!!! warning
    Do not copy per-build offsets into user-facing API pages. They are volatile
    reverse-engineering evidence, not public API contracts.
