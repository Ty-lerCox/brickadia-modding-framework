const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const { makeEnvironment } = require('./helpers');
const {
  createDashboardImport,
  createTelemetryPlan,
  uploadDashboardImport,
  writeDashboardImport,
  writeTelemetryAlloy,
} = require('../src/orchestrator');

test('bmfctl telemetry plan renders Alloy config without secret values', () => {
  const env = makeEnvironment();
  const out = path.join(env.root, 'alloy', 'bmf.alloy');
  const previous = {
    url: process.env.BMF_GRAFANA_REMOTE_WRITE_URL,
    username: process.env.BMF_GRAFANA_REMOTE_WRITE_USERNAME,
    token: process.env.BMF_GRAFANA_REMOTE_WRITE_TOKEN,
  };
  process.env.BMF_GRAFANA_REMOTE_WRITE_URL = 'https://prometheus.example/api/prom/push';
  process.env.BMF_GRAFANA_REMOTE_WRITE_USERNAME = '12345';
  process.env.BMF_GRAFANA_REMOTE_WRITE_TOKEN = 'secret-token';
  try {
    const plan = createTelemetryPlan({
      ...env.options,
      out,
      profileName: 'Telemetry Fixture',
      telemetryEnvironment: 'dev lab',
      telemetryInstance: 'fixture one',
      grafanaBaseUrl: 'https://grafana.example',
      scrapeInterval: '30s',
    });

    assert.equal(plan.status, 'ready');
    assert.equal(plan.labels.environment, 'dev-lab');
    assert.equal(plan.alloy.outputPath, out);
    assert.match(plan.alloy.config, /127\.0\.0\.1:8080/);
    assert.match(plan.alloy.config, /scrape_interval = "30s"/);
    assert.equal(plan.alloy.config.includes('secret-token'), false);
    assert.equal(plan.alloy.missingSecretRefs.length, 0);
  } finally {
    restoreEnv('BMF_GRAFANA_REMOTE_WRITE_URL', previous.url);
    restoreEnv('BMF_GRAFANA_REMOTE_WRITE_USERNAME', previous.username);
    restoreEnv('BMF_GRAFANA_REMOTE_WRITE_TOKEN', previous.token);
  }
});

test('bmfctl telemetry alloy dry-run does not write generated config', () => {
  const env = makeEnvironment();
  const out = path.join(env.root, 'alloy', 'dry-run.alloy');
  const result = writeTelemetryAlloy({
    ...env.options,
    out,
    dryRun: true,
    scrapeInterval: '10s',
  });

  assert.equal(result.status, 'planned');
  assert.equal(result.dryRun, true);
  assert.equal(fs.existsSync(out), false);
  assert.equal(result.outputPath, out);
});

test('bmfctl telemetry dashboard builds a redacted import contract', () => {
  const env = makeEnvironment();
  const previous = process.env.BMF_GRAFANA_API_TOKEN;
  process.env.BMF_GRAFANA_API_TOKEN = 'dashboard-secret-token';
  try {
    const plan = createDashboardImport({
      ...env.options,
      profileName: 'Dashboard Fixture',
      grafanaBaseUrl: 'grafana.example',
      telemetryEnvironment: 'dev lab',
      telemetryInstance: 'fixture one',
    });

    assert.equal(plan.status, 'ready');
    assert.equal(plan.request.url, 'https://grafana.example/api/dashboards/db');
    assert.equal(plan.payload.dashboard.uid, 'bmf-standard');
    assert.equal(plan.request.secretStatus[0].configured, true);
    assert.equal(JSON.stringify(plan).includes('dashboard-secret-token'), false);
  } finally {
    restoreEnv('BMF_GRAFANA_API_TOKEN', previous);
  }
});

test('bmfctl telemetry dashboard dry-run does not write generated payload', () => {
  const env = makeEnvironment();
  const out = path.join(env.root, 'grafana', 'dashboard-import.json');
  const result = writeDashboardImport({
    ...env.options,
    out,
    dryRun: true,
    grafanaBaseUrl: 'https://grafana.example',
  });

  assert.equal(result.status, 'planned');
  assert.equal(result.dryRun, true);
  assert.equal(fs.existsSync(out), false);
  assert.equal(result.outputPath, out);
});

