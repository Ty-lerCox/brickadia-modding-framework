# Observability and Performance

BMF exposes performance telemetry through runtime JSON files that the
BMF-vendored Omegga runtime exports as Prometheus metrics. Grafana Alloy can then
scrape Omegga locally and remote-write the data to Grafana Cloud.

## Who Should Read This?

BMF maintainers should use this page before changing polling, hooks, command
traffic, event volume, or native mutation. Server operators should use it to
wire metrics and evaluate frame-time risk. Plugin authors should use it when a
plugin might create frequent server work.

## Runtime Files

BMF writes the following files under the managed UE4SS runtime:

```text
Mods/BMF/runtime/status.json
Mods/BMF/runtime/telemetry.json
Mods/BMF/runtime/frame-telemetry.json
```

`status.json` describes runtime health, loaded plugins, audit counts, command
worker mode, command worker intervals, and command worker limits.

`telemetry.json` aggregates BMF-side activity:

- command counts and durations by command name
- file/socket command transport counts and durations
- framework event emit and handler counts/durations
- plugin-owned Lua handler counts/durations by plugin and hook
- scheduler callback counts/durations
- command/socket worker poll counts, durations, and processed item counts

`frame-telemetry.json` is written by the optional native `BMFFrameTelemetry`
UE4SS C++ mod. It contains Unreal engine tick `DeltaSeconds` aggregates,
sample counts, slow-frame counters, and recent spikes.

## Omegga and Grafana Cloud Path

The BMF-vendored Omegga Windows runtime reads the runtime JSON files and exposes
them at:

```text
http://127.0.0.1:8080/metrics
```

The Omegga repository owns the Grafana Cloud setup guide, Alloy config, and
dashboard JSON:

```text
omegga-master/omegga-master/docs/observability-grafana-cloud.md
omegga-master/omegga-master/observability/grafana-cloud.alloy
omegga-master/omegga-master/observability/run-grafana-alloy.ps1
omegga-master/omegga-master/observability/grafana/brickadia-overview-dashboard.json
```

Use that guide for Grafana Cloud tokens, remote-write variables, dashboard
import, and Alloy troubleshooting.

## Command Worker Performance Changes

The file-backed command worker is legacy diagnostic plumbing, not the normal
`BMF Bridge socket` integration path. It is no longer treated as cheap idle
work.

Current defaults:

```text
BMF_COMMAND_WORKER_ENABLED=0
BMF_COMMAND_WORKER_POLL_MS=250
BMF_COMMAND_WORKER_FALLBACK_POLL_MS=1000
BMF_COMMAND_WORKER_MAX_FILES_PER_POLL=1
BMF_COMMAND_WORKER_ASYNC=1
```

Enable `BMF_COMMAND_WORKER_ENABLED=1` only for legacy validation scripts that
have not yet moved to the socket client. Normal BMF Desktop and Omegga adapter
flows should use `BMFSocket`.

When `LoopAsync` is available, the command worker enumerates request files from
an async loop and schedules only the claimed command dispatch onto the game
thread. This keeps filesystem polling and idle directory scans away from the
game thread. `BMF_COMMAND_WORKER_MAX_FILES_PER_POLL` caps how much work can be
scheduled from one poll.

If async scheduling is unavailable or disabled, BMF can fall back to
game-thread loops or delayed callbacks. Treat those modes as degraded:

```text
bmf_command_worker_info{mode="LoopAsync"}                  preferred
bmf_command_worker_info{mode="LoopInGameThread"}           fallback
bmf_command_worker_info{mode="ExecuteInGameThreadWithDelay"} fallback
bmf_command_worker_info{mode="stopped"}                    unhealthy
```

Environment knobs:

```text
BMF_ALLOW_LOOPASYNC=1                  allow LoopAsync explicitly
BMF_ALLOW_LOOPASYNC=0                  force async loop off
BMF_COMMAND_WORKER_ENABLED=1           opt in to legacy request-file validation
BMF_COMMAND_WORKER_ASYNC=0             disable async command worker path
BMF_ALLOW_GAME_THREAD_LOOP=1           allow game-thread loop fallback
BMF_ALLOW_DELAYED_WORKER_FALLBACK=0    fail closed instead of using recurring delayed callbacks
BMF_COMMAND_WORKER_POLL_MS=<ms>        async poll interval
BMF_COMMAND_WORKER_FALLBACK_POLL_MS=<ms>
BMF_COMMAND_WORKER_MAX_FILES_PER_POLL=<n>
```

