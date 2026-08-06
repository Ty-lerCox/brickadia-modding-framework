# Phase 2 Structural Hitch Remediation

Date: 2026-08-05
Lifecycle addendum: 2026-08-06

Phase 1.5 proved that bounded admission prevents several expensive operations
from compounding in one frame. Phase 2 addresses the remaining structural
problem: individual synchronous discovery and drain paths could still monopolize
the Brickadia game thread after admission.

## Rollback checkpoint

Phase 1.5 is preserved in two local commits:

- BMF `190a8e7` (`Phase 1.5 BMF containment checkpoint`)
- Brickadia/Omegga `12d8644` (`Phase 1.5 Omegga reconciliation checkpoint`)

These commits predate the Phase 2 changes and remain the source-level rollback
point. They have not been pushed.

## Pre-rollout evidence

The Phase 1.5 server remains PID `52720` on UDP `7777` while Phase 2 is being
validated statically. Its deployed BMF runtime SHA-256 is:

`26794DD098F56B52B43050B84822F63239CDB03E064B47D2218FC1B32C7B9F74`

The live process accumulated 12 frames at or above 100 ms. Nine were attributable
to startup and the active canary. Three later spikes, at 315.862 ms, 270.559 ms,
and 111.385 ms, did not correlate with a BMF socket command. The growing Omegga
UE4SS bridge log scan and the independent native drains were still outside the
Phase 1.5 scheduler and are addressed below.

At the last pre-rollout sample the current 61-frame window averaged 16.538 ms,
peaked at 17.508 ms, and contained no frame at or above 33.33 ms. All direct and
tunnel queue depths were zero.

## Phase 2 changes

### One BMF game-thread admission owner

Direct and tunnel requests now share one bounded, weighted-fair scheduler. The
fixed selection cycle is four direct-interactive slots, four tunnel-interactive
slots, one direct-bulk slot, and one tunnel-bulk slot. Both paths share the 3 ms
game-thread pump budget, overload state, absolute-deadline checks, queue-age
telemetry, and terminal ownership.

Direct requests have bounded count and byte admission, request-ID replay, and
terminal states for completed, failed, rejected, expired, and outcome-unknown
work. A transport or cleanup failure cannot dispatch an accepted side effect a
second time in the same process. New bounded-mode requests must provide their
original issue time and absolute deadline; intermediary transports may shorten
that deadline but cannot reset it.

Command output is capped by both line count and serialized bytes. Truncated
responses carry an explicit marker and telemetry. Direct and tunnel replay
caches are also bounded by aggregate retained bytes as well as entry count, so
large responses cannot turn exactly-once retention into unbounded memory growth.

### Cache-first player registry

Ordinary player list, status-message, whisper, and broadcast paths now consume a
memory snapshot populated by the Omegga player-sync adapter. They do not read
`players.json`, parse the complete Brickadia log, or call `FindAllOf` per request.

The registry cache retains only plain player identity and snapshot data. It must
not retain a raw UE `UObject`, player-controller wrapper, or controller address
across frames or reconnects. When a command needs a live controller, the design
target is to acquire it fresh on the game thread through a lifecycle-guarded
resolver, use it only during that dispatch, and then discard it. If a fresh
controller cannot be resolved safely, the command fails closed instead of
trying an old handle or address. Broad discovery remains restricted to an
explicit, deduplicated repair with cooldown and publishes one new registry
generation for all waiting callers. Durable `players.json` writes are performed
by Node rather than the game thread.

This stricter rule was added after the 2026-08-06 reconnect-and-whisper crash.
Calling `IsValid()` on a stale UE wrapper is not a safe validation strategy: the
native pointer may already be invalid before that method can answer. Source
hardening now prevents cross-frame raw-object retention in chat, player registry,
game-command tunnel, native tree-target, and prefab-capture paths. The controlled
deployment and reconnect revalidation completed on 2026-08-06.

Automatic join reconciliation is cache-only and explicitly sends
`repair=false`; broad controller repair can only be requested manually. The
Node sync producer suppresses unchanged snapshots and coalesces overlapping
updates into one newest-state pass, preventing periodic work from refilling the
bulk queue with duplicate player data. Records are stably ordered and compacted
for transport. A tested 64 KiB producer/direct-command ceiling supports the
30-player server limit while the aggregate queue remains capped at 128 KiB;
larger snapshots update the durable cache but fail closed before socket send.

### Bounded Omegga UE4SS inbox

