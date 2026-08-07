# Phase 0C join attribution and callerless probe

Date: 2026-08-06

## Outcome

Phase 0C was halted at its repeated-frame safety stop. The isolated test server
was stopped before any callerless command was submitted.

- Join attribution: **UNRESOLVED**
- Callerless test-server transport: **NOT RUN**
- Production recovery decision: not part of this phase; no production GO was
  issued.

The callerless transport itself did not return a failure or an unsupported
result. It was not invoked, so it has not been proven or disproven. The test-only Wire source
remains an offline validation fixture only. It was never added to the production
action registry, staged into the production world, or invoked on production.

## Production checkpoint

Production remained on the accepted Phase 0B baseline throughout the work:

- Brickadia PID: `25272`
- UDP owner: PID `25272` on port `7777`
- deployed runtime SHA-256:
  `40F649B43033756BB7DB346B30F25FE4B323ADF179FC897A91E5AD27BB5FDC1B`
- BMF state: running and server-ready, with zero plugin errors
- newest crash folder: unchanged at `2026-08-06T00:24:22Z`

No production executable, UE4SS payload, plugin, setting, world, role,
assignment, password, player limit, or death setting was changed.

## Offline gates

The following Phase 0C gates passed before test-server activation:

- Omegga production build
- focused join-correlation tests
- fail-closed private-delivery regression
- BMF bridge tests: 11/11
- BMF player-sync tests: 22/22
- callerless no-op contract test
- WireScript diagnostics: zero errors and zero warnings
- WireScript compile/decode round trip: 36 bricks, 36 components, 48 wires
- Lua 5.3 canonical/template/staged compile gate
- canonical/template/staged byte parity
- exact 200-main-chunk-local positive boundary
- 201-local negative fixture rejection
- stale-context, connection-generation, identity, no-fallback, private-delivery,
  scheduler, and UObject-lifetime runtime guards: 26/26
- BMF runtime-package validation
- BMF plugin-facade and capability-surface validation
- `git diff --check`

The complete Omegga backend run passed 285 of 289 tests. Four pre-existing
baseline failures remain in the version matcher and server-status test doubles:
the test expects an unexported `extractBrickadiaVersion` helper, and two status
tests omit the `Console.Server.Status` facade. These failures are outside the
Phase 0C changes. The missing `better-sqlite3` native binding was rebuilt; all
database tests then passed.

## Isolated server construction

The test used a physical 2.32 GiB copy of the Brickadia install, a separate
Omegga work directory, a separate `data/Saved` directory, a separate UE4SS tree,
and UDP port `7799`. Production port `7777` remained owned by PID `25272`.

The first isolated process was:

- Brickadia PID: `8992`
- Omegga PID: `38536`
- port: `7799`
- map: `Plate`

The isolated Brickadia and Omegga processes were stopped after the safety
condition. Port `7799` was confirmed unbound afterward.

## Controlled join evidence

One controlled join completed before the halt. No frame above 33.333 ms was
recorded during that join.

| Phase | Duration | Outcome |
| --- | ---: | --- |
| log line to matcher | 0 ms | ok |
| connection generation | 0 ms | ok |
| join event emission | 1 ms | ok |
| player/controller reconciliation | 90 ms | error |

The 90 ms reconciliation was asynchronous and did not produce a slow game
frame. The isolated frame counter remained at one spike: a 221.417 ms map-load
startup frame recorded before the player joined. That startup spike's bounded
context contained role initialization and autosave initialization markers.

The run also exposed an isolation defect in the test harness. The physical copy
contained stale runtime JSON copied from production, and the attribution process
was initially pointed at the inactive `main` runtime alias while the isolated
process wrote to the `brickadia-install` alias. The correlation phase records
above came from the isolated Omegga process, but the runtime queue fields in the
startup spike context cannot be trusted. The server was stopped instead of
continuing with contaminated attribution metadata.

## Production frame stop condition

Read-only inspection of the live Phase 0B frame telemetry found 19 lifetime
frames above 100 ms. Thirteen were present in the retained recent window between
`2026-08-06T18:48:24.622Z` and `2026-08-06T19:14:27.899Z`:

`138.514`, `129.651`, `104.195`, `269.105`, `116.395`, `1121.026`,
`331.625`, `115.255`, `129.272`, `317.014`, `148.473`, `131.174`, and
`331.491` ms.

The current steady-state frame window returned to a normal maximum near 17 ms,
and there was no crash or PID change. However, repeated frames above 100 ms are
an explicit Phase 0C stop condition.

One retained spike is join-adjacent: a player completed `Join succeeded` at
`2026-08-06T19:04:44.722Z`, followed by a 331.625 ms frame at
`2026-08-06T19:04:44.838Z`, 116 ms later. Current production operation telemetry
does not attribute that frame to BMF. Later BMF player-sync work peaked at 10 ms
with zero controller resolutions, global scans, or repairs. The remaining recent
slow frames have no matching bounded operation record in the production build.

## Source state

Phase 0C instrumentation remains local and uncommitted for review. It includes:

- fixed-cardinality join phase timing
- bounded structured join correlation records
- bounded 250 ms frame-spike context capture
- plugin-worker and plugin-callback timing
- player-sync construction, serialization, publication, bridge, ingestion, and
  readiness timing
- aggregate Prometheus metrics without UUID, name, request ID, path, or address
  labels
- an offline, exactly-once, no-op callerless Wire fixture

No local commit was created because the callerless PASS condition was not met.
Nothing was pushed.

## Required next gate

Before resuming Phase 0C:

1. Recreate the isolated runtime without copied production runtime artifacts.
2. Resolve the active UE4SS alias before setting the attribution status path.
3. Prove queue and runtime context fields come from the isolated PID.
4. Decide how the newly observed production `>100 ms` cluster should be handled
   under the stated stop policy.
5. Resume with a fresh ten-join A/B run only after that decision.
6. Submit one callerless no-op only after the join run remains below the safety
   thresholds.
