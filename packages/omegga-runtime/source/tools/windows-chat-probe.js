const { spawn } = require('node:child_process');
const fs = require('node:fs');
const path = require('node:path');
const readline = require('node:readline');

const omeggaDir = process.argv[2] || path.resolve(__dirname, '..');
const startupTimeoutMs = Number(process.env.OMEGGA_PROBE_STARTUP_TIMEOUT_MS || 180_000);
const probeTimeoutMs = Number(process.env.OMEGGA_PROBE_COMMAND_TIMEOUT_MS || 12_000);
const settleAfterStartMs = Number(process.env.OMEGGA_PROBE_SETTLE_MS || 15_000);
const bridgeRoot = path.join(omeggaDir, 'data', 'ue4ss-bridge');
const diagnosticCommand =
  process.env.OMEGGA_PROBE_DIAGNOSTIC_COMMAND || 'Omegga.Bridge.ProbeChatApi';
const directCommand =
  process.env.OMEGGA_PROBE_DIRECT_COMMAND || 'Chat.Broadcast Hello from bridge';
const terminalBroadcastText = process.env.OMEGGA_PROBE_TERMINAL_BROADCAST || '';

const child = spawn('node', ['--enable-source-maps', 'index.js', '-d', '-v'], {
  cwd: omeggaDir,
  env: {
    ...process.env,
    NO_COLOR: '1',
    FORCE_COLOR: '0',
    OMEGGA_UE4SS_CHAT_TRACE: process.env.OMEGGA_UE4SS_CHAT_TRACE || '1',
  },
  stdio: ['pipe', 'pipe', 'pipe'],
  windowsHide: true,
});

const lines = [];
let exitCode = null;
let exitSignal = null;
let exited = false;

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

function sleep(ms) {
  return new Promise(resolve => setTimeout(resolve, ms));
}

function readOptionalFile(filePath) {
  if (!filePath || !fs.existsSync(filePath)) return '';
  return fs.readFileSync(filePath, 'utf8');
}

function getLatestBridgeSessionDir() {
  if (!fs.existsSync(bridgeRoot)) return null;
  const sessionDirs = fs
    .readdirSync(bridgeRoot, { withFileTypes: true })
    .filter(entry => entry.isDirectory())
    .map(entry => path.join(bridgeRoot, entry.name))
    .sort((left, right) => fs.statSync(right).mtimeMs - fs.statSync(left).mtimeMs);
  return sessionDirs[0] ?? null;
}

function tailLines(value, count) {
  const list = String(value || '').split(/\r?\n/).filter(Boolean);
  return list.slice(Math.max(0, list.length - count));
}

function matchLine(patterns) {
  for (const line of lines) {
    for (const pattern of patterns) {
      if (pattern.test(line)) return line;
    }
  }
  return null;
}

async function waitForPatterns(patterns, timeoutMs, label) {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    const matched = matchLine(patterns);
    if (matched) return matched;

    if (exited) {
      throw new Error(
        `Probe target exited before ${label} completed. code=${exitCode} signal=${exitSignal}`,
      );
    }

    if (Date.now() >= deadline) return null;
    await sleep(200);
  }
}

async function stopChild() {
  if (exited) return;

  try {
    child.stdin.write('/stop\n');
  } catch {}

  const deadline = Date.now() + 15_000;
  while (!exited && Date.now() < deadline) {
    await sleep(200);
  }

  if (!exited) {
    child.kill('SIGTERM');
    const taskkill = spawn('taskkill', ['/PID', String(child.pid), '/T', '/F'], {
      stdio: 'ignore',
      windowsHide: true,
    });
    await new Promise(resolve => taskkill.on('exit', resolve));
  }
}

function snapshotOutbox(sessionDir) {
  return readOptionalFile(sessionDir ? path.join(sessionDir, 'outbox.ndjson') : '').length;
}

function readOutboxDelta(sessionDir, startOffset) {
  return readOptionalFile(sessionDir ? path.join(sessionDir, 'outbox.ndjson') : '').slice(startOffset);
}