Omegga's separate Windows write queue and UE4SS inbox now have dual count and
serialized-byte caps. Requests carry issue time, an absolute deadline, and a
fixed interactive/bulk class. Node checks the deadline before writing; Lua checks
it again before any UE API or durable side effect. Timed-out requests left in the
append-only inbox therefore expire instead of executing later.

The only reserved-capacity UE4SS requests are ping and echo, and that capacity
is independently bounded. Exact `Server.Status` requests are answered directly
from Node's immutable identity snapshot and never enter the UE4SS inbox.
`Omegga.Bridge.BmfDispatch` is routed through the BMF socket by Omegga and is
fail-closed inside Lua, removing its former inline scheduler bypass.

Both Node and Lua reject missing or expired deadlines in bounded mode, and Lua
checks again inside the EngineTick callback immediately before any UE API or
durable side effect. A 64 KiB record ceiling is enforced while reading, not
after allocating an arbitrarily large line. The BMF socket broker also caps its
pending-command map and every client input buffer. The Omegga BMF Bridge plugin
independently caps commands awaiting responses and its own receive buffer.

### Cache-only server identity and build detection

`Server.Status` no longer scans the growing Brickadia log on the game thread. Its
plain server identity is read once from the bounded `GameUserSettings.ini` file
before launch and passed to UE4SS as immutable process state. The configured
name is only a fallback.

Omegga also no longer rereads the complete Brickadia log on every control write
to rediscover the build CL. It updates a small build snapshot from the stdout
stream it already consumes. The append-only UE4SS outbox is consumed by byte
offset in bounded slices instead of being reread from the beginning every 100
ms, and Node host health is written to `host-status.json` while Lua alone owns
the runtime `status.json` snapshot.

The current settings intentionally remain unchanged. Before rollout they contain
`ServerName=CityRPG v1 - Under Maintenance`; Phase 2 does not guess or rewrite a
different name.

### Bounded native event drains

Tree and zone native queues now share the same full-pump 3 ms origin. The default
path removes one event at a time, alternates sources, and drains at most four
events per pump. It checks the budget before removing an event and immediately
after its callback finishes. If that callback overruns, no additional event or
socket command begins in the same slice.

One Lua event callback remains indivisible. The scheduler cannot preempt it after
it starts, but the source-specific overrun is counted and later work is deferred.

## Rollback controls

The live launcher should keep the Phase 1 ingress cap enabled. Phase 2 behavior
can be reduced independently with these controls followed by one controlled
restart:

```text
BMF_UNIFIED_SOCKET_ADMISSION_ENABLED=0
BMF_PLAYER_REGISTRY_CACHE_FIRST_ENABLED=0
BMF_PLAYER_REGISTRY_REPAIR_ENABLED=0
BMF_SOCKET_NATIVE_DRAIN_BUDGET_ENABLED=0
OMEGGA_UE4SS_BOUNDED_ADMISSION_ENABLED=0
OMEGGA_BMF_SOCKET_BOUNDED_ADMISSION_ENABLED=0
```

The first flag returns BMF direct/tunnel dispatch to the Phase 1.5 path. The
player flags restore the legacy player path only for diagnosis; they should not
be the first rollback because request-time discovery is the known hitch source.
The native flag restores the old 64-tree plus 64-zone drain behavior. The
Omegga flag restores its legacy unbounded admission semantics; individual
depth, byte, record-size, and deadline values remain explicit in the launcher.
The BMF socket flag relaxes Omegga core's broker bounds; the BMF Bridge plugin's
pending and input limits remain safety invariants.
Do not re-enable inline `BmfDispatch`; use the Phase 1.5 Omegga commit for a
complete source rollback.
Do not automatically retry a durable command whose outcome is unknown.

## Static validation

The original Phase 2 scheduler, admission, and producer checks passed. The
2026-08-06 lifecycle addendum added the following final checks:

- Lua runtime/lifecycle regression suite: 13/13 passed.
- BMF Bridge interop suite: 10/10 passed.
- Safe-worker transport suite: 13/13 passed in both the supported and active
  Omegga trees.
- Supported and active Omegga backend builds: passed (109 modules).
- Canonical and packaged Lua runtimes: byte-identical and Lua 5.3 compile/AST
  clean.
- Scoped diff checks: clean.

Earlier Phase 2 coverage also included:

