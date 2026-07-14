---
name: brickadia-permission-policy
description: Inspect, model, patch, and validate Brickadia role files and permission policies used by BMF/Omegga server-side mods. Use when Codex needs Brickadia permission keys, inherited denial, default/named role behavior, owner or bypass analysis, RoleSetup file mutation, SpawnItems/Applicator policy checks, or proof that role-file enforcement matches a desired gameplay restriction.
---

# Brickadia Permission Policy

## Overview

Use this skill when a feature depends on Brickadia roles or permissions. Treat role-file policy as an important layer, but do not confuse it with live interception of a gameplay action unless the live server proves that connection.

## Workflow

1. State the policy target.
   - Name the gameplay permission being allowed or denied.
   - State what must remain allowed.
   - Identify whether owners/admins/bypass roles are in scope.

2. Locate role data.
   - Find the active Brickadia saved-dir used by the current server.
   - For Omegga-managed servers, verify the saved-dir path through BMF/Omegga config instead of guessing.
   - Inspect default and named role files before patching.

3. Model inheritance.
   - Check default role permissions first.
   - Treat named roles as compliant when they inherit a denial and do not explicitly re-allow the forbidden permission.
   - Flag explicit allows that override the intended denial.

4. Patch conservatively.
   - Preserve unknown keys and formatting where practical.
   - Make idempotent changes and report `changed=false` when the policy is already compliant.
   - Keep policy patches separate from native/Lua hook implementation.

5. Validate both policy and behavior.
   - Add headless tests for normalized role files and inherited denial.
   - Expose BMF commands that report whether a component or permission is allowed.
   - Live-test if the user-facing behavior depends on Brickadia enforcing the role key at runtime.

## Common Anchors

```text
BR.Permission.SpawnItems
RoleSetup
default role
named roles
inherited denial
explicit allow
NoSpawnItemApplicator
evaluateApplicatorComponentAccess
```

## Report Format

```text
Permission:
Desired policy:
Active role files:
Inheritance result:
Patch result:
Validation:
Live enforcement boundary:
```
