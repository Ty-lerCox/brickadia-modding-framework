const assert = require('assert');
const fs = require('fs');
const net = require('net');
const os = require('os');
const path = require('path');
const test = require('node:test');

const BmfBridge = require('./omegga.plugin');

function tempRoot(t) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'bmf-bridge-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  return root;
}

function eventRecord(event, payload = {}) {
  return {
    level: 'info',
    message: `event emitted: ${event}`,
    source: 'event',
    ts: '2026-06-16T12:00:00Z',
    data: {
      event,
      payload,
      handlers: 1,
      errors: [],
      ok: true,
    },
  };
}

test('normalizes event records and redacts retained payload secrets', () => {
  const envelope = BmfBridge.normalizeEnvelope(eventRecord('resource.hit', {
    player: {
      id: '33333333-3333-4333-8333-333333333333',
      token: 'do-not-show',
    },
    endpoint: 'http://192.168.1.20:3000',
    _bmf: {
      eventId: '42',
      source: 'native.BMFSocketResourceNative',
    },
  }), {
    transport: 'events-jsonl',
    redactPrivateIps: true,
  });

  assert.strictEqual(envelope.id, '42');
  assert.strictEqual(envelope.type, 'event');
  assert.strictEqual(envelope.event, 'resource.hit');
  assert.strictEqual(envelope.transport, 'events-jsonl');
  assert.strictEqual(envelope.source, 'native.BMFSocketResourceNative');
  assert.strictEqual(envelope.payload.player.token, '[redacted]');
  assert.strictEqual(envelope.payload.endpoint, 'http://[private-ip]:3000');
  assert.ok(envelope.redactions >= 2);
});

test('tails event log fallback, applies bounded retention, and delivers subscribers', async t => {
  const root = tempRoot(t);
  const eventLogPath = path.join(root, 'events.jsonl');
  const bridge = new BmfBridge(
    {},
    {
      runtimeDir: root,
      eventLogPath,
      maxRecords: 2,
      readExistingEventLog: true,
      tailEvents: false,
    }
  );
  const delivered = [];
  bridge.subscribe('*', record => delivered.push(record));

  for (const event of ['one', 'two', 'three']) {
    fs.appendFileSync(eventLogPath, `${JSON.stringify(eventRecord(event, { token: `${event}-token` }))}\n`, 'utf8');
    bridge.pollEventLog();
  }

  assert.deepStrictEqual(delivered.map(record => record.event), ['one', 'two', 'three']);
  assert.deepStrictEqual(bridge.recentRecords().map(record => record.event), ['two', 'three']);
  assert.strictEqual(bridge.counters.dropped, 1);
  assert.strictEqual(bridge.recentRecords()[0].payload.token, '[redacted]');
});

test('file fallback command writes request and records response envelope', async t => {
  const root = tempRoot(t);
  const commandDir = path.join(root, 'commands');
  const bridge = new BmfBridge(
    {},
    {
      runtimeDir: root,
      commandDir,
      tailEvents: false,
      commandTimeoutMs: 1000,
    }
  );

  const responsePromise = bridge.invokeCommand('bmf.status token=secret', { transport: 'file-command' });
  while (!fs.existsSync(commandDir) || fs.readdirSync(commandDir).filter(file => file.endsWith('.request.txt')).length === 0) {
    await new Promise(resolve => setTimeout(resolve, 10));
  }
  const requestFile = fs.readdirSync(commandDir).find(file => file.endsWith('.request.txt'));
  const requestId = path.basename(requestFile, '.request.txt');
  assert.strictEqual(fs.readFileSync(path.join(commandDir, requestFile), 'utf8'), 'bmf.status token=secret');
  fs.writeFileSync(
    path.join(commandDir, `${requestId}.response.txt`),
    ['ok=true', 'detail=healthy', 'command=bmf.status', 'BMF bmf.status OK', ''].join('\n'),
    'utf8'
  );

  const response = await responsePromise;
  assert.strictEqual(response.ok, true);
  assert.strictEqual(response.detail, 'healthy');
  assert.strictEqual(response.transport, 'file-command');
  const records = bridge.recentRecords();
  assert.strictEqual(records[0].type, 'command');
  assert.strictEqual(records[0].payload.command, 'bmf.status token=[redacted]');
  assert.strictEqual(records[1].type, 'response');
  assert.strictEqual(records[1].status, 'ok');
});

test('socket transport sends hello, subscribes, receives events, and resolves commands', async t => {
  const root = tempRoot(t);
  const received = [];
  const server = net.createServer(socket => {
    socket.setEncoding('utf8');
    let buffer = '';
    socket.on('data', chunk => {
      buffer += chunk;
      let index = buffer.indexOf('\n');
      while (index >= 0) {
        const line = buffer.slice(0, index).trim();
        buffer = buffer.slice(index + 1);
        if (line) {
          const message = JSON.parse(line);
          received.push(message);
          if (message.type === 'subscribe') {
            socket.write(`${JSON.stringify({ type: 'event', source: 'bmf', ts: '2026-06-16T12:00:00Z', record: eventRecord('serverReady', { ok: true }) })}\n`);
          }
          if (message.type === 'command') {
            socket.write(`${JSON.stringify({ type: 'response', source: 'bmf', id: message.id, ok: true, detail: 'ok', response: 'ok=true\ndetail=ok\ncommand=bmf.status\n' })}\n`);
          }
        }
        index = buffer.indexOf('\n');
      }
    });
  });
  t.after(() => server.close());
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const port = server.address().port;
  fs.writeFileSync(
    path.join(root, 'socket.json'),
    JSON.stringify({
      enabled: true,
      host: '127.0.0.1',
      port,
      token: 'socket-token',
    }),
    'utf8'
  );

  const bridge = new BmfBridge(
    {},
    {
      runtimeDir: root,
      tailEvents: false,
      socketReconnectMs: 0,
      commandTimeoutMs: 1000,
    }
  );
  t.after(() => bridge.stop());
  await bridge.init();

  while (!bridge.socketReady() || bridge.recentRecords({ filter: { event: 'serverReady' } }).length === 0) {
    await new Promise(resolve => setTimeout(resolve, 10));
  }

  const response = await bridge.invokeCommand('bmf.status');
  assert.strictEqual(response.ok, true);
  assert.strictEqual(response.transport, 'socket');
  assert.ok(received.find(message => message.type === 'hello' && message.token === 'socket-token'));
  assert.ok(received.find(message => message.type === 'subscribe'));
  assert.ok(received.find(message => message.type === 'command' && message.command === 'bmf.status'));
  assert.strictEqual(bridge.recentRecords({ filter: { event: 'serverReady' } })[0].transport, 'socket');
});

test('pause skips subscriber delivery without unbounded retention', () => {
  const bridge = new BmfBridge({}, { maxRecords: 1, tailEvents: false });
  const delivered = [];
  bridge.subscribe('*', record => delivered.push(record));
  bridge.setPaused(true);
  bridge.recordEnvelope(eventRecord('paused.one'), { transport: 'events-jsonl' });
  bridge.recordEnvelope(eventRecord('paused.two'), { transport: 'events-jsonl' });

  assert.deepStrictEqual(delivered, []);
  assert.strictEqual(bridge.recentRecords().length, 1);
  assert.strictEqual(bridge.recentRecords()[0].event, 'paused.two');
  assert.strictEqual(bridge.counters.pausedSkipped, 2);
  assert.strictEqual(bridge.counters.dropped, 1);
});
