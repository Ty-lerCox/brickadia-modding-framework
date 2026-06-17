const fs = require('node:fs');
const path = require('node:path');

const { buildLogSources, resolveRuntimePaths } = require('./observations');
const { createServerProfile, publicProfile } = require('./profiles');
const { redactValue } = require('./traffic');

const DEFAULT_MAX_LOG_LINES = 250;
const DEFAULT_MAX_LOG_BYTES_PER_FILE = 512 * 1024;
const DEFAULT_MAX_LOG_SOURCES = 32;
const DEFAULT_MAX_LOG_JOURNALS = 8;
const LOG_SNAPSHOT_GUARDRAILS = [
  'read-existing-log-files-only',
  'bounded-file-reads',
  'bounded-line-retention',
  'bounded-source-count',
  'redact-secrets-before-display-or-export',
  'do-not-add-ui-driven-server-probes',
];

function collectLogSnapshot(input = {}, options = {}) {
  const profile = normalizeProfile(input.profile || input);
  const root = resolveRoot(options.root || profile.paths?.bmfRoot || profile.root);
  const paths = options.paths || resolveRuntimePaths(profile);
  const limits = {
    maxLines: boundedInteger(options.maxLines ?? options.limit, DEFAULT_MAX_LOG_LINES, 1, 5000),
    maxBytesPerFile: boundedInteger(options.maxBytesPerFile ?? options.maxBytes, DEFAULT_MAX_LOG_BYTES_PER_FILE, 4096, 16 * 1024 * 1024),
    maxSources: boundedInteger(options.maxSources, DEFAULT_MAX_LOG_SOURCES, 1, 256),
    maxJournalFiles: boundedInteger(options.maxJournalFiles, DEFAULT_MAX_LOG_JOURNALS, 0, 100),
  };
  const state = {
    records: [],
    sourceDiagnostics: [],
    redactions: 0,
    parseErrors: 0,
    droppedRecords: 0,
  };

  const sources = buildSnapshotSources(profile, paths, root, options, limits).slice(0, limits.maxSources);
  sources.forEach((source, index) => readLogSource(state, source, {
    ...limits,
    sourceIndex: index,
    redactPrivateIps: Boolean(options.redactPrivateIps),
  }));

  const sorted = state.records
    .map((record, index) => ({ record, index }))
    .sort((left, right) => {
      const leftTime = timestampMs(left.record.timestamp);
      const rightTime = timestampMs(right.record.timestamp);
      if (leftTime !== rightTime) return leftTime - rightTime;
      if (left.record.sourceIndex !== right.record.sourceIndex) return left.record.sourceIndex - right.record.sourceIndex;
      return left.index - right.index;
    })
    .map(item => {
      const clone = { ...item.record };
      delete clone.sourceIndex;
      return clone;
    });
  const retained = sorted.slice(-limits.maxLines);
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
      existingSources: state.sourceDiagnostics.filter(source => source.exists).length,
      parseErrors: state.parseErrors,
      redactions: state.redactions,
      truncatedSources: state.sourceDiagnostics.filter(source => source.truncated).length,
    },
    sources: state.sourceDiagnostics,
    paths: {
      runtimeDir: paths.runtimeDir || null,
      omeggaRuntime: paths.omeggaRuntime || null,
      journalRoot: options.journalRoot ? path.resolve(options.journalRoot) : path.join(root, 'artifacts', 'local', 'transactions'),
    },
    limits,
    guardrails: LOG_SNAPSHOT_GUARDRAILS,
  };
}

function buildSnapshotSources(profile, paths, root, options, limits) {
  const sources = buildLogSources(paths)
    .filter(source => !['alloy-config'].includes(source.id))
    .map(source => ({
      id: source.id,
      component: source.component,
      path: source.path,
      kind: source.id.endsWith('jsonl') ? 'jsonl' : source.id.endsWith('status') || source.id.includes('telemetry') ? 'json' : 'text',
    }));

  if (paths.omeggaRuntime) {
    const omeggaRoot = path.resolve(paths.omeggaRuntime);
    sources.push(
      logSource('omegga-log', 'omegga-runtime', path.join(omeggaRoot, 'omegga.log'), 'text'),
      logSource('omegga-latest-log', 'omegga-runtime', path.join(omeggaRoot, 'logs', 'latest.log'), 'text'),
      logSource('omegga-session-log', 'omegga-runtime', path.join(omeggaRoot, 'logs', 'omegga.log'), 'text'),
    );
  }

  const journalRoot = path.resolve(options.journalRoot || path.join(root, 'artifacts', 'local', 'transactions'));
  sources.push(...recentJournalSources(journalRoot, limits.maxJournalFiles));

  return dedupeSources(sources);
}

