# Runtime Files

BMF writes generated runtime state under `Mods/BMF/runtime/`. These files are
operational evidence, socket status, or adapter caches. They should not be
committed.

## Who Should Read This?

Server operators should use this page when inspecting a live install.
Integrators should use it when wiring Omegga adapters. Maintainers should use
it when adding a new runtime file or changing ownership rules.

## Core Files

| Path | Owner | Purpose |
| --- | --- | --- |
| `runtime/status.json` | BMF | Runtime health, loaded plugin counts, command counts, config flags, and paths. |
| `runtime/telemetry.json` | BMF | Aggregate BMF command, event, plugin, worker, and socket timing counters. |
| `runtime/frame-telemetry.json` | `BMFFrameTelemetry` | Native frame-time samples for `L6 Frame Time` validation. |
| `runtime/socket.json` | BMF socket transport | Socket connection status, counters, and last error. |
| `runtime/bmf.log` | BMF | Human-readable framework log. |
| `runtime/events.jsonl` | BMF | Durable event evidence for diagnostics and support bundles. |
| `runtime/audit.jsonl` | BMF | Admin, mutation, denial, capability, and rate-limit audit records. |
| `runtime/logs/plugins/<PluginName>.log` | BMF | Per-plugin log mirror. |
| `runtime/players.json` | BMF and Omegga adapter | Safe player identity cache populated by `BMF.players.sync` or Omegga player sync. |
| `runtime/minigames/definitions.json` | BMF | BMF-owned desired minigame definitions. |
| `runtime/install-manifest.json` | Installer | Copied file hashes and backup metadata from install. |

## Command Worker

`runtime/commands/` is a legacy diagnostic command queue. Socket-backed
integrations should not use it for normal live traffic. BMF still bounds any
request-file polling work so old validation artifacts cannot create unbounded
filesystem work.

## Adapter Files

| Path | Owner | Purpose |
| --- | --- | --- |
| `runtime/minigame-adapter-status.json` | Omegga minigame adapter | Adapter mode, skipped unsafe polling reasons, and status for minigame event feeds. |
| `runtime/events.jsonl` | BMF | Durable event evidence for diagnostics and support bundles. |
| `runtime/players.json` | BMF plus Omegga player sync | Safe identity cache for player lookup, summary, and policy feedback. |

## Cleanup Rules

- Do not edit generated runtime files by hand while the server is running.
- It is safe to archive or delete runtime evidence only when the server is
  stopped and the current validation run no longer needs it.
- Keep `runtime/commands/` empty before starting a clean canary unless the test
  intentionally exercises legacy command-file handling.
- Treat JSONL logs as append-only evidence. Rotate or archive them outside the
  running process.
