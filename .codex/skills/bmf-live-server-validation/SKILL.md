---
name: bmf-live-server-validation
description: Validate BMF Lua plugins, native hooks, bridge commands, Omegga-managed installs, and Brickadia gameplay behavior against a live local server. Use when Codex needs to start or inspect a Brickadia/Omegga server, query BMF status, reconnect the local client, run allowed/denied gameplay checks, clean validation canaries, or prove a BMF change works beyond static tests.
---

# BMF Live Server Validation

## Overview

Use this skill when a BMF change must be proven on a real Brickadia server. Static and headless validation are useful, but live validation must confirm the active process, bridge path, plugin load state, and gameplay result.

## Workflow

1. Define the live proof.
   - State the exact allowed and denied cases.
   - Identify whether proof requires only BMF commands, a connected client, or a user-performed in-game action.
   - Use `llm-request-box` only for concrete actions the user must do in game.

2. Check the server state.
   - Find the active Brickadia server PID and port, usually `127.0.0.1:7777` for local validation.
   - Check related Omegga/Node launcher processes when the server is managed by Omegga.
   - Confirm the server did not silently exit before trusting bridge timeouts.

3. Find the current bridge session.
   - Locate the bridge directory that is actively receiving command/response files.
   - Do not assume an older bridge directory is still live after a restart.
   - Query BMF status before testing plugin-specific commands.

4. Validate plugin load.
   - Confirm BMF status is running, expected plugins are loaded, and plugin error count is zero.
   - Run status/check commands exposed by the plugin under test.
   - Capture the key command response values, not just "command returned."

5. Connect the client when needed.
   - Use `brickadia-client-join` to reconnect the local Steam client to `127.0.0.1:7777`.
   - Verify join through the latest Brickadia client log or BMF/Omegga player cache.
   - If player sync/role data is required, validate the Omegga-backed path, not a direct Brickadia-only launch.

6. Exercise behavior.
   - Test the denied case and one non-target allowed case.
   - For native hooks, refresh volatile pointers after every server restart before testing.
   - If a live result contradicts a BMF command result, treat the live result as the bug and trace the missing layer.

7. Clean up.
   - Remove temporary canary plugins or generated live staging artifacts when they could pollute the next run.
   - Do not stop unrelated user servers. Stop only disposable validation processes or processes that this task started and still needs to control.

## Evidence To Report

```text
Server PID/port:
Bridge session:
BMF status:
Plugin status:
Client join evidence:
Allowed case:
Denied case:
Cleanup performed:
```
