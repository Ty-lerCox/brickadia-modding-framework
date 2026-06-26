const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const net = require('node:net');

const { createServerProfile, publicProfile } = require('./profiles');
const { resolveRuntimePaths } = require('./observations');

const DEFAULT_MAX_RECORDS = 100;
const DEFAULT_MAX_BYTES_PER_FILE = 512 * 1024;
const DEFAULT_SOCKET_CONNECT_TIMEOUT_MS = 1000;
const DEFAULT_SOCKET_RECONNECT_MS = 2500;
const DEFAULT_MAX_SOCKET_BUFFER_BYTES = 1024 * 1024;
const TRAFFIC_SOCKET_CLIENTS = new Map();
const TRAFFIC_GUARDRAILS = [
  'socket-only-live-traffic',
  'single-loopback-socket-subscriber',
  'bounded-socket-buffer',
  'bounded-status-file-reads',
  'bounded-record-retention',
  'redact-secrets-before-display-or-export',
  'do-not-add-ui-driven-server-probes',
  'do-not-send-bmf-commands',
];
const TRAFFIC_EXPORT_GUARDRAILS = [
  ...TRAFFIC_GUARDRAILS,
  'explicit-export-confirmation-required',
  'export-redacted-snapshot-only',
  'support-export-can-anonymize-players',
  'support-export-can-redact-private-ips',
];
const SECRET_KEY_PATTERN = /(token|secret|password|api[-_]?key|authorization|auth|bearer|credential|steam|session)/i;
const PLAYER_KEY_PATTERN = /(player|user|account|steam[-_]?id|host[-_]?id|uuid|display[-_]?name)/i;
const PRIVATE_IPV4_PATTERN = /\b(?:10\.\d{1,3}\.\d{1,3}\.\d{1,3}|192\.168\.\d{1,3}\.\d{1,3}|172\.(?:1[6-9]|2\d|3[01])\.\d{1,3}\.\d{1,3})\b/g;

function collectTrafficSnapshot(input = {}, options = {}) {
  const profile = normalizeProfile(input.profile || input);
  const paths = options.paths || resolveRuntimePaths(profile);
  const limits = {
    maxRecords: boundedInteger(options.maxRecords ?? options.limit, DEFAULT_MAX_RECORDS, 1, 5000),
    maxBytesPerFile: boundedInteger(options.maxBytesPerFile ?? options.maxBytes, DEFAULT_MAX_BYTES_PER_FILE, 4096, 16 * 1024 * 1024),
    maxSocketBufferBytes: boundedInteger(options.maxSocketBufferBytes, DEFAULT_MAX_SOCKET_BUFFER_BYTES, 64 * 1024, 16 * 1024 * 1024),
  };
  const state = {
    records: [],
    sourceDiagnostics: [],
    parseErrors: 0,
    redactions: 0,
    droppedRecords: 0,
  };
  const redactionOptions = {
    anonymizePlayers: Boolean(options.anonymizePlayers),
    redactPrivateIps: Boolean(options.redactPrivateIps),
  };

  readSocketStreamSource(state, paths, {
    ...redactionOptions,
    maxRecords: limits.maxRecords,
    maxBufferBytes: limits.maxSocketBufferBytes,
    connectTimeoutMs: boundedInteger(options.socketConnectTimeoutMs, DEFAULT_SOCKET_CONNECT_TIMEOUT_MS, 100, 10_000),
    reconnectMs: boundedInteger(options.socketReconnectMs, DEFAULT_SOCKET_RECONNECT_MS, 0, 60_000),
  });
  readBridgeStatusSource(state, paths.bridgeStatus, {
    ...redactionOptions,
    maxBytes: limits.maxBytesPerFile,
    maxRecords: limits.maxRecords,
    source: 'omegga.bmf-bridge',
  });
  readJsonStatusSource(state, 'socket-metadata', paths.socketMetadata, {
    ...redactionOptions,
    maxBytes: limits.maxBytesPerFile,
    source: 'bmf-socket',
    transport: 'socket-metadata',
    includeRecord: false,
  });

  const sorted = state.records
    .map((record, index) => ({ record, index }))
    .sort((left, right) => {
      const leftTime = timestampMs(left.record.timestamp);
      const rightTime = timestampMs(right.record.timestamp);
      if (leftTime !== rightTime) return rightTime - leftTime;
      return right.index - left.index;
    });
  const deduped = [];
  const seenRecords = new Set();
  for (const item of sorted) {
    const key = recordDedupeKey(item.record);
    if (seenRecords.has(key)) {
      state.droppedRecords += 1;
      continue;
    }
    seenRecords.add(key);
    deduped.push(item.record);
  }
  const retained = deduped.slice(0, limits.maxRecords);
  state.droppedRecords += Math.max(0, deduped.length - retained.length);

  return {
    schemaVersion: 1,
    collectedAt: toIso(options.now || new Date()),
    profile: publicProfile(profile),
    records: retained,
    summary: {
      retained: retained.length,
      dropped: state.droppedRecords,
      sources: state.sourceDiagnostics.length,
      parseErrors: state.parseErrors,
      redactions: state.redactions,
      truncatedSources: state.sourceDiagnostics.filter(source => source.truncated).length,
    },
    sources: state.sourceDiagnostics,
    paths: {
      runtimeDir: paths.runtimeDir || null,
      socketMetadata: paths.socketMetadata || null,
      bridgeStatus: paths.bridgeStatus || null,
    },
    limits,
    guardrails: TRAFFIC_GUARDRAILS,
  };
}

