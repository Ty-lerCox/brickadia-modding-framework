const { spawn } = require('node:child_process');
const fs = require('node:fs');
const path = require('node:path');
const readline = require('node:readline');

const omeggaDir = process.argv[2] || path.resolve(__dirname, '..');
const bridgeRoot = path.join(omeggaDir, 'data', 'ue4ss-bridge');
const startupTimeoutMs = Number(process.env.OMEGGA_PROBE_STARTUP_TIMEOUT_MS || 180_000);
const commandTimeoutMs = Number(process.env.OMEGGA_PROBE_COMMAND_TIMEOUT_MS || 30_000);

const child = spawn('node', ['--enable-source-maps', 'index.js', '-v'], {
  cwd: omeggaDir,
  env: {
    ...process.env,
    NO_COLOR: '1',
    FORCE_COLOR: '0',
  },
  stdio: ['pipe', 'pipe', 'pipe'],
  windowsHide: true,
});

const lines = [];
let exited = false;
let exitCode = null;
let exitSignal = null;

function logLine(channel, line) {
  const entry = `[${channel}] ${line}`;
  lines.push(entry);
  console.log(entry);
}

function createLineReader(stream, channel) {
  const rl = readline.createInterface({ input: stream });
  rl.on('line', line => logLine(channel, line));
  return rl;
}

const stdoutReader = createLineReader(child.stdout, 'stdout');
const stderrReader = createLineReader(child.stderr, 'stderr');

child.on('exit', (code, signal) => {
  exited = true;
  exitCode = code;
  exitSignal = signal;
  logLine('probe', `child exited code=${code} signal=${signal}`);
});

function getLatestBridgeSessionDir(afterMs = 0) {
  if (!fs.existsSync(bridgeRoot)) return null;
  const sessionDirs = fs
    .readdirSync(bridgeRoot, { withFileTypes: true })
    .filter(entry => entry.isDirectory())
    .map(entry => path.join(bridgeRoot, entry.name))
    .filter(dir => {
      if (!afterMs) return true;
      return fs.statSync(dir).mtimeMs >= afterMs;
    })
    .sort((left, right) => fs.statSync(right).mtimeMs - fs.statSync(left).mtimeMs);
  return sessionDirs[0] ?? null;
}

function readOutbox(sessionDir) {
  if (!sessionDir) return '';
  const outboxPath = path.join(sessionDir, 'outbox.ndjson');
  if (!fs.existsSync(outboxPath)) return '';
  return fs.readFileSync(outboxPath, 'utf8');
}

function appendInboxMessage(sessionDir, payload) {
  const inboxPath = path.join(sessionDir, 'inbox.ndjson');
  fs.appendFileSync(inboxPath, JSON.stringify(payload) + '\n', 'utf8');
}

function encode(text) {
  return Buffer.from(text, 'utf8').toString('base64');
}

async function waitFor(predicate, timeoutMs, label) {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    const result = predicate();
    if (result) return result;
    if (exited) {
      throw new Error(
        `Probe target exited before ${label} completed. code=${exitCode} signal=${exitSignal}`
      );
    }
    if (Date.now() >= deadline) return null;
    await new Promise(resolve => setTimeout(resolve, 200));
  }
}

async function stopChild() {
  if (exited) return;

  try {
    child.stdin.write('/stop\n');
  } catch {}

  const deadline = Date.now() + 15_000;
  while (!exited && Date.now() < deadline) {
    await new Promise(resolve => setTimeout(resolve, 200));
  }

  if (!exited) {
    const killer = spawn('taskkill', ['/PID', String(child.pid), '/T', '/F'], {
      stdio: 'ignore',
      windowsHide: true,
    });
    await new Promise(resolve => killer.on('exit', resolve));
  }
}

async function main() {
  const startedAt = Date.now();

  const startup = await waitFor(
    () =>
      lines.find(
        line =>
          /Server has started/.test(line) ||
          /Server has closed/.test(line) ||
          /Select authentication method/.test(line) ||
          /Server failed authentication check/.test(line)
      ),
    startupTimeoutMs,
    'startup'
  );

  if (!startup) {
    throw new Error(`Timed out waiting for startup after ${startupTimeoutMs}ms`);
  }
  if (/Select authentication method/.test(startup)) {
    throw new Error('Omegga requested interactive authentication during the probe');
  }
  if (/Server failed authentication check/.test(startup)) {
    throw new Error('Brickadia authentication failed during the probe');
  }
  if (/Server has closed/.test(startup)) {
    throw new Error('Brickadia server closed before startup completed');
  }

  const mapLoaded = await waitFor(
    () => lines.find(line => /Map changed to/.test(line) || /World successfully loaded/.test(line)),
    60_000,
    'map load'
  );
  if (!mapLoaded) {
    throw new Error('Timed out waiting for the initial map load');
  }

  const sessionDir = await waitFor(
    () => getLatestBridgeSessionDir(startedAt - 1000),
    10_000,
    'bridge session'
  );
  if (!sessionDir) {
    throw new Error('No fresh bridge session was created');
  }

  logLine('probe', `bridge session=${sessionDir}`);

  const helloSeen = await waitFor(
    () => readOutbox(sessionDir).includes('"method":"bridge.hello"'),
    10_000,
    'bridge hello'
  );
  if (!helloSeen) {
    throw new Error('Bridge hello was not observed in outbox');
  }

  appendInboxMessage(sessionDir, {
    jsonrpc: '2.0',
    id: 901,
    method: 'console.exec',
    params: {
      command_b64: encode('Omegga.Bridge.ProbeChatApi'),
    },
  });

  const probeResult = await waitFor(
    () => {
      const outbox = readOutbox(sessionDir);
      return outbox.includes('"request_id":901') ? outbox : null;
    },
    commandTimeoutMs,
    'probe chat api response'
  );

  appendInboxMessage(sessionDir, {
    jsonrpc: '2.0',
    id: 902,
    method: 'chat.broadcast',
    params: {
      message_b64: encode('Hello from proof run'),
    },
  });

  const chatResult = await waitFor(
    () => {
      const outbox = readOutbox(sessionDir);
      return outbox.includes('"request_id":902') ? outbox : null;
    },
    commandTimeoutMs,
    'chat broadcast response'
  );

  const finalOutbox = readOutbox(sessionDir);
  const result = {
    sessionDir,
    probeResponseSeen: Boolean(probeResult),
    chatResponseSeen: Boolean(chatResult),
    childExited: exited,
  };

  logLine('probe-result', JSON.stringify(result));
  logLine('probe-outbox', '--- begin outbox tail ---');
  for (const line of finalOutbox.split(/\r?\n/).slice(-80)) {
    if (line.length > 0) logLine('probe-outbox', line);
  }
  logLine('probe-outbox', '--- end outbox tail ---');
}

(async () => {
  try {
    await main();
    process.exitCode = 0;
  } catch (error) {
    logLine('probe-error', error instanceof Error ? error.message : String(error));
    process.exitCode = 1;
  } finally {
    stdoutReader.close();
    stderrReader.close();
    await stopChild();
  }
})();
