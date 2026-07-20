# Command Tunnel Benchmark

Use `scripts/benchmark-bmf-command-tunnel.js` to compare the current and
candidate BMF command paths without changing the benchmark between runs. The
harness reports four different boundaries:

- authenticated socket `ping` to BMF `pong` round-trip;
- candidate `tunnel.request` to `tunnel.ack` round-trip;
- BMF command request to command-response round-trip;
- send time to the unique `/cityrpgRemote` marker appearing in the authoritative
  `Brickadia.log`.

The final measurement uses the timestamp written by Brickadia when available,
not the time at which Node notices the file change. This keeps filesystem watch
latency out of the primary completion number. The watcher time remains in the
artifact as a diagnostic.

The benchmark does not claim that a whisper was rendered by a remote client. It
proves that the authenticated socket request reached BMF, the one opaque
Brickadia command entrypoint returned, Brickadia's command router observed the
unique command, and BMF still answered a health ping afterward.

## Safety Contract

Socket-only mode sends bounded `ping` messages and does not require a player.
Command mode:

- requires the explicit `--confirm-live` flag;
- generates only `/cityrpgRemote whisper <player> <unique marker>`;
- allows no user-supplied gameplay action;
- allows at most 20 command samples;
- enforces at least 500 milliseconds between command samples;
- stops at the first failed command or health check;
- refuses a non-loopback socket host;
- does not start, stop, restart, or modify the server.

The default five command samples are suitable for a smoke test. Use 16 samples
for a more useful p95 comparison while leaving eight calls of headroom under the
current 24-command/10-second BMF player-message limit. Run the benchmark during
a quiet gameplay window because ordinary CityRPG traffic shares that limit.

## Before Run

Run from the BMF repository on the server version that represents the baseline.
Replace the player value with a currently connected player.

```powershell
$bmfSocket = Join-Path $env:APPDATA 'omegga\steam_installs\main\Brickadia\Binaries\Win64\ue4ss\main\Mods\BMF\runtime\socket.json'
$brickadiaLog = 'C:\Users\tycox\OneDrive\Documents\GitHub\Brickadia\omegga-master\omegga-master\data\Saved\Logs\Brickadia.log'
$canaryPlayer = '<connected-player>'

node .\scripts\benchmark-bmf-command-tunnel.js run `
  --label before `
  --mode all `
  --command-protocol legacy `
  --socket-path $bmfSocket `
  --log-path $brickadiaLog `
  --player $canaryPlayer `
  --ping-samples 20 `
  --command-samples 16 `
  --command-spacing-ms 500 `
  --baseline-ms 30000 `
  --recovery-ms 30000 `
  --require-metrics `
  --confirm-live `
  --out-json .\artifacts\local\bmf-command-tunnel-before.json
```

The 30-second baseline and recovery windows are only waited when the metrics
endpoint is available. For a transport-only diagnostic, use `--mode socket
--no-metrics`; do not use that shortened mode as the frame-time promotion gate.

## After Run

Run the same sample counts, spacing, player, server population, and metrics
settings after installing the candidate implementation:

```powershell
node .\scripts\benchmark-bmf-command-tunnel.js run `
  --label after `
  --mode all `
  --command-protocol tunnel `
  --socket-path $bmfSocket `
  --log-path $brickadiaLog `
  --player $canaryPlayer `
  --ping-samples 20 `
  --command-samples 16 `
  --command-spacing-ms 500 `
  --baseline-ms 30000 `
  --recovery-ms 30000 `
  --require-metrics `
  --confirm-live `
  --out-json .\artifacts\local\bmf-command-tunnel-after.json
```

The `legacy` protocol sends the fixed command through
`bmf.chat.player-message-impl`. The `tunnel` protocol sends the same unencoded
opaque line through `tunnel.request` and waits through `tunnel.ack` for the
terminal `tunnel.result`. This makes the before/after run compare the old and
new ingress paths while keeping the Brickadia command identical.

The legacy wrapper may be written explicitly when diagnosing compatibility.
`{command}` is replaced with the percent-encoded fixed command:

```powershell
--bmf-command-template 'bmf.chat.player-message-impl message={command} confirm=cityrpg-remote'
```

The template is ignored in `tunnel` mode. In `legacy` mode it must use the
approved `bmf.chat.player-message-impl` entrypoint, contain exactly one
`{command}`, and contain no newline. This restriction prevents a benchmark
argument from becoming an arbitrary BMF command launcher.

## Compare