function readSocketStreamSource(state, paths, options) {
  const diagnostic = sourceDiagnostic('socket-stream', null);
  diagnostic.transport = 'socket';
  diagnostic.status = 'unconfigured';
  state.sourceDiagnostics.push(diagnostic);

  const metadataPath = paths.socketMetadata;
  if (!metadataPath || !fs.existsSync(metadataPath)) {
    diagnostic.error = 'BMF socket metadata was not found.';
    return;
  }

  try {
    const result = readHeadText(metadataPath, 64 * 1024);
    diagnostic.exists = true;
    diagnostic.bytes = result.bytes;
    diagnostic.truncated = result.truncated;
    diagnostic.mtime = fs.statSync(metadataPath).mtime.toISOString();
    const parsed = safeJsonParse(result.text);
    if (!parsed.ok || !parsed.value || typeof parsed.value !== 'object') {
      diagnostic.parseErrors += 1;
      state.parseErrors += 1;
      diagnostic.error = parsed.error || 'invalid socket metadata JSON';
      return;
    }

    const metadata = parsed.value;
    const config = {
      enabled: asBoolean(metadata.enabled, true),
      host: String(metadata.host || '127.0.0.1').trim() || '127.0.0.1',
      port: boundedInteger(metadata.port, 0, 0, 65535),
      token: String(metadata.token || '').trim(),
      runtimeDir: paths.runtimeDir || path.dirname(metadataPath),
      metadataPath,
    };
    diagnostic.path = config.port > 0 ? `tcp://${config.host}:${config.port}` : metadataPath;

    if (!config.enabled || !config.port || !config.token) {
      stopTrafficSocketClient(socketClientKey(config));
      diagnostic.status = config.enabled ? 'not-configured' : 'disabled';
      diagnostic.error = config.enabled
        ? 'Socket metadata is missing host, port, or token.'
        : 'Socket transport is disabled in metadata.';
      return;
    }

    const client = ensureTrafficSocketClient(config, options);
    const clientState = client.statusSnapshot();
    diagnostic.status = clientState.status;
    diagnostic.error = clientState.lastError || null;
    diagnostic.socketRecords = clientState.records;
    diagnostic.dropped = clientState.dropped;
    state.droppedRecords += clientState.dropped;
    diagnostic.connects = clientState.connects;
    diagnostic.disconnects = clientState.disconnects;
    diagnostic.parseErrors = clientState.parseErrors;
    diagnostic.transports.push('socket');
    diagnostic.clientId = clientState.clientId;

    for (const record of client.recordsSnapshot(options.maxRecords)) {
      addRecord(state, diagnostic, record, { transport: record.transport || 'socket' });
    }
  } catch (error) {
    diagnostic.status = 'error';
    diagnostic.error = error.message || String(error);
  }
}

function ensureTrafficSocketClient(config, options) {
  const key = socketClientKey(config);
  const existing = TRAFFIC_SOCKET_CLIENTS.get(key);
  if (existing) {
    existing.updateOptions(options);
    return existing;
  }

  for (const [clientKey, client] of TRAFFIC_SOCKET_CLIENTS.entries()) {
    if (client.metadataPath === config.metadataPath && clientKey !== key) {
      client.stop();
      TRAFFIC_SOCKET_CLIENTS.delete(clientKey);
    }
  }

  const client = new TrafficSocketClient(config, options);
  TRAFFIC_SOCKET_CLIENTS.set(key, client);
  client.connect();
  return client;
}

