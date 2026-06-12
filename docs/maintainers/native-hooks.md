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

Player and role decisions remain owned by `examples/NoSpawnItemApplicator`,
which can write allowed contexts back into the native control file when policy
permits a retry.

## Interactable Prefix Guard

The Interactable prefix guard blocks denied Print-to-Console tags at save time.
Refresh it after restart:

```powershell
.\scripts\sync-interact-prefix-guard-native-hook.ps1
```

`examples/InteractConsolePrefixGuard` owns whitelisted prefixes, allowed
contexts, denial mode, and feedback event paths.

## Runtime Brick State

Runtime brick state mutation is a native control path, not a general tag
resolver. Callers must provide an explicit live runtime brick id candidate, and
BMF native code validates the internal runtime id before applying visibility or
collision changes.

See [Runtime Brick State](../api/runtime-bricks.md) for caller rules and
[Observability and Performance](../architecture/observability-performance.md)
for frame-time requirements.

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
