#!/usr/bin/env node

'use strict';

const crypto = require('node:crypto');
const fs = require('node:fs');
const net = require('node:net');
const os = require('node:os');
const path = require('node:path');
const { performance } = require('node:perf_hooks');

const FEATURE = 'bmf-command-tunnel-benchmark';
const SOURCE = 'bmf.command-tunnel-benchmark';
const DEFAULT_SOCKET_PATH = path.join(
  process.env.APPDATA || '',
  'omegga',
  'steam_installs',
  'main',
  'Brickadia',
  'Binaries',
  'Win64',
  'ue4ss',
  'main',
  'Mods',
  'BMF',
  'runtime',
  'socket.json',
);
const DEFAULT_BMF_COMMAND_TEMPLATE =
  'bmf.chat.player-message-impl message={command} confirm=cityrpg-remote';
const SAFE_BMF_COMMAND_NAMES = new Set([
  'bmf.chat.player-message-impl',
]);
const PROMETHEUS_NAMES = new Set([
  'brickadia_server_up',
  'bmf_runtime_status_up',
  'bmf_telemetry_up',
  'brickadia_frame_telemetry_up',
  'brickadia_frame_telemetry_hook_registered',
  'brickadia_frame_delta_milliseconds',
  'brickadia_frame_samples_total',
  'brickadia_frame_slow_total',
  'brickadia_frame_spikes_total',
  'bmf_command_processed_total',
  'bmf_command_transport_total',
  'bmf_worker_items_total',
]);

function defaultRunOptions() {
  return {
    action: 'run',
    label: 'candidate',
    mode: 'all',
    commandProtocol: 'legacy',
    socketPath: process.env.OMEGGA_BMF_SOCKET_PATH || DEFAULT_SOCKET_PATH,
    logPath: process.env.BRICKADIA_LOG_PATH || '',
    player: '',
    pingSamples: 10,
    commandSamples: 5,
    pingSpacingMs: 100,
    commandSpacingMs: 500,
    timeoutMs: 5000,
    logTimeoutMs: 5000,
    metricsUrl: process.env.OMEGGA_LIVE_COMMAND_CANARY_METRICS_URL || 'http://127.0.0.1:8080/metrics',
    metricsTimeoutMs: 2500,
    baselineMs: 30000,
    recoveryMs: 30000,
    requireMetrics: false,
    confirmLive: false,
    outJson: '',
    bmfCommandTemplate: DEFAULT_BMF_COMMAND_TEMPLATE,
    maxSocketP95Ms: 300,
    maxCommandP95Ms: 300,
    maxNew100MsFrames: 0,
    maxFrameAverageIncreasePercent: 5,
  };
}

function defaultCompareOptions() {
  return {
    action: 'compare',
    before: '',
    after: '',
    outJson: '',
    maxSocketP95Ms: 300,
    maxCommandP95Ms: 300,
    maxP95RegressionPercent: 5,
    maxNew100MsFrames: 0,
  };
}

function parseArgs(argv) {
  const values = [...argv];
  let action = 'run';
  if (values[0] === 'run' || values[0] === 'compare') action = values.shift();
  const args = action === 'compare' ? defaultCompareOptions() : defaultRunOptions();

  const readValue = (token, indexRef) => {
    if (indexRef.index + 1 >= values.length) throw new Error(`Missing value for ${token}.`);
    indexRef.index += 1;
    return values[indexRef.index];
  };

  const numberValue = (token, value) => {
    const parsed = Number(value);
    if (!Number.isFinite(parsed)) throw new Error(`${token} must be a number.`);
    return parsed;
  };

  const indexRef = { index: 0 };
  for (; indexRef.index < values.length; indexRef.index += 1) {
    const token = values[indexRef.index];
    if (token === '--help' || token === '-h') args.help = true;
    else if (token === '--out-json' || token === '--out') args.outJson = readValue(token, indexRef);
    else if (token === '--max-socket-p95-ms') args.maxSocketP95Ms = numberValue(token, readValue(token, indexRef));
    else if (token === '--max-command-p95-ms') args.maxCommandP95Ms = numberValue(token, readValue(token, indexRef));
    else if (token === '--max-new-100ms-frames') args.maxNew100MsFrames = numberValue(token, readValue(token, indexRef));
    else if (action === 'compare' && token === '--before') args.before = readValue(token, indexRef);
    else if (action === 'compare' && token === '--after') args.after = readValue(token, indexRef);
    else if (action === 'compare' && token === '--max-p95-regression-percent') {
      args.maxP95RegressionPercent = numberValue(token, readValue(token, indexRef));
    } else if (action === 'run' && token === '--label') args.label = readValue(token, indexRef);
    else if (action === 'run' && token === '--mode') args.mode = readValue(token, indexRef).toLowerCase();
    else if (action === 'run' && token === '--command-protocol') {
      args.commandProtocol = readValue(token, indexRef).toLowerCase();
    }
    else if (action === 'run' && (token === '--socket-path' || token === '--socket')) {
      args.socketPath = readValue(token, indexRef);
    } else if (action === 'run' && token === '--log-path') args.logPath = readValue(token, indexRef);
    else if (action === 'run' && token === '--player') args.player = readValue(token, indexRef);
    else if (action === 'run' && token === '--ping-samples') {
      args.pingSamples = numberValue(token, readValue(token, indexRef));
    } else if (action === 'run' && token === '--command-samples') {
      args.commandSamples = numberValue(token, readValue(token, indexRef));
    } else if (action === 'run' && token === '--ping-spacing-ms') {
      args.pingSpacingMs = numberValue(token, readValue(token, indexRef));
    } else if (action === 'run' && token === '--command-spacing-ms') {
      args.commandSpacingMs = numberValue(token, readValue(token, indexRef));
    } else if (action === 'run' && token === '--timeout-ms') {
      args.timeoutMs = numberValue(token, readValue(token, indexRef));
    } else if (action === 'run' && token === '--log-timeout-ms') {
      args.logTimeoutMs = numberValue(token, readValue(token, indexRef));
    } else if (action === 'run' && token === '--metrics-url') {
      args.metricsUrl = readValue(token, indexRef);
    } else if (action === 'run' && token === '--metrics-timeout-ms') {
      args.metricsTimeoutMs = numberValue(token, readValue(token, indexRef));
    } else if (action === 'run' && token === '--baseline-ms') {
      args.baselineMs = numberValue(token, readValue(token, indexRef));
    } else if (action === 'run' && token === '--recovery-ms') {
      args.recoveryMs = numberValue(token, readValue(token, indexRef));
    } else if (action === 'run' && token === '--no-metrics') args.metricsUrl = '';
    else if (action === 'run' && token === '--require-metrics') args.requireMetrics = true;
    else if (action === 'run' && token === '--confirm-live') args.confirmLive = true;
    else if (action === 'run' && token === '--bmf-command-template') {
      args.bmfCommandTemplate = readValue(token, indexRef);
    } else if (action === 'run' && token === '--max-frame-average-increase-percent') {
      args.maxFrameAverageIncreasePercent = numberValue(token, readValue(token, indexRef));
    } else {
      throw new Error(`Unknown argument for ${action}: ${token}`);
    }
  }

  validateArgs(args);
  return args;
}