function stopTrafficSocketClient(key) {
  const client = TRAFFIC_SOCKET_CLIENTS.get(key);
  if (!client) return;
  client.stop();
  TRAFFIC_SOCKET_CLIENTS.delete(key);
}

function resetTrafficSocketClients() {
  for (const client of TRAFFIC_SOCKET_CLIENTS.values()) client.stop();
  TRAFFIC_SOCKET_CLIENTS.clear();
}

function socketClientKey(config) {
  const tokenHash = crypto.createHash('sha256').update(String(config.token || '')).digest('hex').slice(0, 16);
  return [
    path.resolve(config.metadataPath || config.runtimeDir || ''),
    config.host,
    config.port,
    tokenHash,
  ].join('|');
}

class TrafficSocketClient {
  constructor(config, options = {}) {
    this.config = { ...config };
    this.metadataPath = config.metadataPath;
    this.clientId = crypto.randomBytes(6).toString('hex');
    this.records = [];
    this.socket = null;
    this.buffer = '';
    this.reconnectTimer = null;
    this.status = 'idle';
    this.lastError = '';
    this.connects = 0;
    this.disconnects = 0;
    this.parseErrors = 0;
    this.dropped = 0;
    this.updateOptions(options);
  }

  updateOptions(options = {}) {
    this.options = {
      anonymizePlayers: Boolean(options.anonymizePlayers),
      redactPrivateIps: Boolean(options.redactPrivateIps),
      maxRecords: boundedInteger(options.maxRecords, DEFAULT_MAX_RECORDS, 1, 5000),
      maxBufferBytes: boundedInteger(options.maxBufferBytes, DEFAULT_MAX_SOCKET_BUFFER_BYTES, 64 * 1024, 16 * 1024 * 1024),
      connectTimeoutMs: boundedInteger(options.connectTimeoutMs, DEFAULT_SOCKET_CONNECT_TIMEOUT_MS, 100, 10_000),
      reconnectMs: boundedInteger(options.reconnectMs, DEFAULT_SOCKET_RECONNECT_MS, 0, 60_000),
    };
    this.trimRecords();
  }

  connect() {
    if (this.socket && !this.socket.destroyed) return;
    if (this.reconnectTimer) return;

    this.status = 'connecting';
    this.lastError = '';
    const socket = net.createConnection({
      host: this.config.host,
      port: this.config.port,
    });
    this.socket = socket;
    socket.setEncoding('utf8');
    socket.setNoDelay(true);
    socket.setTimeout(this.options.connectTimeoutMs);
    socket.on('connect', () => {
      this.status = 'connected';
      this.lastError = '';
      this.connects += 1;
      socket.setTimeout(0);
      this.write({
        type: 'hello',
        role: 'plugin',
        source: 'bmf.desktop',
        token: this.config.token,
        version: 1,
      });
      this.write({
        type: 'subscribe',
        source: 'bmf.desktop',
        events: ['*'],
      });
      this.recordStatus('connected', {
        host: this.config.host,
        port: this.config.port,
      });
    });
    socket.on('data', chunk => this.handleData(chunk));
    socket.on('timeout', () => {
      this.lastError = `Timed out connecting to BMF socket ${this.config.host}:${this.config.port}.`;
      socket.destroy();
    });
    socket.on('error', error => {
      this.lastError = error.message || String(error);
      this.status = 'error';
    });
    socket.on('close', () => {
      if (this.status === 'connected') this.disconnects += 1;
      if (this.status !== 'stopped') this.status = this.lastError ? 'error' : 'disconnected';
      this.socket = null;
      this.scheduleReconnect();
    });
  }

  scheduleReconnect() {
    if (this.status === 'stopped') return;
    if (this.reconnectTimer || this.options.reconnectMs <= 0) return;
    this.reconnectTimer = setTimeout(() => {
      this.reconnectTimer = null;
      this.connect();
    }, this.options.reconnectMs);
    if (typeof this.reconnectTimer.unref === 'function') this.reconnectTimer.unref();
  }

