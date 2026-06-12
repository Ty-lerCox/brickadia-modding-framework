# Tool Guard Policies

**Labels:** `policy`, `experimental hooks`, `L2 Headless`, `L5 Negative`

Tool-guard APIs evaluate gameplay policy for Brickadia tools and components.
They are policy surfaces first; live enforcement still needs a safe event source
or native hook.

For hook flow, see
[Hooked Brickadia Events Into Lua](../../architecture/architecture-patterns.md#8-hooked-brickadia-events-into-lua).
For validation status, see
[API Validation Evidence](../../validation/api-validation.md#permissions).

## Who Should Read This?

Plugin authors should use this page to choose the right guard API. Server
operators should use it to understand what is policy-only versus live-enforced.
BMF maintainers should use it as the split point between Lua decisions and hook
capture.

## Policy Areas

| Need | Page |
| --- | --- |
| Deny Applicator `SpawnItem` / `ItemSpawn` components | [Applicator Policy](applicator-policy.md) |
| Limit Interactable Print-to-Console prefixes | [Interactable Tags](interactable-tags.md) |
| Limit risky brick assets by role | [Brick Assets](brick-assets.md) |

## Result Shape

Tool policies return `data.allowed` plus a machine-readable `data.decision`.
Native or adapter paths should treat policy output as the decision source and
keep hook code focused on safe capture and handoff.

!!! warning
    Do not bury hook mechanics in plugin policy. Hooks should capture the
    minimum event context, then hand policy decisions to BMF Lua.
