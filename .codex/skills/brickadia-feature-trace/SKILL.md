---
name: brickadia-feature-trace
description: Trace how Brickadia implements a specific gameplay, tool, component, permission, RPC, or server-side feature using local repo artifacts, BMF/Omegga/UE4SS evidence, runtime probes, and live validation. Use when Codex needs to discover where a feature is handled, find a safe hook or mutation point, distinguish policy-only enforcement from live interception, or turn reverse-engineering findings into a validated implementation plan for Brickadia/BMF work.
---

# Brickadia Feature Trace

## Overview

Use this skill for discovery before implementation. The goal is to move from a user-visible Brickadia behavior to evidence-backed names, call paths, policy keys, hook candidates, runtime addresses, and validation steps.

For the ItemSpawn/applicator example, read `references/item-spawn-applicator-case.md` when the task touches applicator components, spawn item permissions, native function pointers, or when a concrete example would clarify the workflow.

## Workflow

1. Frame the exact behavior.
   - State the feature, the desired change, and the behavior that must remain allowed.
   - Write the success condition in game terms first, then translate it into code terms.
   - Keep the server-side/client-side boundary explicit. Most BMF work should stay server-side unless the user says otherwise.

2. Build an evidence map before editing.
   - Search the active repo first with `rg`; include sibling BMF/Omegga roots when present.
   - Search TODOs, docs, manifests, examples, scripts, bridge helpers, UE4SS dumps/logs, generated SDK/reflection output, and native hook helpers.
   - Record exact filenames, symbols, command outputs, process IDs, and runtime addresses that support the hypothesis.

3. Use a synonym ladder.
   - Start with the user's words: `item spawn`, `applicator`, `component`, `permission`, `tool`.
   - Try Brickadia-style names: `SpawnItem`, `ItemSpawn`, `BR.Permission.SpawnItems`.
   - Try engine/API shapes: `AddComponent`, `ServerAddComponent`, `UFunction`, `RPC`, `ComponentClass`, `RoleSetup`.
   - Try owning classes and tools discovered along the way, such as `BRTool_Applicator`.

4. Separate policy from interception.
   - A role key, Lua evaluator, or config mutation can prove policy intent.
   - A cancellable RPC, UFunction, UObject method, native detour, or safe UE4SS hook is required for live interception.
   - If only policy is proven, say "policy-ready, not live-enforced" and preserve a clear hook TODO.

5. Validate each layer.
   - Static: prove names exist in source, docs, dumps, or generated artifacts.
   - Headless: add or run focused validators when BMF Lua/framework behavior changes.
   - Live: query BMF/bridge status, confirm the server PID, refresh volatile addresses after restart, and verify allowed and denied cases.
   - Use `brickadia-client-join` when a local client must reconnect. Use `llm-request-box` only when the user must perform a concrete in-game action.

6. Treat runtime pointers as volatile.
   - UObject/UFunction addresses move across server restarts.
   - When a hook needs addresses, document the discovery command and automate refresh rather than storing a stale value.
   - Verify an existing hook before reinjecting so repeated runs do not stack detours.

7. Finish with a narrow result.
   - If a hook is found, provide the hook name/object, why it is safe enough, the validation evidence, and the smallest implementation slice.
   - If no safe hook is found, provide the strongest boundary reached, rejected candidates, and the next concrete trace step.
   - Do not bury uncertainty. Label assumptions, unproven links, and live-test gaps.

## Search Starters

Use these as starting points, then adapt to the discovered names:

```powershell
rg -n -i "spawnitem|itemspawn|applicator|addcomponent|serveraddcomponent|component" .
rg -n "BR\.Permission|SpawnItems|RoleSetup|UFunction|RPC" .
rg -n -i "hook|detour|native|bridge|ue4ss|reflection|dump" .
```

When a sibling BMF repo exists, search it too:

```powershell
rg -n -i "spawnitem|itemspawn|applicator|serveraddcomponent" C:\Users\tycox\OneDrive\Documents\GitHub\bmf
```

## Output Shape

Keep discovery reports short and evidence-first:

```text
Target:
Preserve:
Evidence:
Hypothesis:
Validation:
Hook or boundary:
Next implementation slice:
Risks:
```