  stop() {
    this.status = 'stopped';
    if (this.reconnectTimer) clearTimeout(this.reconnectTimer);
    this.reconnectTimer = null;
    if (this.socket) {
      this.socket.removeAllListeners();
      this.socket.destroy();
    }
    this.socket = null;
  }

  write(message) {
    if (!this.socket || this.socket.destroyed || !this.socket.writable) return false;
    this.socket.write(`${JSON.stringify(message)}\n`);
    return true;
  }

  handleData(chunk) {
    this.buffer += String(chunk || '');
    if (Buffer.byteLength(this.buffer, 'utf8') > this.options.maxBufferBytes) {
      this.lastError = 'BMF socket input buffer exceeded the configured limit.';
      this.buffer = '';
      this.recordEnvelope({
        type: 'drop',
        source: 'bmf.desktop',
        ts: toIso(new Date()),
        payload: { reason: 'socket-buffer-limit' },
      });
      return;
    }

    let index = this.buffer.indexOf('\n');
    while (index >= 0) {
      const line = this.buffer.slice(0, index).trim();
      this.buffer = this.buffer.slice(index + 1);
      if (line) this.handleLine(line);
      index = this.buffer.indexOf('\n');
    }
  }

  handleLine(line) {
    const parsed = safeJsonParse(line);
    if (!parsed.ok || !parsed.value || typeof parsed.value !== 'object') {
      this.parseErrors += 1;
      this.lastError = parsed.error || 'invalid socket JSON';
      return;
    }
    this.recordEnvelope(parsed.value);
  }

  recordStatus(status, payload = {}) {
    this.recordEnvelope({
      type: 'status',
      source: 'bmf.desktop',
      ts: toIso(new Date()),
      status,
      payload,
    });
  }

  recordEnvelope(message) {
    const record = normalizeEnvelope(message, {
      anonymizePlayers: this.options.anonymizePlayers,
      redactPrivateIps: this.options.redactPrivateIps,
      transport: 'socket',
      source: message.source || 'bmf-socket',
      observedAt: message.ts || toIso(new Date()),
    });
    this.records.push(record);
    this.trimRecords();
  }

  trimRecords() {
    const excess = this.records.length - this.options.maxRecords;
    if (excess <= 0) return;
    this.records.splice(0, excess);
    this.dropped += excess;
  }

  recordsSnapshot(limit = this.options.maxRecords) {
    const count = boundedInteger(limit, this.options.maxRecords, 1, 5000);
    return this.records.slice(-count);
  }

  statusSnapshot() {
    return {
      clientId: this.clientId,
      status: this.status,
      lastError: this.lastError,
      connects: this.connects,
      disconnects: this.disconnects,
      parseErrors: this.parseErrors,
      records: this.records.length,
      dropped: this.dropped,
    };
  }
}

function writeTrafficTraceExport(input = {}, options = {}) {
  const profile = normalizeProfile(input.profile || input);
  const now = toIso(options.now || new Date());
  const outputPath = resolveTrafficExportPath(profile, options, now);
  const snapshot = collectTrafficSnapshot({ profile }, {
    ...options,
    anonymizePlayers: Boolean(options.anonymizePlayers),
    redactPrivateIps: Boolean(options.redactPrivateIps),
  });
  const payload = {
    schemaVersion: 1,
    feature: 'traffic.trace.export',
    createdAt: now,
    profile: publicProfile(profile),
    anonymizedPlayers: Boolean(options.anonymizePlayers),
    redactedPrivateIps: Boolean(options.redactPrivateIps),
    snapshot,
    guardrails: TRAFFIC_EXPORT_GUARDRAILS,
  };
  const json = `${JSON.stringify(payload, null, 2)}\n`;
  const sha256 = crypto.createHash('sha256').update(json).digest('hex');
  const dryRun = options.dryRun !== false;

  const result = {
    schemaVersion: 1,
    feature: 'traffic.trace.export',
    status: dryRun ? 'planned' : 'written',
    dryRun,
    confirmed: false,
    createdAt: now,
    outputPath,
    bytes: Buffer.byteLength(json, 'utf8'),
    sha256,
    summary: snapshot.summary,
    snapshot,
    guardrails: TRAFFIC_EXPORT_GUARDRAILS,
  };

  if (dryRun) return result;
  if (String(options.confirm || '').toLowerCase() !== 'export') {
    throw new Error('Refusing to export traffic trace without explicit --confirm export.');
  }

  fs.mkdirSync(path.dirname(outputPath), { recursive: true });
  fs.writeFileSync(outputPath, json, 'utf8');
  return {
    ...result,
    confirmed: true,
  };
}