function validateArgs(args) {
  const assertFiniteRange = (name, value, min, max) => {
    if (!Number.isFinite(value) || value < min || value > max) {
      throw new Error(`${name} must be between ${min} and ${max}.`);
    }
  };

  if (args.action === 'compare') {
    if (!args.help && (!args.before || !args.after)) {
      throw new Error('compare requires --before and --after report paths.');
    }
    assertFiniteRange('--max-socket-p95-ms', args.maxSocketP95Ms, 1, 60000);
    assertFiniteRange('--max-command-p95-ms', args.maxCommandP95Ms, 1, 60000);
    assertFiniteRange('--max-p95-regression-percent', args.maxP95RegressionPercent, 0, 10000);
    assertFiniteRange('--max-new-100ms-frames', args.maxNew100MsFrames, 0, 1000000);
    return;
  }

  if (args.help) return;

  if (!['socket', 'command', 'all'].includes(args.mode)) {
    throw new Error('--mode must be socket, command, or all.');
  }
  if (!['legacy', 'tunnel'].includes(args.commandProtocol)) {
    throw new Error('--command-protocol must be legacy or tunnel.');
  }
  if (!/^[A-Za-z0-9._-]{1,64}$/.test(args.label)) {
    throw new Error('--label must contain 1-64 letters, digits, dots, underscores, or hyphens.');
  }
  assertFiniteRange('--ping-samples', args.pingSamples, 1, 100);
  assertFiniteRange('--command-samples', args.commandSamples, 1, 20);
  if (!Number.isInteger(args.pingSamples) || !Number.isInteger(args.commandSamples)) {
    throw new Error('--ping-samples and --command-samples must be integers.');
  }
  assertFiniteRange('--ping-spacing-ms', args.pingSpacingMs, 0, 60000);
  assertFiniteRange('--command-spacing-ms', args.commandSpacingMs, 500, 60000);
  assertFiniteRange('--timeout-ms', args.timeoutMs, 1000, 60000);
  assertFiniteRange('--log-timeout-ms', args.logTimeoutMs, 1000, 60000);
  assertFiniteRange('--metrics-timeout-ms', args.metricsTimeoutMs, 250, 30000);
  assertFiniteRange('--baseline-ms', args.baselineMs, 0, 120000);
  assertFiniteRange('--recovery-ms', args.recoveryMs, 0, 120000);
  assertFiniteRange('--max-socket-p95-ms', args.maxSocketP95Ms, 1, 60000);
  assertFiniteRange('--max-command-p95-ms', args.maxCommandP95Ms, 1, 60000);
  assertFiniteRange('--max-new-100ms-frames', args.maxNew100MsFrames, 0, 1000000);
  assertFiniteRange('--max-frame-average-increase-percent', args.maxFrameAverageIncreasePercent, 0, 1000);
  if (/command|all/.test(args.mode)) {
    if (!args.confirmLive) {
      throw new Error('Command probes require the explicit --confirm-live flag.');
    }
    if (!args.player || args.player.length > 64 || /[\r\n]/.test(args.player)) {
      throw new Error('Command probes require --player with a 1-64 character connected player name.');
    }
    if (!args.logPath) throw new Error('Command probes require --log-path to Brickadia.log.');
    if (args.commandProtocol === 'legacy') {
      const placeholderCount = args.bmfCommandTemplate.split('{command}').length - 1;
      const bmfCommandName = args.bmfCommandTemplate.match(/^(\S+)/)?.[1] || '';
      if (
        args.bmfCommandTemplate.length > 1024 ||
        /[\r\n]/.test(args.bmfCommandTemplate) ||
        !SAFE_BMF_COMMAND_NAMES.has(bmfCommandName) ||
        placeholderCount !== 1
      ) {
        throw new Error(
          '--bmf-command-template must use an approved command-tunnel entrypoint, contain one {command}, contain no newline, and stay under 1024 characters.',
        );
      }
    }
  }
}

function usage() {
  return [
    'BMF command tunnel before/after benchmark',
    '',
    'Socket-only (safe, no gameplay command):',
    '  node scripts/benchmark-bmf-command-tunnel.js run --label before --mode socket',
    '',
    'Socket plus fixed safe /cityrpgRemote whisper probes:',
    '  node scripts/benchmark-bmf-command-tunnel.js run --label before --mode all `',
    '    --log-path <Brickadia.log> --player <connected-player> --confirm-live',
    '',
    'Compare reports:',
    '  node scripts/benchmark-bmf-command-tunnel.js compare `',
    '    --before artifacts/local/bmf-command-tunnel-before.json `',
    '    --after artifacts/local/bmf-command-tunnel-after.json',
    '',
    'Run options:',
    '  --socket-path <path>                 Mods/BMF/runtime/socket.json.',
    '  --mode <socket|command|all>          Default: all.',
    '  --command-protocol <legacy|tunnel>   Default: legacy.',
    '  --ping-samples <1-100>               Default: 10.',
    '  --command-samples <1-20>             Default: 5.',
    '  --ping-spacing-ms <ms>               Default: 100.',
    '  --command-spacing-ms <500-60000>     Default: 500.',
    '  --log-path <path>                    Active Brickadia.log; required for command probes.',
    '  --player <name>                      Connected whisper target; required for command probes.',
    '  --confirm-live                       Required before any gameplay command is sent.',
    '  --bmf-command-template <template>    One {command} placeholder; defaults to the current path.',
    '  --metrics-url <url>                  Default: http://127.0.0.1:8080/metrics.',
    '  --baseline-ms <0-120000>             Idle frame baseline. Default: 30000.',
    '  --recovery-ms <0-120000>             Post-probe recovery window. Default: 30000.',
    '  --no-metrics                         Skip Prometheus snapshots.',
    '  --require-metrics                    Fail if either metrics snapshot is unavailable.',
    '  --out-json <path>                    Explicit JSON artifact path.',
  ].join(os.EOL);
}