- BMF Lua scheduler guards: 9/9 passed.
- Canonical and packaged BMF runtimes: byte-identical.
- Lua 5.3 compile/AST scheduler validation: passed.
- BMF-supported Omegga backend build: passed (108 modules).
- Native drain Prometheus coverage: passed.
- BMF-supported Omegga focused admission/status/exporter tests: 25/25 passed.
- Active Omegga focused admission/status/exporter/join tests: 32/32 passed.
- Active Omegga backend build: passed (108 modules).
- BMF Bridge: 8/8 focused tests passed. Player-sync package and integration
  copies: 21/21 focused tests each passed. Coverage includes 30-player capacity,
  stable-order suppression, two-pass overlapping-sync coalescing,
  pending-map rejection, outbound command rejection, and receive-buffer
  overflow handling.
- CityRPG focused socket test, full regression suite, and TypeScript build:
  passed.
- Scoped Prettier and diff checks: passed.

## Known limits

- Lua uses second-resolution `os.time()` for its final deadline check, so an
  expired request can be rejected up to just under one second late, never early.
- Replay-cache accounting uses serialized payload size plus a conservative table
  allowance rather than exact Lua VM heap measurement.
- A single Lua/UE callback remains indivisible after it begins; Phase 2 prevents
  any additional native or socket work from starting after that overrun.
- Trusted one-shot maintenance clients and the CityRPG direct client rely on the
  broker/runtime's 64 KiB rejection rather than duplicating that preflight in
  every producer. Their current commands are small and bounded responses have
  timeouts; future bulk producers should preflight locally and use the `bulk`
  service class.

## Live acceptance result — 2026-08-06

The crash-specific lifecycle gate is accepted after one controlled restart.

- The old stack stopped through the supervisor stop marker; no process was
  force-killed. The replacement Brickadia server is PID `118620` on UDP `7777`.
- The live BMF runtime SHA-256 is
  `DDF997D8620DBF318BF36021984300A179E5A9F7EA878E9995978C2E76C21825`.
  The live OmeggaBridge SHA-256 is
  `9A3A7EC8CBEDCD4480767297ACA6B69481289A9A69E746C03B172710F205B253`.
  The live BMFSocket DLL SHA-256 is
  `2A930FE6BE07930075307E68DBB7EF495CC0934EC3F0496114E40BA9FB37FC11`.
- `Ty` joined, disconnected, and rejoined. CityRPG issued the new-session team
  assignment, player sync published the two-player snapshot, and two whisper
  probes ran on opposite sides of the reconnect. Both bridge traces explicitly
  reported `cross-frame UObject caches disabled` and `fresh bounded discovery`.
  The unsupported console execution returned false; it failed closed and the
  server remained alive.
- No crash folder newer than
  `UECC-Windows-C263CC0B487D1E11B1D99E86386BEFBD_0000` at `00:24:22Z` appeared.
- Direct and tunnel queue depths returned to zero; there were no tunnel
  rejections, expirations, or worker errors. At the final health check the
  60-frame window averaged `16.553 ms`, peaked at `17.566 ms`, and averaged
  `60.411 FPS`. BMF, Omegga, CityRPG, UDP `7777`, and telemetry were healthy.
- `ServerName=CityRPG v1 - Under Maintenance` remained unchanged. The active
  role hashes remained
  `7D2E02F91139209DD13492DF90344B7212ECD44830CE1B00F802175A8824F8C3`
  and
  `37135873DEC7E75F598857F415167079EAD13A19AF6CBCB58258B884DFFF2BA0`.

This proves the stale-controller crash path is contained. It does not claim
that every hitch is gone: one-shot startup discovery still recorded `530 ms`,
`212 ms`, and `118 ms` command maxima, and reconnect/canary activity produced
additional frames above `100 ms`. Those events did not come from queue growth;
the queues remained at depth zero. They are the remaining indivisible-work
performance boundary, not a reason to reuse Unreal objects.

The rollback backup is:

`C:\Users\tycox\OneDrive\Documents\GitHub\Brickadia\artifacts\service-start\pre-phase2-20260805-1959`

## Original live acceptance checklist

The rollout is not accepted until one controlled restart demonstrates all of the
following:

- Settings, roles, assignments, and the server-name file retain their pre-rollout
  hashes.
- Normal `players.list`, status-message, whisper, and broadcast requests perform
  zero global controller scans.
- No live `UObject`, controller wrapper, or controller address is retained and
  reused across frames; reconnect-then-whisper and reconnect-then-team probes
  resolve a fresh controller or fail closed without a crash.
