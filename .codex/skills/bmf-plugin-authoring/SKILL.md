---
name: bmf-plugin-authoring
description: Create, evolve, package, document, and validate BMF Lua plugins for Brickadia server-side mods. Use when Codex needs a BMF plugin folder, bmf.json metadata, config defaults, command registration, status/check commands, policy evaluators, live-hook entry points, headless canaries, docs/manifests updates, or cleanup of generated validation plugins.
---

# BMF Plugin Authoring

## Overview

Use this skill when building or changing a BMF Lua plugin. Keep plugins small, observable, and explicit about whether they are policy-ready, live-enforced, or waiting for a discovered hook.

## Workflow

1. Define the plugin contract.
   - State the gameplay behavior, config knobs, commands, and validation cases.
   - Keep reusable framework APIs in BMF core when multiple plugins will need them.
   - Keep plugin-specific policy and presentation in the example/plugin folder.

2. Build the plugin shape.
   - Provide `bmf.json` metadata and `main.lua`.
   - Add `config.json` only when there are meaningful defaults.
   - Register clear commands such as `*.status`, `*.check`, or `*.enforce` for validation and support.

3. Make behavior observable.
   - Status output should include loaded config, policy mode, counters, last error/reason, and active hook/bridge state when relevant.
   - Check commands should support one positive and one negative case without requiring manual gameplay.
   - Avoid silent success for partial enforcement.

4. Separate policy and live hooks.
   - Name future hook entry points explicitly, for example `onApplicatorComponentApply`.
   - If the hook is not wired, say "policy-ready, not live-enforced" in code comments, docs, and final status.
   - Do not pretend a role/file evaluator cancels a Brickadia RPC unless live validation proves it.

5. Add focused validation.
   - Extend existing PowerShell validators when possible.
   - Stage the real plugin in a disposable validation runtime rather than validating only synthetic canaries.
   - Test command registration, status output, and allowed/denied checks.

6. Package and document narrowly.
   - Update manifests/docs only for the actual exposed API or plugin behavior.
   - Keep wording conservative about live enforcement boundaries.
   - Clean generated canary plugins from shared UE4SS runtime folders after tests.

## Output Shape

```text
Plugin:
Commands:
Config:
Framework APIs touched:
Enforcement level:
Validators:
Live validation:
Cleanup:
```
