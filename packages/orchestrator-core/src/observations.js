const fs = require('node:fs');
const http = require('node:http');
const net = require('node:net');
const path = require('node:path');

const { buildServiceHealth } = require('./health');
const { loadUnifiedRuntimeManifest } = require('./manifest');
const { createServerProfile, publicProfile } = require('./profiles');
const { buildServiceDiagnostics } = require('./services');

const DEFAULT_FRESHNESS_MS = {
  bmfStatus: 30_000,
  socketMetadata: 30_000,
  frameTelemetry: 30_000,
  bridgeStatus: 30_000,
};

function collectLocalProfileStatus(input = {}, options = {}) {
  const manifest = options.manifest || loadUnifiedRuntimeManifest(options).manifest;
  const profile = normalizeProfile(input.profile || input);
  const paths = resolveRuntimePaths(profile);
  const serviceDiagnostics = buildServiceDiagnostics(profile, {
    portInspection: options.portInspection,
  });
  const observations = collectLocalObservations(profile, paths, {
    ...options,
    serviceDiagnostics,
  });
  const health = buildServiceHealth(manifest, observations);

  return {
    schemaVersion: 1,
    collectedAt: toIso(options.now || new Date()),
    profile: publicProfile(profile),
    health,
    serviceDiagnostics,
    observations,
    paths,
    logSources: buildLogSources(paths),
    guardrails: [
      'read-existing-runtime-files-only',
      'bounded-file-reads',
      'bounded-local-port-inspection',
      'loopback-health-check-timeouts',
      'redact-secrets-before-display-or-export',
    ],
  };
}

function normalizeProfile(input = {}) {
  if (input && input.schemaVersion === 1 && input.id && input.ports && input.paths && input.telemetry) {
    return input;
  }
  return createServerProfile(input);
}

function resolveRuntimePaths(profile) {
  const brickadiaWin64 = profile.paths?.brickadiaWin64
    ? path.resolve(profile.paths.brickadiaWin64)
    : null;
  const runtimeDir = profile.paths?.bmfRuntimeDir
    ? path.resolve(profile.paths.bmfRuntimeDir)
    : brickadiaWin64
      ? path.join(brickadiaWin64, 'ue4ss', 'main', 'Mods', 'BMF', 'runtime')
      : null;
  const bmfModDir = runtimeDir ? path.dirname(runtimeDir) : null;
  const modsDir = bmfModDir ? path.dirname(bmfModDir) : null;

  return {
    brickadiaWin64,
    brickadiaExe: brickadiaWin64 ? path.join(brickadiaWin64, 'BrickadiaServer-Win64-Shipping.exe') : null,
    omeggaRuntime: profile.paths?.omeggaRuntime ? path.resolve(profile.paths.omeggaRuntime) : null,
    ue4ssDwmapi: brickadiaWin64 ? path.join(brickadiaWin64, 'dwmapi.dll') : null,
    ue4ssModsDir: modsDir,
    bmfModDir,
    bmfEnabled: bmfModDir ? path.join(bmfModDir, 'enabled.txt') : null,
    runtimeDir,
    bmfStatus: runtimeDir ? path.join(runtimeDir, 'status.json') : null,
    bmfTelemetry: runtimeDir ? path.join(runtimeDir, 'telemetry.json') : null,
    frameTelemetry: runtimeDir ? path.join(runtimeDir, 'frame-telemetry.json') : null,
    eventsJsonl: runtimeDir ? path.join(runtimeDir, 'events.jsonl') : null,
    auditJsonl: runtimeDir ? path.join(runtimeDir, 'audit.jsonl') : null,
    bmfLog: runtimeDir ? path.join(runtimeDir, 'bmf.log') : null,
    commandDir: runtimeDir ? path.join(runtimeDir, 'commands') : null,
    socketMetadata: runtimeDir ? path.join(runtimeDir, 'socket.json') : null,
    bridgeStatus: runtimeDir ? path.join(runtimeDir, 'bmf-bridge-status.json') : null,
    grafanaAlloyConfig: profile.paths?.grafanaAlloyConfig
      ? path.resolve(profile.paths.grafanaAlloyConfig)
      : null,
    omeggaMetricsUrl: `http://127.0.0.1:${profile.ports.omeggaWeb}/metrics`,
    alloyReadyUrl: `http://127.0.0.1:${profile.ports.alloyReady}/-/ready`,
  };
}