Use `BMF_COMMAND_WORKER_MAX_FILES_PER_POLL=1` unless a live test proves a higher
value does not raise max frame time.

## Socket Worker

`BMFSocket` remains the preferred path for latency-sensitive Omegga plugin
traffic. Omegga starts an authenticated loopback broker and passes
`OMEGGA_BMF_SOCKET_*` values into the Brickadia server. BMF connects from inside
the UE4SS process and processes newline-delimited JSON command/event messages.

The socket worker can also use `LoopAsync`; it still must queue and bound game
thread work. A socket reduces transport latency, but it does not make Unreal
property reads, team mutation, or command dispatch free.

Useful variables:

```text
OMEGGA_BMF_SOCKET_ENABLED=1
OMEGGA_BMF_SOCKET_HOST=127.0.0.1
OMEGGA_BMF_SOCKET_PORT=<port>
OMEGGA_BMF_SOCKET_TOKEN=<token>
OMEGGA_BMF_SOCKET_POLL_MS=200
```

Use `bmf.socket.status` to inspect socket health from the BMF Bridge socket route.

## Native Frame Telemetry

`BMFFrameTelemetry` is optional because it is native UE4SS code. When deployed
and enabled, it registers an engine tick callback and writes low-rate aggregate
frame data to:

```text
Mods/BMF/runtime/frame-telemetry.json
```

The Omegga exporter turns that JSON into metrics such as:

```text
brickadia_frame_telemetry_up
brickadia_frame_telemetry_hook_registered
brickadia_frame_delta_milliseconds{scope="window",statistic="avg"}
brickadia_frame_delta_milliseconds{scope="window",statistic="max"}
brickadia_frame_fps{scope="window",statistic="avg"}
brickadia_frame_slow_total{threshold_ms}
brickadia_frame_spikes_total{threshold_ms="100"}
brickadia_frame_spike_last_delta_milliseconds
```

Build and deploy with:

```powershell
.\scripts\build-bmf-frame-telemetry-native-mod.ps1 -Deploy
```

Restart the Brickadia server after deploying so Omegga can stage and enable the
native mod. Disable the sampler with `BMF_FRAME_TELEMETRY_ENABLED=0` or override
the output path with `BMF_FRAME_TELEMETRY_PATH`.

## Performance Guardrails

Every new feature that polls, loops over players, sends BMF commands, scans
UObjects, mutates Brickadia state, or handles minigame bursts needs a frame-time
budget.

Use these rules:

- Prefer event-driven data or one shared bulk snapshot over per-player polling.
- Do not scan files, parse large payloads, enumerate broad UObject lists, or run
  analytics on the game thread.
- Keep command/event work idempotent where possible, for example
  `playerId:teamId`, so duplicate events do not duplicate mutations.
- Add feature flags for risky or experimental paths.
- Emit command count, command duration, worker throughput, queue/backlog, and
  frame metrics before considering a high-risk path done.
- Validate with a 30 to 60 second baseline, then trigger the feature, then
  disable it and confirm frame time returns toward baseline.

Do not rely only on average frame time. The local telemetry investigation showed
that max frame time can remain high even after command volume improves.

### Runtime Brick State Guardrails

Runtime brick state mutation is an experimental native control path, not a
polling path. Keep it narrow:

- Enable it only with `BMF_BRICK_RUNTIME_SET_ENABLED=1`.
- Prefer `uuid=<uuid> purpose=<purpose>` or `tag=lookup:<uuid>:<purpose>` for
  public gameplay APIs.
- Treat explicit live runtime brick ids as diagnostic/runtime-cache values,
  not as a scripter-facing contract.
- Allow GUID/tag-only runtime-brick workflows only when they use existing
  bindings, explicit positions, or cached exact target-cache lookups. Do not
  add broad live UObject scans to satisfy convenience lookups.
- Keep `BMF_BRICK_GRID_CONTEXT_CACHE_TTL_MS` bounded, currently `300000`, so
  visibility/collision setters can survive normal gameplay retry timing without
  reusing native grid-context pointers indefinitely.
- Keep native sparse-grid scans bounded with `BMF_BRICK_CONTEXT_SCAN_MAX_MS`.
  Gameplay background scans should stay near owner hints and leave
  `BMF_BRICK_CONTEXT_HINT_FULL_FALLBACK_ENABLED=0` so a miss returns a bounded
  failure instead of falling into a process-wide scan.
