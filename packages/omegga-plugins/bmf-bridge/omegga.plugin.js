const fs = require('fs');
const net = require('net');
const os = require('os');
const path = require('path');

const VERSION = '0.1.0';
const DEFAULT_RECORD_LIMIT = 500;
const GUARDRAILS = [
  'observe-existing-traffic-only',
  'do-not-add-ui-driven-server-probes',
  'bound-retained-record-count',
  'redact-secrets-before-display-or-export',
];
const SECRET_KEY_PATTERN = /(token|secret|password|api[-_]?key|authorization|bearer|credential)/i;
const PRIVATE_IPV4_PATTERN = /\b(?:10\.\d{1,3}\.\d{1,3}\.\d{1,3}|192\.168\.\d{1,3}\.\d{1,3}|172\.(?:1[6-9]|2\d|3[01])\.\d{1,3}\.\d{1,3})\b/g;

function asNumber(value, fallback) {
  const number = Number(value);
  return Number.isFinite(number) ? number : fallback;
}

function asBoolean(value, fallback) {
  if (typeof value === 'boolean') return value;
  if (typeof value === 'number') return value !== 0;
  if (typeof value === 'string') {
    const normalized = value.trim().toLowerCase();
    if (['true', '1', 'yes', 'on'].includes(normalized)) return true;
    if (['false', '0', 'no', 'off'].includes(normalized)) return false;
  }
  return fallback;
}

function compactObject(value) {
  const result = {};
  for (const [key, next] of Object.entries(value || {})) {
    if (next !== undefined && next !== null && next !== '') {
      result[key] = next;
    }
  }
  return result;
}

function isoSeconds(date = new Date()) {
  return date.toISOString().replace(/\.\d{3}Z$/, 'Z');
}

function safeJsonParse(text) {
  try {
    return { ok: true, value: JSON.parse(text) };
  } catch (error) {
    return { ok: false, error };
  }
}

function readJsonFile(filePath) {
  if (!filePath || !fs.existsSync(filePath)) return null;
  const parsed = safeJsonParse(fs.readFileSync(filePath, 'utf8'));
  return parsed.ok && parsed.value && typeof parsed.value === 'object' ? parsed.value : null;
}

function env(name) {
  return String(process.env[name] || '').trim();
}

function standardRuntimeDir() {
  const appData = env('APPDATA') || path.join(os.homedir(), 'AppData', 'Roaming');
  return path.resolve(
    appData,
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
    'runtime'
  );
}

function commandName(commandText) {
  return String(commandText || '').trim().split(/\s+/)[0] || '';
}

function redactCommandText(commandText) {
  return String(commandText || '').replace(
    /\b([A-Za-z0-9_.-]*(?:token|secret|password|api[_-]?key|authorization|credential)[A-Za-z0-9_.-]*)=([^ \t\r\n]+)/gi,
    '$1=[redacted]'
  );
}

function redactValue(value, options = {}, seen = new WeakSet()) {
  let redactions = 0;

  function visit(next, key, depth) {
    if (SECRET_KEY_PATTERN.test(String(key || ''))) {
      redactions += 1;
      return '[redacted]';
    }

    if (next === null || next === undefined) return next;

    if (typeof next === 'string') {
      let text = next.replace(
        /\b(Bearer|Token)\s+[A-Za-z0-9._~+/=-]+/gi,
        (_match, scheme) => {
          redactions += 1;
          return `${scheme} [redacted]`;
        }
      );
      text = text.replace(
        /\b([A-Za-z0-9_.-]*(?:token|secret|password|api[_-]?key|authorization|credential)[A-Za-z0-9_.-]*)=([^ \t\r\n&]+)/gi,
        (_match, name) => {
          redactions += 1;
          return `${name}=[redacted]`;
        }
      );
      if (options.redactPrivateIps) {
        text = text.replace(PRIVATE_IPV4_PATTERN, () => {
          redactions += 1;
          return '[private-ip]';
        });
      }
      return text;
    }

    if (typeof next !== 'object') return next;
    if (depth > asNumber(options.maxDepth, 8)) return '[max-depth]';
    if (seen.has(next)) return '[circular]';
    seen.add(next);

    if (Array.isArray(next)) {
      return next.map((item, index) => visit(item, index, depth + 1));
    }

    const clone = {};
    for (const [childKey, childValue] of Object.entries(next)) {
      clone[childKey] = visit(childValue, childKey, depth + 1);
    }
    return clone;
  }

  return {
    value: visit(value, '', 0),
    redactions,
  };
}