function collectLocalObservations(profile, paths, options = {}) {
  const nowMs = toTimeMs(options.now || new Date());
  const freshness = {
    ...DEFAULT_FRESHNESS_MS,
    ...(options.freshnessMs || {}),
  };
  const bmfStatus = readJson(paths.bmfStatus);
  const socketMetadata = readJson(paths.socketMetadata);
  const bridgeStatus = readJson(paths.bridgeStatus);

  return {
    'brickadia-files': observeBrickadiaFiles(paths),
    'omegga-running': observeOmeggaRuntime(paths, {
      metricsProbe: options.metricsProbe,
      serviceDiagnostics: options.serviceDiagnostics,
    }),
    'ue4ss-enabled': observeUe4ss(paths),
    'bmf-status-fresh': observeFreshJsonFile(paths.bmfStatus, {
      nowMs,
      maxAgeMs: freshness.bmfStatus,
      healthySummary: 'BMF status file is fresh.',
      missingSummary: 'BMF runtime status file was not found.',
      staleSummary: 'BMF runtime status file is stale.',
      nextAction: 'start-stack',
      details: bmfStatus.value ? {
        version: bmfStatus.value.version,
        serverReady: bmfStatus.value.server_ready,
        commandWorker: bmfStatus.value.command_worker_mode,
      } : null,
    }),
    'bmf-socket-connected': observeBmfSocket(paths, bmfStatus.value, socketMetadata.value, bridgeStatus.value, {
      nowMs,
      maxAgeMs: freshness.socketMetadata,
    }),
    'frame-telemetry-fresh': observeFrameTelemetry(profile, paths, {
      nowMs,
      maxAgeMs: freshness.frameTelemetry,
    }),
    'metrics-endpoint': observeLoopbackEndpoint(paths.omeggaMetricsUrl, options.metricsProbe, {
      disabledSummary: 'Omegga metrics endpoint was not probed in this health pass.',
      nextAction: 'start-stack',
    }),
    'alloy-ready': observeAlloy(profile, paths, options.alloyProbe),
    'dashboard-imported': observeDashboard(profile),
  };
}

function observeBrickadiaFiles(paths) {
  if (!paths.brickadiaWin64) return unknown('Brickadia Win64 path is not configured.', [], 'install-stack');
  if (!exists(paths.brickadiaExe)) {
    return unhealthy('Brickadia dedicated server binary is missing.', [paths.brickadiaExe], 'install-stack');
  }
  return healthy('Brickadia dedicated server binary exists.', [paths.brickadiaExe]);
}

function observeOmeggaRuntime(paths, options = {}) {
  if (!paths.omeggaRuntime) return unknown('Omegga runtime path is not configured.', [], 'install-stack');
  if (!exists(paths.omeggaRuntime)) {
    return unhealthy('BMF-compatible Omegga runtime path is missing.', [paths.omeggaRuntime], 'install-stack');
  }
  if (options.metricsProbe?.ok) {
    return healthy('Omegga metrics endpoint responded; runtime appears running.', [
      paths.omeggaRuntime,
      paths.omeggaMetricsUrl,
    ]);
  }
  return {
    status: 'unknown',
    summary: 'Omegga runtime path exists; process ownership has not been inspected yet.',
    evidence: [paths.omeggaRuntime],
    nextAction: 'start-stack',
  };
}

function observeUe4ss(paths) {
  if (!paths.brickadiaWin64) return unknown('Brickadia Win64 path is not configured.', [], 'install-stack');
  const required = [paths.ue4ssDwmapi, paths.ue4ssModsDir, paths.bmfModDir, paths.bmfEnabled];
  const missing = required.filter(item => !exists(item));
  if (missing.length > 0) return unhealthy('UE4SS/BMF files are not fully staged.', missing, 'repair-stack');
  return healthy('UE4SS and BMF mod enablement files are staged.', required);
}

function observeBmfSocket(paths, bmfStatus, socketMetadata, bridgeStatus, options) {
  const evidence = compact([
    paths.socketMetadata,
    paths.bridgeStatus && exists(paths.bridgeStatus) ? paths.bridgeStatus : null,
  ]);
  if (!paths.socketMetadata || !exists(paths.socketMetadata)) {
    return degraded('BMF socket metadata is not available.', evidence, 'start-stack');
  }
  const freshness = freshnessStatus(paths.socketMetadata, options);
  if (!freshness.fresh) return degraded('BMF socket metadata is stale.', evidence, 'restart-stack');

  const socketEnabled = asBoolean(socketMetadata?.enabled, false);
  const hasBrokerConfig = socketMetadata?.host && Number(socketMetadata?.port) > 0 && socketMetadata?.token;
  const bmfWorkerStarted = asBoolean(bmfStatus?.socket_worker_started, false);
  const bridgeConnected = asBoolean(bridgeStatus?.socket?.connected, false);
  const nativeStatus = socketNativeStatus(socketMetadata);
  const nativeConnected = socketNativeConnected(socketMetadata, nativeStatus);
  const nativeRunning = nativeConnected || asBoolean(socketMetadata?.started, false) || asBoolean(nativeStatus?.running, false);
  const observedActivity = socketActivityObserved(socketMetadata, nativeStatus);
  const lastError = String(socketMetadata?.lastError || nativeStatus?.lastError || '').trim();
  if (socketEnabled && hasBrokerConfig && bmfWorkerStarted && nativeRunning && !lastError) {
    if (nativeConnected) return healthy('BMF native socket client reports an active loopback broker connection.', evidence);
    if (observedActivity) return healthy('BMF socket worker is fresh and has processed socket traffic without reported errors.', evidence);
    return healthy('BMF socket worker is running with fresh metadata and no reported socket errors.', evidence);
  }
  if (socketEnabled && hasBrokerConfig && bridgeConnected && !nativeConnected) {
    return degraded('BMF bridge is connected, but the native socket client is not connected to the broker.', evidence, 'restart-stack');
  }
  if (socketEnabled && hasBrokerConfig && bmfWorkerStarted) {
    return degraded(lastError ? `BMF socket worker reported an error: ${lastError}` : 'BMF socket worker is running, but no socket activity has been reported.', evidence, 'restart-stack');
  }
  return degraded('BMF socket metadata exists, but a connected worker has not been reported.', evidence, 'start-stack');
}

