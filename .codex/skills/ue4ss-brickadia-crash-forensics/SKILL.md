---
name: ue4ss-brickadia-crash-forensics
description: Diagnose Brickadia server exits, UE4SS crashes, bridge timeouts, BMF Lua callback failures, and native-hook instability. Use when Codex sees a dead server process, port no longer bound, command timeout, crash folder, UE4SS log error, invalid Lua callback reference, or uncertain failure after plugin reload, native injection, or Omegga restart.
---

# UE4SS Brickadia Crash Forensics

## Overview

Use this skill when the server stops responding or exits during Brickadia/BMF/UE4SS work. Do not assume a bridge timeout means the bridge is the root cause; first separate timeout, server exit, Lua error, native hook crash, and Omegga launcher failure.

## Workflow

1. Classify the symptom.
   - Check whether the Brickadia server process is alive.
   - Check whether the expected port is still bound.
   - Check whether Omegga/Node launcher processes are alive.
   - Check whether bridge files are still updating.

2. Gather recent evidence.
   - Tail UE4SS logs, Brickadia server logs, Omegga logs, and BMF bridge responses.
   - Inspect newest Brickadia crash folders when the process exited.
   - Record timestamps so logs from stale runs are not mixed with the current crash.

3. Separate likely causes.
   - Bridge timeout with live server: wrong bridge directory, stalled worker, or command routing problem.
   - Server exited with normal-looking bridge logs: inspect crash stack and Brickadia logs.
   - UE4SS Lua stack/callback failures: audit timers, delayed callbacks, invalid function refs, and plugin reload cleanup.
   - Native hook crash: confirm injection timing, target pointer freshness, parameter handling, and duplicate detour status.
   - Omegga launch failure: inspect launcher stdout/stderr and managed install state.

4. Minimize before restart loops.
   - Disable or remove only the suspected generated plugin/hook when possible.
   - Keep a copy of the failing log/crash evidence before cleaning live folders.
   - Restart from a clean process tree when stale launchers or orphaned servers exist.

5. Validate the fix.
   - Confirm the server stays alive after BMF loads, after client join, after plugin reload, and after the feature action that previously failed.
   - Query BMF/plugin status after restart.
   - For native hooks, re-run pointer discovery for the new PID before retesting.

## Report Format

```text
Symptom:
Process/port state:
Newest relevant logs:
Crash stack clue:
Likely layer:
Fix attempted:
Post-fix validation:
Remaining risk:
```
