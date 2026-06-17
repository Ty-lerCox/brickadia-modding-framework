const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');

const { createServerProfile, publicProfile } = require('./profiles');
const { resolveRuntimePaths } = require('./observations');

const DEFAULT_MAX_RECORDS = 100;
const DEFAULT_MAX_BYTES_PER_FILE = 512 * 1024;
const DEFAULT_MAX_COMMAND_FILES = 50;
const TRAFFIC_GUARDRAILS = [
  'observe-existing-traffic-only',
  'bounded-file-reads',
  'bounded-record-retention',
  'bounded-command-file-sampling',
  'redact-secrets-before-display-or-export',
  'do-not-add-ui-driven-server-probes',
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
    maxCommandFiles: boundedInteger(options.maxCommandFiles, DEFAULT_MAX_COMMAND_FILES, 1, 500),
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

  readJsonlSource(state, 'events-jsonl', paths.eventsJsonl, {
    ...redactionOptions,
    maxBytes: limits.maxBytesPerFile,
    kind: 'event-log',
    transport: 'jsonl',
    source: 'bmf-runtime',
  });
  readJsonlSource(state, 'audit-jsonl', paths.auditJsonl, {
    ...redactionOptions,
    maxBytes: limits.maxBytesPerFile,
    kind: 'audit-log',
    transport: 'audit-jsonl',
    source: 'bmf-audit',
  });
  readJsonStatusSource(state, 'bmf-bridge-status', paths.bridgeStatus, {
    ...redactionOptions,
    maxBytes: limits.maxBytesPerFile,
    source: 'omegga.bmf-bridge',
    transport: 'bridge-status',
  });
  readJsonStatusSource(state, 'socket-metadata', paths.socketMetadata, {
    ...redactionOptions,
    maxBytes: limits.maxBytesPerFile,
    source: 'bmf-socket',
    transport: 'socket-metadata',
  });
  readCommandSources(state, paths.commandDir, {
    ...redactionOptions,
    maxFiles: limits.maxCommandFiles,
    maxBytes: Math.min(limits.maxBytesPerFile, 64 * 1024),
  });

  const sorted = state.records
    .map((record, index) => ({ record, index }))
    .sort((left, right) => {
      const leftTime = timestampMs(left.record.timestamp);
      const rightTime = timestampMs(right.record.timestamp);
      if (leftTime !== rightTime) return leftTime - rightTime;
      return left.index - right.index;
    })
    .map(item => item.record);
  const retained = sorted.slice(-limits.maxRecords);
  state.droppedRecords += Math.max(0, sorted.length - retained.length);

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
      eventsJsonl: paths.eventsJsonl || null,
      auditJsonl: paths.auditJsonl || null,
      commandDir: paths.commandDir || null,
      socketMetadata: paths.socketMetadata || null,
      bridgeStatus: paths.bridgeStatus || null,
    },
    limits,
    guardrails: TRAFFIC_GUARDRAILS,
  };
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

function readJsonlSource(state, id, filePath, options) {
  const diagnostic = sourceDiagnostic(id, filePath);
  state.sourceDiagnostics.push(diagnostic);
  if (!filePath || !fs.existsSync(filePath)) return;

  try {
    const result = readTailText(filePath, options.maxBytes);
    diagnostic.exists = true;
    diagnostic.bytes = result.bytes;
    diagnostic.truncated = result.truncated;
    diagnostic.mtime = fs.statSync(filePath).mtime.toISOString();

    const lines = splitJsonl(result.text, result.truncated);
    for (const line of lines) {
      const parsed = safeJsonParse(line);
      if (!parsed.ok) {
        diagnostic.parseErrors += 1;
        state.parseErrors += 1;
        continue;
      }
      const envelope = normalizeEnvelope(parsed.value, {
        ...options,
        observedAt: diagnostic.mtime,
      });
      addRecord(state, diagnostic, envelope, options);
    }
  } catch (error) {
    diagnostic.error = error.message || String(error);
  }
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
    addRecord(state, diagnostic, normalizeEnvelope(parsed.value, {
      kind: 'status',
      source: options.source,
      transport: options.transport,
      observedAt: diagnostic.mtime,
    }), options);
  } catch (error) {
    diagnostic.error = error.message || String(error);
  }
}