async function sendCommand(sessionDir, label, input) {
  const outboxOffset = snapshotOutbox(sessionDir);
  logLine('probe', `sending ${label}: ${input}`);
  child.stdin.write(`${input}\n`);
  await sleep(probeTimeoutMs);
  return readOutboxDelta(sessionDir, outboxOffset);
}

function summarizeOutboxDelta(delta) {
  const executor = delta.match(/"executor":"([^"]+)"/)?.[1] ?? null;
  const message = delta.match(/"message":"([^"]+)"/)?.[1] ?? null;
  const data = delta.match(/"data":"([^"]*)"/)?.[1] ?? null;
  return {
    accepted: /"accepted":true/.test(delta),
    executor,
    message,
    data,
    raw: delta,
  };
}

const stdoutReader = createLineReader(child.stdout, 'stdout');
const stderrReader = createLineReader(child.stderr, 'stderr');

child.on('exit', (code, signal) => {
  exited = true;
  exitCode = code;
  exitSignal = signal;
  logLine('probe', `child exited code=${code} signal=${signal}`);
});

(async () => {
  try {
    const started = await waitForPatterns(
      [/Server has started/, /Select authentication method/, /Server failed authentication check/],
      startupTimeoutMs,
      'startup',
    );
    if (!started) throw new Error(`Timed out waiting for startup after ${startupTimeoutMs}ms`);
    if (/Select authentication method/.test(started)) {
      throw new Error('Omegga requested interactive authentication during the probe');
    }
    if (/Server failed authentication check/.test(started)) {
      throw new Error('Brickadia authentication failed during the probe');
    }

    await sleep(settleAfterStartMs);
    const mapLoaded =
      matchLine([/Map changed to/, /World successfully loaded/]) ||
      matchLine([/ProcessServerTravel/, /Server switch level:/]);

    const bridgeSessionDir = getLatestBridgeSessionDir();
    const chatTracePath = bridgeSessionDir ? path.join(bridgeSessionDir, 'chat-trace.log') : null;

    logLine('probe', `bridge session=${bridgeSessionDir ?? 'unknown'}`);
    logLine('probe', `chat trace=${chatTracePath ?? 'unknown'}`);

    const diagnosticDelta = diagnosticCommand
      ? await sendCommand(bridgeSessionDir, 'diagnostic', `/cmd ${diagnosticCommand}`)
      : '';
    const directDelta = directCommand
      ? await sendCommand(bridgeSessionDir, 'direct', `/cmd ${directCommand}`)
      : '';
    const terminalDelta = terminalBroadcastText
      ? await sendCommand(bridgeSessionDir, 'terminal', terminalBroadcastText)
      : '';

    const chatTraceContents = readOptionalFile(chatTracePath);
    const chatTraceTail = tailLines(chatTraceContents, 80);

    const result = {
      startupMatched: started,
      mapMatched: mapLoaded,
      settleAfterStartMs,
      bridgeSessionDir,
      chatTracePath,
      diagnosticCommand,
      diagnostic: summarizeOutboxDelta(diagnosticDelta),
      directCommand,
      direct: summarizeOutboxDelta(directDelta),
      terminalBroadcastText: terminalBroadcastText || null,
      terminal: summarizeOutboxDelta(terminalDelta),
      hookObserved:
        /hook .*Chat/i.test(chatTraceContents) ||
        /attempt direct succeeded/i.test(chatTraceContents) ||
        /attempt call-by-name succeeded/i.test(chatTraceContents),
      chatTraceTail,
    };

    logLine('probe-result', JSON.stringify(result));

    if (chatTraceTail.length > 0) {
      logLine('chat-trace', '--- begin chat trace tail ---');
      for (const line of chatTraceTail) logLine('chat-trace', line);
      logLine('chat-trace', '--- end chat trace tail ---');
    }

    process.exitCode = result.direct.accepted || result.hookObserved ? 0 : 1;
  } catch (error) {
    logLine('probe-error', error instanceof Error ? error.message : String(error));
    process.exitCode = 1;
  } finally {
    stdoutReader.close();
    stderrReader.close();
    await stopChild();
  }
})();
