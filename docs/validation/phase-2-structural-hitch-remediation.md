# Phase 2 Structural Hitch Remediation

Date: 2026-08-05

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

Live controller access remains on the game thread. A cached controller handle is
validated before reuse; a miss performs a targeted lookup. Broad discovery is
restricted to an explicit, deduplicated repair with cooldown and publishes one
new registry generation for all waiting callers. Durable `players.json` writes
are performed by Node rather than the game thread.

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

## Live acceptance gate

The rollout is not accepted until one controlled restart demonstrates all of the
following:

- Settings, roles, assignments, and the server-name file retain their pre-rollout
  hashes.
- Normal `players.list`, status-message, whisper, and broadcast requests perform
  zero global controller scans.
- One explicit player repair is deduplicated and obeys cooldown.
- Direct and tunnel queues drain without growing oldest age or starvation.
- Expired Omegga inbox requests do not execute later.
- Repeated `Server.Status` requests do not scan the Brickadia log.
- Normal cached game-thread handlers remain below 5 ms, with a target below 1 ms.
- The busy-period soak creates no unexplained frame at or above 100 ms and no new
  server crash folder.

Live post-rollout hashes, probe counts, latency distributions, frame results, and
the exact backup directory will be appended after the controlled activation.
