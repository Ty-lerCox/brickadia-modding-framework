# Event Traffic Inspector

The event traffic inspector is a BMF Desktop view for live BMF/Omegga command
and event payloads.

It should feel closer to NgRx Redux DevTools than a metrics dashboard: a
timeline of envelopes, filters, selected payload details, and transport state.

## Goal

When a user hits a Brickadia object, runs a command, joins a minigame, or a
plugin emits a BMF event, the operator should be able to see the event move
through the stack:

```text
Brickadia/UE4SS -> BMF Lua -> BMFSocket or JSONL -> Omegga bridge -> plugin consumer
```

For example, an axe hit should eventually produce a resource/native-hit event
when that capture path is enabled. The inspector should show the event envelope,
payload, timestamp, source, transport, and consumer status.

## Sources

The inspector can read from:

- BMF socket broker event stream;
- BMF `runtime/events.jsonl` fallback;
- BMF command request/response records;
- Omegga bridge plugin diagnostics;
- BMF audit and telemetry summaries.

Socket should be preferred for live inspection. JSONL remains the durable audit
and fallback source.

Current seed: `packages/omegga-plugins/bmf-bridge` is the generic Omegga-side
collector/helper for these sources. It normalizes socket events, JSONL event
records, and file-backed command responses into the envelope below; retains a
bounded redacted in-memory buffer; exposes subscribe/unsubscribe and
`invokeCommand` helpers for other Omegga plugins; and writes
`runtime/bmf-bridge-status.json` for health diagnostics. It intentionally keeps
CityRPG-specific mapping and gameplay policy out of the bridge.

Additional seed: `packages/orchestrator-core/src/traffic.js` now provides the
shared Desktop/CLI traffic snapshot. It reads bounded tails from
`runtime/events.jsonl` and `runtime/audit.jsonl`, redacted status from
`runtime/socket.json` and `runtime/bmf-bridge-status.json`, and recent
file-backed command request/response records. `bmfctl traffic --json` and the
BMF Desktop Traffic tab use this same observe-only snapshot.

Current Desktop seed: the Traffic tab now layers Material filters, selectable
timeline rows, selected-payload JSON rendering, copy-to-clipboard actions,
source/socket status, bounded live auto-refresh, pause/resume backpressure,
last-refresh status, and confirmed redacted trace export on top of the shared
snapshot. Export writes an anonymized support trace through Electron IPC using
the shared `traffic.trace.export` contract; the renderer still does not read or
write runtime files directly.

## Envelope Fields

Each displayed record should normalize to:

| Field | Purpose |
| --- | --- |
| `id` | Correlation id when available. |
| `timestamp` | When the record was produced or observed. |
| `type` | Event, command, response, status, log, or drop. |
| `event` | BMF event name, if applicable. |
| `command` | BMF command name, if applicable. |
| `source` | BMF, UE4SS, Omegga, plugin, native helper, or fallback file. |
| `transport` | Socket, JSONL, file command, Omegga bridge, or unknown. |
| `status` | Pending, ok, error, dropped, replayed, or fallback. |
| `payload` | Redacted structured payload. |
| `durationMs` | Command or handler duration when known. |
| `consumer` | Plugin/client that consumed or responded when known. |

## UI Features

Required features:

- event timeline;
- filter by event name, command, source, transport, status, and plugin;
- selected payload viewer with JSON formatting;
- copy payload;
- pause/resume live stream;
- enable/disable bounded live refresh without adding server probes;
- clear local view without clearing runtime files;
- show socket connected/disconnected state;
- show fallback mode when socket is unavailable;
- export a redacted trace for bug reports.

Useful later features:

- correlation grouping for command/response pairs;
- diff between two selected payloads;
- dropped/backpressure counter;
- replay selected command in a dry-run or explicit safe mode when supported.

## Safety Rules

The inspector must not add expensive server probes just to populate the UI.
It should observe existing socket events, JSONL records, command responses, and
telemetry summaries.

Payloads should be redacted before rendering or export:

- socket tokens;
- Grafana tokens;
- Steam credentials;
- API keys;
- private IPs when exporting support bundles;
- player identifiers when the export mode requests anonymization.

## Performance Guardrails

High-volume traffic must be bounded:

- cap retained records per profile session;
- coalesce repetitive status records;
- apply backpressure when the renderer is paused;
- avoid parsing large payloads on the game thread;
- record dropped/coalesced counts in local app diagnostics.

The socket makes inspection lower latency, not free. Any new BMF event producer
that touches Brickadia live state still needs feature flags and frame-time
validation before gameplay promotion.
