# Phase 1.5 Containment Checkpoint

Date: 2026-08-05

This checkpoint preserves the known-good BMF/Omegga containment baseline before
the Phase 2 unified-admission and player-cache rewrite. It is intentionally split
across two repository commits named:

- `Phase 1.5 BMF containment checkpoint`
- `Phase 1.5 Omegga reconciliation checkpoint`

Phase 2 changes must not be folded into either checkpoint.

## Live result

- Controlled activation moved Brickadia from PID `133636` to PID `52720` on UDP
  port `7777`.
- The BMF runtime loaded telemetry schema 2 with the 3 ms game-thread admission
  budget enabled and the effective direct ingress cap set to 2.
- The bounded live canary completed three commands exactly once and produced no
  new frame at or above 100 ms during its active window.
- Socket RTT p95 changed from 51.494 ms to 51.567 ms, a 0.142% regression.
- Recovery-window frame time averaged 16.468 ms with a 17.501 ms maximum.
- Scheduler queue depths and oldest ages returned to zero.
- The existing server settings and role files were preserved. The server name was
  `CityRPG v1 - Under Maintenance` before and after activation.

The rollout is containment, not preemption. An isolated `bmf.players.list
livecontrollers=true` operation still took 147 ms end to end and caused a 66.5 ms
frame. Phase 2 must remove request-time global discovery from ordinary paths.

## Benchmark evidence

- [Pre-activation benchmark](../../artifacts/local/bmf-command-tunnel-phase1-before-restart.json)
  - SHA-256: `A959E2A64F6DA928F514A13E8FE49F8A469EA71593C29872A9352611AD5F784E`
- [Post-activation benchmark](../../artifacts/local/bmf-command-tunnel-phase15-after-restart.json)
  - SHA-256: `E0522A3C7D2095E80251E3516BD580035BE1E47D7B8BFB9D3132F4C90242DEB4`

Re-run the comparison from the BMF repository root:

```powershell
node scripts/benchmark-bmf-command-tunnel.js compare `
  --before artifacts/local/bmf-command-tunnel-phase1-before-restart.json `
  --after artifacts/local/bmf-command-tunnel-phase15-after-restart.json
```

## State backup

The named world save created before activation is
`PrePhase15Restart_20260805_1807`.

The local settings/roles backup is:

`C:\Users\tycox\OneDrive\Documents\GitHub\Brickadia\artifacts\service-start\pre-phase15-restart-20260805T220700Z`

| File | SHA-256 |
| --- | --- |
| `GameUserSettings.ini` | `3B5358A6EFB9DCD97B27FB88358BD5DB4FD6FC826C5FA22E23FA5330595800F6` |
| `RoleAssignments.json` | `37135873DEC7E75F598857F415167079EAD13A19AF6CBCB58258B884DFFF2BA0` |
| `RoleSetup2.json` | `7D2E02F91139209DD13492DF90344B7212ECD44830CE1B00F802175A8824F8C3` |

Do not restore these files while Brickadia is writing them. Stop the managed
server first, verify the exact destination paths, restore only the named files,
and then start the stack normally.

## Rollback controls

The lowest-risk behavioral rollback is to change the launcher flags and perform
one controlled restart:

```text
BMF_GAME_THREAD_PUMP_BUDGET_ENFORCED=0
OMEGGA_BMF_JOIN_RECONCILIATION_ENABLED=0
```

The flags independently disable elapsed-time admission stopping and the bounded
Omegga unresolved-join fallback. Standard Omegga log matching remains enabled.
Keep `BMF_DIRECT_SOCKET_INGRESS_CAP_ENABLED=1`: that cap is the retained Phase 1
safety net. Set it to `0` only for an intentional rollback of the full Phase 1
containment design, not a normal Phase 1.5 rollback.

For a source rollback, first leave unrelated working-tree changes untouched.
Resolve the two checkpoint commits by their exact subjects and revert only those
commits in their respective repositories:

```powershell
git log --oneline --grep="Phase 1.5"
git revert <checkpoint-commit>
```

Rebuild the Omegga backend and perform a controlled restart before judging the
runtime result. Do not automatically retry a durable command whose outcome is
unknown.

## Validation captured by the checkpoint

- BMF scheduler guard tests: 5/5 passed.
- BMF Prometheus test: passed.
- BMF runtime/template byte parity: passed.
- Lua 5.3 compile/AST and scheduler scans: passed.
- BMF-supported Omegga production build: passed (106 modules).
- Live Omegga focused join, Prometheus, and Windows tests: 33/33 passed.
- Live Omegga production backend build: passed (106 modules).
- The broader Omegga backend suite had 261 passing tests and two pre-existing,
  unrelated `version.test.ts` failures caused by its missing
  `extractBrickadiaVersion` export.