function sleep(ms) {
  return new Promise(resolve => setTimeout(resolve, ms));
}

function round(value, digits = 3) {
  if (!Number.isFinite(value)) return null;
  const factor = 10 ** digits;
  return Math.round(value * factor) / factor;
}

function percentile(values, quantile) {
  const sorted = values.filter(Number.isFinite).slice().sort((left, right) => left - right);
  if (sorted.length === 0) return null;
  if (sorted.length === 1) return sorted[0];
  const index = (sorted.length - 1) * quantile;
  const lower = Math.floor(index);
  const upper = Math.ceil(index);
  if (lower === upper) return sorted[lower];
  return sorted[lower] + (sorted[upper] - sorted[lower]) * (index - lower);
}

function summarize(values) {
  const finite = values.filter(Number.isFinite);
  if (finite.length === 0) {
    return { count: 0, min: null, p50: null, p90: null, p95: null, p99: null, max: null, mean: null };
  }
  const total = finite.reduce((sum, value) => sum + value, 0);
  return {
    count: finite.length,
    min: round(Math.min(...finite)),
    p50: round(percentile(finite, 0.5)),
    p90: round(percentile(finite, 0.9)),
    p95: round(percentile(finite, 0.95)),
    p99: round(percentile(finite, 0.99)),
    max: round(Math.max(...finite)),
    mean: round(total / finite.length),
  };
}

function parseKeyValueResponse(response) {
  const fields = {};
  for (const line of String(response || '').split(/\r?\n/)) {
    const index = line.indexOf('=');
    if (index <= 0) continue;
    const key = line.slice(0, index).trim();
    if (key) fields[key] = line.slice(index + 1).trim();
  }
  return fields;
}

function quoteConsoleArg(value) {
  return `"${String(value).replace(/\\/g, '\\\\').replace(/"/g, '\\"')}"`;
}

function buildSafeCommandProbe(player, marker, template = DEFAULT_BMF_COMMAND_TEMPLATE) {
  const opaqueCommand = `/cityrpgRemote whisper ${quoteConsoleArg(player)} ${quoteConsoleArg(marker)}`;
  return {
    marker,
    opaqueCommand,
    bmfCommand: template.replace('{command}', encodeURIComponent(opaqueCommand)),
  };
}

function parseBrickadiaTimestamp(line) {
  const match = String(line || '').match(
    /^\[(\d{4})\.(\d{2})\.(\d{2})-(\d{2})\.(\d{2})\.(\d{2}):(\d{3})\]/,
  );
  if (!match) return null;
  return Date.UTC(
    Number(match[1]),
    Number(match[2]) - 1,
    Number(match[3]),
    Number(match[4]),
    Number(match[5]),
    Number(match[6]),
    Number(match[7]),
  );
}

function waitForLogMarker(logPath, marker, timeoutMs) {
  const absolutePath = path.resolve(logPath);
  let offset = fs.statSync(absolutePath).size;
  let partial = '';
  let watcher = null;
  let interval = null;
  let timer = null;
  let checking = false;
  let settled = false;
  let resolvePromise;
  let rejectPromise;

  const cleanup = () => {
    if (watcher) watcher.close();
    if (interval) clearInterval(interval);
    if (timer) clearTimeout(timer);
    watcher = null;
    interval = null;
    timer = null;
  };

  const finish = (error, value) => {
    if (settled) return;
    settled = true;
    cleanup();
    if (error) rejectPromise(error);
    else resolvePromise(value);
  };

  const check = () => {
    if (checking || settled) return;
    checking = true;
    try {
      const stat = fs.statSync(absolutePath);
      if (stat.size < offset) {
        offset = 0;
        partial = '';
      }
      if (stat.size <= offset) return;
      const length = stat.size - offset;
      if (length > 4 * 1024 * 1024) {
        finish(new Error(`Brickadia.log grew by more than 4 MiB while waiting for marker ${marker}.`));
        return;
      }
      const handle = fs.openSync(absolutePath, 'r');
      try {
        const buffer = Buffer.alloc(length);
        fs.readSync(handle, buffer, 0, length, offset);
        offset = stat.size;
        const lines = `${partial}${buffer.toString('utf8')}`.split(/\r?\n/);
        partial = lines.pop() || '';
        for (const line of lines) {
          if (!line.includes(marker)) continue;
          finish(null, {
            line,
            observedPerformanceMs: performance.now(),
            logTimestampEpochMs: parseBrickadiaTimestamp(line),
          });
          return;
        }
      } finally {
        fs.closeSync(handle);
      }
    } catch (error) {
      finish(error);
    } finally {
      checking = false;
    }
  };

  const promise = new Promise((resolve, reject) => {
    resolvePromise = resolve;
    rejectPromise = reject;
  });
  watcher = fs.watch(absolutePath, { persistent: false }, check);
  interval = setInterval(check, 100);
  timer = setTimeout(
    () => finish(new Error(`Timed out waiting for ${marker} in ${absolutePath}.`)),
    timeoutMs,
  );
  return {
    promise,
    cancel: reason => finish(new Error(reason || `Log observation cancelled for ${marker}.`)),
  };
}

class BmfSocketClient {
  constructor(metadata, options = {}) {
    this.metadata = metadata;
    this.timeoutMs = options.timeoutMs || 5000;
    this.source = options.source || SOURCE;
    this.socket = null;
    this.buffer = '';
    this.pending = new Map();
    this.records = [];
  }