function parseKeyValueResponse(text) {
  const lines = String(text || '').split(/\r?\n/);
  const fields = {};
  for (const line of lines) {
    const match = line.match(/^([^=\s]+)=(.*)$/);
    if (match) fields[match[1]] = match[2];
  }
  const okField = String(fields.ok || '').trim().toLowerCase();
  return {
    ok: okField === 'true' || okField === '1' || okField === 'yes',
    detail: fields.detail || '',
    command: fields.command || '',
    fields,
    lines: lines.filter(Boolean),
    text: String(text || ''),
  };
}

function normalizeEventRecord(record, message, options) {
  const data = record && typeof record.data === 'object' ? record.data : {};
  const payload = data.payload && typeof data.payload === 'object' ? data.payload : {};
  const bmf = payload._bmf && typeof payload._bmf === 'object' ? payload._bmf : {};
  const redacted = redactValue(payload, options);
  return {
    id: String(bmf.eventId || bmf.event_id || message.id || data.id || ''),
    timestamp: String(record.ts || bmf.emittedAt || bmf.emitted_at || message.ts || isoSeconds()),
    type: 'event',
    event: String(data.event || bmf.event || message.event || ''),
    command: '',
    source: String(bmf.source || record.source || message.source || 'bmf'),
    transport: options.transport || 'unknown',
    status: data.ok === false ? 'error' : 'ok',
    payload: redacted.value,
    durationMs: Number.isFinite(Number(data.durationMs)) ? Number(data.durationMs) : undefined,
    consumer: String(data.consumer || ''),
    redactions: redacted.redactions,
  };
}

function normalizeCommandRecord(message, options) {
  const commandText = String(message.command || options.command || '');
  const redacted = redactValue(
    {
      id: message.id || options.id || '',
      command: redactCommandText(commandText),
    },
    options
  );
  return {
    id: String(message.id || options.id || ''),
    timestamp: String(message.ts || options.timestamp || isoSeconds()),
    type: 'command',
    event: '',
    command: commandName(commandText),
    source: String(message.source || options.source || 'omegga.bmf-bridge'),
    transport: options.transport || 'unknown',
    status: String(options.status || message.status || 'pending'),
    payload: redacted.value,
    durationMs: Number.isFinite(Number(options.durationMs)) ? Number(options.durationMs) : undefined,
    consumer: String(options.consumer || 'bmf'),
    redactions: redacted.redactions,
  };
}

function normalizeResponseRecord(message, options) {
  const responseText = typeof message.response === 'string' ? message.response : '';
  const parsed = responseText ? parseKeyValueResponse(responseText) : null;
  const ok = typeof message.ok === 'boolean' ? message.ok : parsed ? parsed.ok : false;
  const commandText = String(options.command || parsed?.command || message.command || '');
  const payload = {
    id: message.id || options.id || '',
    ok,
    detail: message.detail || parsed?.detail || '',
    command: commandText ? redactCommandText(commandText) : undefined,
    response: parsed || message.response || null,
  };
  const redacted = redactValue(payload, options);
  return {
    id: String(message.id || options.id || ''),
    timestamp: String(message.ts || options.timestamp || isoSeconds()),
    type: 'response',
    event: '',
    command: commandName(commandText),
    source: String(message.source || 'bmf'),
    transport: options.transport || 'unknown',
    status: ok ? 'ok' : 'error',
    payload: redacted.value,
    durationMs: Number.isFinite(Number(options.durationMs)) ? Number(options.durationMs) : undefined,
    consumer: String(options.consumer || 'omegga.bmf-bridge'),
    redactions: redacted.redactions,
  };
}

function normalizeDropRecord(message, options) {
  const redacted = redactValue(message.payload || {}, options);
  return {
    id: String(message.id || ''),
    timestamp: String(message.ts || isoSeconds()),
    type: 'drop',
    event: '',
    command: '',
    source: String(message.source || 'omegga.bmf-bridge'),
    transport: options.transport || message.transport || 'unknown',
    status: 'dropped',
    payload: redacted.value,
    durationMs: undefined,
    consumer: '',
    redactions: redacted.redactions,
  };
}

function normalizeStatusRecord(message, options) {
  const redacted = redactValue(message.payload || message, options);
  return {
    id: String(message.id || ''),
    timestamp: String(message.ts || isoSeconds()),
    type: String(message.type || 'status'),
    event: '',
    command: '',
    source: String(message.source || 'omegga.bmf-bridge'),
    transport: options.transport || message.transport || 'unknown',
    status: String(message.status || 'ok'),
    payload: redacted.value,
    durationMs: undefined,
    consumer: '',
    redactions: redacted.redactions,
  };
}

