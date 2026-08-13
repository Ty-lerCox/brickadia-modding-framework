'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const net = require('node:net');
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');

const {
  BmfSocketClient,
  buildSafeCommandProbe,
  compareReports,
  metricsDelta,
  parseArgs,
  parseBrickadiaTimestamp,
  parsePrometheusSnapshot,
  resolveTunnelIdentity,
  summarize,
  waitForLogMarker,
} = require('./benchmark-bmf-command-tunnel.js');

test('parseArgs keeps gameplay probes explicitly opt-in and bounded', () => {
  assert.throws(
    () => parseArgs(['run', '--mode', 'command', '--player', 'Ty', '--log-path', 'Brickadia.log']),
    /--confirm-live/,
  );
  assert.throws(
    () =>
      parseArgs([
        'run',
        '--mode',
        'command',
        '--player',
        'Ty',
        '--log-path',
        'Brickadia.log',
        '--confirm-live',
        '--command-samples',
        '21',
      ]),
    /between 1 and 20/,
  );
  assert.throws(
    () =>
      parseArgs([
        'run',
        '--mode',
        'command',
        '--player',
        'Ty',
        '--log-path',
        'Brickadia.log',
        '--confirm-live',
        '--command-spacing-ms',
        '499',
      ]),
    /between 500 and 60000/,
  );
  assert.throws(
    () =>
      parseArgs([
        'run',
        '--mode',
        'command',
        '--player',
        'Ty',
        '--log-path',
        'Brickadia.log',
        '--confirm-live',
        '--bmf-command-template',
        'bmf.server.shutdown confirm=shutdown {command}',
      ]),
    /approved command-tunnel entrypoint/,
  );
  const args = parseArgs([
    'run',
    '--mode',
    'command',
    '--player',
    'Ty',
    '--log-path',
    'Brickadia.log',
    '--confirm-live',
  ]);
  assert.equal(args.commandSamples, 5);
  assert.equal(args.commandSpacingMs, 500);
  assert.equal(args.commandProtocol, 'legacy');
  assert.equal(
    parseArgs([
      'run',
      '--mode',
      'command',
      '--command-protocol',
      'tunnel',
      '--player',
      'Ty',
      '--log-path',
      'Brickadia.log',
      '--confirm-live',
    ]).commandProtocol,
    'tunnel',
  );
  assert.equal(parseArgs(['--help']).help, true);
});

test('safe probe always uses the fixed cityrpgRemote whisper shape', () => {
  const probe = buildSafeCommandProbe('Player One', 'MARKER:123');
  assert.equal(
    probe.opaqueCommand,
    '/cityrpgRemote whisper:Player One:MARKER:123',
  );
  assert.match(probe.bmfCommand, /^bmf\.chat\.player-message-impl message=%2FcityrpgRemote/);
  assert.match(decodeURIComponent(probe.bmfCommand), /whisper:Player One:MARKER:123/);
  assert.doesNotMatch(probe.bmfCommand, /[\r\n]/);
  assert.throws(() => buildSafeCommandProbe('Player:One', 'MARKER_123'), /player field/);
  assert.throws(() => buildSafeCommandProbe('Player One', 'MARKER\n123'), /line break/);
});

test('tunnel identity comes from one current player-cache record', t => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'bmf-tunnel-identity-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const socketPath = path.join(root, 'socket.json');
  fs.writeFileSync(socketPath, '{}');
  fs.writeFileSync(
    path.join(root, 'players.json'),
    JSON.stringify({
      players: [
        {
          uuid: '33333333-3333-4333-8333-333333333333',
          username: 'Ty',
          connectionGeneration: 7,
        },
      ],
    }),
  );

  assert.deepEqual(resolveTunnelIdentity(socketPath, 'ty'), {
    senderUuid: '33333333-3333-4333-8333-333333333333',
    senderName: 'Ty',
    connectionGeneration: 7,
    playersPath: path.join(root, 'players.json'),
  });

  fs.writeFileSync(
    path.join(root, 'players.json'),
    JSON.stringify({ players: [{ uuid: '33333333-3333-4333-8333-333333333333', username: 'Ty' }] }),
  );
  assert.throws(() => resolveTunnelIdentity(socketPath, 'Ty'), /incomplete or invalid/);
});

test('latency summaries use interpolated percentiles', () => {
  assert.deepEqual(summarize([1, 2, 3, 4]), {
    count: 4,
    min: 1,
    p50: 2.5,
    p90: 3.7,
    p95: 3.85,
    p99: 3.97,
    max: 4,
    mean: 2.5,
  });
});

test('Brickadia timestamps are parsed as UTC milliseconds', () => {
  const line = '[2026.07.20-03.40.49:659][243]LogBrickadia: [Wire Graph] Set Team Success';
  assert.equal(parseBrickadiaTimestamp(line), Date.UTC(2026, 6, 20, 3, 40, 49, 659));
  assert.equal(parseBrickadiaTimestamp('not a Brickadia line'), null);
});