function readLogSource(state, source, options) {
  const diagnostic = {
    id: source.id,
    component: source.component,
    path: source.path || null,
    kind: source.kind,
    exists: false,
    bytes: 0,
    lines: 0,
    parseErrors: 0,
    redactions: 0,
    truncated: false,
    mtime: null,
    error: null,
  };
  state.sourceDiagnostics.push(diagnostic);
  if (!source.path || !fs.existsSync(source.path)) return;

  try {
    const stat = fs.statSync(source.path);
    const result = source.kind === 'json' || source.kind === 'journal'
      ? readHeadText(source.path, options.maxBytesPerFile)
      : readTailText(source.path, options.maxBytesPerFile);
    diagnostic.exists = true;
    diagnostic.bytes = result.bytes;
    diagnostic.truncated = result.truncated;
    diagnostic.mtime = stat.mtime.toISOString();

    if (source.kind === 'json') {
      readJsonDocument(state, diagnostic, source, result.text, {
        ...options,
        observedAt: diagnostic.mtime,
      });
      return;
    }

    if (source.kind === 'journal') {
      readJournalDocument(state, diagnostic, source, result.text, {
        ...options,
        observedAt: diagnostic.mtime,
      });
      return;
    }

    const lines = splitLines(result.text, result.truncated);
    lines.forEach((line, index) => {
      if (source.kind === 'jsonl') {
        readJsonLine(state, diagnostic, source, line, {
          ...options,
          lineNumber: index + 1,
          observedAt: diagnostic.mtime,
        });
      } else {
        addRecord(state, diagnostic, normalizePlainLogLine(line, source, {
          ...options,
          lineNumber: index + 1,
          observedAt: diagnostic.mtime,
        }));
      }
    });
  } catch (error) {
    diagnostic.error = error.message || String(error);
  }
}

function readJsonDocument(state, diagnostic, source, text, options) {
  const parsed = safeJsonParse(text);
  if (!parsed.ok) {
    noteParseError(state, diagnostic);
    return;
  }
  addRecord(state, diagnostic, normalizeJsonLogRecord(parsed.value, source, {
    ...options,
    lineNumber: 1,
  }));
}

function readJournalDocument(state, diagnostic, source, text, options) {
  const parsed = safeJsonParse(text);
  if (!parsed.ok) {
    noteParseError(state, diagnostic);
    return;
  }
  const value = parsed.value || {};
  const summary = value.summary || {};
  const message = [
    value.rollbackId ? `rollback=${value.rollbackId}` : `transaction=${value.transactionId || source.id}`,
    value.operationId ? `operation=${value.operationId}` : null,
    value.status ? `status=${value.status}` : null,
    summary.ready !== undefined ? `ready=${summary.ready}` : null,
    summary.blocked !== undefined ? `blocked=${summary.blocked}` : null,
    Array.isArray(value.errors) && value.errors.length ? `errors=${value.errors.length}` : null,
  ].filter(Boolean).join(' ');
  addRecord(state, diagnostic, normalizeJsonLogRecord({
    ts: value.finishedAt || value.createdAt || options.observedAt,
    level: value.status === 'failed' ? 'error' : 'info',
    source: source.id,
    message,
    data: {
      transactionId: value.transactionId,
      rollbackId: value.rollbackId,
      operationId: value.operationId,
      status: value.status,
      summary,
      errors: value.errors || [],
    },
  }, source, {
    ...options,
    lineNumber: 1,
  }));
}

function readJsonLine(state, diagnostic, source, line, options) {
  const parsed = safeJsonParse(line);
  if (!parsed.ok) {
    noteParseError(state, diagnostic);
    addRecord(state, diagnostic, normalizePlainLogLine(line, source, options));
    return;
  }
  addRecord(state, diagnostic, normalizeJsonLogRecord(parsed.value, source, options));
}

function normalizePlainLogLine(line, source, options) {
  const redacted = redactValue(line, {
    redactPrivateIps: options.redactPrivateIps,
  });
  return {
    id: `${source.id}:${options.lineNumber || 0}`,
    timestamp: extractTimestamp(redacted.value) || options.observedAt || toIso(new Date()),
    sourceId: source.id,
    component: source.component,
    severity: inferSeverity(redacted.value),
    message: String(redacted.value || ''),
    lineNumber: options.lineNumber || null,
    redactions: redacted.redactions,
    sourceIndex: options.sourceIndex,
  };
}