function normalizeEnvelope(input, options = {}) {
  let message = input;
  if (typeof input === 'string') {
    const parsed = safeJsonParse(input);
    message = parsed.ok ? parsed.value : { type: 'log', message: input };
  }
  if (!message || typeof message !== 'object') {
    message = { type: 'log', message: String(input || '') };
  }

  let record = message;
  if (typeof message.record_json === 'string') {
    const parsed = safeJsonParse(message.record_json);
    if (parsed.ok) record = parsed.value;
  } else if (message.record && typeof message.record === 'object') {
    record = message.record;
  }

  if (
    (message.type === 'event' || record.source === 'event') &&
    record &&
    typeof record === 'object' &&
    record.data &&
    typeof record.data === 'object' &&
    record.data.event
  ) {
    return compactObject(normalizeEventRecord(record, message, options));
  }

  if (message.type === 'response' || options.kind === 'response') {
    return compactObject(normalizeResponseRecord(message, options));
  }

  if (message.type === 'command' || options.kind === 'command') {
    return compactObject(normalizeCommandRecord(message, options));
  }

  if (message.type === 'drop' || options.kind === 'drop') {
    return compactObject(normalizeDropRecord(message, options));
  }

  return compactObject(normalizeStatusRecord(message, options));
}

function coalesceKey(record) {
  if (!record || !['status', 'log'].includes(record.type)) return '';
  const payload = record.payload || {};
  return [
    record.type,
    record.source || '',
    record.transport || '',
    record.status || '',
    payload.message || payload.detail || '',
  ].join('|');
}

