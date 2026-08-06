# Phase 2 Final Integrated Validation

Date: 2026-08-06
Disposition: **NO-GO**

## Executive result

The deployed stack remained alive, retained its server configuration, performed
zero steady-state global player scans, and passed the static identity and UObject
lifecycle suites. The live reconnect gate nevertheless failed: one controlled
reconnect created five new CityRPG tunnel `outcome_unknown` results. Each affected
operation's attribution record had an empty sender UUID and
`connection_generation=0`. No retry was attempted.

The mandatory 30-minute canary was stopped after 613.109 seconds, as required by
the unknown-outcome stop condition. This report does not claim a 30-minute or
24-hour soak.

## Original symptoms and confirmed causes

The incident began as server crashes and severe frame hitches, followed by
private command responses appearing for a different player. Investigation found:

1. Private delivery guessed a recipient from name/controller availability and
   could broadcast after private-delivery failure. This allowed responses to
   cross player boundaries.
2. Raw Unreal wrappers/controllers were retained across asynchronous or reconnect
   boundaries. Calling validation methods on a stale wrapper could itself crash.
3. Ordinary player commands performed broad discovery and log/file work on the
   game thread.
4. Independent direct and tunnel queues could compound work in one frame.
5. `/cityrpgRemote` remains an indivisible native implementation call. Successful
   calls currently require roughly 35–65 ms of game-thread time.
6. The unified broker candidate began some post-join work before its native
   implementation was callable. Exact-once protection correctly classified the
   already-started work as outcome unknown instead of retrying it.

## Deployed state

| Item | Current state |
| --- | --- |
| Supervisor PID/start | 68992 / 2026-08-06 01:28:44 America/New_York |
| Omegga Node PID/start | 35792 / 2026-08-06 01:28:45 America/New_York |
| Brickadia PID/start | 122392 / 2026-08-06 01:29:19 America/New_York |
| Brickadia port | UDP 7777, owned by PID 122392 |
| Omegga/BMF ports | TCP 8080, 3000, and 41232, owned by PID 35792 |
| BMF | running, ready, compatible, 0 plugin errors |
| BMF Lua plugins | InteractConsolePrefixGuard, NoSpawnItemApplicator, TieredBrickPlacementGuard |
| BMF Bridge | connected, pending 0, socket errors 0, buffer overflows 0 |
| CityRPG | TCP health listener on 3000 healthy; full test and TypeScript build passed |
| Frame telemetry | enabled, hook registered, current Brickadia PID matched |
| Unified broker | disabled; Phase 1.5 admission restored |
| World | `CityRPG_ItemBufferFix_20260802_1320` |

The applicator and placement native hooks both report the current Brickadia PID,
current-process timestamps, enabled blocking, and verified targets. The placement
guard reports 56 denied assets and 20 denied prefab hashes.

## Deployed hashes

| Artifact | SHA-256 | Parity |
| --- | --- | --- |
| Active/source BMF runtime | `D88CCC76B384142839D3186A8582A16A3B3B358629D33D53344754F6328A4662` | identical |
| Active/source frame DLL | `A3951B65605933C959F326347EFD93E2EDEF2773BC41D214B54071C8336A1A96` | identical |
| Active/source OmeggaBridge | `8479EC00B499FC4550A1DB4A94D7E0BF9F62508A7EDFFE923B9E9E03F6B2CBEB` | identical |
| Omegga `dist/main.js` | `7028D031DBBAE2FA13CCDC1BD72508D0380E6BB14734B24A106460A9F3C274A4` | production build passed |
| Omegga `dist/index.js` | `F37E22293CD9988A24BE014D20486B3AA452F16094702496A02A3E9CEA9D4793` | production build passed |
| Live/source CityRPG `dist/index.js` | `D5411FCF816633388FE954368EBB1487F49D09E98D13145FF8641C59CDA92E8A` | identical |

## Settings and identity comparison

| Setting | Current | Comparison |
| --- | --- | --- |
| Server name | `CityRPG v1 - Under Maintenance` | unchanged |
| Description | empty | unchanged |
| Player limit | 30 | unchanged |
| Password present | no | unchanged |
| Explicit death setting | not serialized in `GameUserSettings.ini` | unchanged/absent |
| Settings semantic hash | `34EB5A41874FF2296FBE3F42EA6A378B32627A72D9595064EA486490258BC584` | stable during canary |
| Role setup hash | `33577F37E98187B362EBF48793126A11767382EB9A22C155D39F972A249BD968` | stable during canary |
| Role assignments hash | `37135873DEC7E75F598857F415167079EAD13A19AF6CBCB58258B884DFFF2BA0` | stable during canary |
| World pointer hash | `49F85B6A763123D41B24B42318955EDDA427A5EFBEA23CE18A7C2EC8E22B7E83` | identical to pre-rollout |