function resolveTrafficExportPath(profile, options, now) {
  if (options.out || options.outputPath || options.tracePath) {
    return path.resolve(options.out || options.outputPath || options.tracePath);
  }
  const root = options.exportRoot || options.root || process.cwd();
  const profileId = String(profile?.id || 'local').replace(/[^A-Za-z0-9_.-]+/g, '-');
  const stamp = String(now || toIso(new Date())).replace(/[:.]/g, '-');
  return path.join(root, 'artifacts', 'local', 'traffic-traces', `${profileId}-${stamp}.json`);
}

function normalizeProfile(input = {}) {
  if (input && input.schemaVersion === 1 && input.id && input.ports && input.paths && input.telemetry) {
    return input;
  }
  return createServerProfile(input);
}

function readJsonStatusSource(state, id, filePath, options) {
  const diagnostic = sourceDiagnostic(id, filePath);
  state.sourceDiagnostics.push(diagnostic);
  if (!filePath || !fs.existsSync(filePath)) return;

  try {
    const result = readHeadText(filePath, options.maxBytes);
    diagnostic.exists = true;
    diagnostic.bytes = result.bytes;
    diagnostic.truncated = result.truncated;
    diagnostic.mtime = fs.statSync(filePath).mtime.toISOString();
    const parsed = safeJsonParse(result.text);
    if (!parsed.ok) {
      diagnostic.parseErrors += 1;
      state.parseErrors += 1;
      return;
    }
    if (options.includeRecord !== false) {
      addRecord(state, diagnostic, normalizeEnvelope(parsed.value, {
        kind: 'status',
        source: options.source,
        transport: options.transport,
        observedAt: diagnostic.mtime,
      }), options);
    }
  } catch (error) {
    diagnostic.error = error.message || String(error);
  }
}

