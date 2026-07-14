---
name: bmf-live-command-canary
description: Use when adding, updating, or running the opt-in BMF/Omegga live command canary that starts Brickadia/Omegga test mode, fires safe command probes, and proves UE4SS/BMF command routing does not crash the dedicated server.
---

# BMF Live Command Canary

## Overview

Use this skill to run or evolve the live command canary for Brickadia/BMF/Omegga after engine upgrades, UE4SS fixes, command routing changes, chat-command rewrites, bridge changes, or crash regressions. The goal is not broad gameplay automation; it is a bounded startup canary that fires known-safe probes and fails loudly if the server dies, the BMF bridge drops, or command paths regress.

When this work involves a live server or code changes, also follow `bmf-live-server-validation` and `bmf-performance-guardrails`.

## Code Locations

- Live Omegga checkout: `C:\Users\tycox\OneDrive\Documents\GitHub\Brickadia\omegga-master\omegga-master`
- BMF vendored Omegga source: `C:\Users\tycox\OneDrive\Documents\GitHub\bmf\packages\omegga-runtime\source`
- Canary module: `src\validation\liveCommandCanary.ts`
- Canary tests: `src\validation\liveCommandCanary.test.ts`
- Startup wiring: `src\main.ts`

Keep the live checkout and vendored BMF copy behaviorally aligned unless the user explicitly wants a one-sided experiment.

## Run Workflow

1. Check whether another Codex thread or live migration is actively using the server. Do not restart Omegga or Brickadia while another UE4SS/BMF migration thread is depending on the current process unless the user asked for that interruption.
2. Confirm the Omegga process is being started fresh. The current canary is a startup hook enabled by environment variables; it does not attach to an already-running Omegga process.
3. Start from the live Omegga checkout unless the user specifically asks to test the vendored BMF package.
4. Set the canary environment variables in the same PowerShell session that starts Omegga.
5. Start Omegga, wait for the canary report, and inspect server liveness, BMF status, UE4SS logs, and the JSON report before declaring success.

PowerShell startup:

```powershell
cd C:\Users\tycox\OneDrive\Documents\GitHub\Brickadia\omegga-master\omegga-master
$env:OMEGGA_LIVE_COMMAND_CANARY='1'
$env:OMEGGA_LIVE_COMMAND_CANARY_FAIL_FAST='1'
$env:OMEGGA_LIVE_COMMAND_CANARY_PLAYER='Ty'
$env:OMEGGA_LIVE_COMMAND_CANARY_BASELINE_MS='30000'
npm start
```

Useful optional variables:

- `OMEGGA_LIVE_COMMAND_CANARY_PLAYER`: player name used by whisper/status-message probes. Prefer `Ty` for this machine when the local client is connected.
- `OMEGGA_LIVE_COMMAND_CANARY_FAIL_FAST`: set to `1` when the canary should stop Omegga and exit nonzero on the first failure.
- `OMEGGA_LIVE_COMMAND_CANARY_BASELINE_MS`: startup settle window before probes, default `30000`.
- `OMEGGA_LIVE_COMMAND_CANARY_SPACING_MS`: delay between probes, default `500`.
- `OMEGGA_LIVE_COMMAND_CANARY_START_TIMEOUT_MS`: timeout for Omegga start, default `60000`.
- `OMEGGA_LIVE_COMMAND_CANARY_METRICS_URL`: Prometheus metrics endpoint if not using the default local target.
- `OMEGGA_LIVE_COMMAND_CANARY_REPORT`: explicit JSON report path. Default is `artifacts\live-command-canary-latest.json`.

## Default Probe Matrix

The canary should remain a small, high-signal matrix. Current expected coverage:

- Legacy typed chat command: `Chat.Broadcast`
- Current `br.` typed chat command: `br.Chat.Broadcast`
- Legacy whisper path: `Chat.Whisper "Ty" ...`
- Current whisper path: `br.Chat.Whisper "Ty" ...`
- Current status-message path: `br.Chat.StatusMessage "Ty" ...`
- Omegga API broadcast helper
- Omegga API whisper helper
- Read-only Windows control output: `GetAll BRPlayerState UserName`
- BMF bridge command: `Omegga.Bridge.BMF bmf.status`

Every probe must perform a health check after execution. A probe is not complete just because the command call returned.

## Safety Rules

Only add commands that are safe for a disposable live validation pass. Keep the denylist and tests updated with every expansion.

Never live-fire these command classes from the canary:

- `exit` or `quit`
- `ServerTravel`
- `Server.Shutdown` or `br.Server.Shutdown`
- world load/save commands such as `BR.World.Load`, `br.BR.World.Load`, `BR.World.SaveAs`
- brick clearing or loading commands such as `Bricks.Clear`, `br.Bricks.Clear`, `Bricks.Load`

Guardrails for new probes:

- Add one command family at a time.
- Prefer read-only or chat/status commands over world-mutating behavior.
- Use batching and spacing; do not create a continuous polling loop.
- Keep all probes opt-in behind `OMEGGA_LIVE_COMMAND_CANARY=1`.
- Add unit tests proving dangerous commands are rejected and expected safe commands are allowed.
- If a probe depends on a connected player, make that dependency explicit in the report and failure message.

## Static Validation

From the live Omegga checkout, run:

```powershell
npx vitest --config vitest.backend.config.mts --run src/validation/liveCommandCanary.test.ts src/windows.test.ts
npm run build
npx prettier --check src/main.ts src/validation/liveCommandCanary.ts src/validation/liveCommandCanary.test.ts
git diff --check -- src/main.ts src/validation/liveCommandCanary.ts src/validation/liveCommandCanary.test.ts
```

For the vendored BMF source, at minimum run Prettier and `git diff --check` on the mirrored files. Do not install dependencies or perform broad package churn just to build the vendored source unless the user asks or the repository already has the needed dependency state.

## Passing Evidence

Report the result in terms of observable evidence, not intent. A passing canary requires:

- Omegga finished startup and did not enter stopping state during the probe sweep.
- Brickadia dedicated server process and UDP `7777` remain alive.
- Omegga web/API port remains available if it was expected for the run.
- The Windows control channel still responds after each command.
- BMF status probe succeeds.
- Metrics, when available, still report healthy values such as `brickadia_server_up`, `bmf_runtime_status_up`, `bmf_telemetry_up`, and `brickadia_frame_telemetry_hook_registered`.
- No new UE4SS fatal error, crash folder, or server exit appears during the run.
- The JSON report says the canary passed or identifies the exact failing probe.

If the canary fails, preserve the report and crash/log artifacts, identify the first failing probe, and switch to crash forensics instead of widening the matrix.