- One explicit player repair is deduplicated and obeys cooldown.
- Direct and tunnel queues drain without growing oldest age or starvation.
- Expired Omegga inbox requests do not execute later.
- Repeated `Server.Status` requests do not scan the Brickadia log.
- Normal cached game-thread handlers remain below 5 ms, with a target below 1 ms.
- The busy-period soak creates no unexplained frame at or above 100 ms and no new
  server crash folder.

The crash-specific items above passed. Longer-duration performance observation
remains appropriate because a short controlled canary cannot prove the absence
of every unrelated hitch over days of gameplay.

## Unified-broker rollout gate — 2026-08-06

Phase 2 is **not accepted for live use**. The unified direct/tunnel broker was
enabled for the smallest controlled slice, exposed a connection-readiness race,
and was rolled back with its documented single flag. The live launcher now has
`BMF_UNIFIED_SOCKET_ADMISSION_ENABLED=0`, restoring Phase 1.5 admission while
retaining the new attribution, cache, identity, frame-telemetry, and dashboard
work.

With the unified broker enabled, 68 CityRPG tunnel operations were accepted but
only 12 reached an injected terminal result. The other 56 became
`outcome_unknown`; no duplicate or expired operation was observed. Attribution
showed the broker beginning `/cityrpgRemote` work during the post-join interval
where a controller existed but the native implementation call was not yet
reliably callable. Because execution had begun, exact-once semantics correctly
forbade an automatic retry. A later harmless direct tunnel diagnostic succeeded
in 41 ms at the `implementation_call` stage, confirming that this was a
lifetime/readiness boundary rather than queue growth.

The same evidence also leaves one structural performance issue open:
`/cityrpgRemote` native invocation remains an indivisible 35–65 ms game-thread
handler even when it succeeds. A 3 ms scheduler can prevent a second job from
starting after that overrun, but cannot preempt the call itself. Performance
work must next split or eliminate that native implementation call without
weakening UUID-plus-generation routing or retrying unknown outcomes.

After the rollback and one controlled restart:

- the supervisor and Brickadia server remained healthy, UDP 7777 stayed bound,
  and no new crash folder was created (the count remained 368);
- the active world remained `CityRPG_ItemBufferFix_20260802_1320`, the configured
  server name remained `CityRPG v1 - Under Maintenance`, and an exact normalized
  settings comparison found zero semantic differences;
- reconnect reconciliation completed 9 of 9 tunnel operations with zero unknown
  outcomes and zero duplicates;
- 100 cached `bmf.players.list` calls completed 100/100 with p50 1 ms, p95 1 ms,
  p99 1 ms, and a 3 ms maximum;
- a 12-way parallel `bmf.status` burst completed 12/12, after which direct and
  tunnel depth and oldest age returned to zero;
- ordinary-player global scans, repair scans, unknown outcomes, and duplicate
  outcomes all had zero delta during those canaries;
- direct status-message and whisper probes with incomplete controller-path
  metadata failed closed as `PRIVATE_IDENTITY_STALE`; they did not fall back to
  another player or global chat;
- the 30-minute observer completed 1,800 one-second samples. Its final frame
  window averaged 16.545 ms (about 60.44 FPS) and peaked at 17.491 ms. The
  canary added one frame in the 33.3–50 ms band, zero frames at or above 50 ms,
  and zero frames at or above 100 ms. Queue depth and queue age stayed zero, and
  global-scan, unknown-outcome, and duplicate counters did not increase;
- the autosave timer ran every 30 seconds throughout the window. It reported
  `Skipping auto save (no bricks changed)`, so timer coexistence is proven but
  dirty-world save I/O is not covered by this canary.

The native 30-minute raw samples were not retained locally after the observer's
final formatter exceeded its wrapper timeout, and the configured remote-write
credential has no query scope. Exact 30-minute frame p50/p95/p99 values therefore
cannot be reported honestly from this run. The threshold counters prove the p99
was below 33.3 ms, but the requested p95-below-20-ms gate remains formally
unverified. A future rollout should persist the observer samples before enabling
the candidate and must repeat the dirty-world autosave and multi-player canaries.

The pre-rollout recovery bundle, including settings, active-world identity,
deployed BMF/UE4SS payloads, and the touched Omegga tree, is at:

`C:\Users\tycox\OneDrive\Documents\GitHub\Brickadia\artifacts\phase2-rollout-20260806-0110`