function readBridgeStatusSource(state, filePath, options) {
  const diagnostic = sourceDiagnostic('bmf-bridge-status', filePath);
  diagnostic.transport = 'socket';
  state.sourceDiagnostics.push(diagnostic);
  if (!filePath || !fs.existsSync(filePath)) return;

  try {
    const result = readHeadText(filePath, options.maxBytes);
    diagnostic.exists = true;
    diagnostic.bytes = result.bytes;
    diagnostic.truncated = result.truncated;
    diagnostic.mtime = fs.statSync(filePath).mtime.toISOString();
    const parsed = safeJsonParse(result.text);
    if (!parsed.ok || !parsed.value || typeof parsed.value !== 'object') {
      diagnostic.parseErrors += 1;
      state.parseErrors += 1;
      diagnostic.error = parsed.error || 'invalid bridge status JSON';
      return;
    }

    const status = parsed.value;
    diagnostic.status = status.socket?.connected === true
      ? 'connected'
      : status.socket?.connected === false
        ? 'disconnected'
        : String(status.transport || 'unknown');
    diagnostic.retained = boundedInteger(status.records?.retained, 0, 0, 1_000_000);
    diagnostic.dropped = boundedInteger(status.records?.dropped, 0, 0, 1_000_000);
    diagnostic.coalesced = boundedInteger(status.records?.coalesced, 0, 0, 1_000_000);
    diagnostic.statusLimit = boundedInteger(status.records?.statusLimit, 0, 0, 5000);
    if (status.transport && !diagnostic.transports.includes(status.transport)) {
      diagnostic.transports.push(status.transport);
    }

    const recentRecords = Array.isArray(status.recentRecords) ? status.recentRecords : [];
    const limit = boundedInteger(options.maxRecords, DEFAULT_MAX_RECORDS, 1, 5000);
    for (const retainedRecord of recentRecords.slice(-limit)) {
      const record = normalizeEnvelope(retainedRecord, {
        ...options,
        source: retainedRecord?.source || options.source,
        transport: retainedRecord?.transport || 'socket',
        observedAt: diagnostic.mtime,
      });
      addRecord(state, diagnostic, record, { transport: record.transport || 'socket' });
    }
  } catch (error) {
    diagnostic.error = error.message || String(error);
  }
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

  if (isNormalizedTrafficRecord(record)) {
    return compactObject(redactNormalizedTrafficRecord(record, options));
  }
  if (looksLikeEventRecord(record)) {
    return compactObject(normalizeEventRecord(record, message, options));
  }
  if (looksLikeAuditRecord(record) || options.kind === 'audit-log') {
    return compactObject(normalizeAuditRecord(record, options));
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

function isNormalizedTrafficRecord(record) {
  return !!(
    record &&
    typeof record === 'object' &&
    typeof record.type === 'string' &&
    record.timestamp &&
    !record.data
  );
}

function redactNormalizedTrafficRecord(record, options) {
  const redacted = redactValue(record.payload ?? {}, options);
  return {
    id: String(record.id || ''),
    timestamp: String(record.timestamp || record.ts || options.observedAt || toIso(new Date())),
    type: String(record.type || 'status'),
    event: String(record.event || ''),
    command: String(record.command || ''),
    source: String(record.source || options.source || 'bmf'),
    transport: String(record.transport || options.transport || 'unknown'),
    status: String(record.status || 'ok'),
    payload: redacted.value,
    durationMs: numberOrUndefined(record.durationMs),
    consumer: String(record.consumer || ''),
    coalesced: numberOrUndefined(record.coalesced),
    redactions: boundedInteger(record.redactions, 0, 0, 1_000_000) + redacted.redactions,
  };
}

function looksLikeEventRecord(record) {
  return !!(
    record &&
    typeof record === 'object' &&
    ((record.source === 'event' && record.data && record.data.event) ||
      record.type === 'event' ||
      (record.data && record.data.payload && record.data.event))
  );
}

function looksLikeAuditRecord(record) {
  return !!(record && typeof record === 'object' && (record.action || record.auditAction));
}

function normalizeEventRecord(record, message, options) {
  const data = record && typeof record.data === 'object' ? record.data : {};
  const payload = data.payload && typeof data.payload === 'object' ? data.payload : data.payload ?? data;
  const bmf = payload && typeof payload === 'object' && payload._bmf && typeof payload._bmf === 'object'
    ? payload._bmf
    : {};
  const redacted = redactValue(payload, options);
  return {
    id: String(bmf.eventId || bmf.event_id || message.id || record.id || ''),
    timestamp: String(record.ts || bmf.emittedAt || bmf.emitted_at || message.ts || options.observedAt || toIso(new Date())),
    type: 'event',
    event: String(data.event || bmf.event || message.event || ''),
    command: '',
    source: String(bmf.source || record.source || message.source || options.source || 'bmf'),
    transport: options.transport || message.transport || 'unknown',
    status: data.ok === false || record.level === 'error' ? 'error' : 'ok',
    payload: redacted.value,
    durationMs: numberOrUndefined(data.durationMs || record.durationMs || message.durationMs),
    consumer: String(data.consumer || message.consumer || ''),
    redactions: redacted.redactions,
  };
}

function normalizeAuditRecord(record, options) {
  const redacted = redactValue(record.data || {}, options);
  return {
    id: String(record.id || ''),
    timestamp: String(record.ts || record.timestamp || options.observedAt || toIso(new Date())),
    type: 'audit',
    event: String(record.action || record.auditAction || ''),
    command: commandName(record.data?.command || record.command || ''),
    source: String(record.source || options.source || 'bmf-audit'),
    transport: options.transport || record.transport || 'unknown',
    status: record.ok === false || record.severity === 'error' ? 'error' : 'ok',
    payload: redacted.value,
    durationMs: numberOrUndefined(record.durationMs || record.data?.durationMs),
    consumer: String(record.plugin || record.consumer || ''),
    redactions: redacted.redactions,
  };
}

function normalizeCommandRecord(message, options) {
  const commandText = String(message.command || options.command || '');
  const redacted = redactValue({
    id: message.id || options.id || '',
    command: redactCommandText(commandText),
    file: options.file,
    truncated: options.truncated,
  }, options);
  return {
    id: String(message.id || options.id || ''),
    timestamp: String(message.ts || options.timestamp || options.observedAt || toIso(new Date())),
    type: 'command',
    event: '',
    command: commandName(commandText),
    source: String(message.source || options.source || 'omegga.bmf-bridge'),
    transport: options.transport || message.transport || 'unknown',
    status: String(options.status || message.status || 'pending'),
    payload: redacted.value,
    durationMs: numberOrUndefined(options.durationMs || message.durationMs),
    consumer: String(options.consumer || 'bmf'),
    redactions: redacted.redactions,
  };
}

function normalizeResponseRecord(message, options) {
  const responseText = typeof message.response === 'string' ? message.response : '';
  const parsed = responseText ? parseKeyValueResponse(responseText) : null;
  const response = parsed || message.response || {};
  const ok = typeof message.ok === 'boolean'
    ? message.ok
    : typeof response.ok === 'boolean'
      ? response.ok
      : false;
  const commandText = String(options.command || response.command || message.command || '');
  const payload = {
    id: message.id || options.id || '',
    ok,
    detail: message.detail || response.detail || '',
    command: commandText ? redactCommandText(commandText) : undefined,
    response,
    file: options.file,
    truncated: options.truncated,
  };
  const redacted = redactValue(payload, options);
  return {
    id: String(message.id || options.id || ''),
    timestamp: String(message.ts || options.timestamp || options.observedAt || toIso(new Date())),
    type: 'response',
    event: '',
    command: commandName(commandText),
    source: String(message.source || options.source || 'bmf'),
    transport: options.transport || message.transport || 'unknown',
    status: ok ? 'ok' : 'error',
    payload: redacted.value,
    durationMs: numberOrUndefined(options.durationMs || response.durationMs || response.totalMs),
    consumer: String(options.consumer || 'omegga.bmf-bridge'),
    redactions: redacted.redactions,
  };
}

function normalizeDropRecord(message, options) {
  const redacted = redactValue(message.payload || {}, options);
  return {
    id: String(message.id || ''),
    timestamp: String(message.ts || options.observedAt || toIso(new Date())),
    type: 'drop',
    event: '',
    command: '',
    source: String(message.source || options.source || 'omegga.bmf-bridge'),
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
  const socketConnected = message.socket && typeof message.socket === 'object'
    ? message.socket.connected
    : undefined;
  return {
    id: String(message.id || ''),
    timestamp: String(message.updatedAt || message.ts || options.observedAt || toIso(new Date())),
    type: String(message.type || 'status'),
    event: '',
    command: '',
    source: String(message.source || options.source || 'omegga.bmf-bridge'),
    transport: options.transport || message.transport || 'unknown',
    status: String(message.status || (socketConnected === false ? 'disconnected' : 'ok')),
    payload: redacted.value,
    durationMs: undefined,
    consumer: '',
    redactions: redacted.redactions,
  };
}

function addRecord(state, diagnostic, envelope, options) {
  const record = compactObject(envelope);
  if (!record.timestamp) record.timestamp = toIso(new Date());
  state.redactions += boundedInteger(record.redactions, 0, 0, 1000000);
  diagnostic.records += 1;
  if (options.transport && !diagnostic.transports.includes(options.transport)) {
    diagnostic.transports.push(options.transport);
  }
  state.records.push(record);
}

function redactValue(value, options = {}, seen = new WeakSet()) {
  let redactions = 0;

  function visit(next, key, depth) {
    const keyText = String(key || '');
    if (SECRET_KEY_PATTERN.test(keyText)) {
      redactions += 1;
      return '[redacted]';
    }
    if (options.anonymizePlayers && PLAYER_KEY_PATTERN.test(keyText)) {
      redactions += 1;
      return '[anonymized]';
    }
    if (next === null || next === undefined) return next;

    if (typeof next === 'string') {
      let text = redactUrl(next);
      if (text !== next) redactions += 1;
      text = text.replace(
        /\b(Bearer|Token)\s+[A-Za-z0-9._~+/=-]+/gi,
        (_match, scheme) => {
          redactions += 1;
          return `${scheme} [redacted]`;
        },
      );
      text = text.replace(
        /\b([A-Za-z0-9_.-]*(?:token|secret|password|api[_-]?key|authorization|credential|session)[A-Za-z0-9_.-]*)=([^ \t\r\n&]+)/gi,
        (_match, name) => {
          redactions += 1;
          return `${name}=[redacted]`;
        },
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
    if (depth > boundedInteger(options.maxDepth, 8, 1, 32)) return '[max-depth]';
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
  const fields = {};
  const lines = String(text || '').split(/\r?\n/).filter(Boolean);
  for (const line of lines) {
    const match = line.match(/^([^=\s]+)=(.*)$/);
    if (match) fields[match[1]] = match[2];
  }
  const okField = String(fields.ok || '').trim().toLowerCase();
  return {
    ok: okField === 'true' || okField === '1' || okField === 'yes',
    detail: fields.detail || '',
    command: fields.command || '',
    durationMs: numberOrUndefined(fields.bmf_command_total_ms || fields.durationMs),
    dispatchMs: numberOrUndefined(fields.bmf_command_dispatch_ms),
    requestAgeMs: numberOrUndefined(fields.bmf_command_request_age_ms),
    transport: fields.bmf_command_transport || '',
    fields,
    lines,
  };
}

function readHeadText(filePath, maxBytes) {
  const stat = fs.statSync(filePath);
  const bytes = Math.min(stat.size, maxBytes);
  const buffer = Buffer.alloc(bytes);
  const fd = fs.openSync(filePath, 'r');
  try {
    fs.readSync(fd, buffer, 0, bytes, 0);
  } finally {
    fs.closeSync(fd);
  }
  return {
    text: buffer.toString('utf8'),
    bytes,
    truncated: stat.size > bytes,
  };
}

function safeJsonParse(text) {
  try {
    return { ok: true, value: JSON.parse(text), error: null };
  } catch (error) {
    return { ok: false, value: null, error: error.message || String(error) };
  }
}

function sourceDiagnostic(id, filePath) {
  return {
    id,
    path: filePath || null,
    exists: false,
    bytes: 0,
    records: 0,
    parseErrors: 0,
    truncated: false,
    transports: [],
    mtime: null,
    error: null,
  };
}

function commandName(commandText) {
  return String(commandText || '').trim().split(/\s+/)[0] || '';
}

function redactCommandText(commandText) {
  return String(commandText || '').replace(
    /\b([A-Za-z0-9_.-]*(?:token|secret|password|api[_-]?key|authorization|credential|session)[A-Za-z0-9_.-]*)=([^ \t\r\n]+)/gi,
    '$1=[redacted]',
  );
}

function redactUrl(url) {
  return String(url || '').replace(/([?&](?:token|api_key|apikey|key|auth|session)=)[^&]+/gi, '$1[redacted]');
}

function compactObject(value) {
  const result = {};
  for (const [key, next] of Object.entries(value || {})) {
    if (next !== undefined && next !== null && next !== '') result[key] = next;
  }
  return result;
}

function boundedInteger(value, fallback, min, max) {
  const parsed = Number(value);
  if (!Number.isFinite(parsed)) return fallback;
  return Math.min(max, Math.max(min, Math.floor(parsed)));
}

function asBoolean(value, fallback = false) {
  if (typeof value === 'boolean') return value;
  if (typeof value === 'number') return value !== 0;
  if (typeof value === 'string') {
    const normalized = value.trim().toLowerCase();
    if (['true', '1', 'yes', 'on'].includes(normalized)) return true;
    if (['false', '0', 'no', 'off'].includes(normalized)) return false;
  }
  return fallback;
}

function numberOrUndefined(value) {
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : undefined;
}

function timestampMs(value) {
  const parsed = Date.parse(value);
  return Number.isFinite(parsed) ? parsed : 0;
}

function recordDedupeKey(record) {
  const type = String(record?.type || '');
  const event = String(record?.event || '');
  const command = String(record?.command || '');
  const id = String(record?.id || '');
  if (id) return ['id', type, event, command, id].join('|');
  return [
    'record',
    String(record?.timestamp || ''),
    type,
    event,
    command,
    String(record?.source || ''),
    String(record?.transport || ''),
    String(record?.status || ''),
    payloadDedupeKey(record?.payload),
  ].join('|');
}

function payloadDedupeKey(payload) {
  try {
    return JSON.stringify(payload) || '';
  } catch (_error) {
    return String(payload || '');
  }
}

function toIso(value) {
  return new Date(value).toISOString();
}

module.exports = {
  DEFAULT_MAX_BYTES_PER_FILE,
  DEFAULT_MAX_RECORDS,
  TRAFFIC_EXPORT_GUARDRAILS,
  TRAFFIC_GUARDRAILS,
  collectTrafficSnapshot,
  normalizeEnvelope,
  parseKeyValueResponse,
  redactValue,
  resetTrafficSocketClients,
  writeTrafficTraceExport,
};
