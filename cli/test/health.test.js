const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const { makeEnvironment, write } = require('./helpers');
const { createHealthReport } = require('../src/orchestrator');

const repoRoot = path.resolve(__dirname, '..', '..');
const manifest = JSON.parse(
  fs.readFileSync(path.join(repoRoot, 'manifests', 'unified-runtime.json'), 'utf8'),
);

test('bmfctl health reads shared local profile observations from runtime files', async () => {
  const env = makeEnvironment();
  const runtimeDir = path.join(env.liveMods, 'BMF', 'runtime');

  write(path.join(env.gameWin64, 'BrickadiaServer-Win64-Shipping.exe'), '');
  write(path.join(env.liveMods, 'BMF', 'enabled.txt'), '\n');
  write(path.join(runtimeDir, 'events.jsonl'), '');
  write(path.join(runtimeDir, 'bmf.log'), '');
  write(
    path.join(runtimeDir, 'status.json'),
    JSON.stringify({
      state: 'running',
      version: '0.1.0-dev',
      updated_at: new Date().toISOString(),
      server_ready: true,
      command_worker_mode: 'async',
      socket_worker_started: true,
    }),
  );
  write(
    path.join(runtimeDir, 'socket.json'),
    JSON.stringify({
      enabled: true,
      host: '127.0.0.1',
      port: 49152,
      token: 'socket-token',
    }),
  );
  write(path.join(runtimeDir, 'frame-telemetry.json'), JSON.stringify({ sampleCount: 12, maxFrameMs: 15 }));

  const report = await createHealthReport({
    ...env.options,
    manifest,
    telemetry: true,
    frameTelemetry: true,
    dashboardUrl: 'https://grafana.example/d/bmf?token=secret',
  });

  assert.equal(report.profile.paths.bmfRuntimeDir, runtimeDir);
  assert.equal(report.observations['brickadia-files'].status, 'healthy');
  assert.equal(report.observations['ue4ss-enabled'].status, 'healthy');
  assert.equal(report.observations['bmf-status-fresh'].status, 'healthy');
  assert.equal(report.observations['bmf-socket-connected'].status, 'healthy');
  assert.equal(report.observations['frame-telemetry-fresh'].status, 'healthy');
  assert.equal(report.observations['metrics-endpoint'].status, 'unknown');
  assert.equal(report.serviceDiagnostics.startReadiness.status, 'unknown');
  assert.ok(report.serviceDiagnostics.ports.some(port => port.id === 'omegga-web'));
  assert.equal(report.observations['dashboard-imported'].evidence[0], 'https://grafana.example/d/bmf?token=[redacted]');
  assert.ok(report.logSources.some(source => source.id === 'events-jsonl' && source.exists));
  assert.ok(report.guardrails.includes('read-existing-runtime-files-only'));
  assert.ok(report.guardrails.includes('bounded-local-port-inspection'));
});