  async connect() {
    await new Promise((resolve, reject) => {
      let connected = false;
      const socket = net.createConnection(
        { host: this.metadata.host, port: Number(this.metadata.port) },
        () => {
          connected = true;
          this.socket = socket;
          this.write({
            type: 'hello',
            role: 'plugin',
            source: this.source,
            version: '1',
            token: this.metadata.token,
          });
          resolve();
        },
      );
      socket.setEncoding('utf8');
      socket.setNoDelay(true);
      socket.on('data', chunk => this.handleData(chunk));
      socket.on('error', error => {
        this.rejectAll(error);
        if (!connected) reject(error);
      });
      socket.on('close', () => this.rejectAll(new Error('BMF socket closed before response.')));
      const timer = setTimeout(() => {
        if (connected) return;
        socket.destroy();
        reject(new Error(`Timed out connecting to ${this.metadata.host}:${this.metadata.port}.`));
      }, this.timeoutMs);
      socket.once('connect', () => clearTimeout(timer));
    });
  }

  close() {
    if (this.socket && !this.socket.destroyed) this.socket.end();
  }

  rejectAll(error) {
    for (const pending of this.pending.values()) {
      clearTimeout(pending.timer);
      pending.reject(error);
    }
    this.pending.clear();
  }

  write(message) {
    if (!this.socket || this.socket.destroyed || !this.socket.writable) {
      throw new Error('BMF socket is not writable.');
    }
    this.socket.write(`${JSON.stringify(message)}\n`);
  }

  handleData(chunk) {
    this.buffer += String(chunk || '');
    let newline = this.buffer.indexOf('\n');
    while (newline >= 0) {
      const line = this.buffer.slice(0, newline).trim();
      this.buffer = this.buffer.slice(newline + 1);
      if (line) this.handleLine(line);
      newline = this.buffer.indexOf('\n');
    }
  }

  handleLine(line) {
    let message;
    try {
      message = JSON.parse(line);
    } catch {
      this.records.push({ type: 'invalid-json' });
      return;
    }
    this.records.push({
      type: message.type || '',
      id: message.id || '',
      ok: message.ok,
      source: message.source || '',
      ts: message.ts || '',
    });
    if (message.type === 'ping') {
      this.write({ type: 'pong', source: this.source, id: message.id, ts: new Date().toISOString() });
      return;
    }
    const pending = this.pending.get(String(message.id || ''));
    if (!pending) return;
    if (pending.ackType && message.type === pending.ackType) {
      pending.ackDurationMs = performance.now() - pending.startedPerformanceMs;
      pending.ackMessage = message;
      return;
    }
    if (message.type !== pending.expectedType) return;
    clearTimeout(pending.timer);
    this.pending.delete(String(message.id));
    pending.resolve({
      id: String(message.id),
      message,
      startedEpochMs: pending.startedEpochMs,
      startedPerformanceMs: pending.startedPerformanceMs,
      durationMs: performance.now() - pending.startedPerformanceMs,
      ackDurationMs: pending.ackDurationMs,
      ackMessage: pending.ackMessage,
    });
  }

  startRequest(type, expectedType, payload = {}, options = {}) {
    const id = `bmf-tunnel-${type}-${Date.now()}-${crypto.randomBytes(4).toString('hex')}`;
    const startedEpochMs = Date.now();
    const startedPerformanceMs = performance.now();
    let resolvePromise;
    let rejectPromise;
    const promise = new Promise((resolve, reject) => {
      resolvePromise = resolve;
      rejectPromise = reject;
    });
    const timer = setTimeout(() => {
      this.pending.delete(id);
      rejectPromise(new Error(`Timed out waiting for BMF ${expectedType} id=${id}.`));
    }, this.timeoutMs);
    this.pending.set(id, {
      expectedType,
      ackType: options.ackType || null,
      ackDurationMs: null,
      ackMessage: null,
      startedEpochMs,
      startedPerformanceMs,
      resolve: resolvePromise,
      reject: rejectPromise,
      timer,
    });
    try {
      this.write({ type, id, source: this.source, ...payload });
    } catch (error) {
      clearTimeout(timer);
      this.pending.delete(id);
      rejectPromise(error);
    }
    return { id, startedEpochMs, startedPerformanceMs, promise };
  }

  ping() {
    return this.startRequest('ping', 'pong', { ts: new Date().toISOString() });
  }

  command(command) {
    return this.startRequest('command', 'response', { command, issuedAt: Date.now() });
  }

  tunnel(line, options = {}) {
    const issuedAtMs = Date.now();
    const requestedDeadlineMs = Number(options.deadlineMs) || 0;
    const deadlineMs = requestedDeadlineMs >= 1_000_000_000_000
      ? requestedDeadlineMs
      : issuedAtMs + (requestedDeadlineMs || this.timeoutMs);
    return this.startRequest(
      'tunnel.request',
      'tunnel.result',
      {
        v: 1,
        channel: 'cityrpg.command.v1',
        line,
        serviceClass: options.serviceClass || 'interactive',
        deadlineMs,
        issuedAtMs,
        idempotencyKey: options.idempotencyKey || '',
      },
      { ackType: 'tunnel.ack' },
    );
  }
}

function parsePrometheusLabels(raw) {
  const labels = {};
  const pattern = /([A-Za-z_][A-Za-z0-9_]*)="((?:\\.|[^"])*)"/g;
  let match;
  while ((match = pattern.exec(raw || '')) !== null) {
    labels[match[1]] = match[2].replace(/\\n/g, '\n').replace(/\\"/g, '"').replace(/\\\\/g, '\\');
  }
  return labels;
}

