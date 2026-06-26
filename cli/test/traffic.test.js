const assert = require('node:assert/strict');
const net = require('node:net');
const path = require('node:path');
const test = require('node:test');
const { makeEnvironment, write } = require('./helpers');
const { createTrafficReport } = require('../src/orchestrator');
const { resetTrafficSocketClients } = require('../../packages/orchestrator-core/src');

async function createTrafficSocketServer(t, options = {}) {
  const token = options.token || 'socket-token';
  const received = [];
  const server = net.createServer(socket => {
    socket.setEncoding('utf8');
    let buffer = '';
    socket.on('data', chunk => {
      buffer += String(chunk || '');
      let index = buffer.indexOf('\n');
      while (index >= 0) {
        const line = buffer.slice(0, index).trim();
        buffer = buffer.slice(index + 1);
        if (line) {
          const message = JSON.parse(line);
          received.push(message);
          if (message.type === 'hello' && message.token === token) {
            for (const envelope of options.envelopes || []) {
              socket.write(`${JSON.stringify(envelope)}\n`);
            }
          }
        }
        index = buffer.indexOf('\n');
      }
    });
  });
  t.after(() => {
    resetTrafficSocketClients();
    server.close();
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  return { token, received, port: server.address().port };
}

async function waitForTrafficReport(options, predicate) {
  let snapshot = createTrafficReport(options);
  for (let attempt = 0; attempt < 50; attempt += 1) {
    if (predicate(snapshot)) return snapshot;
    await new Promise(resolve => setTimeout(resolve, 20));
    snapshot = createTrafficReport(options);
  }
  return snapshot;
}

test('bmfctl traffic returns bounded redacted socket envelopes', async t => {
  const env = makeEnvironment();
  const runtimeDir = path.join(env.liveMods, 'BMF', 'runtime');
  const socketServer = await createTrafficSocketServer(t, {
    envelopes: [
      {
        type: 'event',
        source: 'bmf',
        ts: '2026-06-16T12:00:00Z',
        record: {
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
        },
      },
      {
        type: 'response',
        source: 'bmf',
        ts: '2026-06-16T12:01:00Z',
        id: 'socket-response',
        ok: true,
        detail: 'ok',
        response: [
          'ok=true',
          'detail=ok',
          'command=bmf.status token=response-token',
          'bmf_command_total_ms=9',
        ].join('\n'),
      },
    ],
  });

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
      port: socketServer.port,
      token: socketServer.token,
    }),
  );

  const snapshot = await waitForTrafficReport({
    ...env.options,
    limit: 10,
  }, report => report.records.some(record => record.event === 'interactConsole'));

  assert.ok(snapshot.summary.retained >= 2);
  assert.ok(snapshot.sources.some(source => source.id === 'socket-stream' && source.status === 'connected'));
  assert.equal(snapshot.sources.some(source => source.id === 'events-jsonl'), false);
  assert.ok(snapshot.records.some(record => record.event === 'interactConsole'));
  assert.equal(snapshot.records.find(record => record.type === 'response').durationMs, 9);
  assert.equal(JSON.stringify(snapshot).includes('event-token'), false);
  assert.equal(JSON.stringify(snapshot).includes(socketServer.token), false);
  assert.equal(JSON.stringify(snapshot).includes('response-token'), false);
  assert.ok(snapshot.guardrails.includes('bounded-record-retention'));
  assert.ok(socketServer.received.some(message => message.type === 'subscribe'));
});
