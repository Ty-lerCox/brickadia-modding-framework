const assert = require('node:assert/strict');
const path = require('node:path');
const test = require('node:test');
const { makeEnvironment, write } = require('./helpers');
const { createTrafficReport } = require('../src/orchestrator');

test('bmfctl traffic returns bounded redacted runtime envelopes', () => {
  const env = makeEnvironment();
  const runtimeDir = path.join(env.liveMods, 'BMF', 'runtime');
  const commandDir = path.join(runtimeDir, 'commands');

  write(
    path.join(runtimeDir, 'events.jsonl'),
    JSON.stringify({
      ts: '2026-06-16T12:00:00Z',
      source: 'event',
      data: {
        event: 'interactConsole',
        payload: {
          message: 'hit',
          token: 'event-token',
        },
        ok: true,
      },
    }) + '\n',
  );
  write(
    path.join(runtimeDir, 'socket.json'),
    JSON.stringify({
      enabled: true,
      host: '127.0.0.1',
      port: 49152,
      token: 'socket-token',
    }),
  );
  write(
    path.join(commandDir, 'bmf_bridge_1781611440000_1.response.txt'),
    [
      'ok=true',
      'detail=ok',
      'command=bmf.status token=response-token',
      'bmf_command_total_ms=9',
    ].join('\n') + '\n',
  );

  const snapshot = createTrafficReport({
    ...env.options,
    limit: 10,
  });

  assert.equal(snapshot.summary.retained, 3);
  assert.ok(snapshot.sources.some(source => source.id === 'events-jsonl' && source.records === 1));
  assert.ok(snapshot.records.some(record => record.event === 'interactConsole'));
  assert.equal(snapshot.records.find(record => record.type === 'response').durationMs, 9);
  assert.equal(JSON.stringify(snapshot).includes('event-token'), false);
  assert.equal(JSON.stringify(snapshot).includes('socket-token'), false);
  assert.equal(JSON.stringify(snapshot).includes('response-token'), false);
  assert.ok(snapshot.guardrails.includes('bounded-record-retention'));
});