function parsePrometheusSnapshot(text) {
  const samples = [];
  for (const line of String(text || '').split(/\r?\n/)) {
    if (!line || line.startsWith('#')) continue;
    const match = line.match(/^([A-Za-z_:][A-Za-z0-9_:]*)(\{([^}]*)\})?\s+([^\s]+)(?:\s+\d+)?$/);
    if (!match || !PROMETHEUS_NAMES.has(match[1])) continue;
    const value = Number(match[4]);
    if (!Number.isFinite(value)) continue;
    samples.push({ name: match[1], labels: parsePrometheusLabels(match[3]), value });
  }
  const values = name => samples.filter(sample => sample.name === name);
  const max = name => {
    const entries = values(name);
    return entries.length ? Math.max(...entries.map(entry => entry.value)) : null;
  };
  const sum = name => {
    const entries = values(name);
    return entries.length ? entries.reduce((total, entry) => total + entry.value, 0) : null;
  };
  const frameValue = statistic => {
    const entries = values('brickadia_frame_delta_milliseconds').filter(
      sample => sample.labels.scope === 'window' && sample.labels.statistic === statistic,
    );
    return entries.length ? Math.max(...entries.map(entry => entry.value)) : null;
  };
  const slowTotals = {};
  for (const sample of values('brickadia_frame_slow_total')) {
    const threshold = String(sample.labels.threshold_ms || 'unknown');
    slowTotals[threshold] = (slowTotals[threshold] || 0) + sample.value;
  }
  const groupedCounter = (name, label) => {
    const result = {};
    for (const sample of values(name)) {
      const key = String(sample.labels[label] || 'unknown');
      result[key] = (result[key] || 0) + sample.value;
    }
    return result;
  };
  return {
    capturedAt: new Date().toISOString(),
    up: {
      brickadiaServer: max('brickadia_server_up'),
      bmfRuntime: max('bmf_runtime_status_up'),
      bmfTelemetry: max('bmf_telemetry_up'),
      frameTelemetry: max('brickadia_frame_telemetry_up'),
      frameHookRegistered: max('brickadia_frame_telemetry_hook_registered'),
    },
    frame: {
      windowAverageMs: frameValue('avg'),
      windowMaximumMs: frameValue('max'),
      samplesTotal: sum('brickadia_frame_samples_total'),
      spikesTotal: sum('brickadia_frame_spikes_total'),
      slowTotals,
    },
    attribution: {
      commandProcessedByName: groupedCounter('bmf_command_processed_total', 'command'),
      commandTransportTotals: groupedCounter('bmf_command_transport_total', 'transport'),
      workerItemsByWorker: groupedCounter('bmf_worker_items_total', 'worker'),
    },
  };
}

async function fetchMetricsSnapshot(url, timeoutMs) {
  if (!url) return { available: false, skipped: true, error: null, data: null };
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const response = await fetch(url, { signal: controller.signal });
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    return { available: true, skipped: false, error: null, data: parsePrometheusSnapshot(await response.text()) };
  } catch (error) {
    return { available: false, skipped: false, error: error.message || String(error), data: null };
  } finally {
    clearTimeout(timer);
  }
}

function subtractNullable(after, before) {
  return Number.isFinite(after) && Number.isFinite(before) ? round(after - before) : null;
}

function metricsDelta(beforeResult, afterResult) {
  const before = beforeResult && beforeResult.data;
  const after = afterResult && afterResult.data;
  if (!before || !after) return null;
  const thresholds = new Set([
    ...Object.keys(before.frame.slowTotals || {}),
    ...Object.keys(after.frame.slowTotals || {}),
  ]);
  const slowTotals = {};
  for (const threshold of thresholds) {
    slowTotals[threshold] = subtractNullable(
      after.frame.slowTotals[threshold],
      before.frame.slowTotals[threshold],
    );
  }
  const subtractMaps = (beforeMap, afterMap) => {
    const result = {};
    const keys = new Set([...Object.keys(beforeMap || {}), ...Object.keys(afterMap || {})]);
    for (const key of keys) result[key] = subtractNullable(afterMap?.[key], beforeMap?.[key]);
    return result;
  };
  return {
    frameSamples: subtractNullable(after.frame.samplesTotal, before.frame.samplesTotal),
    frameSpikes: subtractNullable(after.frame.spikesTotal, before.frame.spikesTotal),
    slowTotals,
    endingWindowAverageMs: after.frame.windowAverageMs,
    endingWindowMaximumMs: after.frame.windowMaximumMs,
    windowAverageIncreasePercent:
      Number.isFinite(before.frame.windowAverageMs) &&
      before.frame.windowAverageMs > 0 &&
      Number.isFinite(after.frame.windowAverageMs)
        ? round(((after.frame.windowAverageMs - before.frame.windowAverageMs) / before.frame.windowAverageMs) * 100)
        : null,
    attribution: {
      commandProcessedByName: subtractMaps(
        before.attribution?.commandProcessedByName,
        after.attribution?.commandProcessedByName,
      ),
      commandTransportTotals: subtractMaps(
        before.attribution?.commandTransportTotals,
        after.attribution?.commandTransportTotals,
      ),
      workerItemsByWorker: subtractMaps(
        before.attribution?.workerItemsByWorker,
        after.attribution?.workerItemsByWorker,
      ),
    },
  };
}

function findSlowThresholdDelta(delta, target) {
  if (!delta || !delta.slowTotals) return null;
  const match = Object.entries(delta.slowTotals).find(([threshold]) => Math.abs(Number(threshold) - target) < 0.01);
  return match ? match[1] : null;
}

function publicSocketMetadata(socketPath, metadata) {
  return {
    path: path.resolve(socketPath),
    enabled: metadata.enabled === true,
    available: metadata.available === true,
    started: metadata.started === true,
    host: metadata.host,
    port: metadata.port,
    pollIntervalMs: metadata.pollIntervalMs,
    workerMode: metadata.workerMode,
    workerStarted: metadata.workerStarted,
    updatedAt: metadata.updatedAt,
    tokenPresent: typeof metadata.token === 'string' && metadata.token.length > 0,
  };
}

function ensureLoopback(host) {
  const value = String(host || '').trim().toLowerCase();
  if (!['127.0.0.1', '::1', 'localhost'].includes(value)) {
    throw new Error(`Refusing non-loopback BMF socket host: ${host || '<missing>'}.`);
  }
}

function defaultOutPath(root, label) {
  return path.join(root, 'artifacts', 'local', `bmf-command-tunnel-${label}.json`);
}

