# BMF Bridge

Generic Omegga bridge for BMF command and event traffic.

The bridge is intentionally game-mode neutral. It does not map CityRPG events,
does not probe Brickadia state for the UI, and does not create gameplay events.
It observes the existing BMF socket stream and exposes a small helper API for
Omegga plugins and BMF Desktop. Runtime JSONL files may exist as diagnostic
evidence from other components, but this bridge does not tail them or route
commands through files.

## Runtime Sources

Supported live path:

```text
BMF Lua -> BMFSocket -> Omegga socket broker -> bmf-bridge subscribers
```

Socket discovery uses `OMEGGA_BMF_SOCKET_*` first, then
`Mods/BMF/runtime/socket.json`. If the socket is unavailable, the bridge reports
an unhealthy/disconnected state instead of silently routing live traffic through
files.

## Plugin Helpers

Other Omegga plugins can use the loaded plugin instance directly:

```js
const subscriptionId = bridge.subscribe('minigames.joinminigame', record => {
  console.log(record.event, record.payload);
});

const response = await bridge.invokeCommand('bmf.status');
bridge.unsubscribe(subscriptionId);
```

Adapters loaded as separate Omegga plugins should use Omegga plugin interop:

```js
const bridge = await omegga.getPlugin('BMF Bridge');
await bridge.emitPlugin('invokeCommand', 'bmf.status', { timeoutMs: 5000 });
```

Records normalize to the BMF Desktop event-inspector envelope:

- `id`
- `timestamp`
- `type`
- `event`
- `command`
- `source`
- `transport`
- `status`
- `payload`
- `durationMs`
- `consumer`

The bridge retains a bounded in-memory buffer and drops oldest records once
`maxRecords` is reached. Payloads are redacted before retention and before
subscriber delivery.

## Commands

Registered Omegga command:

```text
/bmfbridge [status|pause|resume]
```

`status` reports transport, socket health, retained record counts, drops,
coalesced status records, socket command counts, and parse errors.

`pause` stops subscriber delivery while keeping bounded diagnostics. `resume`
re-enables delivery. This gives BMF Desktop a backpressure hook when its event
traffic view is paused.

## Safety

This plugin is an observer and command transport helper. It does not start native probes, scan live objects, or poll Brickadia gameplay state to populate the UI.
Any future event producer that reads live server state still needs its own
feature flag and frame-time validation.
