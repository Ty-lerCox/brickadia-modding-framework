---
name: brickadia-native-hook-lifecycle
description: Manage Brickadia native hook discovery, pointer refresh, DLL build/injection, detour safety, status verification, and restart recovery for BMF/UE4SS server-side mods. Use when Codex needs live UFunction/UObject addresses, native control files, injected blockers, per-server hook automation, crash-aware reinjection, or verification that a native hook is installed against the current Brickadia server PID.
---

# Brickadia Native Hook Lifecycle

## Overview

Use this skill when a Brickadia feature requires native/runtime interception instead of only Lua policy or role-file changes.

The recurring hazards are stale process-local pointers, wrong server PID, duplicate detours, and hooks that look installed but target an old server process.

## Workflow

1. Identify the hook contract.
   - State the Brickadia behavior being intercepted and what must still be allowed.
   - Name the candidate UObject/UFunction/class and the parameter or context that decides allow/deny.
   - Keep a Lua/BMF policy boundary separate from the native detour boundary.

2. Resolve the active server.
   - Confirm the Brickadia server process, port, and PID before scanning or injecting.
   - Treat all UObject/UFunction addresses as invalid after every server restart.
   - Verify the bridge/BMF session belongs to the same active process before trusting status.

3. Discover live targets.
   - Prefer existing BMF/Omegga helper commands or reflection dumps before raw memory scanning.
   - Record both symbolic names and live addresses, for example `BRTool_Applicator.ServerAddComponent` plus its `UFunction` pointer.
   - For denied targets, resolve the live component/class/type object, not just its string name.

4. Write control state deliberately.
   - Update the hook control file only after all required targets are resolved for the current PID.
   - Keep fields explicit: target function, denied object/class, allowed contexts, and any policy mode.
   - Avoid preserving raw addresses in committed config unless the file is clearly runtime-only.

5. Build and inject once.
   - Build the native DLL from the checked-in source or the repo helper script.
   - Use a unique output name when Windows loader caching could reuse an old DLL.
   - Before patching, detect whether the target slot already points at the detour; skip or verify instead of stacking hooks.

6. Verify installation.
   - Read the hook status file/log and confirm the reported PID matches the active server.
   - Confirm original function pointer, detour pointer, denied target, and policy fields.
   - Exercise both cases: blocked target fails, non-target behavior still works.

7. Automate repeatability.
   - If manual pointer refresh was needed, create or update a single script that performs discovery, control-file write, build/inject, and verification.
   - Make the script idempotent for an already-hooked active process.
   - Report a concrete blocked reason when discovery fails instead of injecting with partial state.

## Safety Rules

- Do not inject into an unknown or stale PID.
- Do not trust addresses copied from a previous run.
- Do not reinject blindly after a timeout; first determine whether the server exited, the bridge stalled, or the hook is already present.
- Keep native hook changes narrowly scoped and validate with live gameplay when the behavior is user-facing.

## Output Shape

```text
Target function:
Denied target:
Allowed context/policy:
Active PID:
Discovery method:
Injection result:
Verification:
Remaining risk:
```