function normalizeJsonLogRecord(value, source, options) {
  const record = value && typeof value === 'object' ? value : { message: String(value || '') };
  const redacted = redactValue(record, {
    redactPrivateIps: options.redactPrivateIps,
  });
  const payload = redacted.value;
  const message = String(
    payload.message ||
    payload.detail ||
    payload.action ||
    payload.event ||
    payload.status ||
    payload.state ||
    source.id,
  );
  return {
    id: String(payload.id || `${source.id}:${options.lineNumber || 0}`),
    timestamp: String(payload.ts || payload.timestamp || payload.updatedAt || payload.finishedAt || payload.createdAt || options.observedAt || toIso(new Date())),
    sourceId: source.id,
    component: source.component,
    severity: inferSeverity(payload.level || payload.severity || payload.status || message),
    message,
    lineNumber: options.lineNumber || null,
    payload,
    redactions: redacted.redactions,
    sourceIndex: options.sourceIndex,
  };
}

function addRecord(state, diagnostic, record) {
  diagnostic.lines += 1;
  diagnostic.redactions += boundedInteger(record.redactions, 0, 0, 1000000);
  state.redactions += boundedInteger(record.redactions, 0, 0, 1000000);
  state.records.push(record);
}

function noteParseError(state, diagnostic) {
  diagnostic.parseErrors += 1;
  state.parseErrors += 1;
}

function recentJournalSources(journalRoot, maxFiles) {
  if (maxFiles <= 0 || !fs.existsSync(journalRoot)) return [];
  try {
    return fs.readdirSync(journalRoot, { withFileTypes: true })
      .filter(entry => entry.isFile() && entry.name.toLowerCase().endsWith('.json'))
      .map(entry => {
        const filePath = path.join(journalRoot, entry.name);
        const stat = fs.statSync(filePath);
        return { filePath, name: entry.name, mtimeMs: stat.mtimeMs };
      })
      .sort((left, right) => right.mtimeMs - left.mtimeMs)
      .slice(0, maxFiles)
      .sort((left, right) => left.mtimeMs - right.mtimeMs)
      .map(entry => logSource(`transaction-journal:${entry.name}`, 'orchestrator-core', entry.filePath, 'journal'));
  } catch {
    return [];
  }
}

function logSource(id, component, filePath, kind) {
  return { id, component, path: filePath, kind };
}

function dedupeSources(sources) {
  const seen = new Set();
  const out = [];
  for (const source of sources) {
    const key = `${source.id}\0${source.path || ''}`.toLowerCase();
    if (seen.has(key)) continue;
    seen.add(key);
    out.push(source);
  }
  return out;
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

function splitLines(text, truncated) {
  const lines = String(text || '').split(/\r?\n/);
  if (truncated && lines.length > 0) lines.shift();
  return lines.map(line => line.trimEnd()).filter(Boolean);
}

function safeJsonParse(text) {
  try {
    return { ok: true, value: JSON.parse(text), error: null };
  } catch (error) {
    return { ok: false, value: null, error: error.message || String(error) };
  }
}

function normalizeProfile(input = {}) {
  if (input && input.schemaVersion === 1 && input.id && input.ports && input.paths && input.telemetry) {
    return input;
  }
  return createServerProfile(input);
}

function resolveRoot(root) {
  return path.resolve(root || path.join(__dirname, '..', '..', '..'));
}

function inferSeverity(value) {
  const text = String(value || '').toLowerCase();
  if (/\b(error|failed|fatal|panic|exception|critical|crash)\b/.test(text)) return 'error';
  if (/\b(warn|warning|degraded|retry|timeout)\b/.test(text)) return 'warning';
  if (/\b(debug|trace)\b/.test(text)) return 'debug';
  return 'info';
}

function extractTimestamp(value) {
  const match = String(value || '').match(/\b\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z\b/);
  return match ? match[0] : null;
}

function boundedInteger(value, fallback, min, max) {
  const parsed = Number(value);
  if (!Number.isFinite(parsed)) return fallback;
  return Math.min(max, Math.max(min, Math.floor(parsed)));
}

function timestampMs(value) {
  const parsed = Date.parse(value);
  return Number.isFinite(parsed) ? parsed : 0;
}

function toIso(value) {
  return new Date(value).toISOString();
}

module.exports = {
  DEFAULT_MAX_LOG_BYTES_PER_FILE,
  DEFAULT_MAX_LOG_JOURNALS,
  DEFAULT_MAX_LOG_LINES,
  DEFAULT_MAX_LOG_SOURCES,
  LOG_SNAPSHOT_GUARDRAILS,
  collectLogSnapshot,
};
