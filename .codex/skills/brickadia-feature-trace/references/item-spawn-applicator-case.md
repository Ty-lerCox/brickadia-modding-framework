# ItemSpawn Applicator Case

Use this case when tracing Brickadia applicator components, item spawning, native UFunction hooks, or permission boundaries.

## Target

Block players from applying the SpawnItem/ItemSpawn component while preserving normal Applicator use.

The important product boundary was not "disable Applicator." It was "allow the Applicator, deny only the spawn-item component path."

## Discovery Chain

1. The project TODO pointed at "applicator permission discovery" before implementation.
2. Role-file policy showed `BR.Permission.SpawnItems` could be denied while other applicator behavior remained conceptually allowed.
3. BMF gained a Lua policy decision point, `BMF.permissions.evaluateApplicatorComponentAccess()`, plus the `NoSpawnItemApplicator` example plugin and `bmf.nospawnitem.*` commands.
4. That Lua/plugin layer was policy-ready but not live-enforced because it did not yet intercept Brickadia's component application call.
5. Broad artifact/reflection scanning did not produce a safe pure-Lua hook candidate. Prior notes warned that some UE4SS struct-parameter hooks were crash-prone on the active Brickadia build.
6. Runtime/native discovery identified the live `BRTool_Applicator.ServerAddComponent` `UFunction` as the apply path to detour.
7. The native blocker needed live pointers for:
   - `function=`: `BRTool_Applicator.ServerAddComponent` `UFunction` object.
   - `denied_component=`: live Brickadia component type object for `ItemSpawn`.
   - `allowed_context=`: applicator/tool context for an allowed player, later handled by BMF proactive priming.
8. Those values were process-local runtime addresses, so a repeatable per-server discovery/injection step was needed after every restart.

## Search Anchors

Use these names when continuing or repeating this trace:

```text
SpawnItem
ItemSpawn
BR.Permission.SpawnItems
Applicator
BRTool_Applicator
ServerAddComponent
AddComponent
UFunction
NoSpawnItemApplicator
evaluateApplicatorComponentAccess
bmf.nospawnitem.status
bmf.nospawnitem.check
applicator-func-blocker-control.txt
```

## Lessons

Separate the desired policy from the interception mechanism. The role/Lua layer can prove what should be denied, but the native or UE4SS hook proves where Brickadia can actually be stopped.

Always validate both sides: the denied component should fail, and a non-target component should still work.

Do not preserve raw UObject/UFunction addresses as durable configuration. Preserve the discovery procedure and automate pointer refresh for the active server PID.

When reinjecting a native hook, detect whether the target function already points at the detour before patching again.