function writeReport(outPath, report) {
  fs.mkdirSync(path.dirname(outPath), { recursive: true });
  fs.writeFileSync(outPath, `${JSON.stringify(report, null, 2)}\n`, 'utf8');
}

function addGate(gates, name, passed, actual, expected) {
  gates.push({ name, passed: passed === true, actual, expected });
}

async function runBenchmark(args) {
  const root = path.resolve(__dirname, '..');
  const outPath = path.resolve(args.outJson || defaultOutPath(root, args.label));
  const errors = [];
  const gates = [];
  const pingSamples = [];
  const commandSamples = [];
  const startedAt = new Date().toISOString();
  const socketPath = path.resolve(args.socketPath);
  const logPath = args.logPath ? path.resolve(args.logPath) : null;
  let metadata = null;
  let socket = null;
  let metricsBaselineStart = null;
  let metricsBefore = null;
  let metricsActiveEnd = null;
  let metricsAfter = null;

  try {
    metadata = JSON.parse(fs.readFileSync(socketPath, 'utf8').replace(/^\uFEFF/, ''));
    ensureLoopback(metadata.host);
    if (!metadata.enabled || !metadata.started || !metadata.port || !metadata.token) {
      throw new Error('BMF socket metadata is not enabled, started, or authenticated.');
    }
    if (/command|all/.test(args.mode)) {
      if (!fs.existsSync(logPath)) throw new Error(`Brickadia log does not exist: ${logPath}`);
    }

    metricsBaselineStart = await fetchMetricsSnapshot(args.metricsUrl, args.metricsTimeoutMs);
    if (args.metricsUrl && metricsBaselineStart.available && args.baselineMs > 0) {
      await sleep(args.baselineMs);
    }
    metricsBefore = await fetchMetricsSnapshot(args.metricsUrl, args.metricsTimeoutMs);
    if (args.requireMetrics && !metricsBefore.available) {
      throw new Error(`Required pre-run metrics unavailable: ${metricsBefore.error || 'unknown error'}.`);
    }

    socket = new BmfSocketClient(metadata, { timeoutMs: args.timeoutMs });
    await socket.connect();

    const initialHealth = await socket.ping().promise;
    if (!Number.isFinite(initialHealth.durationMs)) throw new Error('Initial BMF socket health ping failed.');

    if (args.mode === 'socket' || args.mode === 'all') {
      for (let index = 0; index < args.pingSamples; index += 1) {
        const result = await socket.ping().promise;
        pingSamples.push({ index: index + 1, ok: true, rttMs: round(result.durationMs) });
        if (index + 1 < args.pingSamples) await sleep(args.pingSpacingMs);
      }
    }

    if (args.mode === 'command' || args.mode === 'all') {
      const runId = `${Date.now()}_${crypto.randomBytes(3).toString('hex')}`;
      for (let index = 0; index < args.commandSamples; index += 1) {
        const marker = `BMF_TUNNEL_CANARY_${runId}_${String(index + 1).padStart(2, '0')}`;
        const probe = buildSafeCommandProbe(args.player, marker, args.bmfCommandTemplate);
        const observation = waitForLogMarker(logPath, marker, args.logTimeoutMs);
        const request = args.commandProtocol === 'tunnel'
          ? socket.tunnel(probe.opaqueCommand, {
              deadlineMs: args.timeoutMs,
              idempotencyKey: marker,
            })
          : socket.command(probe.bmfCommand);
        let sample;
        try {
          const response = await request.promise;
          const fields = parseKeyValueResponse(response.message.response || '');
          const responseText = String(response.message.response || '');
          const implementationCalled = args.commandProtocol === 'tunnel'
            ? response.message.state === 'injected'
            : /\bimplementation_called=true\b/i.test(responseText);
          const rateLimited = args.commandProtocol === 'tunnel'
            ? response.message.code === 'RATE_LIMITED'
            : /\bRATE_LIMITED\b/i.test(responseText);
          const commandAccepted = args.commandProtocol === 'tunnel'
            ? response.message.state === 'injected' && response.message.code === 'OK'
            : response.message.ok === true && implementationCalled && !rateLimited;
          if (!commandAccepted) {
            observation.cancel(`BMF rejected safe command probe ${index + 1}.`);
            await observation.promise.catch(() => {});
            const rejectionDetail = args.commandProtocol === 'tunnel'
              ? JSON.stringify({
                  state: response.message.state,
                  code: response.message.code,
                  detail: response.message.detail,
                })
              : responseText.slice(0, 1000);
            throw new Error(`BMF rejected safe command probe ${index + 1}: ${rejectionDetail}`);
          }
          const observed = await observation.promise;
          const observedMs = observed.observedPerformanceMs - request.startedPerformanceMs;
          const logTimestampMs = Number.isFinite(observed.logTimestampEpochMs)
            ? observed.logTimestampEpochMs - request.startedEpochMs
            : null;
          const completionMs = Number.isFinite(logTimestampMs) && logTimestampMs >= -5
            ? Math.max(0, logTimestampMs)
            : observedMs;
          const health = await socket.ping().promise;
          sample = {
            index: index + 1,
            marker,
            ok: commandAccepted,
            protocol: args.commandProtocol,
            ackRttMs: round(response.ackDurationMs),
            responseRttMs: round(response.durationMs),
            consoleObservedMs: round(observedMs),
            consoleTimestampMs: round(logTimestampMs),
            completionMs: round(completionMs),
            postHealthRttMs: round(health.durationMs),
            envelope: {
              ok: response.message.ok === true,
              detail: response.message.detail || '',
              source: response.message.source || '',
              state: response.message.state || '',
              code: response.message.code || '',
            },
            response: {
              implementationCalled,
              rateLimited,
              code: response.message.code || fields.code || '',
              transport: fields.bmf_command_transport || '',
              dispatchMs: Number(response.message.dispatchMs ?? fields.bmf_command_dispatch_ms ?? NaN),
              totalMs: Number(fields.bmf_command_total_ms || NaN),
              queueDepth: Number(response.message.queueDepth ?? NaN),
            },
            consoleLine: observed.line.slice(0, 2000),
          };
        } catch (error) {
          observation.cancel(`Command probe ${index + 1} failed before console observation completed.`);
          sample = {
            index: index + 1,
            marker,
            ok: false,
            error: error.message || String(error),
          };
          commandSamples.push(sample);
          throw error;
        }
        commandSamples.push(sample);
        if (index + 1 < args.commandSamples) await sleep(args.commandSpacingMs);
      }
    }
  } catch (error) {
    errors.push(error.message || String(error));
  } finally {
    if (socket) socket.close();
    metricsActiveEnd = await fetchMetricsSnapshot(args.metricsUrl, args.metricsTimeoutMs);
    if (args.metricsUrl && metricsActiveEnd.available && args.recoveryMs > 0) {
      await sleep(args.recoveryMs);
    }
    metricsAfter = await fetchMetricsSnapshot(args.metricsUrl, args.metricsTimeoutMs);
    if (args.requireMetrics && !metricsAfter.available) {
      errors.push(`Required post-run metrics unavailable: ${metricsAfter.error || 'unknown error'}.`);
    }
  }

  const socketSummary = summarize(pingSamples.filter(sample => sample.ok).map(sample => sample.rttMs));
  const commandResponseSummary = summarize(
    commandSamples.filter(sample => sample.ok).map(sample => sample.responseRttMs),
  );
  const commandAckSummary = summarize(
    commandSamples.filter(sample => sample.ok).map(sample => sample.ackRttMs),
  );
  const commandCompletionSummary = summarize(
    commandSamples.filter(sample => sample.ok).map(sample => sample.completionMs),
  );
  const delta = metricsDelta(metricsBefore, metricsActiveEnd);
  const recoveryDelta = metricsDelta(metricsActiveEnd, metricsAfter);
  const baselineToRecoveryDelta = metricsDelta(metricsBefore, metricsAfter);

  if (args.mode === 'socket' || args.mode === 'all') {
    addGate(
      gates,
      'socket sample completeness',
      pingSamples.length === args.pingSamples && pingSamples.every(sample => sample.ok),
      `${pingSamples.filter(sample => sample.ok).length}/${args.pingSamples}`,
      `${args.pingSamples}/${args.pingSamples}`,
    );
    addGate(gates, 'socket RTT p95', socketSummary.p95 <= args.maxSocketP95Ms, socketSummary.p95, `<= ${args.maxSocketP95Ms} ms`);
  }
  if (args.mode === 'command' || args.mode === 'all') {
    addGate(
      gates,
      'command sample completeness',
      commandSamples.length === args.commandSamples && commandSamples.every(sample => sample.ok),
      `${commandSamples.filter(sample => sample.ok).length}/${args.commandSamples}`,
      `${args.commandSamples}/${args.commandSamples}`,
    );
    addGate(
      gates,
      'console-observed command completion p95',
      commandCompletionSummary.p95 <= args.maxCommandP95Ms,
      commandCompletionSummary.p95,
      `<= ${args.maxCommandP95Ms} ms`,
    );
  }
  if (delta) {
    const new100MsFrames = findSlowThresholdDelta(delta, 100);
    if (Number.isFinite(new100MsFrames)) {
      addGate(gates, 'new >=100ms frames', new100MsFrames <= args.maxNew100MsFrames, new100MsFrames, `<= ${args.maxNew100MsFrames}`);
    }
    if (Number.isFinite(delta.windowAverageIncreasePercent)) {
      addGate(
        gates,
        'frame window average increase',
        delta.windowAverageIncreasePercent <= args.maxFrameAverageIncreasePercent,
        delta.windowAverageIncreasePercent,
        `<= ${args.maxFrameAverageIncreasePercent}%`,
      );
    }
  }
  if (baselineToRecoveryDelta && Number.isFinite(baselineToRecoveryDelta.windowAverageIncreasePercent)) {
    addGate(
      gates,
      'recovery frame window average increase from baseline',
      baselineToRecoveryDelta.windowAverageIncreasePercent <= args.maxFrameAverageIncreasePercent,
      baselineToRecoveryDelta.windowAverageIncreasePercent,
      `<= ${args.maxFrameAverageIncreasePercent}%`,
    );
  }
  const addHealthGates = (prefix, snapshot) => {
    if (!snapshot?.available || !snapshot.data) return;
    for (const [name, value] of Object.entries(snapshot.data.up || {})) {
      if (!Number.isFinite(value) && !args.requireMetrics) continue;
      addGate(gates, `${prefix} ${name}`, value === 1, value, '1');
    }
  };
  addHealthGates('active metrics', metricsActiveEnd);
  addHealthGates('recovery metrics', metricsAfter);
  for (const gate of gates) {
    if (!gate.passed) errors.push(`Acceptance gate failed: ${gate.name} (actual ${gate.actual}, expected ${gate.expected}).`);
  }

  const report = {
    schemaVersion: 1,
    feature: FEATURE,
    status: errors.length === 0 ? 'passed' : 'failed',
    validationLevel: args.mode === 'socket' ? 'L3 Live Server; no player required' : 'L3 Live Server; connected player required',
    label: args.label,
    startedAt,
    finishedAt: new Date().toISOString(),
    guardrails: {
      optInGameplayCommands: args.confirmLive,
      fixedSafeCommand: '/cityrpgRemote whisper <player> <unique marker>',
      maximumCommandSamples: 20,
      commandSpacingMinimumMs: 500,
      actualCommandSamples: args.mode === 'socket' ? 0 : args.commandSamples,
      worldMutation: false,
      remoteSocketAllowed: false,
      runtimeFilesModified: false,
    },
    config: {
      mode: args.mode,
      commandProtocol: args.commandProtocol,
      pingSamples: args.pingSamples,
      commandSamples: args.commandSamples,
      pingSpacingMs: args.pingSpacingMs,
      commandSpacingMs: args.commandSpacingMs,
      timeoutMs: args.timeoutMs,
      logTimeoutMs: args.logTimeoutMs,
      player: args.player || null,
      logPath,
      bmfCommandTemplate: args.bmfCommandTemplate,
      metricsUrl: args.metricsUrl || null,
      baselineMs: args.baselineMs,
      recoveryMs: args.recoveryMs,
    },
    socket: metadata ? publicSocketMetadata(socketPath, metadata) : { path: socketPath },
    measurements: {
      socketPing: { summary: socketSummary, samples: pingSamples },
      tunnelAck: { summary: commandAckSummary },
      commandResponse: { summary: commandResponseSummary },
      consoleCompletion: { summary: commandCompletionSummary, samples: commandSamples },
    },
    metrics: {
      baselineStart: metricsBaselineStart,
      before: metricsBefore,
      activeEnd: metricsActiveEnd,
      after: metricsAfter,
      delta,
      recoveryDelta,
      baselineToRecoveryDelta,
    },
    acceptance: { gates },
    evidence: [
      { kind: 'json', path: socketPath, summary: 'Authenticated BMF socket metadata; token is redacted.' },
      ...(logPath ? [{ kind: 'log', path: logPath, summary: 'Unique marker observations from the active Brickadia log.' }] : []),
      { kind: 'json', path: outPath, summary: 'Benchmark report.' },
    ],
    errors,
  };
  writeReport(outPath, report);
  process.stdout.write(`${JSON.stringify(report, null, 2)}\n`);
  return { code: errors.length === 0 ? 0 : 1, report, outPath };
}