```powershell
node .\scripts\benchmark-bmf-command-tunnel.js compare `
  --before .\artifacts\local\bmf-command-tunnel-before.json `
  --after .\artifacts\local\bmf-command-tunnel-after.json `
  --max-socket-p95-ms 300 `
  --max-command-p95-ms 300 `
  --max-p95-regression-percent 5 `
  --max-new-100ms-frames 0 `
  --out-json .\artifacts\local\bmf-command-tunnel-comparison.json
```

For the later event-driven implementation, repeat the comparison with the
proposed `--max-command-p95-ms 100` promotion gate. Do not apply that tighter
gate retroactively to the 200-millisecond polling baseline.

## Calculations

The harness sorts successful samples and computes an interpolated percentile at
index `(sampleCount - 1) * quantile`. It reports min, p50, p90, p95, p99, max,
and arithmetic mean.

Before/after calculations are:

```text
deltaMs = afterMs - beforeMs
changePercent = ((afterMs - beforeMs) / beforeMs) * 100
speedup = beforeMs / afterMs
```

A negative change is an improvement. Comparison fails when the candidate p95
exceeds the absolute gate, regresses more than the allowed percentage, produces
new frames at or above 100 milliseconds, or its own benchmark report failed.

Prometheus snapshots include:

- Brickadia, BMF runtime, BMF telemetry, and frame-hook health;
- frame window average and maximum;
- sample, spike, and `16.67`, `33.33`, `50`, and `100` millisecond slow-frame
  counters when exported;
- BMF command counts by name and transport;
- BMF worker item counts.

The report separates the active-window delta, the recovery-window delta, and
the baseline-to-recovery delta. A passing latency result is not sufficient when
frame time or command-worker attribution fails its gate.

## Validated Live Result

The 2026-07-20 L3 live-player run passed. Its machine-readable report is
[bmf-command-tunnel-after-20260720T052826Z.json](../../artifacts/local/bmf-command-tunnel-after-20260720T052826Z.json).
The matched `/balance` timestamps and before/after calculations are preserved
separately in
[bmf-command-tunnel-balance-after-20260720T053130Z.json](../../artifacts/local/bmf-command-tunnel-balance-after-20260720T053130Z.json).

| Measurement | Before | After | Result |
| --- | ---: | ---: | --- |
| `/balance` five-display-line span | 2,433 ms | 197 ms | 12.35x faster |
| `/balance` mean inter-line gap | 608.25 ms | 49.25 ms | gaps of 33, 66, 33, and 65 ms |
| `/balance` log entry to final display line | 2,634 ms | 325 ms | 8.10x faster; not a 10x end-to-end result |
| Single outbound request to Brickadia log, mean | 115.4 ms | 25.4 ms | 4.54x faster |
| Single-command Brickadia console completion p95 | -- | 34.6 ms | maximum 35 ms across 5 samples |
| Active frame-window average change | -- | +0.24% | within the 5% gate |
| New frames at or above 100 ms | -- | 0 | passed |

The 10x `/balance` target required the five-line span to be no more than 243.3
ms. The measured 197 ms span passed that target. The alternating one- and
two-pump gaps are consistent with a two-frame `LoopInGameThreadAfterFrames`
cadence and producer timing; the configured 25 ms socket and tunnel values are
quantized to roughly 33 ms game-thread opportunities.

That 10x result applies to the repeated display-command cadence, not every
boundary. Including the initial CityRPG response work, `/balance` appearing in
Brickadia's log through the final display line improved from 2,634 ms to 325
ms, or 8.10x. The five comparable single-command request-to-log samples
improved by 4.54x on their arithmetic mean. No throughput claim is made from
five serial canaries spaced 500 ms apart.

Discovery also ruled out the suspected inbound log flood. The baseline found
no sustained player-position spam, and matched PrintToConsole-to-Omegga lines
were ingested at p50 1 ms and at most 20 ms. That direction was already fast;
the material bottleneck was the old 450 ms outbound display pacing plus 200 ms
socket polling, not Brickadia stdout parsing. The persistent tunnel leaves
PrintToConsole on Omegga's stdout parser and changes only Omegga-to-Brickadia
command injection.

## Static Test

The unit test uses a temporary log and a local mock authenticated broker. It
does not connect to the live server.

```powershell
node --test scripts\benchmark-bmf-command-tunnel.test.js
node --check scripts\benchmark-bmf-command-tunnel.js
git diff --check -- scripts\benchmark-bmf-command-tunnel.js scripts\benchmark-bmf-command-tunnel.test.js docs\validation\command-tunnel-benchmark.md
```
