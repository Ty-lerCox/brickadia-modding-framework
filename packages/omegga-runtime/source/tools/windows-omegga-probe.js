const { spawn } = require('node:child_process');
const fs = require('node:fs');
const path = require('node:path');
const readline = require('node:readline');

const omeggaDir =
  process.argv[2] || path.resolve(__dirname, '..');
const startupTimeoutMs = Number(process.env.OMEGGA_PROBE_STARTUP_TIMEOUT_MS || 180_000);
const commandTimeoutMs = Number(process.env.OMEGGA_PROBE_COMMAND_TIMEOUT_MS || 45_000);
const traceFile = path.join(omeggaDir, 'windows-bridge-trace.log');
const bridgeRoot = path.join(omeggaDir, 'data', 'ue4ss-bridge');
const echoChunkB64 = Buffer.from('Omegga bridge self-test ok', 'utf8').toString('base64');
const statusChunkB64 = Buffer.from('Server Name: Brickadia Windows UE4SS', 'utf8').toString(
  'base64'
);

if (fs.existsSync(traceFile)) {
  fs.rmSync(traceFile, { force: true });
}

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

const stdoutReader = createLineReader(child.stdout, 'stdout');
const stderrReader = createLineReader(child.stderr, 'stderr');

child.on('exit', (code, signal) => {
  exited = true;
  exitCode = code;
  exitSignal = signal;
  logLine('probe', `child exited code=${code} signal=${signal}`);
});

function matchLine(patterns) {
  for (const line of lines) {
    for (const pattern of patterns) {
      if (pattern.test(line)) {
        return { line, pattern };
      }
    }
  }
  return null;
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

function readOutbox(sessionDir) {
  if (!sessionDir) return '';
  const outboxPath = path.join(sessionDir, 'outbox.ndjson');
  if (!fs.existsSync(outboxPath)) return '';
  return fs.readFileSync(outboxPath, 'utf8');
}

async function waitForPatterns(patterns, timeoutMs, label) {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    const matched = matchLine(patterns);
    if (matched) {
      return matched;
    }

    if (exited) {
      throw new Error(
        `Probe target exited before ${label} completed. code=${exitCode} signal=${exitSignal}`
      );
    }

    if (Date.now() >= deadline) {
      return null;
    }

    await new Promise(resolve => setTimeout(resolve, 200));
  }
}

async function waitForOutbox(pattern, timeoutMs, label, sessionDir) {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    const contents = readOutbox(sessionDir);
    if (pattern.test(contents)) {
      return true;
    }

    if (exited) {
      throw new Error(
        `Probe target exited before ${label} completed. code=${exitCode} signal=${exitSignal}`
      );
    }

    if (Date.now() >= deadline) {
      return false;
    }

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
    child.kill('SIGTERM');
    const taskkill = spawn('taskkill', ['/PID', String(child.pid), '/T', '/F'], {
      stdio: 'ignore',
      windowsHide: true,
    });
    await new Promise(resolve => taskkill.on('exit', resolve));
  }
}

(async () => {
  const startupPatterns = [
    /Server has started/,
    /Select authentication method/,
    /Server failed authentication check/,
  ];
  const mapPatterns = [
    /Map changed to/,
    /World successfully loaded/,
  ];
  const statusPatterns = [
    /Server Status/,
    /An error occurred while getting server status/,
    /Server Not Responding/,
    /Server caught unhandled exception/,
  ];

  try {
    const started = await waitForPatterns(startupPatterns, startupTimeoutMs, 'startup');
    if (!started) {
      throw new Error(`Timed out waiting for startup after ${startupTimeoutMs}ms`);
    }
    if (/Select authentication method/.test(started.line)) {
      throw new Error('Omegga requested interactive authentication during the probe');
    }
    if (/Server failed authentication check/.test(started.line)) {
      throw new Error('Brickadia authentication failed during the probe');
    }

    const mapLoaded = await waitForPatterns(mapPatterns, 60_000, 'map load');
    if (!mapLoaded) {
      throw new Error('Timed out waiting for the initial map load');
    }

    const bridgeSessionDir = getLatestBridgeSessionDir();
    logLine('probe', `bridge session=${bridgeSessionDir ?? 'unknown'}`);

    logLine('probe', 'sending /cmd Omegga.Bridge.Echo');
    child.stdin.write('/cmd Omegga.Bridge.Echo\n');
    const selfTestResult = await waitForOutbox(
      new RegExp(`"line_b64":"${echoChunkB64}"`),
      15_000,
      'bridge self-test command',
      bridgeSessionDir
    );

    logLine('probe', 'sending /status');
    child.stdin.write('/status\n');
    const statusResult = await waitForPatterns(
      statusPatterns,
      commandTimeoutMs,
      'status command'
    );

    logLine('probe', 'sending /cmd Server.Status');
    child.stdin.write('/cmd Server.Status\n');
    const rawStatusResult = await waitForOutbox(
      new RegExp(`"line_b64":"${statusChunkB64}"`),
      commandTimeoutMs,
      'raw status command',
      bridgeSessionDir
    );

    const result = {
      startupMatched: started.line,
      mapMatched: mapLoaded.line,
      selfTestMatched: selfTestResult ? 'bridge outbox chunk observed' : null,
      statusMatched: statusResult?.line ?? null,
      directSendKeysMatched: null,
      rawStatusMatched: rawStatusResult ? 'bridge outbox status chunk observed' : null,
      selfTestSucceeded: Boolean(selfTestResult),
      directSendKeysSucceeded: false,
      statusSucceeded: Boolean(statusResult && /Server Status/.test(statusResult.line)),
      rawStatusSucceeded: Boolean(rawStatusResult),
      traceFile,
    };

    logLine('probe-result', JSON.stringify(result));

    if (fs.existsSync(traceFile)) {
      logLine('trace', '--- begin bridge trace ---');
      for (const line of fs.readFileSync(traceFile, 'utf8').split(/\r?\n/)) {
        if (line.length > 0) logLine('trace', line);
      }
      logLine('trace', '--- end bridge trace ---');
    }

    process.exitCode =
      result.selfTestSucceeded ||
      result.directSendKeysSucceeded ||
      result.statusSucceeded ||
      result.rawStatusSucceeded
        ? 0
        : 1;
  } catch (error) {
    logLine('probe-error', error instanceof Error ? error.message : String(error));
    if (fs.existsSync(traceFile)) {
      logLine('trace', '--- begin bridge trace ---');
      for (const line of fs.readFileSync(traceFile, 'utf8').split(/\r?\n/)) {
        if (line.length > 0) logLine('trace', line);
      }
      logLine('trace', '--- end bridge trace ---');
    }
    process.exitCode = 1;
  } finally {
    stdoutReader.close();
    stderrReader.close();
    await stopChild();
  }
})();
