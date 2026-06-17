const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const { makeEnvironment } = require('./helpers');
const { createPlan, createPrerequisiteReport, profileFromContext } = require('../src/orchestrator');
const { resolveContext } = require('../src/context');

const repoRoot = path.resolve(__dirname, '..', '..');
const manifest = JSON.parse(
  fs.readFileSync(path.join(repoRoot, 'manifests', 'unified-runtime.json'), 'utf8'),
);

test('bmfctl plan uses orchestrator-core install operation contract', () => {
  const env = makeEnvironment();
  const plan = createPlan('install-stack', {
    ...env.options,
    manifest,
    telemetry: true,
    profile: 'local-dev',
  });

  assert.equal(plan.operationId, 'install-stack');
  assert.equal(plan.dryRun, true);
  assert.equal(plan.profile.paths.bmfRoot, env.bmfRoot);
  assert.equal(plan.profile.paths.omeggaRuntime, env.omeggaDir);
  assert.ok(plan.actions.some(action => action.component === 'bmf-runtime'));
  assert.ok(plan.actions.some(action => action.component === 'grafana-alloy'));
});

test('bmfctl bootstrap plan includes telemetry and event inspection when requested', () => {
  const env = makeEnvironment();
  const plan = createPlan('bootstrap', {
    ...env.options,
    manifest,
    telemetry: true,
  });

  assert.deepEqual(plan.operations.map(operation => operation.operationId), [
    'install-stack',
    'configure-telemetry',
    'start-stack',
    'inspect-event-traffic',
  ]);
  assert.equal(plan.prerequisites.feature, 'prerequisites.audit');
});

test('bmfctl prerequisites reports blocking setup gaps', () => {
  const env = makeEnvironment();
  const report = createPrerequisiteReport({
    ...env.options,
    telemetry: true,
  });

  assert.equal(report.feature, 'prerequisites.audit');
  assert.equal(report.status, 'blocked');
  assert.ok(report.summary.blocked > 0);
  assert.ok(report.checks.some(check => check.id === 'bmf-root'));
  assert.ok(report.checks.some(check => check.id === 'omegga-runtime-source'));
});

test('bmfctl profile mapping preserves resolved runtime paths and ports', () => {
  const env = makeEnvironment();
  const ctx = resolveContext(env.options);
  const profile = profileFromContext(ctx, {
    profile: 'Local Dev Server',
    brickadiaPort: '7778',
    omeggaWebPort: '8088',
  });

  assert.equal(profile.id, 'local-dev-server');
  assert.equal(profile.ports.brickadia, 7778);
  assert.equal(profile.ports.omeggaWeb, 8088);
  assert.equal(profile.paths.brickadiaWin64, env.gameWin64);
});