function percentageChange(before, after) {
  if (!Number.isFinite(before) || !Number.isFinite(after) || before === 0) return null;
  return round(((after - before) / before) * 100);
}

function compareMetric(name, before, after) {
  return {
    name,
    before,
    after,
    delta: subtractNullable(after, before),
    changePercent: percentageChange(before, after),
    speedup: Number.isFinite(before) && Number.isFinite(after) && after > 0 ? round(before / after) : null,
  };
}

function compareReports(before, after, options) {
  const beforeSocket = before.measurements?.socketPing?.summary?.p95;
  const afterSocket = after.measurements?.socketPing?.summary?.p95;
  const beforeCommand = before.measurements?.consoleCompletion?.summary?.p95;
  const afterCommand = after.measurements?.consoleCompletion?.summary?.p95;
  const afterNew100MsFrames = findSlowThresholdDelta(after.metrics?.delta, 100);
  const comparisons = [
    compareMetric('socket RTT p95 ms', beforeSocket, afterSocket),
    compareMetric('console-observed command completion p95 ms', beforeCommand, afterCommand),
    compareMetric(
      'BMF command response p95 ms',
      before.measurements?.commandResponse?.summary?.p95,
      after.measurements?.commandResponse?.summary?.p95,
    ),
  ];
  const gates = [];
  if (Number.isFinite(afterSocket)) {
    addGate(gates, 'after socket RTT p95', afterSocket <= options.maxSocketP95Ms, afterSocket, `<= ${options.maxSocketP95Ms} ms`);
    const regression = percentageChange(beforeSocket, afterSocket);
    if (Number.isFinite(regression)) {
      addGate(gates, 'socket RTT p95 regression', regression <= options.maxP95RegressionPercent, regression, `<= ${options.maxP95RegressionPercent}%`);
    }
  }
  if (Number.isFinite(afterCommand)) {
    addGate(gates, 'after command completion p95', afterCommand <= options.maxCommandP95Ms, afterCommand, `<= ${options.maxCommandP95Ms} ms`);
    const regression = percentageChange(beforeCommand, afterCommand);
    if (Number.isFinite(regression)) {
      addGate(gates, 'command completion p95 regression', regression <= options.maxP95RegressionPercent, regression, `<= ${options.maxP95RegressionPercent}%`);
    }
  }
  if (Number.isFinite(afterNew100MsFrames)) {
    addGate(gates, 'after new >=100ms frames', afterNew100MsFrames <= options.maxNew100MsFrames, afterNew100MsFrames, `<= ${options.maxNew100MsFrames}`);
  }
  addGate(gates, 'after benchmark status', after.status === 'passed', after.status, 'passed');
  return { comparisons, gates, passed: gates.every(gate => gate.passed) };
}