function readCommandSources(state, commandDir, options) {
  const diagnostic = sourceDiagnostic('command-files', commandDir);
  state.sourceDiagnostics.push(diagnostic);
  if (!commandDir || !fs.existsSync(commandDir)) return;

  try {
    const entries = fs.readdirSync(commandDir, { withFileTypes: true })
      .filter(entry => entry.isFile())
      .filter(entry => /\.(request|response)\.(txt|json)$/i.test(entry.name))
      .map(entry => {
        const filePath = path.join(commandDir, entry.name);
        const stat = fs.statSync(filePath);
        return { filePath, name: entry.name, mtimeMs: stat.mtimeMs, mtime: stat.mtime.toISOString(), bytes: stat.size };
      })
      .sort((left, right) => right.mtimeMs - left.mtimeMs)
      .slice(0, options.maxFiles)
      .sort((left, right) => left.mtimeMs - right.mtimeMs);

    diagnostic.exists = true;
    diagnostic.bytes = entries.reduce((total, entry) => total + entry.bytes, 0);
    diagnostic.truncated = entries.length >= options.maxFiles;

    for (const entry of entries) {
      const result = readHeadText(entry.filePath, options.maxBytes);
      const envelope = normalizeCommandFile(entry, result.text, {
        anonymizePlayers: options.anonymizePlayers,
        redactPrivateIps: options.redactPrivateIps,
        truncated: result.truncated,
      });
      addRecord(state, diagnostic, envelope, {
        source: 'bmf-command-files',
        transport: envelope.transport,
      });
    }
  } catch (error) {
    diagnostic.error = error.message || String(error);
  }
}

function normalizeCommandFile(entry, text, options = {}) {
  const match = entry.name.match(/^(.*)\.(request|response)\.(txt|json)$/i);
  const id = match ? match[1] : path.basename(entry.name);
  const kind = match ? match[2].toLowerCase() : 'request';
  if (kind === 'request') {
    const commandText = String(text || '').trim();
    return compactObject(normalizeCommandRecord({
      id,
      ts: entry.mtime,
      command: commandText,
      source: 'omegga.bmf-bridge',
      status: 'pending',
    }, {
      transport: 'file-command',
      file: entry.name,
      truncated: options.truncated,
    }));
  }

  const payload = entry.name.toLowerCase().endsWith('.json')
    ? parseJsonPayload(text)
    : parseKeyValueResponse(text);
  return compactObject(normalizeResponseRecord({
    id,
    ts: entry.mtime,
    source: 'bmf',
    ok: payload.ok,
    detail: payload.detail,
    command: payload.command,
    response: payload,
  }, {
    transport: 'file-command',
    file: entry.name,
    truncated: options.truncated,
    durationMs: payload.durationMs,
  }));
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
    transport: options.transport || 'audit-jsonl',
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
    status: String(message.status || (socketConnected === false ? 'fallback' : 'ok')),
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

function parseJsonPayload(text) {
  const parsed = safeJsonParse(text);
  if (!parsed.ok || !parsed.value || typeof parsed.value !== 'object') {
    return { ok: false, detail: parsed.error || 'invalid JSON', command: '', raw: String(text || '') };
  }
  return parsed.value;
}

function readTailText(filePath, maxBytes) {
  const stat = fs.statSync(filePath);
  const bytes = Math.min(stat.size, maxBytes);
  const start = Math.max(0, stat.size - bytes);
  const buffer = Buffer.alloc(bytes);
  const fd = fs.openSync(filePath, 'r');
  try {
    fs.readSync(fd, buffer, 0, bytes, start);
  } finally {
    fs.closeSync(fd);
  }
  return {
    text: buffer.toString('utf8'),
    bytes,
    truncated: start > 0,
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

function splitJsonl(text, truncated) {
  const lines = String(text || '').split(/\r?\n/);
  if (truncated && lines.length > 0) lines.shift();
  return lines.map(line => line.trim()).filter(Boolean);
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

function numberOrUndefined(value) {
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : undefined;
}

function timestampMs(value) {
  const parsed = Date.parse(value);
  return Number.isFinite(parsed) ? parsed : 0;
}

function toIso(value) {
  return new Date(value).toISOString();
}

module.exports = {
  DEFAULT_MAX_BYTES_PER_FILE,
  DEFAULT_MAX_COMMAND_FILES,
  DEFAULT_MAX_RECORDS,
  TRAFFIC_EXPORT_GUARDRAILS,
  TRAFFIC_GUARDRAILS,
  collectTrafficSnapshot,
  normalizeEnvelope,
  parseKeyValueResponse,
  redactValue,
  writeTrafficTraceExport,
};