The current settings file has a different byte hash from the checkpoint because
Brickadia rewrote its serialization. Sorting and normalizing its 42 non-empty
lines produces zero semantic differences. The current role hashes were already
present in the 2026-08-05 23:00 identity-incident capture and did not change
during this validation.

## Identity and lifecycle validation

Passed static checks:

- Lua lifecycle/scheduler guard: 18/18.
- Focused Omegga routing, private-delivery, scheduler, and Prometheus tests:
  13/13 across 5 files.
- BMF Bridge and player-sync tests: 33/33.
- The player-sync suite includes simultaneous reconnects resolved by UUID rather
  than array order, stale controller clearing, and bounded 30-player publication.
- Direct whisper and status canaries without a strict envelope failed closed as
  `PRIVATE_IDENTITY_REQUIRED`; delivered count remained zero and there was no
  public fallback.

Live limitations and failure:

- Only one real player was available. The required three-player, 100-response,
  out-of-order routing matrix was not executed and was not simulated.
- Ty's controlled reconnect advanced the cached generation from 1 to 2.
- Reconnect processing accepted 14 new tunnel operations: 9 injected and 5
  became `outcome_unknown`.
- The five unknown operations took 38–53 ms of game-thread time, were cache
  misses, and had `connection_generation=0` with no sender UUID in their
  operation attribution.
- Duplicate counters and explicit identity-mismatch counters remained zero.
- No retry was issued after the unknown outcomes.

Because operation ownership cannot be proven for those five results, issuer,
authorization owner, operation owner, and recipient UUID equivalence is not
established end to end. This alone requires NO-GO.

## Performance validation

Before the reconnect, 100 cached `bmf.players.list` calls completed 100/100 with
server-reported p50/p95/p99/max of 1/1/1/1 ms. A fresh Node process per request
had a 98.11 ms p95, which is process-start overhead and is not reported as BMF
socket latency. A 12-way `bmf.status` burst completed 12/12 and both queues
returned to zero.

The stopped soak observed 36,411 native frame samples over 613.109 seconds. Its
1 Hz `delta_ms_last` sample distribution was p50 16.625 ms, p95 17.252 ms,
p99 17.490 ms, and max 17.628 ms. Those are sampled values, not a complete
native-frame histogram. Exact threshold counters recorded 34 frames above
33.3 ms, 19 above 50 ms, and 11 above 100 ms, normalized to 9.3378, 5.2182,
and 3.0211 per 10,000 frames respectively.

The frame-threshold regressions occurred while full local builds and test suites
were intentionally competing for CPU and disk. They make this attempted soak
unsuitable as a steady-state acceptance window. The worst observed rolling
window was 2,848.121 ms. The 30-second block containing it averaged 21.186 ms
(47.201 FPS). This host-contention attribution does not erase the failed
performance gate; a clean 30-minute gameplay-only window still has to be run.

### 30-second blocks

| Start (s) | Avg frame ms | FPS from avg | Max ms |
| ---: | ---: | ---: | ---: |
| 0 | 16.549 | 60.426 | 17.719 |
| 30 | 16.576 | 60.329 | 43.862 |
| 60 | 16.572 | 60.344 | 32.018 |
| 90 | 16.623 | 60.159 | 33.926 |
| 120 | 16.621 | 60.164 | 43.500 |
| 150 | 16.599 | 60.245 | 18.146 |
| 180 | 16.636 | 60.109 | 44.219 |
| 210 | 16.576 | 60.330 | 17.705 |
| 240 | 16.568 | 60.356 | 17.691 |
| 270 | 16.594 | 60.261 | 17.877 |
| 300 | 21.186 | 47.201 | 2848.121 |
| 330 | 16.665 | 60.006 | 76.231 |
| 360 | 16.565 | 60.369 | 17.692 |
| 390 | 19.020 | 52.576 | 1581.177 |
| 420 | 18.226 | 54.867 | 1908.748 |
| 450 | 16.660 | 60.023 | 96.720 |
| 480 | 16.582 | 60.306 | 18.017 |
| 510 | 16.627 | 60.142 | 64.418 |
| 540 | 16.567 | 60.360 | 17.900 |
| 570 | 16.563 | 60.376 | 18.058 |
| 600 | 17.178 | 58.215 | 86.720 |

Other canary deltas before the mandatory stop:

- direct/tunnel maximum queue depth: 0/0;
- direct/tunnel maximum oldest age: 0/0 ms;
- blocked admission delta: 9;
- expiration delta: 0;
- unknown outcome delta: 5 at final read;
- duplicate delta: 0;
- cache hits/misses: 117/0 (100% hit rate for classified cache reads);
- repair requests/duration: 0/0 ms; live repair coalescing was not exercised;
- ordinary player global scans/duration: 0/0 ms;
- controller resolution delta: 14 by final tunnel accounting;
- autosave log lines: 20. They were `Skipping auto save (no bricks changed)`,
  so dirty-world save I/O was not validated.