test('bmfctl telemetry dashboard upload requires confirmation and redacts token', async () => {
  const env = makeEnvironment();
  const previous = process.env.BMF_GRAFANA_API_TOKEN;
  process.env.BMF_GRAFANA_API_TOKEN = 'dashboard-secret-token';
  try {
    await assert.rejects(
      () => uploadDashboardImport({
        ...env.options,
        grafanaBaseUrl: 'https://grafana.example',
        fetch: async () => {
          throw new Error('fetch should not run without confirmation');
        },
      }),
      /--confirm import/,
    );

    const requests = [];
    const result = await uploadDashboardImport({
      ...env.options,
      grafanaBaseUrl: 'https://grafana.example',
      confirm: 'import',
      fetch: async (url, request) => {
        requests.push({ url, request });
        return {
          ok: true,
          status: 200,
          statusText: 'OK',
          async text() {
            return JSON.stringify({
              status: 'success',
              uid: 'bmf-standard',
              url: '/d/bmf-standard/bmf-standard?token=server-token',
              version: 3,
            });
          },
        };
      },
    });

    assert.equal(requests.length, 1);
    assert.equal(requests[0].url, 'https://grafana.example/api/dashboards/db');
    assert.equal(requests[0].request.headers.Authorization, 'Bearer dashboard-secret-token');
    assert.equal(result.status, 'uploaded');
    assert.equal(result.dashboard.dashboardVersion, 3);
    assert.equal(JSON.stringify(result).includes('dashboard-secret-token'), false);
    assert.equal(JSON.stringify(result).includes('server-token'), false);
  } finally {
    restoreEnv('BMF_GRAFANA_API_TOKEN', previous);
  }
});

test('checked-in Grafana dashboard and PromQL satisfy the performance contract', () => {
  const dashboardPath = path.join(
    __dirname,
    '..',
    '..',
    'observability',
    'grafana',
    'bmf-dashboard.json',
  );
  const dashboard = JSON.parse(fs.readFileSync(dashboardPath, 'utf8'));
  const panels = new Map(dashboard.panels.map(panel => [panel.title, panel]));
  const requiredPanels = [
    'Current FPS (from frame duration)',
    'Average FPS from Average Frame Duration',
    'Average FPS in 30-second Blocks (last 30 minutes)',
    'Average and Worst Frame Time in 30-second Blocks',
    'Frame Duration: Current / p50 / p95 / p99 / Max',
    'Slow Frames per 10,000 Frames',
    'Unified Scheduler Depth, Age, and In-flight Work',
    'Blocked, Expired, and Outcome-Unknown Work',
    'Player Cache Misses, Repairs, Scans, and Unresolved Players',
  ];

  for (const title of requiredPanels) {
    assert.ok(panels.has(title), `missing required dashboard panel: ${title}`);
  }

  const targets = dashboard.panels.flatMap(panel => panel.targets || []);
  assert.ok(targets.length > 0, 'dashboard must contain PromQL targets');
  for (const target of targets) {
    assert.equal(typeof target.expr, 'string');
    assertPromQlStructure(target.expr);
  }

  const averageFpsTargets = panels
    .get('Average FPS from Average Frame Duration')
    .targets.map(target => target.expr);
  assert.equal(averageFpsTargets.length, 3);
  for (const range of ['30s', '5m', '30m']) {
    assert.ok(
      averageFpsTargets.some(expr =>
        expr.includes(`1000 / clamp_min(avg_over_time(`) && expr.includes(`[${range}]`)),
      `average FPS must derive from average frame duration over ${range}`,
    );
  }

  const annotations = dashboard.annotations?.list || [];
  const annotationTags = new Set(annotations.flatMap(annotation => annotation.tags || []));
  for (const tag of ['deployment', 'restart', 'crash', 'autosave', 'reconnect', 'plugin-reload']) {
    assert.ok(annotationTags.has(tag), `missing dashboard annotation tag: ${tag}`);
  }
});

function assertPromQlStructure(expression) {
  const stack = [];
  const pairs = new Map([
    [')', '('],
    [']', '['],
    ['}', '{'],
  ]);
  let inString = false;
  let escaped = false;

  for (const character of expression) {
    if (inString) {
      if (escaped) {
        escaped = false;
      } else if (character === '\\') {
        escaped = true;
      } else if (character === '"') {
        inString = false;
      }
      continue;
    }
    if (character === '"') {
      inString = true;
    } else if ('([{'.includes(character)) {
      stack.push(character);
    } else if (pairs.has(character)) {
      assert.equal(stack.pop(), pairs.get(character), `unbalanced PromQL: ${expression}`);
    }
  }

  assert.equal(inString, false, `unterminated PromQL string: ${expression}`);
  assert.deepEqual(stack, [], `unbalanced PromQL: ${expression}`);
  assert.doesNotMatch(expression, /\b(?:NaN|Infinity)\b/);
}

function restoreEnv(name, value) {
  if (value === undefined) {
    delete process.env[name];
  } else {
    process.env[name] = value;
  }
}
