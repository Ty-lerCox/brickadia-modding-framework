---
name: bmf-performance-guardrails
description: Enforce performance guardrails for Brickadia BMF, Omegga bridge, CityRPG, telemetry, minigame, player-position, team-assignment, command-bus, socket, file-polling, native-hook, or Lua/TypeScript feature work that can affect dedicated-server frame time. Use when Codex is adding, modifying, reviewing, or debugging BMF/Omegga/CityRPG features with polling, per-player reads, command execution, game-thread work, event traffic, metrics, or frame-time spikes.
---

# BMF Performance Guardrails

Use this skill before changing BMF, Omegga, CityRPG, or telemetry paths that can increase Brickadia server frame time. Treat every poll, command, hook, player loop, and bridge round trip as a possible game-thread cost until measured otherwise.

## Risk Profile

Start by identifying the cost shape:

- High frequency: timers under 10 seconds, tick/frame hooks, repeated status probes, player-position sampling, minigame event loops.
- High fan-out: per-player reads, per-plugin scans, per-minigame queries, repeated team checks, chat or whisper loops.
- Game-thread sensitive: UObject/GetAll scans, pawn/controller/property reads, team mutation, command execution, console commands, native hooks.
- IO sensitive: command-file polling, log scanning, config writes, metrics exports, dashboard-generated probes.
- Burst sensitive: reconnects, join/leave, minigame start/end, respawn, kill/damage storms, bulk team assignment.

If a path is frequent, fan-out, or game-thread sensitive, require batching, caching, throttling, and telemetry before considering it done.

## Transport Decision

Choose the lowest-risk transport for the job:

- Use the file command bus only for low-frequency admin/control actions. Its poller must run off the game thread, process a bounded number of files per poll, and emit worker metrics.
- Use sockets or native hooks for high-frequency events or telemetry, but still queue, coalesce, and apply backpressure. A socket is faster transport, not automatic frame-time safety.
- Use an event-driven or bulk snapshot cache for frequent state reads. Do not repeatedly call per-player position APIs when one cached snapshot or event stream can serve all consumers.
- Use console commands only when they are known to be cheaper than API/property reads and are measured under live load. Do not add repeated console polling without telemetry.

Prefer one shared data producer with a cache over multiple feature-specific pollers.

## Game-Thread Rules

Keep this invariant: the game thread should do the minimum required Brickadia interaction, then return.

- Do not scan the filesystem, enumerate broad UObject lists, parse large payloads, or run analytics on the game thread.
- Do not create idle polling that keeps executing when no player, minigame, or consumer needs the data.
- Cap work per tick, poll, or callback. If backlog grows, drop, coalesce, or defer lower-value work.
- Make mutations idempotent where possible, such as `playerId:teamId`, so duplicate events do not produce duplicate game-thread work.
- Add feature flags for new high-cost paths and default them conservatively when the behavior is experimental.

## Command And Poll Design

Use existing central helpers instead of adding ad hoc command directories, timers, or queue loops.

- Give each command a clear semantic name and telemetry label.
- Include `source`, player identifiers, minigame identifiers, and reason fields when useful for attribution.
- Batch related reads, especially player positions and player states.
- Coalesce pending requests for the same snapshot or player before dispatch.
- Add TTLs for cached state and make stale/fresh behavior explicit.
- Avoid continuous work for UI convenience alone. Dashboards should observe existing metrics, not create expensive new server probes.

## Required Telemetry

For any new or changed high-risk path, emit enough metrics to explain frame-time movement:

- Command count by name and status.
- Command duration or processing latency when available.
- Queue depth, dropped/coalesced count, poll interval, and max items processed per poll.
- Frame telemetry before and after the change: average, max, sample count, and slow-frame thresholds such as `>= 16.67 ms`, `>= 33.33 ms`, `>= 50 ms`, and `>= 100 ms`.
- Audit/log lines that tie spikes to feature activity, command names, or hook callbacks.

If the dashboard shows frame spikes but command metrics cannot explain them, add attribution metrics before guessing.

## Live Validation

When validating against a live local server, use the live-server validation workflow if available.

1. Capture a 30 to 60 second baseline with the new feature idle.
2. Trigger the feature path under realistic conditions: reconnect, join minigame, move player, emit burst events, or run the command flow.
3. Inspect Prometheus/Grafana metrics, BMF audit logs, Omegga logs, and UE4SS/native logs as relevant.
4. Compare steady-state and burst frame time against baseline.
5. Disable the feature flag or consumer and confirm frame time returns toward baseline.

Acceptance criteria:

- No unexplained continuous polling.
- No duplicate semantic commands for one intended action.
- Steady-state frame time returns near baseline after bursts.
- Max frame spikes above 100 ms are either eliminated or tied to a known bounded operation with a follow-up.
- Command volume and queue depth stay bounded under the tested player count.

## Spike Response

When frame time spikes after a feature is enabled, debug in this order:

1. Disable the feature flag or consumer to prove causality.
2. Reduce command count and remove duplicate work.
3. Replace per-player polling with a bulk snapshot, shared cache, or event stream.
4. Move polling, IO, and parsing off the game thread.
5. Add backpressure, TTLs, and request coalescing.
6. Re-test before switching transports or adding native code.

Do not treat lower average command volume as sufficient if max frame time still spikes.

## Response Shape

When using this skill, include:

- Risk profile
- Transport/queue decision
- Guardrails applied
- Telemetry added or inspected
- Live validation result
- Remaining risk or next optimization