test('Prometheus parsing and frame deltas retain guardrail thresholds', () => {
  const before = parsePrometheusSnapshot([
    'brickadia_server_up 1',
    'bmf_runtime_status_up 1',
    'brickadia_frame_delta_milliseconds{scope="window",statistic="avg"} 16.5',
    'brickadia_frame_delta_milliseconds{scope="window",statistic="max"} 20',
    'brickadia_frame_samples_total 100',
    'brickadia_frame_slow_total{threshold_ms="100"} 2',
  ].join('\n'));
  const after = parsePrometheusSnapshot([
    'brickadia_server_up 1',
    'bmf_runtime_status_up 1',
    'brickadia_frame_delta_milliseconds{scope="window",statistic="avg"} 16.665',
    'brickadia_frame_delta_milliseconds{scope="window",statistic="max"} 22',
    'brickadia_frame_samples_total 160',
    'brickadia_frame_slow_total{threshold_ms="100"} 2',
  ].join('\n'));
  const delta = metricsDelta({ data: before }, { data: after });
  assert.equal(delta.frameSamples, 60);
  assert.equal(delta.slowTotals['100'], 0);
  assert.equal(delta.windowAverageIncreasePercent, 1);
});

test('log marker observer only accepts bytes appended after it starts', async () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'bmf-tunnel-log-'));
  const logPath = path.join(root, 'Brickadia.log');
  fs.writeFileSync(logPath, '[2026.07.20-01.00.00:000][1] OLD_MARKER\n');
  const observer = waitForLogMarker(logPath, 'NEW_MARKER', 2000);
  setTimeout(() => {
    fs.appendFileSync(
      logPath,
      '[2026.07.20-01.00.00:125][2]LogChatCommands: NEW_MARKER\n',
    );
  }, 25);
  const result = await observer.promise;
  assert.match(result.line, /NEW_MARKER/);
  assert.equal(result.logTimestampEpochMs, Date.UTC(2026, 6, 20, 1, 0, 0, 125));
  fs.rmSync(root, { recursive: true, force: true });
});

test('socket client measures authenticated ping and command response RTT', async t => {
  const token = 'test-token';
  let authenticated = false;
  let tunnelRequest;
  const server = net.createServer(socket => {
    socket.setEncoding('utf8');
    let buffer = '';
    socket.on('data', chunk => {
      buffer += chunk;
      let newline = buffer.indexOf('\n');
      while (newline >= 0) {
        const line = buffer.slice(0, newline).trim();
        buffer = buffer.slice(newline + 1);
        newline = buffer.indexOf('\n');
        if (!line) continue;
        const message = JSON.parse(line);
        if (message.type === 'hello') {
          authenticated = message.token === token;
          continue;
        }
        assert.equal(authenticated, true);
        if (message.type === 'ping') {
          socket.write(`${JSON.stringify({ type: 'pong', id: message.id, source: 'bmf' })}\n`);
        } else if (message.type === 'command') {
          socket.write(`${JSON.stringify({
            type: 'response',
            id: message.id,
            source: 'bmf',
            ok: true,
            response: 'ok=true\nimplementation_called=true\n',
          })}\n`);
        } else if (message.type === 'tunnel.request') {
          tunnelRequest = message;
          socket.write(`${JSON.stringify({
            type: 'tunnel.ack',
            id: message.id,
            source: 'bmf',
            state: 'accepted',
            queueDepth: 1,
          })}\n`);
          socket.write(`${JSON.stringify({
            type: 'tunnel.result',
            id: message.id,
            source: 'bmf',
            state: 'injected',
            code: 'OK',
            dispatchMs: 2,
            queueDepth: 0,
          })}\n`);
        }
      }
    });
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));

  const client = new BmfSocketClient(
    { host: '127.0.0.1', port: server.address().port, token },
    { timeoutMs: 1000 },
  );
  await client.connect();
  t.after(async () => {
    client.close();
    await new Promise(resolve => server.close(resolve));
  });
  const ping = await client.ping().promise;
  const command = await client.command('bmf.status').promise;
  const tunnel = await client.tunnel('/cityrpgRemote whisper:Ty:MARKER').promise;
  assert.ok(ping.durationMs >= 0);
  assert.equal(command.message.ok, true);
  assert.match(command.message.response, /implementation_called=true/);
  assert.equal(tunnel.message.state, 'injected');
  assert.ok(tunnel.ackDurationMs >= 0);
  assert.ok(tunnelRequest.deadlineMs > 1_000_000_000_000);
  assert.ok(tunnelRequest.deadlineMs > tunnelRequest.issuedAtMs);
});

test('before/after comparison calculates speedup and regression gates', () => {
  const report = (label, socketP95, commandP95) => ({
    feature: 'bmf-command-tunnel-benchmark',
    label,
    status: 'passed',
    measurements: {
      socketPing: { summary: { p95: socketP95 } },
      commandResponse: { summary: { p95: commandP95 } },
      consoleCompletion: { summary: { p95: commandP95 } },
    },
    metrics: { delta: { slowTotals: { 100: 0 } } },
  });
  const result = compareReports(report('before', 200, 250), report('after', 80, 90), {
    maxSocketP95Ms: 100,
    maxCommandP95Ms: 100,
    maxP95RegressionPercent: 5,
    maxNew100MsFrames: 0,
  });
  assert.equal(result.passed, true);
  assert.equal(result.comparisons[0].speedup, 2.5);
  assert.equal(result.comparisons[1].speedup, 2.778);
});