function socketNativeConnected(socketMetadata, nativeStatus = socketNativeStatus(socketMetadata)) {
  if (asBoolean(socketMetadata?.connected, false)) return true;
  if (asBoolean(socketMetadata?.nativeConnected, false)) return true;
  return asBoolean(nativeStatus?.connected, false);
}

function socketNativeStatus(socketMetadata) {
  const lastStatus = socketMetadata?.lastStatus;
  if (!lastStatus) return {};
  if (typeof lastStatus === 'object') return lastStatus;
  if (typeof lastStatus !== 'string') return {};
  try {
    return JSON.parse(lastStatus);
  } catch {
    return {};
  }
}

function socketActivityObserved(socketMetadata, nativeStatus = socketNativeStatus(socketMetadata)) {
  return [
    socketMetadata?.receivedCommands,
    socketMetadata?.receivedMessages,
    socketMetadata?.sentEvents,
    socketMetadata?.sentResponses,
    nativeStatus?.sentLines,
    nativeStatus?.receivedLines,
    nativeStatus?.connects,
  ].some(value => Number(value) > 0);
}

function observeFrameTelemetry(profile, paths, options) {
  if (!asBoolean(profile.telemetry?.frameTelemetryEnabled, false)) {
    return degraded('Frame telemetry is disabled for this profile.', [], null);
  }
  return observeFreshJsonFile(paths.frameTelemetry, {
    ...options,
    healthySummary: 'BMF frame telemetry file is fresh.',
    missingSummary: 'BMF frame telemetry file was not found.',
    staleSummary: 'BMF frame telemetry file is stale.',
    nextAction: 'configure-telemetry',
  });
}

function observeAlloy(profile, paths, probe) {
  if (!asBoolean(profile.telemetry?.enabled, false)) return degraded('Grafana telemetry is disabled for this profile.');
  const evidence = compact([paths.grafanaAlloyConfig, paths.alloyReadyUrl]);
  if (paths.grafanaAlloyConfig && !exists(paths.grafanaAlloyConfig)) {
    return degraded('Grafana Alloy config path is configured but missing.', evidence, 'configure-telemetry');
  }
  return observeLoopbackEndpoint(paths.alloyReadyUrl, probe, {
    disabledSummary: 'Grafana Alloy readiness endpoint was not probed in this health pass.',
    evidence,
    nextAction: 'configure-telemetry',
  });
}

function observeDashboard(profile) {
  if (!asBoolean(profile.telemetry?.enabled, false)) return degraded('Grafana telemetry is disabled for this profile.');
  const url = String(profile.telemetry?.dashboardUrl || '').trim();
  if (!url) return degraded('Grafana dashboard URL is not stored on this profile.', [], 'configure-telemetry');
  return healthy('Grafana dashboard URL is stored on this profile.', [redactUrl(url)]);
}

function observeFreshJsonFile(filePath, options) {
  if (!filePath) return unknown(options.missingSummary, [], options.nextAction);
  if (!exists(filePath)) return unhealthy(options.missingSummary, [filePath], options.nextAction);
  const fresh = freshnessStatus(filePath, options);
  if (!fresh.fresh) return unhealthy(`${options.staleSummary} ageMs=${fresh.ageMs}`, [filePath], options.nextAction);
  const parsed = readJson(filePath);
  if (!parsed.ok) return unhealthy(`Could not parse ${path.basename(filePath)}: ${parsed.error}`, [filePath], options.nextAction);
  return {
    status: 'healthy',
    summary: options.healthySummary,
    evidence: [filePath],
    nextAction: null,
    details: options.details || null,
  };
}

