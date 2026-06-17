const fs = require('node:fs');
const path = require('node:path');

const { collectLocalProfileStatus } = require('./observations');
const { collectLogSnapshot } = require('./logs');
const { loadUnifiedRuntimeManifest } = require('./manifest');
const { createServerProfile, publicProfile } = require('./profiles');
const { collectTrafficSnapshot, redactValue } = require('./traffic');

const SNAPSHOT_GUARDRAILS = [
  'explicit-snapshot-write-confirmation-required',
  'bounded-file-reads',
  'bounded-log-tails',
  'redact-secrets-before-display-or-export',
  'write-under-snapshot-root-only',
  'do-not-add-ui-driven-server-probes',
  'do-not-send-bmf-commands',
];

const DEFAULT_MAX_SNAPSHOT_LOG_BYTES = 256 * 1024;
const DEFAULT_MAX_SNAPSHOT_FILES = 32;

function createTroubleshootingSnapshotPlan(input = {}, options = {}) {
  return buildTroubleshootingSnapshot(input, { ...options, dryRun: true });
}

function writeTroubleshootingSnapshot(input = {}, options = {}) {
  if (String(options.confirm || '').toLowerCase() !== 'snapshot') {
    throw new Error('Refusing to write troubleshooting snapshot without --confirm snapshot.');
  }
  return buildTroubleshootingSnapshot(input, { ...options, dryRun: false });
}

function buildTroubleshootingSnapshot(input = {}, options = {}) {
  const profile = normalizeProfile(input.profile || input);
  const root = resolveRoot(options.root || profile.paths?.bmfRoot || profile.root);
  const createdAt = toIso(options.now || new Date());
  const snapshotId = options.snapshotId || makeSnapshotId(profile.id, createdAt);
  const outRoot = path.resolve(options.out || options.outDir || path.join(root, 'artifacts', 'local', 'snapshots', snapshotId));
  const dryRun = options.dryRun !== false;
  const limits = {
    maxLogBytes: boundedInteger(options.maxLogBytes ?? options.maxBytes, DEFAULT_MAX_SNAPSHOT_LOG_BYTES, 4096, 16 * 1024 * 1024),
    maxFiles: boundedInteger(options.maxFiles, DEFAULT_MAX_SNAPSHOT_FILES, 1, 256),
    maxLogLines: boundedInteger(options.maxLogLines ?? options.maxLines, 250, 1, 5000),
    maxTrafficRecords: boundedInteger(options.maxTrafficRecords ?? options.maxRecords, 100, 1, 5000),
  };
  const manifest = safeLoadManifest(root, options.manifest);
  const health = collectSnapshotHealth(profile, {
    root,
    manifest,
    now: options.now,
  });
  const logs = collectLogSnapshot({ profile }, {
    root,
    maxLines: limits.maxLogLines,
    maxBytesPerFile: limits.maxLogBytes,
    maxJournalFiles: options.maxJournalFiles,
    journalRoot: options.journalRoot,
    redactPrivateIps: Boolean(options.redactPrivateIps),
  });
  const traffic = collectTrafficSnapshot({ profile }, {
    root,
    maxRecords: limits.maxTrafficRecords,
    maxBytesPerFile: limits.maxLogBytes,
    maxCommandFiles: options.maxCommandFiles,
    anonymizePlayers: Boolean(options.anonymizePlayers),
    redactPrivateIps: Boolean(options.redactPrivateIps),
  });
  const diagnosticFiles = collectDiagnosticFiles(root, profile, limits.maxFiles);
  const diagnosticLogs = collectDiagnosticLogs(profile, limits.maxFiles);
  const copiedFiles = diagnosticFiles.map(file => copyPlanRecord(outRoot, file, 'files', '.txt'));
  const copiedLogs = diagnosticLogs.map(file => copyPlanRecord(outRoot, file, 'logs', '.tail.log', { mode: 'tail', bytes: limits.maxLogBytes }));
  const doctorReport = options.doctorReport || null;

  const snapshot = {
    schemaVersion: 1,
    feature: 'troubleshooting.snapshot',
    status: dryRun ? 'planned' : 'written',
    dryRun,
    snapshotId,
    createdAt,
    root: outRoot,
    profile: publicProfile(profile),
    summary: {
      healthStatus: health.health.status,
      healthChecks: health.health.checks.length,
      logRecords: logs.summary.retained,
      trafficRecords: traffic.summary.retained,
      copiedFiles: copiedFiles.length,
      copiedLogs: copiedLogs.length,
      doctorStatus: doctorReport?.status || null,
    },
    files: {
      snapshot: path.join(outRoot, 'snapshot.json'),
      profile: path.join(outRoot, 'profile.json'),
      health: path.join(outRoot, 'health.json'),
      logs: path.join(outRoot, 'logs.json'),
      traffic: path.join(outRoot, 'traffic.json'),
      manifest: path.join(outRoot, 'unified-runtime-manifest.json'),
      doctor: doctorReport ? path.join(outRoot, 'doctor.json') : null,
      readme: path.join(outRoot, 'README.txt'),
    },
    copiedFiles,
    copiedLogs,
    limits,
    guardrails: SNAPSHOT_GUARDRAILS,
  };

  if (!dryRun) {
    writeSnapshotFiles(snapshot, {
      profile,
      health,
      logs,
      traffic,
      manifest,
      doctorReport,
      diagnosticFiles,
      diagnosticLogs,
      limits,
    });
  }

  return snapshot;
}