Startup operations are separated from steady-state results. Their lifetime maxima
were applicator native-target discovery 704 ms, UObject description 178 ms, and
zone-wire startup 134 ms. The current normal-path long handler is
`cityrpg.remote`: 65 ms maximum game-thread time and 168 ms maximum total time.

## Stability result

At stop time:

- crash-folder count remained 368; no new crash folder or stale-UObject crash
  signature appeared;
- Brickadia and Omegga PIDs did not change;
- settings, roles, assignments, and world identity did not change;
- BMF Bridge remained connected with pending depth zero;
- no queue-age growth, global scan, duplicate durable action, or explicit
  private-delivery mismatch was observed;
- the reconnect-time unknown outcomes failed the lifecycle gate before the
  required 30-minute duration.

## Builds and tests

- Active Omegga production build: passed, 108 modules.
- CityRPG full test suite: passed.
- CityRPG TypeScript build: passed.
- BMF orchestrator-core: 44/44 passed.
- BMF CLI: 40/40 passed.
- Dashboard/PromQL contract: 6/6 passed; dashboard has 23 panels.
- Canonical/template Lua parity: byte-identical; Lua 5.3 compiler and AST checks
  passed; no unsafe scheduler findings.

## Diff and repository audit

The BMF change set contains no tracked crash dump, supervisor stop sentinel,
temporary backup, detected secret, or accidental log. The native frame DLL is
an intentional versioned deployment bundle. Prometheus label tests passed and
request IDs, UUIDs, object paths, and addresses are not used as metric labels.
The absolute workstation path in the earlier validation document was replaced
with a repository-relative rollback path.

The BMF and CityRPG worktrees were clean before this final report. The Brickadia
worktree remains intentionally dirty with the deployed Omegga delta plus older
user-owned research artifacts; these were not swept into a commit. The required
five-way separation is therefore not perfectly represented in one repository:
commit `6f2f9f0` combines scheduler work with fail-closed routing, and the deployed
Omegga delta is not isolated from the pre-existing dirty Brickadia checkout.

Primary changed areas are:

- `framework/ue4ss/Mods/BMF/Scripts/bmf/runtime.lua` and its packaged template;
- Omegga Bridge and player-sync plugins;
- Omegga socket, player, matcher, safe-worker, private-delivery, and Prometheus
  sources and tests;
- native frame telemetry source and DLL;
- Grafana dashboard and telemetry tests;
- CityRPG rental tunnel regression test;
- Phase 2 architecture, API, and validation documentation.

## Local commits

| Category | Commits |
| --- | --- |
| P0 identity/fail-closed routing | `6f2f9f0` (also contains scheduler integration); Brickadia/Omegga `8ef9a49` |
| UObject lifetime safety | `23b4280`; Brickadia/Omegga `8ef9a49` |
| Scheduler/cache remediation | `718a802`, `6f2f9f0` |
| Telemetry/Grafana | `840fa86`, `31914fc` |
| Tests/documentation | `4f15db0f` (CityRPG), `ef04d01` plus this report |
| Rollback checkpoints | BMF `190a8e7`; Brickadia/Omegga `12d8644` |

Nothing was pushed.

## Rollback

The immediate scheduler rollback is already active:

```text
BMF_UNIFIED_SOCKET_ADMISSION_ENABLED=0
```

Do not retry unknown durable operations. The complete recovery bundle is at
`../Brickadia/artifacts/phase2-rollout-20260806-0110`. A full rollback requires
restoring the captured config/world pointer, active BMF/UE4SS payload, and
captured Omegga files, followed by one controlled supervisor-managed restart.
Verify normalized settings, role/assignment hashes, world hash, the new PID, and
all health endpoints before accepting traffic.

## Unresolved risks and recommendation

**Recommendation: NO-GO.**

Blocking risks:

1. Five outcome-unknown CityRPG operations reproduced on an ordinary reconnect
   even with unified admission disabled.
2. Those operations did not carry a usable sender UUID or connection generation
   in attribution, so ownership equivalence cannot be proven.
3. The three-player live routing matrix was not run because only one player was
   available.
4. The required clean 30-minute canary was stopped at 10 minutes 13 seconds and
   was contaminated by local build/test load before the stop.
5. `/cityrpgRemote` remains an explained but unresolved 35–65 ms indivisible
   game-thread handler.
6. Dirty-world autosave and live repair coalescing remain untested.

Do not re-enable the unified broker or describe Phase 2 as complete. Continue
dashboard/alert observation, but first fix the reconnect readiness/identity
envelope and remove or split the long native implementation call. Then rerun the
three-player identity matrix and a persisted, gameplay-only 30-minute canary.