function observeLoopbackEndpoint(url, probe, options) {
  const evidence = compact([...(options.evidence || []), url]);
  if (!probe) {
    return {
      status: 'unknown',
      summary: options.disabledSummary,
      evidence,
      nextAction: options.nextAction || null,
    };
  }
  if (probe.ok) return healthy(`Loopback endpoint responded with HTTP ${probe.statusCode || 200}.`, evidence);
  return degraded(`Loopback endpoint did not respond cleanly: ${probe.error || 'unavailable'}`, evidence, options.nextAction);
}

function buildLogSources(paths) {
  const sources = [
    logSource('bmf-log', 'bmf-runtime', paths.bmfLog),
    logSource('bmf-status', 'bmf-runtime', paths.bmfStatus),
    logSource('bmf-bridge-status', 'omegga-plugin-bmf-bridge', paths.bridgeStatus),
    logSource('frame-telemetry', 'bmf-frame-telemetry', paths.frameTelemetry),
    logSource('alloy-config', 'grafana-alloy', paths.grafanaAlloyConfig),
  ];
  if (exists(paths.eventsJsonl)) sources.push(logSource('events-jsonl', 'bmf-runtime', paths.eventsJsonl));
  if (exists(paths.auditJsonl)) sources.push(logSource('audit-jsonl', 'bmf-runtime', paths.auditJsonl));
  return sources.filter(item => item.path);
}

function logSource(id, component, filePath) {
  return {
    id,
    component,
    path: filePath,
    exists: exists(filePath),
  };
}

function freshnessStatus(filePath, options) {
  const stat = fs.statSync(filePath);
  const ageMs = Math.max(0, Math.round((options.nowMs || Date.now()) - stat.mtimeMs));
  return {
    ageMs,
    fresh: ageMs <= Math.max(0, Number(options.maxAgeMs) || 0),
  };
}

function readJson(filePath) {
  if (!filePath || !exists(filePath)) return { ok: false, value: null, error: 'missing' };
  try {
    return {
      ok: true,
      value: JSON.parse(fs.readFileSync(filePath, 'utf8')),
      error: null,
    };
  } catch (error) {
    return {
      ok: false,
      value: null,
      error: error.message || String(error),
    };
  }
}

function exists(filePath) {
  return !!(filePath && fs.existsSync(filePath));
}

function healthy(summary, evidence = []) {
  return { status: 'healthy', summary, evidence: compact(evidence), nextAction: null };
}

function degraded(summary, evidence = [], nextAction = null) {
  return { status: 'degraded', summary, evidence: compact(evidence), nextAction };
}

function unhealthy(summary, evidence = [], nextAction = null) {
  return { status: 'unhealthy', summary, evidence: compact(evidence), nextAction };
}

function unknown(summary, evidence = [], nextAction = null) {
  return { status: 'unknown', summary, evidence: compact(evidence), nextAction };
}

function compact(items) {
  return items.filter(item => item !== undefined && item !== null && item !== '');
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

function redactUrl(url) {
  return String(url || '').replace(/([?&](?:token|api_key|apikey|key|auth)=)[^&]+/gi, '$1[redacted]');
}

function toIso(value) {
  return new Date(value).toISOString();
}

function toTimeMs(value) {
  return new Date(value).getTime();
}

function probeTcpPort({ host = '127.0.0.1', port, timeoutMs = 350 }) {
  return new Promise(resolve => {
    if (!port || Number(port) <= 0) {
      resolve({ ok: false, error: 'port-not-configured' });
      return;
    }
    const socket = net.createConnection({ host, port: Number(port) });
    let settled = false;
    const settle = result => {
      if (settled) return;
      settled = true;
      socket.destroy();
      resolve(result);
    };
    socket.setTimeout(timeoutMs);
    socket.on('connect', () => settle({ ok: true, host, port: Number(port) }));
    socket.on('timeout', () => settle({ ok: false, error: 'timeout', host, port: Number(port) }));
    socket.on('error', error => settle({ ok: false, error: error.code || error.message, host, port: Number(port) }));
  });
}

function probeHttpEndpoint(url, { timeoutMs = 500, maxBytes = 4096 } = {}) {
  return new Promise(resolve => {
    const request = http.get(url, response => {
      let bytes = 0;
      response.on('data', chunk => {
        bytes += chunk.length;
        if (bytes > maxBytes) request.destroy();
      });
      response.on('end', () => {
        resolve({
          ok: response.statusCode >= 200 && response.statusCode < 300,
          statusCode: response.statusCode,
          bytes,
        });
      });
    });
    request.setTimeout(timeoutMs, () => request.destroy(new Error('timeout')));
    request.on('error', error => resolve({ ok: false, error: error.message || String(error) }));
  });
}

module.exports = {
  DEFAULT_FRESHNESS_MS,
  buildLogSources,
  collectLocalObservations,
  collectLocalProfileStatus,
  probeHttpEndpoint,
  probeTcpPort,
  resolveRuntimePaths,
};