function writeSnapshotFiles(snapshot, data) {
  ensureDir(snapshot.root);
  writeJson(snapshot.files.profile, publicProfile(data.profile));
  writeJson(snapshot.files.health, data.health);
  writeJson(snapshot.files.logs, data.logs);
  writeJson(snapshot.files.traffic, data.traffic);
  if (data.manifest) writeJson(snapshot.files.manifest, data.manifest);
  if (data.doctorReport && snapshot.files.doctor) writeJson(snapshot.files.doctor, data.doctorReport);

  for (let index = 0; index < data.diagnosticFiles.length; index++) {
    const file = data.diagnosticFiles[index];
    const destination = snapshot.copiedFiles[index]?.absoluteSnapshotPath
      || path.join(snapshot.root, 'files', `${safeSnapshotName(file)}.txt`);
    writeRedactedFileCopy(file, destination, data.limits.maxLogBytes, false);
  }
  for (let index = 0; index < data.diagnosticLogs.length; index++) {
    const file = data.diagnosticLogs[index];
    const destination = snapshot.copiedLogs[index]?.absoluteSnapshotPath
      || path.join(snapshot.root, 'logs', `${safeSnapshotName(file)}.tail.log`);
    writeRedactedFileCopy(file, destination, data.limits.maxLogBytes, true);
  }

  writeText(snapshot.files.readme, [
    'BMF troubleshooting snapshot',
    '',
    `Created: ${snapshot.createdAt}`,
    `Profile: ${snapshot.profile.name || snapshot.profile.id}`,
    `Health: ${snapshot.summary.healthStatus}`,
    '',
    'Snapshot files are bounded and redacted before export.',
    'Logs are tailed, not copied in full.',
    'No BMF commands or game-server probes were sent to create this snapshot.',
    '',
  ].join('\n'));
  writeJson(snapshot.files.snapshot, snapshot);
}

function collectDiagnosticFiles(root, profile, maxFiles) {
  const paths = profile.paths || {};
  return uniquePaths([
    path.join(root, 'manifests', 'unified-runtime.json'),
    path.join(root, 'manifests', 'bmf-package.json'),
    path.join(root, 'manifests', 'dependencies.json'),
    path.join(root, 'manifests', 'compatibility.json'),
    path.join(root, 'observability', 'observability-manifest.json'),
    paths.bmfRuntimeDir ? path.join(paths.bmfRuntimeDir, 'status.json') : null,
    paths.bmfRuntimeDir ? path.join(paths.bmfRuntimeDir, 'socket.json') : null,
    paths.bmfRuntimeDir ? path.join(paths.bmfRuntimeDir, 'frame-telemetry.json') : null,
    paths.bmfRuntimeDir ? path.join(paths.bmfRuntimeDir, 'bmf-bridge-status.json') : null,
    paths.omeggaRuntime ? path.join(paths.omeggaRuntime, 'package.json') : null,
    paths.omeggaRuntime ? path.join(paths.omeggaRuntime, 'plugins', 'bmf-bridge', 'plugin.json') : null,
  ]).filter(exists).slice(0, maxFiles);
}

function collectDiagnosticLogs(profile, maxFiles) {
  const paths = profile.paths || {};
  const candidates = [];
  if (paths.bmfRuntimeDir) {
    candidates.push(
      path.join(paths.bmfRuntimeDir, 'events.jsonl'),
      path.join(paths.bmfRuntimeDir, 'audit.jsonl'),
      path.join(paths.bmfRuntimeDir, 'bmf.log'),
    );
  }
  if (paths.omeggaRuntime) {
    candidates.push(
      path.join(paths.omeggaRuntime, 'omegga.log'),
      path.join(paths.omeggaRuntime, 'logs', 'latest.log'),
      path.join(paths.omeggaRuntime, 'logs', 'omegga.log'),
    );
    candidates.push(...scanDirectLogFiles(paths.omeggaRuntime, 16));
  }
  return uniquePaths(candidates).filter(exists).slice(0, maxFiles);
}

function collectSnapshotHealth(profile, options = {}) {
  const manifest = options.manifest?.manifest || options.manifest;
  if (manifest && !manifest.error) {
    try {
      return collectLocalProfileStatus({ profile }, {
        root: options.root,
        manifest,
        now: options.now,
      });
    } catch (error) {
      return fallbackHealth(profile, error, options.now);
    }
  }
  return fallbackHealth(profile, manifest?.error || 'Unified runtime manifest was not available.', options.now);
}