module.exports = class BmfBridge {
  constructor(omegga, config) {
    this.omegga = omegga || {};
    this.config = config || {};
    this.records = [];
    this.subscribers = new Map();
    this.nextSubscriptionId = 1;
    this.pendingSocketCommands = new Map();
    this.commandSequence = 0;
    this.socket = null;
    this.socketBuffer = '';
    this.socketConfig = null;
    this.eventLogOffset = 0;
    this.eventLogPartial = '';
    this.eventLogInterval = null;
    this.reconnectTimer = null;
    this.statusInterval = null;
    this.started = false;
    this.paused = false;
    this.lastStatusWriteError = null;
    this.counters = {
      retained: 0,
      dropped: 0,
      coalesced: 0,
      pausedSkipped: 0,
      socketConnects: 0,
      socketDisconnects: 0,
      socketErrors: 0,
      socketMessages: 0,
      socketEvents: 0,
      socketResponses: 0,
      socketCommandsSent: 0,
      fileEvents: 0,
      fileCommands: 0,
      fileResponses: 0,
      fallbackCommands: 0,
      parseErrors: 0,
      redactions: 0,
      statusWrites: 0,
      lastRecord: null,
      lastError: null,
      transport: 'initializing',
      socketConnected: false,
    };
    this.handleStatusCommand = this.handleStatusCommand.bind(this);
  }

  async init() {
    if (!asBoolean(this.config.enabled, true)) {
      console.log('[bmf-bridge] disabled by config');
      return { registeredCommands: ['bmfbridge'] };
    }

    this.started = true;
    if (typeof this.omegga.on === 'function') {
      this.omegga.on('cmd:bmfbridge', this.handleStatusCommand);
    }

    this.startEventLogTail();
    this.startStatusWrites();
    if (this.preferredTransport === 'socket') {
      this.connectSocket();
    } else {
      this.counters.transport = 'file-fallback';
    }

    this.writeStatusFile({ lifecycle: 'started' });
    return {
      registeredCommands: ['bmfbridge'],
      helpers: ['subscribe', 'unsubscribe', 'invokeCommand', 'recentRecords', 'statusSnapshot'],
    };
  }

  async stop() {
    this.started = false;
    if (this.eventLogInterval) clearInterval(this.eventLogInterval);
    if (this.reconnectTimer) clearTimeout(this.reconnectTimer);
    if (this.statusInterval) clearInterval(this.statusInterval);
    this.eventLogInterval = null;
    this.reconnectTimer = null;
    this.statusInterval = null;

    if (this.socket) {
      this.socket.removeAllListeners();
      this.socket.destroy();
    }
    this.socket = null;
    this.socketBuffer = '';
    this.counters.socketConnected = false;

    for (const [id, pending] of this.pendingSocketCommands.entries()) {
      clearTimeout(pending.timer);
      pending.reject(new Error(`BMF socket command cancelled during bridge stop: ${id}`));
    }
    this.pendingSocketCommands.clear();

    const remove =
      (typeof this.omegga.off === 'function' && this.omegga.off.bind(this.omegga)) ||
      (typeof this.omegga.removeListener === 'function' && this.omegga.removeListener.bind(this.omegga));
    if (remove) remove('cmd:bmfbridge', this.handleStatusCommand);
    this.writeStatusFile({ lifecycle: 'stopped' });
  }

  get preferredTransport() {
    return String(this.config.preferredTransport || 'socket').trim().toLowerCase();
  }

  get maxRecords() {
    return Math.max(1, asNumber(this.config.maxRecords, DEFAULT_RECORD_LIMIT));
  }

  get runtimeDir() {
    const configured = String(this.config.runtimeDir || '').trim();
    if (configured) return path.resolve(configured);

    const envRuntimeDir = env('OMEGGA_BMF_RUNTIME_DIR');
    if (envRuntimeDir) return path.resolve(envRuntimeDir);

    const commandDir = String(this.config.commandDir || env('OMEGGA_BMF_COMMAND_DIR') || '').trim();
    if (commandDir) return path.dirname(path.resolve(commandDir));

    return standardRuntimeDir();
  }

  get commandDir() {
    const configured = String(this.config.commandDir || '').trim();
    if (configured) return path.resolve(configured);

    const envCommandDir = env('OMEGGA_BMF_COMMAND_DIR');
    if (envCommandDir) return path.resolve(envCommandDir);

    return path.join(this.runtimeDir, 'commands');
  }

  get eventLogPath() {
    const configured = String(this.config.eventLogPath || '').trim();
    if (configured) return path.resolve(configured);

    const envEventPath = env('OMEGGA_BMF_EVENTS_PATH');
    if (envEventPath) return path.resolve(envEventPath);

    return path.join(this.runtimeDir, 'events.jsonl');
  }

  get socketMetadataPath() {
    const configured = String(this.config.socketPath || '').trim();
    if (configured) return path.resolve(configured);
    return path.join(this.runtimeDir, 'socket.json');
  }

  get statusPath() {
    const configured = String(this.config.statusPath || '').trim();
    if (configured) return path.resolve(configured);
    return path.join(this.runtimeDir, 'bmf-bridge-status.json');
  }

  discoverSocketConfig() {
    const metadata = readJsonFile(this.socketMetadataPath) || {};
    const host =
      String(this.config.socketHost || env('OMEGGA_BMF_SOCKET_HOST') || metadata.host || '127.0.0.1').trim();
    const port = asNumber(this.config.socketPort || env('OMEGGA_BMF_SOCKET_PORT') || metadata.port, 0);
    const token = String(this.config.socketToken || env('OMEGGA_BMF_SOCKET_TOKEN') || metadata.token || '').trim();
    let explicitEnabled = this.config.socketEnabled;
    if (explicitEnabled === undefined || explicitEnabled === null || explicitEnabled === '') {
      explicitEnabled = env('OMEGGA_BMF_SOCKET_ENABLED');
    }
    if (explicitEnabled === '') {
      explicitEnabled = metadata.enabled;
    }
    const enabled = asBoolean(explicitEnabled, port > 0 && token !== '');
    return {
      enabled,
      host,
      port,
      token,
      pollIntervalMs: asNumber(metadata.pollIntervalMs || env('OMEGGA_BMF_SOCKET_POLL_MS'), 200),
      role: String(this.config.socketRole || 'plugin'),
      source: String(this.config.socketSource || 'omegga.bmf-bridge'),
    };
  }

  socketReady() {
    return !!(this.socket && this.counters.socketConnected && !this.socket.destroyed && this.socket.writable);
  }

  connectSocket() {
    if (!this.started) return;
    if (this.socketReady()) return;

    const socketConfig = this.discoverSocketConfig();
    this.socketConfig = socketConfig;
    if (!socketConfig.enabled || !socketConfig.port || !socketConfig.token) {
      this.counters.transport = 'file-fallback';
      this.writeStatusFile({ socket: 'unavailable' });
      this.scheduleReconnect();
      return;
    }

    if (this.socket) {
      this.socket.removeAllListeners();
      this.socket.destroy();
      this.socket = null;
    }

    const socket = net.createConnection(
      {
        host: socketConfig.host,
        port: socketConfig.port,
      },
      () => {
        this.counters.socketConnected = true;
        this.counters.socketConnects += 1;
        this.counters.transport = 'socket';
        this.sendSocketMessage({
          type: 'hello',
          role: socketConfig.role,
          source: socketConfig.source,
          version: VERSION,
          token: socketConfig.token,
        });
        this.sendSocketMessage({
          type: 'subscribe',
          source: socketConfig.source,
          events: Array.isArray(this.config.socketEvents) ? this.config.socketEvents : ['*'],
        });
        this.writeStatusFile({ socket: 'connected' });
      }
    );
    socket.setEncoding('utf8');
    socket.on('data', chunk => this.handleSocketData(chunk));
    socket.on('error', error => {
      this.counters.socketErrors += 1;
      this.counters.lastError = error.message || String(error);
      this.writeStatusFile({ socketError: this.counters.lastError });
    });
    socket.on('close', () => {
      const wasConnected = this.counters.socketConnected;
      this.counters.socketConnected = false;
      this.counters.transport = 'file-fallback';
      if (wasConnected) this.counters.socketDisconnects += 1;
      this.rejectPendingSocketCommands('BMF socket disconnected before response.');
      this.writeStatusFile({ socket: 'closed' });
      this.scheduleReconnect();
    });
    this.socket = socket;
  }

  scheduleReconnect() {
    if (!this.started || this.preferredTransport !== 'socket') return;
    if (this.reconnectTimer) return;
    const reconnectMs = Math.max(0, asNumber(this.config.socketReconnectMs, 2500));
    if (reconnectMs <= 0) return;
    this.reconnectTimer = setTimeout(() => {
      this.reconnectTimer = null;
      this.connectSocket();
    }, reconnectMs);
  }

  sendSocketMessage(message) {
    if (!this.socket || this.socket.destroyed || !this.socket.writable) return false;
    this.socket.write(`${JSON.stringify(message)}\n`);
    return true;
  }

  handleSocketData(chunk) {
    this.socketBuffer += String(chunk || '');
    let index = this.socketBuffer.indexOf('\n');
    while (index >= 0) {
      const line = this.socketBuffer.slice(0, index).trim();
      this.socketBuffer = this.socketBuffer.slice(index + 1);
      if (line) this.handleSocketLine(line);
      index = this.socketBuffer.indexOf('\n');
    }
  }

  handleSocketLine(line) {
    const parsed = safeJsonParse(line);
    if (!parsed.ok || !parsed.value || typeof parsed.value !== 'object') {
      this.counters.parseErrors += 1;
      this.counters.lastError = `socket JSON parse failed: ${parsed.error?.message || 'invalid JSON'}`;
      return;
    }

    const message = parsed.value;
    this.counters.socketMessages += 1;
    if (message.type === 'ping') {
      this.sendSocketMessage({
        type: 'pong',
        source: this.socketConfig?.source || 'omegga.bmf-bridge',
        ts: isoSeconds(),
        id: message.id,
      });
      return;
    }

    if (message.type === 'response') {
      this.handleSocketResponse(message);
      return;
    }

    if (message.type === 'event') {
      this.counters.socketEvents += 1;
      this.recordEnvelope(message, { transport: 'socket' });
      return;
    }

    if (message.type === 'hello' || message.type === 'ack' || message.type === 'status') {
      this.recordEnvelope(message, { transport: 'socket' });
    }
  }

  handleSocketResponse(message) {
    this.counters.socketResponses += 1;
    const id = String(message.id || '');
    const pending = this.pendingSocketCommands.get(id);
    const durationMs = pending ? Date.now() - pending.startedAtMs : undefined;
    if (pending) {
      clearTimeout(pending.timer);
      this.pendingSocketCommands.delete(id);
    }
    const envelope = this.recordEnvelope(message, {
      kind: 'response',
      transport: 'socket',
      command: pending?.command || message.command || '',
      durationMs,
    });
    const response = {
      ok: envelope.status === 'ok',
      detail: envelope.payload?.detail || '',
      transport: 'socket',
      response: typeof message.response === 'string' ? parseKeyValueResponse(message.response) : message.response,
      envelope,
    };
    if (pending) pending.resolve(response);
  }

  rejectPendingSocketCommands(message) {
    for (const [id, pending] of this.pendingSocketCommands.entries()) {
      clearTimeout(pending.timer);
      this.pendingSocketCommands.delete(id);
      pending.reject(new Error(`${message} id=${id}`));
    }
  }

  startEventLogTail() {
    if (!asBoolean(this.config.tailEvents, true)) return;
    const eventLogPath = this.eventLogPath;
    if (fs.existsSync(eventLogPath) && !asBoolean(this.config.readExistingEventLog, false)) {
      this.eventLogOffset = fs.statSync(eventLogPath).size;
    }

    const intervalMs = Math.max(250, asNumber(this.config.eventPollIntervalMs, 1000));
    this.eventLogInterval = setInterval(() => this.pollEventLog(), intervalMs);
    this.pollEventLog();
  }

  pollEventLog() {
    const eventLogPath = this.eventLogPath;
    if (!eventLogPath || !fs.existsSync(eventLogPath)) return;

    let stat;
    try {
      stat = fs.statSync(eventLogPath);
    } catch (error) {
      this.counters.lastError = error.message || String(error);
      return;
    }

    if (this.socketReady() && !asBoolean(this.config.tailEventsWhenSocketConnected, false)) {
      this.eventLogOffset = stat.size;
      this.eventLogPartial = '';
      return;
    }

    if (stat.size < this.eventLogOffset) {
      this.eventLogOffset = 0;
      this.eventLogPartial = '';
    }
    if (stat.size <= this.eventLogOffset) return;

    const maxBytes = Math.max(4096, asNumber(this.config.maxReadBytesPerPoll, 65536));
    let start = this.eventLogOffset;
    if (stat.size - start > maxBytes) {
      start = stat.size - maxBytes;
      this.eventLogPartial = '';
      this.recordEnvelope(
        {
          type: 'drop',
          source: 'omegga.bmf-bridge',
          transport: 'events-jsonl',
          payload: {
            reason: 'event-log-backpressure',
            skippedBytes: start - this.eventLogOffset,
          },
        },
        { kind: 'drop', transport: 'events-jsonl' }
      );
    }

    const bytesToRead = stat.size - start;
    const buffer = Buffer.alloc(bytesToRead);
    const fd = fs.openSync(eventLogPath, 'r');
    try {
      fs.readSync(fd, buffer, 0, bytesToRead, start);
    } finally {
      fs.closeSync(fd);
    }
    this.eventLogOffset = stat.size;

    const text = this.eventLogPartial + buffer.toString('utf8');
    const endsWithNewline = text.endsWith('\n') || text.endsWith('\r');
    const lines = text.split(/\r?\n/);
    this.eventLogPartial = endsWithNewline ? '' : lines.pop() || '';
    for (const line of lines) {
      if (line.trim()) this.ingestEventLogLine(line);
    }
  }

  ingestEventLogLine(line) {
    const parsed = safeJsonParse(line);
    if (!parsed.ok) {
      this.counters.parseErrors += 1;
      this.counters.lastError = `events.jsonl parse failed: ${parsed.error?.message || 'invalid JSON'}`;
      return null;
    }
    this.counters.fileEvents += 1;
    return this.recordEnvelope(parsed.value, { transport: 'events-jsonl' });
  }

  recordEnvelope(input, options = {}) {
    const envelope = normalizeEnvelope(input, {
      ...options,
      redactPrivateIps: asBoolean(options.redactPrivateIps, asBoolean(this.config.redactPrivateIpsOnExport, false)),
    });
    this.counters.redactions += asNumber(envelope.redactions, 0);

    const previous = this.records[this.records.length - 1];
    const previousKey = coalesceKey(previous);
    const nextKey = coalesceKey(envelope);
    if (previousKey && previousKey === nextKey) {
      previous.coalesced = asNumber(previous.coalesced, 1) + 1;
      previous.timestamp = envelope.timestamp;
      this.counters.coalesced += 1;
      return previous;
    }

    this.records.push(envelope);
    while (this.records.length > this.maxRecords) {
      this.records.shift();
      this.counters.dropped += 1;
    }
    this.counters.retained = this.records.length;
    this.counters.lastRecord = compactObject({
      id: envelope.id,
      timestamp: envelope.timestamp,
      type: envelope.type,
      event: envelope.event,
      command: envelope.command,
      transport: envelope.transport,
      status: envelope.status,
    });

    this.deliverEnvelope(envelope);
    return envelope;
  }

  deliverEnvelope(envelope) {
    if (this.paused) {
      this.counters.pausedSkipped += 1;
      return;
    }
    for (const [id, subscriber] of this.subscribers.entries()) {
      if (!this.matchesFilter(envelope, subscriber.filter)) continue;
      try {
        subscriber.handler(envelope);
      } catch (error) {
        this.counters.lastError = `subscriber ${id} failed: ${error.message || error}`;
      }
    }
  }

  subscribe(filter, handler) {
    if (typeof handler !== 'function') {
      throw new Error('BMF bridge subscriber must be a function.');
    }
    const id = String(this.nextSubscriptionId++);
    this.subscribers.set(id, {
      filter: filter || '*',
      handler,
    });
    return id;
  }

  unsubscribe(id) {
    return this.subscribers.delete(String(id));
  }

  matchesFilter(envelope, filter) {
    if (!filter || filter === '*') return true;
    if (typeof filter === 'function') return filter(envelope) === true;
    if (typeof filter === 'string') {
      return envelope.event === filter || envelope.type === filter || envelope.command === filter;
    }
    if (Array.isArray(filter)) {
      return filter.some(item => this.matchesFilter(envelope, item));
    }
    if (typeof filter === 'object') {
      for (const [key, expected] of Object.entries(filter)) {
        if (expected === undefined || expected === null || expected === '') continue;
        if (Array.isArray(expected)) {
          if (!expected.includes(envelope[key])) return false;
        } else if (expected !== envelope[key]) {
          return false;
        }
      }
      return true;
    }
    return false;
  }

  recentRecords(options = {}) {
    const limit = Math.max(0, asNumber(options.limit, this.records.length));
    const filter = options.filter || '*';
    const records = this.records.filter(record => this.matchesFilter(record, filter));
    return limit > 0 ? records.slice(-limit) : records;
  }

  setPaused(paused) {
    this.paused = !!paused;
    this.writeStatusFile({ paused: this.paused });
  }

  async invokeCommand(commandText, options = {}) {
    const command = String(commandText || '').trim();
    if (!command) throw new Error('BMF command text is required.');

    const preferSocket = String(options.transport || this.preferredTransport).toLowerCase() === 'socket';
    if (preferSocket && this.socketReady()) {
      return this.invokeSocketCommand(command, options);
    }

    this.counters.fallbackCommands += 1;
    return this.invokeFileCommand(command, options);
  }

  invokeSocketCommand(command, options = {}) {
    if (!this.socketReady()) {
      throw new Error('BMF socket is not connected.');
    }

    const id = String(options.id || `bmf_bridge_${Date.now()}_${++this.commandSequence}`);
    const timeoutMs = Math.max(100, asNumber(options.timeoutMs, asNumber(this.config.commandTimeoutMs, 5000)));
    const startedAtMs = Date.now();
    const message = {
      type: 'command',
      source: this.socketConfig?.source || 'omegga.bmf-bridge',
      id,
      command,
    };

    this.recordEnvelope(message, {
      kind: 'command',
      transport: 'socket',
      status: 'pending',
      command,
    });

    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pendingSocketCommands.delete(id);
        const error = new Error(`timed out waiting for BMF socket response: ${commandName(command)}`);
        this.recordEnvelope(
          {
            type: 'response',
            source: 'bmf',
            id,
            ok: false,
            detail: error.message,
          },
          {
            kind: 'response',
            transport: 'socket',
            command,
            durationMs: Date.now() - startedAtMs,
          }
        );
        reject(error);
      }, timeoutMs);

      this.pendingSocketCommands.set(id, {
        command,
        startedAtMs,
        timer,
        resolve,
        reject,
      });

      if (!this.sendSocketMessage(message)) {
        clearTimeout(timer);
        this.pendingSocketCommands.delete(id);
        reject(new Error('failed to write BMF socket command.'));
        return;
      }
      this.counters.socketCommandsSent += 1;
    });
  }

  writeCommandRequest(command, idPrefix = 'bmf_bridge') {
    const commandDir = this.commandDir;
    const safePrefix = String(idPrefix || 'bmf_bridge').replace(/[^a-zA-Z0-9_-]/g, '_');
    const id = `${safePrefix}_${Date.now()}_${++this.commandSequence}`;
    const tmpPath = path.join(commandDir, `${id}.request.tmp`);
    const requestPath = path.join(commandDir, `${id}.request.txt`);
    const responsePath = path.join(commandDir, `${id}.response.txt`);

    fs.mkdirSync(commandDir, { recursive: true });
    fs.writeFileSync(tmpPath, command, 'utf8');
    fs.renameSync(tmpPath, requestPath);
    return { id, requestPath, responsePath };
  }

  async invokeFileCommand(command, options = {}) {
    const startedAtMs = Date.now();
    const timeoutMs = Math.max(100, asNumber(options.timeoutMs, asNumber(this.config.commandTimeoutMs, 5000)));
    const request = this.writeCommandRequest(command, options.idPrefix || commandName(command) || 'bmf_bridge');
    this.counters.fileCommands += 1;
    this.recordEnvelope(
      {
        type: 'command',
        source: 'omegga.bmf-bridge',
        id: request.id,
        command,
      },
      {
        kind: 'command',
        transport: 'file-command',
        status: 'pending',
        command,
      }
    );

    const deadline = Date.now() + timeoutMs;
    while (Date.now() <= deadline) {
      if (fs.existsSync(request.responsePath)) {
        const text = fs.readFileSync(request.responsePath, 'utf8');
        if (asBoolean(options.cleanupResponse, true)) {
          try {
            fs.unlinkSync(request.responsePath);
          } catch (_cleanupError) {}
        }
        const parsed = parseKeyValueResponse(text);
        this.counters.fileResponses += 1;
        const envelope = this.recordEnvelope(
          {
            type: 'response',
            source: 'bmf',
            id: request.id,
            ok: parsed.ok,
            detail: parsed.detail,
            command,
            response: text,
          },
          {
            kind: 'response',
            transport: 'file-command',
            command,
            durationMs: Date.now() - startedAtMs,
          }
        );
        return {
          ok: parsed.ok,
          detail: parsed.detail,
          transport: 'file-command',
          request,
          response: parsed,
          envelope,
        };
      }
      await new Promise(resolve => setTimeout(resolve, Math.min(50, Math.max(1, deadline - Date.now()))));
    }

    const error = new Error(`timed out waiting for BMF command response: ${commandName(command)}`);
    this.recordEnvelope(
      {
        type: 'response',
        source: 'bmf',
        id: request.id,
        ok: false,
        detail: error.message,
        command,
      },
      {
        kind: 'response',
        transport: 'file-command',
        command,
        durationMs: Date.now() - startedAtMs,
      }
    );
    throw error;
  }

  handleStatusCommand(speaker, action = 'status') {
    const verb = String(action || 'status').trim().toLowerCase();
    if (verb === 'pause') this.setPaused(true);
    if (verb === 'resume') this.setPaused(false);

    const status = this.statusSnapshot();
    const lines = [
      `BMF bridge: transport=${status.transport} socket=${status.socket.connected ? 'connected' : 'disconnected'} paused=${status.paused ? 'true' : 'false'}`,
      `records: retained=${status.records.retained} dropped=${status.records.dropped} coalesced=${status.records.coalesced} paused_skipped=${status.records.pausedSkipped}`,
      `commands: socket_sent=${status.commands.socketSent} file_sent=${status.commands.fileSent} fallback=${status.commands.fallback}`,
      `events: socket=${status.events.socket} file=${status.events.file} parse_errors=${status.events.parseErrors}`,
      `paths: runtime=${status.paths.runtimeDir}`,
      `paths: commands=${status.paths.commandDir}`,
      `paths: events=${status.paths.eventLogPath}`,
    ];
    if (status.lastError) lines.push(`last_error=${status.lastError}`);
    this.sayToSpeaker(speaker, lines);
  }

  sayToSpeaker(speaker, lines) {
    const target = typeof speaker === 'string' ? speaker : speaker?.name || speaker?.displayName || '';
    if (target && typeof this.omegga.whisper === 'function') {
      for (const line of lines) this.omegga.whisper(target, line);
      return;
    }
    if (typeof this.omegga.broadcast === 'function') {
      for (const line of lines) this.omegga.broadcast(line);
      return;
    }
    for (const line of lines) console.log(`[bmf-bridge] ${line}`);
  }

  startStatusWrites() {
    const intervalMs = Math.max(0, asNumber(this.config.statusWriteIntervalMs, 5000));
    if (intervalMs <= 0) return;
    this.statusInterval = setInterval(() => this.writeStatusFile(), intervalMs);
  }

  statusSnapshot(extra = {}) {
    const socket = this.socketConfig || this.discoverSocketConfig();
    return {
      updatedAt: isoSeconds(),
      version: VERSION,
      guardrails: GUARDRAILS,
      transport: this.counters.transport,
      paused: this.paused,
      records: {
        retained: this.records.length,
        max: this.maxRecords,
        dropped: this.counters.dropped,
        coalesced: this.counters.coalesced,
        pausedSkipped: this.counters.pausedSkipped,
      },
      socket: {
        enabled: !!socket.enabled,
        connected: this.counters.socketConnected,
        host: socket.host,
        port: socket.port,
        token: socket.token ? '[redacted]' : '',
        connects: this.counters.socketConnects,
        disconnects: this.counters.socketDisconnects,
        errors: this.counters.socketErrors,
      },
      commands: {
        socketSent: this.counters.socketCommandsSent,
        socketResponses: this.counters.socketResponses,
        fileSent: this.counters.fileCommands,
        fileResponses: this.counters.fileResponses,
        fallback: this.counters.fallbackCommands,
      },
      events: {
        socket: this.counters.socketEvents,
        file: this.counters.fileEvents,
        parseErrors: this.counters.parseErrors,
        redactions: this.counters.redactions,
      },
      subscribers: this.subscribers.size,
      paths: {
        runtimeDir: this.runtimeDir,
        commandDir: this.commandDir,
        eventLogPath: this.eventLogPath,
        socketMetadataPath: this.socketMetadataPath,
        statusPath: this.statusPath,
      },
      lastRecord: this.counters.lastRecord,
      lastError: this.counters.lastError || this.lastStatusWriteError,
      ...extra,
    };
  }

  writeStatusFile(extra = {}) {
    const statusPath = this.statusPath;
    if (!statusPath) return;
    try {
      fs.mkdirSync(path.dirname(statusPath), { recursive: true });
      fs.writeFileSync(statusPath, `${JSON.stringify(this.statusSnapshot(extra), null, 2)}\n`, 'utf8');
      this.counters.statusWrites += 1;
      this.lastStatusWriteError = null;
    } catch (error) {
      this.lastStatusWriteError = error.message || String(error);
    }
  }
};

module.exports.VERSION = VERSION;
module.exports.normalizeEnvelope = normalizeEnvelope;
module.exports.redactValue = redactValue;
module.exports.parseKeyValueResponse = parseKeyValueResponse;
module.exports.commandName = commandName;