- Use `BMF_BRICK_OWNER_CONTEXT_SCAN_FOR_SET_ENABLED=1` only for bounded,
  explicit runtime-id gameplay workflows. Owner memory scans must never be used
  as broad discovery.
- Test after restart on a known canary brick before using the path for gameplay.

The setter uses Brickadia's visibility/collision setters and needs a plausible
sparse-grid context. Native lookup accepts a candidate id only when the returned
brick reports the same internal runtime id field. Context lookup should prefer
cached or hook-captured context. If cold-start lookup is needed, use
`BMF_BRICK_CONTEXT_BACKGROUND_SCAN_ENABLED=1` so the resolver runs off the game
thread.

Caller behavior matters as much as native behavior:

- Wait for the matching queued `sequence` in `bmf.bricks.runtime.status`.
- Treat `BRICK_GRID_CONTEXT_SCAN_PENDING` as a bounded retry signal.
- Sleep between retries and cap the total result wait.
- Avoid continuous polling.
- Enable direct byte-write gates only for narrow runtime-id workflows with live
  validation, and keep them behind rollback flags. When live collision needs the
  Brickadia setter path, enable `BMF_BRICK_RUNTIME_SCAN_BEFORE_DIRECT_WRITE_ENABLED=1`
  so direct writes wait for one bounded background context-scan attempt before
  falling back.

Before a gameplay system such as CityRPG tree chopping promotes this path,
capture `L6 Frame Time` evidence and keep a rollback flag available.

## L6 Frame Time Validation

`L6 Frame Time` is the status-stage gate for performance-sensitive features.
Run it after the feature already has the functional validation level it needs,
such as `L2 Headless`, `L3 Live Player`, or `L4 Multiplayer`.

Minimum procedure:

1. Enable `BMFFrameTelemetry` and confirm `brickadia_frame_telemetry_up` and
   `brickadia_frame_telemetry_hook_registered` are `1`.
2. Capture a 30 to 60 second baseline with the feature idle.
3. Trigger the feature path under realistic load.
4. Capture command, worker, event, and frame metrics during the active window.
5. Disable or stop the feature path and capture a recovery window.
6. Record whether frame time returns toward baseline.

Required evidence:

- baseline, active, and recovery time ranges;
- average and max `brickadia_frame_delta_milliseconds`;
- slow-frame rates for `16.67`, `33.33`, `50`, and `100` ms thresholds;
- `brickadia_frame_spikes_total` and latest spike age/delta;
- relevant command/worker attribution, including command rate, command duration,
  worker item count, and worker poll duration;
- feature flags or config values used for the run;
- final result: passed, failed, blocked, or skipped with reason.

Default acceptance target for local development:

- steady-state max frame time returns near baseline after the active window;
- no unexplained recurring `>= 100 ms` native frame spikes;
- command-worker throughput remains bounded;
- disabling the suspected feature reduces the spike pattern if that feature is
  blamed for the regression.

If the feature intentionally performs a large bounded operation, document the
expected spike and add a follow-up if it can affect live gameplay.

## Player Position Lesson

CityRPG zone polling exposed the first important regression: frequent live
player-position reads can produce visible hitches and `100+ ms` native frame
spikes even with one player. Reducing command volume helped, but the expensive
part was still the live position read path.

For future player-location features:

- Prefer a single shared provider and cache over each feature polling BMF.
- Use a bulk player-position snapshot or event stream if one is available.
- Coalesce duplicate position requests for the same player/window.
- Increase cache TTL before increasing poll rate.
- Keep unsafe live pawn reads disabled unless crash-validated for the current
  Brickadia build.
- Add a feature flag so the position consumer can be disabled during frame-time
  diagnosis.

When debugging spikes, first disable the consumer, then reduce duplicate work,
then batch/cache/coalesce, and only then change transport.

## Validation Queries

In Grafana Explore, useful first checks are:

```promql
brickadia_frame_delta_milliseconds{scope="window",statistic="max"}
sum by (threshold_ms) (rate(brickadia_frame_slow_total[$__rate_interval]))
sum by (command, status) (rate(bmf_command_processed_total[$__rate_interval]))
bmf_command_duration_milliseconds{statistic=~"avg|max|last"}
bmf_command_worker_info
bmf_worker_items_total
```

Healthy steady state for local development should have fresh BMF status and
telemetry files, a readable frame telemetry file when the native sampler is
enabled, bounded command-worker throughput, and no unexplained recurring max
frame spikes above `100 ms`.