function fallbackHealth(profile, error, now) {
  const message = error?.message || String(error || 'Health collection was unavailable.');
  return {
    schemaVersion: 1,
    collectedAt: toIso(now || new Date()),
    profile: publicProfile(profile),
    health: {
      status: 'unknown',
      summary: {
        healthy: 0,
        degraded: 0,
        unhealthy: 0,
        unknown: 1,
      },
      checks: [
        {
          id: 'unified-runtime-manifest',
          component: 'BMF',
          severity: 'required',
          status: 'unknown',
          healthyWhen: 'Unified runtime manifest is readable.',
          summary: message,
          evidence: [],
          nextAction: 'repair-stack',
        },
      ],
    },
    serviceDiagnostics: null,
    observations: {},
    paths: {},
    logSources: [],
    guardrails: [
      'read-existing-runtime-files-only',
      'bounded-file-reads',
      'redact-secrets-before-display-or-export',
    ],
  };
}

function scanDirectLogFiles(dir, maxFiles) {
  if (!exists(dir)) return [];
  try {
    return fs.readdirSync(dir, { withFileTypes: true })
      .filter(entry => entry.isFile() && entry.name.toLowerCase().endsWith('.log'))
      .slice(0, maxFiles)
      .map(entry => path.join(dir, entry.name));
  } catch {
    return [];
  }
}

function writeRedactedFileCopy(sourcePath, destination, maxBytes, tail) {
  if (!exists(sourcePath)) return;
  const text = tail ? readTailText(sourcePath, maxBytes).text : readHeadText(sourcePath, maxBytes).text;
  const redacted = redactFileText(text);
  ensureDir(path.dirname(destination));
  writeText(destination, redacted);
}

function redactFileText(text) {
  const parsed = safeJsonParse(text);
  if (parsed.ok) return `${JSON.stringify(redactValue(parsed.value).value, null, 2)}\n`;
  return String(redactValue(String(text || '')).value || '');
}

function copyPlanRecord(outRoot, sourcePath, folder, suffix, extra = {}) {
  const relative = path.join(folder, `${safeSnapshotName(sourcePath)}${suffix || ''}`).replace(/\\/g, '/');
  return {
    source: sourcePath,
    snapshotPath: relative,
    absoluteSnapshotPath: path.join(outRoot, relative),
    ...extra,
  };
}

function safeLoadManifest(root, manifestPath) {
  try {
    return loadUnifiedRuntimeManifest({ root, manifest: manifestPath });
  } catch (error) {
    return {
      error: error.message || String(error),
    };
  }
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
  return { text: buffer.toString('utf8'), bytes, truncated: start > 0 };
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
  return { text: buffer.toString('utf8'), bytes, truncated: stat.size > bytes };
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

function safeSnapshotName(label) {
  return String(label || 'file').replace(/^[A-Za-z]:/, '').replace(/[\\/:"*?<>|]+/g, '__');
}

function makeSnapshotId(profileId, createdAt) {
  return `${String(profileId || 'local').replace(/[^A-Za-z0-9_.-]+/g, '-')}-${createdAt.replace(/[:.]/g, '-')}`;
}

function writeJson(filePath, value) {
  writeText(filePath, `${JSON.stringify(value, null, 2)}\n`);
}

function writeText(filePath, text) {
  ensureDir(path.dirname(filePath));
  fs.writeFileSync(filePath, text, 'utf8');
}

function ensureDir(dir) {
  fs.mkdirSync(dir, { recursive: true });
}

function exists(filePath) {
  return Boolean(filePath) && fs.existsSync(filePath);
}

function uniquePaths(items) {
  const seen = new Set();
  const out = [];
  for (const item of items) {
    if (!item) continue;
    const resolved = path.resolve(item);
    const key = resolved.toLowerCase();
    if (seen.has(key)) continue;
    seen.add(key);
    out.push(resolved);
  }
  return out;
}

function safeJsonParse(text) {
  try {
    return { ok: true, value: JSON.parse(text), error: null };
  } catch (error) {
    return { ok: false, value: null, error: error.message || String(error) };
  }
}

function boundedInteger(value, fallback, min, max) {
  const parsed = Number(value);
  if (!Number.isFinite(parsed)) return fallback;
  return Math.min(max, Math.max(min, Math.floor(parsed)));
}

function toIso(value) {
  return new Date(value).toISOString();
}

module.exports = {
  DEFAULT_MAX_SNAPSHOT_FILES,
  DEFAULT_MAX_SNAPSHOT_LOG_BYTES,
  SNAPSHOT_GUARDRAILS,
  createTroubleshootingSnapshotPlan,
  writeTroubleshootingSnapshot,
};