function compareBenchmarkReports(args) {
  const root = path.resolve(__dirname, '..');
  const beforePath = path.resolve(args.before);
  const afterPath = path.resolve(args.after);
  const outPath = path.resolve(
    args.outJson || path.join(root, 'artifacts', 'local', 'bmf-command-tunnel-comparison.json'),
  );
  const before = JSON.parse(fs.readFileSync(beforePath, 'utf8').replace(/^\uFEFF/, ''));
  const after = JSON.parse(fs.readFileSync(afterPath, 'utf8').replace(/^\uFEFF/, ''));
  if (before.feature !== FEATURE || after.feature !== FEATURE) {
    throw new Error(`Both reports must have feature=${FEATURE}.`);
  }
  const result = compareReports(before, after, args);
  const report = {
    schemaVersion: 1,
    feature: `${FEATURE}-comparison`,
    status: result.passed ? 'passed' : 'failed',
    generatedAt: new Date().toISOString(),
    before: { path: beforePath, label: before.label, status: before.status },
    after: { path: afterPath, label: after.label, status: after.status },
    comparisons: result.comparisons,
    acceptance: { gates: result.gates },
    errors: result.gates.filter(gate => !gate.passed).map(gate => `${gate.name}: actual ${gate.actual}, expected ${gate.expected}`),
  };
  writeReport(outPath, report);
  process.stdout.write(`${JSON.stringify(report, null, 2)}\n`);
  return { code: result.passed ? 0 : 1, report, outPath };
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.help) {
    process.stdout.write(`${usage()}\n`);
    return 0;
  }
  const result = args.action === 'compare' ? compareBenchmarkReports(args) : await runBenchmark(args);
  return result.code;
}

module.exports = {
  BmfSocketClient,
  buildSafeCommandProbe,
  compareReports,
  metricsDelta,
  parseArgs,
  parseBrickadiaTimestamp,
  parsePrometheusSnapshot,
  percentile,
  summarize,
  waitForLogMarker,
};

if (require.main === module) {
  main()
    .then(code => {
      process.exitCode = code;
    })
    .catch(error => {
      process.stderr.write(`${error && error.stack ? error.stack : error}\n`);
      process.exitCode = 1;
    });
}
